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

// Topics returns all topic names derived from the configured prefix.
func (c Config) Topics() []string {
	return []string{c.TopicLifecycle(), c.TopicHeartbeat(), c.TopicInference()}
}
