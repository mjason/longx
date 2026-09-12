//go:build linux

package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

// guard has nothing to hold on Linux: the OOM score is inherited and the
// address-space limit lives in the child.
type guard struct{}

// kill: nothing beyond the process-group signal on this platform.
func (g guard) kill() {}

// beforeStart raises our own oom_score_adj so the child tree inherits it.
// Raising never needs privileges; lowering would (CAP_SYS_RESOURCE), which
// is why the BEAM keeps 0 and the tree goes up.
func beforeStart(cfg config) error {
	if cfg.OOMScoreAdj == 0 {
		return nil
	}
	return os.WriteFile("/proc/self/oom_score_adj", []byte(strconv.Itoa(cfg.OOMScoreAdj)), 0)
}

// afterStart caps the child's address space; its descendants inherit the
// limit. Applied via prlimit(2) so the shim's own Go runtime is untouched.
func afterStart(c *child, cfg config) error {
	if cfg.MemoryLimit == 0 {
		return nil
	}
	limit := syscall.Rlimit{Cur: cfg.MemoryLimit, Max: cfg.MemoryLimit}
	_, _, errno := syscall.RawSyscall6(syscall.SYS_PRLIMIT64,
		uintptr(c.proc.Process.Pid), uintptr(syscall.RLIMIT_AS),
		uintptr(unsafe.Pointer(&limit)), 0, 0, 0)
	if errno != 0 {
		return fmt.Errorf("prlimit(RLIMIT_AS, %d): %v", cfg.MemoryLimit, errno)
	}
	return nil
}

// collectStats walks /proc and sums every descendant of the child (by parent
// pid, so re-grouped sandboxed commands are included too).
func collectStats(c *child) treeStats {
	root := c.proc.Process.Pid
	type proc struct {
		ppid  int
		ticks int64
	}
	procs := map[int]proc{}

	entries, err := os.ReadDir("/proc")
	if err != nil {
		return treeStats{}
	}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		ppid, ticks, ok := readStat(pid)
		if ok {
			procs[pid] = proc{ppid: ppid, ticks: ticks}
		}
	}

	// descendants of root, breadth first
	children := map[int][]int{}
	for pid, p := range procs {
		children[p.ppid] = append(children[p.ppid], pid)
	}
	var stats treeStats
	var ticks int64
	queue := []int{root}
	for len(queue) > 0 {
		pid := queue[0]
		queue = queue[1:]
		p, ok := procs[pid]
		if !ok {
			continue
		}
		stats.Processes++
		stats.RSSBytes += readRSS(pid)
		ticks += p.ticks
		queue = append(queue, children[pid]...)
	}
	stats.CPUMillis = ticks * 1000 / clockTicks()
	return stats
}

// readStat returns ppid and utime+stime (clock ticks) from /proc/<pid>/stat.
func readStat(pid int) (ppid int, ticks int64, ok bool) {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return 0, 0, false
	}
	// the comm field is parenthesised and may contain spaces: split after it
	end := bytes.LastIndexByte(raw, ')')
	if end < 0 {
		return 0, 0, false
	}
	fields := strings.Fields(string(raw[end+1:]))
	// fields[0] = state, [1] = ppid, [11] = utime, [12] = stime
	if len(fields) < 13 {
		return 0, 0, false
	}
	ppid, err = strconv.Atoi(fields[1])
	if err != nil {
		return 0, 0, false
	}
	utime, _ := strconv.ParseInt(fields[11], 10, 64)
	stime, _ := strconv.ParseInt(fields[12], 10, 64)
	return ppid, utime + stime, true
}

func readRSS(pid int) uint64 {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/statm")
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(raw))
	if len(fields) < 2 {
		return 0
	}
	pages, _ := strconv.ParseUint(fields[1], 10, 64)
	return pages * uint64(os.Getpagesize())
}

// clockTicks is CLK_TCK, read from our auxiliary vector (AT_CLKTCK = 17).
func clockTicks() int64 {
	raw, err := os.ReadFile("/proc/self/auxv")
	if err == nil {
		for i := 0; i+16 <= len(raw); i += 16 {
			key := binary.LittleEndian.Uint64(raw[i:])
			if key == 17 {
				return int64(binary.LittleEndian.Uint64(raw[i+8:]))
			}
		}
	}
	return 100
}
