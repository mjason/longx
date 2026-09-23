//go:build !windows

package main

import (
	"io"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// harness drives run() the way the BEAM does: packets in via hostIn,
// packets out via hostOut.
type harness struct {
	t      *testing.T
	in     *io.PipeWriter
	out    *io.PipeReader
	done   chan int
	pkts   chan Packet
	pid    int
	closed bool
	credit int     // SendInput packets skipped by next()
	exit   *Packet // ExitStatus stashed by next(); it may precede stream data
}

func newHarness(t *testing.T, cfg config, env []byte) *harness {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()

	h := &harness{t: t, in: inW, out: outR, done: make(chan int, 1), pkts: make(chan Packet, 64)}

	go func() { h.done <- run(inR, outW, cfg); outW.Close() }()
	go func() {
		for {
			p, err := readPacket(outR)
			if err != nil {
				close(h.pkts)
				return
			}
			h.pkts <- p
		}
	}()

	h.send(TagCommandEnv, env)
	return h
}

func start(t *testing.T, args ...string) *harness {
	t.Helper()
	h := newHarness(t, config{Args: args, Stderr: "stream", Grace: time.Second}, nil)
	p := h.expect(TagPid)
	pid, err := decodeUint32(p.Data)
	if err != nil {
		t.Fatal(err)
	}
	h.pid = int(pid)
	return h
}

func (h *harness) send(tag uint8, data []byte) {
	h.t.Helper()
	if err := writePacket(h.in, tag, data); err != nil {
		h.t.Fatalf("send %d: %v", tag, err)
	}
}

func (h *harness) closeHost() {
	if !h.closed {
		h.closed = true
		h.in.Close()
	}
}

// next returns the next packet, skipping SendInput credits (they arrive at
// unpredictable points and tests assert on them explicitly when relevant).
func (h *harness) next() Packet {
	h.t.Helper()
	for {
		select {
		case p, ok := <-h.pkts:
			if !ok {
				h.t.Fatal("host output closed unexpectedly")
			}
			if p.Tag == TagSendInput {
				h.credit++
				continue
			}
			if p.Tag == TagExitStatus {
				h.exit = &p
				continue
			}
			return p
		case <-time.After(5 * time.Second):
			h.t.Fatal("timed out waiting for packet")
		}
	}
}

func (h *harness) expect(tag uint8) Packet {
	h.t.Helper()
	p := h.next()
	if p.Tag != tag {
		h.t.Fatalf("expected tag %d, got %d (%q)", tag, p.Tag, p.Data)
	}
	return p
}

func (h *harness) expectCredit() {
	h.t.Helper()
	if h.credit > 0 {
		h.credit--
		return
	}
	select {
	case p := <-h.pkts:
		if p.Tag != TagSendInput {
			h.t.Fatalf("expected SendInput credit, got %d", p.Tag)
		}
	case <-time.After(5 * time.Second):
		h.t.Fatal("timed out waiting for SendInput credit")
	}
}

func (h *harness) expectNothing(d time.Duration) {
	h.t.Helper()
	select {
	case p := <-h.pkts:
		if p.Tag != TagSendInput {
			h.t.Fatalf("expected silence, got tag %d (%q)", p.Tag, p.Data)
		}
	case <-time.After(d):
	}
}

func (h *harness) readOut(max uint32) Packet {
	h.t.Helper()
	h.send(TagSendOutput, encodeUint32(max))
	return h.next()
}

func (h *harness) expectExit(code int32) {
	h.t.Helper()
	p := h.exitPacket()
	got, _ := decodeUint32(p.Data)
	if int32(got) != code {
		h.t.Fatalf("exit status: want %d got %d", code, int32(got))
	}
}

// exitPacket returns the ExitStatus packet, whether already stashed or next
// on the wire.
func (h *harness) exitPacket() Packet {
	h.t.Helper()
	if h.exit != nil {
		p := *h.exit
		h.exit = nil
		return p
	}
	for {
		select {
		case p, ok := <-h.pkts:
			if !ok {
				h.t.Fatal("host output closed before ExitStatus")
			}
			switch p.Tag {
			case TagSendInput:
				h.credit++
			case TagExitStatus:
				return p
			default:
				h.t.Fatalf("expected ExitStatus, got tag %d (%q)", p.Tag, p.Data)
			}
		case <-time.After(5 * time.Second):
			h.t.Fatal("timed out waiting for ExitStatus")
		}
	}
}

func (h *harness) waitRun() {
	h.t.Helper()
	h.closeHost()
	select {
	case <-h.done:
	case <-time.After(5 * time.Second):
		h.t.Fatal("run() did not return")
	}
}

func processAlive(pid int) bool {
	return syscall.Kill(pid, 0) == nil
}

func groupAlive(pgid int) bool {
	return syscall.Kill(-pgid, 0) == nil
}

func TestEchoOutputThenEOFAndExit(t *testing.T) {
	h := start(t, "echo", "hello")
	p := h.readOut(1024)
	if p.Tag != TagOutput || string(p.Data) != "hello\n" {
		t.Fatalf("got %d %q", p.Tag, p.Data)
	}
	h.send(TagSendOutput, encodeUint32(1024))
	h.expect(TagOutputEOF)
	h.expectExit(0)
	h.waitRun()
}

func TestCatRoundTripAndCloseInput(t *testing.T) {
	h := start(t, "cat")
	h.expectCredit()
	h.send(TagInput, []byte("abc"))
	p := h.readOut(1024)
	if p.Tag != TagOutput || string(p.Data) != "abc" {
		t.Fatalf("got %d %q", p.Tag, p.Data)
	}
	h.expectCredit()
	h.send(TagCloseInput, nil)
	h.send(TagSendOutput, encodeUint32(1024))
	h.expect(TagOutputEOF)
	h.expectExit(0)
	h.waitRun()
}

// NoStdin: the child reads /dev/null, as a command from a script with nothing to
// read — no pipe (ripgrep with no path searches a piped stdin instead of the
// directory, and found nothing in an empty one), EOF at once, no input credit
func TestNoStdinGivesTheChildDevNull(t *testing.T) {
	h := newHarness(t, config{
		Args:    []string{"sh", "-c", "[ -p /dev/stdin ] && echo pipe || echo none; cat; echo done"},
		Stderr:  "stream",
		Grace:   time.Second,
		NoStdin: true,
	}, nil)
	h.expect(TagPid)
	var out []byte
	for {
		p := h.readOut(1024)
		if p.Tag == TagOutputEOF {
			break
		}
		if p.Tag != TagOutput {
			t.Fatalf("got tag %d (%q)", p.Tag, p.Data)
		}
		out = append(out, p.Data...)
	}
	if string(out) != "none\ndone\n" {
		t.Fatalf("output %q", out)
	}
	h.expectExit(0)
	if h.credit != 0 {
		t.Fatalf("input credit offered with no stdin: %d", h.credit)
	}
	h.waitRun()
}

func TestOutputRespectsMaxSize(t *testing.T) {
	h := start(t, "echo", "0123456789")
	p := h.readOut(4)
	if p.Tag != TagOutput || string(p.Data) != "0123" {
		t.Fatalf("got %d %q", p.Tag, p.Data)
	}
	h.send(TagCloseOutput, nil)
	h.expect(TagOutputEOF)
	h.expectExit(0)
	h.waitRun()
}

func TestNoOutputWithoutDemand(t *testing.T) {
	h := start(t, "sh", "-c", "yes | head -c 1000000")
	h.expectNothing(300 * time.Millisecond)
	p := h.readOut(10)
	if p.Tag != TagOutput || len(p.Data) == 0 || len(p.Data) > 10 {
		t.Fatalf("got %d len=%d", p.Tag, len(p.Data))
	}
	h.send(TagKill, encodeUint32(100))
	h.exitPacket()
	h.waitRun()
}

func TestExitStatusNonZero(t *testing.T) {
	h := start(t, "sh", "-c", "exit 7")
	h.expectExit(7)
	h.waitRun()
}

func TestStderrStream(t *testing.T) {
	h := start(t, "sh", "-c", "echo err 1>&2")
	h.send(TagSendStderr, encodeUint32(1024))
	p := h.expect(TagStderr)
	if string(p.Data) != "err\n" {
		t.Fatalf("got %q", p.Data)
	}
	h.send(TagSendStderr, encodeUint32(1024))
	h.expect(TagStderrEOF)
	h.expectExit(0)
	h.waitRun()
}

func TestStderrDisabledAnswersEOF(t *testing.T) {
	h := newHarness(t, config{Args: []string{"sh", "-c", "echo err 1>&2"}, Stderr: "disable", Grace: time.Second}, nil)
	h.expect(TagPid)
	h.send(TagSendStderr, encodeUint32(1024))
	h.expect(TagStderrEOF)
	h.expectExit(0)
	h.waitRun()
}

func TestStderrRedirectToStdout(t *testing.T) {
	h := newHarness(t, config{Args: []string{"sh", "-c", "echo err 1>&2"}, Stderr: "redirect_to_stdout", Grace: time.Second}, nil)
	h.expect(TagPid)
	p := h.readOut(1024)
	if p.Tag != TagOutput || string(p.Data) != "err\n" {
		t.Fatalf("got %d %q", p.Tag, p.Data)
	}
	h.expectExit(0)
	h.waitRun()
}

func TestEnvIsPassed(t *testing.T) {
	env := append([]byte{0, 7}, []byte("FOO=bar")...)
	h := newHarness(t, config{Args: []string{"sh", "-c", "echo $FOO"}, Stderr: "stream", Grace: time.Second}, env)
	h.expect(TagPid)
	p := h.readOut(1024)
	if string(p.Data) != "bar\n" {
		t.Fatalf("got %q", p.Data)
	}
	h.expectExit(0)
	h.waitRun()
}

func TestWorkingDirectory(t *testing.T) {
	dir := t.TempDir()
	h := newHarness(t, config{Args: []string{"pwd"}, Dir: dir, Stderr: "stream", Grace: time.Second}, nil)
	h.expect(TagPid)
	p := h.readOut(1024)
	want, _ := filepath.EvalSymlinks(dir)
	got, _ := filepath.EvalSymlinks(string(p.Data[:len(p.Data)-1]))
	if got != want {
		t.Fatalf("pwd: want %q got %q", want, got)
	}
	h.expectExit(0)
	h.waitRun()
}

func TestStartErrorForMissingCommand(t *testing.T) {
	h := newHarness(t, config{Args: []string{"/definitely/not/here"}, Stderr: "stream", Grace: time.Second}, nil)
	p := h.expect(TagStartError)
	if len(p.Data) == 0 {
		t.Fatal("want a reason")
	}
	h.waitRun()
}

func TestKillGracefulTermHonoured(t *testing.T) {
	h := start(t, "sleep", "30")
	started := time.Now()
	h.send(TagKill, encodeUint32(5000))
	h.expectExit(128 + int32(syscall.SIGTERM))
	if time.Since(started) > 2*time.Second {
		t.Fatal("graceful kill took too long — SIGTERM was not delivered promptly")
	}
	h.waitRun()
}

func TestKillEscalatesToSIGKILLAfterGrace(t *testing.T) {
	h := start(t, "sh", "-c", `trap "" TERM; sleep 30`)
	time.Sleep(100 * time.Millisecond) // let the trap install
	started := time.Now()
	h.send(TagKill, encodeUint32(300))
	h.expectExit(128 + int32(syscall.SIGKILL))
	if d := time.Since(started); d < 250*time.Millisecond || d > 3*time.Second {
		t.Fatalf("escalation timing off: %v", d)
	}
	h.waitRun()
}

func TestKillTakesWholeProcessGroup(t *testing.T) {
	// the subshell keeps a `sleep` child; both must die
	h := start(t, "sh", "-c", "sleep 30; echo never")
	time.Sleep(100 * time.Millisecond)
	h.send(TagKill, encodeUint32(200))
	h.exitPacket()
	h.waitRun()
	deadline := time.Now().Add(2 * time.Second)
	for groupAlive(h.pid) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if groupAlive(h.pid) {
		t.Fatal("process group still alive after kill")
	}
}

func TestHostDisappearingKillsChildTree(t *testing.T) {
	h := start(t, "sh", "-c", "sleep 30; echo never")
	time.Sleep(100 * time.Millisecond)
	if !processAlive(h.pid) {
		t.Fatal("precondition: child should be running")
	}
	h.waitRun() // closes host stdin == BEAM died
	deadline := time.Now().Add(3 * time.Second)
	for groupAlive(h.pid) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if groupAlive(h.pid) {
		t.Fatal("child tree survived the host going away")
	}
}

func TestSignalIsForwarded(t *testing.T) {
	h := start(t, "sh", "-c", `trap "echo got; exit 0" USR1; while :; do sleep 0.05; done`)
	time.Sleep(150 * time.Millisecond)
	h.send(TagSignal, encodeUint32(uint32(syscall.SIGUSR1)))
	p := h.readOut(1024)
	if p.Tag != TagOutput || string(p.Data) != "got\n" {
		t.Fatalf("got %d %q", p.Tag, p.Data)
	}
	h.expectExit(0)
	h.waitRun()
}

func TestExitStatusArrivesEvenIfHostNeverReadsOutput(t *testing.T) {
	h := start(t, "echo", "unread")
	h.expectExit(0)
	// shim must stay alive until the host drains or closes the stream
	select {
	case <-h.done:
		t.Fatal("run() returned before host closed output stream")
	case <-time.After(200 * time.Millisecond):
	}
	h.send(TagCloseOutput, nil)
	h.expect(TagOutputEOF)
	h.send(TagCloseStderr, nil)
	h.expect(TagStderrEOF)
	select {
	case <-h.done:
	case <-time.After(2 * time.Second):
		t.Fatal("run() did not return after streams closed")
	}
}
