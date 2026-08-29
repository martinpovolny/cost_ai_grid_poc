package api

import (
	"encoding/json"
	"log/slog"
	"testing"
	"time"
)

func TestValidateCloudEventAcceptsCanonicalOSACv1(t *testing.T) {
	h := &APIHandler{logger: slog.Default()}
	data, err := json.Marshal(meteringData{
		ResourceID: "vm-1", ResourceType: "compute_instance", TenantID: "tenant-1",
		CurrentState: "RUNNING", TransitionTime: time.Now().UTC().Format(time.RFC3339),
		SchemaVersion: "v1",
	})
	if err != nil {
		t.Fatal(err)
	}
	event := cloudEventInternal{
		SpecVersion: "1.0", ID: "event-1", Source: "osac-metering", Type: eventTypeResourceCreated,
		Time: time.Now().UTC(), Data: data,
		OSACResourceID: "vm-1", OSACResourceType: "compute_instance", OSACTenant: "tenant-1",
	}
	if err := h.validateCloudEvent(event); err != nil {
		t.Fatalf("canonical OSAC v1 event rejected: %v", err)
	}
}

func TestValidateCloudEventRejectsMismatchedOSACv1Identity(t *testing.T) {
	h := &APIHandler{logger: slog.Default()}
	data := json.RawMessage(`{"resource_id":"vm-2","resource_type":"compute_instance","tenant_id":"tenant-1","current_state":"RUNNING","schema_version":"v1"}`)
	event := cloudEventInternal{
		SpecVersion: "1.0", ID: "event-2", Source: "osac-metering", Type: eventTypeResourceCreated,
		Time: time.Now().UTC(), Data: data,
		OSACResourceID: "vm-1", OSACResourceType: "compute_instance", OSACTenant: "tenant-1",
	}
	if err := h.validateCloudEvent(event); err == nil {
		t.Fatal("mismatched OSAC v1 identity was accepted")
	}
}

func TestCloudEventDigestIsStable(t *testing.T) {
	event := cloudEventInternal{
		SpecVersion: "1.0", ID: "event-3", Source: "osac-metering", Type: eventTypeResourceCreated,
		Time: time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC), Data: json.RawMessage(`{"resource_id":"vm-1"}`),
	}
	first, err := cloudEventDigest(event)
	if err != nil {
		t.Fatal(err)
	}
	second, err := cloudEventDigest(event)
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("digest is not stable: %s != %s", first, second)
	}
}
