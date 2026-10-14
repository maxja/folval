// SPDX-License-Identifier: AGPL-3.0-or-later

// Package config holds folval-gw runtime settings (flags only; no config
// file in Phase 2).
package config

// Config carries every folval-gw runtime setting.
type Config struct {
	DNSAddr   string // UDP and TCP DNS listen address, e.g. "192.168.100.1:1053"
	HTTPAddr  string // HTTP echo/logger listen address, e.g. "192.168.100.1:8080"
	Sinkhole  string // A-record answer for every name without an override
	Overrides string // hosts-style override file path ("" disables)
	Out       string // JSONL event log path ("" = stderr)
}

// ParseFlags maps CLI flags into a Config. Interfaces only (Phase 2, step 2).
func ParseFlags() Config {
	panic("phase2: not implemented")
}
