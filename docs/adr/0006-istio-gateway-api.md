# Add a separate Istio Gateway API mode

Scheme C uses Kubernetes Gateway API to compare routing, resource lifecycle, and policy attachment with the existing schemes. It remains a separate mode because scheme B provides the Istio API comparison. Both modes use the same ZoneTrust contract and plain HTTP applications.

Istio automatically provisions one Gateway per zone. A namespace-local ConfigMap customizes its generated Deployment through the supported strategic merge interface. Automated gateways disable injection, so the existing SPIRE injection template cannot add their socket. The patch merges the existing `workload-socket` volume by name, clears its `emptyDir`, and adds SPIRE CSI. It does not use `$patch: replace`, because that would replace the full volumes list and remove Istio's required volumes. The patch also adds a read-only mount. An init container waits for the socket. Bootstrap then checks workload readiness and verifies the served SVID. No manual deployment fallback is required by the implementation.

HTTPRoute controls routing. DestinationRule retains outbound `ISTIO_MUTUAL`, exact destination SVID matching, and one request per connection. The routing resources are more portable, but these TLS and SPIRE details remain specific to Istio. The existing connection-lifetime decision still applies.

A bootstrap-owned AuthorizationPolicy targets the local Gateway and permits only 8080. The controller owns a separate targetRef policy for allowed 8443 principals. After xDS observes deletion of that policy, the baseline denies protected traffic. Namespace RBAC and admission permit recreation of only the fixed generated policy name. The controller cannot modify the baseline.

The generated ServiceAccount is part of the identity contract. The ClusterSPIFFEID derives its URI and workload selector from the actual Pod ServiceAccount. Bootstrap and e2e check that the account matches the policy and DestinationRule expectations. A mismatch fails verification instead of silently accepting another identity.

[Pinned API and implementation references](../gateway-api-research.md) describe the supported customization, TLS extension, and policy attachment.
