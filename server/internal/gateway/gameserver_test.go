// SPDX-License-Identifier: AGPL-3.0-or-later
package gateway

import (
	"bytes"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/maxja/folval/server/internal/evidence"
)

// Captured wire shapes (D9 decrypt, 2026-10-21): the SendCommands reply is
// exactly "{}"; GetAccountInformation returns the account JSON verbatim.
func TestGameserverSendCommands(t *testing.T) {
	lg := evidence.NewLogger(io.Discard)
	h := GameserverHandler(lg, []byte(`{"Result":{"AccountId":1}}`))

	req := httptest.NewRequest(http.MethodPost, routeSendCommands, strings.NewReader(`{"commands":[]}`))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("SendCommands status = %d, want 200", rec.Code)
	}
	if body := rec.Body.String(); body != "{}" {
		t.Fatalf("SendCommands body = %q, want {}", body)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}
	if c := rec.Header().Get("Connection"); c != "close" {
		t.Fatalf("Connection = %q, want close (reference server closes per reply)", c)
	}
}

func TestGameserverAccountInfo(t *testing.T) {
	account := `{"Result":{"AccountId":3123971,"Wallet":{"InGameCoin":1000}}}`
	lg := evidence.NewLogger(io.Discard)
	h := GameserverHandler(lg, []byte(account))

	req := httptest.NewRequest(http.MethodGet, routeAccountInfo, nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GetAccountInformation status = %d, want 200", rec.Code)
	}
	if rec.Body.String() != account {
		t.Fatalf("account body not served verbatim: %q", rec.Body.String())
	}
}

func TestGameserverFallbackAccount(t *testing.T) {
	lg := evidence.NewLogger(io.Discard)
	h := GameserverHandler(lg, []byte(gameserverAccountFallback))
	req := httptest.NewRequest(http.MethodGet, routeAccountInfo, nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.HasPrefix(rec.Body.String(), `{"Result":`) {
		t.Fatalf("fallback account not served: %d %q", rec.Code, rec.Body.String())
	}
}

func TestGameserverUnknownRouteAndMethods(t *testing.T) {
	lg := evidence.NewLogger(io.Discard)
	h := GameserverHandler(lg, nil)

	req := httptest.NewRequest(http.MethodGet, "/SomeService.hqs/Unknown", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unknown route status = %d, want 404 (visible miss)", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, routeSendCommands, nil)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET SendCommands status = %d, want 405", rec.Code)
	}
}

// TestGameserverLoopTLS exercises the full TLS serving path with the
// ephemeral self-signed cert (loadOrCreateCert path "" — the lab passes the
// stable PEM instead): handshake, route dispatch, Connection semantics.
func TestGameserverLoopTLS(t *testing.T) {
	lg := evidence.NewLogger(io.Discard)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go gameserverLoop(ln, "", "", "", lg)

	client := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, // self-signed test cert
		},
		Timeout: 5 * time.Second,
	}

	resp, err := client.Get("https://" + ln.Addr().String() + routeAccountInfo)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || !bytes.HasPrefix(body, []byte(`{"Result":`)) {
		t.Fatalf("TLS account fetch: %d %q", resp.StatusCode, body)
	}
}
