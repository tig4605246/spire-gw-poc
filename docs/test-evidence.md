# POC test evidence

This record separates local cluster tests, image builds, browser checks, and GitHub CI. Measurements are POC data, not production benchmarks.

## Host and versions

The local runs used Linux `6.18.6-061806-generic` on `x86_64`, with 122 GiB of RAM. Docker Server was `29.3.0`. The pinned tools were kind `v0.33.0`, Helm `v3.21.0`, and Istio `1.31.0`.

Both modes use three Kubernetes `v1.34.11` nodes and Cilium `1.19.0`. SPIRE is `1.15.3`, from hardened chart `0.30.2`, with CRD chart `0.6.1`. Container builds use Go `1.26.8`. Local Go unit checks used the installed Go `1.26.1` toolchain.

## Static checks and builds

`make test` passed. It runs Go tests, `go vet`, race tests, shell regression tests, YAML checks, both deployment overlays, and both Envoy configurations.

### PR review regressions

The review fixes passed `make test` on 2026-09-13. These checks include an empty generated Istio rule list and the independent baseline, RBAC, and admission manifests.

Synthetic certificate tests accept a valid SPIRE-issued leaf. They reject an unrelated issuer, incorrect URI, invalid key usage, missing client authentication usage, and expiry. The unrelated-issuer case still fails when the presented certificates also contain the trusted SPIRE CA.

The live Istio suite now includes admission enforcement and generated-policy deletion with controller recovery. It waits for active listener configuration to observe deletion before probing the protected port. Those probes require HTTP 403 and an unchanged destination counter. Historical live results below predate these additions; use the current CI artifacts for the expanded suite.

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

The initial identity check matched SPIRE CA serial `6f2cf934c864fed52eeead62ff0d579a` against Envoy trust-anchor metadata. This historical check did not prove the leaf issuer. PR review identified that gap. The updated verifier performs cryptographic chain verification instead.

At one inspection point, Docker reported about 1.26 GiB for the control-plane node and 0.86–0.91 GiB for each worker. These figures exclude build caches and other host processes.

## Istio: fresh cluster

On 2026-09-13, `make destroy MODE=istio`, `make bootstrap MODE=istio`, and `make e2e MODE=istio` completed successfully. The suite passed all 12 cases, with zero failures and no skipped cases. Local artifacts are in `.state/istio/evidence/20260913T121115-632742/`.

These initial measurements precede the connection-reuse change in ADR 0004. The final CI artifacts contain results for the updated configuration.

The same functional matrix passed with controller-generated Istio authorization. During controller outage, A→B remained allowed and B→A remained denied. The generated policy was visible in Kubernetes and enforced by the destination proxy.

Both proxies reported `SYNCED` for CDS, EDS, LDS, and RDS. The live Pod checks found exactly one regular `istio-proxy` container per gateway, with the SPIRE CSI socket mount. Apps remained plain HTTP workloads with one container.

Both gateway trust-anchor serials matched SPIRE CA serial `6d47213b69820debff200911c4447ddf`. This historical metadata match did not establish a cryptographic relationship to the leaf certificate. It is not leaf-issuer evidence.

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

The [workflow](../.github/workflows/ci.yaml) runs unit, race, generation, manifest, Envoy, multi-architecture build, and all three cluster suites. The [Actions history](https://github.com/tig4605246/spire-gw-poc/actions/workflows/ci.yaml) contains the independent runner results and downloadable e2e evidence.

The first runner check job passed. Its bootstrap jobs exposed a missing `rg` utility on the runner. The bootstrap now uses standard `grep` for that fixed-string assertion.

Later runners exposed an Istio test race after policy changes. A focused local reproduction observed transient 403 responses after an initial successful allow probe. Every successful spoof response had the protected headers removed. The harness now separates traffic convergence from its strict header, denial, and app-counter assertions. Final runner status is available in the linked Actions history.

An independent runner also exposed intermittent Istio denials during controller outage. The local reproduction kept the same AuthorizationPolicy resource version and correct peer SPIFFE identity. Disabling source-gateway connection reuse produced eight successful requests out of eight. Restoring reuse produced three denials out of eight. Both inter-gateway DestinationRules now limit each connection to one request. The outage test checks eight requests, not one. [ADR 0004](adr/0004-bound-istio-gateway-connections.md) records the evidence and performance trade-off.

## Gateway API addition: September 2026

The local host ran `make test` successfully after the Gateway API changes. This includes Go unit, race, and vet checks, shell harness checks, certificate-chain negative cases, current-generation condition checks, and all three manifest overlays. A new Go test applies the real ConfigMap customization with Kubernetes strategic merge. It verifies that the SPIRE socket change preserves Istio's other volumes and mounts.

The initial customization used `$patch: replace` inside the volumes list. Live Istiod logs showed that the generated Deployment lost its required volumes. The corrected patch merges `workload-socket` by name and removes only its `emptyDir` source. Both generated Deployments were accepted after this change. The regression test rejects the original patch.

The local standalone regression passed 12/12 cases. Artifacts are in `.state/standalone/evidence/20260915T235629-3601467/`. Desired-to-applied p50/p95 were 77/80 ms; applied-to-traffic p50/p95 were 60/64 ms.

The local Istio regression could not finish bootstrap after three attempts. A GHCR connection reset prevented the worker's SPIFFE CSI image from downloading. This caused SPIRE rollout timeouts before e2e started. Independent [CI on the initial Gateway API branch](https://github.com/tig4605246/spire-gw-poc/actions/runs/34990197747) passed standalone 12/12 and Istio 14/14. Its Gateway API bootstrap failed; it is not a successful scheme C result.

Local Gateway API bootstrap also needed retries for cold image downloads. The local investigation installed Istio and applied the Gateway resources separately to isolate the merge failure. Its later bootstrap therefore reused those resources. Fresh-cluster reproducibility is evaluated separately by CI.

### Scheme C local acceptance

On 2026-09-16 (Asia/Taipei), bootstrap completed and the full e2e suite passed **15/15**, with no skipped cases. Artifacts are in `.state/istio-gateway-api/evidence/20260916T000415-3652291/`. The host was Linux/amd64. The cluster used Kubernetes 1.34.11, kind 0.33.0, Cilium 1.19.0, SPIRE 1.15.3, Istio 1.31.0, and Gateway API 1.6.0 standard CRDs. The host's kubectl 1.36.1 reported unsupported client/server version skew; these results do not establish support for that skew.

Both `zone-a/zone-gateway` and `zone-b/zone-gateway` had current-generation `Accepted=True` and `Programmed=True`. Each generated Deployment, Service, and ServiceAccount had an owner reference to the exact Gateway UID. Each zone had one Ready proxy Pod, with the specified node selection, labels, and read-only SPIRE CSI mount. All four HTTPRoutes had current-generation `Accepted=True` and `ResolvedRefs=True`.

Both live ServiceAccounts were `zone-gateway-istio`. The served SVID URI SANs were exactly `spiffe://poc.example/ns/zone-a/sa/zone-gateway-istio` and `spiffe://poc.example/ns/zone-b/sa/zone-gateway-istio`. The verifier checked their complete chains against SPIRE's public bundle before and after rotation. It did not use the host CA store.

The suite observed this zone-a renewal without changing Gateway or app Pod UIDs or restart counts:

| Observation | Public leaf serial | Expiry (UTC) |
| --- | --- | --- |
| Before | `FFA71555922CE41DC53ABAF0F1C65713` | `2026-09-15T16:06:29Z` |
| After | `080FDD9836CD9659EA4D42728A966965` | `2026-09-15T16:07:24Z` |

All 20 timing samples used actual dashboard API changes and matching applied generations:

| Interval | p50 | p95 | Samples |
| --- | ---: | ---: | ---: |
| API acceptance → applied status | 396 ms | 413 ms | 20 |
| Applied status → observed traffic | 57 ms | 63 ms | 20 |

The security cases verified independent directions, 403 denials with unchanged app counters, header removal, direct-app NetworkPolicy isolation, and plain HTTP apps. While the controller was stopped, accepted authorization remained active. Deleting the generated policy then produced denial through the independent targetRef baseline. The controller safely recreated its fixed-name policy after recovery. Attempts to modify the baseline or an arbitrary policy name were rejected.

The no-client-certificate case trusted SPIRE's public bundle and observed the TLS `certificate required` alert. Its first version exited OpenSSL at stdin EOF before the TLS 1.3 alert arrived. The corrected probe uses `-ign_eof` with a timeout. Harness tests reject missing alerts and untrusted server chains.

`istioctl analyze --all-namespaces --failure-threshold Error` passed. Its JSON contained only informational notices about uninjected namespaces, existing Service port names, and injection annotations. No analyzer errors or warnings were present.

## Interpretation and limitations

The timing loop measures 20 actual value changes. It first sets the opposite value outside the sample set. The measurements include curl, kubectl, and the test harness.

Istio applied status reports an observed Kubernetes policy write. A separate traffic check measures subsequent xDS propagation. A deleted edge must converge to a destination RBAC 403 before the counter assertion runs.

The Envoy validator reports deprecation notices for accepted fields in the pinned version. Istio reports informational notices for unmeshed namespaces, control-plane Service port names, and injection annotations. Analyzer errors and unsynchronized gateway proxies fail the checks.

The tests do not cover federation, production load, high availability, or long-duration rotation. No private keys or raw certificate dumps are part of this evidence.
