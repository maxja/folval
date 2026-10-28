resource "proxmox_virtual_environment_vm" "folval3" {
  name        = var.vm_name
  node_name   = var.pve_node
  vm_id       = var.vm_id
  description = "Managed by OpenTofu - folly-n-valor game VM (Quadro P1000 passthrough)"

  # Windows 10 LTSC box image: q35 + OVMF (no Secure Boot), virtio bus
  machine      = "q35"
  bios         = "ovmf"
  on_boot      = true
  stop_on_destroy = true

  started = var.vm_started # provision creates it NOT started

  cpu {
    cores = var.vm_cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  # P1000 is the only display: vga none, dummy plug on mini-DP = sink
  vga {
    type = "none"
  }

  hostpci {
    device  = "hostpci0"
    mapping = var.pci_mapping_name # PVE 9: tokens can't set raw ids — Resource Mapping required
    pcie    = true
  }

  efi_disk {
    datastore_id      = var.storage_pool
    file_format       = "raw"
    pre_enrolled_keys = false
  }

  # OS disk: adopted out-of-band — the image was imported manually with
  # `qm importdisk 300 local:iso/folval2.img local-lvm` because bpg's disk
  # import requires SSH and PVE 9 has no raw-image import API. Everything
  # else about this VM is API-managed.

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = var.guest_mac
  }

  agent {
    enabled = true
    trim    = false
  }

  operating_system {
    type = "win10"
  }

  # No initialization block: Windows has no cloud-init. Autologon, virtio,
  # WinRM and qemu-ga are baked into the image (see host/push/MANIFEST.md).
}
