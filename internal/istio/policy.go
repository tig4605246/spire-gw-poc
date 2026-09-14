// Package istio renders and applies the controller-owned AuthorizationPolicy.
package istio

import (
	"context"
	"fmt"
	"reflect"
	"sort"

	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	GeneratedPolicyName = "zone-trust-generated"
	FieldManager        = "zone-trust-controller"
)

var authorizationPolicyGVK = schema.GroupVersionKind{Group: "security.istio.io", Version: "v1", Kind: "AuthorizationPolicy"}

// Principal is deliberately the Istio source.principal spelling, without spiffe://.
// Istio's policy API represents a SPIFFE principal as trust-domain/ns/namespace/sa/serviceaccount.
func Principal(sourceZone string) string { return "poc.example/ns/" + sourceZone + "/sa/zone-gateway" }

// Render returns the dynamic AuthorizationPolicy owned for destinationZone.
// The independent bootstrap policy owns the public 8080 call entrypoint. This
// policy therefore controls only protected 8443 cross-zone traffic: an empty
// rules list is an explicit deny-all until an allowed incoming edge exists.
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
		"metadata": map[string]interface{}{"name": GeneratedPolicyName, "namespace": destinationZone, "labels": map[string]interface{}{
			"app.kubernetes.io/managed-by": "zone-trust-controller", "security.poc.example/destination-zone": destinationZone,
		}},
		"spec": map[string]interface{}{
			"selector": map[string]interface{}{"matchLabels": map[string]interface{}{"app.kubernetes.io/component": "zone-gateway", "security.poc.example/zone": destinationZone}},
			"action":   "ALLOW", "rules": rules,
		},
	}}
	policy.SetGroupVersionKind(authorizationPolicyGVK)
	return policy, nil
}

type Applicator struct{ Client client.Client }

func (a Applicator) Apply(ctx context.Context, destinationZone string, trusts []v1alpha1.ZoneTrust) error {
	if a.Client == nil {
		return fmt.Errorf("Istio policy client is nil")
	}
	policy, err := Render(destinationZone, trusts)
	if err != nil {
		return err
	}
	// Never take over a hand-authored policy with our well-known name. This check
	// makes accidental resource-name collision an explicit, fail-closed error.
	existing := &unstructured.Unstructured{}
	existing.SetGroupVersionKind(authorizationPolicyGVK)
	err = a.Client.Get(ctx, client.ObjectKey{Namespace: destinationZone, Name: GeneratedPolicyName}, existing)
	if err == nil && existing.GetLabels()["app.kubernetes.io/managed-by"] != "zone-trust-controller" {
		return fmt.Errorf("AuthorizationPolicy %s/%s exists but is not controller-owned", destinationZone, GeneratedPolicyName)
	}
	if err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("read existing AuthorizationPolicy: %w", err)
	}
	if err := a.Client.Patch(ctx, policy, client.Apply, client.FieldOwner(FieldManager), client.ForceOwnership); err != nil {
		return fmt.Errorf("server-side apply AuthorizationPolicy: %w", err)
	}
	// Do not report a ZoneTrust generation as applied merely because the PATCH was
	// accepted. A direct read confirms that the desired policy is observable with
	// the exact rendered spec before the reconciler advances status.
	observed := &unstructured.Unstructured{}
	observed.SetGroupVersionKind(authorizationPolicyGVK)
	if err := a.Client.Get(ctx, client.ObjectKey{Namespace: destinationZone, Name: GeneratedPolicyName}, observed); err != nil {
		return fmt.Errorf("observe applied AuthorizationPolicy: %w", err)
	}
	expectedSpec, _, err := unstructured.NestedMap(policy.Object, "spec")
	if err != nil {
		return fmt.Errorf("read rendered AuthorizationPolicy spec: %w", err)
	}
	observedSpec, found, err := unstructured.NestedMap(observed.Object, "spec")
	if err != nil || !found || !reflect.DeepEqual(expectedSpec, observedSpec) {
		return fmt.Errorf("observed AuthorizationPolicy %s/%s does not match rendered policy", destinationZone, GeneratedPolicyName)
	}
	return nil
}
