# SPIRE zone gateway POC

This repository is the implementation target for a kind-based proof of concept that compares two ways to enforce zone-to-zone workload trust at dedicated Envoy gateways:

- **A — standalone Envoy:** Envoy obtains and rotates its X.509-SVID through the SPIRE Agent SDS API. A small Kubernetes controller is also Envoy's external authorization service.
- **B — Envoy managed by Istio:** Istio programs one Envoy gateway per zone. The controller materializes the same `ZoneTrust` resources as Istio `AuthorizationPolicy` objects.

Both variants preserve the same security boundary:

```text
caller -> source zone gateway == SPIRE mTLS ==> destination zone gateway -> plain HTTP -> app
```

Only gateways mount the SPIFFE CSI socket and handle SPIFFE identities. Application Pods do not have a sidecar, certificate, SPIFFE socket, mTLS code, or SPIFFE library.

## Current status

The architecture and implementation contract are complete. The POC itself is intentionally not implemented on this branch yet.

- [Architecture](docs/architecture.md) — invariants, request paths, identity model, controller/API contract, and the two variants.
- [Implementation plan](docs/implementation-plan.md) — target file tree, ordered work packages, exact verification matrix, and completion criteria.
- [Architecture decisions](docs/adr/0001-zone-trust-control-plane.md) — why zone trust is authorization over an authenticated SPIFFE identity rather than dynamic trust-bundle mutation.
- [Codex handoff](docs/codex-handoff.md) — a concise starting brief for the implementation task.

## Pinned baseline

The design was checked on 2026-09-13 against current upstream releases and documentation.

| Component | Baseline | Role |
|---|---:|---|
| SPIRE | `v1.15.3` | SVID issuance, rotation, node/workload attestation |
| SPIRE hardened Helm chart | `0.30.2` | Server, Agent, CSI driver, controller-manager |
| Envoy | `v1.39.1` | Both variants' gateway data plane |
| Istio | `1.31.0` | Variant B gateway configuration and authorization |
| kind | `v0.33.0` | Local cluster lifecycle |
| Kubernetes node image | `v1.34.1` | Deliberately inside SPIRE's documented Kubernetes quickstart range |

Version pins belong in one `versions.env` file when implementation begins. Image digests should be recorded after the first successful multi-architecture run.

## Upstream design references

- [SPIRE Agent SDS support](https://spiffe.io/docs/latest/deploying/spire_agent/#envoy-sds-support)
- [SPIRE Kubernetes quickstart](https://spiffe.io/docs/latest/try/getting-started-k8s/)
- [SPIRE's Envoy X.509-SVID tutorial](https://spiffe.io/docs/latest/microservices/envoy-x509/readme/)
- [Istio SPIRE integration](https://istio.io/latest/docs/ops/integrations/spire/)
- [Istio Authorization Policy reference](https://istio.io/latest/docs/reference/config/security/authorization-policy/)
- [Envoy external authorization filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_authz_filter)
- [Envoy Lua TLS connection APIs](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/lua_filter.html#ssl-connection-object-api)

## License

Apache-2.0. See [LICENSE](LICENSE).
