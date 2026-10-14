// SPDX-License-Identifier: AGPL-3.0-or-later
package dnswire

import (
	"bytes"
	"encoding/hex"
	"net"
	"testing"
)

// buildQuery is a test helper: minimal well-formed 1-question A/AAAA query.
func buildQuery(t *testing.T, id uint16, name string, qtype uint16) []byte {
	t.Helper()
	msg := []byte{
		byte(id >> 8), byte(id), // id
		0x01, 0x00, // flags: RD
		0x00, 0x01, // qdcount
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	}
	msg = append(msg, EncodeName(name)...)
	msg = append(msg, byte(qtype>>8), byte(qtype), 0x00, 0x01) // qtype, class IN
	return msg
}

func TestParseQueryWellFormed(t *testing.T) {
	msg := buildQuery(t, 0xBEEF, "Example.COM", 1)
	id, name, qtype, ok := ParseQuery(msg)
	if !ok {
		t.Fatal("expected ok")
	}
	if id != 0xBEEF {
		t.Errorf("id = %#x, want 0xBEEF", id)
	}
	if name != "example.com." {
		t.Errorf("name = %q, want lowercase dot-terminated", name)
	}
	if qtype != 1 {
		t.Errorf("qtype = %d, want 1 (A)", qtype)
	}
}

func TestParseQueryMalformed(t *testing.T) {
	cases := [][]byte{
		nil,
		[]byte{0x00, 0x01, 0x01}, // short header
		{0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}, // qdcount != 1
	}
	for i, msg := range cases {
		if _, _, _, ok := ParseQuery(msg); ok {
			t.Errorf("case %d: expected not ok", i)
		}
	}
}

func TestBuildReplySinkholeAnswer(t *testing.T) {
	q := buildQuery(t, 0x1234, "anything.test.", 1)
	_, name, qtype, _ := ParseQuery(q)
	reply := BuildReply(0x1234, name, qtype, net.ParseIP("192.168.100.1").To4(), RCODEOK)
	if len(reply) < HeaderLen {
		t.Fatalf("reply too short: %d", len(reply))
	}
	if reply[0] != 0x12 || reply[1] != 0x34 {
		t.Errorf("id not echoed: % x", reply[:2])
	}
	if reply[2]&0x80 == 0 {
		t.Error("QR bit not set")
	}
	if reply[3]&0x0F != 0 {
		t.Errorf("rcode = %d, want 0", reply[3]&0x0F)
	}
	if reply[6] != 0 || reply[7] != 1 {
		t.Errorf("ancount = %d, want 1", uint16(reply[6])<<8|uint16(reply[7]))
	}
	if !bytes.Contains(reply, net.ParseIP("192.168.100.1").To4()) {
		t.Errorf("answer missing sinkhole IP: %s", hex.Dump(reply))
	}
}

func TestBuildReplyNoAnswerNXDomain(t *testing.T) {
	reply := BuildReply(0x0001, "nx.test.", 1, nil, 3) // rcode 3 = NXDOMAIN
	if reply[3]&0x0F != 3 {
		t.Errorf("rcode = %d, want 3", reply[3]&0x0F)
	}
	if reply[6] != 0 || reply[7] != 0 {
		t.Errorf("ancount = %d, want 0", uint16(reply[6])<<8|uint16(reply[7]))
	}
}
