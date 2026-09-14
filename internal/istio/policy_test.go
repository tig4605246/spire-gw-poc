package istio

import (
	"testing"

	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func zt(source, destination string, allowed bool) v1alpha1.ZoneTrust {
	return v1alpha1.ZoneTrust{ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.CanonicalName(source, destination)}, Spec: v1alpha1.ZoneTrustSpec{SourceZone: source, DestinationZone: destination, Allowed: allowed}}
}

func TestRenderStableExactPrincipals(t *testing.T) {
	policy, err := Render("zone-b", []v1alpha1.ZoneTrust{zt("zone-z", "zone-b", true), zt("zone-a", "zone-b", true), zt("zone-c", "zone-a", true)})
	if err != nil {
		t.Fatal(err)
	}
	rules, found, err := unstructured.NestedSlice(policy.Object, "spec", "rules")
	if err != nil || !found || len(rules) != 2 {
		t.Fatalf("rules: %v %v %d", err, found, len(rules))
	}
	first := rules[0].(map[string]interface{})
	from := first["from"].([]interface{})[0].(map[string]interface{})
	got := from["source"].(map[string]interface{})["principals"].([]interface{})
	if len(got) != 1 || got[0] != "poc.example/ns/zone-a/sa/zone-gateway" {
		t.Fatalf("unexpected first principal: %#v", got)
	}
}

// With no allowed incoming edge the dynamic policy must select the gateway but
// contain no ALLOW rules.  The independently managed bootstrap policy owns the
// public 8080 entrypoint; retaining it here would make deletion of this policy
// fail open for protected 8443 traffic.
func TestRenderNoAllowedTrustsHasNoRules(t *testing.T) {
	policy, err := Render("zone-b", []v1alpha1.ZoneTrust{zt("zone-a", "zone-b", false)})
	if err != nil {
		t.Fatal(err)
	}
	rules, found, err := unstructured.NestedSlice(policy.Object, "spec", "rules")
	if err != nil {
		t.Fatal(err)
	}
	if !found || len(rules) != 0 {
		t.Fatalf("dynamic deny-all policy rules = %#v, want empty list", rules)
	}
}
