//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestCgroupMountDiscovery(t *testing.T) {
	mounts := "31 20 0:29 / /sys/fs/cgroup rw - cgroup2 cgroup rw\n"
	root, err := delegatedRoot("0::/user.slice/longx.service/supervisor\n", mounts)
	if err != nil || root != "/sys/fs/cgroup/user.slice/longx.service" {
		t.Fatalf("root=%q err=%v", root, err)
	}
	// A cgroup namespace's mount may expose only a subtree.
	mounts = "31 20 0:29 /user.slice /cg rw - cgroup2 cgroup rw\n"
	root, err = delegatedRoot("0::/user.slice/longx.service/supervisor\n", mounts)
	if err != nil || root != "/cg/longx.service" {
		t.Fatalf("subtree root=%q err=%v", root, err)
	}
	for _, membership := range []string{"0::/\n", "0::/something.service\n", "0::/../../supervisor\n"} {
		if _, err := delegatedRoot(membership, mounts); err == nil {
			t.Fatalf("accepted unowned hierarchy: %q", membership)
		}
	}
}

func TestCgroupDelegationNeedsExactManagerConfirmation(t *testing.T) {
	for _, item := range []struct {
		raw  string
		want bool
	}{
		{"Delegate=yes\nControlGroup=/app.slice/longx.service\n", true},
		{"ControlGroup=/app.slice/longx.service\nDelegate=yes\n", true},
		{"Delegate=no\nControlGroup=/app.slice/longx.service\n", false},
		{"Delegate=yes\nControlGroup=/different/longx.service\n", false},
		{"Delegate=yes\n", false},
	} {
		if got := matchesDelegation(item.raw, "/app.slice/longx.service"); got != item.want {
			t.Fatalf("manager response %q: got %v want %v", item.raw, got, item.want)
		}
	}
}

func TestCgroupLimitsValidateBeforeLaunching(t *testing.T) {
	for _, cfg := range []config{
		{Cgroup: "invalid"},
		{Cgroup: "required", MemoryMax: -1},
		{Cgroup: "required", SwapMax: -1},
		{Cgroup: "required", CgroupRoot: "/"},
		{Cgroup: "required", CgroupRoot: "relative"},
	} {
		cfg.Args = []string{"true"}
		if _, err := startChild(cfg, nil); err == nil {
			t.Fatalf("accepted invalid cgroup config: %+v", cfg)
		}
	}
}

func TestExplicitUnavailableCgroupFailsClosed(t *testing.T) {
	root := filepath.Join(t.TempDir(), "missing")
	_, err := startChild(config{Args: []string{"true"}, Cgroup: "auto", CgroupRoot: root}, nil)
	if err == nil || !strings.Contains(err.Error(), "cgroup") {
		t.Fatalf("explicit root silently degraded: %v", err)
	}
}

func TestCgroupEventParsing(t *testing.T) {
	if got := eventValue("low 0\noom_kill 3\noom_group_kill 1\n", "oom_kill"); got != 3 {
		t.Fatalf("oom count: %d", got)
	}
	if eventValue("populated 1\nfrozen 0\n", "populated") != 1 {
		t.Fatal("missed a populated cgroup")
	}
}

func TestCgroupNeverRemovesAPopulatedGroup(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "job")
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "cgroup.events"), []byte("populated 1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	result := finishCgroup(path, 0)
	if !result.Populated || result.CleanupError == "" {
		t.Fatalf("claimed successful cleanup: %+v", result)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("removed evidence of a surviving task: %v", err)
	}
}

func TestCgroupMissingPopulationIsNotProofOfCleanup(t *testing.T) {
	path := t.TempDir()
	if err := os.WriteFile(filepath.Join(path, "cgroup.events"), []byte("frozen 0\n"), 0600); err != nil {
		t.Fatal(err)
	}
	result := finishCgroup(path, 0)
	if !result.Populated || result.CleanupError == "" {
		t.Fatalf("unknown group state treated as empty: %+v", result)
	}
}

func TestCgroupQuarantineBlocksRestartEvenWithLiveOwner(t *testing.T) {
	root := t.TempDir()
	start, err := processStart(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	name := "job-" + strconv.Itoa(os.Getpid()) + "-" + start + "-1"
	path := filepath.Join(root, name)
	marker := filepath.Join(root, "blocked-"+name)
	for _, dir := range []string{path, marker} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(path, "cgroup.events"), []byte("populated 1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := reapQuarantinedCgroups(root, 0); !errors.Is(err, errUnsafeCgroup) {
		t.Fatalf("allowed restart while owner still alive: %v", err)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("quarantine lost: %v", err)
	}
}

// Real containment tests run only in an explicitly delegated, bounded service,
// never by changing the cgroup of the running Longx or the developer's shell.
func TestCgroupIntegrationReadOnlyCapability(t *testing.T) {
	if os.Getenv("LONGX_CGROUP_TEST") != "1" {
		t.Skip("run in a delegated test service with LONGX_CGROUP_TEST=1")
	}
	membership, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		t.Fatal(err)
	}
	mounts, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		t.Fatal(err)
	}
	root, err := delegatedRoot(string(membership), string(mounts))
	if err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	controlBefore, err := os.ReadFile(filepath.Join(root, "cgroup.subtree_control"))
	if err != nil {
		t.Fatal(err)
	}
	report := cgroupStatus()
	if report.Status != "eligible" || report.Path != root {
		t.Fatalf("delegated service not detected: %+v", report)
	}
	after, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	controlAfter, err := os.ReadFile(filepath.Join(root, "cgroup.subtree_control"))
	if err != nil {
		t.Fatal(err)
	}
	if len(before) != len(after) || string(controlBefore) != string(controlAfter) {
		t.Fatal("capability probe changed the delegated hierarchy")
	}
	for i := range before {
		if before[i].Name() != after[i].Name() {
			t.Fatal("capability probe changed delegated entries")
		}
	}
}

func startCgroupTest(t *testing.T, cfg config) (*harness, resourceGuard) {
	t.Helper()
	if os.Getenv("LONGX_CGROUP_TEST") != "1" {
		t.Skip("run in a delegated test service with LONGX_CGROUP_TEST=1")
	}
	cfg.Cgroup = "required"
	cfg.MemoryMax = 64 * 1024 * 1024
	cfg.MemoryMaxSet = true
	cfg.SwapMaxSet = true
	cfg.Grace = 100 * time.Millisecond
	if err := initLogger("stderr"); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, cfg, nil)
	t.Cleanup(func() { h.closeHost() })
	packet := h.expect(TagResourceGuard)
	var info resourceGuard
	if err := json.Unmarshal(packet.Data, &info); err != nil {
		t.Fatal(err)
	}
	if info.Status != "active" {
		t.Fatalf("not contained: %+v", info)
	}
	pid, _ := decodeUint32(h.expect(TagPid).Data)
	h.pid = int(pid)
	return h, info
}

func cgroupExit(t *testing.T, h *harness) resourceExit {
	t.Helper()
	for {
		p := h.next()
		if p.Tag == TagOutputEOF || p.Tag == TagStderrEOF {
			continue
		}
		if p.Tag != TagResourceExit {
			t.Fatalf("expected resource exit, got %d (%q)", p.Tag, p.Data)
		}
		var result resourceExit
		if err := json.Unmarshal(p.Data, &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
}

func TestCgroupIntegrationChildContainedBeforeExec(t *testing.T) {
	h, info := startCgroupTest(t, config{Args: []string{"sh", "-c", "cat /proc/self/cgroup; read line"}, Stderr: "stream"})
	h.send(TagSendOutput, encodeUint32(4096))
	output := string(h.expect(TagOutput).Data)
	if !strings.Contains(output, filepath.Base(info.Path)) {
		t.Fatalf("child ran outside its cgroup: %q", output)
	}
	h.send(TagInput, []byte("\n"))
	h.send(TagCloseOutput, nil)
	h.send(TagCloseStderr, nil)
	result := cgroupExit(t, h)
	if result.Populated || result.CleanupError != "" {
		t.Fatalf("cleanup: %+v", result)
	}
	h.exitPacket()
	h.waitRun()
}

func TestCgroupIntegrationPtyKeepsContainment(t *testing.T) {
	h, info := startCgroupTest(t, config{
		Args: []string{"sh", "-c", "cat /proc/self/cgroup; read line"},
		PTY:  true,
	})
	h.send(TagSendOutput, encodeUint32(4096))
	output := string(h.expect(TagOutput).Data)
	if !strings.Contains(output, filepath.Base(info.Path)) {
		t.Fatalf("PTY child outside task cgroup: %q", output)
	}
	h.send(TagKill, encodeUint32(100))
	result := cgroupExit(t, h)
	if result.Populated || result.CleanupError != "" {
		t.Fatalf("PTY cleanup: %+v", result)
	}
	h.exitPacket()
	h.send(TagCloseOutput, nil)
	h.waitRun()
}

func TestCgroupIntegrationOOMStaysInsideTask(t *testing.T) {
	h, _ := startCgroupTest(t, config{
		Args:   []string{"python3", "-c", "x=bytearray(256*1024*1024)"},
		Stderr: "disable", NoStdin: true,
	})
	h.send(TagCloseOutput, nil)
	result := cgroupExit(t, h)
	if result.OOMKill == 0 || result.Populated || result.CleanupError != "" {
		t.Fatalf("not a verified task-local OOM: %+v", result)
	}
	h.expectExit(137)
	h.waitRun()
}

func TestCgroupIntegrationNormalExitKillsSetsidDescendant(t *testing.T) {
	h, info := startCgroupTest(t, config{
		Args:   []string{"sh", "-c", "setsid sleep 30 >/dev/null 2>&1 & sleep 0.2"},
		Stderr: "disable", NoStdin: true,
	})
	h.send(TagCloseOutput, nil)
	result := cgroupExit(t, h)
	if result.Populated || result.CleanupError != "" {
		t.Fatalf("escaped child survived: %+v", result)
	}
	if _, err := os.Stat(info.Path); !os.IsNotExist(err) {
		t.Fatalf("task cgroup survived: %v", err)
	}
	h.expectExit(0)
	h.waitRun()
}

func TestCgroupIntegrationKillAndHostLoss(t *testing.T) {
	for _, closeHost := range []bool{false, true} {
		t.Run(map[bool]string{false: "kill", true: "host-loss"}[closeHost], func(t *testing.T) {
			h, info := startCgroupTest(t, config{
				Args:   []string{"sh", "-c", "setsid sleep 30 >/dev/null 2>&1 & exec sleep 30"},
				Stderr: "disable", NoStdin: true,
			})
			if closeHost {
				h.closeHost()
			} else {
				h.send(TagKill, encodeUint32(100))
				cgroupExit(t, h)
				h.exitPacket()
				h.send(TagCloseOutput, nil)
			}
			h.waitRun()
			if _, err := os.Stat(info.Path); !os.IsNotExist(err) {
				t.Fatalf("task cgroup survived: %v", err)
			}
		})
	}
}

func TestCgroupIntegrationReapsAbandonedSetsidTask(t *testing.T) {
	h, info := startCgroupTest(t, config{
		Args: []string{"sleep", "30"}, Stderr: "disable", NoStdin: true,
	})
	tasks := filepath.Dir(info.Path)
	orphan := filepath.Join(tasks, "job-2147483647-0-1")
	if err := os.Mkdir(orphan, 0700); err != nil {
		t.Fatal(err)
	}
	for name, value := range map[string]string{
		"memory.max": "67108864", "memory.swap.max": "0", "memory.oom.group": "1",
	} {
		if err := writeControl(orphan, name, value); err != nil {
			t.Fatal(err)
		}
	}
	fd, err := os.Open(orphan)
	if err != nil {
		t.Fatal(err)
	}
	proc := exec.Command("sleep", "30")
	proc.SysProcAttr = &syscall.SysProcAttr{Setsid: true, UseCgroupFD: true, CgroupFD: int(fd.Fd())}
	if err := proc.Start(); err != nil {
		fd.Close()
		t.Fatal(err)
	}
	fd.Close()
	t.Cleanup(func() { proc.Process.Kill(); proc.Wait(); os.Remove(orphan) })
	if err := reapOrphanCgroups(tasks); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatalf("orphan retained: %v", err)
	}
	h.send(TagKill, encodeUint32(100))
	result := cgroupExit(t, h)
	if result.Populated || result.CleanupError != "" {
		t.Fatalf("live task cleanup: %+v", result)
	}
	h.exitPacket()
	h.send(TagCloseOutput, nil)
	h.waitRun()
}
