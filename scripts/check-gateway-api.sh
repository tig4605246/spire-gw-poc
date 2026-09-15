#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export KUBECONFIG=${KUBECONFIG:-"$ROOT/.state/istio-gateway-api/kubeconfig"}
deadline=$((SECONDS + ${GATEWAY_API_TIMEOUT_SECONDS:-300}))
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
while (( SECONDS < deadline )); do
  if kubectl get gateways.gateway.networking.k8s.io,httproutes.gateway.networking.k8s.io,deployments,pods,services,serviceaccounts,destinationrules.networking.istio.io -A -o json >"$check_dir/resources.json" 2>"$check_dir/error" &&
    python3 "$ROOT/scripts/lib/check-gateway-api.py" <"$check_dir/resources.json" >"$check_dir/result" 2>"$check_dir/error"; then
    cat "$check_dir/result"
    exit 0
  fi
  sleep 2
done
printf 'Gateway API readiness or generated identity check failed:\n' >&2
cat "$check_dir/error" >&2
kubectl get gateways.gateway.networking.k8s.io,httproutes.gateway.networking.k8s.io -A -o yaml >&2 || true
kubectl get pods -A -o wide >&2 || true
kubectl get events -A --sort-by=.lastTimestamp >&2 || true
# Accepted=True is set by a different controller from automatic deployment.
# Include its leadership and logs when no generated workload appears.
kubectl -n istio-system get leases -o wide >&2 || true
kubectl -n istio-system logs deployment/istiod --tail=300 >&2 || true
exit 1
