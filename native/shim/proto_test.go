package main

import (
	"bytes"
	"io"
	"testing"
)

func TestPacketRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	if err := writePacket(&buf, TagOutput, []byte("hello")); err != nil {
		t.Fatalf("write: %v", err)
	}
	// 4 byte length (tag + payload) + tag + payload
	want := []byte{0, 0, 0, 6, TagOutput, 'h', 'e', 'l', 'l', 'o'}
	if !bytes.Equal(buf.Bytes(), want) {
		t.Fatalf("wire format mismatch: got %v want %v", buf.Bytes(), want)
	}

	pkt, err := readPacket(&buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if pkt.Tag != TagOutput || string(pkt.Data) != "hello" {
		t.Fatalf("got %+v", pkt)
	}
}

func TestReadPacketEmptyPayload(t *testing.T) {
	var buf bytes.Buffer
	if err := writePacket(&buf, TagCloseInput, nil); err != nil {
		t.Fatal(err)
	}
	pkt, err := readPacket(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if pkt.Tag != TagCloseInput || len(pkt.Data) != 0 {
		t.Fatalf("got %+v", pkt)
	}
}

func TestReadPacketEOF(t *testing.T) {
	_, err := readPacket(bytes.NewReader(nil))
	if err != io.EOF {
		t.Fatalf("want io.EOF, got %v", err)
	}
}

func TestReadPacketTruncatedIsNotEOF(t *testing.T) {
	// length says 6 bytes follow, only 2 present
	_, err := readPacket(bytes.NewReader([]byte{0, 0, 0, 6, TagOutput, 'h'}))
	if err == nil || err == io.EOF {
		t.Fatalf("want a non-EOF error for truncated packet, got %v", err)
	}
}

func TestReadPacketRejectsOversized(t *testing.T) {
	_, err := readPacket(bytes.NewReader([]byte{0xff, 0xff, 0xff, 0xff, TagOutput}))
	if err == nil {
		t.Fatal("want error for oversized packet")
	}
}

func TestReadPacketRejectsZeroLength(t *testing.T) {
	_, err := readPacket(bytes.NewReader([]byte{0, 0, 0, 0}))
	if err == nil {
		t.Fatal("want error for zero-length packet (must at least carry a tag)")
	}
}

func TestWritePacketRejectsOversized(t *testing.T) {
	var buf bytes.Buffer
	err := writePacket(&buf, TagOutput, make([]byte, MaxPayload+1))
	if err == nil {
		t.Fatal("want error for oversized payload")
	}
}

func TestDecodeEnv(t *testing.T) {
	data := []byte{0, 3, 'A', '=', '1', 0, 5, 'B', 'B', '=', '2', '2'}
	env, err := decodeEnv(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(env) != 2 || env[0] != "A=1" || env[1] != "BB=22" {
		t.Fatalf("got %v", env)
	}
}

func TestDecodeEnvTruncated(t *testing.T) {
	if _, err := decodeEnv([]byte{0, 9, 'A'}); err == nil {
		t.Fatal("want error")
	}
	if _, err := decodeEnv([]byte{0}); err == nil {
		t.Fatal("want error")
	}
}

func TestUint32Helpers(t *testing.T) {
	b := encodeUint32(0x01020304)
	if !bytes.Equal(b, []byte{1, 2, 3, 4}) {
		t.Fatal(b)
	}
	n, err := decodeUint32(b)
	if err != nil || n != 0x01020304 {
		t.Fatal(n, err)
	}
	if _, err := decodeUint32([]byte{1, 2}); err == nil {
		t.Fatal("want error for short input")
	}
}
