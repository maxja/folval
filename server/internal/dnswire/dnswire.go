// SPDX-License-Identifier: AGPL-3.0-or-later

// Package dnswire implements the minimal DNS wire format folval-gw needs:
// one-question query parsing and A-record reply construction. Hand-rolled
// on purpose (no external deps) — swap for miekg/dns in Phase 4+ if EDNS
// or other record types start mattering.
package dnswire

import "net"

// DNS wire-format limits and rcodes used by the parser/builder.
const (
	MaxUDPSize = 512 // classic UDP payload limit we read per packet
	HeaderLen  = 12  // id, flags, qd/an/ns/ar counts
	MaxNameLen = 255 // wire-format maximum encoded name length

	RCODEOK      = 0 // NOERROR
	RCODEFormerr = 1 // FORMERR — malformed query
	RCODERefused = 5 // REFUSED — unsupported opcode/question count
)

// EncodeName converts a dotted textual name to DNS wire format
// (length-prefixed labels, root-terminated, no compression).
func EncodeName(name string) []byte {
	panic("phase2: not implemented")
}

// ParseQuery decodes a DNS query message: returns the transaction id,
// the single question name (lowercased, dot-terminated, e.g. "example.com."),
// the qtype, and whether the message is a well-formed 1-question QUERY we
// are willing to answer.
func ParseQuery(msg []byte) (id uint16, name string, qtype uint16, ok bool) {
	panic("phase2: not implemented")
}

// BuildReply constructs a response to a parsed query. If ip is non-nil the
// answer carries an A record with that IP; otherwise the response carries
// no answer records and rcode governs (0 = NOERROR/empty, 3 = NXDOMAIN).
// Echoes id, name and qtype; sets QR and RD/RA bits.
func BuildReply(id uint16, name string, qtype uint16, ip net.IP, rcode int) []byte {
	panic("phase2: not implemented")
}
