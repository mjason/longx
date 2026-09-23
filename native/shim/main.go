// shim bridges an Erlang port to a child process with back-pressure, a
// separate stderr stream, graceful process-tree termination, and cleanup when
// the BEAM dies. Driven by Longx.Shim; see proto.go for the wire format.
package main

import (
	"flag"
	"fmt"
	"os"
	"time"
)

const usage = "usage: shim [flags] -- <program> [args...]"

func main() {
	// the project's file watcher and its ignore listing (watch.go, rules.go):
	// subcommands of their own, no port protocol
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "watch":
			os.Exit(watchMain())
		case "ignored":
			os.Exit(listMain("ignored", listIgnored))
		case "files":
			os.Exit(listMain("files", listFiles))
		}
	}

	dir := flag.String("cd", "", "working directory for the child")
	stderr := flag.String("stderr", "stream", "stderr handling: stream|console|disable|redirect_to_stdout")
	logTarget := flag.String("log", "", "shim diagnostics: stderr or a file path")
	grace := flag.Duration("grace", 5*time.Second, "soft-kill grace period used when the host disappears")
	oomScoreAdj := flag.Int("oom_score_adj", 0, "Linux: oom_score_adj for the shim and its child tree (-1000..1000)")
	memoryLimit := flag.Uint64("memory_limit", 0, "cap the child tree's memory in bytes (0 = none)")
	cleanEnv := flag.Bool("clean_env", false, "give the child only the environment sent by the host, nothing of the shim's own")
	pty := flag.Bool("pty", false, "run the child on a pseudo-terminal: one output stream, stdin stays open (unix only)")
	noStdin := flag.Bool("no_stdin", false, "give the child the null device as stdin instead of a pipe (not with -pty)")
	protocol := flag.String("protocol_version", "", "protocol version expected by the host")
	version := flag.Bool("v", false, "print protocol version and exit")
	flag.Parse()

	if *version {
		fmt.Printf("protocol_version: %s\n", ProtocolVersion)
		return
	}
	if err := initLogger(*logTarget); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if *protocol != ProtocolVersion {
		die(fmt.Sprintf("protocol version mismatch: host %q, shim %q", *protocol, ProtocolVersion))
	}
	if flag.NArg() < 1 {
		die(usage)
	}

	cfg := config{
		Args:        flag.Args(),
		Dir:         *dir,
		Stderr:      *stderr,
		Grace:       *grace,
		OOMScoreAdj: *oomScoreAdj,
		MemoryLimit: *memoryLimit,
		CleanEnv:    *cleanEnv,
		PTY:         *pty,
		NoStdin:     *noStdin,
	}
	os.Exit(run(os.Stdin, os.Stdout, cfg))
}

// die reports a startup problem on the protocol channel and to stderr.
func die(reason string) {
	_ = writePacket(os.Stdout, TagStartError, []byte(reason))
	fmt.Fprintln(os.Stderr, reason)
	os.Exit(2)
}
