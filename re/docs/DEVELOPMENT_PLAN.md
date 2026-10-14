# Development Plan — Automated RE & Network Interception Environment

**Project codename:** `folly-n-valor` (Go module: `github.com/maxja/folval/server`)
**Status:** Phase 0 COMPLETE (2026-10-10). **Phase 1 COMPLETE (2026-10-12 22:36)** — gate passed: `vagrant up` boots the guest in ~2.5 min, WinRM round-trip ok, domain `folly-n-valor_default` running on `re-isolated-net` only (single virtio NIC, no mgmt attachment). Path to the gate: attempt 8 (2026-10-11) proved the unattended install; the static-IP rebuild landed 2026-10-12 19:22 (folval-static-ip ONSTART task + qemu-ga baked in); first `up` (21:09) failed on box metadata `virtual_size: 10` for a 60 GiB image (`package-box.sh` read the `children[].file` `virtual-size` from `qemu-img info --output=json` — fixed, repackaged, stale pool volumes purged); second `up` (22:29) failed at 61 s because `config.winrm.timeout = 60` capped the WinRM `ready?` probe and killed the boot wait (line removed — default 1800); third `up` (22:33) passed. Windows is in `Notification 0xC004F034` activation state — VOLUME_MAK key applied (EnterpriseS, correct non-IoT edition) but cannot reach the clearing house in the hermetic lab; expected, not a blocker. Next: Phase 2 (network isolation + mock gateway). Decisions D0–D4 recorded 2026-10-10 (D4 revised 2026-10-11); D5 (target game acquisition) pending, D6 (debloat scope) recorded 2026-10-12.
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

## Project Definition

- **Core Vision:** One-command, verifiable provisioning of a hermetic Windows RE lab where all guest egress is intercepted by an operator-controlled gateway, dynamic instrumentation is pre-loaded, and static-analysis artifacts flow to the host.
- **Key constraints:** Linux host (Fedora kernel 7.2.8-300) with QEMU/KVM + vagrant-libvirt; Windows guest (LTSC, x64) via WinRM communicator; guest has **no internet access ever** — all guest-bound artifacts (frida-server, Python, drivers) must be downloaded host-side and pushed in; user must hold a valid Windows LTSC license.
- **Tech stack:** Vagrant + vagrant-libvirt, libvirt/QEMU (KVM), nftables, Go mock gateway, PowerShell provisioners, Frida, Samba share, Ghidra (host-side).

## Decisions (D0–D4 recorded 2026-10-10; D5–D6 recorded 2026-10-12)

**D0 — Execution host: Option A (agent-driven via libvirt socket).** Post-decision verification: the container already mounts the host's libvirt sockets and unsandboxed `virsh -c qemu+unix:///system` works (libvirt 12.6.0 / QEMU 11.1.2, KVM present). QEMU runs on the host, so no `/dev/kvm` passthrough or container recreation is needed. Standing gaps: agent shell has no sudo (package installs are user-run); container lacks CAP_NET_ADMIN (agent generates nftables rules, user applies them on the host).

**D1 — LTSC image source: Option A (Packer build from user-provided official ISO + license).** Media staged 2026-10-10: `packer/isos/en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso` (4,899,461,120 bytes; SHA-256 `c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d`; UDF label `CES_X64FREV_EN-US_DV9`; `sources/install.wim` present, no `install.esd`/`install_MultiEdition.esd`; WIM enumerated 2026-10-10: **2 images** — Index 1 `Windows 10 Enterprise LTSC 2021` (EditionID `EnterpriseS`, x86_64, en-US, build 19041 SP-build 1288) and Index 2 `Windows 10 Enterprise N LTSC 2021`; install selects **Index 1 by name** — exact match for the non-IoT license). Filename matches official MVS naming; **Media update 2026-10-11:** user staged `packer/isos/en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso` (4.6 GB, SHA-256 `a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160`) — despite the filename it is **dual-edition**: Index 1 `Windows 10 Enterprise LTSC 2021` (`EnterpriseS`, non-IoT — build target, matches the license) and Index 2 `Windows 10 IoT Enterprise LTSC 2021` (`IoTEnterpriseS`). This is now the build media (`iso_path`); Index 2 is the fallback if the user's key turns out to be IoT-channel (suspected cause of the earlier specialize ProductKey rejection on non-IoT media). The previous `d289cf96` ISO (LTSC + LTSC-N) remains in `packer/isos/` as backup. **D1 hard gate:** prior media's hash cross-check passed 2026-10-10 (SHA-256 `c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d`, MD5 `b5a7be560dbd73619945129e52be1b5f` user-confirmed). Fallback source approved: uupdump.net with edition exactly "Windows 10 Enterprise LTSC 2021" (consumer 21H2 chains have no LTSC edition), options: Include updates ✓, .NET 3.5 ✓, component cleanup ✗, ESD compression ✗; massgrave.dev rejected as an ISO source. License: 1Password `op://DevOPS/Windows 10 Enterprise LTSC 21H2/license key` — non-IoT Windows 10 Enterprise LTSC 2021 (item label "21H2" = same product, build 19044 family), 29-char key validated by user (`wc -c` = 30 incl. newline). `pkvars.hcl` deleted by user (`packer/vars/` empty) — key resolution: `build.sh` consumes `PKR_VAR_windows_license_key` or `FOLVAL_OP_REF` from env / gitignored `packer/op-ref.env` (reference only, never the key); no op URI in tracked files, per D4. Recommended SKU stands: Windows 10 Enterprise LTSC 2021 x64 (no TPM/SecureBoot requirement; Windows 11 LTSC 2024 would add vTPM/OVMF constraints).

**D2 — Guest sequencing: Option A (Windows LTSC from Phase 1).** Phase 2 verification executes from the Windows guest; no staging VM.

**D3 — TLS interception: Option A (Frida-based extraction).** The gateway never terminates TLS; guest port 443 is not whitelisted — pinned TLS fails by design, pushing traffic analysis to Frida hooks in Phase 4. Revisit only if Phase 4 results demand it.

**D4 — Build execution wiring (2026-10-10): W1 agent-driven preferred, W2 fallback.** Environment audit: this shell runs as host uid 1000 (SELinux unconfined) with `/usr/bin/op`, `~/.local/bin/packer`, `qemu-system-x86_64`, `wimlib-imagex`, and world-writable `/dev/kvm` — the agent can run the full Packer build with KVM acceleration locally. `op read` works from this shell via 1Password desktop-app integration (GUI approval per use; `op whoami` misleadingly reports "not signed in"). **Revision (2026-10-10, later): the license key is NOT part of the build at all** — unattend ProductKey values caused the specialize pass to fail ("value outside the range of acceptable values"; interpolation and key shape forensically ruled out). Key application moved to Phase 3: `slmgr /ipk` over WinRM (key resolved from 1Password at provision time via `op-ref.env`/env, never in tracked files), with manual OOBE entry as the fallback during builds. Either way the key never appears in repo, logs, or chat. **Revision 2 (2026-10-11): key returned to the build — keyless installs on this media are fatal ("Windows cannot read the ProductKey setting").** Working placement: windowsPE `UserData/ProductKey` with `WillShowUI=OnError` (manual VNC entry as fallback), rendered at build time by `build.sh` from `answer/Autounattend.xml.in` (token `__FOLVAL_WIN_KEY__`, `op read` → sed; rendered file is trap-deleted and gitignored). Attempt 4 verified: "Valid product key in blackboard", no VNC prompt, specialize pass parsed and applied cleanly. Attempt 4 subsequently failed at the oobeSystem pass parse — cause: nonexistent setting `HideOnlineActivationScreens` (removed; OOBE block trimmed to schema-certain settings). Evidence: setupact.log via virt-cat; cached `C:\Windows\Panther\unattend.xml` is key-free (setup scrubs it).

**D5 — Target game acquisition: PENDING (recorded 2026-10-12).** The target is a Steam-distributed client–server title (the client is played against the server this project recreates; title/app-id intentionally not recorded in repo docs). User assessment: probably Steam-DRM'd. Unknowns: DRM-free build availability, whether official servers still run, and the client's endpoint/protocol profile — the last one settles the D3 interplay (with no 443 whitelist and no TLS termination, an HTTPS-only client cannot reach the gateway until Phase 4 Frida work or a D3 revision). Leading option: **one-time audited online window**, sequenced after Phase 3 — temporarily attach the NAT'd `default` libvirt network as a second NIC, install Steam and log in once, install the game (restore a Steam backup made on the user's real PC, or full download), launch once online to clear any first-run Steam initialization, switch Steam to offline mode, detach the NIC, re-run the Phase 2 isolation gate, and record the window in the phase log as a documented exception to "guest never gets internet". Snapshots before/after the window (verify `vagrant snapshot` support in vagrant-libvirt, else `virsh snapshot-create-as`). Fallback if a DRM-free build exists: plain push via WinRM/Samba, no online window at all. Decision deferred to the Phase 3/4 boundary.

**D6 — Debloat scope: quiet guest only (decided 2026-10-12).** In a hermetic lab, telemetry cannot phone home regardless (Phase 2 drops all egress), so debloat-for-privacy is pointless; heavy debloat also diverges the guest from a realistic client environment. Kept: a minimal quiet-guest provisioner (`vm/debloat.ps1`) — DiagTrack, dmwappushservice, telemetry scheduled tasks off, telemetry=Security, WU service off, SMB1 off (retained from the directive; harmless here) — its purpose is cutting noise in DNS logs, pcaps, and Frida traces, not security. Dropped: the guest-side default-deny outbound firewall and its whitelist from the original Phase 3 — host nftables is the sole enforcement boundary, and guest-side blocking would hide egress attempts from the wire, destroying the exact research signal (what the client tries to contact). Guest stays otherwise vanilla.

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

### Phase 2 — Network Isolation & Mock Gateway (directive Phase 2)

- **Goal:** Guest can reach *only* 192.168.100.1, and only the services the mock gateway offers; all transit traffic captured.
- **Dependencies:** Phase 1 verified.
- **Deliverables:** `host/firewall/` — nftables ruleset + idempotent apply script + persistence unit: input from bridge accepts DNS (udp/tcp 53) and HTTP (tcp 80) to .1, plus host WinRM from .10 only; everything else from 192.168.100.0/24 dropped — port 443 deliberately not whitelisted per D3; forward chain drops any traffic with iif/oif the bridge. `server/` — Go gateway `folval-gw`: DNS sinkhole (all A answers → 192.168.100.1, per-host overrides file, full query log), HTTP echo/logger; static guest IP (no DHCP → no dnsmasq port-53 conflict). `host/capture/` — tcpdump unit on the bridge writing `captures/pcap/`. Ruleset is generated by the agent; user applies it on the host (container has no CAP_NET_ADMIN).
- **Verification (from Windows guest):** `ping 8.8.8.8` times out / 100% loss; `ping 192.168.100.1` succeeds; `Resolve-DnsName example.com -Server 192.168.100.1` returns 192.168.100.1 (sinkhole) and the query appears in the gateway log and pcap; host `nft list table folval` shows the active ruleset.

### Phase 3 — Windows LTSC Provision & Debloat (directive Phase 3)

- **Goal:** Quiet, low-telemetry-noise guest. Enforcement stays at the host boundary — no guest-side egress control (D6).
- **Dependencies:** Phase 2 verified (no accidental internet exposure during provisioning).
- **Deliverables (revised by D6, 2026-10-12):** `vm/debloat.ps1` — quiet-guest scope only: disable DiagTrack + dmwappushservice + telemetry-scheduled tasks, set telemetry to Security, disable SMB1, disable the Windows Update service. **No guest-side outbound firewall policy** — the guest firewall stays vanilla: host nftables (Phase 2) is the sole enforcement boundary, and guest-side blocking would hide egress attempts from the wire, losing the research signal. All provisioning over WinRM; no guest internet assumed.
- **Verification (Windows guest):** `Get-Service DiagTrack` is Disabled; `Get-Service wuauserv` is Disabled; `Get-NetFirewallProfile | Select Name,DefaultOutboundAction` shows the vanilla default (Allow — proof no guest-side blocking was applied); negative test of the host boundary from inside the guest: `Test-NetConnection 192.168.100.1 -Port 8080` fails (dropped by host nftables, not by the guest).

### Phase 4 — Frida Injection & Instrumentation (directive Phase 4)

- **Goal:** Working instrumentation handshake against arbitrary guest processes.
- **Dependencies:** Phase 3 verified.
- **Deliverables:** `vm/setup_frida.ps1`: installs guest Python 3 (offline installer pushed from host — guest has no internet), installs `frida-server-<ver>-windows-x86_64` (host-downloaded, version-pinned to match host `frida-tools`), registers it as a Windows service (SYSTEM, autostart), firewall whitelist for host frida client (tcp 27042 from 192.168.100.1 only). Hook scripts in `re/frida/` pushed to `C:\re\frida\`. Host: `pipx install frida-tools==<matching>`.
- **Verification:** Note — the directive's `frida -p <PID> --version` is invalid CLI usage (`--version` prints and exits; it never attaches). Correct gate: start `notepad.exe` in guest, then from host `frida -H 192.168.100.10 -p <PID> -q -e "console.log(Process.arch)"` prints `x64`, and a test hook from `re/frida/` (module enumeration on notepad) loads without error.

### Phase 5 — Shared Workspace for Ghidra (directive Phase 5)

- **Goal:** Guest-extracted binaries, DLLs, and memory dumps land on host for Ghidra.
- **Dependencies:** Phase 3 verified (guest stable, share mountable); Samba from Phase 0.
- **Deliverables:** Host Samba share bound to the bridge IP only (`\\192.168.100.1\re`), guest maps `Z:` via provisioner. Deviation from directive, documented: vagrant-libvirt provides no native synced-folder mechanism for Windows guests (no virtiofs/9p), so `config.vm.synced_folder` is declared `disabled: true` and the Samba mount implements the same contract; fallback attempt of Vagrant `type: "smb"` recorded during execution. Ghidra itself runs on the host against `re/ghidra/` project files.
- **Verification:** `echo probe > re/ghidra/probe.txt` on host; `Get-Content Z:\ghidra\probe.txt` in guest succeeds within seconds; reverse direction: file written in guest appears on host.

## Cross-Phase Rules

- Gates are hard: no Phase N+1 work begins until Phase N verification output is captured (in `re/docs/` phase log) and passes.
- Any unexpected error, ambiguous parameter, or directive/reality mismatch → stop, log, ask.
- Every such event is recorded in `.ai-memory/misconceptions.md` immediately (tool → misconception → correction).
- Guest never gets internet: any artifact the guest needs is fetched host-side and pushed (WinRM upload / share / disk).

## Risk Register

| Risk | Phase | Mitigation |
|---|---|---|
| Agent has no sudo | 0+ | User runs package installs; agent verifies afterwards |
| ~~Vagrant 2.3.4 vs latest vagrant-libvirt plugin~~ | 0 | Resolved: Fedora ships tested pair (plugin 0.11.2, system) |
| `op` binary present, session not signed in | 1 | W1: user runs `op signin` once (verify persistence) or desktop-app integration; W2 fallback: user runs build wrapper — key never in repo/chat |
| LTSC licensing violation | 1 | D1: user-supplied ISO + key; key kept out of git and chat |
| ISO provenance unverified | 1 | MVS-style filename + UDF label consistent; SHA-256 computed — hard gate: cross-check against source page before build |
| Container lacks CAP_NET_ADMIN | 2 | Agent generates nftables rules + apply script; user applies on host; gate re-verifies |
| libvirt mgmt-network NAT leak | 1 | `mgmt_attach: false`, qemu-ga discovery; verify no second interface in guest |
| virtio driver missing during install | 1 | Packer driver injection (virtio-win ISO) |
| nft rules lost on reboot | 2 | Persistence unit; re-verify after host reboot in gate |
| dnsmasq/gateway port-53 conflict | 2 | Static IP, DHCP disabled on isolated net |
| frida client/server version skew | 4 | Both pinned to same release; gate checks handshake |
| SMB mount quirks in Windows guest | 5 | Provisioner idempotent `net use` with retry; fallback rsync-over-share staged |

## Target Directory Layout

```
folly-n-valor/
├── Vagrantfile              # Phase 1
├── lab.sh                   # orchestrator: build/add/up/verify/rebuild/license/down/destroy
├── packer/                  # Phase 1 (if Q1=A): template + answer files
├── host/
│   ├── firewall/            # Phase 2: folval.nft + apply script + unit
│   └── capture/             # Phase 2: tcpdump unit on bridge
├── server/                  # Phase 2: folval-gw (Go): DNS sinkhole, HTTP log
├── vm/                      # guest provisioners: debloat.ps1, setup_frida.ps1, ...
├── re/
│   ├── docs/                # this plan, phase logs, architecture notes
│   ├── frida/               # hook scripts pushed to guest
│   └── ghidra/              # host-side Ghidra projects + shared artifacts
├── captures/pcap/           # bridge captures
├── logs/                    # lab.sh run logs (build.log, up.log) — contents local-only
└── .ai-memory/              # misconceptions.md (tracked); handoff.md local-only (gitignored)
```

Dirs are created lazily when their phase's first artifact lands (decided 2026-10-12); `logs/` is the exception — created upfront because `lab.sh` writes there daily (structure preserved via `.gitkeep`, contents gitignored).
