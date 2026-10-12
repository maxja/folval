#!/bin/bash
# folval lab orchestrator — single entrypoint for the whole pipeline.
#
# Day-to-day (VM already built and imported):
#   ./lab.sh up          Start the isolated VM (vagrant up)
#   ./lab.sh down        Shut the VM down (vagrant halt)
#   ./lab.sh destroy     vagrant destroy (box stays imported)
#   ./lab.sh verify      Phase 1 gate: libvirt domain up + WinRM round-trip
#   ./lab.sh license     Show Windows activation state in the guest (slmgr /dli)
#
# Full rebuild from the staged ISO:
#   ./lab.sh rebuild     packer build -> box import -> vagrant up -> verify
#
#   (re)build needs a 1Password approval popup for the license key read.
#   The .box contains the keyed Windows image: it is gitignored and must
#   never leave this machine.
set -euo pipefail
cd "$(dirname "$0")"

BOX_NAME="folval/win10-ltsc-2021"
BOX_FILE="packer/output/folval-win10-ltsc-2021.box"

case "${1:-}" in
  build)
    ( cd packer && ./build.sh build )
    ;;
  add)
    if [ ! -f "$BOX_FILE" ]; then
      echo "No box at $BOX_FILE — run './lab.sh build' first." >&2
      exit 1
    fi
    vagrant box add --force "$BOX_NAME" "$BOX_FILE"
    ;;
  up)
    vagrant up
    ;;
  verify)
    echo "== libvirt domains =="
    virsh -c qemu+unix:///system list --all | grep -E "Name|folval" || true
    echo "== WinRM round-trip =="
    if vagrant winrm -c "echo ok"; then
      echo "GATE: Phase 1 verification PASSED"
    else
      echo "GATE: Phase 1 verification FAILED" >&2
      exit 1
    fi
    ;;
  rebuild)
    bash "$0" build
    bash "$0" add
    bash "$0" up
    bash "$0" verify
    ;;
  license)
    vagrant winrm -c "cscript //nologo %windir%\system32\slmgr.vbs /dli"
    ;;
  down)
    vagrant halt
    ;;
  destroy)
    vagrant destroy
    ;;
  *)
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
