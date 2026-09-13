# Bound Istio gateway connections during policy changes

Set `connectionPool.http.maxRequestsPerConnection: 1` on both inter-gateway DestinationRules, only for port 8443. This disables HTTP connection reuse between the Istio gateways. It prevents the intermittent authorization results reproduced with reused connections during rapid policy changes.

The failing request had the correct SPIFFE peer identity. The generated AuthorizationPolicy remained unchanged and allowed that identity. With connection reuse disabled, all eight post-controller-shutdown requests succeeded. Restoring the original setting caused three of eight requests to return 403. This identifies connection reuse as the relevant variable; it does not prove an internal Envoy defect.

Istio documents that this setting disables keep-alive in its [DestinationRule reference](https://istio.io/latest/docs/reference/config/networking/destination-rule/#ConnectionPoolSettings-HTTPSettings). Envoy documents connection-local filter state and listener draining in its [LDS reference](https://www.envoyproxy.io/docs/envoy/latest/configuration/listeners/lds.html). Retained connection state during listener changes is consistent with the observed behavior.

This POC accepts additional connection and TLS setup costs to demonstrate live policy changes reliably. It is not a production throughput configuration. The setting does not disable mTLS, relax exact-principal checks, or replace the measured xDS convergence interval. Standalone ext-authz still checks each protected request and does not need this setting.
