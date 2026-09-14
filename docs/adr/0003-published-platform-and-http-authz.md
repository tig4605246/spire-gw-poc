# Use a published platform and Envoy's HTTP authorization contract

The proposed Kubernetes node tag `v1.34.1` does not exist. Use the published Kubernetes `v1.34.11` image from kind `v0.33.0`, with its digest. Cilium `1.19.0` supports Kubernetes 1.34 and enforces the POC's NetworkPolicy rules. The [upstream research](../upstream-research.md) records the release and compatibility sources.

Envoy's HTTP authorization transport preserves the original HTTP method and appends the request path to `path_prefix`. The authorizer therefore accepts all methods at `/check` and `/check/*` on its private listener. The decision uses only the gateway-derived SPIFFE identity and destination zone. This adapts the planned `POST /check` example to the actual transport without changing the authorization boundary.

Gateway registrations use a 120-second SVID lifetime for the rotation demonstration. The acceptance test waits for a new certificate serial in the running proxy. It does not export keys or depend on a restart to imply rotation.
