package controller

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

type Metrics struct {
	reconciles *prometheus.CounterVec
	applied    *prometheus.GaugeVec
	checks     *prometheus.CounterVec
	checkTime  *prometheus.HistogramVec
}

func NewMetrics(registerer prometheus.Registerer) *Metrics {
	m := &Metrics{
		reconciles: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "zone_trust_reconcile_total", Help: "Completed ZoneTrust reconciliation attempts."}, []string{"backend", "result"}),
		applied:    prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "zone_trust_applied_generation", Help: "Last generation applied for a directional edge."}, []string{"source", "destination"}),
		checks:     prometheus.NewCounterVec(prometheus.CounterOpts{Name: "zone_trust_check_total", Help: "Standalone authorization checks."}, []string{"source", "destination", "decision"}),
		checkTime:  prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "zone_trust_check_duration_seconds", Help: "Standalone authorization check duration."}, []string{"source", "destination"}),
	}
	registerer.MustRegister(m.reconciles, m.applied, m.checks, m.checkTime)
	return m
}
func (m *Metrics) ObserveReconcile(backend, result string) {
	if m != nil {
		m.reconciles.WithLabelValues(backend, result).Inc()
	}
}
func (m *Metrics) ObserveApplied(source, destination string, generation int64) {
	if m != nil {
		m.applied.WithLabelValues(source, destination).Set(float64(generation))
	}
}
func (m *Metrics) ObserveCheck(source, destination, decision string, elapsed time.Duration) {
	if m != nil {
		m.checks.WithLabelValues(source, destination, decision).Inc()
		m.checkTime.WithLabelValues(source, destination).Observe(elapsed.Seconds())
	}
}
