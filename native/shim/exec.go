package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"time"
)

// config describes one child process run.
type config struct {
	Args   []string
	Dir    string
	Stderr string        // "stream" | "console" | "disable" | "redirect_to_stdout"
	Grace  time.Duration // SIGTERM → SIGKILL grace used when the host disappears
	// OOMScoreAdj (Linux) is applied to the shim before the child is spawned, so
	// the whole tree inherits it: with a positive value the kernel's OOM killer
	// prefers this tree (fattest process first) over the BEAM.
	OOMScoreAdj int
	// MemoryLimit in bytes caps the child tree (Linux: RLIMIT_AS on the child,
	// Windows: the Job's memory limit); 0 = none.
	MemoryLimit uint64
}

// frameWriter serialises packets to the host. Any write error means the host
// is gone (broken pipe), which is reported through `gone`.
type frameWriter struct {
	mu   sync.Mutex
	w    io.Writer
	gone chan struct{}
	once sync.Once
}

func newFrameWriter(w io.Writer) *frameWriter {
	return &frameWriter{w: w, gone: make(chan struct{})}
}

func (f *frameWriter) write(tag uint8, data []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := writePacket(f.w, tag, data); err != nil {
		logf("host write failed (%v); treating host as gone", err)
		f.once.Do(func() { close(f.gone) })
	}
}

// stream is one demand-driven output pipe (stdout or stderr).
type stream struct {
	name   string
	dataTg uint8
	eofTag uint8
	r      *os.File
	demand chan int // >0: read up to n bytes; 0: close
}

func newStream(name string, dataTag, eofTag uint8, r *os.File) *stream {
	return &stream{name: name, dataTg: dataTag, eofTag: eofTag, r: r, demand: make(chan int, 1)}
}

// ask hands a demand to the reader goroutine. The host is credit based (one
// outstanding read per stream), so a full buffer is a protocol violation.
func (s *stream) ask(n int) {
	select {
	case s.demand <- n:
	default:
		logf("%s: demand while a read is pending — dropped", s.name)
	}
}

// serve answers demands until EOF, close, or a read error.
func (s *stream) serve(out *frameWriter) {
	defer s.r.Close()
	buf := make([]byte, MaxPayload)

	for n := range s.demand {
		if n <= 0 {
			out.write(s.eofTag, nil)
			return
		}
		if n > MaxPayload {
			n = MaxPayload
		}
		read, err := s.r.Read(buf[:n])
		if read > 0 {
			out.write(s.dataTg, buf[:read])
			continue
		}
		if err != nil && err != io.EOF {
			logf("%s: read error: %v", s.name, err)
		}
		out.write(s.eofTag, nil)
		return
	}
}

// run executes cfg.Args, bridging it to the host over hostIn/hostOut until the
// child has exited and every output stream is finished, or the host is gone.
// It returns the shim's own exit code.
func run(hostIn io.Reader, hostOut io.Writer, cfg config) int {
	out := newFrameWriter(hostOut)

	first, err := readPacket(hostIn)
	if err != nil || first.Tag != TagCommandEnv {
		out.write(TagStartError, []byte("first packet must be CommandEnv"))
		return 3
	}
	env, err := decodeEnv(first.Data)
	if err != nil {
		out.write(TagStartError, []byte(err.Error()))
		return 3
	}

	child, err := startChild(cfg, env)
	if err != nil {
		out.write(TagStartError, []byte(err.Error()))
		return 3
	}
	out.write(TagPid, encodeUint32(uint32(child.proc.Process.Pid)))

	osSigs := make(chan os.Signal, 1)
	// SIGPIPE must be caught: otherwise the Go runtime exits the shim on the
	// first failed write to a dead host before we can clean up the child.
	signal.Notify(osSigs, shutdownSignals()...)
	defer signal.Stop(osSigs)

	inputCh := make(chan []byte, 1)
	termCh := make(chan time.Duration, 1)
	sigCh := make(chan int, 4)
	hostGone := make(chan struct{})
	waitDone := make(chan struct{})

	go child.feedStdin(inputCh, out)

	var streams sync.WaitGroup
	streamsDone := make(chan struct{})
	for _, s := range child.streams {
		streams.Add(1)
		go func(s *stream) { defer streams.Done(); s.serve(out) }(s)
	}
	go func() { streams.Wait(); close(streamsDone) }()

	go func() {
		child.waitErr = child.proc.Wait()
		close(waitDone)
	}()

	go readHost(hostIn, child, inputCh, termCh, sigCh, out, hostGone)

	exited := false
	finished := false
	terminating := false
	terminate := func(grace time.Duration) {
		if terminating {
			return
		}
		terminating = true
		go child.terminate(grace, waitDone)
	}
	// Once the child is gone the host has lost interest; stop the child tree
	// (a no-op if it already exited) and leave.
	shutdown := func(why string) int {
		logf("%s; terminating child", why)
		terminate(cfg.Grace)
		<-waitDone
		return 0
	}

	// waitCase is nil'd after firing so the select stops spinning on it;
	// waitDone itself stays valid for terminate/shutdown.
	waitCase := waitDone
	streamsCase := streamsDone

	for {
		select {
		case grace := <-termCh:
			terminate(grace)

		case sig := <-sigCh:
			child.signal(sig)

		case s := <-osSigs:
			return shutdown(fmt.Sprintf("received %v", s))

		case <-hostGone:
			return shutdown("host closed its side")

		case <-out.gone:
			return shutdown("host unwritable")

		case <-waitCase:
			waitCase = nil
			exited = true
			out.write(TagExitStatus, encodeUint32(uint32(exitStatus(child.waitErr))))
			if finished {
				return 0
			}

		case <-streamsCase:
			streamsCase = nil
			finished = true
			if exited {
				return 0
			}
		}
	}
}

// readHost dispatches packets from the host. It never blocks on the child so a
// Kill can always get through; the host's credit model guarantees the buffered
// channels have room when the protocol is followed.
func readHost(hostIn io.Reader, child *child, inputCh chan<- []byte, termCh chan<- time.Duration, sigCh chan<- int, out *frameWriter, hostGone chan<- struct{}) {
	defer close(hostGone)
	inputClosed := false

	for {
		pkt, err := readPacket(hostIn)
		if err != nil {
			if err != io.EOF {
				logf("host read error: %v", err)
			}
			return
		}

		switch pkt.Tag {
		case TagInput:
			if inputClosed {
				logf("Input after CloseInput — dropped")
				continue
			}
			select {
			case inputCh <- pkt.Data:
			default:
				logf("Input without credit — dropped %d bytes", len(pkt.Data))
			}

		case TagCloseInput:
			if !inputClosed {
				inputClosed = true
				close(inputCh)
			}

		case TagSendStats:
			out.write(TagStats, encodeStats(child.stats()))

		case TagSendOutput:
			n, err := decodeUint32(pkt.Data)
			if err != nil {
				logf("SendOutput: %v", err)
				continue
			}
			child.stdout.ask(int(n))

		case TagCloseOutput:
			child.stdout.ask(0)

		case TagSendStderr:
			n, err := decodeUint32(pkt.Data)
			if err != nil {
				logf("SendStderr: %v", err)
				continue
			}
			if child.stderr == nil {
				out.write(TagStderrEOF, nil)
				continue
			}
			child.stderr.ask(int(n))

		case TagCloseStderr:
			if child.stderr != nil {
				child.stderr.ask(0)
			}

		case TagKill:
			ms, err := decodeUint32(pkt.Data)
			if err != nil {
				logf("Kill: %v", err)
				continue
			}
			select {
			case termCh <- time.Duration(ms) * time.Millisecond:
			default:
			}

		case TagSignal:
			sig, err := decodeUint32(pkt.Data)
			if err != nil {
				logf("Signal: %v", err)
				continue
			}
			select {
			case sigCh <- int(sig):
			default:
				logf("Signal queue full — dropped %d", sig)
			}

		default:
			logf("unknown tag %d — ignored", pkt.Tag)
		}
	}
}

// child is a started process plus the pipes we own.
type child struct {
	proc    *exec.Cmd
	stdin   *os.File
	stdout  *stream
	stderr  *stream // nil unless Stderr == "stream"
	streams []*stream
	waitErr error
	guard   guard // platform resource guard (Job object on Windows)
}

// startChild launches cfg.Args with our own os.Pipe()s rather than
// exec.Cmd's StdoutPipe: Wait() must not close a read end that a reader
// goroutine is still draining, and EOF should arrive only once every
// process in the group holding the write end has gone.
func startChild(cfg config, env []string) (*child, error) {
	if len(cfg.Args) == 0 {
		return nil, errors.New("no command given")
	}
	path, err := exec.LookPath(cfg.Args[0])
	if err != nil {
		return nil, err
	}

	proc := exec.Command(path, cfg.Args[1:]...)
	proc.Dir = cfg.Dir
	proc.Env = append(os.Environ(), env...)
	setProcessGroup(proc)

	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	proc.Stdin = stdinR
	proc.Stdout = stdoutW

	c := &child{proc: proc, stdin: stdinW}
	c.stdout = newStream("stdout", TagOutput, TagOutputEOF, stdoutR)
	c.streams = []*stream{c.stdout}

	var stderrW *os.File
	switch cfg.Stderr {
	case "stream", "":
		stderrR, w, err := os.Pipe()
		if err != nil {
			return nil, err
		}
		stderrW = w
		proc.Stderr = w
		c.stderr = newStream("stderr", TagStderr, TagStderrEOF, stderrR)
		c.streams = append(c.streams, c.stderr)
	case "console":
		proc.Stderr = os.Stderr
	case "disable":
		proc.Stderr = nil
	case "redirect_to_stdout":
		proc.Stderr = stdoutW
	default:
		return nil, fmt.Errorf("invalid stderr mode %q", cfg.Stderr)
	}

	if err := beforeStart(cfg); err != nil {
		logf("resource guard: %v", err)
	}
	err = proc.Start()
	// The child holds its own copies now; ours must go so EOF can propagate.
	stdinR.Close()
	stdoutW.Close()
	if stderrW != nil {
		stderrW.Close()
	}
	if err != nil {
		stdinW.Close()
		for _, s := range c.streams {
			s.r.Close()
		}
		return nil, err
	}
	if err := afterStart(c, cfg); err != nil {
		logf("resource guard: %v", err)
	}
	return c, nil
}

// feedStdin writes host Input to the child, granting one credit at a time.
func (c *child) feedStdin(inputCh <-chan []byte, out *frameWriter) {
	defer c.stdin.Close()
	for {
		out.write(TagSendInput, nil)
		data, ok := <-inputCh
		if !ok {
			return
		}
		if _, err := c.stdin.Write(data); err != nil {
			logf("child stdin write failed: %v", err)
			return
		}
	}
}

// terminate asks the whole process group to stop, escalating to a hard kill
// once grace has passed without the child exiting.
func (c *child) terminate(grace time.Duration, waitDone <-chan struct{}) {
	logf("terminating child (grace %v)", grace)
	softKillTree(c.proc.Process)
	select {
	case <-waitDone:
		return
	case <-time.After(grace):
		logf("grace expired; hard-killing child tree")
		hardKillTree(c.proc.Process)
		c.guard.kill()
	}
}
