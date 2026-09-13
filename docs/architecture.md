# Architecture

## 1. Goal and non-goals

The POC demonstrates dynamic, directional trust between at least two logical zones in one kind cluster. An operator changes a trust edge in a dashboard; that action updates a Kubernetes custom resource; the running data plane begins allowing or denying the affected cross-zone request without rebuilding an image or editing a static manifest.

The POC compares two implementations while holding the application-facing contract constant.

In scope:

- two zones, initially `zone-a` and `zone-b`;
- a dedicated Envoy gateway Pod and an application Pod in every zone;
- SPIRE Server, one SPIRE Agent per Kubernetes node, SPIFFE CSI driver, and automatic gateway registration;
- source-gateway-to-destination-gateway mTLS with short-lived X.509-SVIDs obtained from SPIRE Agent SDS;
- peer SPIFFE ID authorization at the destination gateway;
- a Kubernetes-native, directional `ZoneTrust` policy and dashboard;
- standalone Envoy and Istio-managed Envoy variants;
- repeatable allow, deny, spoofing, fail-closed, and SVID-rotation tests.

Out of scope:

- end-user identity and OIDC;
- direct Pod-to-Pod mesh mTLS;
- application sidecars;
- multiple Kubernetes clusters or SPIRE Server federation;
- VM bootstrap automation. The identity and gateway model is VM-compatible, but this POC's executable environment is kind.

## 2. Security invariants

These invariants are acceptance criteria, not implementation suggestions.

1. Cross-zone traffic reaches an application only through the destination zone gateway.
2. The source gateway presents an X.509-SVID and the destination gateway requires and validates it.
3. A gateway gets its private key from SPIRE Agent SDS through the CSI-mounted Unix socket. The key is never placed in a Kubernetes `Secret`, `ConfigMap`, image, or application filesystem.
4. The destination Envoy derives the peer SPIFFE ID from the validated TLS connection. User-supplied identity headers are removed or overwritten before authorization.
5. `ZoneTrust` is directional. `zone-a -> zone-b` says nothing about `zone-b -> zone-a`.
6. Missing, malformed, stale, or unavailable policy state fails closed for the protected mTLS ingress port.
7. An app receives plain HTTP from its local gateway and does not mount the SPIFFE socket or contain an Envoy/Istio sidecar.
8. NetworkPolicy prevents cross-zone callers from reaching an app Service directly. Only the local gateway's Pod labels may enter the app port.
9. The dashboard cannot mutate arbitrary Kubernetes objects. The controller service account is limited to `ZoneTrust` CRUD/status, controller-owned Istio policies in Istio mode, and the minimum discovery reads.
10. A successful dashboard response means the `ZoneTrust` object was accepted by the API server. The UI separately displays whether the controller has observed and applied that generation.

## 3. Identity and trust model

### 3.1 SPIFFE IDs

Use one trust domain, `poc.example`, and the Istio-compatible identity shape:

```text
spiffe://poc.example/ns/zone-a/sa/zone-gateway
spiffe://poc.example/ns/zone-b/sa/zone-gateway
```

The source zone is derived from the `ns` segment. Authorization additionally requires `sa/zone-gateway`; a random workload in a source namespace must not acquire gateway privileges.

The SPIRE Controller Manager owns gateway registrations through a `ClusterSPIFFEID` whose selectors require both:

```text
k8s:ns:<zone namespace>
k8s:sa:zone-gateway
```

The application service accounts have no SPIRE registration and no CSI volume.

### 3.2 "Zone trust" is authorization, not bundle federation

All POC zones are security segments inside one SPIFFE trust domain. SPIRE authenticates *who the peer is*; `ZoneTrust` decides *whether that authenticated peer may enter a destination zone*.

The dashboard therefore changes authorization state, not root bundles. Mutating bundles per click would conflate cryptographic trust-domain federation with an application connectivity policy, disturb unrelated identities, and make propagation/rollback much harder to reason about. A future multi-cluster extension can map each cluster or organization to a separate trust domain and federate stable bundles; the directional zone matrix should still remain an authorization layer.

## 4. Common request path

Each gateway exposes two ports:

- `8080/tcp` — POC call entrypoint. `GET /call/<destination-zone>/<path>` tells the source gateway to call the named destination gateway.
- `8443/tcp` — protected cross-zone ingress. It requires a client X.509-SVID and routes an authorized request to the local app.

Each app exposes `8080/tcp` inside its zone.

```text
                                              destination zone
 source zone                                  +--------------------------+
 +--------------------------+                 |                          |
 |                          |                 |  +--------------------+  |
 | test/client              |                 |  | zone-b gateway     |  |
 |      | plain HTTP        |                 |  | :8443              |  |
 |      v                   |   SPIRE mTLS    |  | - validate SVID    |  |
 | +--------------------+   |================>|  | - resolve peer ID  |  |
 | | zone-a gateway     |   |                 |  | - enforce policy   |  |
 | | :8080              |   |                 |  +---------+----------+  |
 | +--------------------+   |                 |            | plain HTTP |
 |   SDS -> SPIRE Agent     |                 |            v            |
 |                          |                 |  +--------------------+  |
 +--------------------------+                 |  | zone-b app :8080   |  |
                                              |  | no SPIFFE/Istio    |  |
                                              |  +--------------------+  |
                                              +--------------------------+
```

The destination app returns a small JSON document containing its zone and request path. It does not make an authorization decision and should not receive `x-spiffe-peer-id`.

## 5. Kubernetes API contract

### 5.1 `ZoneTrust` CRD

Use a cluster-scoped CR so every directed edge has one canonical name.

```yaml
apiVersion: security.poc.example/v1alpha1
kind: ZoneTrust
metadata:
  name: zone-a-to-zone-b
spec:
  sourceZone: zone-a
  destinationZone: zone-b
  allowed: true
status:
  observedGeneration: 3
  applied: true
  backend: ext-authz       # or istio-authorization-policy
  message: policy active
  lastTransitionTime: "2026-09-13T10:00:00Z"
```

Validation rules:

- `sourceZone` and `destinationZone` are immutable DNS labels;
- zones must differ;
- the object name must equal `<sourceZone>-to-<destinationZone>`;
- `allowed` is required;
- duplicate directed edges are rejected by naming and controller validation.

The CRD must include a status subresource, printer columns for source/destination/allowed/applied/backend, and CEL validations where the Kubernetes version supports them.

### 5.2 Controller and dashboard API

One Go binary, `zone-trust-controller`, serves the dashboard/API and runs reconciliation. It supports `POLICY_BACKEND=standalone|istio`.

Endpoints:

| Method and path | Purpose |
|---|---|
| `GET /` | Embedded static dashboard |
| `GET /api/v1/zones` | Known zones and gateway readiness |
| `GET /api/v1/trusts` | Desired CR state plus applied status |
| `PUT /api/v1/trusts/{source}/{destination}` | Body `{"allowed":true|false}`; server-side apply the canonical CR |
| `GET /api/v1/events` | Server-sent events for policy/status changes |
| `POST /check` | Standalone Envoy ext-authz endpoint on a separate internal listener; not exposed outside the cluster |
| `GET /healthz` | Process liveness |
| `GET /readyz` | API watch established and initial policy snapshot loaded |
| `GET /metrics` | Reconcile/check counters and latency |

The dashboard uses only this API. It must not hold a Kubernetes token or call the API server from browser JavaScript.

Serve dashboard/API on `:8080`, ext-authz on `:9000`, and metrics/probes on `:8081`. Create separate Kubernetes Services so NetworkPolicy can allow gateway Pods to reach only port 9000 while the localhost dashboard port-forward reaches only port 8080.

Discover zones from namespaces labeled `security.poc.example/zone: "true"`; do not accept an arbitrary namespace name from the browser as a zone.

The UI presents a directed matrix. The diagonal is disabled. Toggling a cell writes the CR, shows a pending generation, and turns solid only after `status.observedGeneration == metadata.generation && status.applied`.

### 5.3 Reconcile semantics

The controller uses informers/client-go, not a polling shell command.

```text
dashboard PUT
    -> Kubernetes API updates ZoneTrust generation
        -> controller reconcile
            -> standalone: rebuild immutable in-memory decision snapshot
            -> istio: server-side apply generated AuthorizationPolicy
        -> write ZoneTrust status
        -> SSE update to dashboard
```

Updates must be idempotent. Deleting an edge is equivalent to deny. The controller starts with an empty deny-all snapshot until its informer cache has synchronized.

## 6. Variant A — standalone Envoy

### 6.1 Data plane

Each zone owns a normal Envoy Deployment with one replica, one ServiceAccount named `zone-gateway`, a ConfigMap bootstrap, and a CSI ephemeral volume:

```yaml
volumes:
  - name: workload-socket
    csi:
      driver: csi.spiffe.io
      readOnly: true
```

Mount the volume at `/run/secrets/workload-spiffe-uds`. Configure an Envoy static cluster pointing to its `socket` Unix-domain socket and use that cluster for SDS secrets:

- `default` — the gateway's rotating `TlsCertificate`/X.509-SVID;
- `ROOTCA` — the validation context/bundle.

Both upstream client TLS and downstream server TLS use SDS. Downstream port 8443 has `require_client_certificate: true`.

Inbound HTTP filter order is security-sensitive:

1. Lua reads `streamInfo():downstreamSslConnection():uriSanPeerCertificate()`.
2. Lua requires exactly one URI SAN matching `spiffe://poc.example/ns/<zone>/sa/zone-gateway`, overwrites `x-spiffe-peer-id`, and sets the static destination zone header.
3. Envoy `ext_authz` calls `zone-trust-authorizer.control-plane.svc:9000/check` with only the trusted identity, destination, method, and path headers. `failure_mode_allow` is `false`.
4. Header mutation removes internal identity/control headers before routing.
5. Router forwards plain HTTP to the local app cluster.

The external authorizer accepts a request only when its immutable snapshot contains an `allowed: true` edge matching the authenticated source namespace and destination. It returns `403` with a machine-readable denial reason otherwise.

### 6.2 Dynamic behavior

No Envoy restart or config reload is needed for a trust toggle. Envoy continues to own TLS authentication and SPIFFE ID extraction; its external authorization filter delegates the rapidly changing relationship decision to the controller. This keeps the custom control plane small and auditable while still driving live enforcement.

The controller outage behavior is fail-closed because Envoy's ext-authz filter has `failure_mode_allow: false`. An explicit short timeout (target 250 ms) bounds failures.

### 6.3 What to verify

- Envoy config validation succeeds for both rendered zone configs.
- SPIRE issues different SVIDs to each gateway; the URI SANs match their namespaces.
- deleting/restarting a gateway obtains a new certificate without a mounted key file.
- spoofed `x-spiffe-peer-id` on port 8080 does not change the identity seen on port 8443.
- controller unavailability causes 403/5xx and never reaches the app.

## 7. Variant B — Envoy + Istio

### 7.1 Deployment model

Istiod manages the gateway Envoys, but there is still one explicit gateway Deployment per zone. Do not inject or enroll application Pods.

Install Istio with `meshConfig.trustDomain: poc.example` and the official custom `spire` injection template that mounts `csi.spiffe.io` at `/run/secrets/workload-spiffe-uds`. The zone gateway deployments use the gateway injection template plus the SPIRE template. Their identities retain Istio's required form:

```text
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

Per zone, create:

- `Deployment`/`Service` for `zone-gateway` with ports 8080 and 8443;
- Istio `Gateway` with HTTP port 8080 and `ISTIO_MUTUAL` port 8443;
- `VirtualService` routes from 8080 to destination gateway Services and from 8443 to the local app Service;
- `DestinationRule` using `ISTIO_MUTUAL` for destination gateway port 8443;
- a controller-owned `AuthorizationPolicy` selecting only the gateway workload;
- NetworkPolicy that permits the app port only from the local gateway.

### 7.2 Generated authorization

For each destination zone, reconcile all incoming `ZoneTrust` edges into exactly one generated `AuthorizationPolicy`, named `zone-trust-generated`, in that zone namespace.

The policy has action `ALLOW` and contains:

- one unconditional rule for the POC call-entry port `8080`;
- one rule per allowed incoming edge on port `8443`, matching the exact Istio source principal `poc.example/ns/<source>/sa/zone-gateway`.

Istio omits the URI scheme in its policy representation. The certificate URI retains `spiffe://`. See [ADR 0002](adr/0002-istio-principal-representation.md).

Keeping a single controller-owned policy per destination avoids overlapping generated resources and makes deny-all explicit: when no incoming edge is allowed, only port 8080 remains reachable and every request to 8443 is denied.

The controller uses server-side apply with a dedicated field manager, waits until the written object is observable, then marks each involved `ZoneTrust` generation applied. Drift is repaired during reconcile. It never edits hand-authored authorization policies.

### 7.3 Identity parsing boundary

Istio's Envoy validates mTLS and supplies the authenticated SPIFFE principal directly to the AuthorizationPolicy engine. The controller never trusts an HTTP identity header in this variant. The app sees plain HTTP after the gateway route and has no sidecar.

### 7.4 What to verify

- each zone gateway proxy secret is issued by SPIRE, not Istiod's default CA;
- `istioctl proxy-config secret` shows the expected URI SAN;
- toggling a `ZoneTrust` changes a real `AuthorizationPolicy` resource and converges without restarting gateways;
- the denied response comes from the destination gateway and its app request counter does not increase;
- the app Pod has one container, no `csi.spiffe.io` volume, and accepts direct plain HTTP only from the local gateway labels.

## 8. Shared platform installation

Use the SPIFFE hardened Helm repository and pin chart `0.30.2`, whose app version is SPIRE `1.15.3`. Defaults install the server, agent, SPIFFE CSI driver, and SPIRE Controller Manager. Supply a values file that at minimum sets:

```yaml
global:
  spire:
    trustDomain: poc.example
    clusterName: spire-gw-poc
spire-agent:
  sds:
    defaultSVIDName: default
    defaultBundleName: ""
    defaultAllBundlesName: ROOTCA
```

The exact key path must be confirmed with `helm show values` for the pinned chart during implementation; fail bootstrap if the rendered Agent config does not contain the three SDS names.

Use PSAT node attestation. Do not copy the older SAT examples; SAT was removed in SPIRE 1.12.

## 9. Isolation and observability

### 9.1 NetworkPolicy

Every zone should be default-deny ingress. Explicitly allow:

- gateway 8080 from the e2e/test namespace or local port-forward path;
- gateway 8443 from Pods labeled as zone gateways;
- app 8080 only from its own namespace's gateway Pod labels;
- DNS and required SPIRE/Istio control-plane flows.

The exact kind CNI behavior must be tested. If the default kindnet does not enforce NetworkPolicy, bootstrap a pinned policy-capable CNI (for example Cilium or Calico) instead of claiming direct-app isolation was verified.

### 9.2 Metrics and logs

Controller metrics:

- `zone_trust_reconcile_total{backend,result}`;
- `zone_trust_applied_generation{source,destination}`;
- `zone_trust_check_total{source,destination,decision}`;
- `zone_trust_check_duration_seconds`.

Gateway access logs include source SPIFFE ID, destination zone, response code, response-code detail, and upstream host. Do not log certificates or private material.

## 10. Variant comparison

| Dimension | A: standalone Envoy | B: Envoy + Istio |
|---|---|---|
| SPIRE key delivery | Direct Envoy SDS | Istio proxy SDS through the same CSI socket |
| Dynamic policy | Controller's in-memory snapshot, checked through ext-authz | Controller-generated Istio `AuthorizationPolicy` |
| Gateway config ownership | Hand-authored Envoy bootstrap | Istiod from Gateway/VirtualService/DestinationRule |
| Policy propagation | One informer event plus next request | Kubernetes write plus Istiod/xDS convergence |
| Failure mode | ext-authz dependency; explicitly fail closed | Last accepted Envoy policy continues during controller outage |
| Operational footprint | Small, but custom authz service is on the request path | Larger control plane; less custom data-plane logic |
| Debugging | Envoy config/logs + controller snapshot | Kubernetes resources + Istiod + Envoy proxy state |
| Best fit | Small gateway-only deployments and transparent control | Existing Istio operations, richer traffic/policy needs |
| VM path | Natural: Envoy + SPIRE Agent on VM | Supported but requires Istio VM onboarding/control-plane reachability |

## 11. Known limitations to state in the final POC

- One kind cluster and one SPIFFE trust domain do not demonstrate SPIFFE federation.
- The plain HTTP caller entrypoint is a test harness, not an end-user authentication boundary.
- One gateway replica per zone makes behavior easy to inspect but is not highly available.
- Authorization is zone-level and service-account-level, not path/tenant/user-level.
- Dashboard authentication is intentionally omitted for local kind; bind it to localhost via port-forward.
- The POC proves certificate rotation functionally, not long-duration production rotation under load.
