// SPDX-License-Identifier: AGPL-3.0-or-later

// Package gateway runs the folval-gw service loops: DNS sinkhole (UDP+TCP)
// and HTTP echo/logger. Runs unprivileged — listens on high ports only
// (:1053/:8080); host nftables DNATs guest traffic 53->1053 and 80->8080
// on the lab bridge, so the guest sees standard ports.
package gateway

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/maxja/folval/server/internal/config"
	"github.com/maxja/folval/server/internal/dnswire"
	"github.com/maxja/folval/server/internal/evidence"
	"github.com/maxja/folval/server/internal/overrides"
)

// qtypeA / qtypeAAAA are the only question types the policy distinguishes.
const (
	qtypeA    = 1
	qtypeAAAA = 28
)

// Run starts the DNS (UDP+TCP) and HTTP loops per cfg and blocks until one
// fails.
func Run(cfg config.Config) error {
	sinkhole := net.ParseIP(cfg.Sinkhole)
	if sinkhole == nil || sinkhole.To4() == nil {
		return fmt.Errorf("gateway: sinkhole must be IPv4, got %q", cfg.Sinkhole)
	}
	ov := make(map[string]net.IP)
	if cfg.Overrides != "" {
		var err error
		ov, err = overrides.LoadFromFile(cfg.Overrides)
		if err != nil {
			return err
		}
	}

	var out io.Writer = os.Stderr
	if cfg.Out != "" {
		f, err := os.OpenFile(cfg.Out, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
		if err != nil {
			return fmt.Errorf("gateway: open log: %w", err)
		}
		defer f.Close()
		out = f
	}
	lg := evidence.NewLogger(out)

	udpConn, err := net.ListenPacket("udp", cfg.DNSAddr)
	if err != nil {
		return fmt.Errorf("gateway: dns udp listen: %w", err)
	}
	defer udpConn.Close()
	tcpLn, err := net.Listen("tcp", cfg.DNSAddr)
	if err != nil {
		return fmt.Errorf("gateway: dns tcp listen: %w", err)
	}
	defer tcpLn.Close()
	httpLn, err := net.Listen("tcp", cfg.HTTPAddr)
	if err != nil {
		return fmt.Errorf("gateway: http listen: %w", err)
	}
	defer httpLn.Close()
	var probeLn net.Listener
	if cfg.TCPProbe != "" {
		probeLn, err = net.Listen("tcp", cfg.TCPProbe)
		if err != nil {
			return fmt.Errorf("gateway: tcprobe listen: %w", err)
		}
		defer probeLn.Close()
	}
	var tlsLn net.Listener
	fwd, fwdErr := parseForward(cfg.Forward)
	if fwdErr != nil {
		return fwdErr
	}
	// Mode overlap on one port (8443), priority: gameserver > forward >
	// probe. Resolved before ANY listener is created so a yielded mode never
	// binds.
	if cfg.GameserverAddr != "" {
		if cfg.GameserverAddr == cfg.TLSProbe {
			cfg.TLSProbe = ""
		}
		if cfg.GameserverAddr == fwd.Listen {
			fwd.Listen = ""
		}
	}
	if fwd.Listen != "" && fwd.Listen == cfg.TLSProbe {
		cfg.TLSProbe = ""
	}
	if cfg.TLSProbe != "" {
		tlsLn, err = net.Listen("tcp", cfg.TLSProbe)
		if err != nil {
			return fmt.Errorf("gateway: tlsprobe listen: %w", err)
		}
		defer tlsLn.Close()
	}
	// Gameserver endpoint (Phase 5) — TLS + .hqs routes; see gameserver.go.
	var gsLn net.Listener
	if cfg.GameserverAddr != "" {
		gsLn, err = net.Listen("tcp", cfg.GameserverAddr)
		if err != nil {
			return fmt.Errorf("gateway: gameserver listen: %w", err)
		}
		defer gsLn.Close()
	}
	var fwdLn net.Listener
	if fwd.Listen != "" {
		fwdLn, err = net.Listen("tcp", fwd.Listen)
		if err != nil {
			return fmt.Errorf("gateway: forward listen: %w", err)
		}
		defer fwdLn.Close()
	}

	lg.Event("meta", "", "gateway.start", "",
		fmt.Sprintf("dns=%s http=%s tcprobe=%s tlsprobe=%s forward=%s->%s gameserver=%s sinkhole=%s overrides=%d", cfg.DNSAddr, cfg.HTTPAddr, cfg.TCPProbe, cfg.TLSProbe, fwd.Listen, fwd.Target, cfg.GameserverAddr, cfg.Sinkhole, len(ov)))

	errCh := make(chan error, 8)
	go func() { errCh <- fmt.Errorf("gateway: dns udp: %w", dnsUDPLoop(udpConn, sinkhole, ov, lg)) }()
	go func() { errCh <- fmt.Errorf("gateway: dns tcp: %w", dnsTCPLoop(tcpLn, sinkhole, ov, lg)) }()
	go func() {
		srv := &http.Server{Handler: HTTPHandler(lg, cfg.PushDir), ReadHeaderTimeout: 10 * time.Second}
		errCh <- fmt.Errorf("gateway: http: %w", srv.Serve(httpLn))
	}()
	if probeLn != nil {
		go func() { errCh <- fmt.Errorf("gateway: tcprobe: %w", tcpProbeLoop(probeLn, lg)) }()
	}
	if tlsLn != nil {
		go func() { errCh <- fmt.Errorf("gateway: tlsprobe: %w", tcpProbeLoop(tlsLn, lg)) }()
	}
	if fwdLn != nil {
		go func() { errCh <- fmt.Errorf("gateway: forward: %w", forwardLoop(fwdLn, fwd.Target, lg)) }()
	}
	if gsLn != nil {
		go func() {
			errCh <- fmt.Errorf("gateway: gameserver: %w", gameserverLoop(gsLn, cfg.GameserverCert, cfg.GameserverAccount, cfg.GameserverKeylog, lg))
		}()
	}
	return <-errCh
}

// AnswerIP resolves the lookup policy: override IP if present, else sinkhole.
func AnswerIP(name string, sinkhole net.IP, ov map[string]net.IP) net.IP {
	if ip, ok := ov[name]; ok {
		return ip
	}
	return sinkhole
}

// respond builds and returns the reply for a parsed question, or a
// FORMERR/empty header reply for garbage input.
func respond(msg []byte, sinkhole net.IP, ov map[string]net.IP) []byte {
	id, name, qtype, ok := dnswire.ParseQuery(msg)
	if !ok {
		if len(msg) >= dnswire.HeaderLen { // echo id if we at least have a header
			id = uint16(msg[0])<<8 | uint16(msg[1])
			return dnswire.BuildReply(id, ".", qtypeA, nil, dnswire.RCODEFormerr)
		}
		return nil // not even a header: nothing sensible to echo
	}
	if qtype == qtypeA {
		return dnswire.BuildReply(id, name, qtype, AnswerIP(name, sinkhole, ov), dnswire.RCODEOK)
	}
	// Non-A questions: NOERROR with no answer records (AAAA especially —
	// sinkholing AAAA too would just shadow the A path in dual-stack clients).
	return dnswire.BuildReply(id, name, qtype, nil, dnswire.RCODEOK)
}

// dnsUDPLoop answers queries on a UDP socket; one goroutine, sequential
// read/respond. Logs every query (name, type, override-vs-sinkhole decision).
func dnsUDPLoop(conn net.PacketConn, sinkhole net.IP, ov map[string]net.IP, lg *evidence.Logger) error {
	buf := make([]byte, 1500) // room for EDNS-sized queries
	for {
		n, addr, err := conn.ReadFrom(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		query := buf[:n]
		reply := respond(query, sinkhole, ov)
		if reply == nil {
			lg.Event("dns", addr.String(), "dns.drop", "", "unparsable: no header")
			continue
		}
		logQuery(lg, addr.String(), query, reply)
		if _, err := conn.WriteTo(reply, addr); err != nil {
			lg.Event("dns", addr.String(), "dns.write-error", "", err.Error())
		}
	}
}

// logQuery emits one evidence line for a (query, reply) pair.
func logQuery(lg *evidence.Logger, src string, query, reply []byte) {
	_, name, qtype, ok := dnswire.ParseQuery(query)
	detail := fmt.Sprintf("type=%d", qtype)
	if !ok {
		detail = "malformed"
		name = ""
	} else if qtype == qtypeA && len(reply) >= 16 && reply[7] == 1 { // has A answer
		ip := reply[len(reply)-4:]
		detail = fmt.Sprintf("type=A answer=%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3])
	}
	lg.Event("dns", src, "dns.query", name, detail)
}

// dnsTCPLoop answers queries on TCP (length-prefixed messages, RFC 1035 §4.2.2).
// Needed for truncation-fallback resolvers and large payloads.
func dnsTCPLoop(ln net.Listener, sinkhole net.IP, ov map[string]net.IP, lg *evidence.Logger) error {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go serveDNSOverTCP(conn, sinkhole, ov, lg)
	}
}

func serveDNSOverTCP(conn net.Conn, sinkhole net.IP, ov map[string]net.IP, lg *evidence.Logger) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	for {
		var lenPrefix [2]byte
		if _, err := io.ReadFull(r, lenPrefix[:]); err != nil {
			return // client closed or idle timeout
		}
		msgLen := int(binary.BigEndian.Uint16(lenPrefix[:]))
		if msgLen == 0 {
			continue
		}
		query := make([]byte, msgLen)
		if _, err := io.ReadFull(r, query); err != nil {
			return
		}
		reply := respond(query, sinkhole, ov)
		if reply == nil {
			lg.Event("dns", conn.RemoteAddr().String(), "dns.drop", "", "unparsable: no header")
			return
		}
		logQuery(lg, conn.RemoteAddr().String(), query, reply)
		out := make([]byte, 2+len(reply))
		binary.BigEndian.PutUint16(out, uint16(len(reply)))
		copy(out[2:], reply)
		if _, err := conn.Write(out); err != nil {
			return
		}
	}
}

// tcpProbeLoop accepts connections on the capture-only probe listener
// (Phase 4b): the guest's analytics client SYN's the sinkhole on tcp/11234;
// the host firewall admits that port to this listener so the first bytes of
// the custom-port protocol can be captured without touching the guest.
func tcpProbeLoop(ln net.Listener, lg *evidence.Logger) error {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go serveTCPProbe(conn, lg)
	}
}

// Probe capture bounds: total bytes per connection and per-chunk hex head.
const (
	probeMaxTotal = 4096
	probeHexHead  = 512 // large enough for a TLS ClientHello incl. SNI
	probeIdle     = 30 * time.Second
)

// serveTCPProbe reads and logs what the client sends, then closes. It NEVER
// writes — the listener is evidence capture, not a mock backend; the client
// is expected to retry on its own backoff (observed 1/2/4/8 s on the wire).
func serveTCPProbe(conn net.Conn, lg *evidence.Logger) {
	defer conn.Close()
	src := conn.RemoteAddr().String()
	_ = conn.SetReadDeadline(time.Now().Add(probeIdle))
	total := 0
	buf := make([]byte, 1024)
	for total < probeMaxTotal {
		n, err := conn.Read(buf)
		if n > 0 {
			head := buf[:n]
			if len(head) > probeHexHead {
				head = head[:probeHexHead]
			}
			lg.Event("tcp", src, "tcp.probe-data", "",
				fmt.Sprintf("len=%d total=%d hex=%s", n, total+n, hex.EncodeToString(head)))
			total += n
			_ = conn.SetReadDeadline(time.Now().Add(probeIdle))
		}
		if err != nil {
			break // EOF, idle timeout, or reset — capture-only, never respond
		}
	}
	lg.Event("tcp", src, "tcp.probe-close", "", fmt.Sprintf("total=%d", total))
}

// ForwardSpec is a parsed -forward flag: relay LISTEN to TARGET.
type ForwardSpec struct {
	Listen string
	Target string
}

// parseForward validates the "LISTEN->TARGET" flag form; empty input
// yields an empty spec (disabled).
func parseForward(s string) (ForwardSpec, error) {
	if s == "" {
		return ForwardSpec{}, nil
	}
	i := strings.Index(s, "->")
	if i <= 0 || i+2 >= len(s) {
		return ForwardSpec{}, fmt.Errorf("gateway: forward must be LISTEN->TARGET, got %q", s)
	}
	spec := ForwardSpec{Listen: strings.TrimSpace(s[:i]), Target: strings.TrimSpace(s[i+2:])}
	for _, addr := range []string{spec.Listen, spec.Target} {
		if _, _, err := net.SplitHostPort(addr); err != nil {
			return ForwardSpec{}, fmt.Errorf("gateway: forward address %q: %w", addr, err)
		}
	}
	return spec, nil
}

// forwardLoop relays each accepted connection to the oracle target (the
// in-guest reference server). Unlike the capture-only probes this mode
// ANSWERS — the client's TLS gets a server response so the handshake (and
// the game's protocol above it) proceeds while the host pcap ring records
// every byte on the wire.
func forwardLoop(ln net.Listener, target string, lg *evidence.Logger) error {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go serveForward(conn, target, lg)
	}
}

// serveForward gates on the first ClientHello's SNI, then relays to the
// oracle target (the in-guest reference server). Unlike the capture-only
// probes this mode ANSWERS — the client's TLS gets a server response so the
// handshake (and the game's protocol above it) proceeds while the host pcap
// ring records every byte on the wire.
//
// SNI GATE (session 12): the sealed guest resolves EVERY name to this host
// (DNS sinkhole), and Windows background services (WCDP wdcp/wdcpalt,
// ecs.office, settings-win, Edge, WU, checkappexec — plus Steam) dial the
// forward port with modern TLS1.2/1.3 ClientHellos. The ancient OpenSSL
// oracle dies silently under those bursts (205/302 observed relayed sources
// carried wdcp* SNIs). The game's legacy stack sends a 182-byte TLS1.0
// ClientHello with NO SNI. Policy: relay only no-SNI (the game, and any
// pre-SNI legacy client) or SNI "Gameserver"; RST everything else. Unparsable
// heads are ALLOWED — the game path must never be blocked by a parser edge.
// Refusals are logged (tcp.forward-refused) so the noise cadence stays visible.
func serveForward(conn net.Conn, target string, lg *evidence.Logger) {
	defer conn.Close()
	src := conn.RemoteAddr().String()

	// Dial the target concurrently with the ClientHello peek so dial-failure
	// semantics (instant FIN to the client + event) stay identical to the
	// pre-gate forward even for silent connections.
	type dialResult struct {
		up  net.Conn
		err error
	}
	dialCh := make(chan dialResult, 1)
	go func() {
		up, err := net.DialTimeout("tcp", target, 5*time.Second)
		if err != nil {
			lg.Event("tcp", src, "tcp.forward-open", target, "dial-failed: "+err.Error())
		}
		dialCh <- dialResult{up, err}
	}()

	head, name, _ := peekClientHello(conn)
	if name != "" && !strings.EqualFold(name, "Gameserver") {
		lg.Event("tcp", src, "tcp.forward-refused", target, "sni="+name)
		if d := <-dialCh; d.err == nil {
			d.up.Close() // never relayed: release the oracle-side conn
		}
		if tc, ok := conn.(*net.TCPConn); ok {
			_ = tc.SetLinger(0) // RST on close: fail fast, no polite FIN to linger on
		}
		return
	}

	d := <-dialCh
	if d.err != nil {
		return // already logged dial-failed above
	}
	up := d.up
	defer up.Close()
	lg.Event("tcp", src, "tcp.forward-open", target, "relay")
	cs, sc := relayLogged(io.MultiReader(bytes.NewReader(head), conn), conn, up, src, lg)
	lg.Event("tcp", src, "tcp.forward-close", target, fmt.Sprintf("client->server=%d server->client=%d", cs, sc))
}

// peekClientHello reads (bounded: 5s deadline, 16KB cap) until the first
// complete TLS record is buffered, returning it plus its SNI ("" when the
// hello carries none or cannot be parsed). The returned head must be
// replayed into the relay — those bytes are already consumed from conn.
func peekClientHello(conn net.Conn) (head []byte, sni string, err error) {
	const maxHead = 16 * 1024
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer func() { _ = conn.SetReadDeadline(time.Time{}) }()

	buf := make([]byte, 0, 4096)
	tmp := make([]byte, 4096)
	for len(buf) < maxHead {
		n, rerr := conn.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
		}
		if len(buf) >= 1 && buf[0] != 0x16 {
			// Not a TLS v3 record head (SSLv2-style or plain data): nothing
			// to gate on — relay immediately, parser said "". This keeps the
			// non-TLS fast path the forward historically had.
			return buf, "", nil
		}
		if len(buf) >= 5 && buf[0] == 0x16 {
			recLen := int(buf[3])<<8 | int(buf[4])
			if recLen >= 0 && len(buf) >= 5+recLen {
				return buf[:5+recLen], sniFromClientHello(buf[:5+recLen]), nil
			}
		}
		if rerr != nil {
			if len(buf) > 0 {
				return buf, sniFromClientHello(buf), nil
			}
			return nil, "", rerr
		}
	}
	return buf, sniFromClientHello(buf), nil
}

// sniFromClientHello walks the TLS record -> handshake -> extensions chain
// with explicit bounds checks and returns the server_name (host_name) of the
// first name_type=0 entry, lowercased. Returns "" on ANY structural doubt —
// callers treat "" as "gate open" (game path must never be blocked).
func sniFromClientHello(b []byte) string {
	if len(b) < 5 || b[0] != 0x16 {
		return ""
	}
	p := 5
	if len(b) < p+4 || b[p] != 0x01 { // handshake type: ClientHello
		return ""
	}
	p += 4 // handshake type(1) + length(3); legacy_version(2) + random(32) follow
	p += 2 + 32
	if len(b) < p+1 {
		return ""
	}
	sessLen := int(b[p])
	p++
	if len(b) < p+sessLen {
		return ""
	}
	p += sessLen
	if len(b) < p+2 {
		return ""
	}
	cipherLen := int(b[p])<<8 | int(b[p+1])
	p += 2
	if len(b) < p+cipherLen || cipherLen%2 != 0 {
		return ""
	}
	p += cipherLen
	if len(b) < p+1 {
		return ""
	}
	compLen := int(b[p])
	p++
	if len(b) < p+compLen {
		return ""
	}
	p += compLen
	if len(b) < p+2 { // no extensions block at all
		return ""
	}
	extTotal := int(b[p])<<8 | int(b[p+1])
	p += 2
	if len(b) < p+extTotal {
		return ""
	}
	end := p + extTotal
	for p+4 <= end {
		extType := int(b[p])<<8 | int(b[p+1])
		extLen := int(b[p+2])<<8 | int(b[p+3])
		p += 4
		if p+extLen > end {
			return ""
		}
		if extType == 0 { // server_name
			q := p
			if q+2 > p+extLen {
				return ""
			}
			listLen := int(b[q])<<8 | int(b[q+1])
			q += 2
			if q+listLen > p+extLen {
				return ""
			}
			for q+3 <= p+extLen {
				nameType := int(b[q])
				nameLen := int(b[q+1])<<8 | int(b[q+2])
				q += 3
				if q+nameLen > p+extLen {
					return ""
				}
				if nameType == 0 && nameLen > 0 {
					return strings.ToLower(string(b[q : q+nameLen]))
				}
				q += nameLen
			}
		}
		p += extLen
	}
	return ""
}

// relayLogged copies both directions concurrently; the first direction to
// finish closes both sockets so the other unblocks. Returns byte totals.
// client is an io.Reader: serveForward wraps the conn with a prefix reader
// when it pre-read the ClientHello for the SNI gate.
func relayLogged(clientRead io.Reader, clientConn net.Conn, server net.Conn, src string, lg *evidence.Logger) (cs, sc int64) {
	type dirResult struct {
		dir string
		n   int64
	}
	res := make(chan dirResult, 2)
	copyOne := func(from io.Reader, to net.Conn, dir string) {
		n, _ := copyLogged(from, to, dir, src, lg)
		res <- dirResult{dir, n}
	}
	go copyOne(clientRead, server, "c2s")
	go copyOne(server, clientConn, "s2c")
	r1 := <-res
	clientConn.Close()
	server.Close()
	r2 := <-res
	for _, r := range []dirResult{r1, r2} {
		if r.dir == "c2s" {
			cs = r.n
		} else {
			sc = r.n
		}
	}
	return
}

// copyLogged copies src->dst, logging ONLY the first chunk (hex head,
// probeHexHead cap) as tcp.forward-data — ClientHello/SNI parity with probe
// mode without bloating the JSONL on long relays; the pcap ring holds the
// authoritative bytes.
func copyLogged(from io.Reader, to net.Conn, dir, src string, lg *evidence.Logger) (int64, error) {
	var total int64
	first := true
	buf := make([]byte, 32*1024)
	for {
		n, err := from.Read(buf)
		if n > 0 {
			if first {
				head := buf[:n]
				if len(head) > probeHexHead {
					head = head[:probeHexHead]
				}
				lg.Event("tcp", src, "tcp.forward-data", dir,
					fmt.Sprintf("len=%d total=%d hex=%s", n, total+int64(n), hex.EncodeToString(head)))
				first = false
			}
			total += int64(n)
			if _, werr := to.Write(buf[:n]); werr != nil {
				return total, werr
			}
		}
		if err != nil {
			return total, err
		}
	}
}

// ncsiBody is the exact page body Windows NCSI expects (a byte-different
// body makes Windows report "no internet", which changes client behavior —
// the lab must look online to the guest).
const ncsiBody = "Microsoft Connect Test"

// ncsiResponse returns the canned NCSI reply for host/path, or ok=false if
// the request is not an NCSI probe. Windows probes two endpoints:
//
//	/connecttest.txt -> 200 with the fixed body above
//	/redirect       -> 302 redirecting to itself (probe follows it and
//	                   expects the same redirect again)
//
// Matching is on Host (port stripped) + path; both the IPv4 and IPv6 probe
// hostnames are covered.
func ncsiResponse(host, path string) (status int, location, body string, ok bool) {
	host = strings.Split(host, ":")[0]
	if host != "www.msftconnecttest.com" && host != "ipv6.msftconnecttest.com" {
		return 0, "", "", false
	}
	switch path {
	case "/connecttest.txt":
		return http.StatusOK, "", ncsiBody, true
	case "/redirect":
		return http.StatusFound, "http://" + host + "/redirect", "", true
	}
	return 0, "", "", false
}

// HTTPHandler returns the echo/logger handler: every request is logged
// (method, Host, path) and answered 200 with a body that self-identifies
// as folval-gw so accidental client hits are self-evidencing in guest-side
// logs too. NCSI probes are the one built-in exception: they get the
// genuine Microsoft responses so Windows reports "Internet access".
// With pushDir set, GET /push/<name> serves files from that directory —
// the D5 acquisition path for staging the game into the guest over the
// isolated net (the only HTTP route the firewall permits).
// pushPrefix is the URL path prefix routed to the staging directory.
const pushPrefix = "/push/"

func HTTPHandler(lg *evidence.Logger, pushDir string) http.Handler {
	var pushFS http.Handler
	if pushDir != "" {
		pushFS = http.StripPrefix(pushPrefix, http.FileServer(http.Dir(pushDir)))
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := r.Host + r.URL.Path
		if pushFS != nil && strings.HasPrefix(r.URL.Path, pushPrefix) {
			lg.Event("http", r.RemoteAddr, "http.push", name, r.Method)
			pushFS.ServeHTTP(w, r)
			return
		}
		if status, location, body, ok := ncsiResponse(r.Host, r.URL.Path); ok {
			lg.Event("http", r.RemoteAddr, "http.request", name, r.Method+" ncsi")
			if location != "" {
				w.Header().Set("Location", location)
			}
			w.WriteHeader(status)
			fmt.Fprint(w, body)
			return
		}
		lg.Event("http", r.RemoteAddr, "http.request", name, r.Method)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintf(w, "folval-gw mock gateway\nMethod: %s\nURL: %s\nHost: %s\n", r.Method, r.URL.Path, r.Host)
	})
}
