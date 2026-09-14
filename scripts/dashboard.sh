#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MODE=${MODE:-standalone}
export KUBECONFIG=${KUBECONFIG:-"$ROOT/.state/$MODE/kubeconfig"}
printf 'Dashboard: http://127.0.0.1:8080 (Ctrl-C to stop)\n'
exec kubectl -n control-plane port-forward --address 127.0.0.1 service/zone-trust-controller 8080:8080
