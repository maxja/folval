# vm/ — guest-side PowerShell tools

Versioned source of truth for scripts that run **inside the Windows guest**
(hermetic bench at 192.168.100.10). Transport is the gateway's `/push/`
staging dir; runtime location is `C:\re\` (scratch) or `C:\re\server\` (the
reference oracle stack).

## Flow

    host:  bash host/tools/guest-push.sh vm/<script>.ps1 [<name>]
    host:  bash host/tools/guest-run.sh -c "powershell -NoProfile -ExecutionPolicy Bypass -File C:\re\<name>"

## Inventory

Oracle stack (D9 reference server, cross-built from the Lost Worlds source):

- `oracle-stage.ps1` — first-time bring-up: download `mqelserver.exe` +
  OpenSSL DLLs from `/push/`, start on :8443 with `SSLKEYLOGFILE`.
- `oracle-restart.ps1` — clean restart with a fresh keylog; **keeps**
  `re-server-key.pem` so the self-signed cert identity is stable across
  restarts (guest Root store trusts it once; pcaps stay decryptable).
  Ends with a local schannel handshake smoke test.
- `oracle-firewall.ps1` — guest-side inbound rule `folval-oracle-8443` +
  mqelserver health check.
- `oracle-trust.ps1` — idempotent import of the server cert into
  `Cert:\LocalMachine\Root` (covers schannel/CEF clients; the engine's
  static OpenSSL is covered by certpatch instead).

Probes (quick diagnostics, print a one-line verdict):

- `probe-connect.ps1` — TCP reachability of the gateway 443-DNAT vs direct
  8443 path (firewall regression check).
- `probe-tls.ps1` — TLS smoke against the server directly vs via the
  gateway forward relay.
- `probe-wer.ps1` — last WER crash events for mqelserver.

Base image provisioning (Packer/Vagrant):

- `debloat.ps1`, `setup_frida.ps1` — first-boot guest setup.

## Conventions

- `tmp/` stays gitignored scratch (one-off payloads, screenshots, keylog
  copies). Anything reused across sessions belongs here in `vm/`.
- New probes: name `probe-<thing>.ps1`, exit nonzero on hard failure.
