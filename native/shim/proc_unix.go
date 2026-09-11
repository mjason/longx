//go:build !windows

package main

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

// setProcessGroup puts the child in its own process group so signals reach
// every descendant (codex spawns sandboxed commands of its own).
func setProcessGroup(proc *exec.Cmd) {
	proc.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func killGroup(p *os.Process, sig syscall.Signal) {
	if err := syscall.Kill(-p.Pid, sig); err != nil && !errors.Is(err, syscall.ESRCH) {
		logf("kill(-%d, %v): %v", p.Pid, sig, err)
	}
}

func softKillTree(p *os.Process) { killGroup(p, syscall.SIGTERM) }
func hardKillTree(p *os.Process) { killGroup(p, syscall.SIGKILL) }

// signal forwards a host-requested signal to the process group.
func (c *child) signal(sig int) {
	killGroup(c.proc.Process, syscall.Signal(sig))
}

func shutdownSignals() []os.Signal {
	return []os.Signal{os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGPIPE}
}

// exitStatus mirrors shell conventions: the exit code, or 128+signal when the
// child was killed by a signal. -1 if Wait failed for another reason.
func exitStatus(err error) int32 {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		if ws, ok := exitErr.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int32(ws.Signal())
		}
		return int32(exitErr.ExitCode())
	}
	return -1
}
