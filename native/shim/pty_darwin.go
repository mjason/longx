//go:build darwin

package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// macOS: grant + unlock the pty, then ask the master for its slave's name
// (TIOCPTYGNAME fills a 128-byte buffer).
const (
	ioctlTIOCPTYGRANT = 0x20007454
	ioctlTIOCPTYUNLK  = 0x20007452
	ioctlTIOCPTYGNAME = 0x40807453
	ioctlTIOCSWINSZ   = 0x80087467
)

func openPty() (master, slave *os.File, err error) {
	master, err = os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	if err := ioctl(master.Fd(), ioctlTIOCPTYGRANT, 0); err != nil {
		master.Close()
		return nil, nil, fmt.Errorf("grantpt: %w", err)
	}
	if err := ioctl(master.Fd(), ioctlTIOCPTYUNLK, 0); err != nil {
		master.Close()
		return nil, nil, fmt.Errorf("unlockpt: %w", err)
	}
	var name [128]byte
	if err := ioctl(master.Fd(), ioctlTIOCPTYGNAME, uintptr(unsafe.Pointer(&name[0]))); err != nil {
		master.Close()
		return nil, nil, fmt.Errorf("ptsname: %w", err)
	}
	end := 0
	for end < len(name) && name[end] != 0 {
		end++
	}
	slave, err = os.OpenFile(string(name[:end]), os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		master.Close()
		return nil, nil, err
	}
	return master, slave, nil
}
