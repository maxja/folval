// SPDX-License-Identifier: AGPL-3.0-or-later
package gateway

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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

func TestTCPProbeCapturesFirstBytesNoResponse(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	var logBuf bytes.Buffer
	lg := evidence.NewLogger(&logBuf)
	go tcpProbeLoop(ln, lg)

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write([]byte("folval-probe-first-bytes")); err != nil {
		t.Fatal(err)
	}
	// Capture-only: the listener must never respond. A short read deadline
	// proves no bytes arrive before we close our side.
	_ = conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	got := make([]byte, 16)
	if n, err := conn.Read(got); n > 0 {
		t.Fatalf("probe listener responded with %d bytes: %q", n, got[:n])
	} else if err == nil {
		t.Fatal("read returned 0 bytes and no error — unexpected")
	} else if !os.IsTimeout(err) {
		t.Fatalf("expected read timeout, got %v", err)
	}
	conn.Close()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		s := logBuf.String()
		if strings.Contains(s, "tcp.probe-close") {
			if !strings.Contains(s, "tcp.probe-data") {
				t.Fatal("close logged without any data event")
			}
			want := hex.EncodeToString([]byte("folval-probe-first-bytes"))
			if !strings.Contains(s, "hex="+want) {
				t.Fatalf("captured hex missing payload; got:\n%s", s)
			}
			return // pass
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no tcp.probe-close within deadline; got:\n%s", logBuf.String())
}

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
	h := HTTPHandler(evidence.NewLogger(&logBuf), "")
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

func TestNCSIResponses(t *testing.T) {
	// Direct unit checks of the override table.
	if s, loc, body, ok := ncsiResponse("www.msftconnecttest.com", "/connecttest.txt"); !ok || s != 200 || body != "Microsoft Connect Test" || loc != "" {
		t.Errorf("connecttest.txt: %d %q %q ok=%v", s, loc, body, ok)
	}
	// Port-suffixed Host must still match.
	if s, _, _, ok := ncsiResponse("www.msftconnecttest.com:80", "/connecttest.txt"); !ok || s != 200 {
		t.Errorf("port-suffixed host: %d ok=%v", s, ok)
	}
	if s, loc, _, ok := ncsiResponse("ipv6.msftconnecttest.com", "/redirect"); !ok || s != 302 || loc != "http://ipv6.msftconnecttest.com/redirect" {
		t.Errorf("redirect: %d %q ok=%v", s, loc, ok)
	}
	if _, _, _, ok := ncsiResponse("www.msftconnecttest.com", "/other.txt"); ok {
		t.Errorf("unknown path on NCSI host must fall through to echo")
	}
	if _, _, _, ok := ncsiResponse("evil.example", "/connecttest.txt"); ok {
		t.Errorf("non-NCSI host must not get NCSI responses")
	}
}

func TestHTTPHandlerNCSIOverTheWire(t *testing.T) {
	h := HTTPHandler(testLogger(), "")
	srv := httptest.NewServer(h)
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/connecttest.txt", nil)
	req.Host = "www.msftconnecttest.com"
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || string(body) != "Microsoft Connect Test" {
		t.Errorf("NCSI probe not answered genuinely: %d %q", resp.StatusCode, body)
	}
}

func TestHTTPHandlerPushRoute(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "stage.txt"), []byte("payload"), 0o644); err != nil {
		t.Fatal(err)
	}
	var logBuf bytes.Buffer
	h := HTTPHandler(evidence.NewLogger(&logBuf), dir)
	srv := httptest.NewServer(h)
	defer srv.Close()

	// File is served...
	resp, err := http.Get(srv.URL + "/push/stage.txt")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || string(body) != "payload" {
		t.Errorf("push serve: %d %q", resp.StatusCode, body)
	}
	if !strings.Contains(logBuf.String(), `"type":"http.push"`) {
		t.Errorf("missing push evidence line: %q", logBuf.String())
	}
	// ...http.Dir keeps everything inside the root (paths are cleaned and
	// rejoined onto the root), and missing files 404...
	resp2, err := http.Get(srv.URL + "/push/missing.txt")
	if err != nil {
		t.Fatal(err)
	}
	resp2.Body.Close()
	if resp2.StatusCode != 404 {
		t.Errorf("missing file should 404: %d", resp2.StatusCode)
	}
	// ...and with pushDir disabled the route is gone.
	h2 := HTTPHandler(testLogger(), "")
	srv2 := httptest.NewServer(h2)
	defer srv2.Close()
	resp3, err := http.Get(srv2.URL + "/push/stage.txt")
	if err != nil {
		t.Fatal(err)
	}
	body3, _ := io.ReadAll(resp3.Body)
	if strings.Contains(string(body3), "payload") {
		t.Errorf("push route must be disabled without pushdir: %q", body3)
	}
}

func TestParseForward(t *testing.T) {
	spec, err := parseForward("192.168.100.1:8443->192.168.100.10:8443")
	if err != nil || spec.Listen != "192.168.100.1:8443" || spec.Target != "192.168.100.10:8443" {
		t.Fatalf("valid spec not parsed: %+v err=%v", spec, err)
	}
	if spec, err := parseForward(""); err != nil || spec.Listen != "" {
		t.Fatalf("empty input must yield disabled spec, got %+v err=%v", spec, err)
	}
	for _, bad := range []string{"no-arrow", "->target", "listen->", "192.168.100.1:8443->noport"} {
		if _, err := parseForward(bad); err == nil {
			t.Errorf("invalid spec %q accepted", bad)
		}
	}
}

// TestForwardRelaysAndLogs checks the oracle path end-to-end: a client
// through the forward listener reaches the target and gets its bytes back
// (the mode ANSWERS, unlike the capture-only probes), and the evidence log
// records open, first-chunk head per direction, and close with totals.
func TestForwardRelaysAndLogs(t *testing.T) {
	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	go func() { // echo server = stand-in for the reference backend
		for {
			c, err := target.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_, _ = io.Copy(c, c)
			}(c)
		}
	}()

	fwdLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer fwdLn.Close()
	var logBuf bytes.Buffer
	lg := evidence.NewLogger(&logBuf)
	go forwardLoop(fwdLn, target.Addr().String(), lg)

	conn, err := net.Dial("tcp", fwdLn.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	payload := []byte("folval-oracle-relay")
	if _, err := conn.Write(payload); err != nil {
		t.Fatal(err)
	}
	echo := make([]byte, len(payload))
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := io.ReadFull(conn, echo); err != nil {
		t.Fatalf("relay did not answer: %v", err)
	}
	if !bytes.Equal(echo, payload) {
		t.Fatalf("echo mismatch: %q", echo)
	}
	conn.Close() // triggers relay close + logging

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		s := logBuf.String()
		if strings.Contains(s, "tcp.forward-close") {
			if !strings.Contains(s, "tcp.forward-open") || !strings.Contains(s, `"type":"tcp.forward-data"`) {
				t.Fatalf("missing open/data events; got:\n%s", s)
			}
			if !strings.Contains(s, "hex="+hex.EncodeToString(payload)) {
				t.Fatalf("first-chunk hex head missing; got:\n%s", s)
			}
			// detail is JSON: '>' is escaped as \u003e
			if !strings.Contains(s, "client-\\u003eserver=19") || !strings.Contains(s, "server-\\u003eclient=19") {
				t.Fatalf("byte totals missing; got:\n%s", s)
			}
			return // pass
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no tcp.forward-close within deadline; got:\n%s", logBuf.String())
}

// TestForwardDialFailureLogged pins the failure mode the game sees when the
// reference server is not up yet: connection accepted, then closed again —
// logged as dial-failed so the evidence trail explains the client's retry.
func TestForwardDialFailureLogged(t *testing.T) {
	// Nothing listens on the target port (reserved TEST-NET-3 loop is fine
	// for connect attempts; use 127.0.0.1 with an unlikely port).
	fwdLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer fwdLn.Close()
	var logBuf bytes.Buffer
	lg := evidence.NewLogger(&logBuf)
	go forwardLoop(fwdLn, "127.0.0.1:1", lg)

	conn, err := net.Dial("tcp", fwdLn.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 8)
	if _, err := conn.Read(buf); err == nil {
		t.Fatal("expected EOF after dial failure")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(logBuf.String(), "dial-failed") {
			return // pass
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no dial-failed event within deadline; got:\n%s", logBuf.String())
}
