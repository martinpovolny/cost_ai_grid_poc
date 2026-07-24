package ruleengine

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"sync"

	zen "github.com/gorules/zen-go"

	"github.com/osac-project/cost-event-consumer/internal/inventory"
)

type RuleStore interface {
	PricingRulesVersion(ctx context.Context) (int64, error)
	AllPricingRules(ctx context.Context) ([]inventory.PricingRule, error)
}

type Engine struct {
	engine        zen.Engine
	rulesDir      string
	store         RuleStore
	mu            sync.RWMutex
	cache         map[string][]byte
	cachedVersion int64
}

func New(rulesDir string) *Engine {
	e := &Engine{rulesDir: rulesDir}
	loader := func(key string) ([]byte, error) {
		return os.ReadFile(path.Join(rulesDir, key))
	}
	e.engine = zen.NewEngine(zen.EngineConfig{Loader: loader})
	return e
}

func NewFromStore(store RuleStore) *Engine {
	e := &Engine{
		store: store,
		cache: make(map[string][]byte),
	}
	loader := func(key string) ([]byte, error) {
		e.mu.RLock()
		defer e.mu.RUnlock()
		data, ok := e.cache[key]
		if !ok {
			return nil, fmt.Errorf("rule %q not found in cache", key)
		}
		return data, nil
	}
	e.engine = zen.NewEngine(zen.EngineConfig{Loader: loader})
	return e
}

func (e *Engine) ReloadIfChanged(ctx context.Context) (bool, error) {
	if e.store == nil {
		return false, nil
	}

	version, err := e.store.PricingRulesVersion(ctx)
	if err != nil {
		return false, fmt.Errorf("check pricing rules version: %w", err)
	}

	if version == e.cachedVersion {
		return false, nil
	}

	rules, err := e.store.AllPricingRules(ctx)
	if err != nil {
		return false, fmt.Errorf("load pricing rules: %w", err)
	}

	newCache := make(map[string][]byte, len(rules))
	for _, r := range rules {
		newCache[r.Name] = r.RuleJSON
	}

	e.mu.Lock()
	e.cache = newCache
	e.cachedVersion = version
	e.mu.Unlock()

	return true, nil
}

func (e *Engine) HasRules() bool {
	if e.rulesDir != "" {
		return true
	}
	e.mu.RLock()
	defer e.mu.RUnlock()
	return len(e.cache) > 0
}

func (e *Engine) RuleNames() []string {
	e.mu.RLock()
	defer e.mu.RUnlock()
	names := make([]string, 0, len(e.cache))
	for k := range e.cache {
		names = append(names, k)
	}
	return names
}

func (e *Engine) Close() {
	e.engine.Dispose()
}

type PricingInput struct {
	InstanceType string  `json:"instance_type"`
	TenantTier   string  `json:"tenant_tier"`
	TenantID     string  `json:"tenant_id"`
	ResourceType string  `json:"resource_type"`
	MeterName    string  `json:"meter_name"`
	Value        float64 `json:"value"`
}

type PricingOutput struct {
	CostAmount    float64 `json:"cost_amount"`
	EffectiveRate float64 `json:"effective_rate"`
	Currency      string  `json:"currency"`
	Description   string  `json:"description"`
	PricePerHour  float64 `json:"price_per_hour"`
	DiscountPct   float64 `json:"discount_pct"`
}

func (e *Engine) EvaluateRate(ruleFile string, input PricingInput) (*PricingOutput, error) {
	inputMap := map[string]any{
		"instance_type": input.InstanceType,
		"tenant_tier":   input.TenantTier,
		"tenant_id":     input.TenantID,
		"resource_type": input.ResourceType,
		"meter_name":    input.MeterName,
		"value":         input.Value,
	}

	resp, err := e.engine.Evaluate(ruleFile, inputMap)
	if err != nil {
		return nil, fmt.Errorf("rule evaluation failed: %w", err)
	}

	var output PricingOutput
	if err := json.Unmarshal(resp.Result, &output); err != nil {
		return nil, fmt.Errorf("unmarshal rule output: %w", err)
	}

	return &output, nil
}
