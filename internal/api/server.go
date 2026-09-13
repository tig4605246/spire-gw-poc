// Package api exposes the dashboard API and the fail-closed HTTP ext-authz endpoint.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
	"github.com/tig4605246/spire-gw-poc/internal/authz"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const zoneLabel = "security.poc.example/zone"
const apiRequestTimeout = 5 * time.Second

type Metrics interface {
	ObserveCheck(source, destination, decision string, elapsed time.Duration)
}

type Server struct {
	Client  client.Client // deliberately direct/uncached for browser mutations and reads
	Store   *authz.Store
	UI      http.Handler
	Metrics Metrics
	broker  *broker
}

func NewServer(c client.Client, store *authz.Store, ui http.Handler, metrics Metrics) *Server {
	return &Server{Client: c, Store: store, UI: ui, Metrics: metrics, broker: newBroker()}
}

func (s *Server) DashboardHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/zones", s.zones)
	mux.HandleFunc("/api/v1/trusts", s.trusts)
	mux.HandleFunc("/api/v1/trusts/", s.trust)
	mux.HandleFunc("/api/v1/events", s.events)
	if s.UI != nil {
		mux.Handle("/", s.UI)
	} else {
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	}
	return requestLimit(mux)
}

func (s *Server) AuthorizerHandler() http.Handler { return requestLimit(http.HandlerFunc(s.check)) }

type zoneResponse struct {
	Name         string `json:"name"`
	GatewayReady bool   `json:"gatewayReady"`
}

func (s *Server) zones(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	ctx, cancel := apiContext(r.Context())
	defer cancel()
	var namespaces corev1.NamespaceList
	if err := s.Client.List(ctx, &namespaces, client.MatchingLabels{zoneLabel: "true"}); err != nil {
		serviceUnavailable(w, err)
		return
	}
	var pods corev1.PodList
	if err := s.Client.List(ctx, &pods, client.MatchingLabels{"app.kubernetes.io/component": "zone-gateway"}); err != nil {
		serviceUnavailable(w, err)
		return
	}
	ready := map[string]bool{}
	for _, pod := range pods.Items {
		if pod.Status.Phase == corev1.PodRunning && podReady(pod) {
			ready[pod.Namespace] = true
		}
	}
	result := make([]zoneResponse, 0, len(namespaces.Items))
	for _, namespace := range namespaces.Items {
		result = append(result, zoneResponse{Name: namespace.Name, GatewayReady: ready[namespace.Name]})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	writeJSON(w, http.StatusOK, map[string]any{"zones": result})
}

func podReady(pod corev1.Pod) bool {
	for _, condition := range pod.Status.Conditions {
		if condition.Type == corev1.PodReady {
			return condition.Status == corev1.ConditionTrue
		}
	}
	return false
}

func (s *Server) trusts(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	ctx, cancel := apiContext(r.Context())
	defer cancel()
	var trusts v1alpha1.ZoneTrustList
	if err := s.Client.List(ctx, &trusts); err != nil {
		serviceUnavailable(w, err)
		return
	}
	sort.Slice(trusts.Items, func(i, j int) bool { return trusts.Items[i].Name < trusts.Items[j].Name })
	writeJSON(w, http.StatusOK, map[string]any{"trusts": trusts.Items})
}

func (s *Server) trust(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		methodNotAllowed(w)
		return
	}
	ctx, cancel := apiContext(r.Context())
	defer cancel()
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/v1/trusts/"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		badRequest(w, "path must be /api/v1/trusts/{source}/{destination}")
		return
	}
	source, destination := parts[0], parts[1]
	if err := validateZones(source, destination); err != nil {
		badRequest(w, err.Error())
		return
	}
	var body struct {
		Allowed *bool `json:"allowed"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil || body.Allowed == nil || decoder.Decode(&struct{}{}) != io.EOF {
		badRequest(w, "body must be exactly {\"allowed\": true|false}")
		return
	}
	if err := s.ensureKnownZones(ctx, source, destination); err != nil {
		if errors.Is(err, errUnknownZone) {
			badRequest(w, err.Error())
		} else {
			serviceUnavailable(w, err)
		}
		return
	}
	name := v1alpha1.CanonicalName(source, destination)
	var current v1alpha1.ZoneTrust
	err := s.Client.Get(ctx, types.NamespacedName{Name: name}, &current)
	if err == nil && (current.Spec.SourceZone != source || current.Spec.DestinationZone != destination) {
		writeError(w, http.StatusConflict, "canonical name belongs to a different edge")
		return
	}
	if err != nil && !apierrors.IsNotFound(err) {
		serviceUnavailable(w, err)
		return
	}
	desired := &v1alpha1.ZoneTrust{TypeMeta: metav1.TypeMeta{APIVersion: v1alpha1.GroupVersion.String(), Kind: "ZoneTrust"}, ObjectMeta: metav1.ObjectMeta{Name: name}, Spec: v1alpha1.ZoneTrustSpec{SourceZone: source, DestinationZone: destination, Allowed: *body.Allowed}}
	if err := s.Client.Patch(ctx, desired, client.Apply, client.FieldOwner("zone-trust-dashboard")); err != nil {
		if apierrors.IsConflict(err) {
			writeError(w, http.StatusConflict, "ZoneTrust is owned by another field manager")
			return
		}
		serviceUnavailable(w, err)
		return
	}
	// A direct read provides the generation accepted by the API server, not a cache observation.
	if err := s.Client.Get(ctx, types.NamespacedName{Name: name}, desired); err != nil {
		serviceUnavailable(w, err)
		return
	}
	s.Publish("trusts", desired)
	writeJSON(w, http.StatusAccepted, map[string]any{"trust": desired})
}

func (s *Server) ensureKnownZones(ctx context.Context, source, destination string) error {
	var namespaces corev1.NamespaceList
	if err := s.Client.List(ctx, &namespaces, client.MatchingLabels{zoneLabel: "true"}); err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, namespace := range namespaces.Items {
		seen[namespace.Name] = true
	}
	if !seen[source] || !seen[destination] {
		return fmt.Errorf("%w: source and destination must be labeled POC zones", errUnknownZone)
	}
	return nil
}

var errUnknownZone = errors.New("unknown zone")

func (s *Server) check(w http.ResponseWriter, r *http.Request) {
	// Envoy's HTTP ext_authz transport preserves the downstream method and appends
	// the original path after path_prefix. The authorizer therefore intentionally
	// accepts every method at /check and /check/*; it never authorizes by that path.
	if r.URL.Path != "/check" && !strings.HasPrefix(r.URL.Path, "/check/") {
		http.NotFound(w, r)
		return
	}
	started := time.Now()
	peer, destination := r.Header.Get("x-spiffe-peer-id"), r.Header.Get("x-destination-zone")
	allowed, source, reason := s.Store.Check(peer, destination, started)
	decision := "deny"
	status := http.StatusForbidden
	if allowed {
		decision, status = "allow", http.StatusOK
	}
	w.Header().Set("x-zone-trust-decision", reason)
	w.Header().Set("Cache-Control", "no-store")
	if s.Metrics != nil {
		s.Metrics.ObserveCheck(labelOrUnknown(source), labelOrUnknown(destination), decision, time.Since(started))
	}
	writeJSON(w, status, map[string]string{"decision": decision, "reason": reason})
}

func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	channel, cancel := s.broker.subscribe()
	defer cancel()
	fmt.Fprint(w, "event: policy\ndata: {\"state\":\"connected\"}\n\n")
	flusher.Flush()
	for {
		select {
		case <-r.Context().Done():
			return
		case message := <-channel:
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", message.event, message.data)
			flusher.Flush()
		case <-time.After(20 * time.Second):
			fmt.Fprint(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}

func (s *Server) Publish(event string, value any) { s.broker.publish(event, value) }

type eventMessage struct{ event, data string }
type broker struct {
	mu          sync.Mutex
	subscribers map[chan eventMessage]struct{}
}

func newBroker() *broker { return &broker{subscribers: map[chan eventMessage]struct{}{}} }
func (b *broker) subscribe() (<-chan eventMessage, func()) {
	ch := make(chan eventMessage, 4)
	b.mu.Lock()
	b.subscribers[ch] = struct{}{}
	b.mu.Unlock()
	return ch, func() { b.mu.Lock(); delete(b.subscribers, ch); b.mu.Unlock() }
}
func (b *broker) publish(event string, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		return
	}
	message := eventMessage{event: event, data: string(data)}
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subscribers {
		select {
		case ch <- message:
		default:
		}
	}
}

func validateZones(source, destination string) error {
	spec := v1alpha1.ZoneTrustSpec{SourceZone: source, DestinationZone: destination}
	return spec.Validate()
}
func apiContext(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(parent, apiRequestTimeout)
}
func labelOrUnknown(value string) string {
	if value == "" {
		return "unknown"
	}
	return value
}
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
func badRequest(w http.ResponseWriter, message string) { writeError(w, http.StatusBadRequest, message) }
func methodNotAllowed(w http.ResponseWriter) {
	w.Header().Set("Allow", "GET, PUT")
	writeError(w, http.StatusMethodNotAllowed, "method not allowed")
}
func serviceUnavailable(w http.ResponseWriter, err error) {
	writeError(w, http.StatusServiceUnavailable, "Kubernetes API unavailable")
}
func requestLimit(next http.Handler) http.Handler { return http.MaxBytesHandler(next, 64<<10) }
