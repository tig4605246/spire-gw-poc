package controller

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
	"github.com/tig4605246/spire-gw-poc/internal/authz"
	istiogatewayapi "github.com/tig4605246/spire-gw-poc/internal/istio_gateway_api"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
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

func TestRefreshGatewayAPIAppliesPolicyAndRecordsBackend(t *testing.T) {
	zoneTrust := &v1alpha1.ZoneTrust{
		ObjectMeta: metav1.ObjectMeta{Name: "zone-a-to-zone-b", Generation: 4},
		Spec:       v1alpha1.ZoneTrustSpec{SourceZone: "zone-a", DestinationZone: "zone-b", Allowed: true},
	}
	reconciler, kubeClient := newGatewayAPIReconciler(t,
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "zone-b", Labels: map[string]string{ZoneLabel: "true"}}},
		zoneTrust,
	)
	if err := reconciler.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	var status v1alpha1.ZoneTrust
	if err := kubeClient.Get(context.Background(), types.NamespacedName{Name: zoneTrust.Name}, &status); err != nil {
		t.Fatal(err)
	}
	if !status.Status.Applied || status.Status.ObservedGeneration != zoneTrust.Generation || status.Status.Backend != "istio-gateway-api-authorization-policy" {
		t.Fatalf("status = %#v", status.Status)
	}
	policy := &unstructured.Unstructured{}
	policy.SetGroupVersionKind(gatewayAPIAuthorizationPolicyGVK)
	if err := kubeClient.Get(context.Background(), types.NamespacedName{Namespace: "zone-b", Name: "zone-trust-generated"}, policy); err != nil {
		t.Fatal(err)
	}
	targets, found, err := unstructured.NestedSlice(policy.Object, "spec", "targetRefs")
	if err != nil || !found || len(targets) != 1 {
		t.Fatalf("targetRefs = %#v, found=%v, err=%v", targets, found, err)
	}
	target := targets[0].(map[string]interface{})
	if target["group"] != "gateway.networking.k8s.io" || target["kind"] != "Gateway" || target["name"] != "zone-gateway" {
		t.Fatalf("targetRef = %#v", target)
	}
}

func TestRefreshGatewayAPIRecordsApplyFailure(t *testing.T) {
	zoneTrust := &v1alpha1.ZoneTrust{
		ObjectMeta: metav1.ObjectMeta{Name: "zone-a-to-zone-b", Generation: 4},
		Spec:       v1alpha1.ZoneTrustSpec{SourceZone: "zone-a", DestinationZone: "zone-b", Allowed: true},
	}
	reconciler, kubeClient := newGatewayAPIReconciler(t,
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "zone-b", Labels: map[string]string{ZoneLabel: "true"}}},
		zoneTrust,
	)
	reconciler.IstioGatewayAPI.Client = applyFailureClient{Client: kubeClient}
	err := reconciler.Refresh(context.Background())
	if err == nil || !strings.Contains(err.Error(), "server-side apply AuthorizationPolicy") {
		t.Fatalf("Refresh error = %v, want apply failure", err)
	}
	var status v1alpha1.ZoneTrust
	if err := kubeClient.Get(context.Background(), types.NamespacedName{Name: zoneTrust.Name}, &status); err != nil {
		t.Fatal(err)
	}
	if status.Status.Applied || status.Status.ObservedGeneration != zoneTrust.Generation || status.Status.Backend != "istio-gateway-api-authorization-policy" || !strings.Contains(status.Status.Message, "reconcile failed") {
		t.Fatalf("status = %#v", status.Status)
	}
}

var gatewayAPIAuthorizationPolicyGVK = schema.GroupVersionKind{Group: "security.istio.io", Version: "v1", Kind: "AuthorizationPolicy"}

func newGatewayAPIReconciler(t *testing.T, objects ...client.Object) (*Reconciler, client.Client) {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := v1alpha1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	if err := corev1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	scheme.AddKnownTypeWithName(gatewayAPIAuthorizationPolicyGVK, &unstructured.Unstructured{})
	scheme.AddKnownTypeWithName(gatewayAPIAuthorizationPolicyGVK.GroupVersion().WithKind("AuthorizationPolicyList"), &unstructured.UnstructuredList{})
	kubeClient := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&v1alpha1.ZoneTrust{}).WithObjects(objects...).Build()
	return &Reconciler{
		Client:          kubeClient,
		APIReader:       kubeClient,
		Backend:         BackendIstioGatewayAPI,
		Store:           authz.NewStore(0),
		IstioGatewayAPI: istiogatewayapi.Applicator{Client: kubeClient},
		Metrics:         NewMetrics(prometheus.NewRegistry()),
	}, kubeClient
}

type applyFailureClient struct{ client.Client }

func (applyFailureClient) Patch(context.Context, client.Object, client.Patch, ...client.PatchOption) error {
	return errors.New("apiserver unavailable")
}
