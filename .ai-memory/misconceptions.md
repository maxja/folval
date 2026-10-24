# Agent Misconception & API Log — ACTIVE

Rules that still govern every session. Historical/solved entries live in
`misconceptions-archive.md` (rarely read; full original wording).

## Agent / host environment

- **Container isolation:** host daemons are invisible to `systemctl is-active` (judge by connecting, e.g. `virsh -c qemu+unix:///system version --daemon`); the container mounts host libvirt sockets (no `/dev/kvm` needed — QEMU runs on the host); `sudo` requires a password (route installs through the user); shares host PID namespace but NOT net namespace (`pgrep` sees host processes; `/sys/class/net` does not show virbr1 — judge NIC state via virsh).
- **Zed terminal sandbox:** blocks unix-socket syscalls (`virsh` needs `unsandboxed: true`); sandboxed commands may silently discard stderr — re-check tool state unsandboxed. The permission parser rejects `$VAR`/`$(...)` even unsandboxed; write literal commands. Tool paths for `move_path`/`copy_path`/`create_directory` must be prefixed with the project root dir; `write_file` with empty content silently no-ops (use a newline).
- **virsh default URI is `qemu:///session`** for the agent shell — always `virsh -c qemu:///system ...`.
- **pkill self-match:** bracket-trick ALL patterns (`outpu[t]-win-ltsc`) or kill by numeric PID.
- **lab.sh `ts_run <log> <cmd...>`:** log path FIRST, else it becomes a stray file named like the first word.
- **Sourced env files:** quote values with spaces (`VAR="a b"`) — unquoted splits and executes the tail.
- **Steam data lookups:** steamdb.info is bot-hostile (comply, don't retry); store pages redirect silently for delisted apps. Target-title facts: ask the user; identity stays out of repo files.

## WinRM & guest operations

- **`vagrant winrm -c` runs via PowerShell:** no `%windir%` cmd expansions (absolute paths or `$env:`); `dir` is aliased to Get-ChildItem (no `/s /b` — wrap cmd builtins in `cmd /c "…"`); `config.winrm.timeout` is a per-probe boot-wait cap, NOT an operation timeout — never lower it (tune `boot_timeout`).
- **Nested-quote one-liners are a tar pit:** three quoting layers + spaces in `Program Files (x86)`. Stop after the FIRST failure; write ONE clean `.ps1` locally → UTF-16LE base64 → `powershell -EncodedCommand` (`host/tools/guest-winrm.sh <script.ps1>` does exactly this).
- **WinRM stdout MANGLES binary** (bytes ≥0x80 re-encoded as UTF-8): never exfil binaries via `cmd /c type`. Recipe at 20MB scale: guest-side gzip → chunked base64, **256KB raw chunks (~341KB base64)** under the 500KB envelope → assemble + size assert + MD5 both sides (driver template: `tmp/crash/exfil-dump.sh`). `guest-push.sh` needs the gateway running — a misleading size printout after an `Invoke-WebRequest` failure is `Get-Item` on the OLD file.
- **WinRM sessions reap child processes:** daemons must start session-detached (Task Scheduler), never bare `Start-Process` in a one-shot exec.
- **PowerShell `param()` must be the FIRST statement** (only comments may precede) — else "'param' is not recognized" and all arguments are silently ignored (defaults can still bind via the side-effecting argument expression, masking it).
- **Every guest script sets `$ProgressPreference = 'SilentlyContinue'` first** — progress bars in captured stdout wedge qemu-ga permanently (EOVERFLOW; only `virsh destroy` + `start` recovers; blocks WinRM address discovery too).
- **Windows firewall default-inbound-block:** listeners need a subnet-scoped inbound rule (isolated NIC profile = Public). After unclean shutdowns verify WinRM firewall rules + profile. `Disable-ScheduledTask` needs `-TaskPath`. `Get-ChildItem -Include` needs `-Recurse`. NCSI retry loops to msftconnecttest are NORMAL in the sealed guest (free liveness signal). NLA caches its verdict — reboot after NCSI-affecting changes.
- **`schtasks /TR` stores the string verbatim** (unexpanded `$Var` stays literal; verify `/V` "Task To Run" after create). Cross-session interactive launches: HKCU-Run key + `ui-dispatch.cmd` (a SYSTEM WinRM `New-ScheduledTaskAction` with explicit path fails `0x800710E0`; `/IT` tasks staged non-interactively never run).

## qemu-ga

- **guest-exec lifecycle:** fetch `guest-exec-status` IMMEDIATELY (pids reaped fast); output keys are `out-data`/`err-data` (base64) and appear only with `"capture-output": true` — omitting it = silent empty output. Windows argv is joined without re-quoting (embed escaped quotes around inner strings); PowerShell cold start ~10 s (30 s timeout).
- **A wedged agent stays wedged until `virsh destroy` + `start`** — `host/tools/guest-run.sh` auto-falls back to WinRM (`guest-winrm.sh`); scripts must stay idempotent. NEVER attach Frida probes to qemu-ga.exe.

## Frida & instrumentation

- **Attach check:** `frida -p <PID> --version` is invalid — use `frida -H <host> -p <PID> -q -e "..."` or `host/tools/frida-run.sh` (Python API; CLI always enters its REPL). `console.log` goes to the LOG handler, not the `on("message")` callback; spawned processes are killed by the runner on detach (`dev.kill`).
- **Frida 17 API:** static `Module.findExportByName`/`getExportByName` are GONE — use `Process.getModuleByName('dll').findExportByName('name')` / `Process.findModuleByName`; `Process.enumerateModules()[0]` is NOT the main exe — use `Process.mainModule`.
- **Session boundary:** a session-0 (SYSTEM) frida-server SEES but CANNOT attach session-1 processes; certpatch inject.exe likewise fails `VirtualAllocEx err 5` from session 0 (even `/RU vagrant` schtasks runs session 0). Working pattern: user-session frida-server via the `ui-dispatch.cmd` chain (`FOLVAL_FRIDA_PORT=27043`), keep :27042 for headless probes; inject.exe must run from the same session-1 chain.
- **frida-server binds localhost by default** — always `-l 0.0.0.0:<port>`. `frida-run.sh` composition: comma-separated scripts concatenate into ONE session script; `FOLVAL_SCRIPT_ENV` (JSON), `FOLVAL_SPAWN_ENV` (`;`-separated k=v), `FOLVAL_SPAWN_CWD`.
- **In a packed process make NO native calls at script-load time** (loader-lock flakiness) — hook-only design.

## Gateway / firewall / lab network ops

- **folval-gw cannot bind :443** — unprivileged ports + DNAT (guest 443→host 8443, 53→1053, 80→8080) in `host/firewall/folval.nft`.
- **Editing the repo nft file changes nothing live:** deployed copy is `/etc/folval/folval.nft` (folval-firewall.service). Deploy: `sudo install -m644 host/firewall/folval.nft /etc/folval/folval.nft && sudo systemctl restart folval-firewall`; verify after ANY reboot/edit with a guest probe (`vm/probe-connect.ps1`).
- **Prefer the portless DNAT path** (`https://Gameserver` → :443→8443): direct guest→GW:8443 accepts are order-fragile against libvirt rules reloads and regress after VM reboots. Sinkhole+forward hijacks ALL guest :443 into the forward (noise handshakes complete on the self-signed cert).
- **Self-generated certs: backdate notBefore by 7d** (`now`-based certs fail `verify error:num=9: not yet valid` under clock skew) and persist the PEM (`FOLVAL_SERVER_PEM`) for stable identity + decryptable pcaps. When a TLS client aborts right after ServerHello+Cert, run `openssl s_client` from a known-good clock and READ the verify errors before touching trust machinery.
- **Guest clock:** domain redefined `<clock offset='localtime'/>` (durable fix). A ±3h skew does NOT break TLS with backdated certs — don't chase cert trust when only wall-clock is off. Host logs are UTC (gateway.jsonl) vs host-local out/ filenames.

## Engine (game client) facts

- **The exe is UBX-packed** (`.text/.rdata/.data` raw-size 0; payload in `.UBX0/.UBX1`): static disasm of the file is useless — unpacked code exists only in memory (crash dumps; runtime module base ≠ preferred 0x400000 — RVA = dumpVA − dumpModuleBase). Crash minidumps do NOT contain the unpacked `.text` (only packed `.UBX` regions); the proven live-exfil: `re/frida/phase5/dump_text.js` streams `.text` [base+0x1000,+0x9EC000) as 106×96KB base64 chunks via `send()` at the first `Direct3DCreate9` call → reassemble from the JSONL.
- **The engine has an ANTI-TAMPER self-CRC at ~+3.4s wall:** an in-exe Interceptor trampoline installed before it → modal "…file corruption has been detected !" → shutdown. DLL hooks don't trip it. In-exe hooks must land AFTER the first `Direct3DCreate9` call (post-CRC, pre-Bloomberg-init); certpatch's ~12s delay was accidentally correct. No-D3D-events + corruption box = CRC tripped, NOT real corruption — never re-download on that symptom. Steam's validation also RESTORES truncated overlay DLLs after enough idle time — re-run `vm/overlaycorrupt.ps1` before each run batch if Reset fails again.
- **`Process.mainModule` is WRONG in the packed process (returns bcrypt.dll, Frida 17):** find the exe via `Process.enumerateModules()` first name ending `.exe`.
- **Composed frida probes share ONE scope:** a second top-level `var CFG` silently overwrote gpu_shim's config after its loaded-event (deptex/fmtswap dead → INTZ RT E_OUTOFMEMORY). Name probe globals uniquely (`STRLEN_CFG`).
- **INTZ depth-RT detail:** the engine's depth-RT is `CreateTexture(usage includes 0x2, fmt=INTZ)` — deptex hook catches it via the 0x2 bit and rewrites fmt→21+usage→RT (hr=0 verified).
- **Engine crypto is STATIC** (libCURL+OpenSSL compiled into the packed exe): Windows trust-store imports only fix UI/CEF/schannel; the engine's only trust knob is certpatch.dll injection, and TIMING matters — engine dials ~90 s after spawn and backs off after one failure (inject within ~60 s).
- **Engine net stack uses no ws2_32 exports:** netstat/`Get-NetTCPConnection -OwningProcess` is ground truth; persistent SynSent = SYNs dropped host-side.
- **Architecture map:** UI = CEF loading `http://localhost/gamedata/UI/Html/en/Index.html` from a LOCAL webserver; the JS bridge object is injected only after the backend link is up (`Uncaught ReferenceError` = UI alive, backend dead); analytics dials `hqbloomberg.ubisoft.org:11234`; BootManager's "user signed-in" is steam-offline, NOT backend auth.
- **Local UI webserver is http.sys (PID-4, invisible to owner queries):** after engine crashes, zombie registrations block :80 — order matters: reboot → start `vm/uiweb80.ps1` → THEN spawn the game.
- **Decode the ClientHello before attributing it** (SNI + cipher list + client_version from relay hex; no-SNI+small ≠ the game); correlate connection attempts against a FULL census of the window, not the expected-hostname set.
- **Launch-recipe dependencies (Phase 4b, still in force):** gpu_shim quirks on d3d9/Basic-Display — MULTITHREADED(0x10) kills CreateDevice (0x52→0x20), no depth textures (INTZ→fmt 21+RENDERTARGET), DXT1/DXT5 OK but ATI2 fatal → fmtswap ATI2-only (blanket swaps corrupt), force windowed; in-process D3DCAPS9 readbacks are garbage (trust dxdiag); `steam_appid.txt` next to the exe (else 1 Hz poll park); Steam overlay must stay neutralized (in-place truncate after Steam's ~75 s settle — `vm/overlaycorrupt.ps1`; renames/dir-blocks do NOT survive Steam validation); fmtswap verdicts: always read per-format CreateTexture hr from the shim log first.
- **A "silent stall" may be a MODAL MessageBox** — census the desktop (VNC / window_enum) before diagnosing internally; orphaned UI processes RESPAWN the engine (watchdog, not us) — kill orphans between experiments. Under capture-only TLS the healthy game retries ~30 s forever; degraded runs give up after 3.
- **`ui-start.sh` resolves bare names** (staged `start "" "steam.exe"` fails at every autologon); never send runner stderr to /dev/null (console logs = `out/<stem>.console.log`).
- **Crash reports are `BIN>` containers** at `<gamedir>\CrashReport\Exception_*.breport` (record format: `BIN<typechar>` + name\0 + u32-LE len + data; the file "magic" is record #1's header). When the engine dies silently, check this BEFORE theorizing. Carver: `tmp/crash/carve.ps1`; analysis: `tmp/crash/analyze-dump.py` + `disas-crash.py`.

## Evidence & repo hygiene

- **Identity policy:** title identity NEVER in committed files; the leak vector is session-record PROSE (narratives), not configs. Self-scan on EVERY commit: `git add -A && git grep --cached -iE "<terms>"` (flags BEFORE pathspec). Terms live only in the gitignored handoff. Unpushed history can be scrubbed (backup branch, `git reset --soft`, redact, recommit).
- **`./lab.sh evidence:status|clean [--force]`:** status inventories logs/captures/out with LIVE/STALE ring classification; clean is dry-run by default; keepers via `out/.keep`. Full rules: `re/docs/ARTIFACTS.md`. Distill first, delete second; stop the gateway before cleaning logs/.
- **pcap discipline:** ring members `<base>00..(N-1)` (a bare-base file is a non-ring relic — check mtimes); coverage starts at ring/service start (compare timestamps before concluding "not captured"/"is captured"); `tcpdump -n` still prints service names (use `-nn`); text output reverse-resolves (use `-n`); a mid-diagnosis `-w` start TRUNCATES previous captures.
- **TLS decryption:** CRLF-terminated keylogs load ZERO secrets silently (tell: raw ciphertext +24B/record; fix `guest-pull.sh --strip-cr`); relayed (DNAT+forward) streams only decrypt after stream isolation (`tshark -r ring -Y "tcp.stream==N" -w s.pcap`, frames renumber); size-classify streams first. mqelserver.log holds only banners — RE instrumentation logs land in `Plugins\Logs\MQELOffline.log` (pull BOTH).
- **py-minidump 0.0.24:** parse() logs a scary PEB traceback but SUCCEEDS; `md.exception.exception_records` is a plain LIST; `ThreadContext` is a raw FILE offset (not `reader.read()`, which takes virtual addresses); x86 CONTEXT: Ebp=0xB4, Eip=0xB8, SegCs=0xBC, EFlags=0xC0, Esp=0xC4 — verify SegCs==0x23/SegSs==0x2B before trusting the parse.
- **capinfos labels are version-dependent** ("Earliest/Latest" vs "First/Last packet time:"); match `/ packet time:/` generically.
- **exiftool** (host, `sudo dnf install perl-Image-ExifTool`): instant PE/MSI/ISO metadata triage (version resources, PDB path, PE facts); `-j` for scripting; read-only policy on evidence.

## 2026-10-23 (late) — frida/guest lessons
- A SECOND frida session cannot attach to a process spawned by frida-run (agent monopolizes — `TransportError: timeout was reached`). Attach-type probes (window_enum, shot) must either compose into the spawn (IIFE scope, no `var CFG` collisions) or attach to a DIFFERENT process (steam.exe).
- WinRM PowerShell screenshots (`CopyFromScreen`) capture only the session-0 desktop — session-1 game visuals need PrintWindow from a session-1 process, or VNC eyes.
- Game window: title = the game's full title, class `Runtime v0.3`, seen by steam.exe-attached window_enum early in a run, but in-proc EnumWindows (composed shot.js) found nothing ×10 — don't assume cross-session visibility == in-proc visibility.
- Process "killed" in runner log = harness timeout kill (normal); absence of it + dead process = game exited on its own. ExitProcess hook distinguishes (installed, but no exit events seen yet — exits may go through CRT exit() → RtlExitUserProcess instead).
- Verify assumptions about "unhandled crash" first: run36 "died ~12s" per user's screen, but process was ALIVE 2min+ rendering headless — window death ≠ process death.

## 2026-10-24 — root-cause & environment lessons
- **Read the target's OWN logs before theorizing**: `GameData\Bin\HQ_Bloomberg.log` (append-only, per-session markers) held the entire boot narrative (reporter dials, connect fails, UnInit) and the session-history classification (breport=crash / UnInit=clean exit / neither=wedged). Check for engine-side logs FIRST in any "silent exit" investigation.
- **Validate URL→disk mappings against the actual tree**: lobby URL prefix `/gamedata/*` maps to `GameData\DATA\*` — a 404 on the UI page killed the CEF at +10s and the whole engine at +19s. A 200-check of the exact first-requested URL is a mandatory step after starting any webserver for the target.
- **Killing a listener on http.sys by "OwningProcess" kills nothing** (it reports PID 4/SYSTEM; Stop-Process silently fails) — kill the serving process by CommandLine match (Get-CimInstance Win32_Process), and note multiple HttpListeners can coexist on the same prefix with the OLD one still answering.
- **Return-address emulation in UBX-packed code is untrustworthy**: a `pop;pop;pop;ret` tail found by pattern-scan may belong to a NEIGHBOR function (new prologues hide in between; real tails jmp into UBX0). Wrong ret → wild jump → agent wedge (events stop, runner hangs in detach, game survives as windowless zombie). Prefer register-redirect-to-sandbox + let the function run naturally; fault-based REG_FIXES (fix reg at the fault, retry insn) is the bulletproof layer.
- **PlausibleHeap-style range checks don't catch valid-looking garbage** (points at unmapped/freed pages) — readability probes (`readByteArray` try/catch) or fault-based fixes do.
- **FOLVAL_SCRIPT_ENV does NOT reach attach-mode scripts** (it's set in the spawned process env; the attach target's env is untouched) — attach probes must use their own defaults or a different channel; spawn-composed probes get it fine.
- **The engine's first gameserver dial is ~+90-100s, not ~+12s** (the 12s figure was certpatch's historical delay, not the dial time). Respawned engine instances (CEF watchdog) carry NO certpatch — a cert-abort dial at ~+100s is the RESPAWN, not the primary instance.
- **pkill self-match strikes again**: bracket-trick ALL patterns (`[f]rida-venv/bin/python`), or the shell kills its own pipeline (exit 143, no output).
- WinRM one-shot `powershell -File server.ps1` runs the server FOREGROUND — the call "times out" while the server lives in that session (reaped at session end). uiweb80 survived because the timed-out session's reaping lagged/persisted — always re-verify listeners after WinRM "timeouts".
