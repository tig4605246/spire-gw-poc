# Use Istio's authenticated principal representation

SPIRE certificates contain full `spiffe://poc.example/ns/<zone>/sa/zone-gateway` URI SANs. Istio's `source.principals` field uses `poc.example/ns/<zone>/sa/zone-gateway`, without the URI scheme, according to the [official reference](https://istio.io/latest/docs/reference/config/security/authorization-policy/#Source).

The controller uses this exact representation for Istio policies. The standalone authorizer still requires the full URI. This corrects the architecture's policy example and preserves exact trust-domain, namespace, and service-account matching.
