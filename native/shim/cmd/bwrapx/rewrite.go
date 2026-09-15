// bwrapx is the bubblewrap wrapper Longx puts in front of codex when a
// project lets host paths into its sandbox (GPU nodes, USB, a socket).
//
// codex builds a bubblewrap command line with `--dev /dev` — a minimal
// device tree that hides every host device — and has no option to bind a
// device in (its writable roots are `--bind`s without device access, seeded
// with protected metadata, so a device node there breaks the launch). The
// wrapper is found as `bwrap` on codex's PATH, forwards `--help`/`--version`
// (codex probes capabilities that way) and otherwise inserts one bind per
// configured path right after the `--dev /dev` pair — `--dev-bind` for
// anything under /dev, `--bind` for the rest — then execs the real bwrap.
// Nothing else in the command line is touched: the filesystem and network
// policy stay exactly what codex decided.
package main

import "strings"

// Bind is one host path to expose inside the sandbox.
type Bind struct {
	Path string
	Dev  bool // device access needed: anything under /dev
}

// Classify turns configured paths into binds: paths under /dev get
// `--dev-bind` (a plain bind mounts nodev), everything else `--bind`.
func Classify(paths []string) []Bind {
	binds := make([]Bind, 0, len(paths))
	for _, p := range paths {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		binds = append(binds, Bind{Path: p, Dev: p == "/dev" || strings.HasPrefix(p, "/dev/")})
	}
	return binds
}

// Passthrough returns true for the argument lists that must reach bwrap
// untouched: capability probes and anything without a `--dev` mount to
// hang the binds on (bubblewrap applies mounts in order, so a bind under
// /dev only sticks after `--dev /dev`).
func Passthrough(args []string) bool {
	if len(args) == 0 || args[0] == "--help" || args[0] == "--version" {
		return true
	}
	return devIndex(args) < 0
}

// Rewrite inserts the binds after the `--dev <path>` pair. Arguments after
// the `--` separator are the sandboxed command and are never inspected.
func Rewrite(args []string, binds []Bind) []string {
	i := devIndex(args)
	if i < 0 || len(binds) == 0 {
		return args
	}
	out := make([]string, 0, len(args)+3*len(binds))
	out = append(out, args[:i+2]...)
	for _, b := range binds {
		flag := "--bind"
		if b.Dev {
			flag = "--dev-bind"
		}
		out = append(out, flag, b.Path, b.Path)
	}
	out = append(out, args[i+2:]...)
	return out
}

// devIndex is the position of the first `--dev` option before `--`, or -1.
func devIndex(args []string) int {
	for i, a := range args {
		if a == "--" {
			return -1
		}
		if a == "--dev" && i+1 < len(args) {
			return i
		}
	}
	return -1
}
