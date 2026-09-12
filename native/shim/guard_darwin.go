//go:build darwin

package main

import (
	"os/exec"
	"strconv"
	"strings"
)

type guard struct{}

// kill: nothing beyond the process-group signal on this platform.
func (g guard) kill() {}

// macOS has neither oom_score_adj nor a per-tree limit we can set from
// here; jetsam and memory compression are what the platform offers.
func beforeStart(cfg config) error { return nil }

func afterStart(c *child, cfg config) error {
	if cfg.MemoryLimit != 0 {
		logf("memory_limit is not supported on macOS; ignored")
	}
	return nil
}

// collectStats builds the tree from `ps` (pid, ppid, rss in KiB, cpu time).
func collectStats(c *child) treeStats {
	out, err := exec.Command("ps", "-axo", "pid=,ppid=,rss=,cputime=").Output()
	if err != nil {
		return treeStats{}
	}
	type proc struct {
		ppid int
		rss  uint64
		cpu  int64
	}
	procs := map[int]proc{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		pid, _ := strconv.Atoi(f[0])
		ppid, _ := strconv.Atoi(f[1])
		rss, _ := strconv.ParseUint(f[2], 10, 64)
		procs[pid] = proc{ppid: ppid, rss: rss * 1024, cpu: parseCPUTime(f[3])}
	}
	children := map[int][]int{}
	for pid, p := range procs {
		children[p.ppid] = append(children[p.ppid], pid)
	}
	var stats treeStats
	queue := []int{c.proc.Process.Pid}
	for len(queue) > 0 {
		pid := queue[0]
		queue = queue[1:]
		p, ok := procs[pid]
		if !ok {
			continue
		}
		stats.Processes++
		stats.RSSBytes += p.rss
		stats.CPUMillis += p.cpu
		queue = append(queue, children[pid]...)
	}
	return stats
}

// parseCPUTime reads ps's [[dd-]hh:]mm:ss.cc into milliseconds.
func parseCPUTime(s string) int64 {
	days := int64(0)
	if i := strings.IndexByte(s, '-'); i >= 0 {
		days, _ = strconv.ParseInt(s[:i], 10, 64)
		s = s[i+1:]
	}
	parts := strings.Split(s, ":")
	var secs float64
	for _, p := range parts {
		v, _ := strconv.ParseFloat(p, 64)
		secs = secs*60 + v
	}
	return (days*86400+int64(secs))*1000 + int64((secs-float64(int64(secs)))*1000)
}
