// SPDX-License-Identifier: AGPL-3.0-or-later
package dnswire

import (
	"fmt"
	"net"
	"strings"
)

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
	name = strings.TrimSuffix(name, ".")
	if name == "" {
		return []byte{0}
	}
	out := make([]byte, 0, len(name)+2)
	for _, label := range strings.Split(name, ".") {
		if len(label) == 0 || len(label) > 63 {
			continue // skip empty/oversized labels rather than emit garbage
		}
		out = append(out, byte(len(label)))
		out = append(out, label...)
	}
	return append(out, 0)
}

// ParseQuery decodes a DNS query message: returns the transaction id,
// the single question name (lowercased, dot-terminated, e.g. "example.com."),
// the qtype, and whether the message is a well-formed 1-question QUERY we
// are willing to answer.
func ParseQuery(msg []byte) (id uint16, name string, qtype uint16, ok bool) {
	if len(msg) < HeaderLen {
		return 0, "", 0, false
	}
	id = uint16(msg[0])<<8 | uint16(msg[1])
	flags := uint16(msg[2])<<8 | uint16(msg[3])
	qdcount := uint16(msg[4])<<8 | uint16(msg[5])
	opcode := (flags >> 11) & 0xF
	if flags&0x8000 != 0 || opcode != 0 || qdcount != 1 {
		return id, "", 0, false
	}
	// Question section: labels then root, then qtype(2) + qclass(2).
	i := HeaderLen
	var sb strings.Builder
	for {
		if i >= len(msg) {
			return id, "", 0, false
		}
		l := int(msg[i])
		if l == 0 {
			i++
			break
		}
		if l > 63 || i+1+l > len(msg) { // no compression pointers in questions
			return id, "", 0, false
		}
		if sb.Len() > 0 {
			sb.WriteByte('.')
		}
		sb.Write(msg[i+1 : i+1+l])
		i += 1 + l
	}
	if i+4 > len(msg) {
		return id, "", 0, false
	}
	qtype = uint16(msg[i])<<8 | uint16(msg[i+1])
	name = strings.ToLower(sb.String()) + "."
	if len(name) > MaxNameLen {
		return id, "", 0, false
	}
	return id, name, qtype, true
}

// BuildReply constructs a response to a parsed query. If ip is non-nil the
// answer carries an A record with that IP; otherwise the response carries
// no answer records and rcode governs (0 = NOERROR/empty, 3 = NXDOMAIN).
// Echoes id, name and qtype; sets QR and RD/RA bits.
func BuildReply(id uint16, name string, qtype uint16, ip net.IP, rcode int) []byte {
	// Header: id, QR|RD|RA (+ opcode 0) | rcode, qd=1, an=ip!=nil, ns=0, ar=0.
	ancount := uint16(0)
	if ip != nil {
		ancount = 1
	}
	out := []byte{
		byte(id >> 8), byte(id),
		0x81, 0x80 | byte(rcode&0xF),
		0x00, 0x01,
		byte(ancount >> 8), byte(ancount),
		0x00, 0x00,
		0x00, 0x00,
	}
	// Question echo.
	qname := EncodeName(name)
	out = append(out, qname...)
	out = append(out, byte(qtype>>8), byte(qtype), 0x00, 0x01)
	// Answer (A record, no compression, TTL 60).
	if ip != nil {
		v4 := ip.To4()
		if v4 == nil {
			panic(fmt.Sprintf("dnswire: BuildReply got non-IPv4 answer %s", ip))
		}
		out = append(out, qname...)
		out = append(out,
			0x00, 0x01, // type A
			0x00, 0x01, // class IN
			0x00, 0x00, 0x00, 0x3C, // TTL 60
			0x00, 0x04, // RDLENGTH
			v4[0], v4[1], v4[2], v4[3],
		)
	}
	return out
}
