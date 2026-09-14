#!/usr/bin/env bash
# These fixtures use ephemeral synthetic test keys only. They are unrelated to
# POC gateway identities and are removed with the temporary directory.
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/scripts/lib/verify-svid-chain.sh"

for command in openssl awk grep sed wc date cp cat mkdir cmp; do
  command -v "$command" >/dev/null || { printf 'missing test command: %s\n' "$command" >&2; exit 1; }
done

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/spire-gw-svid-chain.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
expected_uri='spiffe://poc.example/ns/zone-a/sa/zone-gateway'

make_ca() {
  local name=$1
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7 \
    -subj "/CN=$name" \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -addext 'subjectKeyIdentifier=hash' \
    -keyout "$temp_dir/$name.key" -out "$temp_dir/$name.pem" >/dev/null 2>&1
}

make_leaf() {
  local name=$1 uri=$2 signer=$3 days=$4 eku=${5:-clientAuth,serverAuth} key_usage=${6:-digitalSignature}
  openssl req -newkey rsa:2048 -nodes -sha256 -subj "/CN=$name" \
    -keyout "$temp_dir/$name.key" -out "$temp_dir/$name.csr" >/dev/null 2>&1
  cat >"$temp_dir/$name.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,$key_usage
extendedKeyUsage=$eku
subjectAltName=URI:$uri
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
  openssl x509 -req -in "$temp_dir/$name.csr" -CA "$temp_dir/$signer.pem" -CAkey "$temp_dir/$signer.key" \
    -CAcreateserial -days "$days" -sha256 -extfile "$temp_dir/$name.ext" -out "$temp_dir/$name.pem" >/dev/null 2>&1
}

make_ca spire-root
make_ca unrelated-root
make_leaf valid "$expected_uri" spire-root 1
make_leaf unrelated-same-uri "$expected_uri" unrelated-root 1
make_leaf wrong-uri 'spiffe://poc.example/ns/zone-b/sa/zone-gateway' spire-root 1
# A double slash leaves the namespace component empty, so this is not a valid
# gateway SPIFFE identity despite being accepted as a generic URI SAN by X.509.
make_leaf malformed-uri 'spiffe://poc.example/ns//sa/zone-gateway' spire-root 1
make_leaf server-only "$expected_uri" spire-root 1 serverAuth
make_leaf wrong-key-usage "$expected_uri" spire-root 1 clientAuth,serverAuth keyEncipherment
: >"$temp_dir/intermediates.pem"
now="$(date +%s)"

printf 'Forwarding from 127.0.0.1:31234 -> 8443\n' >"$temp_dir/port-forward.log"
[[ "$(port_forward_local_port "$temp_dir/port-forward.log")" == 31234 ]]

must_fail() {
  local case_name=$1
  shift
  if "$@" >"$temp_dir/$case_name.stdout" 2>"$temp_dir/$case_name.stderr"; then
    printf 'expected verifier rejection for %s\n' "$case_name" >&2
    return 1
  fi
}

# Simulate an Envoy admin /certs view which includes the SPIRE root beside an
# unrelated leaf.  The old serial-union check accepted this arrangement.  The
# helper deliberately receives the served leaf/chain and the SPIRE bundle only.
cp "$temp_dir/unrelated-same-uri.pem" "$temp_dir/presented-chain.pem"
cat "$temp_dir/unrelated-root.pem" "$temp_dir/spire-root.pem" >>"$temp_dir/presented-chain.pem"
mkdir "$temp_dir/extracted"
extract_pem_certificates "$temp_dir/presented-chain.pem" "$temp_dir/extracted"
openssl x509 -in "$temp_dir/extracted/chain-1.pem" -noout -fingerprint -sha256 | cmp -s - <(openssl x509 -in "$temp_dir/unrelated-same-uri.pem" -noout -fingerprint -sha256)
[[ -s "$temp_dir/extracted/chain-2.pem" && -s "$temp_dir/extracted/chain-3.pem" ]]
cat "$temp_dir/extracted/chain-2.pem" "$temp_dir/extracted/chain-3.pem" >"$temp_dir/presented-intermediates.pem"

verify_spiffe_gateway_leaf "$temp_dir/spire-root.pem" "$temp_dir/valid.pem" "$temp_dir/intermediates.pem" "$expected_uri" "$now"
must_fail unrelated-issuer verify_spiffe_gateway_leaf "$temp_dir/spire-root.pem" "$temp_dir/unrelated-same-uri.pem" "$temp_dir/intermediates.pem" "$expected_uri" "$now"
must_fail wrong-uri verify_spiffe_gateway_leaf "$temp_dir/spire-root.pem" "$temp_dir/wrong-uri.pem" "$temp_dir/intermediates.pem" "$expected_uri" "$now"
must_fail malformed-uri verify_spiffe_gateway_leaf "$temp_dir/spire-root.pem" "$temp_dir/malformed-uri.pem" "$temp_dir/intermediates.pem" "$expected_uri" "$now"
must_fail missing-client-eku verify_spiffe_gateway_leaf "$temp_dir/spire-root.pem" "$temp_dir/server-only.pem" "$temp_dir/intermediates.pem" "$expected_uri" "$now"
must_fail missing-digital-signature verify_spiffe_gateway_leaf "$temp_dir/spire-root.pem" "$temp_dir/wrong-key-usage.pem" "$temp_dir/intermediates.pem" "$expected_uri" "$now"
# Even though a SPIRE root is also present in the synthetic context above, an
# expected-URI leaf issued by another CA must not establish SPIRE provenance.
must_fail serial-union-regression verify_spiffe_gateway_leaf "$temp_dir/spire-root.pem" "$temp_dir/extracted/chain-1.pem" "$temp_dir/presented-intermediates.pem" "$expected_uri" "$now"
# The leaf is valid when issued but must fail when verification is evaluated
# beyond its short lifetime, proving the verifier does not disable time checks.
must_fail expired verify_spiffe_gateway_leaf "$temp_dir/spire-root.pem" "$temp_dir/valid.pem" "$temp_dir/intermediates.pem" "$expected_uri" "$((now + 172800))"

printf 'PASS verify_svid_chain: valid SPIRE leaf accepted; unrelated issuer, URI, KU/EKU, and time failures rejected\n'
