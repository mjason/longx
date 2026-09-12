// Wire protocol between the BEAM (host) and the shim.
//
// Every packet is `<<len::32-big, tag::8, payload::binary>>` where len covers
// the tag byte plus the payload — exactly what an Erlang port opened with
// `{:packet, 4}` produces and expects. The framing and the demand-driven
// read model are adapted from odu (github.com/akash-akya/ex_cmd, MIT,
// Copyright Akash Hiremath), itself based on goon (github.com/alco/goon, MIT,
// Copyright Alexei Sholik). See NOTICE at the repository root.
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// ProtocolVersion must match Longx.Shim.Proto on the Elixir side.
const ProtocolVersion = "3"

// Packets sent by the host to the shim.
const (
	TagInput       uint8 = 1  // payload: bytes for the child's stdin
	TagCloseInput  uint8 = 2  // close the child's stdin
	TagSendOutput  uint8 = 3  // payload: max::32 — read at most `max` bytes from stdout once
	TagSendStderr  uint8 = 4  // payload: max::32 — same for stderr
	TagCloseOutput uint8 = 5  // stop reading stdout
	TagCloseStderr uint8 = 6  // stop reading stderr
	TagKill        uint8 = 7  // payload: grace_ms::32 — terminate the tree, SIGKILL after grace
	TagSignal      uint8 = 8  // payload: signum::32 — forward a signal to the child
	TagCommandEnv  uint8 = 9  // payload: [len::16, "K=V"]* — must be the first packet
	TagSendStats   uint8 = 10 // answer with one Stats packet for the child's process tree
)

// Packets sent by the shim to the host.
const (
	TagPid        uint8 = 16 // payload: pid::32
	TagOutput     uint8 = 17 // payload: stdout bytes (answer to SendOutput)
	TagOutputEOF  uint8 = 18 // stdout reached EOF or was closed
	TagStderr     uint8 = 19 // payload: stderr bytes (answer to SendStderr)
	TagStderrEOF  uint8 = 20
	TagExitStatus uint8 = 21 // payload: status::32-signed
	TagStartError uint8 = 22 // payload: reason string; the child never started
	TagSendInput  uint8 = 23 // the child is ready for one more Input packet
	TagStats      uint8 = 24 // payload: JSON {"processes","rss_bytes","cpu_ms"} (answer to SendStats)
)

// MaxPayload is the largest payload that fits in a single packet. Kept at
// 64 KiB minus framing so one packet always fits one Erlang port message.
const MaxPayload = (1 << 16) - 5

const headerSize = 4 + 1

var (
	errPayloadTooLarge = errors.New("shim: payload exceeds MaxPayload")
	errBadLength       = errors.New("shim: invalid packet length")
	errShortField      = errors.New("shim: field too short")
)

// Packet is one decoded frame.
type Packet struct {
	Tag  uint8
	Data []byte
}

// readPacket reads one frame. It returns io.EOF only on a clean EOF at a
// frame boundary; a truncated frame is io.ErrUnexpectedEOF.
func readPacket(r io.Reader) (Packet, error) {
	var head [headerSize]byte

	if _, err := io.ReadFull(r, head[:4]); err != nil {
		if err == io.ErrUnexpectedEOF {
			return Packet{}, err
		}
		return Packet{}, io.EOF
	}

	length := binary.BigEndian.Uint32(head[:4])
	if length < 1 || length-1 > MaxPayload {
		return Packet{}, errBadLength
	}

	if _, err := io.ReadFull(r, head[4:5]); err != nil {
		return Packet{}, io.ErrUnexpectedEOF
	}

	data := make([]byte, length-1)
	if _, err := io.ReadFull(r, data); err != nil {
		return Packet{}, io.ErrUnexpectedEOF
	}

	return Packet{Tag: head[4], Data: data}, nil
}

// writePacket writes one frame with a single Write call so concurrent writers
// serialised by a mutex never interleave frames.
func writePacket(w io.Writer, tag uint8, data []byte) error {
	if len(data) > MaxPayload {
		return errPayloadTooLarge
	}

	frame := make([]byte, headerSize+len(data))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(data)+1))
	frame[4] = tag
	copy(frame[5:], data)

	_, err := w.Write(frame)
	return err
}

// decodeEnv parses the CommandEnv payload: repeated `<<len::16, "KEY=VALUE">>`.
func decodeEnv(data []byte) ([]string, error) {
	var env []string
	for i := 0; i < len(data); {
		if i+2 > len(data) {
			return nil, fmt.Errorf("shim: truncated env length at offset %d", i)
		}
		n := int(binary.BigEndian.Uint16(data[i : i+2]))
		i += 2
		if i+n > len(data) {
			return nil, fmt.Errorf("shim: truncated env entry at offset %d", i)
		}
		env = append(env, string(data[i:i+n]))
		i += n
	}
	return env, nil
}

func encodeUint32(n uint32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, n)
	return b
}

func decodeUint32(b []byte) (uint32, error) {
	if len(b) != 4 {
		return 0, errShortField
	}
	return binary.BigEndian.Uint32(b), nil
}
