package kafka

// Config holds Kafka connection and topic settings.
type Config struct {
	Brokers         []string // from KAFKA_BROKERS (comma-separated)
	ConsumerGroup   string   // KAFKA_CONSUMER_GROUP, default "cost-consumer"
	TopicPrefix     string   // KAFKA_TOPIC_PREFIX, default "osac.metering"
	ProducerEnabled bool     // KAFKA_PRODUCER, default true when brokers set
	ConsumerEnabled bool     // KAFKA_CONSUMER, default true when brokers set
}

// TopicLifecycle returns the topic name for lifecycle events
// (create/update/delete of OSAC resources).
func (c Config) TopicLifecycle() string { return c.TopicPrefix + ".lifecycle" }

// TopicHeartbeat returns the topic name for heartbeat events
// (periodic compute-instance and cluster liveness signals).
func (c Config) TopicHeartbeat() string { return c.TopicPrefix + ".heartbeat" }

// TopicInference returns the topic name for inference events
// (model lifecycle and token-usage records).
func (c Config) TopicInference() string { return c.TopicPrefix + ".inference" }

// TopicDLQ returns the dead-letter queue topic name.
func (c Config) TopicDLQ() string { return c.TopicPrefix + ".dlq" }

// Topics returns all topic names the consumer subscribes to.
func (c Config) Topics() []string {
	return []string{c.TopicLifecycle(), c.TopicHeartbeat(), c.TopicInference()}
}

// OSAC-985 versioned event type constants.
const (
	EventTypeCreatedV1   = "osac.resource.created.v1"
	EventTypeStartedV1   = "osac.resource.started.v1"
	EventTypeUpdatedV1   = "osac.resource.updated.v1"
	EventTypeSuspendedV1 = "osac.resource.suspended.v1"
	EventTypeResumedV1   = "osac.resource.resumed.v1"
	EventTypeDeletedV1   = "osac.resource.deleted.v1"
	EventTypeHeartbeatV1 = "osac.resource.heartbeat.v1"
	EventTypeInferenceV1 = "osac.inference.usage.v1"
)
