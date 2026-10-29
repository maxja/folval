# VMware Provider — Design & Host Reference (Phase 5c, branch `feat/vmware-provider`)

Status: decisions locked 2026-10-26 (see `PROGRESS.md`, D-VM). Current step: interfaces.
Goal: a second, opt-in provider that gives the guest a **real DX9 device** via VMware's
host-GL 3D translation — replacing the WARP path (~9 fps, fmtswap texture corruption)
without VFIO/passthrough complexity. Success bar: ~30 fps with fewer/no gpu_shim
artifacts, proven on **Fedora at minimum**, then a switch-over decision vs Phase 5b.

## Positioning

- **Parallel** to Phase 5b (VFIO iGPU passthrough). Whichever lane reaches interactive
  fps first wins; the other is retired or kept as fallback. Nothing in the qemu/libvirt
  lab changes: libvirt stays the default provider with its own `.vagrant` state.
- Targets:
  - **Primary:** Fedora x86_64 + Workstation Pro + **Windows 11 x64** guest (native x86 client).
  - **Stretch:** Mac M3 + Fusion + **Windows 11 ARM64** guest (client runs under
    Microsoft's x86-on-ARM emulation + Fusion DX translation — double translation;
    fps target uncertain there; protocol mining and Frida work expected to stay on x64).

## Decision summary (user-approved 2026-10-26)

1. Fresh Packer builds — NO conversion of the existing Win10 LTSC qcow2.
2. Provider UX: `./lab.sh -p vmware` primary; `FOLVAL_PROVIDER` env fallback; default
   `libvirt`. Per-provider `.vagrant` dirs (`.vagrant-libvirt` / `.vagrant-vmware`) so
   both labs coexist on one checkout.
3. Milestone gate: packer build → box add → `vm:up` → WinRM verify → dxdiag shows 3D
   accel → fps-meter client launch → quirk-teardown A/B (retire fmtswap/INTZ/lifeboat
   hacks on a real DX9 device).
4. User inputs: Win11 x64 + ARM64 ISOs (gitignored dir, e.g. `packer/iso/`), Windows
   product keys via the 1Password pattern (never in repo/chat), host installs below.
5. macOS: NO PF/nftables port-redirect needed (Phase-5 flow uses
   `-server_url https://<host>:8443`; the Linux DNAT exists only for the sealed-guest
   canonical-:443 path) and NO persistent sudo (one-time admin actions only).

### Version selection (13.6.x/17.6.x vs 25H2/26H1)

The desktop hypervisors exist on two versioning schemes: **classic** (Fusion 13.6.x,
Workstation 17.6.x — 13.6.4 / 17.6.x are the final classic releases) and **calendar**
(25H2, 26H1 — Broadcom's newer year-half line; same products, newer branch).
Pick rule, in order:
1. **Host OS support decides first** — Fusion is tightly bound to macOS versions;
   a newer macOS may only be supported by the calendar line.
2. **Vagrant pairing** — install the Vagrant VMware Utility version matched to the
   chosen hypervisor (HashiCorp's vagrant-vmware-desktop docs list the matrix);
   mismatch = "Fusion UI works, `vagrant up` can't reach vmnet".
3. Otherwise newest first (26H1 → 25H2 → classic fallback). Guest features this lab
   needs (Win11 ARM64, vTPM/encryption, 3D) exist on both lines.

## Host install — Fedora x86_64 (Workstation Pro)

Not in dnf repos — direct download from Broadcom (free account):

1. `support.broadcom.com` → register/login → Downloads → VMware Cloud Foundation
   → "VMware Workstation Pro" node → newest release per the pick rule above
   (classic `17.6.x` vs calendar `25H2`/`26H1`) → download the `.bundle`.
2. Deps + install:
   ```bash
   sudo dnf install -y kernel-devel-$(uname -r) kernel-headers gcc make
   chmod +x VMware-Workstation-*.bundle
   sudo ./VMware-Workstation-*.bundle --console --required --eulas-agreed
   sudo vmware-modconfig --console --install-all   # builds vmmon + vmnet
   lsmod | grep -E 'vmmon|vmnet'                   # verify
   ```
   - Re-run `vmware-modconfig` after every kernel update.
   - Secure Boot enabled → sign the modules via MOK enrollment, or disable SB.
3. Vagrant + plugin:
   ```bash
   sudo dnf install -y dnf-plugins-core
   sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
   sudo dnf install -y vagrant
   vagrant plugin install vagrant-vmware-desktop
   ```
4. Workstation Pro is free for all use — no VMware license key to enter.

## Host install — macOS M3 (Fusion)

Not on Homebrew (cask removed after Broadcom's login-gated downloads) — direct download:

1. `support.broadcom.com` → "VMware Fusion" node → newest release per the pick rule
   above → universal `.dmg` → install like any app.
2. Tools via brew: `brew install hashicorp/tap/hashicorp-vagrant hashicorp/tap/packer`.
3. `vagrant plugin install vagrant-vmware-desktop`.
4. First `vagrant up` downloads the **Vagrant VMware Utility** — a one-time privileged
   helper PKG (admin password once). This daemon creates/manages host-only vmnets for
   `private_network`, so no manual vmnet editing and no persistent sudo anywhere.
5. Fusion is free — no license key needed.

## Network plan (isolation contract preserved)

- Same subnet contract as the libvirt lab: **192.168.100.0/24**, guest `.10`,
  host `.1`, guest never gets internet.
- VMware `private_network` ⇒ host-only vmnet: no NAT, no forwarding. Unlike the
  libvirt setup, a vmnet-scoped DHCP service exists but only serves that host-only
  network — isolation contract unaffected (static IP pinned on the guest NIC).
- Host-side firewall: Fedora keeps the existing nftables service (interface
  parameterization for the vmware vnic is an open implementation detail). macOS needs
  nothing: gateway binds :8443 on the vmnet host address directly.
- Gateway `/push/` + `guest-pull` transports are provider-agnostic (plain TCP/HTTP
  over the host-only network) — expected to work unchanged.

## VM spec (vmx-level contract, both platforms)

- 8 GB RAM, 8 vCPU, EFI firmware, **hardware version 21**.
- **3D**: `mks.enable3d = TRUE`, `svga.vramSize` ≥ 256 MB.
- **Win11 requirements**: vTPM + Secure Boot via VM encryption
  ("encrypt only the files needed for TPM" mode — keeps the `.vmx` plaintext so the
  vagrant plugin can manage it). Fusion auto-add option: `managedVM.autoAddVTPM`.
- **VMware Tools in the guest is mandatory** — the 3D/DX9 WDDM display driver ships
  with Tools, not with the hypervisor. Packer installs it during the build.
- Box naming: `folval/win11-x64-vmware`, `folval/win11-arm64-vmware`.

## Packer plan

- Two new builders (separate `packer/*.pkr.hcl`), both `vmware-iso`
  (packer-plugin-vmware), reusing `packer/answer/` unattend patterns + `vm/debloat.ps1`:
  - `windows11-x64-vmware.pkr.hcl` — builds on Fedora.
  - `windows11-arm64-vmware.pkr.hcl` — builds on the Mac (Packer via brew).
- ISOs stay in a gitignored `packer/iso/`; keys injected at build time from the
  1Password flow (same discipline as the current build).

## Milestones (each gated, per Cross-Phase Rules)

- **M0 — host prereqs (user):** Workstation + Fedora modules verified; Fusion +
  utility helper on the Mac; vagrant + `vagrant-vmware-desktop` plugin on both.
- **M1 — x64 image:** `lab.sh -p vmware vm:build` produces the Win11 x64 box.
- **M2 — lab up:** `vm:up` / `vm:verify` green on vmware_desktop (WinRM round-trip,
  isolated net, gateway reachability from guest).
- **M3 — 3D verdict:** dxdiag shows VMware SVGA 3D + D3D9 accel; fps-meter client
  launch vs the ~9 fps WARP baseline; report artifact deltas (gpu_shim quirks needed?).
- **M4 — decision:** quirk-teardown A/B at interactive fps → switch-over decision
  (VMware replaces WARP path; Phase 5b continue-or-shelve call). ARM64/Mac lane
  attempted only after x64 proves the design.

## Risks / caveats

- ARM64 guest runs the x86 client under OS emulation — double translation; fps target
  uncertain, Frida-on-emulated-x64 dicey. Fedora x64 is the proof target.
- Win11 + vTPM forces VM encryption; keep it "TPM-files-only" or the vagrant plugin's
  vmx management breaks (verify during M1).
- Windows activation on new virtual hardware: fresh builds + user keys sidestep it,
  but first-boot activation state must be checked in M2.
- The client's anti-tamper/CRC under VMware SVGA is unproven — treat the first M3
  launch as an experiment (console/VNC eyes, expect the modal-box trap).
- Snapshot semantics differ from qcow2 internal snapshots (Vagrant/VMware snapshots);
  provider shim must keep `vm:snapshot` / `vm:snapshot-rollback` semantics identical.
- SELinux (Fedora) may need exceptions for the vmx/3D path — log any avc denials.
- Identity policy applies as always: no game/host/title identities in this file or
  any commit; self-scan before committing.
