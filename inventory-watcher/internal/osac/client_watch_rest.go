//go:build rest_watch

package osac

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// WatchEvents opens a streaming HTTP connection to the OSAC REST events
// endpoint (NDJSON). Blocks until the context is cancelled or the stream ends.
func (c *Client) WatchEvents(ctx context.Context, handler func(Event) error) error {
	streamClient := &http.Client{
		Transport: c.httpClient.Transport,
	}

	url := c.baseURL + "/api/private/v1/events/watch"
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return fmt.Errorf("creating watch request: %w", err)
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}

	resp, err := streamClient.Do(req)
	if err != nil {
		return fmt.Errorf("watch request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("watch returned status %d: %s", resp.StatusCode, body)
	}

	c.logger.Info("watch stream connected", "transport", "rest")

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 1024*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var watchResp EventsWatchResponse
		if err := json.Unmarshal(line, &watchResp); err != nil {
			c.logger.Warn("failed to parse event", "error", err, "line", string(line))
			continue
		}

		if watchResp.Result == nil || watchResp.Result.Event == nil {
			continue
		}

		if err := handler(*watchResp.Result.Event); err != nil {
			c.logger.Error("event handler failed", "error", err, "eventID", watchResp.Result.Event.ID)
		}
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("watch stream error: %w", err)
	}

	return nil
}
