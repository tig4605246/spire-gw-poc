package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	v1alpha1 "github.com/tig4605246/spire-gw-poc/api/v1alpha1"
	"github.com/tig4605246/spire-gw-poc/internal/api"
	"github.com/tig4605246/spire-gw-poc/internal/authz"
	"github.com/tig4605246/spire-gw-poc/internal/controller"
	"github.com/tig4605246/spire-gw-poc/internal/istio"
	"github.com/tig4605246/spire-gw-poc/internal/ui"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(false)))
	if err := run(); err != nil {
		ctrl.Log.WithName("setup").Error(err, "controller exited")
		os.Exit(1)
	}
}

func run() error {
	backend := os.Getenv("POLICY_BACKEND")
	if backend == "" {
		backend = controller.BackendStandalone
	}
	if backend != controller.BackendStandalone && backend != controller.BackendIstio {
		return fmt.Errorf("POLICY_BACKEND must be standalone or istio")
	}
	config, err := ctrl.GetConfig()
	if err != nil {
		return fmt.Errorf("load Kubernetes configuration: %w", err)
	}
	scheme := clientgoscheme.Scheme
	if err := v1alpha1.AddToScheme(scheme); err != nil {
		return err
	}
	// This POC deliberately has a single controller replica. Disabling leader
	// election keeps its RBAC limited to policy/discovery resources; production
	// replicas must enable it and grant the corresponding Lease permissions.
	mgr, err := ctrl.NewManager(config, ctrl.Options{Scheme: scheme, Metrics: metricsserver.Options{BindAddress: "0"}, HealthProbeBindAddress: "0", LeaderElection: false})
	if err != nil {
		return fmt.Errorf("create manager: %w", err)
	}
	direct, err := client.New(config, client.Options{Scheme: scheme})
	if err != nil {
		return fmt.Errorf("create direct Kubernetes client: %w", err)
	}
	registry := prometheus.NewRegistry()
	metrics := controller.NewMetrics(registry)
	store := authz.NewStore(30 * time.Second)
	server := api.NewServer(direct, store, ui.Handler(), metrics)
	reconciler := &controller.Reconciler{Client: mgr.GetClient(), APIReader: mgr.GetAPIReader(), Backend: backend, Store: store, Istio: istio.Applicator{Client: direct}, Events: server, Metrics: metrics}
	if err := reconciler.SetupWithManager(mgr); err != nil {
		return err
	}
	if err := mgr.Add(controller.CacheSyncer{Cache: mgr.GetCache(), Reconciler: reconciler}); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	dashboard := &http.Server{Addr: address("DASHBOARD_ADDR", ":8080"), Handler: server.DashboardHandler(), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second}
	authorizer := &http.Server{Addr: address("AUTHORIZER_ADDR", ":9000"), Handler: server.AuthorizerHandler(), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	observability := &http.Server{Addr: address("OBSERVABILITY_ADDR", ":8081"), Handler: observationHandler(store, registry), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	errs := make(chan error, 4)
	for _, httpServer := range []*http.Server{dashboard, authorizer, observability} {
		go serve(errs, httpServer)
	}
	go func() { errs <- mgr.Start(ctx) }()
	select {
	case <-ctx.Done():
	case err := <-errs:
		if err != nil {
			stop()
			return err
		}
	}
	shutdownContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, httpServer := range []*http.Server{dashboard, authorizer, observability} {
		_ = httpServer.Shutdown(shutdownContext)
	}
	return nil
}

func serve(errs chan<- error, server *http.Server) {
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		errs <- err
	}
}
func address(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
func observationHandler(store *authz.Store, registry *prometheus.Registry) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		if !store.Ready() {
			http.Error(w, "policy cache not synchronized", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	return mux
}
