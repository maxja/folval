# -*- mode: ruby -*-
# vi: set ft=ruby :
# LEGACY (WARP-era) machine — folval Phase 1: Windows 10 Enterprise LTSC 2021
# guest on libvirt/KVM.
# Renamed 2026-10-26 (Vagrantfile -> win10pc.Vagrantfile) to make room for the
# v2 cleanroom Vagrantfile (q35 + iGPU passthrough). Drive THIS file with:
#   VAGRANT_VAGRANTFILE=win10pc.Vagrantfile vagrant <cmd>
# (lab.sh legacy targets do the pinning automatically.)
# NEVER run both VMs at the same time: both self-assign 192.168.100.10 on
# re-isolated-net (v2 intentionally reuses the IP — the whole toolchain
# targets it).
#
# Directive parameters: 8 GB RAM, 4 vCPU, isolated 192.168.100.0/24 network
# with host gateway 192.168.100.1 and guest 192.168.100.10.
# (The 8-vCPU bump below was a 2026-10-25 WARP A/B result: WARP is a CPU
# rasterizer and scaled with cores. With the v2 real-GPU pivot this argument
# is historical — user chose to KEEP 8 for the v2 machine too.)

Vagrant.configure("2") do |config|
  config.vm.box = "folval/win10-ltsc-2021"
  config.vm.guest = :windows

  config.vm.communicator = "winrm"
  config.winrm.username = "vagrant"
  config.winrm.password = "vagrant"
  # NB: do NOT set config.winrm.timeout low — it bounds each `ready?` probe
  # (communicator.rb: Timeout.timeout(winrm.timeout) { shell.cmd("hostname") }),
  # and a Timeout::Error escaping a probe kills the WHOLE boot wait at
  # ~winrm.timeout seconds regardless of boot_timeout (cost: a 61s "Timed
  # out while waiting for the machine to boot" on 2026-10-12). Default 1800.
  config.vm.boot_timeout = 600

  # Windows-on-libvirt has no native synced-folder mechanism; the Phase 5
  # Samba share (\\192.168.100.1\re) implements the workspace contract.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider :libvirt do |lv|
    # CRITICAL: vagrant-libvirt 0.11.2 defaults to the SESSION connection
    # (qemu:///session) when no URI is set — and on that path CreateNetworks
    # returns early WITHOUT creating libvirt networks, so re-isolated-net is
    # silently skipped and domain start fails with "Network not found".
    # The lab lives on the system connection (same as `virsh`); pin it here.
    lv.uri = "qemu:///system"
    lv.driver = "kvm"
    lv.memory = 8192
    lv.cpus = 8
    # 2026-10-25 WARP-boost A/B: host-passthrough exposes the real 7900X to
    # the guest (was: custom EPYC-Genoa) — WARP scales with vCPUs.
    lv.cpu_mode = "host-passthrough"
    lv.title = "folval-win"

    # VNC console: vagrant-libvirt's default graphics type IS vnc (autoport on
    # 127.0.0.1) — no config needed. To view the desktop:
    #   virt-viewer folval-win        # or
    #   virsh vncdisplay folval-win   # shows the port, e.g. :1 -> 5901

    # The default libvirt management network is NAT'd to the internet.
    # Attaching it would silently defeat guest isolation — never enable.
    lv.mgmt_attach = false
    lv.qemu_use_agent = true

    # Absolute-pointer input for VNC: a usb-tablet keeps host and guest
    # cursors locked together (no relative-motion drift). Without it the
    # domain only gets a ps/2 mouse and every VNC click fights the cursor.
    lv.inputs = [{ type: 'tablet', bus: 'usb' }]

    # Bumped from the cirrus/16MB default (Phase 4b, 2026-10-18): the game's
    # D3D9 device creation needed VRAM headroom. Plugin options are
    # lv.video_type / lv.video_vram (v0.11.2) — there is no lv.video_adapter.
    # libvirt video model names: 'vga'/'qxl'/'virtio'/'cirrus' ('std' rejected).
    lv.video_type = 'vga'
    lv.video_vram = 262144
  end

  # Phase 3 provisioning does NOT use a vagrant shell provisioner: uploads
  # go through winrm-fs, which is a stub gem on this host (see misconceptions).
  # `./lab.sh provision` delivers vm/debloat.ps1 via qemu-ga guest-exec
  # (PowerShell -EncodedCommand) instead.

  # Isolated lab network: no DHCP, no forwarding/NAT, host side is 192.168.100.1.
  config.vm.network "private_network",
    ip: "192.168.100.10",
    libvirt__network_name: "re-isolated-net",
    libvirt__host_ip: "192.168.100.1",
    libvirt__netmask: "255.255.255.0",
    libvirt__dhcp_enabled: false,
    libvirt__forward_mode: "none",
    # Survive host reboots: the network autostarts with libvirtd, so
    # `vagrant verify` (WinRM) works even before `vagrant up`.
    libvirt__autostart: true
end
