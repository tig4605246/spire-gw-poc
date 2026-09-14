#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
export PATH="$repo_root/.tools/bin:$PATH"
mode="${MODE:-${1:-standalone}}"
case "$mode" in standalone|istio) ;; *) printf 'MODE must be standalone or istio\n' >&2; exit 2 ;; esac
cluster_name="spire-gw-$mode"
command -v kind >/dev/null || { printf 'missing required command: kind\n' >&2; exit 1; }
if kind get clusters | grep -Fxq "$cluster_name"; then
  kind delete cluster --name "$cluster_name"
fi
