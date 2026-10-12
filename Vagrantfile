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
  config.winrm.timeout = 60
  config.vm.boot_timeout = 600

  # Windows-on-libvirt has no native synced-folder mechanism; the Phase 5
  # Samba share (\\192.168.100.1\re) implements the workspace contract.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider :libvirt do |lv|
    lv.driver = "kvm"
    lv.memory = 8192
    lv.cpus = 4
    lv.title = "folval-win"
    lv.vnc_enabled = true

    # The default libvirt management network is NAT'd to the internet.
    # Attaching it would silently defeat guest isolation — never enable.
    lv.mgmt_attach = false
  end

  # Isolated lab network: no DHCP, no forwarding/NAT, host side is 192.168.100.1.
  config.vm.network "private_network",
    ip: "192.168.100.10",
    libvirt__network_name: "re-isolated-net",
    libvirt__host_ip: "192.168.100.1",
    libvirt__netmask: "255.255.255.0",
    libvirt__dhcp_enabled: false,
    libvirt__forward_mode: "none"
end
