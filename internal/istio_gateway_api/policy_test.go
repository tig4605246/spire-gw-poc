package istiogatewayapi

import (
	"context"
	"errors"
	"strings"
	"testing"

	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func trust(source, destination string, allowed bool) v1alpha1.ZoneTrust {
	return v1alpha1.ZoneTrust{ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.CanonicalName(source, destination)}, Spec: v1alpha1.ZoneTrustSpec{SourceZone: source, DestinationZone: destination, Allowed: allowed}}
}

func TestRenderTargetsGatewayAPIAndUsesGeneratedServiceAccountPrincipal(t *testing.T) {
	policy, err := Render("zone-b", []v1alpha1.ZoneTrust{
		trust("zone-z", "zone-b", true), trust("zone-a", "zone-b", true), trust("zone-c", "zone-a", true),
	})
	if err != nil {
		t.Fatal(err)
	}
	spec, found, err := unstructured.NestedMap(policy.Object, "spec")
	if err != nil || !found {
		t.Fatalf("policy spec: found=%v err=%v", found, err)
	}
	if _, hasSelector := spec["selector"]; hasSelector {
		t.Fatalf("Gateway API policy must not contain selector: %#v", spec)
	}
	targets := spec["targetRefs"].([]interface{})
	if len(targets) != 1 || !equalMap(targets[0], map[string]interface{}{"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gatewayName}) {
		t.Fatalf("targetRefs = %#v", targets)
	}
	rules := spec["rules"].([]interface{})
	if len(rules) != 2 {
		t.Fatalf("rules = %#v", rules)
	}
	first := rules[0].(map[string]interface{})
	principal := first["from"].([]interface{})[0].(map[string]interface{})["source"].(map[string]interface{})["principals"].([]interface{})[0]
	if principal != "poc.example/ns/zone-a/sa/zone-gateway-istio" {
		t.Fatalf("principal = %v", principal)
	}
	port := first["to"].([]interface{})[0].(map[string]interface{})["operation"].(map[string]interface{})["ports"].([]interface{})[0]
	if port != "8443" {
		t.Fatalf("port = %v", port)
	}
}

func TestRenderNoAllowedTrustsUsesExplicitEmptyRules(t *testing.T) {
	policy, err := Render("zone-b", []v1alpha1.ZoneTrust{trust("zone-a", "zone-b", false)})
	if err != nil {
		t.Fatal(err)
	}
	rules, found, err := unstructured.NestedSlice(policy.Object, "spec", "rules")
	if err != nil || !found || len(rules) != 0 {
		t.Fatalf("rules = %#v found=%v err=%v, want []", rules, found, err)
	}
}

func TestApplyRejectsHandAuthoredCollision(t *testing.T) {
	existing, err := Render("zone-b", nil)
	if err != nil {
		t.Fatal(err)
	}
	existing.SetLabels(map[string]string{"app.kubernetes.io/managed-by": "operator"})
	applicator := Applicator{Client: fakeClient(t, existing)}
	err = applicator.Apply(context.Background(), "zone-b", nil)
	if err == nil || !strings.Contains(err.Error(), "not controller-owned") {
		t.Fatalf("Apply error = %v, want ownership collision", err)
	}
}

func TestApplyReturnsReadbackMismatch(t *testing.T) {
	base := fakeClient(t)
	applicator := Applicator{Client: &mismatchClient{Client: base}}
	err := applicator.Apply(context.Background(), "zone-b", nil)
	if err == nil || !strings.Contains(err.Error(), "does not match rendered policy") {
		t.Fatalf("Apply error = %v, want readback mismatch", err)
	}
}

func TestApplyReturnsServerSideApplyFailure(t *testing.T) {
	base := fakeClient(t)
	applicator := Applicator{Client: patchErrorClient{Client: base}}
	err := applicator.Apply(context.Background(), "zone-b", nil)
	if err == nil || !strings.Contains(err.Error(), "server-side apply AuthorizationPolicy") {
		t.Fatalf("Apply error = %v, want patch failure", err)
	}
}

func equalMap(value interface{}, want map[string]interface{}) bool {
	got, ok := value.(map[string]interface{})
	if !ok || len(got) != len(want) {
		return false
	}
	for key, wanted := range want {
		if got[key] != wanted {
			return false
		}
	}
	return true
}

func fakeClient(t *testing.T, objects ...client.Object) client.Client {
	t.Helper()
	scheme := runtime.NewScheme()
	scheme.AddKnownTypeWithName(authorizationPolicyGVK, &unstructured.Unstructured{})
	scheme.AddKnownTypeWithName(authorizationPolicyGVK.GroupVersion().WithKind("AuthorizationPolicyList"), &unstructured.UnstructuredList{})
	return fake.NewClientBuilder().WithScheme(scheme).WithObjects(objects...).Build()
}

type mismatchClient struct {
	client.Client
	gets int
}

func (c *mismatchClient) Get(ctx context.Context, key client.ObjectKey, obj client.Object, options ...client.GetOption) error {
	err := c.Client.Get(ctx, key, obj, options...)
	c.gets++
	if err == nil && c.gets >= 2 {
		if err := unstructured.SetNestedField(obj.(*unstructured.Unstructured).Object, "DENY", "spec", "action"); err != nil {
			return err
		}
	}
	return err
}

type patchErrorClient struct{ client.Client }

func (patchErrorClient) Patch(context.Context, client.Object, client.Patch, ...client.PatchOption) error {
	return errors.New("apiserver unavailable")
}
