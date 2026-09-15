#!/usr/bin/env bash
# Focused regression tests for the spoof-header convergence guard.  They load
# the production functions directly, then replace only network boundaries with
# deterministic mocks so no Kubernetes cluster is required.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Keep this extraction deliberately small: the test exercises the exact helper
# implementations in scripts/e2e.sh without executing its cluster setup.
# shellcheck disable=SC1090 # The source is intentionally generated from the target script.
source <(awk '
  /^request_code\(\)/ { emit=1 }
  /^edge_name\(\)/ { exit }
  emit { print }
' "$ROOT/scripts/e2e.sh")
# shellcheck disable=SC1090 # The source is intentionally generated from the target script.
source <(awk '
  /^wait_for_clean_spoof_allow\(\)/ { emit=1 }
  /^workload_fingerprint\(\)/ { exit }
  emit { print }
' "$ROOT/scripts/e2e.sh")

# shellcheck disable=SC2034 # Consumed by the sourced production helper.
CONVERGENCE_TIMEOUT=1
# shellcheck disable=SC2034 # Consumed by the sourced production helper.
DECISION_STABLE_INTERVAL=0
log() { :; }
fail() { return 1; }
sleep() { :; }

gateway_call() {
  local calls
  calls=$(<"$TEMP_DIR/gateway-calls")
  calls=$((calls + 1))
  printf '%s' "$calls" >"$TEMP_DIR/gateway-calls"
  if [[ "$calls" == 1 ]]; then
    printf 'RBAC: access denied\n403\n'
    return
  fi
  case "$MOCK_SCENARIO" in
    clean|counter-change) printf '{"headers":{"Accept":["*/*"]}}\n200\n' ;;
    leaked-header) printf '{"headers":{"X-SPIFFE-Peer-ID":["forged"]}}\n200\n' ;;
    *) return 2 ;;
  esac
}

app_requests() {
  local reads
  reads=$(<"$TEMP_DIR/app-reads")
  reads=$((reads + 1))
  printf '%s' "$reads" >"$TEMP_DIR/app-reads"
  if [[ "$MOCK_SCENARIO" == counter-change && "$reads" -gt 1 ]]; then
    printf '11\n'
  else
    printf '10\n'
  fi
}

run_scenario() {
  local scenario=$1 expected_status=$2 calls
  MOCK_SCENARIO=$scenario
  printf '0' >"$TEMP_DIR/gateway-calls"
  printf '0' >"$TEMP_DIR/app-reads"
  if wait_for_clean_spoof_allow zone-a zone-b /e2e-spoof -H 'x-spiffe-peer-id: forged' >"$TEMP_DIR/$scenario.log" 2>&1; then
    [[ "$expected_status" == pass ]] || return 1
  else
    [[ "$expected_status" == fail ]] || return 1
  fi
  calls=$(<"$TEMP_DIR/gateway-calls")
  case "$scenario" in
    clean) [[ "$calls" == 2 ]] ;;
    # A 200 response containing a protected header must fail immediately; do
    # not hide that leak by attempting a later clean request.
    leaked-header) [[ "$calls" == 2 ]] ;;
    # A failed probe that changes the destination counter must fail before the
    # helper issues its second (clean) mocked request.
    counter-change) [[ "$calls" == 1 ]] ;;
  esac
}

run_scenario clean pass
run_scenario leaked-header fail
run_scenario counter-change fail
printf 'e2e spoof convergence helper regression tests passed\n'

# shellcheck disable=SC1090 # Load only the two active-listener helpers.
source <(awk '
  /^wait_istio_active_listener_without_dynamic_policy\(\)/ { emit=1 }
  /^pause_controller\(\)/ { exit }
  emit { print }
' "$ROOT/scripts/e2e.sh")
# shellcheck disable=SC2034 # Consumed by the sourced production helpers.
ZONE_B=zone-b
# shellcheck disable=SC2034 # Consumed by the sourced production helpers.
ISTIOCTL=mock_istioctl
kubectl() { printf 'gateway-pod\n'; }
mock_istioctl() { printf '%s\n' "$MOCK_LISTENER"; }

MOCK_LISTENER='[{"name":"0.0.0.0_8443","policies":{}}]'
wait_istio_active_listener_without_dynamic_policy
if wait_istio_active_listener_with_dynamic_deny_all; then
  printf 'missing policy was mistaken for a recreated deny-all policy\n' >&2
  exit 1
fi

MOCK_LISTENER='[{"name":"0.0.0.0_8443","policies":{"ns[zone-b]-policy[zone-trust-generated]-rule[0]":{"permissions":[{"notRule":{"any":true}}],"principals":[{"notId":{"any":true}}]}}}]'
wait_istio_active_listener_with_dynamic_deny_all
if wait_istio_active_listener_without_dynamic_policy; then
  printf 'recreated deny-all policy was mistaken for a missing policy\n' >&2
  exit 1
fi

MOCK_LISTENER='[{"name":"0.0.0.0_8443","policies":{"ns[zone-b]-policy[zone-trust-generated]-rule[0]":{"permissions":[{"any":true}],"principals":[{"any":true}]}}}]'
if wait_istio_active_listener_with_dynamic_deny_all; then
  printf 'permissive generated policy was mistaken for deny-all\n' >&2
  exit 1
fi
printf 'e2e missing versus recreated deny-all listener regression tests passed\n'

# Scheme C must bind the Gateway API object, not the generated Deployment
# selector, and it must use the generated ServiceAccount in its principal.
# Exercise those production helpers with JSON-only kubectl mocks; this catches
# a future regression without requiring a cluster or generated Gateway Pod.
# shellcheck disable=SC2034 # Consumed by the sourced dynamic-policy helper.
ZONE_A=zone-a
# shellcheck disable=SC2034 # Retained to model normal harness context.
ZONE_B=zone-b
# shellcheck disable=SC1090 # Load the exact targetRef/principal helpers.
source <(awk '
  /^assert_istio_baseline\(\)/ { emit=1 }
  /^wait_istio_active_listener_without_dynamic_policy\(\)/ { exit }
  emit { print }
' "$ROOT/scripts/e2e.sh")
MODE=istio-gateway-api
GATEWAY_API_NAME=zone-gateway
GATEWAY_SERVICE_ACCOUNT=zone-gateway-istio
CONVERGENCE_TIMEOUT=1
MOCK_GATEWAY_API_POLICY=valid
kubectl() {
  case "$*" in
    *zone-trust-baseline*)
      if [[ "$MOCK_GATEWAY_API_POLICY" == valid ]]; then
        printf '%s\n' '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"zone-trust-bootstrap"}},"spec":{"targetRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"zone-gateway"}],"rules":[{"to":[{"operation":{"ports":["8080"]}}]}]}}'
      else
        printf '%s\n' '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"zone-trust-bootstrap"}},"spec":{"selector":{"matchLabels":{"app.kubernetes.io/component":"zone-gateway"}},"rules":[{"to":[{"operation":{"ports":["8080"]}}]}]}}'
      fi
      ;;
    *zone-trust-generated*)
      printf '%s\n' '{"spec":{"targetRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"zone-gateway"}],"rules":[{"from":[{"source":{"principals":["poc.example/ns/zone-a/sa/zone-gateway-istio"]}}],"to":[{"operation":{"ports":["8443"]}}]}]}}'
      ;;
    *) printf 'unexpected kubectl mock call: %s\n' "$*" >&2; return 1 ;;
  esac
}
assert_istio_baseline
wait_dynamic_policy_allows_a_to_b
MOCK_GATEWAY_API_POLICY=selector
if assert_istio_baseline 2>"$TEMP_DIR/gateway-api-selector-rejection.log"; then
  printf 'Gateway API baseline selector was accepted instead of targetRefs\n' >&2
  exit 1
fi
printf 'e2e Gateway API targetRef and generated-principal regression tests passed\n'

# The TLS negative test is only meaningful when the server chain is validated
# against SPIRE's public bundle and the server has time to send its TLS 1.3
# CertificateRequired alert.  Source the production helper and mock its I/O
# boundary so this remains a fast regression test without certificate material.
# shellcheck disable=SC1090 # Load only the production Gateway API TLS helper.
source <(awk '
  /^test_gateway_api_rejects_missing_client_certificate\(\)/ { emit=1 }
  /^test_direct_app_bypass\(\)/ { exit }
  emit { print }
' "$ROOT/scripts/e2e.sh")
MODE=istio-gateway-api
ZONE_B=zone-b
GATEWAY_SERVICE=zone-gateway-istio
is_gateway_api_mode() { return 0; }
mktemp() { printf '%s/no-client-cert-public-ca.pem\n' "$TEMP_DIR"; }
kubectl() {
  case "$*" in
    *'bundle show -format pem'*) printf '%s\n' 'PUBLIC-SPIRE-BUNDLE-ONLY' ;;
    *'get pod'*) printf '%s\n' 'gateway-pod' ;;
    *) printf 'unexpected Gateway API TLS kubectl mock call: %s\n' "$*" >&2; return 1 ;;
  esac
}
start_port_forward() {
  local result_var=$1
  printf -v "$result_var" '%s' 9443
}
timeout() {
  local timeout_value=$1 executable=$2
  shift 2
  [[ "$timeout_value" == 15s && "$executable" == openssl ]] || return 1
  printf '%s\n' "$@" >"$TEMP_DIR/no-client-cert-openssl-args"
  printf '%b\n' "$MOCK_TLS_TRANSCRIPT"
}
fail() { return 1; }

run_no_client_certificate_scenario() {
  local scenario=$1 expected=$2
  case "$scenario" in
    valid-no-alert) MOCK_TLS_TRANSCRIPT='Verify return code: 0 (ok)\nDONE' ;;
    untrusted-with-alert) MOCK_TLS_TRANSCRIPT='verify error:num=20\ntlsv13 alert certificate required' ;;
    valid-with-alert) MOCK_TLS_TRANSCRIPT='Verify return code: 0 (ok)\ntlsv13 alert certificate required' ;;
    *) return 2 ;;
  esac
  if test_gateway_api_rejects_missing_client_certificate >"$TEMP_DIR/no-client-cert-$scenario.log" 2>&1; then
    [[ "$expected" == pass ]] || return 1
  else
    [[ "$expected" == fail ]] || return 1
  fi
}

run_no_client_certificate_scenario valid-no-alert fail
run_no_client_certificate_scenario untrusted-with-alert fail
run_no_client_certificate_scenario valid-with-alert pass
for argument in -ign_eof -verify_return_error -no-CApath -no-CAstore; do
  grep -Fxq -- "$argument" "$TEMP_DIR/no-client-cert-openssl-args" || {
    printf 'Gateway API TLS probe omitted required OpenSSL argument: %s\n' "$argument" >&2
    exit 1
  }
done
printf 'e2e Gateway API no-client-certificate TLS regression tests passed\n'
