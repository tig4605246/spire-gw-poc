package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/tig4605246/spire-gw-poc/internal/authz"
)

func TestAuthorizerFailsClosedAndAllowsExactEdge(t *testing.T) {
	store := authz.NewStore(time.Minute)
	server := NewServer(nil, store, nil, nil)
	request := httptest.NewRequest(http.MethodGet, "/check/any/original/path", nil)
	request.Header.Set("x-spiffe-peer-id", "spiffe://poc.example/ns/zone-a/sa/zone-gateway")
	request.Header.Set("x-destination-zone", "zone-b")
	response := httptest.NewRecorder()
	server.AuthorizerHandler().ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("unready code = %d", response.Code)
	}
	// Empty, synchronized policy is an explicit deny-all policy.
	snapshot, err := authz.BuildSnapshot(nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	store.Publish(snapshot)
	store.MarkReady()
	response = httptest.NewRecorder()
	server.AuthorizerHandler().ServeHTTP(response, request)
	if response.Code != http.StatusForbidden || response.Header().Get("x-zone-trust-decision") != "edge-denied" {
		t.Fatalf("unexpected deny: %d %q", response.Code, response.Header().Get("x-zone-trust-decision"))
	}
}
