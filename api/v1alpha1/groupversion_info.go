// Package v1alpha1 contains the ZoneTrust Kubernetes API.
// +kubebuilder:object:generate=true
// +groupName=security.poc.example
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

var GroupVersion = schema.GroupVersion{Group: "security.poc.example", Version: "v1alpha1"}

var SchemeBuilder = runtime.NewSchemeBuilder(addKnownTypes)

func AddToScheme(s *runtime.Scheme) error { return SchemeBuilder.AddToScheme(s) }

func addKnownTypes(s *runtime.Scheme) error {
	s.AddKnownTypes(GroupVersion, &ZoneTrust{}, &ZoneTrustList{})
	metav1.AddToGroupVersion(s, GroupVersion)
	return nil
}
