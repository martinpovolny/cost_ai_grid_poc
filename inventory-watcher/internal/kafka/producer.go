package kafka

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"github.com/twmb/franz-go/pkg/kgo"
)

// Producer publishes CloudEvent JSON to the appropriate Kafka topic.
// Publishing is best-effort: errors are logged but never returned,
// because the primary pipeline writes to the database.
type Producer struct {
	client *kgo.Client
	cfg    Config
	logger *slog.Logger
}

// NewProducer creates a franz-go client configured for async producing.
func NewProducer(cfg Config, logger *slog.Logger) (*Producer, error) {
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(cfg.Brokers...),
		kgo.AllowAutoTopicCreation(),
		kgo.ProducerBatchCompression(kgo.SnappyCompression()),
	)
	if err != nil {
		return nil, fmt.Errorf("kafka producer: %w", err)
	}
	logger.Info("kafka producer created", "brokers", cfg.Brokers)
	return &Producer{client: cl, cfg: cfg, logger: logger}, nil
}

// Publish sends a raw key/value pair to the given topic asynchronously.
// Errors are logged but not propagated.
func (p *Producer) Publish(ctx context.Context, topic, key string, value []byte) {
	rec := &kgo.Record{
		Topic: topic,
		Key:   []byte(key),
		Value: value,
	}
	p.client.Produce(ctx, rec, func(r *kgo.Record, err error) {
		if err != nil {
			p.logger.Error("kafka publish failed",
				"topic", r.Topic,
				"key", string(r.Key),
				"err", err,
			)
		}
	})
}

// PublishEvent routes a CloudEvent payload to the correct topic based on
// eventType and publishes it asynchronously.
//
// Routing rules:
//   - EVENT_TYPE_OBJECT_CREATED/UPDATED/DELETED  -> lifecycle topic, key=resourceID
//   - osac.compute_instance.lifecycle,
//     osac.cluster.lifecycle                     -> heartbeat topic, key=resourceID
//   - osac.model.lifecycle,
//     inference.tokens.used                      -> inference topic, key=tenantID
//
// Unknown event types are logged and dropped.
func (p *Producer) PublishEvent(ctx context.Context, eventType, resourceID, tenantID string, payload []byte) {
	topic, key := p.route(eventType, resourceID, tenantID)
	if topic == "" {
		p.logger.Warn("kafka: unknown event type, skipping publish",
			"event_type", eventType,
		)
		return
	}
	p.Publish(ctx, topic, key, payload)
}

// route determines the target topic and record key for an event type.
func (p *Producer) route(eventType, resourceID, tenantID string) (topic, key string) {
	switch {
	// OSAC object lifecycle mutations.
	case eventType == "EVENT_TYPE_OBJECT_CREATED",
		eventType == "EVENT_TYPE_OBJECT_UPDATED",
		eventType == "EVENT_TYPE_OBJECT_DELETED":
		return p.cfg.TopicLifecycle(), resourceID

	// Periodic heartbeat / liveness signals.
	case strings.HasSuffix(eventType, ".compute_instance.lifecycle"),
		strings.HasSuffix(eventType, ".cluster.lifecycle"):
		return p.cfg.TopicHeartbeat(), resourceID

	// Inference model events and token usage.
	case strings.HasSuffix(eventType, ".model.lifecycle"),
		eventType == "inference.tokens.used":
		return p.cfg.TopicInference(), tenantID

	default:
		return "", ""
	}
}

// Close flushes pending produces and closes the underlying client.
func (p *Producer) Close() {
	p.client.Close()
	p.logger.Info("kafka producer closed")
}
