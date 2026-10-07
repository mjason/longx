package main

import (
	"encoding/json"
	"fmt"
)

// This is a read-only preflight, not a task start. Only the resource-guard
// frame of a successfully started task can attest to active containment.
type cgroupCapability struct {
	Status string `json:"status"`
	Reason string `json:"reason,omitempty"`
	Path   string `json:"path,omitempty"`
}

func cgroupStatusMain() int {
	raw, err := json.Marshal(cgroupStatus())
	if err != nil {
		return 1
	}
	fmt.Println(string(raw))
	return 0
}
