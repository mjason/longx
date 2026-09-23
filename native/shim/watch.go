package main

// `shim watch`: the project's file watcher (fsnotify). The first stdin line is
// the rule config (rules.go); every directory the rules keep gets a watch,
// new ones as they appear. Changes are coalesced for a window and written as
// one JSON line: {"paths": [...], "more", "git", "rules", "overflow", "repo"}. The
// loop ends when stdin closes — the host went away, or stopped watching
// because no page is open.
//
// `shim ignored`: stdin is the rule config; stdout {"ignored": [...]} — what
// the file tree dims. `shim files`: {"files": [...]} — what the @ search
// looks through.

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"
)

const maxBatchPaths = 500

type watcher struct {
	w        *fsnotify.Watcher
	cfg      ruleConfig
	rules    *rules
	watched  map[string]bool
	addError string
	// the batch being gathered
	changed  map[string]bool
	git      bool
	reload   bool
	overflow bool
	repo     bool // .git came or went: the host restarts the watcher with the other config
}

func watchLoop(in io.Reader, out io.Writer, cfg ruleConfig, window time.Duration) error {
	enc := json.NewEncoder(out)
	fw, err := fsnotify.NewBufferedWatcher(4096)
	if err != nil {
		_ = enc.Encode(map[string]any{"error": err.Error()})
		return err
	}
	defer fw.Close()

	s := &watcher{w: fw, cfg: cfg, rules: newRules(cfg), watched: map[string]bool{}, changed: map[string]bool{}}
	s.sync()
	s.watchGit()
	_ = enc.Encode(map[string]any{"ready": true, "watches": len(s.watched)})
	if s.addError != "" {
		_ = enc.Encode(map[string]any{"error": s.addError})
	}

	stdinClosed := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, in)
		close(stdinClosed)
	}()

	var flush <-chan time.Time
	arm := func() {
		if flush == nil && s.pending() {
			flush = time.After(window)
		}
	}
	for {
		select {
		case <-stdinClosed:
			return nil
		case e, ok := <-fw.Events:
			if !ok {
				return nil
			}
			s.handle(e)
			arm()
		case err, ok := <-fw.Errors:
			if !ok {
				return nil
			}
			if errors.Is(err, fsnotify.ErrEventOverflow) {
				s.overflow = true
			} else {
				logger.Printf("watch: %v", err)
			}
			arm()
		case <-flush:
			flush = nil
			if s.reload {
				s.rules = newRules(s.cfg)
				before := s.addError
				s.sync()
				if s.addError != "" && s.addError != before {
					_ = enc.Encode(map[string]any{"error": s.addError})
				}
			}
			_ = enc.Encode(s.take())
		}
	}
}

func (s *watcher) pending() bool {
	return len(s.changed) > 0 || s.git || s.reload || s.overflow || s.repo
}

func (s *watcher) take() map[string]any {
	paths := make([]string, 0, len(s.changed))
	for p := range s.changed {
		paths = append(paths, p)
	}
	slices.Sort(paths)
	more := len(paths) > maxBatchPaths
	if more {
		paths = paths[:maxBatchPaths]
	}
	b := map[string]any{"paths": paths, "more": more, "git": s.git, "rules": s.reload, "overflow": s.overflow, "repo": s.repo}
	s.changed, s.git, s.reload, s.overflow, s.repo = map[string]bool{}, false, false, false, false
	return b
}

// the watches match what the rules keep now: added where missing, dropped where no longer wanted
func (s *watcher) sync() {
	want := map[string]bool{}
	s.rules.walk("", func(rel string, _ bool) { want[rel] = true }, nil)
	for rel := range s.watched {
		if !want[rel] && !strings.HasPrefix(rel, ".git") {
			_ = s.w.Remove(s.abs(rel))
			delete(s.watched, rel)
		}
	}
	for rel := range want {
		s.add(rel)
	}
}

func (s *watcher) add(rel string) {
	if s.watched[rel] {
		return
	}
	if err := s.w.Add(s.abs(rel)); err != nil {
		// most often the inotify limit (fs.inotify.max_user_watches): said once, the rest goes on
		if s.addError == "" {
			s.addError = "could not watch " + rel + ": " + err.Error()
		}
		return
	}
	s.watched[rel] = true
}

// .git: its own entries (HEAD, index, packed-refs), info/ and refs/ — a commit, a
// switch, a fetch; never objects/ or logs/
func (s *watcher) watchGit() {
	if !s.cfg.Git {
		return
	}
	if fi, err := os.Stat(s.abs(".git")); err != nil || !fi.IsDir() {
		return
	}
	s.add(".git")
	if _, err := os.Stat(s.abs(".git/info")); err == nil {
		s.add(".git/info")
	}
	_ = filepath.WalkDir(s.abs(".git/refs"), func(p string, d os.DirEntry, err error) error {
		if err == nil && d.IsDir() {
			s.add(relPath(s.cfg.Root, p))
		}
		return nil
	})
}

func (s *watcher) handle(e fsnotify.Event) {
	if e.Op&^fsnotify.Chmod == 0 {
		return
	}
	rel := relPath(s.cfg.Root, e.Name)
	if rel == "" {
		return
	}
	if rel == ".git" && e.Op&(fsnotify.Create|fsnotify.Remove|fsnotify.Rename) != 0 {
		s.repo = true
		return
	}
	if rel == ".git" || strings.HasPrefix(rel, ".git/") {
		s.handleGit(e, rel)
		return
	}
	if path.Base(rel) == ".gitignore" || rel == ".longxignore" {
		s.reload = true
	}

	dir := false
	if e.Op.Has(fsnotify.Create) || e.Op.Has(fsnotify.Write) {
		if fi, err := os.Stat(e.Name); err == nil {
			dir = fi.IsDir()
		}
	} else {
		dir = s.watched[rel]
	}

	switch {
	case e.Op.Has(fsnotify.Create) && dir:
		// a new directory: watched per the rules, and what landed in it before the
		// watch did reported with it
		s.rules.walk(rel, func(d string, _ bool) { s.add(d) }, func(f string) {
			if !s.rules.ignored(f, false) {
				s.changed[f] = true
			}
		})
	case e.Op.Has(fsnotify.Remove) || e.Op.Has(fsnotify.Rename):
		// a watch follows a renamed directory's inode: dropped with everything under it
		for w := range s.watched {
			if w == rel || strings.HasPrefix(w, rel+"/") {
				_ = s.w.Remove(s.abs(w))
				delete(s.watched, w)
			}
		}
	}

	if !s.rules.ignored(rel, dir) {
		s.changed[rel] = true
	}
}

func (s *watcher) handleGit(e fsnotify.Event, rel string) {
	switch {
	case rel == ".git/HEAD", rel == ".git/index", rel == ".git/packed-refs":
		s.git = true
	case strings.HasPrefix(rel, ".git/refs/"):
		s.git = true
		if e.Op.Has(fsnotify.Create) {
			if fi, err := os.Stat(e.Name); err == nil && fi.IsDir() {
				s.add(rel)
			}
		}
	case rel == ".git/info/exclude":
		s.reload = true
	}
}

func (s *watcher) abs(rel string) string {
	return filepath.Join(s.cfg.Root, filepath.FromSlash(rel))
}

// `shim watch`: the config on the first line, the loop until stdin closes
func watchMain() int {
	in := bufio.NewReader(os.Stdin)
	line, err := in.ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return 2
	}
	var cfg ruleConfig
	if err := json.Unmarshal(line, &cfg); err != nil {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"error": "bad config: " + err.Error()})
		return 2
	}
	if err := watchLoop(in, os.Stdout, cfg, 200*time.Millisecond); err != nil {
		return 1
	}
	return 0
}

// `shim ignored` / `shim files`: the config on stdin, the list on stdout
// ({"ignored": [...]} / {"files": [...]})
func listMain(key string, list func(ruleConfig, int) []string) int {
	var cfg struct {
		ruleConfig
		Max int `json:"max"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&cfg); err != nil {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"error": "bad config: " + err.Error()})
		return 2
	}
	if cfg.Max <= 0 {
		cfg.Max = 20000
	}
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{key: list(cfg.ruleConfig, cfg.Max)})
	return 0
}
