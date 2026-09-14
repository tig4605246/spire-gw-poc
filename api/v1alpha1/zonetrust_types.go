package v1alpha1

import (
	"fmt"
	"regexp"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var dnsLabel = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)

const MaxZoneLength = 63

// ZoneTrustSpec describes one directional, authenticated gateway relationship.
// +kubebuilder:validation:XValidation:rule="self.sourceZone != self.destinationZone",message="sourceZone and destinationZone must differ"
type ZoneTrustSpec struct {
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="sourceZone is immutable"
	SourceZone string `json:"sourceZone"`
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="destinationZone is immutable"
	DestinationZone string `json:"destinationZone"`
	// +kubebuilder:validation:Required
	Allowed bool `json:"allowed"`
}

// ZoneTrustStatus reports the last generation made effective by the chosen backend.
type ZoneTrustStatus struct {
	ObservedGeneration int64       `json:"observedGeneration,omitempty"`
	Applied            bool        `json:"applied,omitempty"`
	Backend            string      `json:"backend,omitempty"`
	Message            string      `json:"message,omitempty"`
	LastTransitionTime metav1.Time `json:"lastTransitionTime,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:resource:scope=Cluster,shortName=ztrust
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Source",type=string,JSONPath=`.spec.sourceZone`
// +kubebuilder:printcolumn:name="Destination",type=string,JSONPath=`.spec.destinationZone`
// +kubebuilder:printcolumn:name="Allowed",type=boolean,JSONPath=`.spec.allowed`
// +kubebuilder:printcolumn:name="Applied",type=boolean,JSONPath=`.status.applied`
// +kubebuilder:printcolumn:name="Backend",type=string,JSONPath=`.status.backend`
// +kubebuilder:validation:XValidation:rule="self.metadata.name == self.spec.sourceZone + '-to-' + self.spec.destinationZone",message="metadata.name must equal <sourceZone>-to-<destinationZone>"
type ZoneTrust struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	// +kubebuilder:validation:Required
	Spec   ZoneTrustSpec   `json:"spec"`
	Status ZoneTrustStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type ZoneTrustList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ZoneTrust `json:"items"`
}

func CanonicalName(source, destination string) string { return source + "-to-" + destination }

func ValidateZone(zone string) error {
	if len(zone) == 0 || len(zone) > MaxZoneLength || !dnsLabel.MatchString(zone) {
		return fmt.Errorf("zone %q must be a DNS label", zone)
	}
	return nil
}

func (s ZoneTrustSpec) Validate() error {
	if err := ValidateZone(s.SourceZone); err != nil {
		return fmt.Errorf("sourceZone: %w", err)
	}
	if err := ValidateZone(s.DestinationZone); err != nil {
		return fmt.Errorf("destinationZone: %w", err)
	}
	if s.SourceZone == s.DestinationZone {
		return fmt.Errorf("sourceZone and destinationZone must differ")
	}
	return nil
}

func (z *ZoneTrust) ValidateCanonicalName() error {
	if err := z.Spec.Validate(); err != nil {
		return err
	}
	if z.Name != CanonicalName(z.Spec.SourceZone, z.Spec.DestinationZone) {
		return fmt.Errorf("name must equal %q", CanonicalName(z.Spec.SourceZone, z.Spec.DestinationZone))
	}
	return nil
}
