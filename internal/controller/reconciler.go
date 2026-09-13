// Package controller reconciles ZoneTrust desired state to the selected policy backend.
package controller

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
	"github.com/tig4605246/spire-gw-poc/internal/authz"
	"github.com/tig4605246/spire-gw-poc/internal/istio"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var errGenerationChanged = fmt.Errorf("ZoneTrust changed during reconciliation")

type policyApplyError struct {
	affected []v1alpha1.ZoneTrust
	cause    error
}

func (e *policyApplyError) Error() string { return e.cause.Error() }
func (e *policyApplyError) Unwrap() error { return e.cause }

const (
	BackendStandalone = "standalone"
	BackendIstio      = "istio"
	ZoneLabel         = "security.poc.example/zone"
	SyncInterval      = 10 * time.Second
	APITimeout        = 5 * time.Second
)

type EventPublisher interface{ Publish(event string, value any) }

type Reconciler struct {
	client.Client
	APIReader client.Reader
	Backend   string
	Store     *authz.Store
	Istio     istio.Applicator
	Events    EventPublisher
	Metrics   *Metrics
	clock     func() time.Time
	mu        sync.Mutex // serializes full-state rebuilds and status transitions
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	if r.Backend != BackendStandalone && r.Backend != BackendIstio {
		return fmt.Errorf("unsupported POLICY_BACKEND %q", r.Backend)
	}
	if r.Store == nil {
		return fmt.Errorf("authorization store is required")
	}
	if r.APIReader == nil {
		r.APIReader = mgr.GetAPIReader()
	}
	if r.clock == nil {
		r.clock = time.Now
	}
	return ctrl.NewControllerManagedBy(mgr).For(&v1alpha1.ZoneTrust{}).Complete(r)
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	// A full rebuild prevents a reconcile ordering race from publishing a partial edge set.
	if err := r.Refresh(ctx); err != nil {
		return ctrl.Result{RequeueAfter: SyncInterval}, err
	}
	if r.Events != nil {
		r.Events.Publish("trusts", map[string]string{"changed": req.Name})
	}
	return ctrl.Result{RequeueAfter: SyncInterval}, nil
}

// Refresh reads authoritative API state, publishes an all-or-nothing standalone
// snapshot or applies every destination policy, then advances matching statuses.
func (r *Reconciler) Refresh(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, APITimeout)
	defer cancel()
	r.mu.Lock()
	defer r.mu.Unlock()
	var refreshErr error
	defer func() {
		if refreshErr != nil {
			r.Metrics.ObserveReconcile(r.Backend, "error")
		} else {
			r.Metrics.ObserveReconcile(r.Backend, "success")
		}
	}()
	reader := r.APIReader
	if reader == nil {
		reader = r.Client
	}
	var trusts v1alpha1.ZoneTrustList
	if err := reader.List(ctx, &trusts); err != nil {
		r.Store.MarkUnready()
		refreshErr = fmt.Errorf("list ZoneTrusts: %w", err)
		return refreshErr
	}
	for i := range trusts.Items {
		if err := trusts.Items[i].ValidateCanonicalName(); err != nil {
			r.Store.MarkUnready()
			r.markFailedExpected(ctx, []v1alpha1.ZoneTrust{trusts.Items[i]}, err)
			refreshErr = err
			return refreshErr
		}
	}

	backendName := ""
	switch r.Backend {
	case BackendStandalone:
		snapshot, err := authz.BuildSnapshot(trusts.Items, r.now())
		if err != nil {
			r.Store.MarkUnready()
			refreshErr = err
			return refreshErr
		}
		r.Store.Publish(snapshot)
		backendName = "ext-authz"
	case BackendIstio:
		if err := r.applyIstio(ctx, trusts.Items); err != nil {
			r.Store.MarkUnready()
			var applyErr *policyApplyError
			if errors.As(err, &applyErr) {
				r.markFailedExpected(ctx, applyErr.affected, err)
			}
			refreshErr = err
			return refreshErr
		}
		// The standalone endpoint is never used in this mode, but an empty snapshot
		// preserves fail-closed behavior should it accidentally be contacted.
		empty, _ := authz.BuildSnapshot(nil, r.now())
		r.Store.Publish(empty)
		backendName = "istio-authorization-policy"
	}
	for _, trust := range trusts.Items {
		if err := r.markApplied(ctx, trust, backendName); err != nil {
			refreshErr = err
			return refreshErr
		}
	}
	r.Store.MarkReady()
	return nil
}

func (r *Reconciler) applyIstio(ctx context.Context, trusts []v1alpha1.ZoneTrust) error {
	destinations := map[string]struct{}{}
	var namespaces corev1.NamespaceList
	if err := r.APIReader.List(ctx, &namespaces, client.MatchingLabels{ZoneLabel: "true"}); err != nil {
		return fmt.Errorf("list zones: %w", err)
	}
	for _, namespace := range namespaces.Items {
		destinations[namespace.Name] = struct{}{}
	}
	for _, trust := range trusts {
		destinations[trust.Spec.DestinationZone] = struct{}{}
	}
	ordered := make([]string, 0, len(destinations))
	for destination := range destinations {
		ordered = append(ordered, destination)
	}
	sort.Strings(ordered)
	for _, destination := range ordered {
		if err := r.Istio.Apply(ctx, destination, trusts); err != nil {
			affected := make([]v1alpha1.ZoneTrust, 0)
			for _, trust := range trusts {
				if trust.Spec.DestinationZone == destination {
					affected = append(affected, trust)
				}
			}
			return &policyApplyError{affected: affected, cause: fmt.Errorf("apply AuthorizationPolicy for %s: %w", destination, err)}
		}
	}
	return nil
}

func (r *Reconciler) markFailedExpected(ctx context.Context, expected []v1alpha1.ZoneTrust, cause error) {
	backend := "ext-authz"
	if r.Backend == BackendIstio {
		backend = "istio-authorization-policy"
	}
	for _, edge := range expected {
		_ = retry.RetryOnConflict(retry.DefaultRetry, func() error {
			var current v1alpha1.ZoneTrust
			reader := r.APIReader
			if reader == nil {
				reader = r.Client
			}
			if err := reader.Get(ctx, types.NamespacedName{Name: edge.Name}, &current); err != nil {
				return client.IgnoreNotFound(err)
			}
			if current.Generation != edge.Generation || current.Spec != edge.Spec {
				return nil
			}
			current.Status = v1alpha1.ZoneTrustStatus{ObservedGeneration: edge.Generation, Applied: false, Backend: backend, Message: "reconcile failed: " + truncate(cause.Error(), 180), LastTransitionTime: metav1.NewTime(r.now())}
			if err := r.Client.Status().Update(ctx, &current); err != nil {
				return err
			}
			if r.Events != nil {
				r.Events.Publish("trusts", current)
			}
			return nil
		})
	}
}
func truncate(value string, max int) string {
	if len(value) <= max {
		return value
	}
	return value[:max]
}

func (r *Reconciler) markApplied(ctx context.Context, expected v1alpha1.ZoneTrust, backend string) error {
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var current v1alpha1.ZoneTrust
		reader := r.APIReader
		if reader == nil {
			reader = r.Client
		}
		if err := reader.Get(ctx, types.NamespacedName{Name: expected.Name}, &current); err != nil {
			if apierrors.IsNotFound(err) {
				return nil
			}
			return err
		}
		if current.Generation != expected.Generation || current.Spec != expected.Spec {
			return errGenerationChanged
		}
		status := v1alpha1.ZoneTrustStatus{ObservedGeneration: current.Generation, Applied: true, Backend: backend, Message: "policy active", LastTransitionTime: metav1.NewTime(r.now())}
		if current.Status.ObservedGeneration == status.ObservedGeneration && current.Status.Applied && current.Status.Backend == status.Backend && current.Status.Message == status.Message {
			return nil
		}
		current.Status = status
		if err := r.Client.Status().Update(ctx, &current); err != nil {
			return err
		}
		if r.Events != nil {
			r.Events.Publish("trusts", current)
		}
		r.Metrics.ObserveApplied(current.Spec.SourceZone, current.Spec.DestinationZone, current.Generation)
		return nil
	})
}
func (r *Reconciler) now() time.Time {
	if r.clock != nil {
		return r.clock().UTC()
	}
	return time.Now().UTC()
}

// CacheSyncer gates readiness on manager cache synchronization and keeps the
// security snapshot fresh through direct API reads. Any failed refresh makes
// standalone authorizer checks deny until a complete replacement is published.
type CacheSyncer struct {
	Cache      interface{ WaitForCacheSync(context.Context) bool }
	Reconciler *Reconciler
}

func (CacheSyncer) NeedLeaderElection() bool { return true }

func (s CacheSyncer) Start(ctx context.Context) error {
	if !s.Cache.WaitForCacheSync(ctx) {
		s.Reconciler.Store.MarkUnready()
		return fmt.Errorf("controller cache did not synchronize")
	}
	if err := s.Reconciler.Refresh(ctx); err != nil {
		return err
	}
	ticker := time.NewTicker(SyncInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			s.Reconciler.Store.MarkUnready()
			return nil
		case <-ticker.C:
			if err := s.Reconciler.Refresh(ctx); err != nil {
				s.Reconciler.Store.MarkUnready()
			}
		}
	}
}
