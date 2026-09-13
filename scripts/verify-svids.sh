#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
mode="${MODE:-${1:-}}"
case "$mode" in standalone|istio) ;; *) printf 'usage: %s standalone|istio\n' "$0" >&2; exit 2 ;; esac
export KUBECONFIG="${KUBECONFIG:-$repo_root/.state/$mode/kubeconfig}"
command -v kubectl >/dev/null || { printf 'missing required command: kubectl\n' >&2; exit 1; }
command -v curl >/dev/null || { printf 'missing required command: curl\n' >&2; exit 1; }

admin_port=9901
[[ "$mode" == istio ]] && admin_port=15000
pf_pid=""
cleanup() {
  [[ -n "$pf_pid" ]] || return 0
  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
  pf_pid=""
}
trap cleanup EXIT
for zone in zone-a zone-b; do
  pod="$(kubectl -n "$zone" get pod -l app.kubernetes.io/component=zone-gateway -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n "$zone" get pod "$pod" -o jsonpath='{.spec.volumes[?(@.csi.driver=="csi.spiffe.io")].name}' | grep -q workload-socket
  local_port="$(shuf -i 20000-40000 -n 1)"
  kubectl -n "$zone" port-forward "pod/$pod" "$local_port:$admin_port" >/dev/null 2>&1 &
  pf_pid=$!
  found=false
  for _ in $(seq 1 30); do
    if curl --silent --fail "http://127.0.0.1:$local_port/certs" | grep -Fq "spiffe://poc.example/ns/$zone/sa/zone-gateway"; then
      found=true
      break
    fi
    sleep 1
  done
  cleanup
  "$found" || {
    printf 'gateway in %s did not expose its expected SPIRE SVID through Envoy admin\n' "$zone" >&2
    exit 1
  }
  printf 'VERIFIED SPIFFE SVID zone=%s uri=spiffe://poc.example/ns/%s/sa/zone-gateway\n' "$zone" "$zone"
done
