package main

// Which paths of a project Longx ignores — the file watcher skips them, the
// file tree dims them, the @ search leaves them out. Every source is written
// in gitignore syntax and they stack, the later overriding the earlier (the
// last matching rule decides, `!` means "not ignored"):
//
//  1. Ignore — Longx's built-in list, then the global setting, then the
//     project's (sent by the host)
//  2. .gitignore — when the project is a git repository: the global
//     excludesfile (sent by the host), .git/info/exclude, the root's and every
//     deeper .gitignore
//  3. Watch — always watched, even when .gitignore hides it (`.longx/`):
//     built in, global, the project's (sent by the host), each line a `!` rule
//  4. .longxignore at the root — above everything: `!target/reports/` brings
//     back what .gitignore hides, a plain line ignores more
//
// `.git` itself is never walked: only its HEAD, index, packed-refs and refs/
// are watched, for the git window.

import (
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"

	"github.com/go-git/go-git/v5/plumbing/format/gitignore"
)

type ruleConfig struct {
	Root      string   `json:"root"`
	Git       bool     `json:"git"`
	Ignore    []string `json:"ignore"`
	Watch     []string `json:"watch"`
	GitGlobal []string `json:"git_global"`
}

type rules struct {
	cfg    ruleConfig
	ignore []gitignore.Pattern
	// the root's patterns first, deeper .gitignore files after (their domain says where they apply)
	git   []gitignore.Pattern
	gitAt map[string]bool // directories whose .gitignore is read
	watch []gitignore.Pattern
	longx []gitignore.Pattern
	// the `!` rules naming a path below a directory (`target/reports`): an ignored
	// directory on their way is still walked, so they can take effect
	reach   [][]string
	matcher gitignore.Matcher
}

func newRules(cfg ruleConfig) *rules {
	r := &rules{cfg: cfg, gitAt: map[string]bool{}}
	r.ignore = parseLines(cfg.Ignore, nil)
	if cfg.Git {
		r.git = append(parseLines(cfg.GitGlobal, nil), readPatterns(filepath.Join(cfg.Root, ".git", "info", "exclude"), nil)...)
		r.readGitignore("")
	}
	for _, line := range cleanLines(cfg.Watch) {
		line = strings.TrimPrefix(line, "!")
		r.watch = append(r.watch, gitignore.ParsePattern("!"+line, nil))
		r.addReach(line)
	}
	for _, line := range readLines(filepath.Join(cfg.Root, ".longxignore")) {
		r.longx = append(r.longx, gitignore.ParsePattern(line, nil))
		if strings.HasPrefix(line, "!") {
			r.addReach(strings.TrimPrefix(line, "!"))
		}
	}
	r.rebuild()
	return r
}

func (r *rules) rebuild() {
	all := slices.Concat(r.ignore, r.git, r.watch, r.longx)
	r.matcher = gitignore.NewMatcher(all)
}

// a directory's own .gitignore, read once as the walk reaches it
func (r *rules) readGitignore(rel string) {
	if !r.cfg.Git || r.gitAt[rel] {
		return
	}
	r.gitAt[rel] = true
	var domain []string
	if rel != "" {
		domain = strings.Split(rel, "/")
	}
	ps := readPatterns(filepath.Join(r.cfg.Root, filepath.FromSlash(rel), ".gitignore"), domain)
	if len(ps) > 0 {
		r.git = append(r.git, ps...)
		r.rebuild()
	}
}

func (r *rules) addReach(line string) {
	p := strings.Trim(line, "/")
	if strings.Contains(p, "/") {
		r.reach = append(r.reach, strings.Split(p, "/"))
	}
}

func (r *rules) ignored(rel string, dir bool) bool {
	if rel == "" {
		return false
	}
	return r.matcher.Match(strings.Split(rel, "/"), dir)
}

// an ignored directory some `!` rule names a path below
func (r *rules) reachesBelow(rel string) bool {
	comps := strings.Split(rel, "/")
	for _, p := range r.reach {
		if reaches(p, comps) {
			return true
		}
	}
	return false
}

func reaches(pattern, dir []string) bool {
	for i, c := range dir {
		if i >= len(pattern) {
			return false
		}
		if pattern[i] == "**" {
			return true
		}
		if ok, _ := path.Match(pattern[i], c); !ok {
			return false
		}
	}
	return len(pattern) > len(dir)
}

// walk visits every directory the rules keep (bridge: ignored, but walked for a
// `!` rule below it) and every file in them; `.git` is never entered
func (r *rules) walk(start string, dir func(rel string, bridge bool), file func(rel string)) {
	r.walkUntil(start, dir, file, nil)
}

// walkUntil: walk, ended as soon as full answers true
func (r *rules) walkUntil(start string, dir func(rel string, bridge bool), file func(rel string), full func() bool) {
	base := filepath.Join(r.cfg.Root, filepath.FromSlash(start))
	_ = filepath.WalkDir(base, func(p string, d os.DirEntry, err error) error {
		if full != nil && full() {
			return filepath.SkipAll
		}
		if err != nil {
			if d != nil && d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		rel := relPath(r.cfg.Root, p)
		if d.IsDir() {
			if d.Name() == ".git" {
				return filepath.SkipDir
			}
			bridge := false
			if r.ignored(rel, true) {
				if !r.reachesBelow(rel) {
					return filepath.SkipDir
				}
				bridge = true
			}
			r.readGitignore(rel)
			if dir != nil {
				dir(rel, bridge)
			}
			return nil
		}
		if file != nil {
			file(rel)
		}
		return nil
	})
}

// listIgnored: what the tree dims — an ignored directory whole (`dist/`), a
// bridge only itself (`target`, no slash) and what stays ignored inside it
// one by one, ignored files where the walk goes; at most max entries
func listIgnored(cfg ruleConfig, max int) []string {
	r := newRules(cfg)
	out := []string{}
	add := func(s string) {
		if len(out) < max {
			out = append(out, s)
		}
	}
	bridges := map[string]bool{}
	r.walk("", func(rel string, bridge bool) {
		if bridge {
			bridges[rel] = true
			add(rel)
		}
	}, func(rel string) {
		if r.ignored(rel, false) {
			add(rel)
		}
	})
	// the ignored directories the walk skipped: children of a walked directory
	walked := func(rel string) bool {
		dir := path.Dir(rel)
		return dir == "." || !r.ignored(dir, true) || bridges[dir]
	}
	r.walk("", func(rel string, _ bool) {
		entries, err := os.ReadDir(filepath.Join(cfg.Root, filepath.FromSlash(rel)))
		if err != nil {
			return
		}
		for _, e := range entries {
			if !e.IsDir() || e.Name() == ".git" {
				continue
			}
			child := strings.TrimPrefix(rel+"/"+e.Name(), "/")
			if r.ignored(child, true) && !r.reachesBelow(child) && walked(child) {
				add(child + "/")
			}
		}
	}, nil)
	return out
}

// listFiles: the files the rules keep (the @ search's list), at most max
func listFiles(cfg ruleConfig, max int) []string {
	r := newRules(cfg)
	out := []string{}
	r.walkUntil("", nil, func(rel string) {
		if len(out) < max && !r.ignored(rel, false) {
			out = append(out, rel)
		}
	}, func() bool { return len(out) >= max })
	return out
}

func relPath(root, p string) string {
	rel, err := filepath.Rel(root, p)
	if err != nil || rel == "." {
		return ""
	}
	return filepath.ToSlash(rel)
}

func parseLines(lines []string, domain []string) []gitignore.Pattern {
	var ps []gitignore.Pattern
	for _, l := range cleanLines(lines) {
		ps = append(ps, gitignore.ParsePattern(l, domain))
	}
	return ps
}

func readPatterns(file string, domain []string) []gitignore.Pattern {
	return parseLines(readLines(file), domain)
}

func readLines(file string) []string {
	b, err := os.ReadFile(file)
	if err != nil {
		return nil
	}
	return cleanLines(strings.Split(string(b), "\n"))
}

// blank lines and comments dropped, trailing spaces and CRs trimmed
func cleanLines(lines []string) []string {
	var out []string
	for _, l := range lines {
		l = strings.TrimRight(l, " \r\t")
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		out = append(out, l)
	}
	return out
}
