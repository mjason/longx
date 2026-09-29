//go:build linux

package main

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// OOM ordering and process-tree statistics for the host. Linux only —
// Windows uses a Job object (compile-checked, exercised in CI).

func readOOMScoreAdj(t *testing.T, pid int) int {
	t.Helper()
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/oom_score_adj")
	if err != nil {
		t.Fatal(err)
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestOOMScoreAdjIsInheritedByTheChild(t *testing.T) {
	cfg := config{Args: []string{"sleep", "30"}, Stderr: "stream", Grace: time.Second, OOMScoreAdj: 500}
	h := newHarness(t, cfg, nil)
	p := h.expect(TagPid)
	pid, _ := decodeUint32(p.Data)

	if got := readOOMScoreAdj(t, int(pid)); got != 500 {
		t.Fatalf("child oom_score_adj: want 500 got %d", got)
	}
	h.send(TagKill, encodeUint32(1000))
	h.exitPacket()
	h.waitRun()
}

func TestStatsCoverTheWholeProcessTree(t *testing.T) {
	// a parent shell with a child that allocates and holds ~32 MiB
	script := "python3 -c 'import time; b = bytearray(32*1024*1024); time.sleep(30)' & sleep 30"
	h := start(t, "sh", "-c", script)
	time.Sleep(300 * time.Millisecond)

	h.send(TagSendStats, nil)
	p := h.expect(TagStats)

	var stats treeStats
	if err := json.Unmarshal(p.Data, &stats); err != nil {
		t.Fatalf("stats payload %q: %v", p.Data, err)
	}
	if stats.Processes < 3 {
		t.Fatalf("processes: want >= 3 (sh, python3, sleep) got %d", stats.Processes)
	}
	if stats.RSSBytes < 32*1024*1024 {
		t.Fatalf("rss: want >= 32 MiB got %d", stats.RSSBytes)
	}
	if stats.CPUMillis < 0 {
		t.Fatalf("cpu: %d", stats.CPUMillis)
	}

	h.send(TagKill, encodeUint32(1000))
	h.exitPacket()
	h.waitRun()
}

func TestStatsAfterExitAreZero(t *testing.T) {
	h := start(t, "true")
	h.exitPacket()
	h.send(TagSendStats, nil)
	p := h.expect(TagStats)
	var stats treeStats
	if err := json.Unmarshal(p.Data, &stats); err != nil {
		t.Fatal(err)
	}
	if stats.Processes != 0 || stats.RSSBytes != 0 {
		t.Fatalf("want empty stats, got %+v", stats)
	}
	h.waitRun()
}
