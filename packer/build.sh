#!/usr/bin/env bash
# folval Phase 1 build wrapper.
# License key handling: Packer does NOT template floppy_files contents, so
# build.sh renders answer/Autounattend.xml from the .in template (sed).
# The key is required — keyless installs fail with "Windows cannot read the
# ProductKey setting". WillShowUI=OnError lets setup prompt for manual entry
# over VNC if the embedded key is rejected.
#
# Usage:
#   ./packer/build.sh              # build (box packaged by post-processor)
#   ./packer/build.sh validate     # packer validate only
#   ./packer/build.sh package      # re-package existing output-win-ltsc disk
#                                  # (no license key needed for package)
#
# Key sources (first match wins):
#   1. PKR_VAR_windows_license_key   e.g. "$(op read '<op-reference>')" in your shell
#   2. FOLVAL_OP_REF                 op reference; this script runs `op read`
#   3. packer/op-ref.env             gitignored file defining FOLVAL_OP_REF
set -euo pipefail
cd "$(dirname "$0")"

ACTION="${1:-build}"

if [[ -f "op-ref.env" ]]; then
  # shellcheck disable=SC1091
  source "op-ref.env"
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
  echo "FOLVAL_OP_REF=<op-reference>" > packer/op-ref.env   # gitignored
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
  sed "s|__FOLVAL_WIN_KEY__|$key|" answer/Autounattend.xml.in > answer/Autounattend.xml
}
trap 'rm -f answer/Autounattend.xml' EXIT

# Stage virtio drivers (floppy payload) + qemu-ga MSI (provisioner upload)
# from the local virtio-win ISO. Floppy budget: ~620 KB of 1440 KB — prune
# ONLY pdb/md and the unused 1 MB netkvmco.exe co-installer; NEVER netkvmp.exe
# (netkvm.inf SourceDisksFiles REQUIRES it — pruning it silently leaves the
# guest without a NIC; see misconceptions log 2026-10-11). Idempotent; 7z.
prepare_media() {
  command -v 7z >/dev/null 2>&1 || { echo "ERROR: 7z (p7zip) is required to stage virtio drivers." >&2; exit 1; }
  # NB: `files/` is a mixed tree (staged guest-agent MSI + tracked network
  # bootstrap payload) — only clear the staged subdir.
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
    packer build .
    ;;
  validate)
    render_answer
    prepare_media
    packer validate .
    ;;
  package)
    ./package-box.sh
    ;;
  *)
    echo "usage: ./build.sh [build|validate|package]" >&2
    exit 1
    ;;
esac
