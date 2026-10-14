// SPDX-License-Identifier: AGPL-3.0-or-later
package overrides

import (
	"fmt"
	"net"
	"os"
	"strings"
)

// Load parses hosts-style CONTENTS ("1.2.3.4  api.example.com",
// "#" comments, blank lines ignored) into lowercase dot-terminated names
// ("api.example.com.") mapped to IPs. Malformed lines are an error; empty
// src yields an empty map, no error.
func Load(src string) (map[string]net.IP, error) {
	m := make(map[string]net.IP)
	for ln, line := range strings.Split(src, "\n") {
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if len(fields) < 2 {
			return nil, fmt.Errorf("overrides: line %d: want \"IP name\", got %q", ln+1, line)
		}
		ip := net.ParseIP(fields[0])
		if ip == nil || ip.To4() == nil {
			return nil, fmt.Errorf("overrides: line %d: invalid IPv4 address %q", ln+1, fields[0])
		}
		name := strings.ToLower(fields[1])
		if !strings.HasSuffix(name, ".") {
			name += "."
		}
		m[name] = ip
	}
	return m, nil
}

// LoadFromFile reads a path and delegates to Load.
func LoadFromFile(path string) (map[string]net.IP, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("overrides: %w", err)
	}
	return Load(string(b))
}
