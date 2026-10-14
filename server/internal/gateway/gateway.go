// SPDX-License-Identifier: AGPL-3.0-or-later

// Package gateway runs the folval-gw service loops: DNS sinkhole (UDP+TCP)
// and HTTP echo/logger. Runs unprivileged — listens on high ports only
// (:1053/:8080); host nftables DNATs guest traffic 53->1053 and 80->8080
// on the lab bridge, so the guest sees standard ports.
package gateway

import (
	"net"
	"net/http"

	"github.com/maxja/folval/server/internal/config"
	"github.com/maxja/folval/server/internal/evidence"
)

// Run starts the DNS (UDP+TCP) and HTTP loops per cfg and blocks until one
// fails.
func Run(cfg config.Config) error {
	panic("phase2: not implemented")
}

// AnswerIP resolves the lookup policy: override IP if present, else sinkhole.
func AnswerIP(name string, sinkhole net.IP, ov map[string]net.IP) net.IP {
	panic("phase2: not implemented")
}

// dnsUDPLoop answers queries on a UDP socket; one goroutine, sequential
// read/respond. Logs every query (name, type, override-vs-sinkhole decision).
func dnsUDPLoop(conn net.PacketConn, sinkhole net.IP, ov map[string]net.IP, lg *evidence.Logger) error {
	panic("phase2: not implemented")
}

// dnsTCPLoop answers queries on TCP (length-prefixed messages, RFC 1035 §4.2.2).
// Needed for truncation-fallback resolvers and large payloads.
func dnsTCPLoop(ln net.Listener, sinkhole net.IP, ov map[string]net.IP, lg *evidence.Logger) error {
	panic("phase2: not implemented")
}

// HTTPHandler returns the echo/logger handler: every request is logged
// (method, Host, path) and answered 200 with a body that self-identifies
// as folval-gw so accidental client hits are self-evidencing in guest-side
// logs too.
func HTTPHandler(lg *evidence.Logger) http.Handler {
	panic("phase2: not implemented")
}
