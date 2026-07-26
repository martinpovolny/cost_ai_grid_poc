// Package emitter constructs CloudEvents 1.0 envelopes and delivers them
// to the cost-event-consumer via HTTP POST.
package emitter

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/go-logr/logr"
	"github.com/google/uuid"
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

var (
	eventsEmitted = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "cost_agent_events_emitted_total",
		Help: "CloudEvents emitted to consumer",
	}, []string{"type", "status"})
)

func init() {
	metrics.Registry.MustRegister(eventsEmitted)
}

// CloudEvent represents a CloudEvents 1.0 envelope.
type CloudEvent struct {
	SpecVersion string      `json:"specversion"`
	Type        string      `json:"type"`
	Source      string      `json:"source"`
	ID          string      `json:"id"`
	Time        time.Time   `json:"time"`
	Subject     string      `json:"subject"`
	Data        any `json:"data"`
}

// Emitter batches CloudEvents and delivers them to the cost-event-consumer.
type Emitter struct {
	consumerURL   string
	token         string
	clusterID     string
	batchSize     int
	batchInterval time.Duration
	client        *http.Client
	eventCh       chan CloudEvent
	logger        logr.Logger
}

// New creates an Emitter that will POST CloudEvents to consumerURL.
func New(consumerURL, token, clusterID string, batchSize int, batchInterval time.Duration, logger logr.Logger) *Emitter {
	return &Emitter{
		consumerURL:   consumerURL,
		token:         token,
		clusterID:     clusterID,
		batchSize:     batchSize,
		batchInterval: batchInterval,
		client:        &http.Client{Timeout: 30 * time.Second},
		eventCh:       make(chan CloudEvent, batchSize*2),
		logger:        logger.WithName("emitter"),
	}
}

// Emit constructs a CloudEvent and pushes it onto the internal channel for
// batched delivery.
func (e *Emitter) Emit(eventType, subject string, data any) {
	ce := CloudEvent{
		SpecVersion: "1.0",
		Type:        eventType,
		Source:      fmt.Sprintf("/cluster/%s", e.clusterID),
		ID:          uuid.New().String(),
		Time:        time.Now().UTC(),
		Subject:     subject,
		Data:        data,
	}
	select {
	case e.eventCh <- ce:
	default:
		e.logger.Info("event channel full, dropping event",
			"type", eventType, "subject", subject)
		eventsEmitted.WithLabelValues(eventType, "dropped").Inc()
	}
}

// Start runs the batch loop. It reads from the event channel and flushes
// when batchSize is reached or batchInterval elapses. Implements
// manager.Runnable.
func (e *Emitter) Start(ctx context.Context) error {
	ticker := time.NewTicker(e.batchInterval)
	defer ticker.Stop()

	batch := make([]CloudEvent, 0, e.batchSize)

	for {
		select {
		case <-ctx.Done():
			// Flush remaining events before exit.
			if len(batch) > 0 {
				e.flush(batch)
			}
			return nil

		case ev := <-e.eventCh:
			batch = append(batch, ev)
			if len(batch) >= e.batchSize {
				e.flush(batch)
				batch = make([]CloudEvent, 0, e.batchSize)
				ticker.Reset(e.batchInterval)
			}

		case <-ticker.C:
			if len(batch) > 0 {
				e.flush(batch)
				batch = make([]CloudEvent, 0, e.batchSize)
			}
		}
	}
}

// NeedLeaderElection returns false — all replicas can emit events.
func (e *Emitter) NeedLeaderElection() bool {
	return false
}

// flush sends each event individually to the consumer with retry
// (3 attempts, 1s/2s/4s exponential backoff).
func (e *Emitter) flush(batch []CloudEvent) {
	for i := range batch {
		e.sendWithRetry(&batch[i])
	}
}

func (e *Emitter) sendWithRetry(ce *CloudEvent) {
	body, err := json.Marshal(ce)
	if err != nil {
		e.logger.Error(err, "failed to marshal CloudEvent",
			"type", ce.Type, "id", ce.ID)
		eventsEmitted.WithLabelValues(ce.Type, "marshal_error").Inc()
		return
	}

	backoff := 1 * time.Second
	const maxAttempts = 3

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		req, err := http.NewRequest(http.MethodPost, e.consumerURL, bytes.NewReader(body))
		if err != nil {
			e.logger.Error(err, "failed to create request",
				"type", ce.Type, "id", ce.ID)
			eventsEmitted.WithLabelValues(ce.Type, "request_error").Inc()
			return
		}
		req.Header.Set("Content-Type", "application/cloudevents+json")
		if e.token != "" {
			req.Header.Set("Authorization", "Bearer "+e.token)
		}

		resp, err := e.client.Do(req)
		if err != nil {
			e.logger.Info("POST failed, retrying",
				"attempt", attempt, "error", err,
				"type", ce.Type, "id", ce.ID)
			if attempt < maxAttempts {
				time.Sleep(backoff)
				backoff *= 2
			}
			continue
		}
		_ = resp.Body.Close()

		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			eventsEmitted.WithLabelValues(ce.Type, "success").Inc()
			return
		}

		e.logger.Info("non-2xx response, retrying",
			"attempt", attempt, "status", resp.StatusCode,
			"type", ce.Type, "id", ce.ID)
		if attempt < maxAttempts {
			time.Sleep(backoff)
			backoff *= 2
		}
	}

	e.logger.Error(fmt.Errorf("all %d attempts failed", maxAttempts),
		"failed to emit CloudEvent",
		"type", ce.Type, "id", ce.ID)
	eventsEmitted.WithLabelValues(ce.Type, "failed").Inc()
}
