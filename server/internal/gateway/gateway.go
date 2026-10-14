// SPDX-License-Identifier: AGPL-3.0-or-later

// Package gateway runs the folval-gw service loops: DNS sinkhole (UDP+TCP)
// and HTTP echo/logger. Runs unprivileged — listens on high ports only
// (:1053/:8080); host nftables DNATs guest traffic 53->1053 and 80->8080
// on the lab bridge, so the guest sees standard ports.
package gateway

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
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

	lg.Event("meta", "", "gateway.start", "",
		fmt.Sprintf("dns=%s http=%s sinkhole=%s overrides=%d", cfg.DNSAddr, cfg.HTTPAddr, cfg.Sinkhole, len(ov)))

	errCh := make(chan error, 3)
	go func() { errCh <- fmt.Errorf("gateway: dns udp: %w", dnsUDPLoop(udpConn, sinkhole, ov, lg)) }()
	go func() { errCh <- fmt.Errorf("gateway: dns tcp: %w", dnsTCPLoop(tcpLn, sinkhole, ov, lg)) }()
	go func() {
		srv := &http.Server{Handler: HTTPHandler(lg), ReadHeaderTimeout: 10 * time.Second}
		errCh <- fmt.Errorf("gateway: http: %w", srv.Serve(httpLn))
	}()
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

// HTTPHandler returns the echo/logger handler: every request is logged
// (method, Host, path) and answered 200 with a body that self-identifies
// as folval-gw so accidental client hits are self-evidencing in guest-side
// logs too.
func HTTPHandler(lg *evidence.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := r.Host + r.URL.Path
		lg.Event("http", r.RemoteAddr, "http.request", name, r.Method)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintf(w, "folval-gw mock gateway\nMethod: %s\nURL: %s\nHost: %s\n", r.Method, r.URL.Path, r.Host)
	})
}
