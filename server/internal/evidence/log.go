// SPDX-License-Identifier: AGPL-3.0-or-later

// Package evidence is the lab's primary DNS/HTTP evidence stream: every
// query and request leaves one JSONL line.
package evidence

import (
	"encoding/json"
	"io"
	"sync"
	"time"
)

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
	w  io.Writer
	mu sync.Mutex
}

// NewLogger wraps a writer.
func NewLogger(w io.Writer) *Logger {
	return &Logger{w: w}
}

// Event emits one event with a fresh timestamp. Safe for concurrent use.
func (l *Logger) Event(proto, src, typ, name, detail string) {
	b, err := json.Marshal(Event{
		TS:     time.Now().UTC().Format(time.RFC3339Nano),
		Proto:  proto,
		Src:    src,
		Type:   typ,
		Name:   name,
		Detail: detail,
	})
	if err != nil {
		return // Event is plain strings; marshaling cannot fail in practice
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.w.Write(append(b, '\n'))
}
