#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
mode="${MODE:-${1:-}}"
case "$mode" in standalone|istio) ;; *) printf 'usage: %s standalone|istio\n' "$0" >&2; exit 2 ;; esac
export KUBECONFIG="${KUBECONFIG:-$repo_root/.state/$mode/kubeconfig}"
for command in kubectl curl openssl python3; do
  command -v "$command" >/dev/null || { printf 'missing required command: %s\n' "$command" >&2; exit 1; }
done

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
  pod="$(kubectl -n "$zone" get pod -l app.kubernetes.io/component=zone-gateway,spiffe.io/spire-managed-identity=true -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n "$zone" get pod "$pod" -o jsonpath='{.spec.volumes[?(@.csi.driver=="csi.spiffe.io")].name}' | grep -q workload-socket
  local_port="$(shuf -i 20000-40000 -n 1)"
  kubectl -n "$zone" port-forward "pod/$pod" "$local_port:$admin_port" >/dev/null 2>&1 &
  pf_pid=$!
  found=false
  certs_json=""
  for _ in $(seq 1 30); do
    if certs_json="$(curl --silent --fail --max-time 3 "http://127.0.0.1:$local_port/certs" 2>/dev/null)" && printf '%s' "$certs_json" | grep -Fq "spiffe://poc.example/ns/$zone/sa/zone-gateway"; then
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
  # The URI SAN establishes workload identity, while issuer provenance comes
  # from a public CA serial match against the SPIRE Server bundle. This rejects
  # a same-URI certificate minted by an unrelated CA such as Istiod.
  envoy_ca_serials="$(printf '%s' "$certs_json" | python3 -c 'import json,sys; doc=json.load(sys.stdin); serials=sorted({format(int(str(cert["serial_number"]), 16), "x") for chain in doc.get("certificates", []) for cert in chain.get("ca_cert", []) if cert.get("serial_number")}); print("\n".join(serials))')"
  bundle_serial="$(kubectl -n spire-system exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server bundle show -format pem -socketPath /tmp/spire-server/private/api.sock | openssl x509 -noout -serial | cut -d= -f2 | python3 -c 'import sys; print(format(int(sys.stdin.read().strip(), 16), "x"))')"
  grep -Fqx "$bundle_serial" <<<"$envoy_ca_serials" || {
    printf 'gateway in %s did not chain to the SPIRE Server trust bundle\n' "$zone" >&2
    exit 1
  }
  printf 'VERIFIED SPIFFE SVID zone=%s uri=spiffe://poc.example/ns/%s/sa/zone-gateway issuer_ca_serial=%s\n' "$zone" "$zone" "$bundle_serial"
done
