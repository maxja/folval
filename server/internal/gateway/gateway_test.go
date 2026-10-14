// SPDX-License-Identifier: AGPL-3.0-or-later
package gateway

import (
	"net"
	"testing"
)

func TestAnswerIPOverrideWins(t *testing.T) {
	ov := map[string]net.IP{"pinned.test.": net.ParseIP("10.0.0.9")}
	if got := AnswerIP("pinned.test.", net.ParseIP("192.168.100.1"), ov); !got.Equal(net.ParseIP("10.0.0.9")) {
		t.Errorf("override not honored: %v", got)
	}
	if got := AnswerIP("other.test.", net.ParseIP("192.168.100.1"), ov); !got.Equal(net.ParseIP("192.168.100.1")) {
		t.Errorf("sinkhole not applied: %v", got)
	}
}

func TestUDPDNSRoundTrip(t *testing.T) {
	t.Skip("red until implementation: dnsUDPLoop")
}
