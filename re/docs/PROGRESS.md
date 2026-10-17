# Progress — folly-n-valor

**Current Phase:** Phase 4 (Frida Injection & Instrumentation)
**Current Step:** Phase 4b on hold pending decision D7

## Phase 4a — COMPLETE (2026-10-17, gate verified live)

- `frida-ps -H 192.168.100.10` enumerates guest processes across the isolated boundary.
- Notepad attach gate: `arch: x64`, `platform: windows`, module enumeration, clean detach.
- `FridaServer` ONSTART SYSTEM scheduled task is reboot-durable: guest rebooted → task auto-started a fresh frida-server, port 27042 re-listening, host re-attached.
- Re-verified 2026-10-17 (late): task Running, `0.0.0.0:27042 LISTENING`, clean guest process census (no game, no stray session-0 probe processes).
- qemu-ga channel healthy (guest-ping + guest-exec answer).

## Active Decisions

- **D3 Wire Profile (pinned):** TCP 443 (TLS — launcher endpoint) + TCP 11234 (publisher analytics) to the sinkhole 192.168.100.1; game-server discovery hostname is DNS-only (connection gated on the launcher flow). Zero non-OS UDP.
- **Frida policy:** non-interactive use only via `host/tools/frida-run.sh` (REPL-free Python-API runner: attach/spawn, bounded wait, clean detach, spawned probes killed on exit). Ad-hoc CLI one-shots must redirect stdin (`</dev/null`) — the CLI always enters its REPL; `-q` only hides the banner. `--spawn` runs in session 0 → probes only; the game is desktop-launched (`host/tools/guest-start.sh`) and attached to by pid/name.
- **Client TLS stack (reference intel, unconfirmed on guest):** game TLS = libCURL statically linked in the exe with the CA compiled in (no OpenSSL DLL exports — hook inside the main module); webview TLS in libcef. A hermetic mock backend needs a certificate story regardless (self-signed termination + cert-shim DLL at launch per the reference).

## Open Decisions

- **D7 — Phase 4b strategy (blocks all 4b work):** Option A (adapt the third-party reference server: host-side instance, gateway DNS override for the game-server hostname, hermetic cert story) vs Option B (pure Frida RE: consolidate `re/frida/phase4b/` via the ideation gate, attach to the desktop-launched game, hook 443/11234). Prerequisite either way: confirm the guest's installed client build (reference validated against build 280139).
- Secondary: capture the client's first pre-TLS bytes on 11234 via a gateway listener (no TLS expected there?) vs Frida hook.

## Completed Milestones

- Phase 0 COMPLETE (2026-10-10)
- Phase 1 COMPLETE (2026-10-12)
- Phase 2 COMPLETE (2026-10-14)
- Phase 3 COMPLETE (2026-10-15)
- Phase 4a COMPLETE (2026-10-17)
