// SPDX-License-Identifier: AGPL-3.0-or-later

// Package overrides maps specific names to pinned IPs, hosts-style.
package overrides

import "net"

// Load parses hosts-style CONTENTS ("1.2.3.4  api.example.com",
// "#" comments, blank lines ignored) into lowercase dot-terminated names
// ("api.example.com.") mapped to IPs. Malformed lines are an error; empty
// src yields an empty map, no error.
func Load(src string) (map[string]net.IP, error) {
	panic("phase2: not implemented")
}

// LoadFromFile reads a path and delegates to Load.
func LoadFromFile(path string) (map[string]net.IP, error) {
	panic("phase2: not implemented")
}
