#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MODE=${MODE:-standalone}
export KUBECONFIG=${KUBECONFIG:-"$ROOT/.state/$MODE/kubeconfig"}
kubectl get pods -A
kubectl get zonetrusts -o wide
"$ROOT/scripts/verify-svids.sh" "$MODE"
if [[ "$MODE" == istio || "$MODE" == istio-gateway-api ]]; then
  kubectl get authorizationpolicies.security.istio.io -A -o yaml
  "$ROOT/.tools/bin/istioctl" proxy-status
fi
if [[ "$MODE" == istio-gateway-api ]]; then
  "$ROOT/scripts/check-gateway-api.sh"
  kubectl get gateways.gateway.networking.k8s.io,httproutes.gateway.networking.k8s.io,referencegrants.gateway.networking.k8s.io -A
fi
