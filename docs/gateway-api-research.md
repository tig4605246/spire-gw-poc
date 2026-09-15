# Gateway API research for mode `istio-gateway-api`

This note records the implementation facts verified on 2026-09-15. It uses
Istio `1.31.0` and Gateway API `v1.6.0` sources. It does not describe a
general Gateway API deployment.

## Versioned installation

Istio 1.31's Gateway API task installs the standard Gateway API CRDs from the
Gateway API `v1.6.0` release. Pin that release URL in `versions.env` and apply
it before creating `Gateway` resources. The `v1.6.0` standard
`ReferenceGrant` CRD serves both `v1` and `v1beta1`; `v1beta1` is its storage
version. The Issue's `gateway.networking.k8s.io/v1beta1` ReferenceGrant is
therefore available from this pinned bundle.

Sources: [Istio 1.31 Gateway API task](https://istio.io/v1.31/docs/tasks/traffic-management/ingress/gateway-api/), [Gateway API v1.6.0 ReferenceGrant CRD](https://github.com/kubernetes-sigs/gateway-api/blob/v1.6.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml).

## Istio automated gateway deployment

For `gatewayClassName: istio`, Istio automatically creates a Deployment,
Service, and ServiceAccount. The documented name form is
`<Gateway name>-<GatewayClass name>`, so a Gateway called `zone-gateway`
uses `zone-gateway-istio`. The generated pod carries
`gateway.networking.k8s.io/gateway-name: <Gateway name>`. Bootstrap must read
the generated Deployment's `spec.template.spec.serviceAccountName` before it
creates a SPIRE expectation. The resource naming convention is useful for
diagnostics but is not a replacement for that check.

`spec.infrastructure.parametersRef` may reference only a ConfigMap in the
Gateway's own namespace. Its data values are strategic-merge overlays. In
Istio 1.31 the permitted keys are `deployment`, `service`, `serviceAccount`,
`horizontalPodAutoscaler`, and `podDisruptionBudget`. Gateway-level overlays
apply after a GatewayClass default overlay.

Sources: [Istio 1.31 task: automated deployment](https://istio.io/v1.31/docs/tasks/traffic-management/ingress/gateway-api/#automated-deployment), [Istio 1.31 deployment controller](https://github.com/istio/istio/blob/1.31.0/pilot/pkg/config/kube/gatewaycommon/deploymentcontroller.go#L609-L769).

### Required CSI overlay shape

An automated gateway already has an `istio-proxy` container. Its generated pod
sets `sidecar.istio.io/inject: "false"`, so an `inject.istio.io/templates`
annotation does not run the existing `gateway,spire` injector templates. Do
not add another proxy container or depend on injection for the CSI mount.

The generated template contains an `emptyDir` volume named `workload-socket`
and a mount at `/var/run/secrets/workload-spiffe-uds`. The SPIRE integration
sample changes the volume to use the CSI driver, changes the mount to
`/run/secrets/workload-spiffe-uds`, and adds an init container that waits for
`socket`. An automated Gateway must make the same changes through its
`deployment` overlay.

Kubernetes strategic merge uses different list keys here: `containers` and
`volumes` merge by `name`, but `volumeMounts` merge by `mountPath`. The patch
must delete the original mount by its old `mountPath` before it adds the new
mount. Do not use `$patch: replace` on the `workload-socket` volume entry. A
list-level replace directive replaces the whole `volumes` list. That removes
Istio's other required volumes and makes the generated Deployment invalid.
Merge the entry by `name`, set `emptyDir` to `null`, and add the CSI source.

A representative ConfigMap entry is:

```yaml
data:
  deployment: |
    spec:
      replicas: 1
      template:
        metadata:
          labels:
            app.kubernetes.io/component: zone-gateway
            security.poc.example/zone: zone-a
            spiffe.io/spire-managed-identity: "true"
        spec:
          nodeSelector:
            security.poc.example/gateway-zone: zone-a
          initContainers:
          - name: wait-for-spire-socket
            image: <pinned shell-capable image>
            command: [sh, -c, 'until test -S /run/secrets/workload-spiffe-uds/socket; do sleep 1; done']
            volumeMounts:
            - name: workload-socket
              mountPath: /run/secrets/workload-spiffe-uds
              readOnly: true
          volumes:
          - name: workload-socket
            emptyDir: null
            csi:
              driver: csi.spiffe.io
              readOnly: true
          containers:
          - name: istio-proxy
            volumeMounts:
            - $patch: delete
              mountPath: /var/run/secrets/workload-spiffe-uds
            - name: workload-socket
              mountPath: /run/secrets/workload-spiffe-uds
              readOnly: true
```

The init container proves that the socket is present before Envoy starts. It
does not prove that SPIRE issued an SVID. The bootstrap and e2e checks must
also verify the actual SVID, URI SAN, and protected traffic.

Sources: [Istio 1.31 generated deployment fixture](https://github.com/istio/istio/blob/1.31.0/pilot/pkg/config/kube/gatewaycommon/testdata/deployment/simple.yaml), [Istio 1.31 SPIRE sample](https://github.com/istio/istio/blob/1.31.0/samples/security/spire/istio-spire-config.yaml), [Kubernetes strategic merge patch reference](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/), [Kubernetes strategic merge list directives](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-api-machinery/strategic-merge-patch.md), [Kubernetes `VolumeMount` patch key](https://github.com/kubernetes/kubernetes/blob/v1.34.0/staging/src/k8s.io/api/core/v1/types.go#L3005-L3011), [Kubernetes `Volume` patch key](https://github.com/kubernetes/kubernetes/blob/v1.34.0/staging/src/k8s.io/api/core/v1/types.go#L4089-L4095).

## SPIRE identity

The SPIRE integration documents the workload identity format:

```text
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

Mode C needs its own ClusterSPIFFEID because the existing identity fixes its
ServiceAccount to `zone-gateway`. Select the new Gateway pods using explicit
mode-C labels and derive the identity from the generated service account:

```yaml
spiffeIDTemplate: spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}
workloadSelectorTemplates:
  - k8s:ns:{{ .PodMeta.Namespace }}
  - k8s:sa:{{ .PodSpec.ServiceAccountName }}
```

The SPIRE guide states that a matching registration must exist before a
sidecar or gateway can become Ready. Apply the ClusterSPIFFEID before creating
Gateways and validate the generated ServiceAccount and serving SVID afterward.

Source: [Istio 1.31 SPIRE integration](https://istio.io/v1.31/docs/ops/integrations/spire/).

## Listeners and routes

Istio 1.31 converts the following Gateway API extension to the Istio
`ISTIO_MUTUAL` server TLS mode. It returns before processing certificate
references, so this listener must not use a Kubernetes TLS Secret for the
SPIRE identity.

```yaml
listeners:
  - name: protected
    port: 8443
    protocol: HTTPS
    tls:
      mode: Terminate
      options:
        gateway.istio.io/tls-terminate-mode: ISTIO_MUTUAL
```

Gateway API's `URLRewrite` filter is Extended support. A
`ReplacePrefixMatch` rewrite requires exactly one `PathPrefix` match. It can
remove `/call/zone-b` while retaining the remainder of the URL:

```yaml
matches:
  - path:
      type: PathPrefix
      value: /call/zone-b
filters:
  - type: URLRewrite
    urlRewrite:
      path:
        type: ReplacePrefixMatch
        replacePrefixMatch: /
```

Use a `RequestHeaderModifier` on the same route to remove each caller-supplied
trust header. URLRewrite and RequestRedirect cannot coexist in one rule.

Sources: [Istio 1.31 TLS conversion](https://github.com/istio/istio/blob/1.31.0/pilot/pkg/config/kube/gateway/conversion.go#L2308-L2336), [Gateway API v1.6.0 HTTPRoute types](https://github.com/kubernetes-sigs/gateway-api/blob/v1.6.0/apis/v1/httproute_types.go#L138-L304), [URL rewrite example](https://github.com/kubernetes-sigs/gateway-api/blob/v1.6.0/examples/standard/http-redirect-rewrite/httproute-rewrite-prefix-path.yaml).

## Cross-namespace backends

A cross-namespace `backendRef` requires a ReferenceGrant in the target
namespace. Give each source route namespace a distinct grant and restrict its
`to` entry to the exact destination Service:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-zone-a-to-zone-b-gateway
  namespace: zone-b
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: zone-a
  to:
    - group: ""
      kind: Service
      name: zone-b-gateway-istio
```

`from` does not have a name field by design. A principal permitted to create
an HTTPRoute in `zone-a` could otherwise rename its Route. The exact Service
name is still a useful limit in `to`.

Source: [Gateway API v1.6.0 ReferenceGrant types](https://github.com/kubernetes-sigs/gateway-api/blob/v1.6.0/apis/v1/referencegrant_types.go#L43-L170).

## AuthorizationPolicy attachment and fail closed behavior

For Kubernetes Gateway data plane pods, use `targetRefs`, not a selector. In
Istio 1.31, a target Gateway must be in the same namespace as the policy.
`selector` and `targetRefs` are mutually exclusive. The policy shape is:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: zone-trust-generated
  namespace: zone-b
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: zone-gateway
  action: ALLOW
  rules: []
```

`rules: []` is the explicit empty allow list. Keep this controller-owned
object separate from the bootstrap-owned baseline policy. The baseline has a
matching targetRef and allows only local port 8080; the generated policy adds
only the allowed principals for port 8443. An absent generated policy must not
expand the baseline to port 8443. A manual deployment fallback must apply
`gateway.networking.k8s.io/gateway-name: <Gateway name>` to its pod for
targetRef attachment.

Sources: [Istio 1.31 AuthorizationPolicy reference](https://istio.io/v1.31/docs/reference/config/security/authorization-policy/), [Istio 1.31 Gateway API task: manual deployment](https://istio.io/v1.31/docs/tasks/traffic-management/ingress/gateway-api/#manual-deployment).

## Outbound mTLS

HTTPRoute controls the Gateway listener and routing. It does not replace
Istio's outbound TLS policy. Retain a DestinationRule for each destination
Gateway Service and set `maxRequestsPerConnection: 1`. Use `ISTIO_MUTUAL` and
the SVID built from the actual generated ServiceAccount:

```yaml
trafficPolicy:
  connectionPool:
    http:
      maxRequestsPerConnection: 1
  tls:
    mode: ISTIO_MUTUAL
    subjectAltNames:
      - spiffe://poc.example/ns/zone-b/sa/<actual-service-account>
```

`ISTIO_MUTUAL` obtains the workload certificate from Istio's workload identity
mechanism. It does not accept manual TLS key or certificate fields.

Source: [Istio 1.31 TLS configuration](https://istio.io/v1.31/docs/ops/configuration/traffic-management/tls-configuration/).

## Implementation checks

Wait for `Gateway` `Programmed=True`, then require `HTTPRoute`
`Accepted=True` and `ResolvedRefs=True`. Report the full status conditions on
failure. Check the generated Deployment and Pod, rather than relying on a
controller's naming convention, for all of the following:

- ServiceAccount name and SVID URI SAN match.
- The pod has the explicit mode-C labels and Gateway-name label.
- The CSI volume and read-only `/run/secrets/workload-spiffe-uds` mount exist.
- The application pods still have one application container and no SPIRE mount.
- AuthorizationPolicy targetRefs point at the local Gateway and the generated
  policy retains explicit empty rules when no edge is allowed.
