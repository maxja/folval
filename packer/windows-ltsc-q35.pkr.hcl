packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# folval2 (VM v2) box: q35 + OVMF UEFI, native GPT install. Sibling of
# windows-ltsc.pkr.hcl (legacy i440fx/BIOS box) — SHARED media (isos/, virtio/,
# files/) is common to both; ONLY build with build-q35.sh, which targets THIS
# file explicitly (`packer build windows-ltsc-q35.pkr.hcl`) so the legacy
# source in the same directory is never loaded alongside it.

# NOTE: the license key is NOT consumed via Packer templating — floppy_files
# contents are copied verbatim. build-q35.sh renders answer/Autounattend-q35.xml
# from the .in template (sed) before Packer runs; the rendered file is
# gitignored and removed on exit. The key itself never enters git.

variable "iso_path" {
  type    = string
  default = "isos/en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso"
}

source "qemu" "win_ltsc_q35" {
  # Media — SHA-256 baseline recorded in re/docs/DEVELOPMENT_PLAN.md (D1)
  iso_url          = var.iso_path
  iso_checksum     = "none"
  output_directory = "output-q35-ltsc"
  vm_name          = "win-ltsc-q35.qcow2"

  # Hardware: q35 + OVMF (UEFI) — matches the v2 Vagrantfile contract
  # (machine_type, pflash code). The plugin (v1.1.7) manages a writable
  # VARS pflash automatically; vars do not persist across build runs,
  # which is fine for an unattended install.
  accelerator     = "kvm"
  machine_type    = "q35"
  firmware        = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
  cpu_model       = "host"
  cpus            = 8
  memory          = 8192
  disk_size       = "60G"
  disk_interface  = "virtio"
  format          = "qcow2"
  net_device      = "virtio-net"
  headless        = true

  # Autounattend + virtio drivers ride the floppy (1.44 MB flat copy — driver
  # packages must stay COMPLETE; build-q35.sh prunes only pdb/md/netkvmco.exe).
  # NO qemuargs -drive anywhere: any -drive in qemuargs suppresses the
  # plugin's default -drive set (iso AND disk vanish — verified 2026-10-11).
  floppy_files = [
    "answer/Autounattend-q35.xml",
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
  sources = ["source.qemu.win_ltsc_q35"]

  # QEMU guest agent (speaks over the vioserial channel) — uploaded and
  # installed over WinRM after first boot. Same retry-with-backoff as legacy
  # (msiexec can race Windows Installer on a fresh image).
  provisioner "file" {
    source      = "files/guest-agent/qemu-ga-x86_64.msi"
    destination = "C:\\Windows\\Temp\\qemu-ga-x86_64.msi"
  }

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

  # Guest-side static network bootstrap (re-isolated-net has NO DHCP by
  # design). Same ONSTART SYSTEM task as the legacy box.
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

  # Package the box INSIDE the packer run (qemu builder deletes the output
  # dir on non-clean exit — packaging must not lag the artifact).
  post-processor "shell-local" {
    inline = [
      "PACKAGE_DISK=output-q35-ltsc/win-ltsc-q35.qcow2 PACKAGE_BOX=output-q35/folval-win10-ltsc-q35.box ./package-box.sh",
    ]
  }
}
