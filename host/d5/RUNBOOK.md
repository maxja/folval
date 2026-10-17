# D5 Runbook — One-Time Audited Online Window (game acquisition)

Purpose: get the target title installed and DRM-initialized inside the
hermetic guest with exactly one audited online window, then re-seal and
re-verify. Identity-free by policy: the title and its app id are never
recorded in tracked files (plan decision D5); they live in
`host/steamcmd/steam.env` (gitignored) and in the operator's head.

Lessons baked into this procedure (2026-10-17 execution):

- **Do not stage content with host steamcmd into the guest.** The Steam
  client purges steamcmd-staged app content when a dependency app is absent
  from the staged set; even staging the dependency left the client
  re-validating against its own manifest. Reliable path: the in-guest Steam
  client installs the title itself during the window.
- **The Steam client cannot update against the sinkhole.** With the isolated
  NIC up, DNS resolves everything to 192.168.100.1 and the client hangs at
  "checking available updates" → "steam needs to be online to update". The
  window therefore disables the isolated NIC so the NAT NIC is the only
  egress. This is what makes the window auditable: only Steam client traffic,
  only via the NAT interface.
- **Single library.** A fresh client install puts new games in the PRIMARY
  library. Do not seed extra libraries; the staging-era `C:\SteamLibrary`
  seeding is retired.
- **Redists are mandatory and not auto-run.** A bare exe launch without them
  dies on MSVCR100.dll. Install from Steamworks Shared after the title
  install (`d5-redist-install.ps1` locates it under any library root).
- **Expect the launch to end at "querying available servers".** The title's
  backend is dead; that state is the expected terminal state of the one
  online launch and proves there is nothing further to initialize online.
  A GPU warning popup (WARP software rasterizer, no host GPU passthrough) is
  also expected — acknowledge and continue.
- **qemu-ga delivery survives NIC changes** (virtio-serial channel, not
  network): `guest-run.sh` keeps working with both NICs down/changed.

## Prerequisites

- Phase 2 boundary active: `systemctl status folval-firewall --no-pager`,
  `nft list table inet folval`; gateway running: `./lab.sh gateway:status`
  (start with `./lab.sh gateway:run`).
- `SteamSetup.exe` staged in `host/push/` (gitignored; fetched from
  steampowered.com outside the lab).
- Host steamcmd session (optional, only if a host-side depot copy is wanted
  as backup): `./lab.sh tools:steamcmd`, `./lab.sh steam:login`,
  `./lab.sh steam:download` — see `lab.sh` header.

## Procedure

### 1. Snapshot the pre-window state

    ./lab.sh vm:snapshot pre-steam-window

### 2. Attach the NAT NIC (host)

    virsh -c qemu:///system attach-interface --domain folly-n-valor_default --type network --source default --model virtio --live

(The guest may take a minute to bring the new adapter up; DHCP from the
default network assigns 192.122.1.x.)

### 3. Disable the isolated NIC (guest)

    bash host/tools/guest-run.sh host/d5/d5-net-window-on.ps1

Expected: `ISOLATED NIC DISABLED`. From here the guest's only egress is the
NAT NIC. Host-side nftables rules do not apply to that path — the audit
surface is the Steam client itself plus the pcap/tcpdump on virbr1 is NOT
seeing this traffic by design (capture stays on the isolated bridge).

### 4. Install the Steam client (guest, hermetic)

    bash host/tools/guest-run.sh host/d5/d5-steam-setup.ps1

Expected: `STEAM-SETUP DONE` with the sha256 of the installer printed.

### 5. Interactive session (USER — in virt-viewer/console)

- Log in to the Windows desktop, start Steam, log in with the account that
  owns the title (password + Steam Guard on phone).
- Let the client finish any self-update.
- Library → the title → Install (defaults to the primary library).
  If the download stalls (dependency app hiccup): pause/resume once; the
  client heals.
- When installed: run `d5-redist-install.ps1` (below) BEFORE first launch.
- First launch: acknowledge the GPU warning (if shown); get to the main
  menu / server-list state; the server list will not populate (dead
  backend — expected). Quit the game.
- Steam menu → Go Offline → let the client restart in offline mode.
- Confirm offline replay: launch the title once more from offline Steam,
  reach the menu, quit.
- Leave Steam running (offline) and tell the operator the window's
  interactive part is done.

Redists (guest, from another host shell while the user session runs):

    bash host/tools/guest-run.sh host/d5/d5-redist-install.ps1

Expected: `REDIST-INSTALL DONE`, exit codes 0 (or 3010), and all DLL
presence checks `True`. If `MISSING:` lines appear, the Steamworks Shared
depot layout differs — inspect with the (gitignored) diagnostic scripts in
`host/push/`.

### 6. Re-seal (guest → host)

    bash host/tools/guest-run.sh host/d5/d5-net-window-off.ps1

Expected: `ISOLATED NIC BACK: 192.168.100.10`.

    virsh -c qemu:///system detach-interface --domain folly-n-valor_default --type network --mac <MAC> --live

Get `<MAC>` from `virsh -c qemu:///system domiflist folly-n-valor_default`
(pick the interface on the `default` network; detach needs type + mac +
`--live` — there is no `--source` flag).

### 7. Re-verify hermeticity (gate)

    bash host/tools/guest-run.sh host/d5/d5-gate.ps1

Expected: every check `PASS` and the final line `GATE: PASS`. The gate
counts only real echo replies (`Reply from <target>: bytes=`); Windows ping
counts host-generated ICMP "destination unreachable" errors as Received, so
its loss-percentage line is meaningless for blocked probes and is printed
only as evidence.

### 8. Snapshot the post-window state

    ./lab.sh vm:snapshot post-game-online

### 9. Record

Append the window (date, deviations, gate result) to D5 in
`re/docs/DEVELOPMENT_PLAN.md`. Keep the title/app id out.

## Rollback / abort

If anything goes wrong mid-window: `./lab.sh vm:snapshot-rollback
pre-steam-window` restores the pre-window disk state (the NAT NIC is
host-side state — detach it separately, then re-run the gate).

## Known-stale artifacts (2026-10-17 window)

`host/push/` holds gitignored one-off diagnostics from the first execution
(several contain the app id and must stay untracked) plus
`d5-stage.tar` (1.4 GB, abandoned staging attempt) and `SteamSetup.exe`
(2.3 MB, reusable for reruns). Safe to delete the tar and the identity-
bearing diagnostics once the window is confirmed good; keep SteamSetup.exe
for reruns.
