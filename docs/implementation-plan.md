# Implementation plan

This plan is ordered so every commit leaves a reviewable, testable increment. The implementer should preserve the security invariants in [architecture.md](architecture.md) and record any necessary deviation in a new ADR.

## 1. Target repository layout

```text
.
├── Makefile
├── README.md
├── versions.env
├── cmd/
│   └── zone-trust-controller/
│       └── main.go
├── internal/
│   ├── api/                 # dashboard REST/SSE and ext-authz HTTP handlers
│   ├── authz/               # SPIFFE ID validation and immutable edge snapshot
│   ├── controller/          # ZoneTrust reconciler and status writer
│   ├── istio/               # AuthorizationPolicy renderer/applicator
│   └── ui/                  # embedded static dashboard
├── api/
│   └── v1alpha1/            # ZoneTrust Go types, deepcopy, scheme registration
├── config/
│   ├── crd/
│   │   └── security.poc.example_zonetrusts.yaml
│   ├── rbac/
│   ├── controller/
│   ├── spire/
│   │   ├── values.yaml
│   │   └── gateway-clusterspiffeid.yaml
│   ├── common/
│   │   ├── namespaces.yaml
│   │   ├── apps.yaml
│   │   ├── network-policies.yaml
│   │   └── initial-trusts.yaml
│   ├── standalone/
│   │   ├── envoy-bootstrap-template.yaml
│   │   ├── gateways.yaml
│   │   └── kustomization.yaml
│   └── istio/
│       ├── istio-operator.yaml
│       ├── gateways.yaml
│       ├── virtual-services.yaml
│       ├── destination-rules.yaml
│       └── kustomization.yaml
├── deploy/
│   ├── standalone/kustomization.yaml
│   └── istio/kustomization.yaml
├── scripts/
│   ├── bootstrap.sh
│   ├── destroy.sh
│   ├── render-envoy.sh
│   ├── verify-svids.sh
│   └── e2e.sh
├── test/
│   ├── fixtures/
│   └── integration/
├── Dockerfile
└── docs/
```

Avoid checked-in generated binaries, downloaded tools, kubeconfigs, and certificate material. Put local tools under `.tools/` and add it to `.gitignore`.

## 2. Developer interface

Expose the complete workflow through stable Make targets:

```text
make tools                       # download pinned helm/istioctl if absent
make test                        # Go unit tests, static checks, manifest checks
make bootstrap MODE=standalone  # create kind, install SPIRE, deploy A
make bootstrap MODE=istio       # create kind, install SPIRE/Istio, deploy B
make e2e MODE=standalone
make e2e MODE=istio
make dashboard                  # localhost-only port-forward and print URL
make inspect                    # Pods, ZoneTrust, SVIDs, effective policy
make destroy
```

All scripts must use `set -Eeuo pipefail`, locate the repository root from their own path, accept `KUBECONFIG`, and avoid changing the user's current kubectl context globally. Generate a dedicated kubeconfig under `.state/<mode>/kubeconfig`.

`bootstrap.sh` must be idempotent for the same mode. Switching modes should require `make destroy` or a distinct cluster name (`spire-gw-standalone`, `spire-gw-istio`) so resources cannot be accidentally mixed.

## 3. Work package 1 — skeleton and checks

Deliverables:

1. `versions.env` with the pinned versions from the README.
2. Go module using the current stable Go version supported by pinned controller-runtime/client-go.
3. `Makefile`, `.dockerignore`, expanded `.gitignore`, controller `Dockerfile` with a non-root distroless final image.
4. CI workflow for unit tests, `go vet`, `go test -race`, YAML lint/schema validation, Envoy config validation, and build.

Checks:

- every image tag is sourced from `versions.env` or Kustomize image overrides;
- controller image builds for `linux/amd64` and `linux/arm64`;
- no floating `latest` tag;
- GitHub Actions do not require repository secrets for pull requests.

Suggested commit: `chore: scaffold reproducible POC toolchain`

## 4. Work package 2 — CRD and controller core

### 4.1 API types

Implement `ZoneTrustSpec` and `ZoneTrustStatus` exactly as specified in the architecture. Generate deepcopy methods and the CRD using controller-gen, then check generated artifacts into the repo.

Add unit tests for:

- canonical edge naming;
- invalid/self edges;
- SPIFFE ID parser acceptance and rejection;
- deterministic policy ordering;
- deny on missing edge;
- immutable snapshot concurrency under `go test -race`.

### 4.2 Reconciler

Use controller-runtime or client-go informers. controller-runtime is preferred because status updates, cache synchronization, server-side apply, health probes, and metrics are standard.

Startup behavior:

1. initialize an empty deny-all snapshot;
2. start the Kubernetes cache;
3. stay unready until cache sync completes;
4. reconcile all existing `ZoneTrust` objects;
5. atomically publish the snapshot or generated Istio policies;
6. write status using conflict retries.

Do not derive decisions from dashboard process memory or annotations.

Suggested commit: `feat: add directional ZoneTrust API and reconciler`

## 5. Work package 3 — dashboard and standalone authorizer

### 5.1 Dashboard

Build a dependency-light UI with embedded HTML/CSS/JavaScript. A framework is unnecessary for a two-zone matrix, but the layout must support more zones returned by the API.

Required states per cell:

- allowed/applied;
- denied/applied;
- pending desired generation;
- reconcile error;
- unreachable controller.

Show the exact source/destination, SPIFFE principal template, backend name, generation, and last transition. Confirm toggles only after the API request succeeds; use SSE to observe application.

### 5.2 REST mutation

The PUT handler validates path/body, builds the canonical object, and uses server-side apply. Return:

- `202 Accepted` with desired generation while application is pending;
- `400` for malformed zones/body;
- `409` for immutable-field/name conflicts;
- `503` if the Kubernetes API is unavailable.

### 5.3 ext-authz contract

Use Envoy's HTTP ext-authz protocol for the POC. `/check` is reachable only on the cluster Service and must:

1. accept `x-spiffe-peer-id` and `x-destination-zone` only from gateway traffic;
2. parse the exact SPIFFE URI and require the gateway service account;
3. consult one atomically loaded snapshot;
4. return 200 for allow or 403 for deny;
5. include a short `x-zone-trust-decision` response header for gateway logs;
6. never trust `x-source-zone` supplied by a caller.

Run `/check` on the architecture's separate `:9000` listener and expose it through a dedicated ClusterIP Service. NetworkPolicy allows only gateway Pods to that Service port. The dashboard Service exposes only `:8080`, and developer access is localhost port-forward only.

Suggested commit: `feat: add live trust dashboard and fail-closed authorizer`

## 6. Work package 4 — shared kind and SPIRE foundation

### 6.1 kind

Create a cluster with one control-plane and two worker nodes. Use node labels to make zone gateway placement deterministic enough for inspection, but do not equate Kubernetes topology labels with workload identity.

Bootstrap order:

1. verify Docker, kubectl, kind, curl, and checksum tooling;
2. create isolated kubeconfig and kind cluster;
3. install a policy-capable CNI if NetworkPolicy enforcement is required;
4. install SPIRE CRDs and SPIRE chart `0.30.2`;
5. wait for Server, Agent on every node, CSI driver, and controller-manager;
6. apply namespaces, ServiceAccounts, and `ClusterSPIFFEID`;
7. build/load the controller image and deploy it;
8. deploy selected mode;
9. run readiness and SVID smoke checks.

### 6.2 SPIRE

Render the Helm chart before installation and assert:

- PSAT node attestation is configured;
- Agent SDS resources are `default` and `ROOTCA` as required by Envoy/Istio;
- CSI driver name is `csi.spiffe.io`;
- socket alternate name `socket` is enabled;
- trust domain and cluster name are exact.

Use `ClusterSPIFFEID` auto-registration rather than imperative `spire-server entry create`. Restrict its Pod selector and workload selector templates to gateway Pods/ServiceAccounts.

### 6.3 Apps and isolation

Use a small pinned HTTP echo image or build a tiny app from this repo. A repo-built app is preferred because it can expose `/healthz`, `/requests`, and deterministic JSON without relying on a mutable third-party image.

Assert in tests that app Pod specs have:

- exactly one app container;
- no sidecars/init sidecars;
- no CSI/hostPath volume;
- no SPIFFE environment variable;
- plain HTTP readiness probe.

Suggested commit: `feat: bootstrap kind and SPIRE gateway identities`

## 7. Work package 5 — variant A

Generate one Envoy config per zone from a reviewed template. Generated ConfigMaps may be checked in if `make generate` is deterministic and CI verifies no diff.

Required Envoy details:

- admin interface bound to `127.0.0.1`, not the Pod network;
- static UDS cluster for SPIRE Agent SDS;
- SDS secret configs for `default` and `ROOTCA`;
- upstream `UpstreamTlsContext` on cross-zone clusters;
- downstream `DownstreamTlsContext` with required client certificate on 8443;
- TLS 1.3 preferred/minimum TLS 1.2;
- Lua identity extraction on the protected listener only;
- exact trust-domain and service-account validation in Lua and controller;
- ext-authz timeout and `failure_mode_allow: false`;
- internal headers removed before the app;
- circuit breaking/retry kept conservative so a deny is not retried;
- JSON access logs with TLS/SPIFFE/policy fields.

Run `envoy --mode validate -c` against every rendered config in CI using `envoyproxy/envoy:v1.39.1`.

Suggested commit: `feat: add standalone SPIRE SDS zone gateways`

## 8. Work package 6 — variant B

### 8.1 Istio installation

Pin Istio `1.31.0` and follow its SPIRE integration guide. The IstioOperator/config must:

- set `meshConfig.trustDomain: poc.example`;
- add the official `spire` injection template;
- mount `csi.spiffe.io` at `/run/secrets/workload-spiffe-uds` in gateway proxies;
- avoid installing a shared default ingress gateway if it is not used;
- deploy two explicit zone gateway workloads after Istiod is ready.

Kubernetes 1.33+ enables native sidecars by default, but these zone gateways use the gateway injection template and a regular proxy container. Keep the SPIRE socket mount on the actual `istio-proxy` container produced by the pinned template and assert it in a rendered Pod.

### 8.2 Traffic resources

Create the Gateway, VirtualService, and DestinationRule resources described in the architecture. Use port-level DestinationRule TLS so only gateway-to-gateway 8443 is `ISTIO_MUTUAL`; local app upstream remains HTTP.

Prevent accidental sidecar injection into app deployments using explicit `sidecar.istio.io/inject: "false"` and a test assertion.

### 8.3 Policy backend

Unit-test the AuthorizationPolicy renderer as a pure function. Its output must be stable, sorted, and contain exact principals. Reconciliation uses server-side apply and owns only `zone-trust-generated`.

After deploy, run:

```text
istioctl analyze --all-namespaces
istioctl proxy-status
istioctl proxy-config secret <zone-gateway-pod> -n <zone>
```

Treat analyzer errors and stale proxies as failures. Document any non-security warnings.

Suggested commit: `feat: add Istio-managed SPIRE zone gateways`

## 9. Work package 7 — e2e and evidence

Use one table-driven `scripts/e2e.sh` for all three modes. Create temporary port-forwards with cleanup traps or use a dedicated test Pod. Never depend on a developer's pre-existing port-forward.

### 9.1 Functional matrix

For each mode:

| Test | Setup/action | Expected result |
|---|---|---|
| default deny | no A→B edge | request denied; B app counter unchanged |
| allow A→B | dashboard API sets true; wait applied generation | HTTP 200 from B app |
| directional | A→B true, B→A false | A→B 200; B→A denied |
| live deny | toggle active A→B to false | next requests deny without Pod restart |
| restore allow | toggle true | requests recover without Pod restart |
| spoof header | caller supplies another `x-spiffe-peer-id` | ignored/overwritten; authenticated source used |
| wrong workload | non-gateway workload tries 8443 | TLS/authorization fails |
| direct app | source zone addresses B app Service | NetworkPolicy denies/timeouts |
| controller outage | scale controller to zero | A fails closed; B retains last applied policy |
| controller recovery | scale back up | status and behavior converge |
| SVID rotation | capture serial/expiry, force safe gateway/SPIRE refresh | new SVID active, traffic resumes without key files |

### 9.2 Structural assertions

- exactly one gateway Deployment and one app Deployment per zone;
- every gateway has the CSI socket and expected SPIFFE entry;
- no app has SPIRE/Istio artifacts;
- no Kubernetes Secret contains gateway private keys;
- `ZoneTrust.status` catches up to its generation;
- variant B has a generated `AuthorizationPolicy`; variant A has none;
- variant A's Envoy config contains ext-authz; variant B's proxy config contains the Istio RBAC policy.

### 9.3 Timing

Measure, do not hard-code, convergence from API acceptance to applied status and from applied status to observed traffic decision. Report p50/p95 over at least 20 toggles as POC data, without presenting it as a production benchmark.

Suggested commit: `test: verify live directional trust in both gateway modes`

## 10. Work package 8 — operator documentation and PR

Replace the README status section with runnable quickstarts. Include:

- prerequisites and tested host architectures;
- expected startup time/resource use;
- both mode commands;
- dashboard screenshot;
- example `ZoneTrust` YAML and kubectl inspection commands;
- SVID/proxy verification commands;
- troubleshooting for CSI socket, registration, Istio readiness, and Docker resources;
- the comparison table and known limitations from the architecture;
- cleanup.

Before opening the PR, capture:

```text
make test
make bootstrap MODE=standalone && make e2e MODE=standalone
make destroy
make bootstrap MODE=istio && make e2e MODE=istio
make destroy
```

The PR description must state exact host architecture, Docker/kind/Kubernetes versions, pass/fail counts, measured convergence, and any skipped test with a reason.

Suggested commit: `docs: add operations guide and verified trade-offs`

## 11. Definition of done

Implementation is complete only when all are true:

- fresh checkout to all three passing modes is automated;
- dashboard toggles mutate real `ZoneTrust` objects;
- applied status corresponds to effective ext-authz or Istio policy state;
- traffic behavior changes without gateway/app restart;
- identity spoofing and controller failure tests pass;
- gateway SVIDs come from SPIRE Agent SDS and rotate;
- apps are plain HTTP and SPIFFE-unaware by manifest and runtime inspection;
- NetworkPolicy direct-bypass test passes under the installed CNI;
- docs contain reproducible evidence for all three modes;
- CI is green and the PR clearly lists remaining non-production limitations.

## 12. Review hotspots

Review these areas as security-sensitive:

1. filter order and header overwrite/removal in standalone Envoy;
2. ext-authz failure behavior and timeouts;
3. SPIFFE URI parsing (URL parser, exact trust domain/path, no prefix matching);
4. `AuthorizationPolicy` behavior when the allow list is empty;
5. controller cache synchronization and startup fail-closed behavior;
6. RBAC scope of the controller ServiceAccount;
7. CSI socket exposure and container selectors in `ClusterSPIFFEID`;
8. NetworkPolicy enforcement by the selected CNI;
9. lack of app sidecars and direct-app bypass;
10. secrets/logs/test artifacts for accidental private key material.

## 13. Scheme C implementation

Issue #2 adds `MODE=istio-gateway-api` while preserving the A/B deployment resources and commands.

1. Pin the standard Gateway API bundle in `versions.env` and install it before Istiod.
2. Add `config/istio-gateway-api` and its deployment overlay. Use automated provisioning with a namespace-local customization ConfigMap.
3. Add an independent ClusterSPIFFEID that derives the identity from the actual Pod ServiceAccount.
4. Add HTTPRoutes, restricted ReferenceGrants, outbound DestinationRules, and the independent targetRef baseline.
5. Add `internal/istio_gateway_api` with separate renderer, ownership checks, SSA, and exact readback.
6. Extend the CLI, certificate verifier, structural checks, and dashboard API tests to the third mode.
7. Run all three acceptance suites. Scheme C also checks Gateway/Route conditions and generated resource ownership.
8. Record live results, certificate rotation, deletion recovery, and convergence in `docs/test-evidence.md`.
9. Submit a PR with the three-mode commands, evidence, and B/C trade-offs.

The deployment helper rejects stale condition generations and unexpected ServiceAccount names. The certificate verifier requires the exact URI and a valid chain against the SPIRE bundle. Tests require denied traffic to leave the destination counter unchanged. CI runs each mode in a separate fresh cluster.
