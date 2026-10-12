# -*- mode: ruby -*-
# vi: set ft=ruby :
# folval Phase 1: Windows 10 Enterprise LTSC 2021 guest on libvirt/KVM.
# Directive parameters: 8 GB RAM, 4 vCPU, isolated 192.168.100.0/24 network
# with host gateway 192.168.100.1 and guest 192.168.100.10.

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
    lv.cpus = 4
    lv.title = "folval-win"

    # VNC console: vagrant-libvirt's default graphics type IS vnc (autoport on
    # 127.0.0.1) — no config needed. To view the desktop:
    #   virt-viewer folval-win        # or
    #   virsh vncdisplay folval-win   # shows the port, e.g. :1 -> 5901

    # The default libvirt management network is NAT'd to the internet.
    # Attaching it would silently defeat guest isolation — never enable.
    lv.mgmt_attach = false
    lv.qemu_use_agent = true
  end

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
