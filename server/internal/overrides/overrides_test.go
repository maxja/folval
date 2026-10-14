// SPDX-License-Identifier: AGPL-3.0-or-later
package overrides

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadBasic(t *testing.T) {
	src := `
# comment line
1.2.3.4  api.example.com
5.6.7.8   mixed.Case.Test   # trailing comment
`
	m, err := Load(src)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(m) != 2 {
		t.Fatalf("len = %d, want 2 (%v)", len(m), m)
	}
	if !m["api.example.com."].Equal(net.ParseIP("1.2.3.4")) {
		t.Errorf("api.example.com. = %v", m["api.example.com."])
	}
	if !m["mixed.case.test."].Equal(net.ParseIP("5.6.7.8")) {
		t.Errorf("mixed case key not normalized: %v", m)
	}
}

func TestLoadEmpty(t *testing.T) {
	m, err := Load("")
	if err != nil {
		t.Fatalf("empty src should be ok: %v", err)
	}
	if len(m) != 0 {
		t.Errorf("want empty map, got %v", m)
	}
}

func TestLoadFromFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hosts")
	if err := os.WriteFile(path, []byte("10.0.0.1  x.test\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := LoadFromFile(path)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !m["x.test."].Equal(net.ParseIP("10.0.0.1")) {
		t.Errorf("x.test. = %v", m["x.test."])
	}
}

func TestLoadBadLine(t *testing.T) {
	if _, err := Load("not an ip  host.test"); err == nil {
		t.Error("expected error for unparsable IP")
	}
}
