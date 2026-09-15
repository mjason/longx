//go:build windows

package main

import (
	"errors"
	"os"
	"os/exec"
)

// No pty on Windows: codex keeps its own executor there (ConPTY included).
func openPty() (master, slave *os.File, err error) {
	return nil, nil, errors.New("pty: not supported on Windows")
}

func setWindowSize(master *os.File, rows, cols uint16) error { return nil }

func attachPty(proc *exec.Cmd, slave *os.File) {}
