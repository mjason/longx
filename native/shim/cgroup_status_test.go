package main

import (
	"encoding/json"
	"testing"
)

func TestCgroupStatusIsReadOnlyAndDoesNotClaimActive(t *testing.T) {
	report := cgroupStatus()
	if report.Status != "eligible" && report.Status != "unavailable" {
		t.Fatalf("capability detection must not claim task protection: %+v", report)
	}
	if report.Status == "unavailable" && report.Reason == "" {
		t.Fatal("unavailable capability needs a visible reason")
	}
	raw, err := json.Marshal(report)
	if err != nil || !json.Valid(raw) {
		t.Fatalf("invalid status JSON: %s (%v)", raw, err)
	}
}
