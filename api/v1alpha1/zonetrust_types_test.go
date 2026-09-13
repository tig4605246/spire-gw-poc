package v1alpha1

import "testing"

func TestCanonicalValidation(t *testing.T) {
	valid := ZoneTrustSpec{SourceZone: "zone-a", DestinationZone: "zone-b"}
	if err := valid.Validate(); err != nil {
		t.Fatal(err)
	}
	if got, want := CanonicalName("zone-a", "zone-b"), "zone-a-to-zone-b"; got != want {
		t.Fatalf("name = %q, want %q", got, want)
	}
	for _, spec := range []ZoneTrustSpec{{SourceZone: "zone-a", DestinationZone: "zone-a"}, {SourceZone: "Zone-A", DestinationZone: "zone-b"}, {SourceZone: "", DestinationZone: "zone-b"}} {
		if err := spec.Validate(); err == nil {
			t.Errorf("invalid spec %#v accepted", spec)
		}
	}
}
