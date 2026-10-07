//go:build linux

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// systemd's DelegateSubgroup=supervisor keeps the BEAM and shim outside this
// sibling subtree. Limits on tasks also bound the sum of concurrent commands.
// No process is moved after exec: CLONE_INTO_CGROUP is used by os/exec.
type taskCgroup struct {
	path string
	fd   *os.File
}

var errUnsafeCgroup = errors.New("previous task containment is unresolved")

func cgroupStatus() cgroupCapability {
	unavailable := func(err error) cgroupCapability {
		return cgroupCapability{Status: "unavailable", Reason: err.Error()}
	}
	membership, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return unavailable(err)
	}
	mounts, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return unavailable(err)
	}
	root, err := delegatedRoot(string(membership), string(mounts))
	if err != nil {
		return unavailable(err)
	}
	if err := inspectDelegation(root); err != nil {
		return unavailable(err)
	}
	return cgroupCapability{
		Status: "eligible",
		Path:   root,
		Reason: "delegation prerequisites detected; task startup must still verify kernel and permission support",
	}
}

// Do not create groups, enable controllers, issue kills, or change service
// configuration merely to draw the settings page.
func inspectDelegation(root string) error {
	var stat unix.Statfs_t
	if err := unix.Statfs(root, &stat); err != nil {
		return err
	}
	if stat.Type != unix.CGROUP2_SUPER_MAGIC {
		return errors.New("root is not a cgroup v2 filesystem")
	}
	actual, err := filepath.EvalSymlinks(root)
	if err != nil || actual != root {
		return errors.New("delegated root must not contain symlinks")
	}
	marker := make([]byte, 16)
	size, err := unix.Getxattr(root, "user.delegate", marker)
	if err != nil {
		if !errors.Is(err, unix.ENODATA) && !errors.Is(err, unix.EOPNOTSUPP) {
			return fmt.Errorf("cannot verify systemd cgroup delegation marker: %w", err)
		}
		if err := verifySystemdDelegation(root); err != nil {
			return err
		}
	} else if string(marker[:size]) != "1" {
		return errors.New("systemd cgroup delegation marker is absent")
	}
	procs, err := os.ReadFile(filepath.Join(root, "cgroup.procs"))
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(procs)) != "" {
		return errors.New("delegated root contains supervisor processes")
	}
	controllers, err := os.ReadFile(filepath.Join(root, "cgroup.controllers"))
	if err != nil {
		return err
	}
	if !strings.Contains(" "+strings.TrimSpace(string(controllers))+" ", " memory ") {
		return errors.New("memory controller is unavailable")
	}
	if err := unix.Access(root, unix.W_OK|unix.X_OK); err != nil {
		return fmt.Errorf("delegated root is not writable: %w", err)
	}
	return inspectDelegationControls(root)
}

func inspectDelegationControls(root string) error {
	// Parent attributes remain the manager's property. Only the delegation
	// control is a preflight prerequisite; task cgroup.kill is checked on the
	// newly created leaf before starting its payload, never on the parent.
	file, err := os.OpenFile(filepath.Join(root, "cgroup.subtree_control"), os.O_WRONLY, 0)
	if err != nil {
		return fmt.Errorf("cgroup.subtree_control is not accessible: %w", err)
	}
	return file.Close()
}

// Some user managers do not publish user.delegate even when delegation is
// enabled. In that case ask the manager, and verify the exact membership, not
// just a basename or the fact that the directory is writable.
func verifySystemdDelegation(root string) error {
	membership, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return err
	}
	var expected string
	for _, line := range strings.Split(string(membership), "\n") {
		if strings.HasPrefix(line, "0::") {
			expected = filepath.Dir(strings.TrimPrefix(line, "0::"))
		}
	}
	unit := filepath.Base(root)
	if filepath.Base(expected) != unit || (!strings.HasSuffix(unit, ".service") && !strings.HasSuffix(unit, ".scope")) {
		return errors.New("cannot verify systemd delegation for this subtree")
	}
	for _, user := range []bool{true, false} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		args := []string{"show", unit, "--property=Delegate", "--property=ControlGroup"}
		if user {
			args = append([]string{"--user"}, args...)
		}
		raw, err := exec.CommandContext(ctx, "systemctl", args...).Output()
		cancel()
		if err == nil && matchesDelegation(string(raw), expected) {
			return nil
		}
	}
	return errors.New("systemd delegation could not be verified (missing marker and no matching delegated unit)")
}

func matchesDelegation(raw, expected string) bool {
	delegated, group := false, ""
	for _, line := range strings.Split(raw, "\n") {
		if line == "Delegate=yes" {
			delegated = true
		}
		if strings.HasPrefix(line, "ControlGroup=") {
			group = strings.TrimPrefix(line, "ControlGroup=")
		}
	}
	return delegated && expected != "" && group == expected
}

func setupGuard(c *child, cfg config) error {
	mode := cfg.Cgroup
	if mode == "" {
		mode = "off"
	}
	if mode != "off" && mode != "auto" && mode != "required" {
		return fmt.Errorf("invalid cgroup mode %q", mode)
	}
	if cfg.MemoryMax < 0 || cfg.SwapMax < 0 {
		return errors.New("cgroup memory and swap limits must be nonnegative")
	}
	if mode == "off" {
		return nil
	}
	c.resourceGuard = &resourceGuard{Status: "unavailable"}
	root := cfg.CgroupRoot
	var err error
	if root != "" {
		if !filepath.IsAbs(root) || filepath.Clean(root) != root || root == "/" || root == "/sys/fs/cgroup" {
			return errors.New("cgroup_root must be a specific, absolute delegated subtree")
		}
	} else {
		membership, readErr := os.ReadFile("/proc/self/cgroup")
		mounts, mountErr := os.ReadFile("/proc/self/mountinfo")
		if readErr != nil {
			err = readErr
		} else if mountErr != nil {
			err = mountErr
		} else {
			root, err = delegatedRoot(string(membership), string(mounts))
			if err == nil {
				err = inspectDelegation(root)
			}
		}
	}
	if err == nil {
		err = prepareCgroup(c, cfg, root)
	}
	if err == nil {
		return nil
	}
	// Explicit requests never execute an uncontained workload.
	if mode == "required" || cfg.CgroupRoot != "" || errors.Is(err, errUnsafeCgroup) {
		return fmt.Errorf("task cgroup unavailable: %w", err)
	}
	c.resourceGuard.Reason = err.Error()
	logf("task cgroup unavailable: %v", err)
	return nil
}

func delegatedRoot(membership, mounts string) (string, error) {
	var current string
	for _, line := range strings.Split(membership, "\n") {
		if strings.HasPrefix(line, "0::") {
			current = strings.TrimPrefix(line, "0::")
		}
	}
	if !strings.HasPrefix(current, "/") || filepath.Clean(current) != current || filepath.Base(current) != "supervisor" {
		return "", errors.New("no delegated supervisor subgroup; install with systemd Delegate=yes and DelegateSubgroup=supervisor")
	}
	parent := filepath.Dir(current)
	if parent == "/" {
		return "", errors.New("refusing the root cgroup hierarchy")
	}
	for _, line := range strings.Split(mounts, "\n") {
		parts := strings.SplitN(line, " - ", 2)
		if len(parts) != 2 || !strings.HasPrefix(parts[1], "cgroup2 ") {
			continue
		}
		fields := strings.Fields(parts[0])
		if len(fields) < 5 {
			continue
		}
		mountRoot, mountPoint := unescapeMount(fields[3]), unescapeMount(fields[4])
		rel, err := filepath.Rel(mountRoot, parent)
		if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
			continue
		}
		root := filepath.Join(mountPoint, rel)
		if root == mountPoint {
			return "", errors.New("refusing to manage the cgroup mount root")
		}
		return root, nil
	}
	return "", errors.New("delegated cgroup v2 mount not found")
}

func unescapeMount(path string) string {
	return strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`).Replace(path)
}

func prepareCgroup(c *child, cfg config, root string) error {
	var stat unix.Statfs_t
	if err := unix.Statfs(root, &stat); err != nil {
		return err
	}
	if stat.Type != unix.CGROUP2_SUPER_MAGIC {
		return errors.New("root is not a cgroup v2 filesystem")
	}
	actual, err := filepath.EvalSymlinks(root)
	if err != nil || actual != root {
		return errors.New("delegated root must not contain symlinks")
	}
	procs, err := os.ReadFile(filepath.Join(root, "cgroup.procs"))
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(procs)) != "" {
		return errors.New("delegated root contains supervisor processes; refusing to move or limit them")
	}
	total, err := machineMemory()
	if err != nil {
		return err
	}
	if err := enableMemory(root); err != nil {
		return err
	}
	tasks := filepath.Join(root, "tasks")
	if err := os.Mkdir(tasks, 0700); err != nil && !os.IsExist(err) {
		return err
	}
	if actual, err := filepath.EvalSymlinks(tasks); err != nil || actual != tasks {
		return errors.New("task cgroup subtree must not contain symlinks")
	}
	// Constants are machine-wide, not a project's override. Concurrent writers
	// write identical values. Parent/ancestor limits remain in force.
	if err := writeControl(tasks, "memory.max", strconv.FormatInt(total/100*80, 10)); err != nil {
		return err
	}
	if err := writeControl(tasks, "memory.swap.max", "1073741824"); err != nil {
		return err
	}
	if err := enableMemory(tasks); err != nil {
		return err
	}
	if err := reapOrphanCgroups(tasks); err != nil {
		return err
	}

	memory := total / 100 * 75
	if cfg.MemoryMaxSet {
		memory = cfg.MemoryMax
	}
	swap := int64(1024 * 1024 * 1024)
	if cfg.SwapMaxSet {
		swap = cfg.SwapMax
	}
	ownerStart, err := processStart(os.Getpid())
	if err != nil {
		return err
	}
	name := fmt.Sprintf("job-%d-%s-%d", os.Getpid(), ownerStart, time.Now().UnixNano())
	path := filepath.Join(tasks, name)
	if err := os.Mkdir(path, 0700); err != nil {
		return err
	}
	ready := false
	defer func() {
		if !ready {
			os.Remove(path)
		}
	}()
	for name, value := range map[string]int64{"memory.max": memory, "memory.swap.max": swap, "memory.oom.group": 1} {
		if err := writeControl(path, name, strconv.FormatInt(value, 10)); err != nil {
			return err
		}
	}
	// Probe permissions without issuing a kill: the kernel's kill sequence
	// also participates in CLONE_INTO_CGROUP's concurrent-fork protection.
	killFile, err := os.OpenFile(filepath.Join(path, "cgroup.kill"), os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	killFile.Close()
	fd, err := os.Open(path)
	if err != nil {
		return err
	}
	c.guard.cgroup = &taskCgroup{path: path, fd: fd}
	c.proc.SysProcAttr.UseCgroupFD = true
	c.proc.SysProcAttr.CgroupFD = int(fd.Fd())
	c.resourceGuard = &resourceGuard{Status: "active", Path: path, MemoryMax: memory, SwapMax: swap}
	ready = true
	return nil
}

func machineMemory() (int64, error) {
	raw, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 3 && fields[0] == "MemTotal:" {
			kb, err := strconv.ParseInt(fields[1], 10, 64)
			if err == nil && kb > 0 {
				return kb * 1024, nil
			}
		}
	}
	return 0, errors.New("cannot determine total memory for shared task budget")
}

func enableMemory(path string) error {
	enabled, err := os.ReadFile(filepath.Join(path, "cgroup.subtree_control"))
	if err != nil {
		return err
	}
	if strings.Contains(" "+strings.TrimSpace(string(enabled))+" ", " memory ") {
		return nil
	}
	return writeControl(path, "cgroup.subtree_control", "+memory")
}

func writeControl(path, name, value string) error {
	// Never create ordinary files on a fake/incorrect cgroup mount.
	file, err := os.OpenFile(filepath.Join(path, name), os.O_WRONLY, 0)
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	defer file.Close()
	if _, err := file.WriteString(value); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}

func (g *taskCgroup) kill() {
	logf("terminating task cgroup %s", g.path)
	if err := writeControl(g.path, "cgroup.kill", "1"); err != nil {
		logf("cgroup kill: %v", err)
	}
}

func closeGuardFD(c *child) {
	if g := c.guard.cgroup; g != nil && g.fd != nil {
		g.fd.Close()
	}
}

func cleanupGuard(c *child) *resourceExit {
	c.cleanupOnce.Do(func() {
		if g := c.guard.cgroup; g != nil {
			logf("verifying task cgroup cleanup")
			g.kill()
			result := finishCgroup(g.path, 2*time.Second)
			if result.Populated {
				// Record the failed cleanup before reporting it. A new shim can
				// arrive while this owner is still alive, so PID liveness alone
				// is insufficient to prevent an unsafe restart.
				marker := filepath.Join(filepath.Dir(g.path), "blocked-"+filepath.Base(g.path))
				if err := os.Mkdir(marker, 0700); err != nil && !os.IsExist(err) {
					result.CleanupError += fmt.Sprintf("; failed to record quarantine: %v", err)
				}
			}
			c.resourceExit = &result
		}
	})
	return c.resourceExit
}

func finishCgroup(path string, timeout time.Duration) resourceExit {
	result := resourceExit{}
	deadline := time.Now().Add(timeout)
	for {
		events, err := os.ReadFile(filepath.Join(path, "cgroup.events"))
		if err != nil {
			result.Populated = true // unknown is not verified empty
			result.CleanupError = fmt.Sprintf("cannot verify task exit: %v", err)
			return result
		}
		populated, err := parseEvent(string(events), "populated")
		if err != nil || populated > 1 {
			result.Populated = true
			result.CleanupError = "cannot verify task exit: missing or invalid cgroup population"
			return result
		}
		result.Populated = populated != 0
		if !result.Populated || !time.Now().Before(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if events, err := os.ReadFile(filepath.Join(path, "memory.events")); err == nil {
		result.OOMKill = eventValue(string(events), "oom_kill")
	}
	if result.Populated {
		result.CleanupError = "task descendants still alive after cgroup.kill; cgroup retained, do not restart the workload"
	} else if err := os.Remove(path); err != nil {
		result.CleanupError = fmt.Sprintf("empty task cgroup could not be removed: %v", err)
	}
	return result
}

func eventValue(raw, key string) uint64 {
	n, _ := parseEvent(raw, key)
	return n
}

func parseEvent(raw, key string) (uint64, error) {
	for _, line := range strings.Split(raw, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == key {
			return strconv.ParseUint(fields[1], 10, 64)
		}
	}
	return 0, fmt.Errorf("missing cgroup event %s", key)
}

func processStart(pid int) (string, error) {
	raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return "", err
	}
	end := strings.LastIndexByte(string(raw), ')')
	if end < 0 {
		return "", errors.New("invalid process stat")
	}
	fields := strings.Fields(string(raw[end+1:]))
	if len(fields) < 20 {
		return "", errors.New("short process stat")
	}
	return fields[19], nil
}

func reapOrphanCgroups(tasks string) error {
	if err := reapQuarantinedCgroups(tasks, 2*time.Second); err != nil {
		return err
	}
	entries, err := os.ReadDir(tasks)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() || !strings.HasPrefix(e.Name(), "job-") {
			continue
		}
		parts := strings.Split(e.Name(), "-")
		if len(parts) != 4 {
			continue
		}
		pid, err := strconv.Atoi(parts[1])
		if err != nil {
			continue
		}
		start, err := processStart(pid)
		if err == nil && start == parts[2] {
			continue
		}
		if err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("%w: cannot verify cgroup owner: %v", errUnsafeCgroup, err)
		}
		path := filepath.Join(tasks, e.Name())
		g := taskCgroup{path: path}
		g.kill()
		result := finishCgroup(path, 2*time.Second)
		if result.Populated {
			return fmt.Errorf("%w: previous task cgroup is still populated: %s", errUnsafeCgroup, path)
		}
	}
	return nil
}

func reapQuarantinedCgroups(tasks string, timeout time.Duration) error {
	entries, err := os.ReadDir(tasks)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() || !strings.HasPrefix(e.Name(), "blocked-job-") {
			continue
		}
		path := filepath.Join(tasks, strings.TrimPrefix(e.Name(), "blocked-"))
		if _, err := os.Stat(path); err == nil {
			g := taskCgroup{path: path}
			g.kill()
			result := finishCgroup(path, timeout)
			if result.Populated || result.CleanupError != "" {
				return fmt.Errorf("%w: quarantined task %s: %s", errUnsafeCgroup, path, result.CleanupError)
			}
		} else if !os.IsNotExist(err) {
			return fmt.Errorf("%w: cannot inspect quarantined task: %v", errUnsafeCgroup, err)
		}
		if err := os.Remove(filepath.Join(tasks, e.Name())); err != nil {
			return fmt.Errorf("%w: cannot clear task quarantine: %v", errUnsafeCgroup, err)
		}
	}
	return nil
}
