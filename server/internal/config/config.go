// SPDX-License-Identifier: AGPL-3.0-or-later
package config

import (
	"flag"
	"fmt"
)

// Config carries every folval-gw runtime setting.
type Config struct {
	DNSAddr   string // UDP and TCP DNS listen address, e.g. "192.168.100.1:1053"
	HTTPAddr  string // HTTP echo/logger listen address, e.g. "192.168.100.1:8080"
	Sinkhole  string // A-record answer for every name without an override
	Overrides string // hosts-style override file path ("" disables)
	Out       string // JSONL event log path ("" = stderr)
}

// ParseFlags maps CLI flags into a Config.
func ParseFlags() Config {
	cfg := Config{}
	flag.StringVar(&cfg.DNSAddr, "dns", "192.168.100.1:1053", "DNS listen address (UDP+TCP); guest reaches it via nftables DNAT 53->1053")
	flag.StringVar(&cfg.HTTPAddr, "http", "192.168.100.1:8080", "HTTP listen address; guest reaches it via nftables DNAT 80->8080")
	flag.StringVar(&cfg.Sinkhole, "sinkhole", "192.168.100.1", "A-record answer for names without an override")
	flag.StringVar(&cfg.Overrides, "overrides", "", "hosts-style override file (IP name per line)")
	flag.StringVar(&cfg.Out, "out", "", "JSONL event log path (default stderr)")
	flag.Parse()

	if cfg.Sinkhole == "" {
		fatal("sinkhole IP must not be empty")
	}
	return cfg
}

func fatal(msg string) {
	fmt.Fprintln(flag.CommandLine.Output(), "folval-gw:", msg)
	flag.Usage()
	panic("invalid flags") // reached only from main goroutine before serving
}
