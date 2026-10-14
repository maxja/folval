// SPDX-License-Identifier: AGPL-3.0-or-later
package gateway

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/maxja/folval/server/internal/dnswire"
	"github.com/maxja/folval/server/internal/evidence"
)

func TestAnswerIPOverrideWins(t *testing.T) {
	ov := map[string]net.IP{"pinned.test.": net.ParseIP("10.0.0.9")}
	if got := AnswerIP("pinned.test.", net.ParseIP("192.168.100.1"), ov); !got.Equal(net.ParseIP("10.0.0.9")) {
		t.Errorf("override not honored: %v", got)
	}
	if got := AnswerIP("other.test.", net.ParseIP("192.168.100.1"), ov); !got.Equal(net.ParseIP("192.168.100.1")) {
		t.Errorf("sinkhole not applied: %v", got)
	}
}

// buildQuery mirrors the wire format from the dnswire tests.
func buildQuery(t *testing.T, id uint16, name string, qtype uint16) []byte {
	t.Helper()
	msg := []byte{byte(id >> 8), byte(id), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}
	msg = append(msg, dnswire.EncodeName(name)...)
	return append(msg, byte(qtype>>8), byte(qtype), 0x00, 0x01)
}

func testLogger() *evidence.Logger { return evidence.NewLogger(io.Discard) }

func TestUDPDNSRoundTrip(t *testing.T) {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	go dnsUDPLoop(conn, net.ParseIP("192.168.100.1"), map[string]net.IP{
		"pinned.test.": net.ParseIP("10.0.0.9"),
	}, testLogger())

	client, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	cases := []struct {
		name     string
		qtype    uint16
		wantIP   string // "" = expect no answer record
		wantANCN byte
	}{
		{"anything.test.", qtypeA, "192.168.100.1", 1},
		{"pinned.test.", qtypeA, "10.0.0.9", 1},
		{"aaaa.test.", qtypeAAAA, "", 0},
	}
	for _, tc := range cases {
		q := buildQuery(t, 0x4242, tc.name, tc.qtype)
		if _, err := client.WriteTo(q, conn.LocalAddr()); err != nil {
			t.Fatal(err)
		}
		buf := make([]byte, 1500)
		_ = client.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _, err := client.ReadFrom(buf)
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		reply := buf[:n]
		if reply[0] != 0x42 || reply[1] != 0x42 {
			t.Errorf("%s: id not echoed", tc.name)
		}
		if reply[2]&0x80 == 0 {
			t.Errorf("%s: QR not set", tc.name)
		}
		if reply[7] != tc.wantANCN {
			t.Errorf("%s: ancount = %d, want %d", tc.name, reply[7], tc.wantANCN)
		}
		if tc.wantIP != "" && !bytes.Contains(reply, net.ParseIP(tc.wantIP).To4()) {
			t.Errorf("%s: answer IP %s missing from reply", tc.name, tc.wantIP)
		}
	}
}

func TestTCPDNSRoundTrip(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go dnsTCPLoop(ln, net.ParseIP("192.168.100.1"), nil, testLogger())

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	q := buildQuery(t, 0x0777, "tcp.test.", qtypeA)
	out := make([]byte, 2+len(q))
	binary.BigEndian.PutUint16(out, uint16(len(q)))
	copy(out[2:], q)
	if _, err := conn.Write(out); err != nil {
		t.Fatal(err)
	}

	r := bufio.NewReader(conn)
	var prefix [2]byte
	if _, err := io.ReadFull(r, prefix[:]); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, binary.BigEndian.Uint16(prefix[:]))
	if _, err := io.ReadFull(r, reply); err != nil {
		t.Fatal(err)
	}
	if reply[7] != 1 || !bytes.Contains(reply, net.ParseIP("192.168.100.1").To4()) {
		t.Errorf("unexpected TCP reply: % x", reply)
	}
}

func TestHTTPHandlerEchoes(t *testing.T) {
	var logBuf bytes.Buffer
	h := HTTPHandler(evidence.NewLogger(&logBuf))
	srv := httptest.NewServer(h)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/health")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		t.Errorf("status = %d", resp.StatusCode)
	}
	if !strings.Contains(string(body), "folval-gw") {
		t.Errorf("body does not self-identify: %q", body)
	}
	logLine := logBuf.String()
	if !strings.Contains(logLine, `"type":"http.request"`) || !strings.Contains(logLine, "/health") {
		t.Errorf("missing evidence line: %q", logLine)
	}
}
