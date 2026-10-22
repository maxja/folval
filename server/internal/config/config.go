// SPDX-License-Identifier: AGPL-3.0-or-later
package config

import (
	"flag"
	"fmt"
)

// Config carries every folval-gw runtime setting.
type Config struct {
	DNSAddr           string // UDP and TCP DNS listen address, e.g. "192.168.100.1:1053"
	HTTPAddr          string // HTTP echo/logger listen address, e.g. "192.168.100.1:8080"
	TCPProbe          string // capture-only TCP listener for first-bytes evidence ("" disables)
	TLSProbe          string // capture-only TLS listener for ClientHello/SNI evidence ("" disables)
	Forward           string // "LISTEN->TARGET" TCP relay for the oracle run ("" disables)
	GameserverAddr    string // TLS Gameserver endpoint reimplementing the observed .hqs routes ("" disables)
	GameserverCert    string // PEM (cert+key) for the Gameserver endpoint; stable identity keeps guest trust + pcap decryptability
	GameserverAccount string // account-state JSON file served by GetAccountInformation (gitignored; captured from the oracle run)
	Sinkhole          string // A-record answer for every name without an override
	Overrides         string // hosts-style override file path ("" disables)
	Out               string // JSONL event log path ("" = stderr)
	PushDir           string // directory served under /push/ ("" disables the route)
}

// ParseFlags maps CLI flags into a Config.
func ParseFlags() Config {
	cfg := Config{}
	flag.StringVar(&cfg.DNSAddr, "dns", "192.168.100.1:1053", "DNS listen address (UDP+TCP); guest reaches it via nftables DNAT 53->1053")
	flag.StringVar(&cfg.HTTPAddr, "http", "192.168.100.1:8080", "HTTP listen address; guest reaches it via nftables DNAT 80->8080")
	flag.StringVar(&cfg.TCPProbe, "tcprobe", "192.168.100.1:11234", "capture-only TCP listener: logs client first bytes, never responds (title analytics port; empty string disables)")
	flag.StringVar(&cfg.TLSProbe, "tlsprobe", "192.168.100.1:8443", "capture-only TLS listener: logs the ClientHello (SNI) the guest's TLS clients send, never responds; guest-side :443 arrives here via nftables DNAT (empty string disables)")
	flag.StringVar(&cfg.Forward, "forward", "", "TCP relay for the oracle run, LISTEN->TARGET (e.g. 192.168.100.1:8443->192.168.100.10:8443); when LISTEN matches -tlsprobe the probe is replaced (one listener, two modes)")
	flag.StringVar(&cfg.GameserverAddr, "gameserver", "", "TLS Gameserver endpoint, e.g. 192.168.100.1:8443 — serves the routes observed in the D9 decrypt (SendCommands, GetAccountInformation); replaces -tlsprobe/-forward when the address overlaps (empty string disables)")
	flag.StringVar(&cfg.GameserverCert, "gameserver-cert", "", "PEM file (cert then key) for the gameserver endpoint; reuse the oracle's stable cert so guest trust and keylog decryption carry over (empty = ephemeral self-signed CN=Gameserver)")
	flag.StringVar(&cfg.GameserverAccount, "gameserver-account", "", "JSON file served verbatim by GET /AccountInformationService.hqs/GetAccountInformation (captured account state from the oracle run; gitignored)")
	flag.StringVar(&cfg.Sinkhole, "sinkhole", "192.168.100.1", "A-record answer for names without an override")
	flag.StringVar(&cfg.Overrides, "overrides", "", "hosts-style override file (IP name per line)")
	flag.StringVar(&cfg.Out, "out", "", "JSONL event log path (default stderr)")
	flag.StringVar(&cfg.PushDir, "pushdir", "", "directory served under /push/ for guest file staging (default disabled)")
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
