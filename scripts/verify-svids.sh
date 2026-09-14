#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/lib/verify-svid-chain.sh"
mode="${MODE:-${1:-}}"
case "$mode" in standalone|istio) ;; *) printf 'usage: %s standalone|istio\n' "$0" >&2; exit 2 ;; esac
export KUBECONFIG="${KUBECONFIG:-$repo_root/.state/$mode/kubeconfig}"
for command in kubectl openssl awk grep sed mktemp cat timeout seq sleep tr head mkdir cut rm date wc; do
  command -v "$command" >/dev/null || { printf 'missing required command: %s\n' "$command" >&2; exit 1; }
done

pf_pid=""
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/spire-gw-svid-verify.XXXXXX")"
cleanup() {
  if [[ -n "$pf_pid" ]]; then
    kill "$pf_pid" >/dev/null 2>&1 || true
    wait "$pf_pid" 2>/dev/null || true
    pf_pid=""
  fi
}
cleanup_all() {
  cleanup
  rm -rf "$temp_dir"
}
trap cleanup_all EXIT

bundle_file="$temp_dir/spire-bundle.pem"
# The SPIRE Server bundle is public material.  It is the only configured
# verifier trust store; no host CA file/path/store can influence this check.
kubectl -n spire-system exec spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server bundle show -format pem \
  -socketPath /tmp/spire-server/private/api.sock >"$bundle_file"
openssl crl2pkcs7 -nocrl -certfile "$bundle_file" | openssl pkcs7 -print_certs -noout >/dev/null

for zone in zone-a zone-b; do
  pod="$(kubectl -n "$zone" get pod -l app.kubernetes.io/component=zone-gateway,spiffe.io/spire-managed-identity=true -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$pod" ]] || { printf 'no managed zone gateway pod found in %s\n' "$zone" >&2; exit 1; }
  kubectl -n "$zone" get pod "$pod" -o jsonpath='{.spec.volumes[?(@.csi.driver=="csi.spiffe.io")].name}' | grep -q workload-socket

  pf_log="$temp_dir/$zone-port-forward.log"
  # Ask kubectl to allocate a local port.  This avoids a race with unrelated
  # local processes and confines the public TLS capture to loopback.
  kubectl -n "$zone" port-forward --address 127.0.0.1 "pod/$pod" 0:8443 >"$pf_log" 2>&1 &
  pf_pid=$!
  local_port=""
  for _ in $(seq 1 30); do
    local_port="$(port_forward_local_port "$pf_log")"
    if [[ -n "$local_port" ]]; then
      break
    fi
    if ! kill -0 "$pf_pid" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  [[ -n "$local_port" ]] || {
    printf 'could not create a TLS port-forward for gateway in %s: %s\n' "$zone" "$(tr '\n' ' ' <"$pf_log")" >&2
    exit 1
  }

  # Envoy sends its public certificate chain before rejecting an unauthenticated
  # client.  A non-zero s_client status is therefore expected for this mTLS
  # listener; absence of a parseable served chain is never accepted.
  served_certificates="$temp_dir/$zone-served-certificates.pem"
  for _ in $(seq 1 3); do
    timeout 10s openssl s_client -showcerts -connect "127.0.0.1:$local_port" \
      -servername "zone-gateway.$zone.svc.cluster.local" </dev/null 2>"$temp_dir/$zone-s-client.err" | \
      awk '
        /-----BEGIN CERTIFICATE-----/ { writing = 1 }
        writing { print }
        /-----END CERTIFICATE-----/ { writing = 0 }
      ' >"$served_certificates" || true
    grep -Fq -- '-----BEGIN CERTIFICATE-----' "$served_certificates" && break
    sleep 1
  done
  cleanup

  chain_dir="$temp_dir/$zone-chain"
  mkdir "$chain_dir"
  extract_pem_certificates "$served_certificates" "$chain_dir" || {
    printf 'gateway in %s did not present a parseable public TLS certificate chain\n' "$zone" >&2
    exit 1
  }
  intermediates_file="$temp_dir/$zone-intermediates.pem"
  : >"$intermediates_file"
  chain_index=2
  while [[ -s "$chain_dir/chain-$chain_index.pem" ]]; do
    cat "$chain_dir/chain-$chain_index.pem" >>"$intermediates_file"
    ((chain_index += 1))
  done

  expected_uri="spiffe://poc.example/ns/$zone/sa/zone-gateway"
  verify_spiffe_gateway_leaf "$bundle_file" "$chain_dir/chain-1.pem" "$intermediates_file" "$expected_uri"
  leaf_serial="$(openssl x509 -in "$chain_dir/chain-1.pem" -noout -serial | cut -d= -f2)"
  not_after="$(openssl x509 -in "$chain_dir/chain-1.pem" -noout -enddate | cut -d= -f2-)"
  printf 'VERIFIED SPIFFE SVID zone=%s uri=%s leaf_serial=%s not_after=%s\n' "$zone" "$expected_uri" "$leaf_serial" "$not_after"
done
