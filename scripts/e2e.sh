#!/usr/bin/env bash
# End-to-end acceptance checks for the directional zone trust POC.
#
# This script deliberately uses the dashboard API for mutations.  It never
# changes a ZoneTrust directly because testing the Kubernetes object alone does
# not exercise the operator-facing contract.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/versions.env"
MODE=${MODE:-standalone}
case "$MODE" in standalone|istio) ;; *) echo "MODE must be standalone or istio" >&2; exit 2 ;; esac
export KUBECONFIG=${KUBECONFIG:-"$ROOT/.state/$MODE/kubeconfig"}

ZONE_A=${E2E_ZONE_A:-zone-a}
ZONE_B=${E2E_ZONE_B:-zone-b}
E2E_NAMESPACE=${E2E_NAMESPACE:-poc-e2e}
CONTROL_NAMESPACE=${E2E_CONTROL_NAMESPACE:-control-plane}
CONTROLLER_DEPLOYMENT=${E2E_CONTROLLER_DEPLOYMENT:-zone-trust-controller}
CONTROLLER_SERVICE=${E2E_CONTROLLER_SERVICE:-zone-trust-controller}
GATEWAY_DEPLOYMENT=${E2E_GATEWAY_DEPLOYMENT:-zone-gateway}
GATEWAY_SERVICE=${E2E_GATEWAY_SERVICE:-zone-gateway}
APP_DEPLOYMENT=${E2E_APP_DEPLOYMENT:-zone-app}
APP_SERVICE=${E2E_APP_SERVICE:-zone-app}
CLIENT_POD=${E2E_CLIENT_POD:-zone-trust-e2e-client}
DIRECT_CLIENT_POD=${E2E_DIRECT_CLIENT_POD:-zone-trust-direct-client}
# versions.env pins the default image. E2E_CURL_IMAGE exists only for a
# deliberate local override (for example, a preloaded air-gapped image).
CURL_IMAGE=${E2E_CURL_IMAGE:-$CURL_IMAGE}
if [[ -n ${E2E_GATEWAY_ADMIN_PORT:-} ]]; then
  GATEWAY_ADMIN_PORT=$E2E_GATEWAY_ADMIN_PORT
elif [[ "$MODE" == istio ]]; then
  GATEWAY_ADMIN_PORT=15000
else
  GATEWAY_ADMIN_PORT=9901
fi
REQUEST_TIMEOUT=${E2E_REQUEST_TIMEOUT:-8}
CONVERGENCE_TIMEOUT=${E2E_CONVERGENCE_TIMEOUT:-90}
TOGGLE_SAMPLES=${E2E_TOGGLE_SAMPLES:-20}
SVID_ROTATION_TIMEOUT=${E2E_SVID_ROTATION_TIMEOUT:-360}
ISTIOCTL=${ISTIOCTL:-"$ROOT/.tools/bin/istioctl"}

if [[ ! -r "$KUBECONFIG" ]]; then
  echo "kubeconfig is not readable: $KUBECONFIG" >&2
  exit 2
fi
for command in kubectl curl python3 awk sort date; do
  command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 2; }
done
if [[ "$MODE" == istio ]]; then
  [[ -x "$ISTIOCTL" ]] || { echo "istioctl is required for Istio e2e: $ISTIOCTL" >&2; exit 2; }
fi

EVIDENCE_ROOT="$ROOT/.state/$MODE/evidence"
STATE_DIR="$EVIDENCE_ROOT/$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$STATE_DIR"
PF_PIDS=()
PASS=0
FAIL=0
CONTROLLER_PORT=
declare -A APP_PORT=()
declare -a APPLY_MS=()
declare -a TRAFFIC_MS=()

cleanup() {
  local pid
  for pid in "${PF_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  kubectl -n "$E2E_NAMESPACE" delete pod "$CLIENT_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$ZONE_A" delete pod "$DIRECT_CLIENT_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

log() { printf '%s\n' "$*" >&2; }
now_ms() { date +%s%3N; }

run_case() {
  local name=$1
  shift
  log "==> $name"
  if "$@"; then
    PASS=$((PASS + 1))
    printf 'PASS\t%s\n' "$name" >>"$STATE_DIR/results.tsv"
    log "    PASS"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL\t%s\n' "$name" >>"$STATE_DIR/results.tsv"
    log "    FAIL (see $STATE_DIR)"
  fi
}

fail() { log "    assertion: $*"; return 1; }

require_cluster_prerequisites() {
  kubectl get namespace "$E2E_NAMESPACE" >/dev/null
  kubectl -n "$CONTROL_NAMESPACE" rollout status "deployment/$CONTROLLER_DEPLOYMENT" --timeout=120s >/dev/null
  local zone
  for zone in "$ZONE_A" "$ZONE_B"; do
    kubectl -n "$zone" rollout status "deployment/$APP_DEPLOYMENT" --timeout=120s >/dev/null
    kubectl -n "$zone" rollout status "deployment/$GATEWAY_DEPLOYMENT" --timeout=180s >/dev/null
  done
}

# Creates a port-forward and assigns its local port to the named variable.
# kubectl permits a local port of 0, avoiding collisions with developer
# processes. Do not call this through command substitution: the cleanup PID
# must remain in this shell's PF_PIDS array.
start_port_forward() {
  local result_var=$1 namespace=$2 target=$3 remote_port=$4 logfile line
  logfile="$STATE_DIR/pf-${namespace}-${target//\//_}-${remote_port}.log"
  kubectl -n "$namespace" port-forward --address 127.0.0.1 "$target" "0:$remote_port" >"$logfile" 2>&1 &
  local pid=$!
  PF_PIDS+=("$pid")
  for _ in $(seq 1 80); do
    if ! kill -0 "$pid" 2>/dev/null; then
      cat "$logfile" >&2 || true
      return 1
    fi
    line=$(sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$logfile" | head -n 1 || true)
    if [[ -n "$line" ]]; then
      printf -v "$result_var" '%s' "$line"
      return 0
    fi
    sleep 0.1
  done
  cat "$logfile" >&2 || true
  return 1
}

start_controller_port_forward() {
  start_port_forward CONTROLLER_PORT "$CONTROL_NAMESPACE" "service/$CONTROLLER_SERVICE" 8080 || return 1
  for _ in $(seq 1 60); do
    curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:$CONTROLLER_PORT/api/v1/zones" >/dev/null && return 0
    sleep 0.2
  done
  return 1
}

start_app_port_forward() {
  local zone=$1 port
  start_port_forward port "$zone" "service/$APP_SERVICE" 8080 || return 1
  APP_PORT[$zone]=$port
  for _ in $(seq 1 60); do
    curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:${APP_PORT[$zone]}/healthz" >/dev/null && return 0
    sleep 0.2
  done
  return 1
}

ensure_app_port_forward() {
  local zone=$1
  local port=${APP_PORT[$zone]:-}
  if [[ -n "$port" ]] && curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:$port/healthz" >/dev/null; then
    return 0
  fi
  start_app_port_forward "$zone"
}

ensure_controller_port_forward() {
  if [[ -n "$CONTROLLER_PORT" ]] && curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:$CONTROLLER_PORT/api/v1/zones" >/dev/null; then
    return 0
  fi
  start_controller_port_forward
}

json_number() {
  local key=$1
  python3 -c 'import json,sys; value=json.load(sys.stdin)[sys.argv[1]]; print(value)' "$key"
}

app_requests() {
  local zone=$1 response
  ensure_app_port_forward "$zone" || return 1
  response=$(curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:${APP_PORT[$zone]}/requests")
  printf '%s' "$response" | json_number requests
}

create_client_pods() {
  kubectl -n "$E2E_NAMESPACE" delete pod "$CLIENT_POD" --ignore-not-found --wait=true >/dev/null || return 1
  kubectl -n "$E2E_NAMESPACE" run "$CLIENT_POD" --image="$CURL_IMAGE" --restart=Never --labels='app.kubernetes.io/component=e2e-client' --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' --command -- sh -c 'sleep 3600' >/dev/null || return 1
  kubectl -n "$E2E_NAMESPACE" wait --for=condition=Ready "pod/$CLIENT_POD" --timeout=120s >/dev/null || return 1

  # This workload carries only the public gateway NetworkPolicy labels so it
  # can reach :8443 after the cross-namespace policy admits gateway Pods. It
  # intentionally omits spiffe.io/spire-managed-identity, so the
  # ClusterSPIFFEID selector cannot issue it a gateway SVID. This tests TLS
  # client-authentication rather than merely a NetworkPolicy rejection.
  kubectl -n "$ZONE_A" delete pod "$DIRECT_CLIENT_POD" --ignore-not-found --wait=true >/dev/null || return 1
  kubectl -n "$ZONE_A" run "$DIRECT_CLIENT_POD" --image="$CURL_IMAGE" --restart=Never --labels="app.kubernetes.io/component=zone-gateway,security.poc.example/zone=$ZONE_A" --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' --command -- sh -c 'sleep 3600' >/dev/null || return 1
  kubectl -n "$ZONE_A" wait --for=condition=Ready "pod/$DIRECT_CLIENT_POD" --timeout=120s >/dev/null || return 1
}

client_curl() {
  # Output has the HTTP code as the final line. A transport failure is 000.
  kubectl -n "$E2E_NAMESPACE" exec "$CLIENT_POD" -- curl --silent --show-error --max-time "$REQUEST_TIMEOUT" -o - -w '\n%{http_code}\n' "$@"
}

gateway_call() {
  local source=$1 destination=$2 path=$3
  shift 3
  client_curl "$@" "http://${GATEWAY_SERVICE}.${source}.svc.cluster.local:8080/call/${destination}${path}"
}

request_code() { tail -n 1; }
request_body() { sed '$d'; }

is_successful_response() {
  local output=$1 code
  code=$(printf '%s\n' "$output" | request_code)
  [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

is_denied_response() {
  local output=$1 code
  code=$(printf '%s\n' "$output" | request_code)
  [[ ! "$code" =~ ^2[0-9][0-9]$ ]]
}

edge_name() { printf '%s-to-%s' "$1" "$2"; }

reset_test_edges() {
  local a_to_b b_to_a
  a_to_b=$(edge_name "$ZONE_A" "$ZONE_B")
  b_to_a=$(edge_name "$ZONE_B" "$ZONE_A")
  # These are the two exact fixture names that this harness owns. Deleting
  # them restores the documented absent-edge deny-all baseline without touching
  # any other ZoneTrust a developer might be inspecting.
  kubectl delete zonetrust "$a_to_b" "$b_to_a" --ignore-not-found >/dev/null || return 1
  printf 'reset fixture edges: %s %s\n' "$a_to_b" "$b_to_a" >>"$STATE_DIR/actions.log" || return 1
}

edge_generation() {
  kubectl get zonetrust "$(edge_name "$1" "$2")" -o jsonpath='{.metadata.generation}'
}

edge_applied() {
  local source=$1 destination=$2 name generation observed applied
  name=$(edge_name "$source" "$destination")
  generation=$(kubectl get zonetrust "$name" -o jsonpath='{.metadata.generation}')
  observed=$(kubectl get zonetrust "$name" -o jsonpath='{.status.observedGeneration}')
  applied=$(kubectl get zonetrust "$name" -o jsonpath='{.status.applied}')
  [[ "$generation" == "$observed" && "$applied" == true ]]
}

wait_edge_applied() {
  local source=$1 destination=$2 deadline=$((SECONDS + CONVERGENCE_TIMEOUT))
  while (( SECONDS < deadline )); do
    if edge_applied "$source" "$destination"; then return 0; fi
    sleep 0.25
  done
  kubectl get zonetrust "$(edge_name "$source" "$destination")" -o yaml >&2 || true
  return 1
}

set_edge() {
  local source=$1 destination=$2 allowed=$3 payload response start accepted applied
  ensure_controller_port_forward || return 1
  payload=$(printf '{"allowed":%s}' "$allowed")
  start=$(now_ms)
  if ! response=$(curl --fail --silent --show-error --max-time 10 -X PUT -H 'Content-Type: application/json' --data "$payload" "http://127.0.0.1:$CONTROLLER_PORT/api/v1/trusts/$source/$destination"); then
    return 1
  fi
  accepted=$(now_ms)
  if ! wait_edge_applied "$source" "$destination"; then return 1; fi
  applied=$(now_ms)
  # Return acceptance and application timestamps to callers; acceptance proves
  # the dashboard API accepted the desired state, application proves the CR
  # status caught up to the generation.
  printf '%s %s %s\n' "$start" "$accepted" "$applied"
}

set_edge_and_wait_for_traffic() {
  local source=$1 destination=$2 allowed=$3 expected=$4 timing start accepted applied observed output
  timing=$(set_edge "$source" "$destination" "$allowed") || return 1
  read -r start accepted applied <<<"$timing" || return 1
  local deadline=$((SECONDS + CONVERGENCE_TIMEOUT))
  while (( SECONDS < deadline )); do
    output=$(gateway_call "$source" "$destination" /e2e-convergence)
    if [[ "$expected" == allow ]] && is_successful_response "$output"; then observed=$(now_ms); break; fi
    if [[ "$expected" == deny ]] && is_denied_response "$output"; then observed=$(now_ms); break; fi
    sleep 0.25
  done
  [[ -n ${observed:-} ]] || return 1
  APPLY_MS+=("$((applied - accepted))")
  TRAFFIC_MS+=("$((observed - applied))")
}

assert_counter_unchanged_after_denied_call() {
  local source=$1 destination=$2 before output after
  before=$(app_requests "$destination") || return 1
  output=$(gateway_call "$source" "$destination" /e2e-denied) || true
  is_denied_response "$output" || { printf '%s\n' "$output" >&2; return 1; }
  after=$(app_requests "$destination") || return 1
  [[ "$before" == "$after" ]] || fail "denied request reached $destination app ($before -> $after)"
}

wait_for_gateway_decision() {
  local source=$1 destination=$2 expected=$3 path=$4 output deadline
  deadline=$((SECONDS + CONVERGENCE_TIMEOUT))
  while (( SECONDS < deadline )); do
    output=$(gateway_call "$source" "$destination" "$path") || true
    if [[ "$expected" == allow ]] && is_successful_response "$output"; then return 0; fi
    if [[ "$expected" == deny ]] && is_denied_response "$output"; then return 0; fi
    sleep 0.25
  done
  return 1
}

workload_fingerprint() {
  local zone
  for zone in "$ZONE_A" "$ZONE_B"; do
    kubectl -n "$zone" get pods -o json | python3 -c '
import json,sys
for pod in json.load(sys.stdin)["items"]:
    labels=pod.get("metadata",{}).get("labels",{})
    component=labels.get("app.kubernetes.io/component")
    managed_gateway=(component == "zone-gateway" and labels.get("spiffe.io/spire-managed-identity") == "true")
    if component != "app" and not managed_gateway:
        continue
    restarts=sum(c.get("restartCount", 0) for c in pod.get("status",{}).get("containerStatuses",[]))
    metadata=pod["metadata"]
    print("{}/{} {} {}".format(metadata["namespace"], metadata["name"], metadata["uid"], restarts))
'
  done | sort
}

assert_workloads_unchanged() {
  local before=$1 after
  after=$(workload_fingerprint) || return 1
  [[ "$before" == "$after" ]] || fail "a policy toggle changed app/gateway Pod UID or restart count"
}

test_default_deny() {
  # A new bootstrap starts with no edge at all. An existing edge here means the
  # cluster was not fresh (or bootstrap violated its deny-all contract), so do
  # not quietly turn that state into an explicit false policy and claim this
  # test covered missing-edge behavior.
  if kubectl get zonetrust "$(edge_name "$ZONE_A" "$ZONE_B")" >/dev/null 2>&1; then
    fail "default-deny test requires no $ZONE_A -> $ZONE_B ZoneTrust"
    return 1
  fi
  assert_counter_unchanged_after_denied_call "$ZONE_A" "$ZONE_B"
}

test_allow() {
  local before output after runtime_before
  runtime_before=$(workload_fingerprint) || return 1
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" allow /e2e-allow-converged || return 1
  before=$(app_requests "$ZONE_B") || return 1
  output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-allow) || return 1
  is_successful_response "$output" || { printf '%s\n' "$output" >&2; return 1; }
  after=$(app_requests "$ZONE_B") || return 1
  [[ "$after" -gt "$before" ]] || fail "allowed request did not reach $ZONE_B app"
  assert_workloads_unchanged "$runtime_before"
}

test_deleted_edge_deny() {
  local runtime_before
  runtime_before=$(workload_fingerprint) || return 1
  kubectl delete zonetrust "$(edge_name "$ZONE_A" "$ZONE_B")" >/dev/null || return 1
  printf 'deleted fixture edge: %s\n' "$(edge_name "$ZONE_A" "$ZONE_B")" >>"$STATE_DIR/actions.log" || return 1
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" deny /e2e-deleted-edge || return 1
  assert_counter_unchanged_after_denied_call "$ZONE_A" "$ZONE_B" || return 1
  assert_workloads_unchanged "$runtime_before"
}

test_directional() {
  local output runtime_before
  runtime_before=$(workload_fingerprint) || return 1
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  set_edge "$ZONE_B" "$ZONE_A" false >/dev/null || return 1
  output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-directional) || return 1
  is_successful_response "$output" || return 1
  assert_counter_unchanged_after_denied_call "$ZONE_B" "$ZONE_A" || return 1
  assert_workloads_unchanged "$runtime_before"
}

test_live_toggle() {
  local runtime_before
  runtime_before=$(workload_fingerprint) || return 1
  set_edge_and_wait_for_traffic "$ZONE_A" "$ZONE_B" false deny || return 1
  set_edge_and_wait_for_traffic "$ZONE_A" "$ZONE_B" true allow || return 1
  assert_workloads_unchanged "$runtime_before"
}

test_spoof_header() {
  local output body before after runtime_before
  runtime_before=$(workload_fingerprint) || return 1
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-spoof \
    -H 'x-spiffe-peer-id: spiffe://poc.example/ns/zone-b/sa/zone-gateway' \
    -H 'x-destination-zone: zone-a') || return 1
  is_successful_response "$output" || return 1
  body=$(printf '%s\n' "$output" | request_body) || return 1
  # The echo app is intentionally used as the final observer: protected headers
  # must not survive Envoy's internal header cleanup.
  if ! printf '%s' "$body" | python3 -c '
import json,sys
h={k.lower(): v for k,v in json.load(sys.stdin).get("headers", {}).items()}
assert "x-spiffe-peer-id" not in h, h
assert "x-destination-zone" not in h, h
'
  then
    return 1
  fi
  # A caller cannot turn an explicit deny into an allow by claiming to be a
  # different gateway. Check this separately from header stripping so both
  # security properties have direct evidence.
  set_edge "$ZONE_A" "$ZONE_B" false >/dev/null || return 1
  before=$(app_requests "$ZONE_B") || return 1
  output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-spoof-deny \
    -H 'x-spiffe-peer-id: spiffe://poc.example/ns/zone-a/sa/zone-gateway' \
    -H 'x-destination-zone: zone-b') || true
  is_denied_response "$output" || return 1
  after=$(app_requests "$ZONE_B") || return 1
  [[ "$before" == "$after" ]] || return 1
  assert_workloads_unchanged "$runtime_before"
}

test_wrong_workload() {
  local before output after
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  before=$(app_requests "$ZONE_B") || return 1
  output=$(kubectl -n "$ZONE_A" exec "$DIRECT_CLIENT_POD" -- curl --silent --show-error --insecure --max-time "$REQUEST_TIMEOUT" -o - -w '\n%{http_code}\n' "https://${GATEWAY_SERVICE}.${ZONE_B}.svc.cluster.local:8443/e2e-wrong-workload" || true)
  is_denied_response "$output" || { printf '%s\n' "$output" >&2; return 1; }
  after=$(app_requests "$ZONE_B") || return 1
  [[ "$before" == "$after" ]] || fail "workload without gateway identity reached $ZONE_B app"
}

test_direct_app_bypass() {
  local before output after
  before=$(app_requests "$ZONE_B") || return 1
  output=$(kubectl -n "$ZONE_A" exec "$DIRECT_CLIENT_POD" -- curl --silent --show-error --max-time "$REQUEST_TIMEOUT" -o - -w '\n%{http_code}\n' "http://${APP_SERVICE}.${ZONE_B}.svc.cluster.local:8080/e2e-direct-app" || true)
  is_denied_response "$output" || { printf '%s\n' "$output" >&2; return 1; }
  after=$(app_requests "$ZONE_B") || return 1
  [[ "$before" == "$after" ]] || fail "NetworkPolicy did not prevent direct app access ($before -> $after)"
}

test_controller_outage_and_recovery() {
  local before output after reverse_before reverse_output reverse_after
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  set_edge "$ZONE_B" "$ZONE_A" false >/dev/null || return 1
  # Status is an API-policy observation. Give Istiod/xDS time to program the
  # already-applied policy before removing the controller; otherwise this test
  # races policy propagation and mistakes that race for outage behavior.
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" allow /e2e-before-controller-outage || return 1
  kubectl -n "$CONTROL_NAMESPACE" scale "deployment/$CONTROLLER_DEPLOYMENT" --replicas=0 >/dev/null || return 1
  kubectl -n "$CONTROL_NAMESPACE" wait --for=delete "pod" -l app.kubernetes.io/name="$CONTROLLER_DEPLOYMENT" --timeout=90s >/dev/null || return 1
  before=$(app_requests "$ZONE_B") || return 1
  output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-controller-outage) || true
  if [[ "$MODE" == standalone ]]; then
    is_denied_response "$output" || { printf '%s\n' "$output" >&2; return 1; }
    after=$(app_requests "$ZONE_B") || return 1
    [[ "$before" == "$after" ]] || return 1
  else
    is_successful_response "$output" || { printf '%s\n' "$output" >&2; return 1; }
  fi
  # Istio retains the last accepted policy when its controller is down. Prove
  # that this is the specific directional state, not an accidental all-open
  # policy: B -> A remains denied and never reaches A's app.
  reverse_before=$(app_requests "$ZONE_A") || return 1
  reverse_output=$(gateway_call "$ZONE_B" "$ZONE_A" /e2e-controller-outage-reverse) || true
  is_denied_response "$reverse_output" || { printf '%s\n' "$reverse_output" >&2; return 1; }
  reverse_after=$(app_requests "$ZONE_A") || return 1
  [[ "$reverse_before" == "$reverse_after" ]] || return 1
  kubectl -n "$CONTROL_NAMESPACE" scale "deployment/$CONTROLLER_DEPLOYMENT" --replicas=1 >/dev/null || return 1
  kubectl -n "$CONTROL_NAMESPACE" rollout status "deployment/$CONTROLLER_DEPLOYMENT" --timeout=180s >/dev/null || return 1
  # The old dashboard port-forward targets the deleted Pod. Re-establish it
  # before inspecting API-backed state, then wait for a real data-plane allow;
  # a previously equal ZoneTrust status alone does not prove the new standalone
  # controller has rebuilt its in-memory snapshot.
  ensure_controller_port_forward || return 1
  wait_edge_applied "$ZONE_A" "$ZONE_B" || return 1
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" allow /e2e-controller-recovery
}

gateway_admin_port() {
  local result_var=$1 zone=$2 pod forwarded_port
  pod=$(kubectl -n "$zone" get pod -l app.kubernetes.io/component=zone-gateway,security.poc.example/zone="$zone",spiffe.io/spire-managed-identity=true -o jsonpath='{.items[0].metadata.name}') || return 1
  [[ -n "$pod" ]] || return 1
  start_port_forward forwarded_port "$zone" "pod/$pod" "$GATEWAY_ADMIN_PORT" || return 1
  printf -v "$result_var" '%s' "$forwarded_port"
}

admin_certificate_metadata() {
  local port=$1 zone=$2 response
  response=$(curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:$port/certs?format=json") || return 1
  # Emit only public certificate metadata. Do not print PEM, certificate bytes,
  # or any private-key related field into the evidence directory or terminal.
  printf '%s' "$response" | python3 -c '
import json,sys
d=json.load(sys.stdin)
items=d.get("certificates", [])
for c in items:
  for cert in c.get("cert_chain", []):
    serial=cert.get("serial_number")
    expiry=cert.get("expiration_time")
    sans=cert.get("subject_alt_names", [])
    uris=[]
    for san in sans:
      if isinstance(san, str):
        uris.append(san.removeprefix("URI:"))
      elif isinstance(san, dict) and isinstance(san.get("uri"), str):
        uris.append(san["uri"])
    expected=f"spiffe://poc.example/ns/{sys.argv[1]}/sa/zone-gateway"
    if serial and expiry and expected in uris:
      print(f"{serial} {expiry}")
      raise SystemExit(0)
raise SystemExit("no serial/expiry in Envoy admin certificate response")
' "$zone"
}

# A local port-forward can close independently of the running gateway (for
# example while Kubernetes replaces the controller Pod during the outage test).
# Reopen it once and retry the public-metadata read; this does not refresh or
# alter the SVID being measured.
read_gateway_certificate_metadata() {
  local result_var=$1 zone=$2 port_var=$3 value
  if ! value=$(admin_certificate_metadata "${!port_var}" "$zone"); then
    gateway_admin_port "$port_var" "$zone" || return 1
    value=$(admin_certificate_metadata "${!port_var}" "$zone") || return 1
  fi
  printf -v "$result_var" '%s' "$value"
}

gateway_admin_contains() {
  local zone=$1 needle=$2 port dump
  gateway_admin_port port "$zone" || return 1
  dump=$(curl --fail --silent --show-error --max-time 8 "http://127.0.0.1:$port/config_dump") || return 1
  [[ "$dump" == *"$needle"* ]]
}

assert_istio_proxy_sync() {
  local zone pod status
  local -a pods=()
  for zone in "$ZONE_A" "$ZONE_B"; do
    pod=$(kubectl -n "$zone" get pod -l app.kubernetes.io/component=zone-gateway,spiffe.io/spire-managed-identity=true -o jsonpath='{.items[0].metadata.name}') || return 1
    [[ -n "$pod" ]] || return 1
    pods+=("$pod")
  done
  status=$("$ISTIOCTL" proxy-status --output json) || return 1
  printf '%s' "$status" | python3 -c '
import json,sys
status=json.load(sys.stdin)
expected=set(sys.argv[1:])
required={
  "type.googleapis.com/envoy.config.cluster.v3.Cluster",
  "type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment",
  "type.googleapis.com/envoy.config.listener.v3.Listener",
  "type.googleapis.com/envoy.config.route.v3.RouteConfiguration",
}
seen=set()
for resource in status.get("resources", []):
    node=resource.get("node", {}).get("id", "")
    pod=next((name for name in expected if node.startswith(name+".")), None)
    if pod is None:
        continue
    configs=resource.get("genericXdsConfigs", [])
    got={entry.get("typeUrl") for entry in configs}
    assert required <= got, (pod, "missing xDS types", required-got)
    assert all(entry.get("configStatus") == "SYNCED" for entry in configs), (pod, configs)
    seen.add(pod)
assert seen == expected, ("missing gateway proxy status", expected-seen)
' "${pods[@]}"
}

test_svid_rotation() {
  local before after output admin_port deadline runtime_before
  runtime_before=$(workload_fingerprint) || return 1
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  gateway_admin_port admin_port "$ZONE_A" || return 1
  read_gateway_certificate_metadata before "$ZONE_A" admin_port || return 1
  printf 'before: %s\n' "$before" >"$STATE_DIR/svid-rotation.txt" || return 1
  # The registration TTL is deliberately short in this POC. Waiting for an
  # actual SDS renewal is safer evidence than restarting a Pod, which may only
  # retrieve the same still-valid SVID from the Agent cache.
  deadline=$((SECONDS + SVID_ROTATION_TIMEOUT))
  while (( SECONDS < deadline )); do
    read_gateway_certificate_metadata after "$ZONE_A" admin_port || return 1
    [[ "$before" != "$after" ]] && break
    sleep 3
  done
  if [[ "$before" == "${after:-}" ]]; then
    fail "no SVID renewal observed within ${SVID_ROTATION_TIMEOUT}s; check SPIRE TTL and SDS rotation"
    return 1
  fi
  printf 'after: %s\n' "$after" >>"$STATE_DIR/svid-rotation.txt" || return 1
  output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-svid-rotation) || return 1
  is_successful_response "$output" || return 1
  assert_workloads_unchanged "$runtime_before"
}

test_structure() {
  local zone app_pod gateway_pod count secret_private_key_count
  for zone in "$ZONE_A" "$ZONE_B"; do
    count=$(kubectl -n "$zone" get deployment -o json | python3 -c 'import json,sys; print(sum(1 for d in json.load(sys.stdin)["items"] if d.get("spec",{}).get("template",{}).get("metadata",{}).get("labels",{}).get("app.kubernetes.io/component") == "zone-gateway"))') || return 1
    [[ "$count" == 1 ]] || return 1
    count=$(kubectl -n "$zone" get deployment -o json | python3 -c 'import json,sys; print(sum(1 for d in json.load(sys.stdin)["items"] if d.get("spec",{}).get("template",{}).get("metadata",{}).get("labels",{}).get("app.kubernetes.io/component") == "app"))') || return 1
    [[ "$count" == 1 ]] || return 1
    app_pod=$(kubectl -n "$zone" get pod -l app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}') || return 1
    gateway_pod=$(kubectl -n "$zone" get pod -l app.kubernetes.io/component=zone-gateway,spiffe.io/spire-managed-identity=true -o jsonpath='{.items[0].metadata.name}') || return 1
    [[ -n "$app_pod" && -n "$gateway_pod" ]] || return 1
    if ! kubectl -n "$zone" get pod "$app_pod" -o json | python3 -c '
import json,sys
p=json.load(sys.stdin); s=p["spec"]
assert len(s["containers"]) == 1, s["containers"]
assert not s.get("initContainers"), s.get("initContainers")
assert all(v.get("csi",{}).get("driver") != "csi.spiffe.io" for v in s.get("volumes", [])), s.get("volumes")
assert all("spiffe" not in e.get("name", "").lower() for c in s["containers"] for e in c.get("env", []))
'
    then
      return 1
    fi
    if ! kubectl -n "$zone" get pod "$gateway_pod" -o json | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert any(v.get("csi",{}).get("driver") == "csi.spiffe.io" for v in p["spec"].get("volumes", [])), p["spec"].get("volumes")
'
    then
      return 1
    fi
    # This reads only the live certificate serial/expiry after confirming the
    # expected SPIFFE URI SAN; it intentionally does not collect certificate
    # bodies or any key material.
    local admin_port
    gateway_admin_port admin_port "$zone" || return 1
    admin_certificate_metadata "$admin_port" "$zone" >/dev/null || return 1
  done
  kubectl get clusterspiffeid zone-gateway >/dev/null || return 1
  secret_private_key_count=$(kubectl get secret -A -o json | python3 -c 'import json,sys; print(sum(1 for x in json.load(sys.stdin)["items"] if "gateway" in x["metadata"]["name"] and any(k.lower().endswith(("key","key.pem")) for k in x.get("data",{}))))') || return 1
  [[ "$secret_private_key_count" == 0 ]] || return 1
  if [[ "$MODE" == standalone ]]; then
    # A standalone cluster does not install Istio's AuthorizationPolicy CRD.
    # If it is present (for example in a developer's mixed diagnostic cluster),
    # it must not contain controller-generated policies.
    if kubectl api-resources --api-group=security.istio.io -o name 2>/dev/null | grep -Fxq authorizationpolicies.security.istio.io; then
      if kubectl get authorizationpolicy -A -l app.kubernetes.io/managed-by=zone-trust-controller --ignore-not-found -o name | grep -q .; then
        return 1
      fi
    fi
    gateway_admin_contains "$ZONE_B" 'ext_authz' || return 1
  else
    for zone in "$ZONE_A" "$ZONE_B"; do
      kubectl -n "$zone" get authorizationpolicy zone-trust-generated >/dev/null || return 1
    done
    gateway_admin_contains "$ZONE_B" 'envoy.filters.http.rbac' || return 1
    assert_istio_proxy_sync || return 1
  fi
  edge_applied "$ZONE_A" "$ZONE_B"
}

report_timings() {
  local values_file=$1 label=$2
  [[ -s "$values_file" ]] || { printf '%s p50=n/a p95=n/a (no samples)\n' "$label"; return; }
  awk '{print $1}' "$values_file" | sort -n | awk -v label="$label" '
    { a[++n]=$1 }
    END { if (!n) exit 1; p50=a[int((n-1)*0.50)+1]; p95=a[int((n-1)*0.95)+1]; printf "%s p50=%sms p95=%sms n=%s\n", label,p50,p95,n }
  '
}

test_toggle_timings() {
  local n allowed timing start accepted applied observed output deadline runtime_before
  runtime_before=$(workload_fingerprint) || return 1
  for ((n=1; n<=TOGGLE_SAMPLES; n++)); do
    if (( n % 2 )); then allowed=true; else allowed=false; fi
    timing=$(set_edge "$ZONE_A" "$ZONE_B" "$allowed") || return 1
    read -r start accepted applied <<<"$timing" || return 1
    deadline=$((SECONDS + CONVERGENCE_TIMEOUT))
    while (( SECONDS < deadline )); do
      output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-timing) || true
      if [[ "$allowed" == true ]] && is_successful_response "$output"; then observed=$(now_ms); break; fi
      if [[ "$allowed" == false ]] && is_denied_response "$output"; then observed=$(now_ms); break; fi
      sleep 0.2
    done
    [[ -n ${observed:-} ]] || return 1
    printf '%s\n' "$((applied - accepted))" >>"$STATE_DIR/apply-ms.txt" || return 1
    printf '%s\n' "$((observed - applied))" >>"$STATE_DIR/traffic-ms.txt" || return 1
    unset observed
  done
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  report_timings "$STATE_DIR/apply-ms.txt" 'API acceptance -> applied status' | tee "$STATE_DIR/timings.txt" || return 1
  report_timings "$STATE_DIR/traffic-ms.txt" 'Applied status -> observed traffic' | tee -a "$STATE_DIR/timings.txt" || return 1
  assert_workloads_unchanged "$runtime_before"
}

main() {
  log "Running $MODE e2e; evidence directory: $STATE_DIR"
  require_cluster_prerequisites
  start_controller_port_forward
  start_app_port_forward "$ZONE_A"
  start_app_port_forward "$ZONE_B"
  reset_test_edges
  create_client_pods

  run_case 'default deny keeps destination counter unchanged' test_default_deny
  run_case 'allow A -> B reaches destination app' test_allow
  run_case 'structural invariants' test_structure
  run_case 'deleting A -> B returns immediately to deny' test_deleted_edge_deny
  run_case 'directional trust permits A -> B but denies B -> A' test_directional
  run_case 'live deny and restore allow without workload restart' test_live_toggle
  run_case 'spoofed protected identity headers are removed before app' test_spoof_header
  run_case 'non-gateway workload cannot enter protected 8443' test_wrong_workload
  run_case 'NetworkPolicy blocks direct zone-a -> zone-b app bypass' test_direct_app_bypass
  run_case 'controller outage and recovery match backend failure semantics' test_controller_outage_and_recovery
  run_case 'gateway SVID refresh exposes new public metadata and recovers traffic' test_svid_rotation
  run_case "${TOGGLE_SAMPLES} toggle convergence timing samples" test_toggle_timings

  log "e2e result: pass=$PASS fail=$FAIL"
  log "evidence: $STATE_DIR"
  (( FAIL == 0 ))
}

main "$@"
