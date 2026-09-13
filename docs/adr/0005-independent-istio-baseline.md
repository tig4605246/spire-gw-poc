# Keep the Istio authorization baseline independent

Bootstrap owns a gateway baseline `ALLOW` policy that permits only port 8080. The controller owns a separate policy containing only permitted port-8443 edges. Deleting the generated policy therefore preserves denial on the protected port after xDS observes the change.

Server-side apply needs both `patch` and `create` permissions to create an absent object. Kubernetes RBAC cannot restrict `create` by resource name. The controller receives namespace-scoped creation permission, with a validating admission policy that restricts its writes to the generated policy name. Existing-object permissions remain name-scoped. The controller cannot alter the baseline or create another permissive policy.

This protects against loss of the generated policy, not deletion of the baseline by a cluster administrator. Kubernetes acceptance also does not imply immediate proxy convergence. The regression test separates the missing-policy state, denied-edge repair, and restoration of an allowed edge.

Sources: [Kubernetes SSA permissions](https://kubernetes.io/docs/reference/using-api/server-side-apply/#access-control-and-permissions), [Kubernetes admission policies](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/), and [Istio authorization defaults](https://istio.io/latest/docs/concepts/security/#implicit-enablement).
