package kafka

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/twmb/franz-go/pkg/kgo"
)

// EventProcessor is implemented by the component that handles incoming
// Kafka records (typically the API handler). Using an interface here
// avoids circular imports between the kafka and api packages.
type EventProcessor interface {
	ProcessKafkaEvent(ctx context.Context, eventType string, payload []byte) error
}

// Consumer reads CloudEvent records from Kafka and feeds them into the
// existing processing pipeline via the EventProcessor interface.
type Consumer struct {
	client    *kgo.Client
	processor EventProcessor
	dlq       *Producer
	dlqTopic  string
	logger    *slog.Logger
}

// NewConsumer creates a franz-go client configured for group consumption
// with manual offset commits.
func NewConsumer(cfg Config, processor EventProcessor, logger *slog.Logger) (*Consumer, error) {
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(cfg.Brokers...),
		kgo.ConsumeTopics(cfg.Topics()...),
		kgo.ConsumerGroup(cfg.ConsumerGroup),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
		kgo.DisableAutoCommit(),
	)
	if err != nil {
		return nil, fmt.Errorf("kafka consumer: %w", err)
	}
	logger.Info("kafka consumer created",
		"brokers", cfg.Brokers,
		"group", cfg.ConsumerGroup,
		"topics", cfg.Topics(),
	)
	return &Consumer{client: cl, processor: processor, dlqTopic: cfg.TopicDLQ(), logger: logger}, nil
}

// SetDLQProducer sets the producer used to publish failed records to the DLQ topic.
func (c *Consumer) SetDLQProducer(p *Producer) { c.dlq = p }

// Run polls Kafka in a loop until ctx is cancelled. Each batch of
// fetched records is handed to the EventProcessor one record at a time;
// offsets are committed after the entire batch is processed.
func (c *Consumer) Run(ctx context.Context) error {
	c.logger.Info("kafka consumer loop starting")
	for {
		fetches := c.client.PollFetches(ctx)

		// Context cancellation is the normal shutdown path.
		if ctx.Err() != nil {
			c.logger.Info("kafka consumer: context cancelled, committing final offsets")
			if err := c.client.CommitUncommittedOffsets(context.Background()); err != nil {
				c.logger.Error("kafka consumer: final offset commit failed", "err", err)
			}
			return ctx.Err()
		}

		// Log any fetch-level errors (broker connectivity, auth, etc.).
		if errs := fetches.Errors(); len(errs) > 0 {
			for _, e := range errs {
				c.logger.Error("kafka fetch error",
					"topic", e.Topic,
					"partition", e.Partition,
					"err", e.Err,
				)
			}
		}

		// Process each record through the pipeline.
		fetches.EachRecord(func(r *kgo.Record) {
			if err := c.processor.ProcessKafkaEvent(ctx, r.Topic, r.Value); err != nil {
				c.logger.Error("kafka: event processing failed",
					"topic", r.Topic,
					"partition", r.Partition,
					"offset", r.Offset,
					"key", string(r.Key),
					"err", err,
				)
				if c.dlq != nil {
					c.dlq.Publish(ctx, c.dlqTopic, string(r.Key), r.Value)
				}
			}
		})

		// Commit after the full batch is processed.
		if err := c.client.CommitUncommittedOffsets(ctx); err != nil {
			c.logger.Error("kafka consumer: offset commit failed", "err", err)
		}
	}
}

// Close shuts down the consumer client, leaving the consumer group
// so that partitions are rebalanced promptly.
func (c *Consumer) Close() {
	c.client.Close()
	c.logger.Info("kafka consumer closed")
}
