# Codex implementation handoff

Use this file as the starting context for the implementation task on another machine.

## Objective

Implement the kind POC specified in [architecture.md](architecture.md), following the ordered work packages and definition of done in [implementation-plan.md](implementation-plan.md).

Two independently deployable modes are required:

1. `standalone`: one standalone Envoy gateway per zone, SPIRE Agent SDS for both client/server SVIDs, destination peer URI SAN extraction inside Envoy, and fail-closed ext-authz against the `ZoneTrust` controller.
2. `istio`: one Istio-managed Envoy gateway per zone, SPIRE Agent SDS through the official Istio integration, and controller-generated Istio `AuthorizationPolicy` from the same `ZoneTrust` CRs.

In both modes the app is plain HTTP, has no sidecar/CSI/SPIFFE code, and is reachable cross-zone only through its local gateway.

## First actions

1. Read all repository docs and `AGENTS.md` if one exists.
2. Confirm current official component releases before changing pins. If newer versions are selected, explain compatibility and update the README/version file together.
3. Check the branch/worktree and preserve unrelated changes.
4. Implement work packages in order with focused commits.
5. Run both complete bootstrap/e2e workflows on a clean cluster before opening the PR.

## Non-negotiable choices

- `ZoneTrust` is authorization over an authenticated SPIFFE identity; do not mutate root bundles for dashboard toggles.
- Use PSAT, SPIFFE CSI, SPIRE Controller Manager registration, and Agent SDS. Do not write private keys to Kubernetes objects or disk.
- Trust is directional and absent/deleted edges deny.
- A browser toggle writes the CR and the UI distinguishes desired from applied generation.
- Standalone identity headers are produced from Envoy's validated TLS connection, never caller input.
- Istio policies match exact `source.principals` on protected port 8443.
- Controller/cache/authz failure is fail-closed where the decision cannot be proven.
- NetworkPolicy must prevent direct app bypass and must be tested with a CNI that enforces it.

## Suggested implementation prompt

> Implement this repository's SPIRE zone gateway POC. Treat `docs/architecture.md` as the architecture contract and `docs/implementation-plan.md` as the execution/acceptance plan. Complete both `standalone` and `istio` modes, run all feasible tests on clean kind clusters, make focused commits, push the feature branch, and open a PR to the default branch with architecture, commands, exact test evidence, and known limitations. If an upstream API differs from the design, verify current official documentation, record the decision in an ADR, and preserve the security invariants.

## Official references to keep open

- https://spiffe.io/docs/latest/deploying/spire_agent/#envoy-sds-support
- https://spiffe.io/docs/latest/try/getting-started-k8s/
- https://spiffe.io/docs/latest/microservices/envoy-x509/readme/
- https://istio.io/latest/docs/ops/integrations/spire/
- https://istio.io/latest/docs/reference/config/security/authorization-policy/
- https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_authz_filter
- https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/lua_filter.html#ssl-connection-object-api
