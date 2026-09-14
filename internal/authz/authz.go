// Package authz validates gateway SPIFFE identities and serves immutable policy snapshots.
package authz

import (
	"fmt"
	"net/url"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
)

const TrustDomain = "poc.example"
const GatewayServiceAccount = "zone-gateway"

type Snapshot struct {
	edges     map[string]struct{}
	refreshed time.Time
}

func (s *Snapshot) Allows(source, destination string) bool {
	if s == nil {
		return false
	}
	_, ok := s.edges[edgeKey(source, destination)]
	return ok
}
func (s *Snapshot) RefreshedAt() time.Time {
	if s == nil {
		return time.Time{}
	}
	return s.refreshed
}

func edgeKey(source, destination string) string { return source + "\x00" + destination }

// BuildSnapshot accepts only valid, explicitly-allowed edges. The returned object is never mutated.
func BuildSnapshot(trusts []v1alpha1.ZoneTrust, now time.Time) (*Snapshot, error) {
	edges := make(map[string]struct{}, len(trusts))
	for _, trust := range trusts {
		if err := trust.ValidateCanonicalName(); err != nil {
			return nil, fmt.Errorf("invalid ZoneTrust %q: %w", trust.Name, err)
		}
		if trust.Spec.Allowed {
			edges[edgeKey(trust.Spec.SourceZone, trust.Spec.DestinationZone)] = struct{}{}
		}
	}
	return &Snapshot{edges: edges, refreshed: now.UTC()}, nil
}

type Store struct {
	snapshot atomic.Pointer[Snapshot]
	ready    atomic.Bool
	maxAge   time.Duration
}

func NewStore(maxAge time.Duration) *Store {
	if maxAge <= 0 {
		maxAge = 30 * time.Second
	}
	s := &Store{maxAge: maxAge}
	s.snapshot.Store(&Snapshot{edges: map[string]struct{}{}})
	return s
}
func (s *Store) Publish(snapshot *Snapshot) {
	if snapshot == nil {
		snapshot = &Snapshot{edges: map[string]struct{}{}}
	}
	s.snapshot.Store(snapshot)
}
func (s *Store) MarkReady()          { s.ready.Store(true) }
func (s *Store) MarkUnready()        { s.ready.Store(false) }
func (s *Store) Ready() bool         { return s.ready.Load() }
func (s *Store) Snapshot() *Snapshot { return s.snapshot.Load() }

func (s *Store) Check(peerURI, destination string, now time.Time) (allowed bool, source string, reason string) {
	if !s.Ready() {
		return false, "", "policy-cache-not-ready"
	}
	source, err := ParseGatewaySPIFFEID(peerURI)
	if err != nil {
		return false, "", "invalid-peer-spiffe-id"
	}
	if err := v1alpha1.ValidateZone(destination); err != nil {
		return false, source, "invalid-destination-zone"
	}
	snapshot := s.Snapshot()
	if snapshot == nil || now.Sub(snapshot.RefreshedAt()) > s.maxAge {
		return false, source, "policy-snapshot-stale"
	}
	if !snapshot.Allows(source, destination) {
		return false, source, "edge-denied"
	}
	return true, source, "edge-allowed"
}

// ParseGatewaySPIFFEID accepts precisely the gateway SVID form used by standalone Envoy.
func ParseGatewaySPIFFEID(raw string) (string, error) {
	// A certificate URI SAN is an identifier, not a URL carrying query/fragment
	// semantics. Reject even empty `?` and `#` delimiters before url.Parse loses
	// that distinction.
	if strings.ContainsAny(raw, "?#") {
		return "", fmt.Errorf("SPIFFE URI must not contain query or fragment")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "spiffe" || u.Host != TrustDomain || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		return "", fmt.Errorf("not a valid %s SPIFFE URI", TrustDomain)
	}
	if u.EscapedPath() != u.Path {
		return "", fmt.Errorf("SPIFFE path must not use escaping")
	}
	parts := strings.Split(strings.TrimPrefix(u.Path, "/"), "/")
	if len(parts) != 4 || parts[0] != "ns" || parts[2] != "sa" || parts[3] != GatewayServiceAccount {
		return "", fmt.Errorf("not a gateway SPIFFE ID")
	}
	if err := v1alpha1.ValidateZone(parts[1]); err != nil {
		return "", err
	}
	return parts[1], nil
}

func SortedAllowedEdges(trusts []v1alpha1.ZoneTrust) []v1alpha1.ZoneTrust {
	result := make([]v1alpha1.ZoneTrust, 0, len(trusts))
	for _, trust := range trusts {
		if trust.Spec.Allowed {
			result = append(result, *trust.DeepCopy())
		}
	}
	sort.Slice(result, func(i, j int) bool {
		return edgeKey(result[i].Spec.SourceZone, result[i].Spec.DestinationZone) < edgeKey(result[j].Spec.SourceZone, result[j].Spec.DestinationZone)
	})
	return result
}
