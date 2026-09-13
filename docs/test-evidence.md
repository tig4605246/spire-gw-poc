# POC test evidence

This record separates local cluster tests, image builds, browser checks, and GitHub CI. Measurements are POC data, not production benchmarks.

## Host and versions

The local runs used Linux `6.18.6-061806-generic` on `x86_64`, with 122 GiB of RAM. Docker Server was `29.3.0`. The pinned tools were kind `v0.33.0`, Helm `v3.21.0`, and Istio `1.31.0`.

Both modes use three Kubernetes `v1.34.11` nodes and Cilium `1.19.0`. SPIRE is `1.15.3`, from hardened chart `0.30.2`, with CRD chart `0.6.1`. Container builds use Go `1.26.8`. Local Go unit checks used the installed Go `1.26.1` toolchain.

## Static checks and builds

`make test` passed. It runs seven Go test functions with table-driven cases, `go vet`, race tests, YAML checks, both deployment overlays, and both Envoy configurations.

`scripts/generate-api.sh` reproduced the checked-in CRD and deepcopy artifacts. Kubernetes also accepted the generated CRD in server-side validation.

Both `zone-trust-controller` and `echo-app` built for `linux/amd64` and `linux/arm64` through Docker Buildx. Runtime cluster tests used `amd64` only.

The builds resolved these upstream image manifests:

| Image | Manifest digest |
| --- | --- |
| `kindest/node:v1.34.11` | `sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d` |
| `envoyproxy/envoy:v1.39.1` | `sha256:57e14a549d7bd43c8d3f6d03e8cfa653e037d4b38e133acd9b54f38c524401b4` |
| `golang:1.26.8` | `sha256:3c3e25a4da13fd0478eed2df1eb35a0e667094a7124d3993a6a1d30f71c17e79` |
| `gcr.io/distroless/static-debian13:nonroot` | `sha256:1c2c046bc09ed40fad370b599a0b1ae7987f55b01e247cf27a7c27cd97e5bbc7` |

## Standalone: fresh cluster

On 2026-09-13, `make destroy MODE=standalone`, `make bootstrap MODE=standalone`, and `make e2e MODE=standalone` completed successfully. Bootstrap took 206.11 seconds on the local host, with some image layers cached.

The suite passed all 12 cases, with zero failures and no skipped cases. Local artifacts are in `.state/standalone/evidence/20260913T120503-568912/`.

The cases cover absent-edge denial, allowed traffic, structural invariants, edge deletion, directionality, live toggles, header spoofing, invalid workloads, direct-app isolation, controller outage/recovery, SVID rotation, and convergence measurements.

Each policy-denied request returned 403 and left the destination app counter unchanged. The outage and direct-app cases separately accepted the expected transport failures. Gateway and app Pod identities and restart counters remained unchanged during toggles and rotation.

| Interval | p50 | p95 | Samples |
| --- | ---: | ---: | ---: |
| API acceptance → applied status | 69 ms | 81 ms | 20 |
| Applied status → observed traffic | 55 ms | 63 ms | 20 |

The rotation check observed these public certificate values in the same running gateway:

| Observation | Serial | Expiry (UTC) |
| --- | --- | --- |
| Before | `de00352d762690df8d772dfef2944c93` | `2026-09-13T04:06:43Z` |
| After | `3aaad06fd830d2b9e3519d28ac0fa788` | `2026-09-13T04:07:33Z` |

A second bootstrap on the existing cluster completed in 36.15 seconds. All four app/gateway Pod UIDs remained unchanged. The allowed edge and its applied generation also remained intact.

The identity check also compared each Envoy trust-anchor serial against the SPIRE Server's public bundle. Both gateways matched SPIRE CA serial `6f2cf934c864fed52eeead62ff0d579a`. This supplements the exact URI SAN and successful mTLS traffic checks with issuer provenance.

At one inspection point, Docker reported about 1.26 GiB for the control-plane node and 0.86–0.91 GiB for each worker. These figures exclude build caches and other host processes.

## Istio: fresh cluster

On 2026-09-13, `make destroy MODE=istio`, `make bootstrap MODE=istio`, and `make e2e MODE=istio` completed successfully. The suite passed all 12 cases, with zero failures and no skipped cases. Local artifacts are in `.state/istio/evidence/20260913T121115-632742/`.

These initial measurements precede the connection-reuse change in ADR 0004. The final CI artifacts contain results for the updated configuration.

The same functional matrix passed with controller-generated Istio authorization. During controller outage, A→B remained allowed and B→A remained denied. The generated policy was visible in Kubernetes and enforced by the destination proxy.

Both proxies reported `SYNCED` for CDS, EDS, LDS, and RDS. The live Pod checks found exactly one regular `istio-proxy` container per gateway, with the SPIRE CSI socket mount. Apps remained plain HTTP workloads with one container.

Both gateway trust-anchor serials matched SPIRE's public CA serial `6d47213b69820debff200911c4447ddf`. This proves the configured trust anchor came from SPIRE, alongside successful mTLS traffic and exact URI SAN checks.

| Interval | p50 | p95 | Samples |
| --- | ---: | ---: | ---: |
| API acceptance → applied status | 413 ms | 416 ms | 20 |
| Applied status → observed traffic | 65 ms | 329 ms | 20 |

The same running gateway exposed these public certificate values:

| Observation | Serial | Expiry (UTC) |
| --- | --- | --- |
| Before | `efbc2fe14fc827f770fd9faaec3beeb3` | `2026-09-13T04:13:04Z` |
| After | `4e6a3ada6c55fbe9b442e8d6a81afe46` | `2026-09-13T04:14:02Z` |

`istioctl analyze --all-namespaces` exited successfully. Its informational notices are listed under limitations.

## Browser

A real Chrome session used the standalone controller through localhost port-forward. Two clicks changed A→B to denied at generation 26, then allowed at generation 27. Kubernetes and the UI showed matching applied generations. No browser errors occurred.

The [dashboard screenshot](images/dashboard.png) shows the live controller state. The browser held no Kubernetes token.

## GitHub CI

The [workflow](../.github/workflows/ci.yaml) runs unit, race, generation, manifest, Envoy, multi-architecture build, and both cluster suites. The [Actions history](https://github.com/tig4605246/spire-gw-poc/actions/workflows/ci.yaml) contains the independent runner results and downloadable e2e evidence.

The first runner check job passed. Its bootstrap jobs exposed a missing `rg` utility on the runner. The bootstrap now uses standard `grep` for that fixed-string assertion.

Later runners exposed an Istio test race after policy changes. A focused local reproduction observed transient 403 responses after an initial successful allow probe. Every successful spoof response had the protected headers removed. The harness now separates traffic convergence from its strict header, denial, and app-counter assertions. Final runner status is available in the linked Actions history.

An independent runner also exposed intermittent Istio denials during controller outage. The local reproduction kept the same AuthorizationPolicy resource version and correct peer SPIFFE identity. Disabling source-gateway connection reuse produced eight successful requests out of eight. Restoring reuse produced three denials out of eight. Both inter-gateway DestinationRules now limit each connection to one request. The outage test checks eight requests, not one. [ADR 0004](adr/0004-bound-istio-gateway-connections.md) records the evidence and performance trade-off.

## Interpretation and limitations

The timing loop measures 20 actual value changes. It first sets the opposite value outside the sample set. The measurements include curl, kubectl, and the test harness.

Istio applied status reports an observed Kubernetes policy write. A separate traffic check measures subsequent xDS propagation. A deleted edge must converge to a destination RBAC 403 before the counter assertion runs.

The Envoy validator reports deprecation notices for accepted fields in the pinned version. Istio reports informational notices for unmeshed namespaces, control-plane Service port names, and injection annotations. Analyzer errors and unsynchronized gateway proxies fail the checks.

The tests do not cover federation, production load, high availability, or long-duration rotation. No private keys or raw certificate dumps are part of this evidence.
