package main

// `shim js`: the JavaScript runtime of a browser session (Longx.Chrome.Runtime)
// — goja (pure Go) with goja_nodejs' event loop, one persistent realm, JSON
// lines over stdio. The host sends `init` (the prelude), then `execute` cells;
// a cell's code is the body of an async function, its console output streams
// back as `log` lines, screenshots as `image` lines, and its settlement is one
// `result` line. The realm's only way out is `__longx_cdp(target, method,
// params)`, a promise the host answers with `cdp_result`.
//
// A cell's top-level `const` / `let` / `var` / `function` / `class`
// declarations survive into the next cell (rewritten in place to land on the
// global object — `wrapCell`), so the model works as in a REPL.
//
// `interrupt` stops a cell wherever it is — a busy loop too, goja's Interrupt
// — and **rebuilds the realm**: goja cannot run promise jobs again after an
// interrupt inside an `await` continuation (probed 2026-09-27), so the state
// is lost and the result says `reset: true`, the same contract as
// browser-use-pi's cell timeout. The deadline the host gave does the same.

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
	"github.com/dop251/goja/ast"
	"github.com/dop251/goja/file"
	"github.com/dop251/goja/parser"
	"github.com/dop251/goja_nodejs/eventloop"
)

//go:embed js_bootstrap.js
var jsBootstrap string

const jsMaxImagesPerCell = 4

type jsRequest struct {
	Type      string          `json:"type"`
	ID        string          `json:"id"`
	Code      string          `json:"code"`
	Prelude   string          `json:"prelude"`
	TimeoutMs int             `json:"timeout_ms"`
	Result    json.RawMessage `json:"result"`
	Error     string          `json:"error"`
}

type jsPending struct {
	resolve func(interface{}) error
	reject  func(interface{}) error
}

type jsRuntime struct {
	out   *json.Encoder
	outMu sync.Mutex

	mu       sync.Mutex
	loop     *eventloop.EventLoop
	vm       *goja.Runtime // Interrupt is goroutine-safe; everything else runs on the loop
	prelude  string
	cell     string // the running cell's id, "" between cells
	images   int
	finished bool
	timer    *time.Timer
	nextCDP  int
	pending  map[string]jsPending
}

func jsMain() int { return jsLoop(os.Stdin, os.Stdout) }

func jsLoop(in io.Reader, out io.Writer) int {
	rt := &jsRuntime{out: json.NewEncoder(out), pending: map[string]jsPending{}}
	if err := rt.build(); err != nil {
		rt.write(map[string]any{"type": "error", "error": err.Error()})
		return 2
	}
	defer rt.loop.Terminate()

	dec := json.NewDecoder(in)
	for {
		var req jsRequest
		if err := dec.Decode(&req); err != nil {
			if errors.Is(err, io.EOF) {
				return 0
			}
			rt.write(map[string]any{"type": "error", "error": "bad request: " + err.Error()})
			return 2
		}
		switch req.Type {
		case "init":
			rt.mu.Lock()
			rt.prelude = req.Prelude
			rt.mu.Unlock()
			if err := rt.runPrelude(); err != nil {
				rt.write(map[string]any{"type": "error", "error": err.Error()})
			} else {
				rt.write(map[string]any{"type": "ready", "engine": "goja"})
			}
		case "execute":
			rt.execute(req)
		case "interrupt":
			rt.interrupt(req.ID)
		case "hold":
			// the cell waits on the person (an origin the session asks about):
			// its deadline stops until `resume`
			rt.hold(req.ID)
		case "resume":
			rt.resume(req.ID, req.TimeoutMs)
		case "cdp_result":
			rt.cdpResult(req)
		case "close":
			return 0
		default:
			rt.write(map[string]any{"type": "error", "error": "unknown request type " + req.Type})
		}
	}
}

func (rt *jsRuntime) write(v any) {
	rt.outMu.Lock()
	defer rt.outMu.Unlock()
	_ = rt.out.Encode(v)
}

// a fresh loop and realm with the host functions and the bootstrap in it
func (rt *jsRuntime) build() error {
	loop := eventloop.NewEventLoop(eventloop.EnableConsole(false))
	loop.Start()
	done := make(chan error, 1)
	loop.RunOnLoop(func(vm *goja.Runtime) {
		rt.mu.Lock()
		rt.vm = vm
		rt.mu.Unlock()
		rt.installHost(vm)
		_, err := vm.RunString(jsBootstrap)
		if err != nil {
			err = fmt.Errorf("bootstrap: %w", err)
		}
		done <- err
	})
	err := <-done
	rt.mu.Lock()
	rt.loop = loop
	rt.mu.Unlock()
	return err
}

func (rt *jsRuntime) runPrelude() error {
	rt.mu.Lock()
	prelude, loop := rt.prelude, rt.loop
	rt.mu.Unlock()
	if prelude == "" {
		return nil
	}
	done := make(chan error, 1)
	loop.RunOnLoop(func(vm *goja.Runtime) {
		_, err := vm.RunString(prelude)
		if err != nil {
			err = errors.New("prelude: " + describeJSError(err))
		}
		done <- err
	})
	return <-done
}

// the host functions the bootstrap and the prelude build on
func (rt *jsRuntime) installHost(vm *goja.Runtime) {
	_ = vm.Set("__longx_log", func(call goja.FunctionCall) goja.Value {
		rt.mu.Lock()
		cell := rt.cell
		rt.mu.Unlock()
		rt.write(map[string]any{"type": "log", "id": cell, "text": call.Argument(0).String()})
		return goja.Undefined()
	})
	_ = vm.Set("__longx_image", func(call goja.FunctionCall) goja.Value {
		rt.mu.Lock()
		if rt.cell == "" || rt.finished || rt.images >= jsMaxImagesPerCell {
			rt.mu.Unlock()
			return vm.ToValue(false)
		}
		rt.images++
		cell := rt.cell
		rt.mu.Unlock()
		rt.write(map[string]any{
			"type": "image", "id": cell,
			"mime": call.Argument(0).String(), "data": call.Argument(1).String(),
		})
		return vm.ToValue(true)
	})
	_ = vm.Set("__longx_done", func(call goja.FunctionCall) goja.Value {
		var value json.RawMessage
		if v := call.Argument(0); !goja.IsNull(v) && !goja.IsUndefined(v) {
			value = json.RawMessage(v.String())
		}
		errText := ""
		if e := call.Argument(1); !goja.IsNull(e) && !goja.IsUndefined(e) {
			errText = e.String()
		}
		rt.finish(value, errText)
		return goja.Undefined()
	})
	_ = vm.Set("__longx_cdp", func(call goja.FunctionCall) goja.Value {
		promise, resolve, reject := vm.NewPromise()
		rt.mu.Lock()
		if rt.cell == "" || rt.finished {
			rt.mu.Unlock()
			_ = reject(vm.ToValue("no cell is running"))
			return vm.ToValue(promise)
		}
		rt.nextCDP++
		id := fmt.Sprintf("r%d", rt.nextCDP)
		rt.pending[id] = jsPending{resolve: resolve, reject: reject}
		rt.mu.Unlock()
		params := call.Argument(2).Export()
		if params == nil {
			params = map[string]any{}
		}
		rt.write(map[string]any{
			"type": "cdp", "id": id,
			"target": call.Argument(0).String(), "method": call.Argument(1).String(),
			"params": params,
		})
		return vm.ToValue(promise)
	})
}

func (rt *jsRuntime) execute(req jsRequest) {
	rt.mu.Lock()
	if rt.cell != "" && !rt.finished {
		rt.mu.Unlock()
		rt.write(map[string]any{"type": "result", "id": req.ID, "value": nil,
			"error": "a cell is already running", "interrupted": false})
		return
	}
	rt.cell = req.ID
	rt.finished = false
	rt.images = 0
	if req.TimeoutMs > 0 {
		id := req.ID
		rt.timer = time.AfterFunc(time.Duration(req.TimeoutMs)*time.Millisecond, func() { rt.interrupt(id) })
	}
	loop := rt.loop
	rt.mu.Unlock()

	source := wrapCell(req.Code)
	loop.RunOnLoop(func(vm *goja.Runtime) {
		_, err := vm.RunString(source)
		if err != nil {
			var interrupted *goja.InterruptedError
			if errors.As(err, &interrupted) {
				return // interrupt() owns the result and rebuilds the realm
			}
			rt.finish(nil, describeJSError(err))
		}
	})
}

// the cell's one result line; later calls for the same cell are ignored
func (rt *jsRuntime) finish(value json.RawMessage, errText string) {
	rt.mu.Lock()
	if rt.cell == "" || rt.finished {
		rt.mu.Unlock()
		return
	}
	id := rt.settle()
	rt.mu.Unlock()
	rt.writeResult(id, value, errText, false, false)
}

// marks the running cell finished (under rt.mu): no more images, logs go on
// without a cell, answers to its host calls are dropped
func (rt *jsRuntime) settle() string {
	rt.finished = true
	if rt.timer != nil {
		rt.timer.Stop()
		rt.timer = nil
	}
	rt.pending = map[string]jsPending{}
	return rt.cell
}

func (rt *jsRuntime) writeResult(id string, value json.RawMessage, errText string, interrupted, reset bool) {
	line := map[string]any{"type": "result", "id": id, "value": nil, "error": nil,
		"interrupted": interrupted, "reset": reset}
	if errText != "" {
		line["error"] = errText
	}
	if value != nil {
		line["value"] = value
	}
	rt.write(line)
}

func (rt *jsRuntime) hold(id string) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if rt.cell == id && !rt.finished && rt.timer != nil {
		rt.timer.Stop()
		rt.timer = nil
	}
}

func (rt *jsRuntime) resume(id string, timeoutMs int) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if rt.cell == id && !rt.finished && rt.timer == nil && timeoutMs > 0 {
		rt.timer = time.AfterFunc(time.Duration(timeoutMs)*time.Millisecond, func() { rt.interrupt(id) })
	}
}

// stops the running cell and rebuilds the realm (see the module doc)
func (rt *jsRuntime) interrupt(id string) {
	rt.mu.Lock()
	if rt.cell != id || rt.finished {
		rt.mu.Unlock()
		return
	}
	rt.settle()
	vm, loop := rt.vm, rt.loop
	rt.mu.Unlock()

	vm.Interrupt("interrupted")
	// waits for the running job to come back (the interrupt lands as soon as
	// the JavaScript reaches its next instruction; a native call it cannot stop
	// keeps us here, and the host kills the process)
	loop.Terminate()
	errText := ""
	if err := rt.build(); err != nil {
		errText = err.Error()
	} else if err := rt.runPrelude(); err != nil {
		errText = err.Error()
	}
	rt.writeResult(id, nil, errText, true, true)
}

func (rt *jsRuntime) cdpResult(req jsRequest) {
	rt.mu.Lock()
	p, ok := rt.pending[req.ID]
	delete(rt.pending, req.ID)
	loop := rt.loop
	rt.mu.Unlock()
	if !ok {
		return
	}
	loop.RunOnLoop(func(vm *goja.Runtime) {
		if req.Error != "" {
			_ = p.reject(vm.ToValue(req.Error))
			return
		}
		var v any
		if len(req.Result) > 0 {
			if err := json.Unmarshal(req.Result, &v); err != nil {
				_ = p.reject(vm.ToValue("bad cdp_result: " + err.Error()))
				return
			}
		}
		_ = p.resolve(vm.ToValue(v))
	})
}

func describeJSError(err error) string {
	var ex *goja.Exception
	if errors.As(err, &ex) {
		text := ex.Error()
		if len(text) > 4000 {
			text = text[:4000] + "…"
		}
		return strings.TrimSpace(text)
	}
	return err.Error()
}

// The cell as the body of an async function. Its top-level declarations are
// rewritten in place so they land on the global object and survive into the
// next cell — `const a = 1, b` becomes `void (a = 1, b = undefined)`, a
// function or class declaration is followed by `globalThis["f"] = f` — the
// way Node's REPL handles top-level await (lib/internal/repl/await.js). A cell
// that does not parse is left alone: the runtime reports its syntax error.
// The code keeps its line numbers.
func wrapCell(code string) string {
	return "__longx_run(async () => {\n" + hoistDeclarations(code) + "\n})"
}

type sourceEdit struct {
	start, end int // [start, end) replaced by text; start == end inserts
	text       string
}

func hoistDeclarations(code string) string {
	const prefix = "(async () => {\n"
	src := prefix + code + "\n})"
	program, err := parser.ParseFile(nil, "", src, 0)
	if err != nil || len(program.Body) != 1 {
		return code
	}
	stmt, ok := program.Body[0].(*ast.ExpressionStatement)
	if !ok {
		return code
	}
	arrow, ok := stmt.Expression.(*ast.ArrowFunctionLiteral)
	if !ok {
		return code
	}
	block, ok := arrow.Body.(*ast.BlockStatement)
	if !ok {
		return code
	}
	at := func(idx interface{ Idx0() file.Idx }) int { return int(idx.Idx0()) - 1 - len(prefix) }
	end := func(idx interface{ Idx1() file.Idx }) int { return int(idx.Idx1()) - 1 - len(prefix) }
	var edits []sourceEdit
	declaration := func(keyword int, bindings []*ast.Binding, last int) {
		kw := keyword
		for kw < len(code) && code[kw] != ' ' && code[kw] != '\t' && code[kw] != '\n' {
			kw++
		}
		edits = append(edits, sourceEdit{keyword, kw, "void ("})
		for _, b := range bindings {
			if _, ident := b.Target.(*ast.Identifier); ident && b.Initializer == nil {
				edits = append(edits, sourceEdit{end(b), end(b), " = undefined"})
			}
		}
		edits = append(edits, sourceEdit{last, last, ")"})
	}
	for _, s := range block.List {
		switch d := s.(type) {
		case *ast.VariableStatement:
			declaration(at(d), d.List, end(d))
		case *ast.LexicalDeclaration:
			declaration(at(d), d.List, end(d))
		case *ast.FunctionDeclaration:
			if d.Function.Name != nil {
				name := d.Function.Name.Name.String()
				edits = append(edits, sourceEdit{end(d), end(d), fmt.Sprintf("; globalThis[%q] = %s;", name, name)})
			}
		case *ast.ClassDeclaration:
			if d.Class.Name != nil {
				name := d.Class.Name.Name.String()
				edits = append(edits, sourceEdit{end(d), end(d), fmt.Sprintf("; globalThis[%q] = %s;", name, name)})
			}
		}
	}
	// from the end, so earlier offsets stay valid
	sort.SliceStable(edits, func(i, j int) bool { return edits[i].start > edits[j].start })
	out := code
	for _, e := range edits {
		if e.start < 0 || e.end > len(out) || e.start > e.end {
			return code
		}
		out = out[:e.start] + e.text + out[e.end:]
	}
	return out
}
