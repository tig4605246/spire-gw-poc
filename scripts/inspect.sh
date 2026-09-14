#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MODE=${MODE:-standalone}
export KUBECONFIG=${KUBECONFIG:-"$ROOT/.state/$MODE/kubeconfig"}
kubectl get pods -A
kubectl get zonetrusts -o wide
"$ROOT/scripts/verify-svids.sh"
if [[ "$MODE" == istio ]]; then
  kubectl get authorizationpolicies.security.istio.io -A -o yaml
  "$ROOT/.tools/bin/istioctl" proxy-status
fi
