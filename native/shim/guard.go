package main

import "encoding/json"

// treeStats describes the child's whole process tree at one instant.
type treeStats struct {
	Processes int    `json:"processes"`
	RSSBytes  uint64 `json:"rss_bytes"`
	CPUMillis int64  `json:"cpu_ms"`
}

func encodeStats(s treeStats) []byte {
	b, err := json.Marshal(s)
	if err != nil {
		return []byte(`{"processes":0,"rss_bytes":0,"cpu_ms":0}`)
	}
	return b
}

// stats answers the host's SendStats; an exited child has an empty tree.
func (c *child) stats() treeStats {
	if c.proc.ProcessState != nil {
		return treeStats{}
	}
	return collectStats(c)
}
