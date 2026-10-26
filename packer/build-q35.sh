#!/usr/bin/env bash
# folval2 (VM v2) build wrapper — q35 + OVMF UEFI, native GPT install.
# Sibling of build.sh (legacy i440fx/BIOS). Builds ONLY the q35 template:
#   packer build windows-ltsc-q35.pkr.hcl
# (explicit file arg — `packer build .` would load BOTH templates in this
# directory and run both builds).
#
# License key handling: identical mechanism to build.sh — the answer file is
# rendered from the .in template via sed; the key comes from 1Password via
# op-ref-q35.env (gitignored) and never touches git.
#
# Usage:
#   ./packer/build-q35.sh              # build (box packaged by post-processor)
#   ./packer/build-q35.sh validate     # packer validate only
#   ./packer/build-q35.sh package      # re-package existing output-q35-ltsc disk
#                                      # (no license key needed for package)
#
# Key sources (first match wins):
#   1. PKR_VAR_windows_license_key   e.g. "$(op read '<op-reference>')" in your shell
#   2. FOLVAL_OP_REF                 op reference; this script runs `op read`
#   3. packer/op-ref-q35.env         gitignored file defining FOLVAL_OP_REF
set -euo pipefail
cd "$(dirname "$0")"

ACTION="${1:-build}"
ANSWER="answer/Autounattend-q35.xml"
TEMPLATE="windows-ltsc-q35.pkr.hcl"
DISK="output-q35-ltsc/win-ltsc-q35.qcow2"
BOX="output-q35/folval-win10-ltsc-q35.box"

if [[ -f "op-ref-q35.env" ]]; then
  # shellcheck disable=SC1091
  source "op-ref-q35.env"
fi

# `package` repackages an existing artifact — it needs neither the license
# key nor media staging (keep it runnable without an op popup).
if [[ "$ACTION" != "package" ]]; then
  if [[ -z "${PKR_VAR_windows_license_key:-}" ]]; then
    if [[ -z "${FOLVAL_OP_REF:-}" ]]; then
      cat >&2 <<'EOF'
ERROR: no Windows license key available.

Provide one of:
  export PKR_VAR_windows_license_key="$(op read '<op-reference>')"
  export FOLVAL_OP_REF='<op-reference>'
  echo "FOLVAL_OP_REF=<op-reference>" > packer/op-ref-q35.env   # gitignored
EOF
      exit 1
    fi
    command -v op >/dev/null 2>&1 || { echo "ERROR: op CLI not found." >&2; exit 1; }
    export PKR_VAR_windows_license_key
    PKR_VAR_windows_license_key="$(op read "$FOLVAL_OP_REF")"
    [[ -n "${PKR_VAR_windows_license_key}" ]] || { echo "ERROR: op read returned an empty value." >&2; exit 1; }
  fi
fi

render_answer() {
  local key
  key="$(printf '%s' "${PKR_VAR_windows_license_key}" | tr -d ' \t\r\n')"
  if [[ ! "$key" =~ ^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$ ]]; then
    echo "ERROR: license key has an unexpected shape (expected 29 chars: 5 groups of 5 alphanumerics, hyphen-separated). Check the 1Password item." >&2
    exit 1
  fi
  sed "s|__FOLVAL_WIN_KEY__|$key|" answer/Autounattend-q35.xml.in > "$ANSWER"
}
trap 'rm -f "$ANSWER"' EXIT

# Stage virtio drivers (floppy payload) + qemu-ga MSI (provisioner upload)
# from the local virtio-win ISO. SHARED with the legacy build (same staging
# dirs, same pruning rules — never prune netkvmp.exe). Idempotent; 7z.
prepare_media() {
  command -v 7z >/dev/null 2>&1 || { echo "ERROR: 7z (p7zip) is required to stage virtio drivers." >&2; exit 1; }
  rm -rf virtio files/guest-agent
  mkdir -p virtio files/guest-agent
  7z x isos/virtio-win.iso -ovirtio viostor/w10/amd64 NetKVM/w10/amd64 vioserial/w10/amd64 -y >/dev/null
  7z x isos/virtio-win.iso -ofiles guest-agent/qemu-ga-x86_64.msi -y >/dev/null
  find virtio -type f \( -name '*.pdb' -o -name '*.md' -o -name 'netkvmco.exe' \) -delete
}

case "$ACTION" in
  build)
    render_answer
    prepare_media
    echo "==> DO NOT interrupt this script (no Ctrl-C): the guest VM shutting"
    echo "==> down is NOT the end — the box is packaged right after, and an"
    echo "==> interrupt makes Packer delete the only built image."
    packer build "$TEMPLATE"
    ;;
  validate)
    render_answer
    prepare_media
    packer validate "$TEMPLATE"
    ;;
  package)
    PACKAGE_DISK="$DISK" PACKAGE_BOX="$BOX" ./package-box.sh
    ;;
  *)
    echo "usage: ./build-q35.sh [build|validate|package]" >&2
    exit 1
    ;;
esac
