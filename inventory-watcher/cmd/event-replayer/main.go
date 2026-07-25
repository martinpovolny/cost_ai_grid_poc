// event-replayer reads a JSONL file of CloudEvents (produced by export-events.sh),
// shifts the timestamps, and re-sends them to the cost-event-consumer ingest
// endpoint. Run it multiple times with increasing --shift values to simulate
// days, weeks, or months of data flowing through the pipeline.
//
// Usage:
//
//	event-replayer -input events-base.jsonl -copies 24 -shift 1h \
//	               -target http://localhost:8021 -token "$(cat /tmp/osac_token.txt)"
//
//	# Simulate 30 days (720 hourly copies):
//	event-replayer -input events-base.jsonl -copies 720 -shift 1h -workers 16 -rate 0
//
//	# From stdin (pipe from export-events.sh):
//	./scripts/export-events.sh | event-replayer -copies 24 -shift 1h -target ...
package main

import (
	"bufio"
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

func main() {
	input := flag.String("input", "-", "JSONL file of CloudEvents ('-' for stdin)")
	target := flag.String("target", "http://localhost:8021", "ingest endpoint base URL")
	token := flag.String("token", os.Getenv("CONSUMER_TOKEN"), "Bearer token (env: CONSUMER_TOKEN)")
	copies := flag.Int("copies", 1, "number of time-shifted copies to send")
	shift := flag.Duration("shift", time.Hour, "time shift applied per copy (e.g. 1h, 24h)")
	workers := flag.Int("workers", 8, "concurrent sender goroutines per copy")
	rate := flag.Int("rate", 500, "max events/sec total (0 = unlimited)")
	pauseBetween := flag.Duration("pause", 0, "pause between copies (0 = none; use to let pipeline drain)")
	dryRun := flag.Bool("dry-run", false, "load and count events but do not send")
	flag.Parse()

	// Load all events into memory (JSONL → []json.RawMessage)
	events, err := loadEvents(*input)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR loading events: %v\n", err)
		os.Exit(1)
	}
	if len(events) == 0 {
		fmt.Fprintln(os.Stderr, "ERROR: no events loaded")
		os.Exit(1)
	}

	fmt.Printf("event-replayer\n")
	fmt.Printf("  source events : %d\n", len(events))
	fmt.Printf("  copies        : %d\n", *copies)
	fmt.Printf("  shift/copy    : %s\n", *shift)
	fmt.Printf("  total events  : %d\n", len(events)**copies)
	fmt.Printf("  target        : %s/api/v1/events\n", *target)
	fmt.Printf("  workers       : %d\n", *workers)
	fmt.Printf("  rate          : ")
	if *rate == 0 {
		fmt.Printf("unlimited\n")
	} else {
		fmt.Printf("%d events/s\n", *rate)
	}
	fmt.Println()

	if *dryRun {
		fmt.Println("[dry-run] Events loaded, nothing sent.")
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
		<-ch
		fmt.Println("\nInterrupted — stopping after current copy...")
		cancel()
	}()

	url := *target + "/api/v1/events"
	client := &http.Client{Timeout: 10 * time.Second}

	var totalSent, totalErrors atomic.Int64
	start := time.Now()

	for copyIdx := 1; copyIdx <= *copies; copyIdx++ {
		if ctx.Err() != nil {
			break
		}

		offset := time.Duration(copyIdx) * *shift
		fmt.Printf("[%s] copy %d/%d  shift=-%s\n",
			time.Now().Format("15:04:05"), copyIdx, *copies, offset)

		sent, errs := sendCopy(ctx, events, url, *token, *workers, *rate, offset, client)
		totalSent.Add(int64(sent))
		totalErrors.Add(int64(errs))

		elapsed := time.Since(start).Seconds()
		evTotal := totalSent.Load()
		fmt.Printf("  → sent=%d errors=%d  cumulative=%d rate=%.0f/s\n",
			sent, errs, evTotal, float64(evTotal)/elapsed)

		if *pauseBetween > 0 && copyIdx < *copies {
			fmt.Printf("  pausing %s for pipeline drain...\n", *pauseBetween)
			select {
			case <-ctx.Done():
			case <-time.After(*pauseBetween):
			}
		}
	}

	elapsed := time.Since(start)
	fmt.Printf("\nDone: %d sent, %d errors in %s (%.0f events/s)\n",
		totalSent.Load(), totalErrors.Load(), elapsed.Round(time.Second),
		float64(totalSent.Load())/elapsed.Seconds())
}

// sendCopy sends all events shifted by the given offset duration.
func sendCopy(ctx context.Context, events []json.RawMessage, url, token string,
	numWorkers, rateLimit int, offset time.Duration, client *http.Client) (sent, errs int) {

	// We shift time by subtracting offset so that copy 1 = 1 shift in the past,
	// copy 2 = 2 shifts in the past, etc. This produces historically-ordered data.
	shiftTo := func(original time.Time) time.Time {
		return original.Add(-offset)
	}

	type result struct{ sent, err int }
	results := make(chan result, numWorkers)

	ch := make(chan json.RawMessage, numWorkers*4)
	var wg sync.WaitGroup

	// Rate limiter
	var ticker *time.Ticker
	var tickCh <-chan time.Time
	if rateLimit > 0 {
		interval := time.Second / time.Duration(rateLimit/numWorkers+1)
		ticker = time.NewTicker(interval)
		defer ticker.Stop()
		tickCh = ticker.C
	}

	for i := 0; i < numWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s, e := 0, 0
			for raw := range ch {
				if ctx.Err() != nil {
					break
				}
				if tickCh != nil {
					select {
					case <-tickCh:
					case <-ctx.Done():
						break
					}
				}
				if sendEvent(client, url, token, raw, shiftTo) {
					s++
				} else {
					e++
				}
			}
			results <- result{s, e}
		}()
	}

	go func() {
		for _, ev := range events {
			select {
			case ch <- ev:
			case <-ctx.Done():
				break
			}
		}
		close(ch)
		wg.Wait()
		close(results)
	}()

	for r := range results {
		sent += r.sent
		errs += r.err
	}
	return
}

// sendEvent patches the time field in the CloudEvent and POSTs it.
func sendEvent(client *http.Client, url, token string, raw json.RawMessage, shiftTo func(time.Time) time.Time) bool {
	var ev map[string]json.RawMessage
	if err := json.Unmarshal(raw, &ev); err != nil {
		return false
	}

	// Shift the time field
	var t time.Time
	if tRaw, ok := ev["time"]; ok {
		if err := json.Unmarshal(tRaw, &t); err == nil {
			shifted := shiftTo(t)
			if tb, err := json.Marshal(shifted); err == nil {
				ev["time"] = tb
			}
		}
	}

	// Generate a new unique ID to avoid duplicate rejection
	if idRaw, ok := ev["id"]; ok {
		var id string
		if json.Unmarshal(idRaw, &id) == nil {
			newID, _ := json.Marshal(fmt.Sprintf("%s-r%x", id, rand.Int31()))
			ev["id"] = newID
		}
	}

	body, err := json.Marshal(ev)
	if err != nil {
		return false
	}

	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return false
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == http.StatusNoContent || resp.StatusCode == http.StatusAccepted
}

// loadEvents reads JSONL from a file or stdin.
func loadEvents(path string) ([]json.RawMessage, error) {
	var f *os.File
	if path == "-" {
		f = os.Stdin
	} else {
		var err error
		f, err = os.Open(path)
		if err != nil {
			return nil, err
		}
		defer f.Close()
	}

	var events []json.RawMessage
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 4*1024*1024), 4*1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 || line[0] != '{' {
			continue
		}
		cp := make([]byte, len(line))
		copy(cp, line)
		events = append(events, json.RawMessage(cp))
	}
	return events, scanner.Err()
}
