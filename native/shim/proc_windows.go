//go:build windows

package main

import (
	"errors"
	"os"
	"os/exec"
	"strconv"
	"syscall"
)

var (
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	generateConsoleCtrlEvent = kernel32.NewProc("GenerateConsoleCtrlEvent")
)

const ctrlBreakEvent = 1

// setProcessGroup gives the child its own console process group so a
// CTRL_BREAK can be aimed at it (and its descendants) without hitting us.
func setProcessGroup(proc *exec.Cmd) {
	proc.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}

// softKillTree is the closest Windows has to SIGTERM for a console program.
func softKillTree(p *os.Process) {
	r, _, err := generateConsoleCtrlEvent.Call(uintptr(ctrlBreakEvent), uintptr(p.Pid))
	if r == 0 {
		logf("GenerateConsoleCtrlEvent(%d): %v", p.Pid, err)
	}
}

// hardKillTree kills the process and every descendant.
func hardKillTree(p *os.Process) {
	cmd := exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(p.Pid))
	if out, err := cmd.CombinedOutput(); err != nil {
		logf("taskkill %d: %v: %s", p.Pid, err, out)
		_ = p.Kill()
	}
}

// reapLeftovers: the command is done, and what it left running in its Job goes
// with it (the Job would take them only when the shim exits — and a leftover
// holding the output kept the shim from exiting)
func (c *child) reapLeftovers() { c.guard.kill() }

// signal maps POSIX numbers onto what Windows can do: SIGINT/SIGTERM become
// CTRL_BREAK, anything else is a hard kill.
func (c *child) signal(sig int) {
	switch sig {
	case 2, 15:
		softKillTree(c.proc.Process)
	default:
		hardKillTree(c.proc.Process)
	}
}

func shutdownSignals() []os.Signal {
	return []os.Signal{os.Interrupt, syscall.SIGTERM}
}

func exitStatus(err error) int32 {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return int32(exitErr.ExitCode())
	}
	return -1
}
