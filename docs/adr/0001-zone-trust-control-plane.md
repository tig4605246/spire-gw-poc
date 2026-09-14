# ADR 0001: Model zone trust as authorization over SPIFFE authentication

- Status: accepted
- Date: 2026-09-13

## Context

The dashboard must change directional trust between zones in real time. Gateways use SPIRE-issued identities and all current POC zones live in one Kubernetes cluster.

SPIFFE trust bundles answer whether an X.509-SVID chains to a trusted authority. They do not express a directional relationship such as "zone A may call zone B, but B may not call A." Replacing trust bundles on every dashboard toggle would affect every identity in the trust domain and couple a fast-changing connectivity rule to CA distribution.

## Decision

Use a single SPIFFE trust domain, `poc.example`, for the POC. The destination gateway always performs cryptographic peer authentication. It then enforces the directional `ZoneTrust` authorization edge against the authenticated peer SPIFFE ID.

- Standalone Envoy extracts the URI SAN and invokes the controller through fail-closed ext-authz.
- Istio-managed Envoy evaluates controller-generated `AuthorizationPolicy` rules using the authenticated `source.principal`.

The Kubernetes `ZoneTrust` CRD is the only desired-state API. Dashboard state is never authoritative by itself.

## Consequences

Positive:

- toggles converge without certificate reissuance or bundle mutation;
- both variants share one user-facing policy model;
- policies are directional, inspectable, auditable, and easy to test;
- SPIRE remains responsible only for attested identity and rotation.

Trade-offs:

- a single trust domain does not demonstrate federation;
- standalone Envoy adds an authorization service call to each protected request;
- Istio has an additional Kubernetes/Istiod propagation hop.

## Rejected alternatives

### Dynamically add/remove SPIRE federated bundles

Rejected because zones are not separate trust domains in this POC and federation is too coarse for per-edge authorization. Bundle rotation is also a poor real-time switch.

### Let applications evaluate `ZoneTrust`

Rejected because it violates the requirement that applications remain unaware of SPIFFE/SPIRE and would duplicate security code.

### Trust a caller-supplied zone header

Rejected because it is spoofable. Identity must originate from a validated mTLS connection.

### Restart Envoy after ConfigMap updates

Rejected because it makes toggles slow and disruptive and does not demonstrate a live policy control plane.

### Build a custom full xDS control plane for both variants

Rejected for this POC. Ext-authz is a standard Envoy enforcement point with a much smaller custom surface, while Istio already supplies the xDS control plane in variant B.
