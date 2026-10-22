// SPDX-License-Identifier: AGPL-3.0-or-later

// Phase 5 (D9 decrypt → reimplementation): the folval-gw Gameserver endpoint.
// The game's backend protocol — captured and decrypted from the oracle run
// (2026-10-21/22) — is plain HTTP/1.1 + JSON over TLS with ".hqs" service
// routes. This file reimplements the two routes the live game was observed
// exercising (two full runs: telemetry SendCommands + account fetch, then
// quest assignment + account refetch):
//
//	POST /ServerCommandService.hqs/SendCommands     -> 200 {}
//	GET  /AccountInformationService.hqs/GetAccountInformation -> 200 <account JSON>
//
// Fidelity notes from the decrypted conversations (tmp/decrypted/, gitignored):
//   - responses carry Content-Type: application/json and Connection: Close
//     (Connection: Close mirrors the reference server, which closes after
//     every reply; the game opens a fresh TLS connection per request);
//   - the SendCommands reply is exactly "{}" (2 bytes, Content-Length: 2);
//   - the account JSON is served verbatim from -gameserver-account so the
//     captured 7243-byte state can be replayed byte-exactly;
//   - unknown routes: the reference server never replies (connection just
//     closes); we answer 404 + an evidence line instead — visible in logs
//     and harmless to the client, which retries the same way either way.
package gateway

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/maxja/folval/server/internal/evidence"
)

// Gameserver route paths as captured on the wire (Host: Gameserver).
const (
	routeSendCommands = "/ServerCommandService.hqs/SendCommands"
	routeAccountInfo  = "/AccountInformationService.hqs/GetAccountInformation"
)

// gameserverAccountFallback is served by GetAccountInformation when no
// -gameserver-account file is configured: a minimal but well-formed account
// state (field names from the captured contract) so the endpoint is runnable
// before the captured JSON is staged.
const gameserverAccountFallback = `{"Result":{"AccountId":1,"CountryCode":"SE","Privileges":9,"Wallet":{"InGameCoin":1000},"ClientSettings":{}}}`

// GameserverHandler returns the .hqs route handler. Every hit is logged as
// evidence ("gameserver.request") so oracle-parity comparisons against the
// reference server's RE log are direct.
func GameserverHandler(lg *evidence.Logger, accountJSON []byte) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := r.Host + r.URL.Path
		switch r.URL.Path {
		case routeSendCommands:
			if r.Method != http.MethodPost {
				lg.Event("gameserver", r.RemoteAddr, "gameserver.request", name, r.Method+" (expected POST)")
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			lg.Event("gameserver", r.RemoteAddr, "gameserver.request", name,
				fmt.Sprintf("%s bytes=%d", r.Method, r.ContentLength))
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Connection", "close")
			fmt.Fprint(w, "{}")
		case routeAccountInfo:
			if r.Method != http.MethodGet {
				lg.Event("gameserver", r.RemoteAddr, "gameserver.request", name, r.Method+" (expected GET)")
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			lg.Event("gameserver", r.RemoteAddr, "gameserver.request", name, r.Method)
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Connection", "close")
			w.Write(accountJSON)
		default:
			// Reference behaviour would be silence + close; we make the miss
			// visible instead (404 + evidence) — same client-side retry, far
			// easier to spot route gaps during the staircase.
			lg.Event("gameserver", r.RemoteAddr, "gameserver.nohandler", name, r.Method)
			http.Error(w, "no handler", http.StatusNotFound)
		}
	})
}

// gameserverLoop serves the Gameserver routes over TLS on ln. The cert is
// loaded from certPath when readable (stable identity: one Root-store /
// certpatch arrangement, forever-decryptable pcaps); otherwise an ephemeral
// self-signed CN=Gameserver cert is generated — enough for wire-shape runs,
// not for trusted ones.
func gameserverLoop(ln net.Listener, certPath, accountPath string, lg *evidence.Logger) error {
	cert, err := loadOrCreateCert(certPath)
	if err != nil {
		return fmt.Errorf("gateway: gameserver cert: %w", err)
	}
	accountJSON := []byte(gameserverAccountFallback)
	if accountPath != "" {
		b, err := os.ReadFile(accountPath)
		if err != nil {
			return fmt.Errorf("gateway: gameserver account file: %w", err)
		}
		accountJSON = b
	}
	srv := &http.Server{
		Handler:           GameserverHandler(lg, accountJSON),
		ReadHeaderTimeout: 10 * time.Second,
	}
	return srv.Serve(tls.NewListener(ln, &tls.Config{
		Certificates: []tls.Certificate{*cert},
		// The observed client negotiates TLS1.2 ECDHE; keep the default
		// modern set — it also serves TLS1.3 probes without config drift.
		MinVersion: tls.VersionTLS12,
	}))
}

// loadOrCreateCert returns the TLS certificate for the Gameserver endpoint:
// the PEM at path when present (cert THEN key in one file, re-server-key.pem
// layout), else a freshly generated self-signed CN=Gameserver certificate.
func loadOrCreateCert(path string) (*tls.Certificate, error) {
	if path != "" {
		if cert, err := tls.LoadX509KeyPair(path, path); err == nil {
			return &cert, nil
		} else if !os.IsNotExist(err) {
			// Readable-but-broken beats silent regeneration: a surprise cert
			// identity would silently break guest trust AND pcap decryption.
			return nil, fmt.Errorf("load %q: %w", path, err)
		}
	}
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	tmpl := x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{Country: []string{"SE"}, Organization: []string{"folval"}, CommonName: "Gameserver"},
		NotBefore:             time.Now().Add(-7 * 24 * time.Hour), // tolerate clock skew
		NotAfter:              time.Now().Add(3650 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	return &tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}, nil
}
