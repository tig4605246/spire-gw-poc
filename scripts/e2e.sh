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
case "$MODE" in standalone|istio|istio-gateway-api) ;; *) echo "MODE must be standalone, istio, or istio-gateway-api" >&2; exit 2 ;; esac
export KUBECONFIG=${KUBECONFIG:-"$ROOT/.state/$MODE/kubeconfig"}

ZONE_A=${E2E_ZONE_A:-zone-a}
ZONE_B=${E2E_ZONE_B:-zone-b}
E2E_NAMESPACE=${E2E_NAMESPACE:-poc-e2e}
CONTROL_NAMESPACE=${E2E_CONTROL_NAMESPACE:-control-plane}
CONTROLLER_DEPLOYMENT=${E2E_CONTROLLER_DEPLOYMENT:-zone-trust-controller}
CONTROLLER_SERVICE=${E2E_CONTROLLER_SERVICE:-zone-trust-controller}
if [[ "$MODE" == istio-gateway-api ]]; then
  # Gateway API owns a Gateway named zone-gateway and Istio automatically
  # creates its independently named workload resources. Keep these identities
  # separate: policy targetRefs bind the Gateway, while traffic uses its
  # generated Service and SPIRE registers its generated ServiceAccount.
  GATEWAY_API_NAME=${E2E_GATEWAY_API_NAME:-zone-gateway}
  GATEWAY_DEPLOYMENT=${E2E_GATEWAY_DEPLOYMENT:-zone-gateway-istio}
  GATEWAY_SERVICE=${E2E_GATEWAY_SERVICE:-zone-gateway-istio}
  GATEWAY_SERVICE_ACCOUNT=${E2E_GATEWAY_SERVICE_ACCOUNT:-zone-gateway-istio}
else
  GATEWAY_API_NAME=${E2E_GATEWAY_API_NAME:-zone-gateway}
  GATEWAY_DEPLOYMENT=${E2E_GATEWAY_DEPLOYMENT:-zone-gateway}
  GATEWAY_SERVICE=${E2E_GATEWAY_SERVICE:-zone-gateway}
  GATEWAY_SERVICE_ACCOUNT=${E2E_GATEWAY_SERVICE_ACCOUNT:-zone-gateway}
fi
APP_DEPLOYMENT=${E2E_APP_DEPLOYMENT:-zone-app}
APP_SERVICE=${E2E_APP_SERVICE:-zone-app}
CLIENT_POD=${E2E_CLIENT_POD:-zone-trust-e2e-client}
DIRECT_CLIENT_POD=${E2E_DIRECT_CLIENT_POD:-zone-trust-direct-client}
# versions.env pins the default image. E2E_CURL_IMAGE exists only for a
# deliberate local override (for example, a preloaded air-gapped image).
CURL_IMAGE=${E2E_CURL_IMAGE:-$CURL_IMAGE}
if [[ -n ${E2E_GATEWAY_ADMIN_PORT:-} ]]; then
  GATEWAY_ADMIN_PORT=$E2E_GATEWAY_ADMIN_PORT
elif [[ "$MODE" == istio || "$MODE" == istio-gateway-api ]]; then
  GATEWAY_ADMIN_PORT=15000
else
  GATEWAY_ADMIN_PORT=9901
fi
REQUEST_TIMEOUT=${E2E_REQUEST_TIMEOUT:-8}
CONVERGENCE_TIMEOUT=${E2E_CONVERGENCE_TIMEOUT:-90}
# A ZoneTrust status update is observed by the controller before an Istio
# AuthorizationPolicy update has necessarily settled in the gateway proxy. A
# single matching response can therefore still be an older xDS snapshot. Keep
# the decision stable over a short bounded window before a security assertion
# takes its counter baseline or evaluates headers.
DECISION_STABLE_SAMPLES=${E2E_DECISION_STABLE_SAMPLES:-5}
DECISION_STABLE_INTERVAL=${E2E_DECISION_STABLE_INTERVAL:-0.25}
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
if [[ "$MODE" == istio || "$MODE" == istio-gateway-api ]]; then
  [[ -x "$ISTIOCTL" ]] || { echo "istioctl is required for Istio e2e: $ISTIOCTL" >&2; exit 2; }
fi
if [[ "$MODE" == istio-gateway-api ]]; then
  command -v openssl >/dev/null || { echo "openssl is required for Gateway API TLS acceptance" >&2; exit 2; }
fi

EVIDENCE_ROOT="$ROOT/.state/$MODE/evidence"
STATE_DIR="$EVIDENCE_ROOT/$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$STATE_DIR"
PF_PIDS=()
PASS=0
FAIL=0
CONTROLLER_PORT=
CONTROLLER_SCALED_DOWN=false
declare -A APP_PORT=()
declare -a APPLY_MS=()
declare -a TRAFFIC_MS=()

cleanup() {
  local pid
  for pid in "${PF_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  # A failed outage assertion must not leave the demonstration control plane
  # unavailable and make later independent checks meaningless. Cleanup errors
  # never replace the original test failure status.
  if [[ "$CONTROLLER_SCALED_DOWN" == true ]]; then
    kubectl -n "$CONTROL_NAMESPACE" scale "deployment/$CONTROLLER_DEPLOYMENT" --replicas=1 >/dev/null 2>&1 || true
  fi
  kubectl -n "$E2E_NAMESPACE" delete pod "$CLIENT_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$ZONE_A" delete pod "$DIRECT_CLIENT_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

log() { printf '%s\n' "$*" >&2; }
now_ms() { date +%s%3N; }
is_istio_mode() { [[ "$MODE" == istio || "$MODE" == istio-gateway-api ]]; }
is_gateway_api_mode() { [[ "$MODE" == istio-gateway-api ]]; }

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
  if is_gateway_api_mode; then
    "$ROOT/scripts/check-gateway-api.sh" | tee "$STATE_DIR/gateway-api-preflight.txt"
  fi
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

is_forbidden_response() {
  local output=$1 code
  code=$(printf '%s\n' "$output" | request_code)
  [[ "$code" == 403 ]]
}

# Failure evidence deliberately includes only an HTTP status and header names.
# It never writes a response body (which could contain caller-provided values)
# into CI logs or evidence files.
response_summary() {
  local output=$1
  printf '%s\n' "$output" | python3 -c '
import json,sys
lines=sys.stdin.read().splitlines()
code=lines[-1] if lines else "<empty>"
body="\n".join(lines[:-1])
try:
    headers=json.loads(body).get("headers", {})
    names=sorted(str(name).lower() for name in headers)
    print(f"http_code={code} header_names={names}")
except Exception:
    print(f"http_code={code} response_body=non-json-or-empty")
'
}

assert_protected_headers_absent() {
  local output=$1 body
  body=$(printf '%s\n' "$output" | request_body) || return 1
  if ! printf '%s' "$body" | python3 -c '
import json,sys
headers=json.load(sys.stdin).get("headers", {})
protected={"x-spiffe-peer-id", "x-destination-zone"}
found=sorted(str(name).lower() for name in headers if str(name).lower() in protected)
assert not found, found
'
  then
    response_summary "$output" >&2
    return 1
  fi
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
    if [[ "$expected" == deny ]] && is_forbidden_response "$output"; then observed=$(now_ms); break; fi
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
  is_forbidden_response "$output" || { response_summary "$output" >&2; return 1; }
  after=$(app_requests "$destination") || return 1
  [[ "$before" == "$after" ]] || fail "denied request reached $destination app ($before -> $after)"
}

wait_for_gateway_decision() {
  local source=$1 destination=$2 expected=$3 path=$4 output deadline stable=0
  deadline=$((SECONDS + CONVERGENCE_TIMEOUT))
  while (( SECONDS < deadline )); do
    output=$(gateway_call "$source" "$destination" "$path") || true
    if { [[ "$expected" == allow ]] && is_successful_response "$output"; } || \
       { [[ "$expected" == deny ]] && is_forbidden_response "$output"; }; then
      stable=$((stable + 1))
      if (( stable >= DECISION_STABLE_SAMPLES )); then return 0; fi
    else
      stable=0
    fi
    sleep "$DECISION_STABLE_INTERVAL"
  done
  log "    timed out waiting for stable $expected decision ($DECISION_STABLE_SAMPLES samples): $(response_summary "${output:-}")"
  return 1
}

# Keep retries restricted to propagation failures. If a spoofed request ever
# reaches the app successfully, validate its headers immediately and fail on a
# leak rather than retrying past the evidence. Failed transport/RBAC probes are
# required not to increment the app counter before trying again.
wait_for_clean_spoof_allow() {
  local source=$1 destination=$2 path=$3 before after output deadline
  shift 3
  before=$(app_requests "$destination") || return 1
  deadline=$((SECONDS + CONVERGENCE_TIMEOUT))
  while (( SECONDS < deadline )); do
    output=$(gateway_call "$source" "$destination" "$path" "$@") || true
    if is_successful_response "$output"; then
      assert_protected_headers_absent "$output" || return 1
      return 0
    fi
    after=$(app_requests "$destination") || return 1
    if [[ "$before" != "$after" ]]; then
      fail "rejected spoof convergence probe reached $destination app ($before -> $after)"
      return 1
    fi
    sleep "$DECISION_STABLE_INTERVAL"
  done
  log "    timed out waiting for spoof request to be allowed: $(response_summary "${output:-}")"
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

assert_istio_baseline() {
  kubectl -n "$ZONE_B" get authorizationpolicy zone-trust-baseline -o json | MODE="$MODE" GATEWAY_API_NAME="$GATEWAY_API_NAME" python3 -c '
import json,os,sys
p=json.load(sys.stdin)
assert p.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/managed-by") == "zone-trust-bootstrap", p
assert p.get("spec", {}).get("rules") == [{"to": [{"operation": {"ports": ["8080"]}}]}], p.get("spec")
if os.environ["MODE"] == "istio-gateway-api":
    assert p.get("spec", {}).get("targetRefs") == [{"group":"gateway.networking.k8s.io", "kind":"Gateway", "name":os.environ["GATEWAY_API_NAME"]}], p.get("spec")
else:
    assert p.get("spec", {}).get("selector", {}).get("matchLabels", {}).get("app.kubernetes.io/component") == "zone-gateway", p.get("spec")
'
}

gateway_principal() { printf 'poc.example/ns/%s/sa/%s' "$1" "$GATEWAY_SERVICE_ACCOUNT"; }

wait_dynamic_policy_empty() {
  local deadline=$((SECONDS + CONVERGENCE_TIMEOUT))
  while (( SECONDS < deadline )); do
    if kubectl -n "$ZONE_B" get authorizationpolicy zone-trust-generated -o json 2>/dev/null | python3 -c '
import json,sys
assert json.load(sys.stdin).get("spec", {}).get("rules") == []
' 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_dynamic_policy_allows_a_to_b() {
  local deadline=$((SECONDS + CONVERGENCE_TIMEOUT))
  while (( SECONDS < deadline )); do
    if kubectl -n "$ZONE_B" get authorizationpolicy zone-trust-generated -o json 2>/dev/null | MODE="$MODE" GATEWAY_API_NAME="$GATEWAY_API_NAME" EXPECTED_PRINCIPAL="$(gateway_principal "$ZONE_A")" python3 -c '
import json,os,sys
p=json.load(sys.stdin)
spec=p.get("spec", {})
rules=spec.get("rules", [])
assert all("8080" not in target.get("operation", {}).get("ports", []) for rule in rules for target in rule.get("to", []))
assert any(
    os.environ["EXPECTED_PRINCIPAL"] in source.get("source", {}).get("principals", [])
    and "8443" in target.get("operation", {}).get("ports", [])
    for rule in rules for source in rule.get("from", []) for target in rule.get("to", [])
)
if os.environ["MODE"] == "istio-gateway-api":
    assert spec.get("targetRefs") == [{"group":"gateway.networking.k8s.io", "kind":"Gateway", "name":os.environ["GATEWAY_API_NAME"]}], spec
' 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_istio_active_listener_without_dynamic_policy() {
  local pod deadline=$((SECONDS + CONVERGENCE_TIMEOUT)) dump
  pod=$(kubectl -n "$ZONE_B" get pod -l app.kubernetes.io/component=zone-gateway,security.poc.example/zone="$ZONE_B",spiffe.io/spire-managed-identity=true -o jsonpath='{.items[0].metadata.name}') || return 1
  [[ -n "$pod" ]] || return 1
  # proxy-config reads Envoy's active listener configuration; unlike a traffic
  # retry it cannot reach the destination application while xDS is converging.
  # Do not interpret the API deletion itself as immediate proxy revocation.
  while (( SECONDS < deadline )); do
    dump=$("$ISTIOCTL" proxy-config listeners "$pod" -n "$ZONE_B" --port 8443 --output json 2>/dev/null) || dump=
    if printf '%s' "$dump" | python3 -c '
import json,sys
d=json.load(sys.stdin)
encoded=json.dumps(d, sort_keys=True)
def walk(value):
    if isinstance(value, dict):
        yield value
        for item in value.values(): yield from walk(item)
    elif isinstance(value, list):
        for item in value: yield from walk(item)
listeners=list(walk(d))
assert any(str(x.get("name", "")).endswith("_8443") for x in listeners), d
assert "zone-trust-generated" not in encoded, encoded
' 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_istio_active_listener_with_dynamic_deny_all() {
  local pod deadline=$((SECONDS + CONVERGENCE_TIMEOUT)) dump
  pod=$(kubectl -n "$ZONE_B" get pod -l app.kubernetes.io/component=zone-gateway,security.poc.example/zone="$ZONE_B",spiffe.io/spire-managed-identity=true -o jsonpath='{.items[0].metadata.name}') || return 1
  [[ -n "$pod" ]] || return 1
  # Istio represents an ALLOW policy with rules: [] as one explicit RBAC
  # deny-all rule (notRule/notId any). This confirms xDS has observed the
  # recreated policy before the following exact-403 counter probe.
  while (( SECONDS < deadline )); do
    dump=$("$ISTIOCTL" proxy-config listeners "$pod" -n "$ZONE_B" --port 8443 --output json 2>/dev/null) || dump=
    if printf '%s' "$dump" | python3 -c '
import json,sys
d=json.load(sys.stdin)
def walk(value):
    if isinstance(value, dict):
        yield value
        for item in value.values(): yield from walk(item)
    elif isinstance(value, list):
        for item in value: yield from walk(item)
listeners=list(walk(d))
assert any(str(x.get("name", "")).endswith("_8443") for x in listeners), d
policies=[]
for item in listeners:
    policies.extend(item.get("policies", {}).items())
name, policy=next((pair for pair in policies if "zone-trust-generated" in pair[0]))
assert policy.get("permissions") == [{"notRule": {"any": True}}], (name, policy)
assert policy.get("principals") == [{"notId": {"any": True}}], (name, policy)
' 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

pause_controller() {
  kubectl -n "$CONTROL_NAMESPACE" scale "deployment/$CONTROLLER_DEPLOYMENT" --replicas=0 >/dev/null || return 1
  CONTROLLER_SCALED_DOWN=true
  if ! kubectl -n "$CONTROL_NAMESPACE" wait --for=delete "pod" -l app.kubernetes.io/name="$CONTROLLER_DEPLOYMENT" --timeout=90s >/dev/null; then
    restore_controller_after_outage || true
    return 1
  fi
}

test_istio_create_guard() {
  is_istio_mode || return 0
  local as_controller="system:serviceaccount:$CONTROL_NAMESPACE:zone-trust-controller" rejection
  # Use POST (rather than apply's PATCH) to exercise the recovery CREATE
  # permission directly. RBAC deliberately grants this verb, so a successful
  # negative test must be rejected by the ValidatingAdmissionPolicy itself.
  if rejection=$(kubectl --as="$as_controller" -n "$ZONE_B" create -f - 2>&1 <<'EOF'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: zone-trust-illegal-e2e
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: zone-gateway
      security.poc.example/zone: zone-b
  action: ALLOW
  rules: []
EOF
); then
    fail "admission guard allowed controller ServiceAccount to create a second AuthorizationPolicy"
    return 1
  fi
  if [[ "$rejection" != *"ValidatingAdmissionPolicy"* || "$rejection" != *"zone-trust-controller-authorizationpolicy-create"* ]]; then
    log "    expected ValidatingAdmissionPolicy rejection, got: $rejection"
    return 1
  fi
  kubectl -n "$ZONE_B" get authorizationpolicy zone-trust-illegal-e2e >/dev/null 2>&1 && return 1

  # Retain the SSA form as a separate check: it must not bypass the name guard
  # through an apply request. The named PATCH permission is absent for this
  # object, so this is defense in depth rather than the VAP proof above.
  if kubectl --as="$as_controller" -n "$ZONE_B" apply --server-side --force-conflicts \
    --field-manager=zone-trust-controller -f - >/dev/null <<'EOF'; then
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: zone-trust-illegal-e2e
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: zone-gateway
      security.poc.example/zone: zone-b
  action: ALLOW
  rules: []
EOF
    fail "controller ServiceAccount server-side applied a second AuthorizationPolicy"
    return 1
  fi

  # Existing-object mutation must remain constrained by RBAC resourceNames;
  # use server-side apply so this covers the same PATCH path as the controller.
  if kubectl --as="$as_controller" -n "$ZONE_B" apply --server-side --force-conflicts \
    --field-manager=zone-trust-controller -f - >/dev/null <<'EOF'; then
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: zone-trust-baseline
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: zone-gateway
      security.poc.example/zone: zone-b
  action: ALLOW
  rules:
    - to:
        - operation:
            ports: ["8443"]
EOF
    fail "controller ServiceAccount mutated the bootstrap AuthorizationPolicy"
    return 1
  fi
  assert_istio_baseline
}

test_istio_dynamic_policy_recreation_fail_closed() {
  is_istio_mode || return 0
  local runtime_before before after
  runtime_before=$(workload_fingerprint) || return 1

  # First delete the dynamic policy while an allowed edge is known to be live.
  # In the former one-policy design this removed the sole 8080 ALLOW policy,
  # leaving no AuthorizationPolicy that selected the gateway and fail-opening
  # protected 8443. The bootstrap policy must retain a stable exact 403 until
  # the controller can recreate the dynamic object.
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  wait_dynamic_policy_allows_a_to_b || return 1
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" allow /e2e-dynamic-predelete-allow || return 1
  before=$(app_requests "$ZONE_B") || return 1
  pause_controller || return 1
  if ! kubectl -n "$ZONE_B" delete authorizationpolicy zone-trust-generated --wait=true >/dev/null; then
    restore_controller_after_outage || true
    return 1
  fi
  if ! assert_istio_baseline || ! wait_istio_active_listener_without_dynamic_policy; then
    restore_controller_after_outage || true
    return 1
  fi
  # The first post-delete request is intentionally only after proxy evidence
  # says the active 8443 RBAC listener no longer has the dynamic policy.
  assert_counter_unchanged_after_denied_call "$ZONE_A" "$ZONE_B" || { restore_controller_after_outage || true; return 1; }
  after=$(app_requests "$ZONE_B") || { restore_controller_after_outage || true; return 1; }
  [[ "$before" == "$after" ]] || { restore_controller_after_outage || true; return 1; }

  # The actual controller SSA recreation proves both the CREATE grant and the
  # admission guard permit the one exact dynamic name. The allowed route may
  # return only after that policy is observed again.
  restore_controller_after_outage || return 1
  ensure_controller_port_forward || return 1
  wait_dynamic_policy_allows_a_to_b || return 1
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" allow /e2e-dynamic-recreated-allow || return 1

  # Repeat from a denied edge. Keep one app counter baseline across both the
  # missing-policy period and the repaired empty-rules policy, proving every
  # probe stayed a 403 through the whole fail-closed transition.
  set_edge "$ZONE_A" "$ZONE_B" false >/dev/null || return 1
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" deny /e2e-dynamic-denied-predelete || return 1
  before=$(app_requests "$ZONE_B") || return 1
  pause_controller || return 1
  if ! kubectl -n "$ZONE_B" delete authorizationpolicy zone-trust-generated --wait=true >/dev/null; then
    restore_controller_after_outage || true
    return 1
  fi
  if ! assert_istio_baseline || ! wait_istio_active_listener_without_dynamic_policy; then
    restore_controller_after_outage || true
    return 1
  fi
  assert_counter_unchanged_after_denied_call "$ZONE_A" "$ZONE_B" || { restore_controller_after_outage || true; return 1; }
  restore_controller_after_outage || return 1
  ensure_controller_port_forward || return 1
  if ! wait_dynamic_policy_empty || ! wait_istio_active_listener_with_dynamic_deny_all; then
    return 1
  fi
  assert_counter_unchanged_after_denied_call "$ZONE_A" "$ZONE_B" || return 1
  after=$(app_requests "$ZONE_B") || return 1
  [[ "$before" == "$after" ]] || return 1

  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  wait_dynamic_policy_allows_a_to_b || return 1
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" allow /e2e-dynamic-final-allow || return 1
  assert_workloads_unchanged "$runtime_before"
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
  if is_gateway_api_mode; then
    printf '%s\n' "$output" | request_body | python3 -c '
import json,sys
body=json.load(sys.stdin)
assert body.get("zone") == sys.argv[1], body
assert body.get("path") == "/e2e-allow", body
' "$ZONE_B" || return 1
  fi
  after=$(app_requests "$ZONE_B") || return 1
  [[ "$after" -gt "$before" ]] || fail "allowed request did not reach $ZONE_B app"
  assert_workloads_unchanged "$runtime_before"
}

test_deleted_edge_deny() {
  local runtime_before
  runtime_before=$(workload_fingerprint) || return 1
  kubectl delete zonetrust "$(edge_name "$ZONE_A" "$ZONE_B")" >/dev/null || return 1
  printf 'deleted fixture edge: %s\n' "$(edge_name "$ZONE_A" "$ZONE_B")" >>"$STATE_DIR/actions.log" || return 1
  if is_istio_mode; then
    # First prove the generated API policy no longer contains the deleted
    # principal. The data-plane helper below then requires a stable series of
    # RBAC 403s; a lone 403 can be an older xDS snapshot while a previous allow
    # update is still in flight.
    local deadline=$((SECONDS + CONVERGENCE_TIMEOUT))
    while (( SECONDS < deadline )); do
      if kubectl -n "$ZONE_B" get authorizationpolicy zone-trust-generated -o json | EXPECTED_PRINCIPAL="$(gateway_principal "$ZONE_A")" python3 -c '
import json,os,sys
policy=json.load(sys.stdin)
for rule in policy.get("spec", {}).get("rules", []):
    for source in rule.get("from", []):
        principals=source.get("source", {}).get("principals", [])
        assert os.environ["EXPECTED_PRINCIPAL"] not in principals
    for target in rule.get("to", []):
        ports=target.get("operation", {}).get("ports", [])
        assert "8443" not in ports
' 2>/dev/null; then
        break
      fi
      sleep 0.25
    done
    (( SECONDS < deadline )) || return 1
    wait_for_gateway_decision "$ZONE_A" "$ZONE_B" deny /e2e-deleted-edge || return 1
  else
    wait_for_gateway_decision "$ZONE_A" "$ZONE_B" deny /e2e-deleted-edge || return 1
  fi
  assert_counter_unchanged_after_denied_call "$ZONE_A" "$ZONE_B" || return 1
  assert_workloads_unchanged "$runtime_before"
}

test_directional() {
  local output runtime_before
  runtime_before=$(workload_fingerprint) || return 1
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  set_edge "$ZONE_B" "$ZONE_A" false >/dev/null || return 1
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" allow /e2e-directional-allow || return 1
  wait_for_gateway_decision "$ZONE_B" "$ZONE_A" deny /e2e-directional-deny || return 1
  output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-directional) || return 1
  is_successful_response "$output" || { response_summary "$output" >&2; return 1; }
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
  local output before after runtime_before
  runtime_before=$(workload_fingerprint) || return 1
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  wait_for_clean_spoof_allow "$ZONE_A" "$ZONE_B" /e2e-spoof \
    -H 'x-spiffe-peer-id: spiffe://poc.example/ns/zone-b/sa/zone-gateway' \
    -H 'x-destination-zone: zone-a' || return 1
  # A caller cannot turn an explicit deny into an allow by claiming to be a
  # different gateway. First reach a stable exact 403, then take the app
  # baseline; the single forged assertion below is intentionally not retried.
  set_edge "$ZONE_A" "$ZONE_B" false >/dev/null || return 1
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" deny /e2e-spoof-deny-converged || return 1
  before=$(app_requests "$ZONE_B") || return 1
  output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-spoof-deny \
    -H 'x-spiffe-peer-id: spiffe://poc.example/ns/zone-a/sa/zone-gateway' \
    -H 'x-destination-zone: zone-b') || true
  is_forbidden_response "$output" || { response_summary "$output" >&2; return 1; }
  after=$(app_requests "$ZONE_B") || return 1
  if [[ "$before" != "$after" ]]; then
    fail "forged denied request reached $ZONE_B app ($before -> $after)"
    return 1
  fi
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

test_gateway_api_rejects_missing_client_certificate() {
  is_gateway_api_mode || return 0
  local ca_file pod local_port transcript
  ca_file=$(mktemp "${TMPDIR:-/tmp}/spire-gateway-api-public-ca.XXXXXX") || return 1
  # The test deliberately trusts only SPIRE's public bundle.  Do not use
  # --insecure or a host trust store: those would make a TLS alert ambiguous
  # between an untrusted server and the required client-certificate rejection.
  if ! kubectl -n spire-system exec spire-server-0 -c spire-server -- \
    /opt/spire/bin/spire-server bundle show -format pem \
    -socketPath /tmp/spire-server/private/api.sock >"$ca_file"; then
    rm -f "$ca_file"
    return 1
  fi
  pod=$(kubectl -n "$ZONE_B" get pod -l app.kubernetes.io/component=zone-gateway,security.poc.example/zone="$ZONE_B",spiffe.io/spire-managed-identity=true -o jsonpath='{.items[0].metadata.name}') || { rm -f "$ca_file"; return 1; }
  if ! start_port_forward local_port "$ZONE_B" "pod/$pod" 8443; then
    rm -f "$ca_file"
    return 1
  fi
  # Never emit this transcript: OpenSSL may include public certificate detail
  # on a failed handshake. We only classify the verification result and alert.
  transcript=$(timeout 15s openssl s_client -verify_return_error \
    -no-CApath -no-CAstore -CAfile "$ca_file" -connect "127.0.0.1:$local_port" \
    -servername "${GATEWAY_SERVICE}.${ZONE_B}.svc.cluster.local" </dev/null 2>&1 || true)
  rm -f "$ca_file"
  if [[ "$transcript" != *'Verify return code: 0 (ok)'* ]]; then
    fail "Gateway API protected listener server chain did not validate against the public SPIRE bundle"
    return 1
  fi
  if [[ "$transcript" != *'certificate required'* && "$transcript" != *'Certificate Required'* && "$transcript" != *'peer did not return a certificate'* ]]; then
    fail "Gateway API protected listener did not reject a client with no certificate"
    return 1
  fi
}

test_direct_app_bypass() {
  local before output after
  before=$(app_requests "$ZONE_B") || return 1
  output=$(kubectl -n "$ZONE_A" exec "$DIRECT_CLIENT_POD" -- curl --silent --show-error --max-time "$REQUEST_TIMEOUT" -o - -w '\n%{http_code}\n' "http://${APP_SERVICE}.${ZONE_B}.svc.cluster.local:8080/e2e-direct-app" || true)
  is_denied_response "$output" || { printf '%s\n' "$output" >&2; return 1; }
  after=$(app_requests "$ZONE_B") || return 1
  [[ "$before" == "$after" ]] || fail "NetworkPolicy did not prevent direct app access ($before -> $after)"
}

restore_controller_after_outage() {
  # run_case intentionally continues after an individual failure, so an outage
  # assertion must restore the control plane before returning. The EXIT trap is
  # retained as a last-resort retry if restoration itself fails.
  kubectl -n "$CONTROL_NAMESPACE" scale "deployment/$CONTROLLER_DEPLOYMENT" --replicas=1 >/dev/null || return 1
  CONTROLLER_SCALED_DOWN=false
  kubectl -n "$CONTROL_NAMESPACE" rollout status "deployment/$CONTROLLER_DEPLOYMENT" --timeout=180s >/dev/null
}

test_controller_outage_and_recovery() {
  local before output after reverse_before reverse_output reverse_after n
  set_edge "$ZONE_A" "$ZONE_B" true >/dev/null || return 1
  set_edge "$ZONE_B" "$ZONE_A" false >/dev/null || return 1
  # Status is an API-policy observation. Give Istiod/xDS time to program the
  # already-applied policy before removing the controller; otherwise this test
  # races policy propagation and mistakes that race for outage behavior.
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" allow /e2e-before-controller-outage || return 1
  kubectl -n "$CONTROL_NAMESPACE" scale "deployment/$CONTROLLER_DEPLOYMENT" --replicas=0 >/dev/null || return 1
  CONTROLLER_SCALED_DOWN=true
  if ! kubectl -n "$CONTROL_NAMESPACE" wait --for=delete "pod" -l app.kubernetes.io/name="$CONTROLLER_DEPLOYMENT" --timeout=90s >/dev/null; then
    restore_controller_after_outage || true
    return 1
  fi
  if ! before=$(app_requests "$ZONE_B"); then
    restore_controller_after_outage || true
    return 1
  fi
  if [[ "$MODE" == standalone ]]; then
    output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-controller-outage) || true
    is_denied_response "$output" || { response_summary "$output" >&2; restore_controller_after_outage || true; return 1; }
    if ! after=$(app_requests "$ZONE_B"); then
      restore_controller_after_outage || true
      return 1
    fi
    if [[ "$before" != "$after" ]]; then
      restore_controller_after_outage || true
      return 1
    fi
  else
    # Each request uses a fresh upstream mTLS connection (enforced by the
    # DestinationRule) and must retain the last accepted Istio policy while
    # the controller is unavailable. One success is not sufficient evidence.
    for ((n=1; n<=8; n++)); do
      output=$(gateway_call "$ZONE_A" "$ZONE_B" "/e2e-controller-outage-$n") || true
      if ! is_successful_response "$output"; then
        response_summary "$output" >&2
        restore_controller_after_outage || true
        return 1
      fi
    done
  fi
  # Istio retains the last accepted policy when its controller is down. Prove
  # that this is the specific directional state, not an accidental all-open
  # policy: B -> A remains denied and never reaches A's app.
  if ! reverse_before=$(app_requests "$ZONE_A"); then
    restore_controller_after_outage || true
    return 1
  fi
  reverse_output=$(gateway_call "$ZONE_B" "$ZONE_A" /e2e-controller-outage-reverse) || true
  if is_istio_mode; then
    is_forbidden_response "$reverse_output" || { response_summary "$reverse_output" >&2; restore_controller_after_outage || true; return 1; }
  else
    is_denied_response "$reverse_output" || { response_summary "$reverse_output" >&2; restore_controller_after_outage || true; return 1; }
  fi
  if ! reverse_after=$(app_requests "$ZONE_A"); then
    restore_controller_after_outage || true
    return 1
  fi
  if [[ "$reverse_before" != "$reverse_after" ]]; then
    restore_controller_after_outage || true
    return 1
  fi
  restore_controller_after_outage || return 1
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
    expected=f"spiffe://poc.example/ns/{sys.argv[1]}/sa/{sys.argv[2]}"
    if serial and expiry and expected in uris:
      print(f"{serial} {expiry}")
      raise SystemExit(0)
raise SystemExit("no serial/expiry in Envoy admin certificate response")
' "$zone" "$GATEWAY_SERVICE_ACCOUNT"
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
  if is_gateway_api_mode; then
    # Verify the entire current public chain and the actual generated
    # ServiceAccount URI before recording only serial/expiry metadata for the
    # renewal comparison. The verifier never prints or retains private keys.
    "$ROOT/scripts/verify-svids.sh" "$MODE" | tee "$STATE_DIR/svid-verify-before.txt" || return 1
  fi
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
  if is_gateway_api_mode; then
    "$ROOT/scripts/verify-svids.sh" "$MODE" | tee "$STATE_DIR/svid-verify-after.txt" || return 1
  fi
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
    if ! kubectl -n "$zone" get pod "$gateway_pod" -o json | MODE="$MODE" python3 -c '
import json,sys
p=json.load(sys.stdin)
s=p["spec"]
assert any(v.get("csi",{}).get("driver") == "csi.spiffe.io" for v in s.get("volumes", [])), s.get("volumes")
if __import__("os").environ.get("MODE") in ("istio", "istio-gateway-api"):
    # The custom gateway injection template intentionally replaces the
    # application container with one Envoy gateway proxy.  Checking the live
    # rendered Pod catches a silently skipped injection (which otherwise
    # leaves an image:auto container and fails much later as an image pull).
    containers=s.get("containers", [])
    assert len(containers) == 1 and containers[0].get("name") == "istio-proxy", containers
    assert any(m.get("mountPath") == "/run/secrets/workload-spiffe-uds" for m in containers[0].get("volumeMounts", [])), containers[0].get("volumeMounts")
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
  if is_gateway_api_mode; then
    kubectl get clusterspiffeid zone-gateway-api >/dev/null || return 1
    "$ROOT/scripts/check-gateway-api.sh" | tee "$STATE_DIR/gateway-api-structure.txt" || return 1
    "$ISTIOCTL" analyze --all-namespaces --failure-threshold Error --output json >"$STATE_DIR/istio-analyze.json" || return 1
  else
    kubectl get clusterspiffeid zone-gateway >/dev/null || return 1
  fi
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
      kubectl -n "$zone" get authorizationpolicy zone-trust-baseline >/dev/null || return 1
      kubectl -n "$zone" get authorizationpolicy zone-trust-generated >/dev/null || return 1
    done
    assert_istio_baseline || return 1
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
  # Establish the opposite value outside the sample set. Each of the 20 loop
  # mutations below then advances the ZoneTrust generation rather than timing a
  # no-op server-side apply of the value left by an earlier test.
  set_edge "$ZONE_A" "$ZONE_B" false >/dev/null || return 1
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" deny /e2e-timing-initial-deny || return 1
  for ((n=1; n<=TOGGLE_SAMPLES; n++)); do
    if (( n % 2 )); then allowed=true; else allowed=false; fi
    timing=$(set_edge "$ZONE_A" "$ZONE_B" "$allowed") || return 1
    read -r start accepted applied <<<"$timing" || return 1
    deadline=$((SECONDS + CONVERGENCE_TIMEOUT))
    while (( SECONDS < deadline )); do
      output=$(gateway_call "$ZONE_A" "$ZONE_B" /e2e-timing) || true
      if [[ "$allowed" == true ]] && is_successful_response "$output"; then observed=$(now_ms); break; fi
      if [[ "$allowed" == false ]] && is_forbidden_response "$output"; then observed=$(now_ms); break; fi
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
  # A previous run may have left an allow policy in a gateway's xDS stream.
  # The fixture objects are gone above, but do not begin the absent-edge case
  # until both data-plane directions have settled to the documented deny-all
  # baseline. This keeps repeated local/CI invocations independent.
  wait_for_gateway_decision "$ZONE_A" "$ZONE_B" deny /e2e-baseline-a-to-b
  wait_for_gateway_decision "$ZONE_B" "$ZONE_A" deny /e2e-baseline-b-to-a

  run_case 'default deny keeps destination counter unchanged' test_default_deny
  run_case 'allow A -> B reaches destination app' test_allow
  run_case 'structural invariants' test_structure
  if is_istio_mode; then
    run_case 'Istio policy create guard blocks baseline weakening' test_istio_create_guard
    run_case 'Istio dynamic policy deletion fails closed and controller recreates it' test_istio_dynamic_policy_recreation_fail_closed
  fi
  run_case 'deleting A -> B returns immediately to deny' test_deleted_edge_deny
  run_case 'directional trust permits A -> B but denies B -> A' test_directional
  run_case 'live deny and restore allow without workload restart' test_live_toggle
  run_case 'spoofed protected identity headers are removed before app' test_spoof_header
  run_case 'non-gateway workload cannot enter protected 8443' test_wrong_workload
  if is_gateway_api_mode; then
    run_case 'Gateway API protected listener rejects no-client-cert TLS with SPIRE CA validation' test_gateway_api_rejects_missing_client_certificate
  fi
  run_case 'NetworkPolicy blocks direct zone-a -> zone-b app bypass' test_direct_app_bypass
  run_case 'controller outage and recovery match backend failure semantics' test_controller_outage_and_recovery
  run_case 'gateway SVID refresh exposes new public metadata and recovers traffic' test_svid_rotation
  run_case "${TOGGLE_SAMPLES} toggle convergence timing samples" test_toggle_timings

  log "e2e result: pass=$PASS fail=$FAIL"
  log "evidence: $STATE_DIR"
  (( FAIL == 0 ))
}

main "$@"
