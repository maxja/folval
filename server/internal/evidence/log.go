// SPDX-License-Identifier: AGPL-3.0-or-later

// Package evidence is the lab's primary DNS/HTTP evidence stream: every
// query and request leaves one JSONL line.
package evidence

import "io"

// Event is one JSONL log line.
type Event struct {
	TS     string `json:"ts"`               // RFC3339
	Proto  string `json:"proto"`            // "dns" | "http" | "meta"
	Src    string `json:"src"`              // client ip:port
	Type   string `json:"type"`             // "dns.query" | "dns.drop" | "http.request" | ...
	Name   string `json:"name,omitempty"`   // queried name / HTTP Host+path
	Detail string `json:"detail,omitempty"` // free-form: answer given, error, method
}

// Logger serializes Events to a single writer (JSONL file or stderr).
type Logger struct {
	w io.Writer
}

// NewLogger wraps a writer.
func NewLogger(w io.Writer) *Logger {
	panic("phase2: not implemented")
}

// Event emits one event with a fresh timestamp.
func (l *Logger) Event(proto, src, typ, name, detail string) {
	panic("phase2: not implemented")
}
