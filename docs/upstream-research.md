# Upstream verification for the SPIRE zone gateway POC

Verified 2026-09-13 against the linked upstream documentation and the
published `spire-0.30.2` chart artifact. This note records version-sensitive
implementation decisions; it does not replace the architecture contract.

## Pins

The requested SPIFFE hardened umbrella chart pin exists. The chart repository
[index](https://spiffe.github.io/helm-charts-hardened/index.yaml) publishes
`spire` chart `0.30.2` at
`https://github.com/spiffe/helm-charts-hardened/releases/download/spire-0.30.2/spire-0.30.2.tgz`.
Its `Chart.yaml` declares `appVersion: 1.15.3`. Keep the requested pins:

| Component | Pin | Verified source |
| --- | --- | --- |
| SPIRE hardened umbrella chart | `0.30.2` | [chart index](https://spiffe.github.io/helm-charts-hardened/index.yaml), [release artifact](https://github.com/spiffe/helm-charts-hardened/releases/tag/spire-0.30.2) |
| SPIRE supplied by that chart | `1.15.3` | [chart metadata in the release artifact](https://github.com/spiffe/helm-charts-hardened/releases/download/spire-0.30.2/spire-0.30.2.tgz) |
| Istio | `1.31.0` | [Istio 1.31 documentation](https://istio.io/latest/docs/ops/integrations/spire/) |
| Envoy validation image | `v1.39.1` | POC implementation pin; validate its configuration at build time rather than treating the current Envoy `latest` docs as its exact API reference. |

The current hardened chart repository has `0.30.2` as the relevant published
release, so no substitute pin is needed.

## Platform pins: kind, Kubernetes, and Cilium

The original Kubernetes node-image pin,
`kindest/node:v1.34.1`, is unavailable: the Docker Hub tag endpoint returned
HTTP 404 on 2026-09-13. `kindest/node:v1.34.0` is published (a multi-platform
manifest list with digest
`sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a`),
but it is not an upstream-supported pairing with the POC's Cilium pin.

The constraint is Cilium `1.18.4`: its versioned source lists Kubernetes
`1.30`, `1.31`, `1.32`, and `1.33` as e2e-tested and guaranteed compatible;
Kubernetes `1.34` is outside that list ([Cilium 1.18.4 requirements source](https://github.com/cilium/cilium/blob/v1.18.4/Documentation/network/kubernetes/requirements.rst)).
Do not claim NetworkPolicy isolation was tested on Cilium `1.18.4` with a 1.34
node image.

`kind` `v0.33.0` is a signed, published release (2026-08-26). Its source
checkout uses Go `1.26.7` in `.go-version`, not Go `1.26.1`; the module's
declared minimum language version remains Go 1.17. Use the signed prebuilt
binary in bootstrap when possible, so the local Go toolchain is not part of
the POC's reproducibility surface ([kind v0.33.0 release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0), [source pin](https://github.com/kubernetes-sigs/kind/blob/v0.33.0/.go-version)).

There is no all-pinned, upstream-tested `kind 0.33.0 + Kubernetes 1.34 +
Cilium 1.18.4` combination. Choose one coherent correction:

| Goal | Recommended pins | Evidence and implication |
| --- | --- | --- |
| Preserve Cilium `1.18.4` | kind `v0.31.0`; `kindest/node:v1.33.7@sha256:d26ef333bdb2cbe9862a0f7c3803ecc7b4303d8cea8e814b481b09949d353040` | The kind `v0.31.0` release publishes this exact image, and Kubernetes 1.33 is in Cilium 1.18.4's supported range ([release list](https://github.com/kubernetes-sigs/kind/releases/tag/v0.31.0)). This is the safest POC choice if retaining the declared Cilium version matters. |
| Preserve kind `v0.33.0` and Kubernetes 1.34 | Cilium `v1.19.0`; `kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d` | kind v0.33.0 publishes the image, and Cilium 1.19.0 lists Kubernetes 1.31–1.34 as tested ([kind release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0), [Cilium 1.19 requirements source](https://github.com/cilium/cilium/blob/v1.19.0/Documentation/network/kubernetes/requirements.rst)). |

The selected POC path is the second row: kind `v0.33.0`, Kubernetes
`v1.34.11`, and Cilium `v1.19.0`. The implementation documentation must
explicitly replace the unavailable `v1.34.1` reference and record this
compatibility decision.

## Go and controller-runtime compatibility

As of 2026-09-13, the official Go download page lists `go1.27.1` as the
latest stable release and `go1.26.8` as the current patch release in the 1.26
line ([Go downloads](https://go.dev/dl/)). Therefore, if the POC intentionally
stays on Go 1.26, pin its build image to `golang:1.26.8`, rather than the
host's `1.26.1` or the stale `1.26.7` recommendation. Docker Hub publishes
that tag as manifest-list digest
`sha256:3c3e25a4da13fd0478eed2df1eb35a0e667094a7124d3993a6a1d30f71c17e79`
(the linux/amd64 image digest is
`sha256:2d54f6c8c6ea532a321e0b4c69553b2ed3637608d4f4357dbed37939fe2620cc`).

`sigs.k8s.io/controller-runtime` `v0.22.4` is the correct companion for
Kubernetes `v0.34.1` libraries: its release `go.mod` requires
`k8s.io/api`, `apimachinery`, and `client-go` at `v0.34.1` and declares
`go 1.24.0` ([v0.22.4 go.mod](https://github.com/kubernetes-sigs/controller-runtime/blob/v0.22.4/go.mod)).
Go 1.26.8 therefore exceeds the supported minimum without a reason to force a
Go 1.27 migration. Keep the module directive at the desired language minimum
(for example `go 1.26.0`); use the container-image tag to pin the patch-level
compiler used in CI and builds.

## CRD CEL immutability clarification

For required string fields such as `spec.sourceZone` and
`spec.destinationZone`, the field-scoped transition rule is simply:

```yaml
x-kubernetes-validations:
- rule: self == oldSelf
  message: value is immutable
```

Do not use `oldSelf == null` for this rule. A CEL expression referencing
`oldSelf` is a transition rule. Kubernetes evaluates it only on updates where
both old and new field values exist; it is not evaluated on create. On an
optional field, it is also not evaluated when the field is added or removed.
The Kubernetes CRD documentation gives `self.foo == oldSelf.foo` as the
immutability pattern ([transition rules](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#transition-rules)).

If a CRD deliberately sets `optionalOldSelf: true` (stable since Kubernetes
1.33), `oldSelf` becomes a CEL `Optional`, so use `oldSelf.hasValue()` and
`oldSelf.value()`; it is not a nullable string. That feature is unnecessary
for the POC's required immutable zone fields.

## SPIRE chart `0.30.2`: exact values

The umbrella chart exposes the Agent values under `spire-agent`, rather than
under `global.spire`. The extracted `spire/charts/spire-agent/values.yaml`
from the published artifact defines these exact keys:

```yaml
global:
  spire:
    trustDomain: poc.example
    clusterName: spire-gw-poc

spire-agent:
  sds:
    enabled: true
    defaultSVIDName: default
    defaultBundleName: ""
    defaultAllBundlesName: ROOTCA
```

This was rendered with Helm 3.21.0 and the chart artifact. The rendered Agent
configuration contains:

```json
"sds": {
  "default_all_bundles_name": "ROOTCA",
  "default_bundle_name": "",
  "default_svid_name": "default",
  "disable_spiffe_cert_validation": false
}
```

This matches the upstream Istio SPIRE guide's federation-compatible naming:
`default_svid_name=default`, `default_bundle_name=null`, and
`default_all_bundles_name=ROOTCA` ([guide](https://istio.io/latest/docs/ops/integrations/spire/#spiffe-federation)).
For this single-trust-domain POC, `ROOTCA` is still a valid validation-context
resource; it is simply configured as the *all bundles* resource name.

Additional chart facts useful for bootstrap assertions:

- `spire-agent.nodeAttestor.k8sPSAT.enabled` defaults to `true`.
- `spire-agent.socketAlternate.names` defaults to `[socket]`, so the CSI mount
  presents the required `socket` alias.
- `spiffe-csi-driver.enabled` and `spire-server.controllerManager.enabled`
  default to `true` in the umbrella chart.

Do not rely only on defaults in the installer: render the pinned chart, then
assert the resulting Agent config has the three SDS resource names and the
socket alternate before applying it. The public SPIRE Agent documentation says
SDS is served on the same public Agent socket as the Workload API, and Envoy
clients are workload-attested ([SPIRE Agent SDS support](https://spiffe.io/docs/latest/deploying/spire_agent/#envoy-sds-support)).

SPIRE documents `default` as the default X.509-SVID `TlsCertificate` resource,
`ROOTCA` as the default local trust-domain validation context, and `ALL` as the
default federated/all-bundles context ([SDS configuration](https://spiffe.io/docs/latest/deploying/spire_agent/#sds-configuration)). The chart override above deliberately renames the latter to `ROOTCA`, as required by Istio's integration instructions.

## Istio and SPIRE gateway integration

Istio's official guide requires identical SPIRE and Istio trust domains and an
installed SPIFFE CSI driver ([integration prerequisites](https://istio.io/latest/docs/ops/integrations/spire/#install-spire)). It also describes the exact CSI mount:

```yaml
volumes:
- name: workload-socket
  csi:
    driver: csi.spiffe.io
    readOnly: true
```

mounted into `istio-proxy` at `/run/secrets/workload-spiffe-uds`.

Define the custom `spire` injection template under
`values.sidecarInjectorWebhook.templates.spire`. For a regular sidecar it
patches `initContainers` on Kubernetes 1.33+ because native sidecars are used.
For a gateway, however, the official guide explicitly says to keep the SPIRE
template patch on regular `containers` regardless of native-sidecar mode
([official gateway-template note](https://istio.io/latest/docs/ops/integrations/spire/#install-istio)).

For each explicit gateway Deployment, use Istio's built-in gateway template
and then apply the SPIRE patch:

```yaml
metadata:
  annotations:
    sidecar.istio.io/inject: "true"
    inject.istio.io/templates: "gateway,spire"
```

The comma-separated annotation is supported by Istio's
[`inject.istio.io/templates`](https://istio.io/latest/docs/reference/config/annotations/#InjectTemplates)
annotation. The built-in gateway template is the documented selection for an
in-cluster Gateway Deployment ([Installing Gateways](https://istio.io/latest/docs/setup/additional-setup/gateway/)). Render an actual gateway Pod in CI and assert that the mount belongs to the regular `istio-proxy` container.

The gateway registration should select the SPIRE-managed identity label and
the intended ServiceAccount/namespace. The official integration example uses
the label `spiffe.io/spire-managed-identity: "true"`; the POC's
`ClusterSPIFFEID` must additionally constrain the namespace and
`zone-gateway` ServiceAccount so a different workload cannot inherit gateway
identity ([SPIRE registration example](https://istio.io/latest/docs/ops/integrations/spire/#option-1-auto-registration-using-the-spire-controller-manager)).

## Istio AuthorizationPolicy principal format

`source.principals` must **not** include `spiffe://`. Istio documents the
authenticated peer principal format as
`<TRUST_DOMAIN>/ns/<NAMESPACE>/sa/<SERVICE_ACCOUNT>`, for example
`cluster.local/ns/default/sa/productpage`; it is derived from the peer
certificate and requires mTLS ([AuthorizationPolicy Source reference](https://istio.io/latest/docs/reference/config/security/authorization-policy/#source)).

Thus the generated policy for a `zone-a` to `zone-b` edge must contain:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: zone-trust-generated
  namespace: zone-b
spec:
  selector:
    matchLabels:
      app: zone-gateway
  action: ALLOW
  rules:
  - to:
    - operation:
        ports: ["8080"]
  - from:
    - source:
        principals: ["poc.example/ns/zone-a/sa/zone-gateway"]
    to:
    - operation:
        ports: ["8443"]
```

The selector must uniquely select the destination gateway. The unconditional
8080 rule is necessary because the existence of any ALLOW policy changes the
selected workload to allow-only semantics: a request is denied unless an
ALLOW rule matches ([evaluation order](https://istio.io/latest/docs/reference/config/security/authorization-policy/#authorization-policy)). An empty incoming list must therefore retain the 8080 rule while omitting every 8443 rule. The policy's `operation.ports` values are strings and match the connection port ([Operation reference](https://istio.io/latest/docs/reference/config/security/authorization-policy/#operation)).

## Standalone Envoy: SDS, identity extraction, and external authorization

SPIRE's SDS API provides `TlsCertificate` resources (including the X.509-SVID)
and `CertificateValidationContext` resources over the public Agent socket.
The `default` resource obtains the workload's default SVID, while the
configured `ROOTCA` resource obtains the validation context ([SPIRE SDS
semantics](https://spiffe.io/docs/latest/deploying/spire_agent/#envoy-sds-support)). Use SDS for both the upstream client TLS context and downstream server TLS context, with downstream client certificates required.

Envoy Lua's
[`uriSanPeerCertificate()`](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/lua_filter.html#uri-san-peer-certificate)
returns a table of URI SAN entries, or an empty table if no peer certificate
or URI SAN exists. On the 8443 listener, after mTLS has validated the
connection, require exactly one URI equal to the allowed grammar
`spiffe://poc.example/ns/<zone>/sa/zone-gateway`; overwrite the identity header
with that value and set the destination internally. Reject malformed,
missing, duplicate, wrong-domain, or wrong-service-account values. Strip both
internal headers before the router sends plain HTTP to the app.

Use the HTTP `envoy.filters.http.ext_authz` filter after the Lua identity
step. Envoy's own HTTP authorization example uses a short `0.25s` timeout and
`failure_mode_allow: false` ([ext_authz configuration](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_authz_filter)). Configure the check request to expose only the derived identity,
destination, method, and path to the controller; do not forward caller-supplied
identity headers or request bodies. Controller unavailability must reject, not
route to the app.

## Recommended implementation checks

1. Add a bootstrap render assertion for the exact Agent SDS JSON values above,
   `k8s_psat`, and the `socket` alternate.
2. Keep SPIRE ID URIs in SPIRE registrations, Envoy Lua, and certificate
   assertions. Use the scheme-less Istio principal only in
   `AuthorizationPolicy.spec.rules[].from[].source.principals`.
3. Render/inject one gateway Pod for the pinned Istio version and assert
   `gateway,spire` produces a regular `istio-proxy` container with the CSI
   mount.
4. Verify a generated empty-edge policy still has the port-8080 ALLOW rule and
   no port-8443 rule; issue traffic tests before claiming denial behavior.

## Caveats

- The upstream Istio guide is written against the current 1.31 documentation.
  The template details are version-sensitive; retain the rendered-Pod test as
  the compatibility gate for the pinned `1.31.0` binary.
- The normal `ROOTCA` meaning in SPIRE is the local bundle, while the Istio
  guide deliberately configures `ROOTCA` as the all-bundles resource alias.
  This POC is single-domain, so either bundle content is equivalent today; use
  the guide's names to match Istio's SDS expectations and preserve a safe
  federation path.
- `uriSanPeerCertificate()` exposes SANs from the peer certificate. Its use as
  an authorization input depends on the listener requiring and validating the
  client certificate before the Lua filter runs.
