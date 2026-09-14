package authz

import (
	"sync"
	"testing"
	"time"

	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func trust(source, destination string, allowed bool) v1alpha1.ZoneTrust {
	return v1alpha1.ZoneTrust{ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.CanonicalName(source, destination)}, Spec: v1alpha1.ZoneTrustSpec{SourceZone: source, DestinationZone: destination, Allowed: allowed}}
}

func TestParseGatewaySPIFFEID(t *testing.T) {
	for _, tc := range []struct {
		in string
		ok bool
	}{
		{"spiffe://poc.example/ns/zone-a/sa/zone-gateway", true},
		{"spiffe://poc.example/ns/zone-a/sa/app", false},
		{"spiffe://other.example/ns/zone-a/sa/zone-gateway", false},
		{"spiffe://poc.example/ns/zone-a/sa/zone-gateway?x=y", false},
	} {
		_, err := ParseGatewaySPIFFEID(tc.in)
		if (err == nil) != tc.ok {
			t.Errorf("%q accepted=%v", tc.in, err == nil)
		}
	}
}

func TestSnapshotDeniesMissingEdge(t *testing.T) {
	now := time.Now()
	snapshot, err := BuildSnapshot([]v1alpha1.ZoneTrust{trust("zone-a", "zone-b", true)}, now)
	if err != nil {
		t.Fatal(err)
	}
	store := NewStore(time.Minute)
	store.Publish(snapshot)
	store.MarkReady()
	if ok, _, _ := store.Check("spiffe://poc.example/ns/zone-b/sa/zone-gateway", "zone-a", now); ok {
		t.Fatal("reverse edge allowed")
	}
	if ok, _, _ := store.Check("spiffe://poc.example/ns/zone-a/sa/zone-gateway", "zone-b", now); !ok {
		t.Fatal("edge denied")
	}
}

func TestStoreConcurrentSnapshots(t *testing.T) {
	store := NewStore(time.Minute)
	store.MarkReady()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < 500; n++ {
				snap, _ := BuildSnapshot([]v1alpha1.ZoneTrust{trust("zone-a", "zone-b", n%2 == 0)}, time.Now())
				store.Publish(snap)
			}
		}()
	}
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < 500; n++ {
				store.Check("spiffe://poc.example/ns/zone-a/sa/zone-gateway", "zone-b", time.Now())
			}
		}()
	}
	wg.Wait()
}
