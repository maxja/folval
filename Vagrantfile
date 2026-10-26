# -*- mode: ruby -*-
# vi: set ft=ruby :
# folval2 — VM v2 "cleanroom": q35 + OVMF (UEFI) + GPT-native install, built
# to receive the Raphael iGPU (Radeon 610M) via VFIO passthrough in Phase 3.
#
# Legacy WARP machine lives in win10pc.Vagrantfile:
#   VAGRANT_VAGRANTFILE=win10pc.Vagrantfile vagrant <cmd>
# NEVER run both VMs at the same time: both self-assign 192.168.100.10 on
# re-isolated-net (v2 reuses the IP on purpose — the whole toolchain —
# gateway forwards, hosts maps, frida scripts — targets it).
#
# Hardware contract (user requirements, 2026-10-26):
#   - q35 chipset + UEFI (OVMF pflash code + dedicated VARS file)
#   - virtio disk with discard=unmap -> guest sees an SSD, TRIM works
#   - 8 vCPU host-passthrough (FINAL user decision: restored 8 over a 4 rec)
#   - 12 GB RAM (the iGPU has no VRAM of its own: firmware steal + shared-GPU
#     carve-outs come out of this pool — do not trim)
#   - <kvm hidden state='on'> (AMD drivers refuse VMs: Error 43 mitigation)
#   - VNC rescue console (vga) until the iGPU takes over display in Phase 3;
#     hostdevs (GFX 10:00.0 + romfile, HDMI-audio 10:00.1, PSP 10:00.2) are
#     attached via the virsh-define workflow (tmp/runA/domain-ovmf.xml
#     pattern), NOT via vagrant — see in-stone rule: never re-up without
#     re-defining the domain.

Vagrant.configure("2") do |config|
  # Distinct machine name -> separate .vagrant state + domain
  # folly-n-valor_folval2 (no collision with the parked legacy domain).
  config.vm.define "folval2"

  config.vm.box = "folval/win10-ltsc-q35"
  config.vm.guest = :windows

  config.vm.communicator = "winrm"
  config.winrm.username = "vagrant"
  config.winrm.password = "vagrant"
  # Same WinRM-timeout trap as legacy: do NOT lower winrm.timeout; it bounds
  # each ready? probe and a Timeout::Error kills the whole boot wait.
  config.vm.boot_timeout = 600

  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider :libvirt do |lv|
    lv.uri = "qemu:///system"
    lv.driver = "kvm"

    # --- q35 + UEFI (user requirement) ---
    lv.machine_type = "q35"
    lv.loader = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
    # NB: vagrant-libvirt emits a PLAIN <nvram>PATH</nvram> (no template
    # support), so this file must pre-exist — `lab.sh vm:up2` seeds it (a
    # writable copy of OVMF_VARS) into libvirt's nvram dir exactly once.
    lv.nvram = "/var/lib/libvirt/qemu/nvram/folval2_VARS.fd"

    # --- CPU/RAM (final: 8 vCPU per user, 12 GB for iGPU UMA carve) ---
    lv.cpu_mode = "host-passthrough"
    lv.cpus = 8
    lv.memory = 12288

    # --- Hide the hypervisor bit from the guest (Error 43) ---
    lv.kvm_hidden = true

    # --- Disk: virtio + TRIM/SSD semantics (user requirement) ---
    lv.disk_bus = "virtio"
    # Primary-disk driver opts (vagrant-libvirt 0.11.2 disk_driver):
    # discard=unmap exposes TRIM; io=native for the qcow2 backing file.
    lv.disk_driver :discard => "unmap", :io => "native"

    # --- Rescue graphics + input (until iGPU lands in Phase 3) ---
    lv.video_type = "vga"
    lv.video_vram = 262144
    lv.inputs = [{ type: "tablet", bus: "usb" }]
    # q35 pairs with xHCI (legacy i440fx used piix3-uhci).
    lv.usbctl_dev = { model: "qemu-xhci", ports: "8" }

    # Guest clock follows host localtime (permanent session-12 fix).
    lv.clock_offset = "localtime"

    lv.title = "folval-win2"

    # Isolation + agent (same contract as legacy; see win10pc.Vagrantfile
    # for the qemu:///system and mgmt_attach rationale).
    lv.mgmt_attach = false
    lv.qemu_use_agent = true
  end

  # Isolated lab network: no DHCP, no forwarding/NAT, host side 192.168.100.1.
  # Same IP as the parked legacy VM — run ONE VM at a time.
  config.vm.network "private_network",
    ip: "192.168.100.10",
    libvirt__network_name: "re-isolated-net",
    libvirt__host_ip: "192.168.100.1",
    libvirt__netmask: "255.255.255.0",
    libvirt__dhcp_enabled: false,
    libvirt__forward_mode: "none",
    libvirt__autostart: true
end
