package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type CloudEvent struct {
	SpecVersion     string    `json:"specversion"`
	Type            string    `json:"type"`
	Source          string    `json:"source"`
	ID             string    `json:"id"`
	Time            time.Time `json:"time"`
	Subject         string    `json:"subject"`
	DataContentType string    `json:"datacontenttype"`
	Data            EventData `json:"data"`
}

type EventData struct {
	// IPP-compatible fields (real format)
	User                string `json:"user"`
	Group               string `json:"group"`
	Subscription        string `json:"subscription"`
	Provider            string `json:"provider"`
	Model               string `json:"model"`
	PromptTokens        int64  `json:"prompt_tokens"`
	CompletionTokens    int64  `json:"completion_tokens"`
	TotalTokens         int64  `json:"total_tokens"`
	CachedInputTokens   int64  `json:"cached_input_tokens"`
	CacheCreationTokens int64  `json:"cache_creation_tokens"`
	ReasoningTokens     int64  `json:"reasoning_tokens"`
	DurationMs          int64  `json:"duration_ms"`
	// Fields for backwards compat with our pipeline
	TenantID string `json:"tenant_id"`
	ModelID  string `json:"model_id"`
}

var models = []struct {
	id       string
	name     string
	provider string
}{
	{"model-claude-sonnet", "claude-sonnet-4-20250514", "anthropic"},
	{"model-claude-opus", "claude-opus-4-20250514", "anthropic"},
	{"model-llama-3-70b", "meta-llama/llama-3-70b", "vllm"},
	{"model-granite-34b", "ibm/granite-34b-code", "vllm"},
}

var tenants = []string{"tenant-acme", "tenant-globex", "tenant-initech"}

// fmtInt formats an int64 with comma separators (e.g. 4721 → "4,721").
func fmtInt(n int64) string {
	s := fmt.Sprintf("%d", n)
	if len(s) <= 3 {
		return s
	}
	var b []byte
	for i, ch := range []byte(s) {
		if i > 0 && (len(s)-i)%3 == 0 {
			b = append(b, ',')
		}
		b = append(b, ch)
	}
	return string(b)
}

func main() {
	target := flag.String("target", "http://localhost:8020", "ingest endpoint base URL")
	count := flag.Int("count", 100, "total number of events to send (ignored when -loop is set)")
	rate := flag.Int("rate", 50, "events per second (0 = unlimited)")
	workers := flag.Int("workers", 4, "concurrent sender goroutines")
	format := flag.String("format", "ipp", "event format: ipp (real) or legacy (old mock)")
	loop := flag.Bool("loop", false, "run continuously at the specified rate forever (ignores -count)")
	duration := flag.Duration("duration", 0, "stop after this long (works with both normal and -loop mode; 0 = no limit)")
	token := flag.String("token", os.Getenv("CONSUMER_TOKEN"), "Bearer token for authenticated ingest endpoint (env: CONSUMER_TOKEN)")
	flag.Parse()

	fmt.Printf("MaaS Simulator\n")
	fmt.Printf("  target:  %s/api/v1/events\n", *target)
	if *loop {
		fmt.Printf("  events:  continuous\n")
	} else {
		fmt.Printf("  events:  %d\n", *count)
	}
	fmt.Printf("  rate:    %d/s\n", *rate)
	fmt.Printf("  workers: %d\n", *workers)
	fmt.Printf("  format:  %s\n", *format)
	if *loop {
		fmt.Printf("  loop:    true\n")
	}
	if *duration > 0 {
		fmt.Printf("  duration: %s\n", *duration)
	}
	fmt.Println()

	url := *target + "/api/v1/events"
	client := &http.Client{Timeout: 5 * time.Second}

	var sent, errCount atomic.Int64
	start := time.Now()

	// ── Context: honour -duration and OS signals ───────────────────────────────
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
		select {
		case <-sigCh:
			fmt.Println("\nInterrupted — stopping...")
			cancel()
		case <-ctx.Done():
		}
	}()

	if *duration > 0 {
		time.AfterFunc(*duration, cancel)
	}

	// ── Worker pool ───────────────────────────────────────────────────────────
	ch := make(chan CloudEvent, *workers*2)

	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ce := range ch {
				body, _ := json.Marshal(ce)
				req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
				req.Header.Set("Content-Type", "application/json")
				if *token != "" {
					req.Header.Set("Authorization", "Bearer "+*token)
				}
				resp, err := client.Do(req)
				if err != nil {
					errCount.Add(1)
					continue
				}
				resp.Body.Close()
				if resp.StatusCode == http.StatusAccepted {
					sent.Add(1)
				} else {
					errCount.Add(1)
				}
			}
		}()
	}

	var interval time.Duration
	if *rate > 0 {
		interval = time.Second / time.Duration(*rate)
	}

	// ── Progress ticker for loop mode ─────────────────────────────────────────
	if *loop {
		go func() {
			ticker := time.NewTicker(10 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case t := <-ticker.C:
					s := sent.Load()
					e := errCount.Load()
					elapsed := time.Since(start).Seconds()
					fmt.Printf("[%s] sent=%s rate=%.1f/s errors=%d\n",
						t.Format("15:04:05"), fmtInt(s), float64(s)/elapsed, e)
				}
			}
		}()
	}

	// ── Main send loop ────────────────────────────────────────────────────────
	i := 0
	for {
		// Check stop conditions.
		select {
		case <-ctx.Done():
			goto endSend
		default:
		}
		if !*loop && i >= *count {
			break
		}

		// Generate event.
		model := models[rand.Intn(len(models))]
		tenant := tenants[rand.Intn(len(tenants))]
		promptTokens := int64(rand.Intn(50000) + 1000)
		completionTokens := int64(rand.Intn(20000) + 500)
		cachedTokens := int64(rand.Intn(5000))
		reasoningTokens := int64(0)
		if model.provider == "anthropic" {
			reasoningTokens = int64(rand.Intn(10000))
		}

		var ce CloudEvent
		if *format == "legacy" {
			ce = CloudEvent{
				SpecVersion:     "1.0",
				Type:            "osac.model.lifecycle",
				Source:          "maas-simulator",
				ID:              fmt.Sprintf("sim-%d-%d", time.Now().UnixNano(), i),
				Time:            time.Now().UTC(),
				Subject:         tenant,
				DataContentType: "application/json",
				Data: EventData{
					TenantID:         tenant,
					ModelID:          model.id,
					Model:            model.name,
					PromptTokens:     promptTokens,
					CompletionTokens: completionTokens,
					TotalTokens:      promptTokens + completionTokens,
					DurationMs:       int64(rand.Intn(5000) + 500),
				},
			}
		} else {
			ce = CloudEvent{
				SpecVersion:     "1.0",
				Type:            "inference.tokens.used",
				Source:          "maas-gateway",
				ID:              fmt.Sprintf("sim-%d-%d", time.Now().UnixNano(), i),
				Time:            time.Now().UTC(),
				Subject:         tenant,
				DataContentType: "application/json",
				Data: EventData{
					User:                tenant,
					Group:               "maas-users",
					Subscription:        "default",
					Provider:            model.provider,
					Model:               model.name,
					PromptTokens:        promptTokens,
					CompletionTokens:    completionTokens,
					TotalTokens:         promptTokens + completionTokens + cachedTokens + reasoningTokens,
					CachedInputTokens:   cachedTokens,
					CacheCreationTokens: 0,
					ReasoningTokens:     reasoningTokens,
					DurationMs:          int64(rand.Intn(5000) + 500),
					TenantID:            tenant,
					ModelID:             model.id,
				},
			}
		}

		// Send — also respects context cancellation so we don't block on a full
		// channel after a signal arrives.
		select {
		case ch <- ce:
		case <-ctx.Done():
			goto endSend
		}
		i++

		// Rate limit — respects context cancellation so -duration exits promptly.
		if interval > 0 {
			select {
			case <-time.After(interval):
			case <-ctx.Done():
				goto endSend
			}
		}

		// Inline progress for count (non-loop) mode.
		if !*loop && (i%100 == 0 || i == *count) {
			elapsed := time.Since(start).Seconds()
			s := sent.Load()
			e := errCount.Load()
			fmt.Printf("\r  sent: %d  errors: %d  rate: %.0f/s", s, e, float64(s)/elapsed)
		}
	}

endSend:
	close(ch)
	wg.Wait()

	elapsed := time.Since(start)
	s := sent.Load()
	e := errCount.Load()
	fmt.Printf("\n\nDone: %d sent, %d errors in %s (%.0f events/s)\n", s, e, elapsed.Round(time.Millisecond), float64(s)/elapsed.Seconds())

	if e > 0 {
		os.Exit(1)
	}
}
