package main

import (
	"io"
	"log"
	"os"
)

var logger = log.New(io.Discard, "", 0)

// initLogger routes shim diagnostics per the -log flag: "" (off), "stderr",
// or a file path. Never stdout — that is the protocol channel.
func initLogger(target string) error {
	var w io.Writer
	switch target {
	case "":
		return nil
	case "stderr":
		w = os.Stderr
	default:
		f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return err
		}
		w = f
	}
	logger = log.New(w, "[shim] ", log.Lmicroseconds)
	return nil
}

func logf(format string, args ...any) { logger.Printf(format, args...) }
