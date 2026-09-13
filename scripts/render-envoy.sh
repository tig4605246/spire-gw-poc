#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/versions.env"

zone=""
output=""
as_configmap=false
validate=false
usage() {
  printf 'usage: %s --zone zone-a|zone-b [--configmap] [--output FILE] [--validate]\n' "$0" >&2
}
while (($#)); do
  case "$1" in
    --zone) zone="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --configmap) as_configmap=true; shift ;;
    --validate) validate=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
case "$zone" in
  zone-a) peer_zone=zone-b ;;
  zone-b) peer_zone=zone-a ;;
  *) usage; exit 2 ;;
esac

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
sed -e "s/__ZONE__/$zone/g" -e "s/__PEER_ZONE__/$peer_zone/g" \
  "$repo_root/config/standalone/envoy-bootstrap-template.yaml" >"$rendered"
# The upstream Envoy image runs as an unprivileged user and needs to read the
# temporary bind mount during --validate.
chmod 0644 "$rendered"

if "$validate"; then
  command -v docker >/dev/null || { printf 'docker is required for Envoy validation\n' >&2; exit 1; }
  docker run --rm --network none \
    -v "$rendered:/etc/envoy/envoy.yaml:ro" \
    "envoyproxy/envoy:${ENVOY_VERSION}" --mode validate -c /etc/envoy/envoy.yaml
fi

if "$as_configmap"; then
  target="${output:-/dev/stdout}"
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s-envoy-bootstrap\n  namespace: %s\ndata:\n  envoy.yaml: |\n' "$zone" "$zone"
    sed 's/^/    /' "$rendered"
  } >"$target"
else
  cat "$rendered" >"${output:-/dev/stdout}"
fi
