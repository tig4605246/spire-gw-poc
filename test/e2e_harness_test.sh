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
