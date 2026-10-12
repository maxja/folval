packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# NOTE: the license key is NOT consumed via Packer templating — floppy_files
# contents are copied verbatim. build.sh renders answer/Autounattend.xml
# from the .in template (sed) before Packer runs; the rendered file is
# gitignored and removed on exit. The key itself never enters git.

variable "iso_path" {
  type    = string
  default = "isos/en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso"
}

source "qemu" "win_ltsc" {
  # Media — SHA-256 baselines recorded in re/docs/DEVELOPMENT_PLAN.md (D1)
  iso_url          = var.iso_path
  iso_checksum     = "none"
  output_directory = "output-win-ltsc"
  vm_name          = "win-ltsc.qcow2"

  # Hardware: BIOS (i440fx "pc") + MBR layout, virtio disk + net
  accelerator     = "kvm"
  machine_type    = "pc"
  cpu_model       = "host"
  cpus            = 4
  memory          = 4096
  disk_size       = "60G"
  disk_interface  = "virtio"
  format          = "qcow2"
  net_device      = "virtio-net"
  headless        = true

  # Autounattend + virtio drivers ride the floppy. Second-CD driver delivery
  # is NOT possible with this builder: any -drive in qemuargs suppresses the
  # plugin's default -drive set (iso AND disk vanish — verified 2026-10-11).
  # Floppy constraint: 1.44 MB flat copy, so driver packages must stay
  # COMPLETE (netkvm.inf requires netkvmp.exe) — build.sh prunes only
  # pdb/md/netkvmco.exe. The license key is rendered into the answer file by
  # build.sh before Packer runs (op read -> sed; WillShowUI=OnError = manual
  # VNC fallback).
  floppy_files = [
    "answer/Autounattend.xml",
    "virtio/",
  ]

  # Communicator
  communicator   = "winrm"
  winrm_username = "vagrant"
  winrm_password = "vagrant"
  winrm_timeout  = "2h"

  shutdown_command = "shutdown /s /t 10 /f /c \"Packer shutdown\""
  shutdown_timeout = "15m"
}

build {
  sources = ["source.qemu.win_ltsc"]

  # QEMU guest agent (speaks over the vioserial channel) — uploaded and
  # installed over WinRM after first boot.
  provisioner "file" {
    source      = "files/guest-agent/qemu-ga-x86_64.msi"
    destination = "C:\\Windows\\Temp\\qemu-ga-x86_64.msi"
  }

  # qemu-ga is OPTIONAL (static-IP WinRM does not need it) — never
  # hard-fail the build on it: msiexec can race Windows Installer on a
  # fresh image (1603/1618), and a thrown check once deleted a fully
  # installed 8.7 GB artifact. Retry with backoff; warn and continue.
  provisioner "powershell" {
    inline = [
      "$installed = $false",
      "for ($i = 1; $i -le 5 -and -not $installed; $i++) {",
      "  $p = Start-Process msiexec -ArgumentList '/i','C:\\Windows\\Temp\\qemu-ga-x86_64.msi','/qn','/norestart' -Wait -PassThru -NoNewWindow",
      "  Write-Output \"msiexec attempt $i exit code: $($p.ExitCode)\"",
      "  if (Get-Service | Where-Object { $_.Name -like '*qemu*' -or $_.DisplayName -like '*QEMU*' }) { $installed = $true }",
      "  if (-not $installed) { Start-Sleep 30 }",
      "}",
      "if ($installed) { Write-Output 'qemu-ga: installed' } else { Write-Output 'WARNING: qemu-ga not installed; continuing (static-IP WinRM does not require it)' }",
    ]
  }

  # Guest-side static network bootstrap. re-isolated-net has NO DHCP by
  # design (Phase 2: the mock gateway owns :53 on 192.168.100.1; libvirt
  # dnsmasq would clash), so the box must self-assign 192.168.100.10 on
  # every boot. Script + ONSTART scheduled task (SYSTEM - fires without
  # any interactive logon, unlike RunOnce, and the box's autologon count
  # is finite). Idempotent; re-asserts WinRM config after NIC changes.
  provisioner "file" {
    source      = "files/network/folval-net.ps1"
    destination = "C:\\Windows\\Temp\\folval-net.ps1"
  }

  provisioner "powershell" {
    inline = [
      "New-Item -ItemType Directory -Force C:\\Windows\\Setup\\Scripts | Out-Null",
      "Copy-Item C:\\Windows\\Temp\\folval-net.ps1 C:\\Windows\\Setup\\Scripts\\folval-net.ps1 -Force",
      "schtasks /Create /F /TN folval-static-ip /SC ONSTART /RU SYSTEM /RL HIGHEST /TR \"powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Setup\\Scripts\\folval-net.ps1\"",
      "schtasks /Query /TN folval-static-ip",
    ]
  }

  # Package the box INSIDE the packer run. The qemu builder deletes the
  # output dir on any non-clean exit — a manual packaging step after
  # `packer build` leaves a window where an interrupt destroys the only
  # image. As a post-processor, the .box lands milliseconds after the
  # artifact and survives later interruptions.
  post-processor "shell-local" {
    inline = ["./package-box.sh"]
  }
}
