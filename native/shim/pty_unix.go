//go:build !windows

package main

import (
	"os"
	"os/exec"
	"syscall"
	"unsafe"
)

// A command asked to run on a terminal (`-pty`): the child gets the slave
// as stdin, stdout and stderr and becomes the session leader owning it;
// the host reads and writes the master as the child's one output stream.
// Signals still reach the whole tree: a new session is a new process
// group, so the group kill by pid keeps working.

func ioctl(fd uintptr, request uintptr, arg uintptr) error {
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, arg); errno != 0 {
		return errno
	}
	return nil
}

type winsize struct {
	rows, cols, xpixel, ypixel uint16
}

// setWindowSize gives the terminal a size before the child looks (80×24,
// what codex's own executor uses when nobody says otherwise).
func setWindowSize(master *os.File, rows, cols uint16) error {
	ws := winsize{rows: rows, cols: cols}
	return ioctl(master.Fd(), ioctlTIOCSWINSZ, uintptr(unsafe.Pointer(&ws)))
}

// attachPty wires the slave end to the child and makes it the child's
// controlling terminal (Setsid + Setctty on fd 0).
func attachPty(proc *exec.Cmd, slave *os.File) {
	proc.Stdin = slave
	proc.Stdout = slave
	proc.Stderr = slave
	proc.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
}
