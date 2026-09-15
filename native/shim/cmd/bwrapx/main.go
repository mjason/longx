package main

import (
	"fmt"
	"os"
	"strings"
	"syscall"
)

// Environment, set by Longx.Codex.Home when it prepares a project's codex:
//
//	LONGX_BWRAP_REAL         the bubblewrap to run (the one codex would have picked)
//	LONGX_BWRAP_PASSTHROUGH  host paths to expose, newline-separated (already resolved)
func main() {
	real := os.Getenv("LONGX_BWRAP_REAL")
	if real == "" {
		fmt.Fprintln(os.Stderr, "bwrapx: LONGX_BWRAP_REAL is not set")
		os.Exit(127)
	}
	args := os.Args[1:]
	if !Passthrough(args) {
		args = Rewrite(args, Classify(strings.Split(os.Getenv("LONGX_BWRAP_PASSTHROUGH"), "\n")))
	}
	if err := syscall.Exec(real, append([]string{real}, args...), os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "bwrapx: exec %s: %v\n", real, err)
		os.Exit(127)
	}
}
