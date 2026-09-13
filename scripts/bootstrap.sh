#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/versions.env"
if [[ ! -x "$repo_root/.tools/bin/kind" || ! -x "$repo_root/.tools/bin/helm" || ! -x "$repo_root/.tools/bin/istioctl" ]]; then
  "$repo_root/scripts/tools.sh"
fi
export PATH="$repo_root/.tools/bin:$PATH"

mode="${MODE:-${1:-}}"
case "$mode" in standalone|istio) ;; *) printf 'MODE must be standalone or istio\n' >&2; exit 2 ;; esac
state_dir="$repo_root/.state/$mode"
requested_kubeconfig="${KUBECONFIG:-}"
mkdir -p "$state_dir"
# A bootstrap can take several minutes. Serialize same-mode invocations so a
# second terminal cannot race Helm upgrades or duplicate image loading.
exec 9>"$state_dir/bootstrap.lock"
flock -n 9 || { printf 'bootstrap for %s is already running\n' "$mode" >&2; exit 1; }
# Never mutate a caller's current context. All kind and kubectl operations use
# the mode-scoped file, which also makes standalone and Istio clusters coexist.
export KUBECONFIG="$state_dir/kubeconfig"
cluster_name="spire-gw-$mode"

require() { command -v "$1" >/dev/null || { printf 'missing required command: %s\n' "$1" >&2; exit 1; }; }
require docker; require kubectl; require kind; require helm; require curl

kind_config="$state_dir/kind.yaml"
cat >"$kind_config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $cluster_name
nodes:
  - role: control-plane
  - role: worker
    labels:
      security.poc.example/gateway-zone: zone-a
  - role: worker
    labels:
      security.poc.example/gateway-zone: zone-b
networking:
  disableDefaultCNI: true
EOF
if ! kind get clusters | grep -Fxq "$cluster_name"; then
  kind create cluster --name "$cluster_name" --image "$KIND_NODE_IMAGE" --config "$kind_config" --kubeconfig "$KUBECONFIG"
else
  kind export kubeconfig --name "$cluster_name" --kubeconfig "$KUBECONFIG"
fi
expected_context="kind-$cluster_name"
[[ "$(kubectl config current-context)" == "$expected_context" ]] || {
  printf 'refusing to mutate unexpected Kubernetes context (wanted %s)\n' "$expected_context" >&2
  exit 1
}
# An explicit KUBECONFIG is honored only after the dedicated file has created
# and identified the mode's kind cluster. Exporting the same cluster context
# to it cannot redirect later mutations to an unrelated cluster.
if [[ -n "$requested_kubeconfig" && "$requested_kubeconfig" != "$KUBECONFIG" ]]; then
  kind export kubeconfig --name "$cluster_name" --kubeconfig "$requested_kubeconfig"
  export KUBECONFIG="$requested_kubeconfig"
  [[ "$(kubectl config current-context)" == "$expected_context" ]] || {
    printf 'explicit KUBECONFIG did not select expected context %s\n' "$expected_context" >&2
    exit 1
  }
fi

helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/ >/dev/null 2>&1 || true
helm repo update >/dev/null

# kindnet does not enforce NetworkPolicy. Cilium is installed before any zone
# workloads so the direct-app isolation test exercises a real policy engine.
helm upgrade --install cilium cilium/cilium --namespace kube-system --version "$CILIUM_VERSION" \
  --set operator.replicas=1
kubectl -n kube-system rollout status daemonset/cilium --timeout=5m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
kubectl wait --for=condition=Ready node --all --timeout=5m

spire_rendered="$state_dir/spire-rendered.yaml"
helm template spire spiffe/spire --namespace spire-system --version "$SPIRE_CHART_VERSION" \
  -f "$repo_root/config/spire/values.yaml" >"$spire_rendered"
for required in '"default_svid_name": "default"' '"default_bundle_name": ""' '"default_all_bundles_name": "ROOTCA"' 'k8s_psat' 'ln -s spire-agent.sock socket'; do
  rg -Fq "$required" "$spire_rendered" || { printf 'SPIRE chart render did not contain required setting: %s\n' "$required" >&2; exit 1; }
done
# CRDs must exist before the umbrella chart, but the CRD chart must not own
# spire-system: the umbrella chart creates and owns that namespace itself.
helm template spire-crds spiffe/spire-crds --version "$SPIRE_CRDS_CHART_VERSION" >"$state_dir/spire-crds-rendered.yaml"
kubectl apply -f "$state_dir/spire-crds-rendered.yaml"
# Helm needs its release namespace to exist before an install. The umbrella
# chart also renders that Namespace, so establish the matching ownership
# metadata first rather than using --create-namespace (which creates an
# unowned Namespace and makes Helm reject the chart's object).
kubectl create namespace spire-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace spire-system app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate namespace spire-system meta.helm.sh/release-name=spire meta.helm.sh/release-namespace=spire-system --overwrite
kubectl apply -f "$repo_root/config/common/namespaces.yaml"
helm upgrade --install spire spiffe/spire --namespace spire-system \
  --version "$SPIRE_CHART_VERSION" -f "$repo_root/config/spire/values.yaml"
kubectl -n spire-system rollout status statefulset/spire-server --timeout=5m
kubectl -n spire-system rollout status daemonset/spire-agent --timeout=5m
kubectl -n spire-system rollout status daemonset/spire-spiffe-csi-driver --timeout=5m
kubectl -n spire-system wait --for=condition=Ready pod/spire-server-0 --timeout=5m

kubectl apply -f "$repo_root/config/spire/gateway-clusterspiffeid.yaml"
if [[ -d "$repo_root/config/crd" ]]; then
  kubectl apply -f "$repo_root/config/crd"
fi

docker build --build-arg GO_VERSION="$GO_VERSION" --build-arg BASE_IMAGE="$DISTROLESS_IMAGE" \
  --build-arg COMMAND=zone-trust-controller -t "$CONTROLLER_IMAGE" "$repo_root"
docker build --build-arg GO_VERSION="$GO_VERSION" --build-arg BASE_IMAGE="$DISTROLESS_IMAGE" \
  --build-arg COMMAND=echo-app -t "$APP_IMAGE" "$repo_root"
kind load docker-image --name "$cluster_name" "$CONTROLLER_IMAGE" "$APP_IMAGE"

if [[ "$mode" == standalone ]]; then
  "$repo_root/scripts/render-envoy.sh" --zone zone-a --configmap --output "$state_dir/zone-a-envoy.yaml" --validate
  "$repo_root/scripts/render-envoy.sh" --zone zone-b --configmap --output "$state_dir/zone-b-envoy.yaml" --validate
  kubectl apply -f "$state_dir/zone-a-envoy.yaml" -f "$state_dir/zone-b-envoy.yaml"
else
  istioctl="${ISTIOCTL:-$repo_root/.tools/bin/istioctl}"
  [[ -x "$istioctl" ]] || { printf 'istioctl %s is missing; run make tools first\n' "$istioctl" >&2; exit 1; }
  "$istioctl" install -y -f "$repo_root/config/istio/istio-operator.yaml"
  kubectl -n istio-system rollout status deployment/istiod --timeout=5m
  # Establish deny-by-default policy before any Istio gateway is created.
  kubectl apply -f "$repo_root/config/istio/default-authorization-policies.yaml"
fi

kubectl apply -k "$repo_root/config/rbac"
kubectl apply -k "$repo_root/config/controller"
kubectl -n control-plane rollout status deployment/zone-trust-controller --timeout=5m
# Apply the public overlay after the controller has become ready. The Istio
# overlay carries the backend environment patch; its default AuthorizationPolicy
# was applied before any gateway workload above.
kubectl apply -k "$repo_root/deploy/$mode"
kubectl -n control-plane rollout status deployment/zone-trust-controller --timeout=5m
kubectl -n zone-a rollout status deployment/zone-app --timeout=5m
kubectl -n zone-b rollout status deployment/zone-app --timeout=5m
kubectl -n zone-a rollout status deployment/zone-gateway --timeout=5m
kubectl -n zone-b rollout status deployment/zone-gateway --timeout=5m
"$repo_root/scripts/verify-svids.sh" "$mode"
