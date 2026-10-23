# History — session records & completed-phase detail

Extracted from PROGRESS.md on 2026-10-23 (rarely read; the active file keeps current phase, decisions, and the ledger). Chronological, oldest first.

---

## Phase 4a — COMPLETE (2026-10-17, gate verified live)

- `frida-ps -H 192.168.100.10` enumerates guest processes across the isolated boundary.
- Notepad attach gate: `arch: x64`, `platform: windows`, module enumeration, clean detach.
- `FridaServer` ONSTART SYSTEM scheduled task is reboot-durable: guest rebooted → task auto-started a fresh frida-server, port 27042 re-listening, host re-attached.
- Re-verified 2026-10-17 (late): task Running, `0.0.0.0:27042 LISTENING`, clean guest process census (no game, no stray session-0 probe processes).
- qemu-ga channel healthy (guest-ping + guest-exec answer).

## Phase 4b — interfaces landed (2026-10-18, pending approval)

- **Probe family** (`re/frida/phase4b/`): `recon.js` (passive census: modules/exports + DNS + connect-map + send-family buffers, hex+ascii heads, event cap) and `tls_plain.js` (path A: launcher OpenSSL DLL exports hooked; path B: read-only marker scan of the unpacked game exe — hook targets pinned post-recon). Seven one-off probes deleted; `tests/test_phase4b.js` rewritten as an env self-check (10/10 PASS on a session-0 notepad spawn).
- **Evidence tee:** `frida-run.sh` appends every send()/log/error as JSONL to `out/<ts>-<target>-<probe>.jsonl`; `out/` gitignored except `.gitkeep` (contents may embed title identity).
- **Gateway `-tcprobe`** (default `192.168.100.1:11234`, `""` disables): capture-only TCP listener — logs client first bytes (hex head 256 B, 4 KB cap/conn, 30 s idle), NEVER responds; live-verified host-side (smoke payload round-tripped into `logs/gateway.jsonl`). Go vet+tests green (16).
- **Firewall:** `host/firewall/folval.nft` gains `tcp dport 11234 accept` — **user must re-apply** (`sudo ./host/firewall/apply.sh` + reinstall to `/etc/folval`) before the guest can reach the listener.
- **Frida 17 API notes:** static `Module.findExportByName` gone (instance methods required); `Process.enumerateModules()[0]` is not the main exe (`Process.mainModule`). All probes fixed accordingly.

## Phase 4b — session-1 injection + game launch (2026-10-18, session of record)

**The session-0 wall, diagnosed:** the SYSTEM frida-server (port 27042, Phase 4a) sees session-1 processes via `frida-ps` but `session.create()` → **"not permitted to attach"** — Windows refuses cross-session (and integrity-level) attach from a session-0 broker; frida's own docs confirm session-0 ≠ desktop attach. Session 0 has NO interactive desktop (not even a console), so a console-allocated SYSTEM server can never serve the desktop.

**The solution (verified working):** a SECOND frida-server running **as the guest user inside interactive session 1**, port **27043**. Launched by the same HKCU-Run dispatcher chain the game uses (auto-logon session 1 → `ui-dispatch.cmd` → `cmd /C start frida-server.exe --listen 0.0.0.0:27043`). `FOLVAL_FRIDA_PORT=27043` switches `frida-run.sh` to it. All game/UI instrumentation goes through :27043 from now on; :27042 remains the headless census channel.

**Game launch plumbing (works):** `host/tools/ui-start.sh '<target>'` re-stages the `HKCU…\Run\ui-dispatch` cmd (game = the Steam install's `…\GameData\Bin\<gameexe>`; launcher = `steam.exe` — full path in gitignored handoff) and **cycles session 1** (logoff→auto-logon→dispatcher). Caveat learned: `New-ScheduledTaskAction` from SYSTEM fails `0x800710E0`; the HKCU-Run approach is the reliable cross-session mechanism. Steam then shows its desktop login (the lab account pre-selected).

**Game launch args (from Steam's own registry Run entry):** `-server_url https://<gshost> -environmentName <env>-live -branchName <branch> -steamid <steamid> -steamticket  -token ` (identities redacted; full form in gitignored handoff + `out/`). The launcher flow normally fills `steamticket`/`token`; direct launch leaves them empty.

**GPU wall + DECISIVE EXPERIMENT (next session's entry point):** with the shim's D3D9 instrumentation the game reaches `CreateDevice` and gets `D3DERR_INVALIDCALL` (0x8876086C) → game's own fatal box "Couldn't create DirectX Device, try rebooting and or updating your drivers" (captured via MessageBox hook; a second variant seen on the screen reads "Can not found a DirectX device with minimum requirements"). `gpu_shim.js` **selftest** then proved: calling `Direct3DCreate9(32)` + `CreateDevice(HAL, 640x480, X8R8G8B8, count=1, windowed, flags=0x20)` and again with `NULLREF` **from inside the same injected process — BOTH S_OK**. So the d3d9 runtime, driver (Win10's built-in d3d9-over-DXGI on Basic Display), and video model are all healthy; **the game's specific parameters fail** (its call: behavior flags 0x52 incl. HW-vertex-processing/MULTITHREADED bits, 1280×720, BackBufferCount=2, and our Check* lies are NOT what it validates against — the d3d9 runtime validates against real driver caps). **Game's published minimum requirements (user-supplied 2026-10-18):** D3D9 **SM 3.0 pixel + vertex** is the hard graphics gate (GeForce 8600 GT / HD 4300 / Intel HD 3000 class); CPU (Pentium IV 3.0) + 2 GB RAM far below the guest's spec; OS range XP SP3–Win8 (guest is Win10 LTSC — out of range, low risk); sound card required — **the domain has no audio device** (latent post-device failure; fix = `<sound model='hda'/>` via virsh define — NOT `lv.sound_type`, which vagrant-libvirt 0.11.2 ignores). The in-box d3d9 on the QEMU-vga/Basic Display stack is presumed SM5.0-capable but UNVERIFIED — the selftest must log the device's `GetDeviceCaps` shader versions; if SM<3.0, that is the root cause of the min-requirements box and the escalation moves to virtio-gpu+VirGL (needs SPICE console) or GPU passthrough.

**Next (immediate):** bisect the game's own CreateDevice args in the hook (start: force flags to 0x20 + its own PP; then flip one field at a time) until S_OK — the shim already logs every field (`CreateDevice`/`CreateDevice.pp` events), so this is a small loop. **Next (post-device, per D9):** the reference-ORACLE run — the full capture architecture is in the D9 entry above; it replaces the old "walk the whole flow" fantasy (no real server exists, so enumeration and server-build are one interleaved capture→respond→verify staircase, seeded by the recorded oracle trace). Escalation rungs if no arg combo works: d3d9-to-D3D11 translation layer (DXTrans/wined3d11), then GPU passthrough (iGPU not visible to host, so likely a discrete card or vGPU — check `lspci` on host).

**New tooling (committed):**
- `lab.sh evidence:status|clean [--force]` + `capture:install` (2026-10-19): evidence hygiene — dry-run-by-default compaction of logs/, stale pcap rings, and out/ probe output; keepers curated via gitignored `out/.keep`, distilled knowledge in gitignored `out/EVIDENCE.md` (D3D9 bisect ledger). Capture unit now writes DATE-STAMPED ring bases (filename = coverage boundary; deploy via root `host/capture/install.sh`).
- `re/frida/phase4b/gpu_shim.js` — D3D9 instrumentation + cap softening (Check* → success, GetDeviceCaps → real caps with software VP, CreateDevice hook logging all args, PP normalization) + MessageBox/ExitProcess/TerminateProcess capture (the "why did it die" recorder) + the CreateDevice selftest.
- `re/frida/phase4b/window_enum.js` — desktop dialog reader: attach to ANY session-1 process (steam.exe works), polls `EnumWindows`+`EnumChildWindows`, emits each new visible window (title/class/pid; `#32770` dialogs include full body text). **This is how we now read Windows alert boxes without the screen** — verified capturing both GPU error variants.
- `host/tools/ui-start.sh` — stage any launch target + cycle session 1 (documented in header). `host/tools/ui-dispatch.cmd` (guest) runs `start "ui-dispatch" <target>`.
- `frida-run.sh`: evidence filenames now PID-suffixed (no more name collisions).
- `host/firewall/folval.nft`: added `tcp dport 11234 accept` (gateway analytics probe; user re-applied: firewall is live, probe listening, host smoke payload logged).

**Launcher analytics (captured pre-game):** via tcprobe 11234 + tls_plain on the launcher: HTTP/1.1 POST to `/log/` with a `k=v` querystring body whose fields decode to `u=<steamid>`, `g=<game build 280139>`, plus several opaque counters (`s/f/c/d/h/b/k/r`) — full sample in gitignored `out/`. TLS SNI = the analytics host (identity kept out of repo files). This is the *launcher's* analytics channel; the game's first network contact is still behind the D3D9 wall.

## Phase 4b — D3D9 WALL BROKEN + GAME BOOT (2026-10-19, SESSION RECORD)

**The wall had four layers, all resolved this session** (full ledger: `out/EVIDENCE.md` — gitignored):
1. **CreateDevice INVALIDCALL** → force behavior flags 0x52→0x20 (drop MULTITHREADED 0x10 + FPU_PRESERVE + HWVP; keep the game's own PP 1280×720/count=2) → **S_OK**. Isolation: 0x30 (SW-VP+MULTITHREADED) dead vs 0x20 S_OK → **MULTITHREADED alone kills CreateDevice** on this stack.
2. **RT E_OUTOFMEMORY** → the engine's `CreateTexture(1280×720, usage=DEPTHSTENCIL, fmt=INTZ)`; native CheckDeviceFormat(depthstencil-texture) = NOTAVAILABLE (the stack has no depth-texture support) → hook swaps INTZ→A8R8G8B8 (fmt 21) + usage→RENDERTARGET (cfg `deptex`).
3. **Texture INVALIDCALL + modal box** ("Failed to create texture 0x8876086c 32×32" — invisible "stall") → DXT1 works, ATI2/DXT5 don't → hook swaps non-DXT1 FOURCC formats to 21 (cfg `fmtswap`). 217+ textures then load, including DXT5 1920×1080 content.
4. **Reset INVALIDCALL** (fullscreen 1024×768, then windowed; PP sanitization did not help) → **the Steam overlay (gameoverlayrenderer.dll) holds pool-DEFAULT resources across Reset** → rename the overlay DLLs in the Steam root + restart Steam → **Reset S_OK**.

**Also required for direct launch:** `steam_appid.txt` = appid next to the game exe (SteamAPI_Init → 1; before that the engine silently parked in a 1Hz poll after Init → 0), plus `SteamAppId`/`SteamGameId` env vars + game-bin CWD (the reference's belt-and-braces).

**Result (user-verified on VNC):** Ubisoft intro plays, distorted-but-alive rendering (expected — compressed formats swapped), in-game cursor works, the game's UI exe (CEF, ×2 procs) spawned by the engine, and the UI shows **"Network Error!"** — the game reached its network layer. The UI is the REST client: `gethostbyname` on the game's server hostname in a retry loop ~every 15–20 s, hosts-pinned to 192.168.100.1.

**Capture plumbing added this session:** folval-gw gains a **`-tlsprobe`** capture-only listener (same pattern as `-tcprobe`: logs the ClientHello hex head — SNI — never responds; 512 B head) on **:8443**, with guest-side **443→8443 DNAT** added to `host/firewall/folval.nft` (unprivileged-port pattern extended; 443 bind = permission denied). **User sudo pending:** `sudo ./host/firewall/apply.sh` — when it lands, the UI's next retry connect reaches the probe and the ClientHello is captured. Then the D9 oracle run: reference server in-guest on :8443 + SSLKEYLOGFILE + hosts pin → full decrypted trace.

**Working launch recipe (runs 15/16):** `FOLVAL_FRIDA_PORT=27043 FOLVAL_SCRIPT_ENV='{"gpu":{"flags":32,"deptex":21,"fmtswap":21,"reset":{"windowed":1,"interval":0,"rate":0}}}' FOLVAL_SPAWN_ENV='SteamAppId=<appid>;SteamGameId=<appid>' FOLVAL_SPAWN_CWD='<gamebin>' FOLVAL_SPAWN_ARGS='<launcher argline>' frida-run.sh --spawn '<gameexe>' gpu_shim.js,steam_probe.js` (identities in gitignored files).

**dxdiag (pristine process):** healthy stack — Microsoft Basic Display Adapter, DDI 12, feature levels 12_1…9_3 (9_3 = SM3.0), 4095 MB shared. The garbage in-process D3DCAPS9 readback (canary-verified: the runtime did write it) is a d3d9-on-Basic-Display artifact, not the adapter's truth — on this stack, trust dxdiag, not in-process caps.


### D9 oracle — client TLS chase (2026-10-21, in flight)

The game's network-error loop was peeled layer by layer; each fix is verified
live before moving on:

- **Hosts pin mangled** — the two pin lines were concatenated into a single
  comment (`# folval hermetic backend pin192.168.100.1\tGameserver`), so the
  engine resolved nothing and showed NETWORK ERROR with zero dials. Rewrote
  the hosts entry (`attrib -r` first, literal TAB via `[char]9`), flushed DNS.
  Result: 27 relays in the next minute; engine handshakes observed.
- **Cert validity +7h skew** — `s_client` against our server showed
  `verify error:num=9: certificate is not yet valid` (notBefore 7h in the
  future: the WinRM-started server process computes X509 times from a
  session-clock with a UTC-7 offset baked in). Engine's OpenSSL rejected the
  cert on validity — invisible to trust-store imports and certpatch both.
  Fix: backdate `notBefore` 7 days, `notAfter` +10y in `ISSLServer.hpp`.
- **Stable server cert** — `CreateSSLCert` now loads `re-server-key.pem`
  (env `FOLVAL_SERVER_PEM`) when present instead of regenerating; identity
  survives restarts → Root store trusts it once, pcaps stay RSA-decryptable.
- **certpatch deployed** (from the Lost Worlds `src/certshim/`): the engine
  links libCURL+OpenSSL statically (no OpenSSL DLLs in GameData\Bin, no
  schannel), so Windows Root imports never applied to it. Injection patches
  the two verify functions in the decrypted `.text` (log-confirmed at
  0157D680/0157E0E0).
- **Analytics pin identified for free** — the engine's Bloomberg telemetry
  dials `hqbloomberg.ubisoft.org:11234`; hosts-pin it to the gateway and the
  existing `-tcprobe` listener (already on 11234!) captures its protocol
  first-bytes without any new code.
- **Remaining failure signature:** engine sends a 181B no-SNI TLS1.2
  ClientHello, gets our 1151B ServerHello+Cert, then silently closes (no
  Finished, no alert) → ErrorPanel. One clean patched retry is still pending
  (injection landed 23s after the engine's only dial; it went into backoff).
  Staged plan in the session handoff: (A) user clicks Retry on the dialog,
  (B) engine verbose-logging switches (DebugSettings.json), (C) plain-HTTP
  `-server_url` test bypassing TLS entirely, (D) frida trace of the abort,
  (E) proper CA chain. Tooling restructured meanwhile: durable guest-side
  scripts moved `tmp/*.ps1` → `vm/` (oracle-stage/restart/firewall/trust,
  probe-connect/tls/wer) + new `host/tools/guest-push.sh` (generic
  `/push/` transport, fixes the overlayblock naming bug);
  `ui-start.sh` dispatcher now runs only `overlaycorrupt.ps1`.
- **UI artefact debt:** the D3D shim renders the login UI with visible
  artefacts (32-bit content duplicated over 64-bit screen, per user reports
  on tmp/screen1/2/4.png — local-only evidence). Readable UI is a prerequisite
  for the manual login click in Stage A.

- Phase 0 COMPLETE (2026-10-10)
- Phase 1 COMPLETE (2026-10-12)
- Phase 2 COMPLETE (2026-10-14)

### D9 — FIRST CLIENT↔SERVER CONVERSATION (2026-10-21 evening, session #3)

**Milestone: the game completed real TLS conversations with the reference
server** — relay closes `client→656B / server→8691B` and `1019/1447B`
(8.7KB = session/config-sized response), followed by a visible in-game pass
through login→intro before returning to the error screen. Full bytes are in
the pcap ring + `sslkeys.log` for offline decryption (pipeline proven D9/1).

How the wall fell — every wrong assumption corrected en route:

- **The "engine TLS abort" was a misattribution.** The 181B no-SNI hellos
  were decoded: SNI `ecs.office.com` / `wdcp.microsoft.com` — Office/Windows
  telemetry rejecting our self-signed cert. The GAME had never dialed at
  all (zero game DNS, zero engine TCP). The day's cert-validity fix
  (7d-backdated notBefore for the +7h WinRM session-clock skew) and stable
  PEM cert remain correct and necessary — they were just never the blocker.
- **Engine requires https** — `http://` `-server_url` → clean exit at +35s
  (mqelserver gained a PLAIN mode anyway: argv `plain`/env FOLVAL_PLAIN,
  same RE rx hex logging, useful for future protocol replay).
- **UI artefacts root-caused & fixed WITHOUT wrappers.** The old fmtswap
  blanket-swapped every FOURCC>200 to RGBA, so the game wrote DXT5-packed
  bytes into RGBA surfaces — corrupting 4743/7226 textures. Texture census:
  DXT5 ×4743, DXT1 ×1649, ATI2 ×343, A8R8G8B8 ×459. fmtswap is now
  format-aware (`{"843666497":21}` map form): ONLY ATI2 (3Dc) is swapped
  (the driver returns NOTAVAILABLE 0x8876086c, fatal to the engine); DXT5
  and DXT1 pass through natively (S_OK ×4880 verified). Visuals readable
  (user-confirmed); minor normal-map shading quirks remain (ATI2 content).
- **dgVoodoo2 dead end, documented**: v2.87.5 wrapper gave perfect visuals
  but the game dies at PACKAGE_HERO (E_OUTOFMEMORY on 1024² texture →
  "Application immediate shutdown"). Root: 32-bit process VA exhaustion —
  exe already has the LAA bit (chars 0x0122), RAM irrelevant (16GB guest
  failed identically; reverted to 8G). VRAM=256/4GB, FastVideoMemoryAccess
  — no effect. Wrapper DLL parked at `C:\re\dgv-D3D9.dll.disabled`.
- **The engine dials Gameserver:8443 directly** (SynSent seen live) — and
  guest→GW **direct :8443 was silently dropped again** after the day's VM
  reboots (nftables/libvirt ordering regression). The portless URL
  `https://Gameserver` (→ :443 → DNAT → forward) is the durable path — the
  old "portless fails to parse" verdict was from the mangled-hosts era.
- **The engine also needs a LOCAL webserver on :80** (lobbyPageUrl
  `http://localhost/gamedata/...`): its ConnectServer is an http.sys
  listener that ended bound-but-dead (orphaned request queues, PID-4
  socket). `vm/uiweb80.ps1` serves GameData on :80 as a replacement
  (zombie http.sys registrations block rebinding until guest reboot).
- **Pass-through sequence** (user-observed on VNC): boot → login pass →
  short intro → back to error screen → hang. Likely a follow-up backend
call failing (see handoff Open Questions).

## D9 — DECRYPT MILESTONE (2026-10-22 session record)

**Bench path back up:** host had been rebooted (VM shut off); `vm:up` recovered it cleanly — the "hung guest" from 2026-10-21 did not persist. WinRM round-trip OK.

**Pipeline, final form:** size-classify relayed streams (`tcp.port==8443 && tcp.len>0`, awk-sum per stream) → isolate each stream to its own pcap → decrypt the fragment with the CR-stripped keylog. Two traps closed this session: CRLF keylog = zero secrets loaded silently (+24B/record raw-ciphertext tell), and relayed streams don't decrypt in the full ring file. Keylog coverage: guest `C:\re\server\sslkeys.log` is append-forever (148 CLIENT_RANDOM at pull) — pull fresh BEFORE analysis; entries exist only for connections the server completed handshakes on (the pre-certpatch abort classes have ServerHello+Cert but no Finished → no secret needed, nothing to decrypt).

**The four milestone conversations** (two runs, 21:35:31 and 21:36:08 host; SNI=Gameserver, TLS1.2 ECDHE-RSA-AES128-GCM, 3-cipher ClientHello with SNI+heartbeat — NOT the 45-cipher SSLv3-era engine stack from the earlier notes):
1. `POST /ServerCommandService.hqs/SendCommands` — body `{"commands":[{$type TrackingCommand → GameStartTracking, GameClientVersion 280139, MachineId, TrackingTagId}]}` → `200 {}` (91B plaintext response).
2. `GET /AccountInformationService.hqs/GetAccountInformation` → 7243B JSON (full account state; includes chat-server config pointing at the title's web/chat host on :80 — a NEW host to pin/capture).
3. Second run adds `StartAssignment{AssignmentId:10}` + `CompleteAssignment{AssignmentId:10}` — the game ran the intro quest against our server, then re-fetched account info.

**Fallback cause (open):** server log silent after the second GetAccountInformation — the error screen was NOT a missing Gameserver route at that moment. Suspects with data: unpinned chat host (config was just delivered to the client), uiweb80 local routes. CLOSED 2026-10-22 (same session, later): the "unexplained" stream classes were attributed — 1765/1292 & 1639/1850 & 597/1977 TLS1.3 convs = HOST-originated probes (GW→guest:8443 SYNs, no guest inbound — manual curl/openssl checks from the evening session; server log confirms TLS1.3 TLS_AES_256_GCM handshakes); the 21:34 189/1276 burst = 182B no-SNI ClientHello + 7B alert right after our cert (cert-rejection aborts, no app data); streams 81/82 = guest's firewall-dropped direct GW:8443 dials (SYN retransmits). No hidden routes: the game's complete wire vocabulary is the two decrypted routes.

**Identity-leak fixes:** title name was committed in `vm/uiweb80.ps1` default path (now derived from the Steam library glob, `FOLVAL_GAMEDATA` overridable); engine namespace name redacted in misconceptions. Self-scan (`git grep -i` after `git add -A`) is now mandatory before EVERY commit per policy.


---

# DEVELOPMENT_PLAN historical records (extracted 2026-10-23)

## Original status line (2026-10-18 era) + Verified Current State + host capability audit

**Project codename:** `folly-n-valor` (Go module: `github.com/maxja/folval/server`)
**Status:** Phase 0 COMPLETE (2026-10-10). **Phase 1 COMPLETE (2026-10-12 22:36)**. **Phase 2 COMPLETE (2026-10-14)** — gate passed: guest egress fully intercepted (8.8.8.8 100% loss on the wire), DNS sinkhole + HTTP echo answering from 192.168.100.1, evidence localized in-repo (`logs/gateway.jsonl`, `captures/pcap/folval.pcap`). **Phase 3 COMPLETE (2026-10-15)** — gate passed: quiet guest (telemetry services/tasks off, vanilla guest firewall), host-boundary negative test ok, genuine NCSI responses served so NLA reports Internet. Firewall + capture units reboot-durable (SELinux module for project-local pcaps). **D5 acquisition window EXECUTED and CLOSED 2026-10-17** — game installed in-guest by the Steam client during a one-time audited online window (second NIC on the NAT'd default network; host-side steamcmd pre-staging abandoned — see D5), one online launch performed (dead server list = expected terminal state), Steam switched to offline mode and offline replay verified, NAT NIC detached (domain XML re-checked: single NIC on `re-isolated-net`), isolation gate re-run and PASSED (automated, real-reply ping heuristic), snapshots before/after the window. First hermetic endpoint observations (D3 input) recorded under Phase 3 (2026-10-17). Phase 4a (Frida injection layer) COMPLETE (2026-10-17) — frida-server 17.24.1 runs in-guest under an ONSTART SYSTEM scheduled task (console apps can't do the SCM handshake — no service), listening on 0.0.0.0:27042 with a subnet-scoped guest firewall rule; artifacts auto-fetched from the gateway /push/ route; host client pinned in `host/frida-venv/` (frida-tools 14.11.0 + frida 17.24.1); `frida-ps -H 192.168.100.10` enumerates guest processes across the isolated boundary. **Phase 4a gate PASSED — Phase 4a CLOSED (2026-10-17):** notepad attach from the host printed `arch: x64, platform: windows` with full module enumeration and a clean detach; the `FridaServer` ONSTART SYSTEM task survived a guest reboot (auto-started a fresh instance, host re-attached — reboot-durability proven); re-verified live later the same day (task Running, `0.0.0.0:27042 LISTENING`, clean guest process census — no stray probe processes). REPL-free scripting landed as `host/tools/frida-run.sh` (Python-API runner — the sanctioned Frida entrypoint; the CLI always drops into its REPL, `-q` only hides the banner). Phase 4b is IN PROGRESS (session-1 injection solved 2026-10-18; D7 resolved — Option B, pure Frida RE) and is blocked on D8 (D3D9 `CreateDevice` wall). — gate passed: `vagrant up` boots the guest in ~2.5 min, WinRM round-trip ok, domain `folly-n-valor_default` running on `re-isolated-net` only (single virtio NIC, no mgmt attachment). Path to the gate: attempt 8 (2026-10-11) proved the unattended install; the static-IP rebuild landed 2026-10-12 19:22 (folval-static-ip ONSTART task + qemu-ga baked in); first `up` (21:09) failed on box metadata `virtual_size: 10` for a 60 GiB image (`package-box.sh` read the `children[].file` `virtual-size` from `qemu-img info --output=json` — fixed, repackaged, stale pool volumes purged); second `up` (22:29) failed at 61 s because `config.winrm.timeout = 60` capped the WinRM `ready?` probe and killed the boot wait (line removed — default 1800); third `up` (22:33) passed. Windows is in `Notification 0xC004F034` activation state — VOLUME_MAK key applied (EnterpriseS, correct non-IoT edition) but cannot reach the clearing house in the hermetic lab; expected, not a blocker. Next: Phase 2 (network isolation + mock gateway). Decisions D0–D4 recorded 2026-10-10 (D4 revised 2026-10-11); D5 (target game acquisition) pending, D6 (debloat scope) recorded 2026-10-12.
**Execution rule:** Sequential phases only. Each phase has an explicit verification gate. Any unclear parameter or unexpected error halts execution and triggers a user question. No guessing, no bypassing gates.

## Overview

An isolated, reproducible QEMU/KVM lab on this Linux host: a Windows LTSC guest (192.168.100.10) provisioned via Vagrant/libvirt, locked behind a host-side nftables firewall that permits contact **only** with a local mock gateway (192.168.100.1). The mock gateway (Go, `server/`) performs DNS interception and traffic logging; Frida instrument targets inside the guest; a shared folder feeds extracted binaries and memory dumps to host-side Ghidra.

## Verified Current State

Repository is a pre-created empty skeleton. Empty files: `Vagrantfile`, `README.md`, `vm/debloat.ps1`, `vm/setup_frida.ps1`, `.ai-memory/misconceptions.md`. Existing dirs: `captures/pcap`, `re/docs`, `re/frida`, `re/ghidra`, `server`, `vm`. Only `server/go.mod` has content (module `github.com/maxja/folval`, go 1.27.2).

**Host capability audit (executed from agent shell, 2026-10-10):**

| Component | Required for | Status |
|---|---|---|
| CPU virtualization extensions (vmx/svm) | KVM | Present (24 vCPU flags; host kernel `kvm_amd` loaded) |
| `/dev/kvm` passthrough into agent context | KVM | Not required — QEMU runs on the host; container drives it via socket |
| libvirt daemon + socket access | libvirt | **VERIFIED WORKING** (libvirt 12.6.0 / QEMU 11.1.2 / KVM accel; container mounts `/run/libvirt`, `libvirt-sock` is 0666) |
| `vagrant` CLI | all phases | Present, 2.3.4 (no plugins installed) |
| `vagrant-libvirt` plugin | Phase 1 | **MISSING** (build deps not installed; agent has no sudo) |
| passwordless sudo | package installs | Not available — `sudo` requires a password |
| `virsh`, `nft`, `tcpdump` | Phases 1–2 | Present |
| `go`, `python3` | Phase 2, tooling | Present |
| `virt-viewer`, `packer`, `pipx` | Phases 1, 4 | Missing (packer/pipx install user-locally without root; virt-viewer runs on host) |
| CAP_NET_ADMIN | Phase 2 (nftables) | Absent in container — agent generates rules, user applies on host |

Audit corrections (logged in misconceptions): `systemctl is-active` cannot see host daemons from inside a container (false negative), and the agent terminal sandbox blocks unix-socket syscalls — `virsh`/`vagrant` must run unsandboxed. Both initially masked that the hypervisor was reachable all along.

## D-decision execution detail

**D1 — LTSC image source: Option A (Packer build from user-provided official ISO + license).** Media staged 2026-10-10: `packer/isos/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso` (4,899,461,120 bytes; SHA-256 `c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d`; UDF label `CES_X64FREV_EN-US_DV9`; `sources/install.wim` present, no `install.esd`/`install_MultiEdition.esd`; WIM enumerated 2026-10-10: **2 images** — Index 1 `Windows 10 Enterprise LTSC 2021` (EditionID `EnterpriseS`, x86_64, en-US, build 19041 SP-build 1288) and Index 2 `Windows 10 Enterprise N LTSC 2021`; install selects **Index 1 by name** — exact match for the non-IoT license). Filename matches official MVS naming; **Media update 2026-10-11:** user staged `packer/isos/en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso` (4.6 GB, SHA-256 `a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160`) — despite the filename it is **dual-edition**: Index 1 `Windows 10 Enterprise LTSC 2021` (`EnterpriseS`, non-IoT — build target, matches the license) and Index 2 `Windows 10 IoT Enterprise LTSC 2021` (`IoTEnterpriseS`). This is now the build media (`iso_path`); Index 2 is the fallback if the user's key turns out to be IoT-channel (suspected cause of the earlier specialize ProductKey rejection on non-IoT media). The previous `d289cf96` ISO (LTSC + LTSC-N) remains in `packer/isos/` as backup. **D1 hard gate:** prior media's hash cross-check passed 2026-10-10 (SHA-256 `c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d`, MD5 `b5a7be560dbd73619945129e52be1b5f` user-confirmed). Fallback source approved: uupdump.net with edition exactly "Windows 10 Enterprise LTSC 2021" (consumer 21H2 chains have no LTSC edition), options: Include updates ✓, .NET 3.5 ✓, component cleanup ✗, ESD compression ✗; massgrave.dev rejected as an ISO source. License: 1Password `op://DevOPS/Windows 10 Enterprise LTSC 21H2/license key` — non-IoT Windows 10 Enterprise LTSC 2021 (item label "21H2" = same product, build 19044 family), 29-char key validated by user (`wc -c` = 30 incl. newline). `pkvars.hcl` deleted by user (`packer/vars/` empty) — key resolution: `build.sh` consumes `PKR_VAR_windows_license_key` or `FOLVAL_OP_REF` from env / gitignored `packer/op-ref.env` (reference only, never the key); no op URI in tracked files, per D4. Recommended SKU stands: Windows 10 Enterprise LTSC 2021 x64 (no TPM/SecureBoot requirement; Windows 11 LTSC 2024 would add vTPM/OVMF constraints).

**D2 — Guest sequencing: Option A (Windows LTSC from Phase 1).** Phase 2 verification executes from the Windows guest; no staging VM.

**D3 — TLS interception: Option A (Frida-based extraction).** The gateway never terminates TLS; guest port 443 is not whitelisted — pinned TLS fails by design, pushing traffic analysis to Frida hooks in Phase 4. Revisit only if Phase 4 results demand it.

**D4 — Build execution wiring (2026-10-10): W1 agent-driven preferred, W2 fallback.** Environment audit: this shell runs as host uid 1000 (SELinux unconfined) with `/usr/bin/op`, `~/.local/bin/packer`, `qemu-system-x86_64`, `wimlib-imagex`, and world-writable `/dev/kvm` — the agent can run the full Packer build with KVM acceleration locally. `op read` works from this shell via 1Password desktop-app integration (GUI approval per use; `op whoami` misleadingly reports "not signed in"). **Revision (2026-10-10, later): the license key is NOT part of the build at all** — unattend ProductKey values caused the specialize pass to fail ("value outside the range of acceptable values"; interpolation and key shape forensically ruled out). Key application moved to Phase 3: `slmgr /ipk` over WinRM (key resolved from 1Password at provision time via `op-ref.env`/env, never in tracked files), with manual OOBE entry as the fallback during builds. Either way the key never appears in repo, logs, or chat. **Revision 2 (2026-10-11): key returned to the build — keyless installs on this media are fatal ("Windows cannot read the ProductKey setting").** Working placement: windowsPE `UserData/ProductKey` with `WillShowUI=OnError` (manual VNC entry as fallback), rendered at build time by `build.sh` from `answer/Autounattend.xml.in` (token `__FOLVAL_WIN_KEY__`, `op read` → sed; rendered file is trap-deleted and gitignored). Attempt 4 verified: "Valid product key in blackboard", no VNC prompt, specialize pass parsed and applied cleanly. Attempt 4 subsequently failed at the oobeSystem pass parse — cause: nonexistent setting `HideOnlineActivationScreens` (removed; OOBE block trimmed to schema-certain settings). Evidence: setupact.log via virt-cat; cached `C:\Windows\Panther\unattend.xml` is key-free (setup scrubs it).

**D5 — Target game acquisition: RESOLVED (2026-10-15).** Leading option (user-confirmed): **host-side download via steamcmd** (user owns the title in their Steam library; title/app-id intentionally not recorded in repo docs). Tooling: `./lab.sh tools:steamcmd [--force]` installs a checksum-pinned steamcmd into the gitignored `host/steamcmd/` (aria2c preferred, curl fallback; 32-bit binary verified working on the Fedora host, first run self-updates ~40 MB); `./lab.sh steam:login` (interactive; password/2FA typed at the prompt, session cached in `~/.local/share/Steam`) and `./lab.sh steam:download [appid]` (`+app_update <appid> validate`; appid from argument or `STEAM_APP_ID` in gitignored `host/steamcmd/steam.env`, alongside `STEAM_USER`) (2026-10-17). The env file may instead hold non-secret 1Password refs `STEAM_USER_FILE` / `STEAM_PASS_FILE` (`op://...`), resolved at run time via `op read` (D4 pattern; needs an active op session); any 2FA/Steam Guard code is still typed at the prompt. Anonymous download verified to fail ("not logged in to Steam") — user login confirmed required. The acquisition sequence at the Phase 3/4 boundary: download on the host with steamcmd + user login, push the install into the guest over the isolated network (WinRM/Samba), then a **one-time audited online window** — temporarily attach the NAT'd `default` libvirt network as a second NIC, one online launch to clear first-run Steam/DRM initialization, switch Steam to offline mode, detach the NIC, re-run the Phase 2 isolation gate, and record the window in the phase log as a documented exception to "guest never gets internet". Snapshots before/after the window (`./lab.sh vm:snapshot`, else `virsh snapshot-create-as`). Fallback if a DRM-free build is available: plain push via WinRM/Samba, no online window at all.

**D5 EXECUTED 2026-10-17 (window closed and re-verified hermetic).** Record for future reruns — deviations from the sequence above:
1. **steamcmd→guest staging abandoned.** The Steam client purges steamcmd-staged app content when a dependency app (Steamworks Shared) is absent from the staged set; pushing the depot plus the dependency still left the client re-validating against its own manifest. Reliable path: let the in-guest Steam client perform the install itself during the window (game landed in the primary library; Steamworks Shared in the pre-created second library — later used as the redist source).
2. **The client updater cannot run against the sinkhole.** With the isolated NIC active, the client hangs at "checking available updates" and reports it needs to be online. The window procedure therefore disables the isolated NIC for its duration (net-window on/off scripts) so all traffic egresses solely via the NAT NIC — the audited part of the window is exactly this: only Steam client traffic, on the NAT interface, with everything else already dropped.
3. **First launch observations.** A GPU warning popup (no host GPU passthrough — WARP software rasterizer; acknowledge and continue, menus render fine) followed by an indefinite "querying available servers" state — the title's backend is long dead, so this is the expected terminal state of the one online launch, and doubles as evidence there is nothing further to initialize online. A bare exe launch without the client fails on MSVCR100.dll — redists are mandatory (installed from Steamworks Shared: VC++ 2010/2012 x86, DXSETUP Jun2010, all verified present afterwards).
4. **Teardown + re-verification.** Steam → Go Offline → offline replay OK → isolated NIC re-enabled → NAT NIC detached (`virsh detach-interface`, domain XML confirmed single NIC) → gate re-run: PASS. The gate's ping heuristic was fixed first: Windows `ping` counts host-generated ICMP "destination unreachable" errors as Received, so its loss line is meaningless for blocked probes — only lines `Reply from <target>: bytes=` count as real echo replies.
5. **Evidence gap, acknowledged:** the bridge pcap service was down for the window and teardown (SELinux path-walk gap, fixed same day — `host/selinux/folval-pcap.te` v1.2 adds `home_root_t`/`user_home_dir_t` dir search; the base policy dontaudits that denial, so it fails with zero AVCs). Endpoint mapping of the window was not a goal (backend dead); the gateway log remains the liveness record.
6. Snapshots: `pre-game-push` (17:06), `pre-steam-install` (17:35), `post-game-online` (18:41), all 2026-10-17.
**D7 — Phase 4b strategy: OPEN (recorded 2026-10-17).** Option A — adapt the third-party reference server: run it host-side on the lab gateway, point the guest's game-server DNS at it via a gateway per-host override, and solve the certificate story hermetically (self-signed termination + cert-shim DLL injection at launch). Potentially makes deep protocol RE of the 14 endpoints unnecessary, but depends on the guest client build matching the reference-validated build (280139) and on a hermetic cert-shim path. Option B — pure Frida RE: consolidate `re/frida/phase4b/` via the Phase 4b ideation gate, attach to the desktop-launched game, hook the 443 TLS write/read path inside the main module (libCURL in-exe; no DLL exports to grab) and the 11234 analytics payloads pre-TLS. Prerequisite either way: confirm the guest's installed client build. Decision pending with the user; all Phase 4b work is on hold until it lands.

**D7 RESOLVED (2026-10-18): Option B, pure Frida RE.** Guest client build confirmed matching the reference-validated build (280139); the reference project (gitignored `tmp/`) is treated as unverified hints only. Full record in `PROGRESS.md` (D7 entry).

**D8 — D3D9 wall resolution path (recorded 2026-10-18 — OPEN).** The game's own `CreateDevice` call fails `D3DERR_INVALIDCALL` (fatal error box) while an in-process selftest with simple parameters returns S_OK — runtime, driver, and video model (vga/256MB) are healthy; the game's specific arguments are the failure (behavior flags 0x52 incl. HW vertex processing + MULTITHREADED, 1280×720, BackBufferCount=2 — d3d9 validates against real driver caps, not softened Check* lies). Resolution ladder: (1) bisect the game's `CreateDevice` args in `gpu_shim.js` — cheap, in-process evidence exists; (2) d3d9→D3D11 translation layer (DXTrans/wined3d class); (3) GPU passthrough (host iGPU not host-visible — discrete card or vGPU required). NULLREF ruled out as a fix (inbox Win10 d3d9 refuses `D3DDEVTYPE_NULLREF` → same INVALIDCALL). Blocks all in-game Phase 4b capture; live status in `PROGRESS.md`.

## Directive-phase records (roadmap, as completed)

## Evolutionary Roadmap

Phase numbering preserves the directive's Phase 1–5; Phase 0 is added for the container/libvirt blocker discovered during audit.

### Phase 0 — Host Execution Environment Readiness — COMPLETE (2026-10-10)

- **Goal:** Agent-controllable KVM + libvirt from the container; Phase 1 tooling in place.
- **Verified:** `virsh -c qemu+unix:///system version --daemon` → libvirt 12.6.0 / QEMU 11.1.2; KVM acceleration in `domcapabilities`; no existing domains; `default` network active; no storage pools.
- **Verified:** `vagrant-libvirt` 0.11.2 present (Fedora system plugin, compatible with system Vagrant 2.3.4 — no pinning needed). Build deps installed by user (`libvirt-devel`, `ruby-devel`, `libxslt-devel`, `libxml2-devel`).
- **Verified:** Packer v1.16.1 installed to `~/.local/bin` (checksum-verified from official releases).
- **Deferred user actions:** Samba on host (Phase 5); nftables ruleset application on host (Phase 2 — container has no CAP_NET_ADMIN); `virt-viewer` on host to watch the Windows install (Phase 1); `op` CLI setup if W1 chosen (see D1/Phase 1).
- **Verification results:** all three gates passed (virsh daemon answer, `vagrant plugin list`, `packer version`).

### Phase 1 — Vagrant & Libvirt Infrastructure (directive Phase 1) — COMPLETE (2026-10-12)

- **Goal:** Windows LTSC domain running under libvirt with defined topology: mgmt-free isolated network `re-isolated-net` (192.168.100.0/24), host gateway 192.168.100.1, guest static 192.168.100.10.
- **Dependencies:** Phase 0 verified; D1 confirmed (ISO staged + hashed; edition-in-WIM check and source-page hash cross-check pending); D4 op wiring: W1 pending user `op signin`, W2 fallback.
- **Deliverables:** Packer QEMU template + unattended answer file for the confirmed LTSC SKU with virtio-win driver injection (virtio-win.iso host-downloaded 2026-10-10 into `packer/isos/` from fedorapeople `stable-virtio`, 837 MB, SHA-256 `303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d` as local baseline; drivers staged to floppy at build time by `packer/build.sh` — QEMU builder has no `additional_iso_files`; qemu-ga MSI installed via WinRM provisioner); resulting box registered locally. Scaffolded and `packer validate` clean 2026-10-10. Build-time note: Packer's user-mode (slirp) networking gives the transient build VM a host-NAT path — hermetic isolation contract applies from Phase 2; nothing in unattended setup requires or fetches anything. Secret handling: `variable "windows_license_key"` declared `sensitive = true`, supplied via `PKR_VAR_windows_license_key`; `packer/build.sh` consumes it from env only — seeded directly, via `FOLVAL_OP_REF`, or via gitignored `packer/op-ref.env` (reference only, never the key) — no pkvars.hcl, key never on disk in the repo, masked in logs. Wiring implemented: W1 (agent-driven) via `packer/op-ref.env` + desktop-app `op` integration; W2 (user shell) works unchanged. Known limitation: the key is inherently embedded into the built VM disk image by Windows setup. `Vagrantfile` (libvirt provider, 8 GB RAM / 4 vCPU, `mgmt_attach: false` — the libvirt default mgmt network is NAT'd to the internet and would silently defeat isolation; qemu-guest-agent enabled for address discovery; WinRM communicator).
- **Verification:** `vagrant up` completes; `virsh list --all` shows the domain running; `vagrant winrm -c "echo ok"` (or guest-agent ping) succeeds. **PASSED 2026-10-12 22:36** — `./lab.sh up` booted the guest in ~2.5 min (WinRM ready 22:36:25), `./lab.sh verify` WinRM round-trip ok; domain `folly-n-valor_default` running with a single NIC on `re-isolated-net` (active, autostart, persistent; no mgmt network attached). Post-gate notes: (1) the first `up` (21:09) failed on box metadata `virtual_size: 10` vs 60 GiB image — fixed in `package-box.sh` (qemu-img JSON `children` trap, see misconceptions); (2) the second `up` (22:29) failed at 61 s because `config.winrm.timeout = 60` bounded the `ready?` probe and killed the boot wait early — the line is removed (default 1800); (3) activation state: `slmgr /dli` → `EnterpriseS`, `VOLUME_MAK` channel, partial key present, `Notification 0xC004F034` — MAK keys cannot activate without reaching Microsoft, which the hermetic lab forbids by design; expected terminal state, not a blocker.
- **Pipeline automation (2026-10-11):** `lab.sh` at repo root is the single entrypoint (`build`/`add`/`up`/`verify`/`rebuild`/`license`/`down`/`destroy`); `windows-ltsc.pkr.hcl` gained a `shell-local` post-processor running `package-box.sh` and `build.sh` a `package` action plus do-not-interrupt banners. Rationale: attempt 5's image (8.7 GB) was destroyed when packer was interrupted after guest shutdown but before the then-manual packaging step — the qemu builder deletes `output-win-ltsc` on any non-clean exit.
- **Static-IP bootstrap (2026-10-11, baked in 2026-10-12):** the box's NIC is DHCP-configured by the build (SLIRP) but `re-isolated-net` runs DHCP-less by design — without guest-side action the first `vagrant up` would strand the guest on APIPA and WinRM to 192.168.100.10 would never connect. Fix baked into the image: `packer/files/network/folval-net.ps1` (idempotent: waits for the virtio NIC, sets 192.168.100.10/24 gw+dns 192.168.100.1, flips the profile Private, re-asserts AllowUnencrypted/Basic) wired to an ONSTART scheduled task running as SYSTEM — chosen over RunOnce because it fires without any interactive logon and the unattend AutoLogon count is finite. `build.sh` now stages only `files/guest-agent` (the `files/` tree also carries tracked payloads). Baked into the 2026-10-12 19:22 box (build log: task `folval-static-ip` created successfully).

### Phase 2 — Network Isolation & Mock Gateway (directive Phase 2) — COMPLETE (2026-10-14)

- **Goal:** Guest can reach *only* 192.168.100.1, and only the services the mock gateway offers; all transit traffic captured.
- **Dependencies:** Phase 1 verified.
- **Deliverables (as designed):** `host/firewall/` — nftables ruleset + idempotent apply script + persistence unit; `server/` — Go gateway `folval-gw` (DNS sinkhole, per-host overrides, full query log, HTTP echo/logger; static guest IP, no DHCP → no dnsmasq port-53 conflict); `host/capture/` — tcpdump unit on the bridge writing `captures/pcap/`. Ruleset generated by the agent; user applies it on the host (container has no CAP_NET_ADMIN).
- **Implemented architecture (verified 2026-10-14):**
  - `host/firewall/folval.nft` (table `inet folval`): prerouting DNATs guest-destined 53→1053 and 80→8080 so `folval-gw` runs fully unprivileged (user-approved "Option A" — no privileged ports anywhere); input chain routes guest-net traffic through `folval_from_guest`, which accepts only post-DNAT DNS/HTTP to 192.168.100.1, guest ICMP echo-request to the gateway, and `ct state established,related` — the established accept is what lets host-initiated WinRM (5985) complete its handshake while the guest itself can still only initiate to the gateway ports; everything else from 192.168.100.0/24 drops; forward chain drops any transit in either direction. Port 443 deliberately not whitelisted (D3). Applied by the user via `host/firewall/apply.sh` (idempotent: deletes then loads the table).
  - `server/` — idiomatic Go module `github.com/maxja/folval/server`: `cmd/folval-gw/` + `internal/{config,dnswire,overrides,evidence,gateway}`; hand-rolled DNS wire format (zero third-party deps), AGPL-3.0-or-later with SPDX headers. DNS: all A answers sinkholed to 192.168.100.1 unless a per-host overrides file overrides (empty overrides path = feature disabled); HTTP: echo responder logging method/URL/host. Evidence stream: JSONL events (`dns.query`, `http.request`, `meta`) to a log file.
  - `host/capture/folval-capture.service` — tcpdump on `virbr1` writing rotating captures into the repo's `captures/pcap/` (evidence stays project-local per user preference).
- **Verification (from Windows guest): PASSED 2026-10-14** — `ping 8.8.8.8` 100% loss (and the unanswered ICMP echo is visible in the pcap — the drop is on the wire, guest default route confirmed present); `ping 192.168.100.1` 0% loss; `Resolve-DnsName gate-check.example -Server 192.168.100.1` → 192.168.100.1, with the query in `logs/gateway.jsonl` and `captures/pcap/folval.pcap` (DNS round-trip + HTTP `GET /probe` → 200 through the port-80 DNAT); `nft list table inet folval` active (user-applied). Windows NCSI background traffic (msftconnecttest/edge/telemetry) continuously exercises the sinkhole and appears in the log — expected hermetic behavior, useful as a liveness signal.
- **Post-gate notes:** (1) host→guest WinRM initially failed after an unclean guest shutdown — root cause was twofold: the guest's WinRM HTTP-In firewall rules had ended up disabled (re-enabled via qemu-ga guest-exec), and the original ruleset dropped the guest's SYN-ACKs in the input chain (fixed by the `ct state established,related` accept above; it also explained a false "guest drops ICMP" reading — ping echo-replies had been dropped host-side). (2) Guest boot to a listening WinRM endpoint can lag several minutes after the domain shows running — probe with timeouts before concluding breakage. (3) tcpdump reverse-resolves IPs in text output (`8.8.8.8` prints as `dns.google`) — grep pcaps with `-n` or by name.

### Phase 3 — Windows LTSC Provision & Debloat (directive Phase 3)

- **Goal:** Quiet, low-telemetry-noise guest. Enforcement stays at the host boundary — no guest-side egress control (D6).
- **Dependencies:** Phase 2 verified (no accidental internet exposure during provisioning).
- **Deliverables (revised by D6, 2026-10-12):** `vm/debloat.ps1` — quiet-guest scope only: disable DiagTrack + dmwappushservice + telemetry-scheduled tasks, set telemetry to Security, disable SMB1, disable the Windows Update service. **No guest-side outbound firewall policy** — the guest firewall stays vanilla: host nftables (Phase 2) is the sole enforcement boundary, and guest-side blocking would hide egress attempts from the wire, losing the research signal. All provisioning over WinRM; no guest internet assumed.
- **Verification (Windows guest):** `Get-Service DiagTrack` is Disabled; `Get-Service wuauserv` is Disabled; `Get-NetFirewallProfile | Select Name,DefaultOutboundAction` shows the vanilla default (Allow — proof no guest-side blocking was applied); negative test of the host boundary from inside the guest: `Test-NetConnection 192.168.100.1 -Port 8080` fails (dropped by host nftables, not by the guest).
- **D5 window at the Phase 3/4 boundary (2026-10-17):** executed and torn down same day; isolation gate re-run after teardown → PASS (automated gate script, real-reply ping heuristic). Full record under D5.
- **First hermetic endpoint observations (2026-10-17; D3/Phase 4 input):** in the post-window offline replay the title resolved exactly two title backend hostnames through the sinkhole — its launcher and game-server discovery endpoints (identities live only in the gitignored gateway log; a third, publisher-owned hostname joined in the later re-launch under capture — see the wire profile below) — and issued **zero** plaintext HTTP requests to them: every post-DNS connection attempt fell through to non-whitelisted ports and was silently dropped at the host boundary, matching D3's TLS-by-default expectation. The only other non-OS chatter was the Steam client's own connectivity probe in a ~3 s retry loop (gateway echoes 200, the client expects 204 — never satisfied; expected in hermetic operation, not a defect). **Wire profile pinned under capture (2026-10-17, one re-launch with the ring live; attribution corrected after a full log census):** the title's hermetic wire footprint is **TCP 443 (TLS)** and **TCP 11234** (custom port), both to the sinkhole address, and **zero non-OS UDP**. Attribution by DNS→SYN correlation: the launcher endpoint SYN'd 443 seven-to-nine ms after each answer (twice); a third hostname — **publisher-owned analytics infrastructure**, absent in the first session, appearing twice in the re-launch — SYN'd **11234** roughly a quarter millisecond after each answer; the game-server discovery hostname resolved but produced **no TCP attempt in the observed window** (its connection is presumably gated on the launcher flow). First launch went straight to SYN on the cached answer (no re-resolution). SYNs retransmit at 1/2/4/8 s backoff (3–5 attempts per socket) before the cycle repeats roughly every 2 minutes. Two initial-window fingerprints split cleanly: every socket with a same-cycle DNS precursor used 64240, while both standalone cached-IP 443 chains used 65535 (consistent with game socket vs embedded web view; unconfirmed). Phase 4 implication: hook targets are the TLS write/read path on 443 (OpenSSL per D3 client-tech intel) plus the custom-port protocol (an analytics endpoint — may still carry session identifiers worth capturing); a gateway per-host DNS override is not needed until a mock backend must terminate TLS with a real certificate story.
- **PASSED 2026-10-15.** Evidence: services DiagTrack/dmwappushservice/wuauserv Disabled and telemetry tasks (Consolidator/UsbCeip) disabled after `./lab.sh vm:provision` (delivered via qemu-ga guest-exec, not a vagrant provisioner — winrm-fs is a stub gem on this host); `Get-NetFirewallProfile DefaultOutboundAction = Allow` (NotConfigured/vanilla) on all profiles; host-boundary negative test `Test-NetConnection 192.168.100.1 -Port 8080` → False; gateway serves genuine NCSI responses (connecttest.txt/redirect) so NLA reports `IPv4Connectivity = Internet` (after one guest reboot to clear the cached NLA verdict — the cache outlives the service fix); NCSI hits visible in `logs/gateway.jsonl`. Post-gate host work: firewall + capture systemd units made reboot-durable (ruleset installed to `/etc/folval/folval.nft`; capture ring `-Z root` + SELinux module `host/selinux/folval-pcap.te` — tcpdump's domain is `netutils_t`, which needs `user_home_t` write plus `dac_override` to keep pcaps project-local). Notes: (1) `Disable-ScheduledTask` needs `-TaskPath` alongside `-TaskName` (name-only form throws 0x80070002); (2) KernelCeip/MareBackup tasks no longer exist on LTSC 2021 — the provisioner treats them as optional.

### Phase 4 — Frida Injection & Instrumentation (directive Phase 4)

- **Goal:** Working instrumentation handshake against arbitrary guest processes.
- **Dependencies:** Phase 3 verified.
- **Deliverables (as implemented 2026-10-17):** single idempotent `vm/setup_frida.ps1` (run: `bash host/tools/guest-run.sh vm/setup_frida.ps1`): (1) fetches pinned artifacts — `python-3.11.5-embed-amd64.zip` + `frida-server-17.24.1-windows-x86_64.exe` — from the gateway `/push/` route (source of truth `host/push/`), (2) extracts Python embed → `C:\python3`, copies server → `C:\frida\frida-server.exe`, (3) guest firewall rule: inbound tcp 27042 from `192.168.100.0/24` only, (4) boot-persistent runner as a **SYSTEM scheduled task** `FridaServer` (ONSTART, HIGHEST) executing `frida-server.exe -l 0.0.0.0:27042`, started via `schtasks /Run` (detached from the provisioning session). Host client: pinned venv `host/frida-venv/` (`frida-tools==14.11.0` + `frida==17.24.1`; frida cp37-abi3 wheels cover host Python 3.15). **Deviations from the original directive, both forced by the environment:** (a) no Windows service — frida-server is a console app that never completes the SCM handshake, so `sc create` always fails 1053; the ONSTART SYSTEM task is the wrapper-free equivalent. (b) no guest internet *or* guest-side SMB: artifacts flow through the hermetic HTTP push route, not a share. Hook scripts in `re/frida/` pushed to `C:\re\frida\` (Phase 4b).
- **Runner & frida policy (added 2026-10-17):** `bash host/tools/frida-run.sh <pid|name> <script.js> [wait_s]` (attach; pid or exact process name) or `bash host/tools/frida-run.sh --spawn <image> <script.js> [wait_s]`; `wait_s` defaults to 10 s, `0` = stay attached until Ctrl-C. REPL-free via the Python API (`add_remote_device` → attach/spawn → `create_script` → bounded wait → clean detach). `--spawn` runs under frida-server (SYSTEM, session 0): probes only — the game is desktop-launched via `host/tools/guest-start.sh`, then attached to by pid/name; spawned processes are killed on exit so probes never outlive the run. Message routing: `console.log` arrives via `set_log_handler`, `send()`/errors via `on("message")` — the runner prints both to stdout as they arrive. Ad-hoc CLI one-shots (`frida -H 192.168.100.10 -p <pid> -q -l <script.js> </dev/null`) are acceptable only with the stdin redirect — without it the CLI waits on stdin after loading (it ALWAYS enters its REPL). **Reference input for Phase 4b (identity-free, 2026-10-17):** a working third-party private-server implementation for this exact title is kept local-only under gitignored `tmp/` (clone; never committed — identity constraint). Its README documents the client's network stack: game TLS is libCURL statically linked into the exe with the CA trust store compiled in, so a mock backend must terminate TLS self-signed AND have a cert-shim DLL injected at client launch; validated against client build 280139 — the guest's installed client build is NOT yet confirmed. This reference is the primary input to D7.
- **Verification:** Note — the directive's `frida -p <PID> --version` is invalid CLI usage (`--version` prints and exits; it never attaches). Correct gate: start `notepad.exe` in guest, then from host `frida -H 192.168.100.10 -p <PID> -q -e "console.log(Process.arch)"` prints `x64`, and a test hook from `re/frida/` (module enumeration on notepad) loads without error. 4a handshake DONE 2026-10-17: `frida-ps -H 192.168.100.10` lists guest processes from the host across the isolated boundary. **Gate CLOSED 2026-10-17:** notepad attach → `arch: x64, platform: windows`, module enumeration, clean detach; guest rebooted → `FridaServer` ONSTART task auto-started (fresh pid), port 27042 re-listening, host re-attached — the task is reboot-durable. Runner validated live: `host/tools/frida-run.sh --spawn notepad.exe re/frida/phase4_gate.js` → gate script output → clean detach, spawned process killed on exit. Tooling fixes landed with the gate: `host/tools/guest-run.sh` output capture repaired (qemu-ga needs `"capture-output":true`; output arrives as base64 `out-data`/`err-data`, not `stdout`) and `host/tools/guest-start.sh` provides session-detached guest launches (WinRM sessions reap children).

### Phase 5 — Shared Workspace for Ghidra (directive Phase 5)

- **Goal:** Guest-extracted binaries, DLLs, and memory dumps land on host for Ghidra.
- **Dependencies:** Phase 3 verified (guest stable, share mountable); Samba from Phase 0.
- **Deliverables:** Host Samba share bound to the bridge IP only (`\\192.168.100.1\re`), guest maps `Z:` via provisioner. Deviation from directive, documented: vagrant-libvirt provides no native synced-folder mechanism for Windows guests (no virtiofs/9p), so `config.vm.synced_folder` is declared `disabled: true` and the Samba mount implements the same contract; fallback attempt of Vagrant `type: "smb"` recorded during execution. Ghidra itself runs on the host against `re/ghidra/` project files.
- **Verification:** `echo probe > re/ghidra/probe.txt` on host; `Get-Content Z:\ghidra\probe.txt` in guest succeeds within seconds; reverse direction: file written in guest appears on host.
