//go:build linux

package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// Linux: /dev/ptmx hands out a master; the slave is /dev/pts/<n> once the
// lock is lifted (the ioctls glibc's unlockpt/ptsname use).
const (
	ioctlTIOCSPTLCK = 0x40045431
	ioctlTIOCGPTN   = 0x80045430
	ioctlTIOCSWINSZ = 0x5414
)

func openPty() (master, slave *os.File, err error) {
	master, err = os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	var unlock int32
	if err := ioctl(master.Fd(), ioctlTIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); err != nil {
		master.Close()
		return nil, nil, fmt.Errorf("unlockpt: %w", err)
	}
	var n uint32
	if err := ioctl(master.Fd(), ioctlTIOCGPTN, uintptr(unsafe.Pointer(&n))); err != nil {
		master.Close()
		return nil, nil, fmt.Errorf("ptsname: %w", err)
	}
	slave, err = os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		master.Close()
		return nil, nil, err
	}
	return master, slave, nil
}
