package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// tokenFilePath is the default location for a Secret-mounted bearer token.
const tokenFilePath = "/var/run/secrets/cost-agent/token"

// Config holds all runtime settings for the kube-cost-agent controller.
// Values are loaded from environment variables; Kubernetes projects
// ConfigMap/Secret data into the pod environment or filesystem.
type Config struct {
	// ConsumerURL is the upstream cost-consumer endpoint (required).
	ConsumerURL string // COST_CONSUMER_URL

	// ConsumerToken is the bearer token for authenticating to the consumer.
	// Read from COST_CONSUMER_TOKEN or from the Secret volume mount at
	// /var/run/secrets/cost-agent/token.
	ConsumerToken string // COST_CONSUMER_TOKEN

	// ClusterID uniquely identifies this cluster (required).
	ClusterID string // CLUSTER_ID

	// TenantID selects the tenant for cost attribution.
	// When empty, the controller uses the namespace name as tenant.
	TenantID string // TENANT_ID

	// HeartbeatInterval is the period between pod heartbeat reports.
	HeartbeatInterval time.Duration // HEARTBEAT_INTERVAL (default 60s)

	// NodeReconcileInterval is the period between node reconciliation sweeps.
	NodeReconcileInterval time.Duration // NODE_RECONCILE_INTERVAL (default 5m)

	// BatchSize is the maximum number of events per HTTP POST.
	BatchSize int // BATCH_SIZE (default 100)

	// BatchInterval is the maximum delay before flushing a partial batch.
	BatchInterval time.Duration // BATCH_INTERVAL (default 5s)

	// ExcludeNamespaces lists namespace patterns to skip.
	// Supports trailing wildcards (e.g. "openshift-*").
	ExcludeNamespaces []string // EXCLUDE_NAMESPACES (default: kube-system,openshift-*)
}

// Load reads configuration from environment variables, applies defaults,
// and validates required fields.
func Load() (*Config, error) {
	c := &Config{
		ConsumerURL:           os.Getenv("COST_CONSUMER_URL"),
		ConsumerToken:         os.Getenv("COST_CONSUMER_TOKEN"),
		ClusterID:             os.Getenv("CLUSTER_ID"),
		TenantID:              os.Getenv("TENANT_ID"),
		HeartbeatInterval:     60 * time.Second,
		NodeReconcileInterval: 5 * time.Minute,
		BatchSize:             100,
		BatchInterval:         5 * time.Second,
		ExcludeNamespaces:     []string{"kube-system", "openshift-*"},
	}

	// If no token in env, try the Secret volume mount.
	if c.ConsumerToken == "" {
		if data, err := os.ReadFile(tokenFilePath); err == nil {
			c.ConsumerToken = strings.TrimSpace(string(data))
		}
	}

	// Parse optional duration overrides.
	if v := os.Getenv("HEARTBEAT_INTERVAL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return nil, fmt.Errorf("HEARTBEAT_INTERVAL: %w", err)
		}
		c.HeartbeatInterval = d
	}
	if v := os.Getenv("NODE_RECONCILE_INTERVAL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return nil, fmt.Errorf("NODE_RECONCILE_INTERVAL: %w", err)
		}
		c.NodeReconcileInterval = d
	}

	// Parse optional int overrides.
	if v := os.Getenv("BATCH_SIZE"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return nil, fmt.Errorf("BATCH_SIZE: %w", err)
		}
		if n < 1 {
			return nil, fmt.Errorf("BATCH_SIZE: must be >= 1, got %d", n)
		}
		c.BatchSize = n
	}
	if v := os.Getenv("BATCH_INTERVAL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return nil, fmt.Errorf("BATCH_INTERVAL: %w", err)
		}
		c.BatchInterval = d
	}

	// Parse optional namespace exclusion list.
	if v := os.Getenv("EXCLUDE_NAMESPACES"); v != "" {
		parts := strings.Split(v, ",")
		ns := make([]string, 0, len(parts))
		for _, p := range parts {
			if s := strings.TrimSpace(p); s != "" {
				ns = append(ns, s)
			}
		}
		c.ExcludeNamespaces = ns
	}

	if err := c.Validate(); err != nil {
		return nil, err
	}
	return c, nil
}

// Validate checks that required fields are populated.
func (c *Config) Validate() error {
	var missing []string
	if c.ConsumerURL == "" {
		missing = append(missing, "COST_CONSUMER_URL")
	}
	if c.ClusterID == "" {
		missing = append(missing, "CLUSTER_ID")
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing required config: %s", strings.Join(missing, ", "))
	}
	return nil
}
