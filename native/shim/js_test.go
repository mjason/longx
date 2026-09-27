package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"
)

// a host talking to jsLoop over pipes, the way Longx.Chrome.Runtime does
type jsHost struct {
	t     *testing.T
	in    *io.PipeWriter
	lines chan map[string]any
	done  chan int
}

func startJS(t *testing.T) *jsHost {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	h := &jsHost{t: t, in: inW, lines: make(chan map[string]any, 256), done: make(chan int, 1)}
	go func() { h.done <- jsLoop(inR, outW); outW.Close() }()
	go func() {
		sc := bufio.NewScanner(outR)
		sc.Buffer(make([]byte, 1<<20), 64<<20)
		for sc.Scan() {
			var m map[string]any
			if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
				t.Errorf("bad line from shim js: %q", sc.Text())
				continue
			}
			h.lines <- m
		}
		close(h.lines)
	}()
	t.Cleanup(func() { inW.Close() })
	return h
}

func (h *jsHost) send(v any) {
	b, _ := json.Marshal(v)
	if _, err := h.in.Write(append(b, '\n')); err != nil {
		h.t.Fatalf("write: %v", err)
	}
}

// the next line of the given type (others are collected in `skipped`)
func (h *jsHost) next(typ string, timeout time.Duration) (map[string]any, []map[string]any) {
	var skipped []map[string]any
	deadline := time.After(timeout)
	for {
		select {
		case m, ok := <-h.lines:
			if !ok {
				h.t.Fatalf("shim js closed while waiting for %q (skipped %v)", typ, skipped)
			}
			if m["type"] == typ {
				return m, skipped
			}
			skipped = append(skipped, m)
		case <-deadline:
			h.t.Fatalf("no %q line within %s (skipped %v)", typ, timeout, skipped)
		}
	}
}

func (h *jsHost) init(prelude string) {
	h.send(map[string]any{"type": "init", "prelude": prelude})
	ready, _ := h.next("ready", 5*time.Second)
	if ready["engine"] != "goja" {
		h.t.Fatalf("ready without engine: %v", ready)
	}
}

func (h *jsHost) execute(id, code string, timeoutMs int) {
	h.send(map[string]any{"type": "execute", "id": id, "code": code, "timeout_ms": timeoutMs})
}

func TestJSExecuteReturnsValueAndStreamsConsole(t *testing.T) {
	h := startJS(t)
	h.init("")
	h.execute("c1", "console.log('hello', {a: 1}); return 1 + 1", 5000)
	result, skipped := h.next("result", 5*time.Second)
	if result["id"] != "c1" || result["value"] != float64(2) || result["error"] != nil {
		t.Fatalf("result: %v", result)
	}
	var logs []string
	for _, m := range skipped {
		if m["type"] == "log" {
			logs = append(logs, m["text"].(string))
		}
	}
	if len(logs) != 1 || logs[0] != `hello {"a":1}` {
		t.Fatalf("console lines: %q", logs)
	}
}

func TestJSStatePersistsAcrossCells(t *testing.T) {
	h := startJS(t)
	h.init("")
	h.execute("c1", "x = 41; function twice(n) { return n * 2 }", 5000)
	h.next("result", 5*time.Second)
	h.execute("c2", "return twice(x) + 2", 5000)
	result, _ := h.next("result", 5*time.Second)
	if result["value"] != float64(84) {
		t.Fatalf("result: %v", result)
	}
}

func TestJSErrorsAreReported(t *testing.T) {
	h := startJS(t)
	h.init("")
	h.execute("c1", "throw new Error('boom')", 5000)
	result, _ := h.next("result", 5*time.Second)
	if err, _ := result["error"].(string); !strings.Contains(err, "boom") {
		t.Fatalf("error not reported: %v", result)
	}
	// a syntax error too, without killing the runtime
	h.execute("c2", "return (", 5000)
	result, _ = h.next("result", 5*time.Second)
	if err, _ := result["error"].(string); !strings.Contains(err, "SyntaxError") {
		t.Fatalf("syntax error not reported: %v", result)
	}
	h.execute("c3", "return 3", 5000)
	result, _ = h.next("result", 5*time.Second)
	if result["value"] != float64(3) {
		t.Fatalf("runtime unusable after errors: %v", result)
	}
}

func TestJSCDPRoundTrip(t *testing.T) {
	h := startJS(t)
	h.init("globalThis.nav = (url) => __longx_cdp('tab:12', 'Page.navigate', {url})")
	h.execute("c1", "const r = await nav('https://example.com'); return r.frameId", 5000)
	cdp, _ := h.next("cdp", 5*time.Second)
	if cdp["target"] != "tab:12" || cdp["method"] != "Page.navigate" {
		t.Fatalf("cdp request: %v", cdp)
	}
	if params, _ := cdp["params"].(map[string]any); params["url"] != "https://example.com" {
		t.Fatalf("cdp params: %v", cdp)
	}
	h.send(map[string]any{"type": "cdp_result", "id": cdp["id"], "result": map[string]any{"frameId": "F1"}})
	result, _ := h.next("result", 5*time.Second)
	if result["value"] != "F1" {
		t.Fatalf("result: %v", result)
	}
	// a CDP error is a catchable Error in the cell
	h.execute("c2", "try { await nav('x') } catch (e) { return 'caught: ' + e.message }", 5000)
	cdp, _ = h.next("cdp", 5*time.Second)
	h.send(map[string]any{"type": "cdp_result", "id": cdp["id"], "error": "Cannot navigate to invalid URL"})
	result, _ = h.next("result", 5*time.Second)
	if result["value"] != "caught: Cannot navigate to invalid URL" {
		t.Fatalf("result: %v", result)
	}
}

func TestJSInterruptStopsABusyLoopAndResetsTheRealm(t *testing.T) {
	h := startJS(t)
	h.init("globalThis.fromPrelude = 'yes'")
	h.execute("c0", "kept = 1", 5000)
	h.next("result", 5*time.Second)
	h.execute("c1", "while (true) {}", 0)
	time.Sleep(50 * time.Millisecond)
	h.send(map[string]any{"type": "interrupt", "id": "c1"})
	result, _ := h.next("result", 5*time.Second)
	if result["interrupted"] != true || result["reset"] != true {
		t.Fatalf("not interrupted with a reset: %v", result)
	}
	// a fresh realm: the prelude is back, the cells' state is gone
	h.execute("c2", "return [typeof console, fromPrelude, typeof kept]", 5000)
	result, _ = h.next("result", 5*time.Second)
	if fmt.Sprint(result["value"]) != "[object yes undefined]" {
		t.Fatalf("realm after interrupt: %v", result)
	}
}

func TestJSTopLevelDeclarationsPersist(t *testing.T) {
	h := startJS(t)
	h.init("")
	h.execute("c1", "const a = 1; let b = 2; function f() { return 3 }\nclass K {}\nvar {c, d = 5} = {c: 4}; const [e] = [6]; return a", 5000)
	result, _ := h.next("result", 5*time.Second)
	if result["value"] != float64(1) || result["error"] != nil {
		t.Fatalf("result: %v", result)
	}
	h.execute("c2", "return a + b + f() + c + d + e + typeof K", 5000)
	result, _ = h.next("result", 5*time.Second)
	if result["value"] != "21function" {
		t.Fatalf("declarations did not persist: %v", result)
	}
	// an early return keeps what was declared before it; a throw does not mask itself
	h.execute("c3", "const z = 9; if (z) return 'early'; const never = 1", 5000)
	h.next("result", 5*time.Second)
	h.execute("c4", "const w = 1; throw new Error('boom'); const q = 2", 5000)
	result, _ = h.next("result", 5*time.Second)
	if err, _ := result["error"].(string); !strings.Contains(err, "boom") {
		t.Fatalf("error masked: %v", result)
	}
	h.execute("c5", "return [z, typeof never, w, typeof q]", 5000)
	result, _ = h.next("result", 5*time.Second)
	if fmt.Sprint(result["value"]) != "[9 undefined 1 undefined]" {
		t.Fatalf("state after early return / throw: %v", result)
	}
}

func TestJSTimeoutInterruptsByItself(t *testing.T) {
	h := startJS(t)
	h.init("")
	h.execute("c1", "while (true) {}", 100)
	result, _ := h.next("result", 5*time.Second)
	if result["interrupted"] != true {
		t.Fatalf("not interrupted by the deadline: %v", result)
	}
}

func TestJSInterruptWhileAwaitingAHostCall(t *testing.T) {
	h := startJS(t)
	h.init("")
	h.execute("c1", "await __longx_cdp('tab:1', 'Page.navigate', {}); return 'late'", 0)
	h.next("cdp", 5*time.Second)
	h.send(map[string]any{"type": "interrupt", "id": "c1"})
	result, _ := h.next("result", 5*time.Second)
	if result["interrupted"] != true {
		t.Fatalf("not interrupted: %v", result)
	}
	// the next cell runs; a late answer to the dead call changes nothing
	h.send(map[string]any{"type": "cdp_result", "id": "r1", "result": map[string]any{}})
	h.execute("c2", "return 7", 5000)
	result, _ = h.next("result", 5*time.Second)
	if result["id"] != "c2" || result["value"] != float64(7) {
		t.Fatalf("result: %v", result)
	}
}

func TestJSHoldStopsTheDeadlineUntilResume(t *testing.T) {
	h := startJS(t)
	h.init("")
	h.execute("c1", "await __longx_cdp('tab:1', 'Slow', {}); return 'done'", 200)
	cdp, _ := h.next("cdp", 5*time.Second)
	h.send(map[string]any{"type": "hold", "id": "c1"})
	time.Sleep(400 * time.Millisecond) // past the deadline, held
	h.send(map[string]any{"type": "resume", "id": "c1", "timeout_ms": 5000})
	h.send(map[string]any{"type": "cdp_result", "id": cdp["id"], "result": map[string]any{}})
	result, _ := h.next("result", 5*time.Second)
	if result["value"] != "done" || result["interrupted"] == true {
		t.Fatalf("held cell did not finish: %v", result)
	}
}

func TestJSImagesAreCappedPerCell(t *testing.T) {
	h := startJS(t)
	h.init("")
	h.execute("c1", "let n = 0; for (let i = 0; i < 6; i++) if (__longx_image('image/png', 'AAAA')) n++; return n", 5000)
	result, skipped := h.next("result", 5*time.Second)
	images := 0
	for _, m := range skipped {
		if m["type"] == "image" {
			images++
			if m["mime"] != "image/png" || m["data"] != "AAAA" || m["id"] != "c1" {
				t.Fatalf("image line: %v", m)
			}
		}
	}
	if images != 4 || result["value"] != float64(4) {
		t.Fatalf("images %d, accepted %v", images, result["value"])
	}
}

func TestJSCloseEndsTheLoop(t *testing.T) {
	h := startJS(t)
	h.init("")
	h.send(map[string]any{"type": "close"})
	select {
	case code := <-h.done:
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("did not exit on close")
	}
}
