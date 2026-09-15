package main

import (
	"reflect"
	"testing"
)

func TestClassify(t *testing.T) {
	got := Classify([]string{"/dev/nvidia0", " /dev/dri ", "/var/run/docker.sock", "", "/dev"})
	want := []Bind{
		{Path: "/dev/nvidia0", Dev: true},
		{Path: "/dev/dri", Dev: true},
		{Path: "/var/run/docker.sock", Dev: false},
		{Path: "/dev", Dev: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
}

func TestPassthrough(t *testing.T) {
	for _, args := range [][]string{{}, {"--help"}, {"--version"}, {"--ro-bind", "/", "/", "--", "true"}} {
		if !Passthrough(args) {
			t.Errorf("%v should pass through", args)
		}
	}
	if Passthrough([]string{"--ro-bind", "/", "/", "--dev", "/dev", "--", "true"}) {
		t.Error("a command line with --dev must be rewritten")
	}
}

func TestRewriteInsertsAfterDev(t *testing.T) {
	// the shape codex builds (linux-sandbox/src/bwrap.rs): root, /dev, then the writable roots
	args := []string{"--ro-bind", "/", "/", "--dev", "/dev", "--bind", "/tmp", "/tmp", "--unshare-user", "--", "/usr/bin/zsh", "-lc", "nvidia-smi --dev /x"}
	got := Rewrite(args, Classify([]string{"/dev/nvidia0", "/dev/dxg", "/var/run/docker.sock"}))
	want := []string{"--ro-bind", "/", "/", "--dev", "/dev",
		"--dev-bind", "/dev/nvidia0", "/dev/nvidia0",
		"--dev-bind", "/dev/dxg", "/dev/dxg",
		"--bind", "/var/run/docker.sock", "/var/run/docker.sock",
		"--bind", "/tmp", "/tmp", "--unshare-user", "--", "/usr/bin/zsh", "-lc", "nvidia-smi --dev /x"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
}

func TestRewriteLeavesOtherShapesAlone(t *testing.T) {
	binds := Classify([]string{"/dev/nvidia0"})
	noDev := []string{"--ro-bind", "/", "/", "--", "true"}
	if got := Rewrite(noDev, binds); !reflect.DeepEqual(got, noDev) {
		t.Fatalf("no --dev: got %v", got)
	}
	// `--dev` after the separator belongs to the command
	after := []string{"--ro-bind", "/", "/", "--", "sh", "-c", "--dev", "/dev"}
	if got := Rewrite(after, binds); !reflect.DeepEqual(got, after) {
		t.Fatalf("--dev after --: got %v", got)
	}
	withDev := []string{"--dev", "/dev", "--", "true"}
	if got := Rewrite(withDev, nil); !reflect.DeepEqual(got, withDev) {
		t.Fatalf("no binds: got %v", got)
	}
}
