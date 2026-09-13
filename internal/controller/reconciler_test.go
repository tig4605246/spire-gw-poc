package controller

import (
	"context"
	"errors"
	"testing"

	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
	"github.com/tig4605246/spire-gw-poc/internal/authz"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestMarkAppliedDoesNotAdvanceConcurrentGeneration(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := v1alpha1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	current := &v1alpha1.ZoneTrust{ObjectMeta: metav1.ObjectMeta{Name: "zone-a-to-zone-b", Generation: 8}, Spec: v1alpha1.ZoneTrustSpec{SourceZone: "zone-a", DestinationZone: "zone-b", Allowed: false}}
	client := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&v1alpha1.ZoneTrust{}).WithObjects(current).Build()
	reconciler := &Reconciler{Client: client, APIReader: client, Store: authz.NewStore(0)}
	expected := current.DeepCopy()
	expected.Generation = 7
	expected.Spec.Allowed = true
	err := reconciler.markApplied(context.Background(), *expected, "ext-authz")
	if !errors.Is(err, errGenerationChanged) {
		t.Fatalf("error = %v, want generation change", err)
	}
	var after v1alpha1.ZoneTrust
	if err := client.Get(context.Background(), types.NamespacedName{Name: current.Name}, &after); err != nil {
		t.Fatal(err)
	}
	if after.Status.Applied || after.Status.ObservedGeneration != 0 {
		t.Fatalf("concurrent generation was marked applied: %#v", after.Status)
	}
}
