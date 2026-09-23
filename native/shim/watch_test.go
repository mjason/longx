package main

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

// a project tree to watch: files and directories relative to root
func tree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, content := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if content != "/" {
			if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	return root
}

func write(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestIgnoredListsWhatTheLayersHide(t *testing.T) {
	root := tree(t, map[string]string{
		".gitignore":             "target/\n.longx/\n*.log\n",
		".longxignore":           "!target/reports/\nsecret.txt\n",
		".git/HEAD":              "ref: refs/heads/main\n",
		"src/a.py":               "",
		"src/b.log":              "",
		"node_modules/x/y.js":    "",
		"target/other.bin":       "",
		"target/reports/r.txt":   "",
		".longx/local/agent.exs": "",
		"secret.txt":             "",
	})
	cfg := ruleConfig{Root: root, Git: true, Ignore: []string{"node_modules/"}, Watch: []string{".longx/"}}

	got := listIgnored(cfg, 1000)
	slices.Sort(got)
	// an ignored directory whole (trailing slash); one a later rule reaches into only
	// itself (no slash), with what stays ignored inside it named one by one
	want := []string{"node_modules/", "secret.txt", "src/b.log", "target", "target/other.bin"}
	if !slices.Equal(got, want) {
		t.Fatalf("ignored = %v, want %v", got, want)
	}
}

// the @ search's list: every file the rules keep, what a `!` rule brings back included
func TestFilesListsWhatTheRulesKeep(t *testing.T) {
	root := tree(t, map[string]string{
		".gitignore":           "target/\n*.log\n",
		".longxignore":         "!target/reports/\n",
		".git/HEAD":            "ref: refs/heads/main\n",
		"src/a.py":             "",
		"src/b.log":            "",
		"node_modules/x/y.js":  "",
		"target/other.bin":     "",
		"target/reports/r.txt": "",
	})
	got := listFiles(ruleConfig{Root: root, Git: true, Ignore: []string{"node_modules/"}}, 1000)
	slices.Sort(got)
	want := []string{".gitignore", ".longxignore", "src/a.py", "target/reports/r.txt"}
	if !slices.Equal(got, want) {
		t.Fatalf("files = %v, want %v", got, want)
	}
	if n := len(listFiles(ruleConfig{Root: root, Git: true}, 2)); n != 2 {
		t.Fatalf("the cap was not kept: %d", n)
	}
}

func TestIgnoredWithoutGitReadsNoGitignore(t *testing.T) {
	root := tree(t, map[string]string{".gitignore": "src/\n", "src/a.py": "", "dist/x": ""})
	got := listIgnored(ruleConfig{Root: root, Git: false, Ignore: []string{"dist/"}}, 1000)
	if !slices.Equal(got, []string{"dist/"}) {
		t.Fatalf("ignored = %v", got)
	}
}

type batch struct {
	Ready    bool     `json:"ready"`
	Watches  int      `json:"watches"`
	Paths    []string `json:"paths"`
	More     bool     `json:"more"`
	Git      bool     `json:"git"`
	Rules    bool     `json:"rules"`
	Overflow bool     `json:"overflow"`
	Repo     bool     `json:"repo"`
	Error    string   `json:"error"`
}

// runs the watch loop on root; batches arrive on the channel; closing stdin ends it
func startWatch(t *testing.T, cfg ruleConfig) (<-chan batch, func()) {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = watchLoop(inR, outW, cfg, 100*time.Millisecond)
		outW.Close()
	}()
	ch := make(chan batch, 100)
	go func() {
		sc := bufio.NewScanner(outR)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			var b batch
			if err := json.Unmarshal(sc.Bytes(), &b); err == nil {
				ch <- b
			}
		}
		close(ch)
	}()
	stop := func() {
		inW.Close()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("the watch loop did not end when stdin closed")
		}
	}
	select {
	case b := <-ch:
		if !b.Ready {
			t.Fatalf("first line is not ready: %+v", b)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no ready line")
	}
	return ch, stop
}

// the paths of every batch within d, and whether any carried the flag
func collect(ch <-chan batch, d time.Duration) (paths []string, bs []batch) {
	deadline := time.After(d)
	for {
		select {
		case b, ok := <-ch:
			if !ok {
				return
			}
			bs = append(bs, b)
			paths = append(paths, b.Paths...)
		case <-deadline:
			return
		}
	}
}

func TestWatchReportsChangesOutsideTheIgnoredTrees(t *testing.T) {
	root := tree(t, map[string]string{
		"src/a.py":            "",
		"node_modules/x/y.js": "",
		".gitignore":          "target/\n.longx/\n",
		".git/HEAD":           "ref: refs/heads/main\n",
		"target/":             "/",
		".longx/local/":       "/",
	})
	ch, stop := startWatch(t, ruleConfig{Root: root, Git: true, Ignore: []string{"node_modules/"}, Watch: []string{".longx/"}})
	defer stop()

	write(t, root, "src/a.py", "print(1)")
	write(t, root, "node_modules/x/y.js", "x")
	write(t, root, "target/out.bin", "x")
	// gitignored, but always watched: the agent description
	write(t, root, ".longx/local/agent.exs", "agent do end")
	paths, _ := collect(ch, 800*time.Millisecond)

	if !slices.Contains(paths, "src/a.py") || !slices.Contains(paths, ".longx/local/agent.exs") {
		t.Fatalf("missing changes: %v", paths)
	}
	for _, p := range paths {
		if p == "node_modules/x/y.js" || p == "target/out.bin" {
			t.Fatalf("an ignored path was reported: %v", paths)
		}
	}
}

func TestWatchFollowsNewDirectories(t *testing.T) {
	root := tree(t, map[string]string{"src/a.py": ""})
	ch, stop := startWatch(t, ruleConfig{Root: root})
	defer stop()

	if err := os.MkdirAll(filepath.Join(root, "pkg/deep"), 0o755); err != nil {
		t.Fatal(err)
	}
	collect(ch, 400*time.Millisecond)
	write(t, root, "pkg/deep/new.go", "package x")
	paths, _ := collect(ch, 600*time.Millisecond)
	if !slices.Contains(paths, "pkg/deep/new.go") {
		t.Fatalf("a file in a new directory was not reported: %v", paths)
	}
}

func TestLongxignoreBringsBackADirectoryGitIgnores(t *testing.T) {
	root := tree(t, map[string]string{
		".gitignore":      "target/\n",
		".longxignore":    "!target/reports/\n",
		".git/HEAD":       "ref: refs/heads/main\n",
		"target/reports/": "/",
	})
	ch, stop := startWatch(t, ruleConfig{Root: root, Git: true})
	defer stop()

	write(t, root, "target/reports/r.txt", "r")
	write(t, root, "target/other.bin", "x")
	paths, _ := collect(ch, 800*time.Millisecond)
	if !slices.Contains(paths, "target/reports/r.txt") {
		t.Fatalf("the brought-back directory was not watched: %v", paths)
	}
	if slices.Contains(paths, "target/other.bin") {
		t.Fatalf("the rest of target/ was reported: %v", paths)
	}
}

func TestAChangedIgnoreFileReloadsTheRules(t *testing.T) {
	root := tree(t, map[string]string{".gitignore": "", ".git/HEAD": "x", "build/": "/"})
	ch, stop := startWatch(t, ruleConfig{Root: root, Git: true})
	defer stop()

	write(t, root, ".gitignore", "build/\n")
	_, bs := collect(ch, 600*time.Millisecond)
	if !slices.ContainsFunc(bs, func(b batch) bool { return b.Rules }) {
		t.Fatalf("no rules batch after .gitignore changed: %+v", bs)
	}
	write(t, root, "build/x.o", "x")
	paths, _ := collect(ch, 600*time.Millisecond)
	if slices.Contains(paths, "build/x.o") {
		t.Fatalf("a newly ignored directory was still reported: %v", paths)
	}
}

func TestGitStateChangesAreFlagged(t *testing.T) {
	root := tree(t, map[string]string{".git/HEAD": "ref: refs/heads/main\n", ".git/refs/heads/": "/", "a.txt": ""})
	ch, stop := startWatch(t, ruleConfig{Root: root, Git: true})
	defer stop()

	write(t, root, ".git/refs/heads/feature", "abc")
	write(t, root, ".git/HEAD", "ref: refs/heads/feature\n")
	paths, bs := collect(ch, 600*time.Millisecond)
	if !slices.ContainsFunc(bs, func(b batch) bool { return b.Git }) {
		t.Fatalf("no git batch: %+v", bs)
	}
	for _, p := range paths {
		if len(p) >= 5 && p[:5] == ".git/" {
			t.Fatalf("git internals reported as file changes: %v", paths)
		}
	}
}

// git init / rm -rf .git: the host restarts the watcher with the other config
func TestARepositoryComingOrGoingIsFlagged(t *testing.T) {
	root := tree(t, map[string]string{"a.txt": ""})
	ch, stop := startWatch(t, ruleConfig{Root: root})
	defer stop()

	write(t, root, ".git/HEAD", "ref: refs/heads/main\n")
	_, bs := collect(ch, 600*time.Millisecond)
	if !slices.ContainsFunc(bs, func(b batch) bool { return b.Repo }) {
		t.Fatalf("no repo batch after .git appeared: %+v", bs)
	}
	if err := os.RemoveAll(filepath.Join(root, ".git")); err != nil {
		t.Fatal(err)
	}
	_, bs = collect(ch, 600*time.Millisecond)
	if !slices.ContainsFunc(bs, func(b batch) bool { return b.Repo }) {
		t.Fatalf("no repo batch after .git went: %+v", bs)
	}
}

func TestABurstIsCoalesced(t *testing.T) {
	root := tree(t, map[string]string{"src/": "/"})
	ch, stop := startWatch(t, ruleConfig{Root: root})
	defer stop()

	for i := 0; i < 200; i++ {
		write(t, root, "src/f"+string(rune('a'+i%26))+".txt", "x")
	}
	_, bs := collect(ch, 800*time.Millisecond)
	if len(bs) == 0 || len(bs) > 4 {
		t.Fatalf("200 writes in %d batches", len(bs))
	}
}
