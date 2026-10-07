//go:build !linux

package main

// These platforms keep their existing process-group / Windows Job protection.
func setupGuard(_ *child, _ config) error { return nil }
func closeGuardFD(_ *child)               {}
func cleanupGuard(_ *child) *resourceExit { return nil }

func cgroupStatus() cgroupCapability {
	return cgroupCapability{Status: "unavailable", Reason: "task cgroup protection is Linux-only"}
}
