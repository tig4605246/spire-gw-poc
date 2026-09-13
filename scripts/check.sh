#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
source versions.env
for script in scripts/*.sh; do bash -n "$script"; done
python3 test/manifests.py
if [[ ${SKIP_ENVOY_VALIDATION:-0} != 1 ]]; then
  for zone in zone-a zone-b; do
    ./scripts/render-envoy.sh --zone "$zone" --validate --output /dev/null
  done
fi
