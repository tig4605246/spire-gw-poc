#!/usr/bin/env bash
# Public-certificate verification helpers for scripts/verify-svids.sh.
# This file never reads, writes, or requests a workload private key.

verify_spiffe_gateway_leaf() {
  local bundle_file=$1 leaf_file=$2 intermediates_file=$3 expected_uri=$4 verification_time=${5:-$(date +%s)}
  local -a verify_args
  # The complete SPIRE bundle is the only trust store.  -partial_chain also
  # permits a SPIRE-published intermediate to be a trust anchor; it does not
  # consult the host trust store.
  verify_args=(-no-CAfile -no-CApath -no-CAstore -x509_strict -partial_chain -attime "$verification_time" -CAfile "$bundle_file")
  [[ -s "$intermediates_file" ]] && verify_args+=(-untrusted "$intermediates_file")

  # Check both TLS roles. Gateway SVIDs authenticate outbound mTLS clients and
  # terminate inbound mTLS servers, so either missing EKU is a failure.
  openssl verify "${verify_args[@]}" -purpose sslserver "$leaf_file" >/dev/null || return 1
  openssl verify "${verify_args[@]}" -purpose sslclient "$leaf_file" >/dev/null || return 1

  local uri_sans
  uri_sans="$(openssl x509 -in "$leaf_file" -noout -ext subjectAltName | grep -o 'URI:[^,[:space:]]*' | cut -c5-)"
  [[ "$(printf '%s\n' "$uri_sans" | sed '/^$/d' | wc -l)" -eq 1 ]] || return 1
  [[ "$uri_sans" == "$expected_uri" ]] || return 1

  # The extension checks remain explicit even though the purpose checks above
  # also validate EKU. They make the gateway's dual-role requirement auditable.
  openssl x509 -in "$leaf_file" -noout -ext basicConstraints | grep -Fq 'CA:FALSE' || return 1
  openssl x509 -in "$leaf_file" -noout -ext keyUsage | grep -Fq 'Digital Signature' || return 1
  local eku
  eku="$(openssl x509 -in "$leaf_file" -noout -ext extendedKeyUsage)" || return 1
  grep -Fq 'TLS Web Server Authentication' <<<"$eku" || return 1
  grep -Fq 'TLS Web Client Authentication' <<<"$eku" || return 1
}

extract_pem_certificates() {
  local input_file=$1 output_dir=$2
  awk -v output_dir="$output_dir" '
    /-----BEGIN CERTIFICATE-----/ { number++; output = output_dir "/chain-" number ".pem"; writing = 1 }
    writing { print > output }
    /-----END CERTIFICATE-----/ { close(output); writing = 0 }
  ' "$input_file"
  [[ -s "$output_dir/chain-1.pem" ]]
}

port_forward_local_port() {
  local port_forward_log=$1
  sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$port_forward_log" | head -n 1
}
