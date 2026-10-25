# Development Plan — Automated RE & Network Interception Environment

**Project codename:** `folly-n-valor` (Go module: `github.com/maxja/folval/server`)
**Execution rule:** Sequential phases only; explicit verification gates; any unclear parameter or unexpected error halts execution and triggers a user question. No guessing, no bypassing gates.

## Overview

An isolated, reproducible QEMU/KVM lab on this Linux host: a Windows LTSC guest (192.168.100.10) provisioned via Vagrant/libvirt, locked behind a host-side nftables firewall that permits contact **only** with a local mock gateway (192.168.100.1). The mock gateway (Go, `server/`) performs DNS interception, traffic logging, and — since the working Phase 5 — serves reimplemented game-backend endpoints over TLS. Frida instruments targets inside the guest; extracted binaries/dumps flow to the host for analysis.

## Current Reality (refreshed 2026-10-23)

- All directive phases (0–5) are COMPLETE; build/deployment records: `HISTORY.md`. Working-phase status: `PROGRESS.md` (currently working Phase 5 — gateway endpoint reimplementation).
- The lab boots with `./lab.sh vm:up` (~2.5 min); WinRM + qemu-ga scripting both live (`host/tools/guest-run.sh`, `guest-winrm.sh`); gateway modes via `./lab.sh gateway:{run,oracle,gameserver,status,stop}`.
- The game is installed in-guest (Steam, offline mode, D5 window closed & re-verified hermetic). It runs to its network layer under the gpu_shim; its wire vocabulary to the Gameserver is decrypted and recorded (D9), and folval-gw now serves those routes itself.
- Current frontier: the new-player funnel is decoded end-to-end (login → castle buy → hero → tutorial attack); the attack flow parks on a **server-side castle-content gap** (oracle ships no Castle_* data — the client has nothing to load), and rendering crawls on WARP (~9 fps) — Phase 5b (GPU passthrough) is prioritized to fix the render side before the content side.
- Guest clock/TZ, cert trust (certpatch), overlay neutralization, and the local :80 UI webserver are all durable solved problems — see the Engine section of `.ai-memory/misconceptions.md` (active).

## Project Definition

- **Core Vision:** One-command, verifiable provisioning of a hermetic Windows RE lab where all guest egress is intercepted by an operator-controlled gateway, dynamic instrumentation is pre-loaded, and static-analysis artifacts flow to the host — aimed at a compatible private game server (D9).
- **Key constraints:** Linux host (Fedora) with QEMU/KVM + vagrant-libvirt; Windows guest (LTSC) via WinRM communicator; guest has **no internet access ever** — all guest-bound artifacts are fetched host-side and pushed in; user holds a valid Windows LTSC license.
- **Tech stack:** Vagrant + vagrant-libvirt, libvirt/QEMU (KVM), nftables, Go mock gateway, PowerShell provisioners, Frida, Wireshark/tshark, py-minidump/capstone.

## Decisions — final states (full reasoning & execution history: `HISTORY.md`)

- **D0 — Execution host: agent-driven via libvirt socket** (container mounts host libvirt sockets; no sudo for the agent — user runs privileged steps; agent generates nftables rules, user applies).
- **D1 — LTSC image: Packer build from the user's official ISO + license.** EnterpriseS (non-IoT) edition; key enters via windowsPE `UserData/ProductKey` at build time, resolved from 1Password (`op read`), never in tracked files. Media hashes & the dual-edition ISO saga: HISTORY.
- **D2 — Guest sequencing:** Windows LTSC from Phase 1; no staging VM.
- **D3 — TLS interception: Frida-based extraction** (gateway never terminates TLS *for capture*; pinned TLS fails by design at the boundary). Superseded in practice by the D9 oracle pattern (in-guest reference server + SSLKEYLOGFILE + certpatch) for plaintext — see HISTORY.
- **D4 — Build wiring: W1 agent-driven** (op desktop-app integration; rendered unattend trap-deleted).
- **D5 — Game acquisition: steamcmd + one-time audited online window** — EXECUTED and CLOSED 2026-10-17 (deviations & snapshots: HISTORY). Title identity never in tracked files.
- **D6 — Debloat: quiet-guest only** (noise reduction for DNS/pcap/traces); host nftables is the sole enforcement boundary; guest firewall stays vanilla so egress attempts stay visible on the wire.
- **D7 — Phase 4b strategy: Option B, pure Frida RE** (resolved 2026-10-18); the third-party reference (gitignored `tmp/`, MIT) is an unverified-hints oracle/tape-recorder only — never ported into the deliverable.
- **D8 — D3D9 wall: RESOLVED via CreateDevice arg bisect** (2026-10-19) — no translation layer or GPU passthrough needed; quirk set lives in misconceptions (active).
- **D9 — Endgame intent: redirectable client + replacement launcher + public server ecosystem** (2026-10-19).
  1. Client redirect needs NO binary mod — backend endpoint is a launch argument; gateway per-host DNS overrides are a second mechanism.
  2. Client-mod ladder only where forced: Frida hooks (proven) → cert-shim DLL at launch (mandatory: engine TLS trust is compiled into the packed exe) → binary patch last resort. CEF UI is the soft target for in-game work.
  3. Public servers must define their own credentials (official backend dead — no genuine handshake to replay). **Scope guard:** non-commercial/educational license; *operating* public servers for third parties needs an explicit future decision (distinct legal exposure). Does not gate lab work.
- **D10 — GPU acceleration: VFIO passthrough, iGPU-primary / 3090-fallback (2026-10-25, user decision).** WARP software rendering (~9 fps steady) throttles the lab; virtio-gpu/virgl/venus rejected (no Windows-guest D3D9). **Radeon 610M (0000:10:00.0, clean IOMMU group) passes to the guest as render adapter — host display stays on the 3090 untouched**; 3090 remains the escalation path if the 610M underdelivers for this 2013 D3D9 title. Guest RAM 4→6G (UMA carve). Adrenalin staged offline via `/push/`. Phase 5b in DEVELOPMENT_PLAN holds the gated step list.

## Phase status

Directive phases 0–5 (host env, vagrant/libvirt, network+gateway, provision+debloat, Frida, shared workspace): **all COMPLETE** — records in `HISTORY.md`. Directive Phase 5 (Samba/Ghidra workspace) is implemented only in part and largely superseded by the `/push/` + `guest-pull.sh` transports; the share is not currently running.

Working phases (post-directive, tracked in `PROGRESS.md`):
- **Phase 4a** — Frida injection layer — COMPLETE (2026-10-17).
- **Phase 4b** — session-1 instrumentation + game boot — COMPLETE (2026-10-19).
- **Phase 5 (working)** — gateway endpoint reimplementation — IN PROGRESS (gameserver routes live; new-player funnel decoded, 8/14 endpoints captured; attack flow blocked on oracle castle-content gap — see PROGRESS session 6).
- **Phase 5b (working)** — **GPU acceleration via VFIO passthrough — PRIORITIZED (2026-10-25, user decision)**; rationale + steps below. Entered because WARP software rendering (~9 fps steady) throttles every protocol-mining run and spawned the whole VA/'NULL'-FOURCC/lifeboat workaround family.

### Phase 5b — VFIO GPU passthrough (iGPU-primary; 3090 = escalation fallback)

Feasibility verified 2026-10-25: host Ryzen 9 7900X, RTX 3090 at 01:00.0/.1 (clean IOMMU group 12, drives host display), **Radeon 610M iGPU at 0000:10:00.0 (1002:164e, IOMMU group 26 solo — CHOSEN: zero host-display disruption)**; bus-10 siblings (PSP 10:00.2, xHCI 10:00.3/.4, audio) stay on host. Rejected: virtio-gpu/viogpudo (2D-only), VirGL/Venus (Linux guests only), experimental virgl WDDM (no D3D9).

State: domain redefined 2026-10-25 (hostdev 10:00.0 → guest slot 00:08.0, 8 vCPU host-passthrough, 6G RAM, kvm-hidden + vendor_id); awaiting host-side vfio bind (user: `/etc/modprobe.d/vfio.conf` ids=1002:164e + softdep amdgpu + dracut + reboot) and offline Adrenalin staging via `/push/` (AMD CDN rejects scripted fetch — browser step).

Steps (each gated):
1. **Host vfio bind (user-assisted, privileged):** done-flag = `lspci -nnk -s 10:00.0` → `Kernel driver in use: vfio-pci`; host display unaffected (3090).
2. **Boot + enumeration:** domain start; guest Device Manager shows unknown VGA at the passed slot (no Code 43 expected — AMD). *Validate:* WinRM up; PCI device present in-guest.
3. **Driver staging (offline guest):** Adrenalin (Radeon 610M / Ryzen 7000, Win10 x64, ~1GB) via gateway `/push/` → silent install (setup flags or INF+pnputil extraction). *Validate:* dxdiag → Radeon 610M, D3D9 accel enabled.
4. **gpu_shim adapter redirection:** force game CreateDevice onto the 610M adapter index (enumerate via GetAdapterIdentifier, match 1002:164e) while desktop stays std-VGA/VNC. *Validate:* d3d9dev log shows real-GPU caps; game renders (shot.js PNG).
5. **Re-baseline + quirk teardown:** FPS-meter run vs leg A (~9 fps WARP, 2026-10-25); then re-test WITHOUT fmtswap/valifeboat/INTZ quirks. *Validate:* ≥10× FPS lift or vsync-capped; full funnel run at interactive speed; document retired quirks.
6. **Escalation (only if 610M underdelivers):** same rework for the 3090 (cable move + 10de:2204,1aef vfio ids + OVMF/mbr2gpt risk note).

## Cross-Phase Rules

- Gates are hard: no Phase N+1 work begins until Phase N verification output is captured and passes.
- Any unexpected error, ambiguous parameter, or directive/reality mismatch → stop, log, ask.
- Every such event is recorded in `.ai-memory/misconceptions.md` immediately (tool → misconception → correction); historical log in its archive sibling.
- Guest never gets internet: any artifact the guest needs is fetched host-side and pushed.
- Identity policy: title identity (names/hosts/ids) never lands in tracked files — self-scan (`git add -A && git grep --cached -iE "<terms>"`) before EVERY commit; terms live only in the gitignored handoff.

## Risk Register (open items only; resolved ones in HISTORY)

| Risk | Mitigation |
|---|---|
| Agent has no sudo / no CAP_NET_ADMIN | User runs privileged steps (package installs, nftables apply); agent verifies afterwards |
| LTSC licensing violation | User-supplied ISO + key; key never in git/chat |
| SMB mount quirks (if the share is revived) | Idempotent `net use` with retry; /push/ + guest-pull as standing fallback |
| Public-server legal exposure | D9 scope guard: explicit follow-up decision before any third-party operation |

## Target Directory Layout

```
folly-n-valor/
├── Vagrantfile              # domain definition (libvirt, isolated net, vga video)
├── lab.sh                   # orchestrator: build/vm/gateway/steam/evidence tasks
├── packer/                  # LTSC box build (template, answer files, isos/ gitignored)
├── host/
│   ├── firewall/            # folval.nft + apply script
│   ├── capture/             # tcpdump ring unit on the bridge
│   ├── d5/                  # acquisition-window scripts
│   ├── selinux/             # folval-pcap.te (project-local pcaps)
│   ├── steamcmd/            # gitignored steamcmd + steam.env
│   ├── push/                # staging dir served by the gateway under /push/
│   └── tools/               # durable host-side tooling (guest-run/winrm/pull/push, frida-run, ui-start, ...)
├── server/                  # folval-gw (Go): DNS sinkhole, HTTP, probes, forward, gameserver
├── vm/                      # guest-side scripts (setup_frida, uiweb80, oracle-*, probe-*, ...)
├── re/
│   ├── docs/                # DEVELOPMENT_PLAN, PROGRESS, HISTORY, ARTIFACTS
│   └── frida/               # hook scripts (phase4b/, ...)
├── captures/pcap/           # bridge ring captures
├── out/                     # run-scoped probe evidence (JSONL; .keep keepers; gitignored)
├── logs/                    # gateway.jsonl etc. (disposable)
└── .ai-memory/              # misconceptions.md (active, tracked) + archive (tracked); handoff.md (gitignored)
```
