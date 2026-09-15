// Package istiogatewayapi renders and applies the controller-owned
// AuthorizationPolicy for Kubernetes Gateway API gateways.
package istiogatewayapi

import (
	"context"
	"fmt"
	"reflect"
	"sort"

	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
	"github.com/tig4605246/spire-gw-poc/internal/istio"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const gatewayName = "zone-gateway"

var authorizationPolicyGVK = schema.GroupVersionKind{Group: "security.istio.io", Version: "v1", Kind: "AuthorizationPolicy"}

// Principal is Istio's source.principal spelling for the ServiceAccount that
// Istio's automated Gateway API deployment creates for each zone Gateway.
// It deliberately omits the spiffe:// URI scheme.
func Principal(sourceZone string) string {
	return "poc.example/ns/" + sourceZone + "/sa/zone-gateway-istio"
}

// Render returns the dynamic 8443 policy for a same-namespace Kubernetes
// Gateway API Gateway. The independently managed baseline owns local 8080;
// empty rules are therefore an explicit protected-port deny-all.
func Render(destinationZone string, trusts []v1alpha1.ZoneTrust) (*unstructured.Unstructured, error) {
	if err := v1alpha1.ValidateZone(destinationZone); err != nil {
		return nil, err
	}
	allowed := make([]v1alpha1.ZoneTrust, 0, len(trusts))
	for _, trust := range trusts {
		if err := trust.ValidateCanonicalName(); err != nil {
			return nil, err
		}
		if trust.Spec.DestinationZone == destinationZone && trust.Spec.Allowed {
			allowed = append(allowed, trust)
		}
	}
	sort.Slice(allowed, func(i, j int) bool { return allowed[i].Spec.SourceZone < allowed[j].Spec.SourceZone })
	rules := make([]interface{}, 0, len(allowed))
	for _, trust := range allowed {
		rules = append(rules, map[string]interface{}{
			"from": []interface{}{map[string]interface{}{"source": map[string]interface{}{"principals": []interface{}{Principal(trust.Spec.SourceZone)}}}},
			"to":   []interface{}{map[string]interface{}{"operation": map[string]interface{}{"ports": []interface{}{"8443"}}}},
		})
	}
	policy := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "security.istio.io/v1", "kind": "AuthorizationPolicy",
		"metadata": map[string]interface{}{"name": istio.GeneratedPolicyName, "namespace": destinationZone, "labels": map[string]interface{}{
			"app.kubernetes.io/managed-by": "zone-trust-controller", "security.poc.example/destination-zone": destinationZone,
		}},
		"spec": map[string]interface{}{
			"targetRefs": []interface{}{map[string]interface{}{"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gatewayName}},
			"action":     "ALLOW",
			"rules":      rules,
		},
	}}
	policy.SetGroupVersionKind(authorizationPolicyGVK)
	return policy, nil
}

// Applicator owns only the fixed generated policy. It protects a name collision
// before SSA, then directly reads the object back before reconciliation may
// advance ZoneTrust status.
type Applicator struct{ Client client.Client }

func (a Applicator) Apply(ctx context.Context, destinationZone string, trusts []v1alpha1.ZoneTrust) error {
	if a.Client == nil {
		return fmt.Errorf("Istio Gateway API policy client is nil")
	}
	policy, err := Render(destinationZone, trusts)
	if err != nil {
		return err
	}
	existing := &unstructured.Unstructured{}
	existing.SetGroupVersionKind(authorizationPolicyGVK)
	err = a.Client.Get(ctx, client.ObjectKey{Namespace: destinationZone, Name: istio.GeneratedPolicyName}, existing)
	if err == nil && existing.GetLabels()["app.kubernetes.io/managed-by"] != "zone-trust-controller" {
		return fmt.Errorf("AuthorizationPolicy %s/%s exists but is not controller-owned", destinationZone, istio.GeneratedPolicyName)
	}
	if err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("read existing AuthorizationPolicy: %w", err)
	}
	if err := a.Client.Patch(ctx, policy, client.Apply, client.FieldOwner(istio.FieldManager), client.ForceOwnership); err != nil {
		return fmt.Errorf("server-side apply AuthorizationPolicy: %w", err)
	}
	observed := &unstructured.Unstructured{}
	observed.SetGroupVersionKind(authorizationPolicyGVK)
	if err := a.Client.Get(ctx, client.ObjectKey{Namespace: destinationZone, Name: istio.GeneratedPolicyName}, observed); err != nil {
		return fmt.Errorf("observe applied AuthorizationPolicy: %w", err)
	}
	expectedSpec, _, err := unstructured.NestedMap(policy.Object, "spec")
	if err != nil {
		return fmt.Errorf("read rendered AuthorizationPolicy spec: %w", err)
	}
	observedSpec, found, err := unstructured.NestedMap(observed.Object, "spec")
	if err != nil || !found || !reflect.DeepEqual(expectedSpec, observedSpec) {
		return fmt.Errorf("observed AuthorizationPolicy %s/%s does not match rendered policy", destinationZone, istio.GeneratedPolicyName)
	}
	return nil
}
