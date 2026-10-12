#!/usr/bin/env bash
# Packages the Packer qcow2 artifact into a vagrant-libvirt box using the
# documented libvirt box layout (metadata.json + box.img). Deliberately manual:
# no reliance on the Packer vagrant post-processor provider mapping.
set -euo pipefail
cd "$(dirname "$0")"

DISK="output-win-ltsc/win-ltsc.qcow2"
BOX="output/folval-win10-ltsc-2021.box"

[[ -f "$DISK" ]] || { echo "ERROR: $DISK not found — run the build first." >&2; exit 1; }

mkdir -p output
rm -rf output/pkg
mkdir output/pkg
cp "$DISK" output/pkg/box.img
# vagrant-libvirt >= 0.11 aborts in HandleBoxImage#verify_box_format unless
# metadata.json declares format AND virtual_size (GiB) - "No image format
# specified for box." / "No image virtual size specified for box.".
# Derive both from the artifact itself instead of hardcoding.
# grep -oP + head -1: extract exactly the digits after the key, first match
# only (a multi-line capture here previously broke the arithmetic below).
VSIZE_BYTES=$(qemu-img info --output=json "$DISK" | grep -oP '"virtual-size"\s*:\s*\K[0-9]+' | head -n1)
[[ "$VSIZE_BYTES" =~ ^[0-9]+$ ]] || { echo "ERROR: could not read virtual size of $DISK." >&2; exit 1; }
# awk for the division: bash arithmetic chokes on values it can't parse as a
# single token (see the 2026-10-12 "arithmetic syntax error" incident).
VSIZE_GIB=$(awk -v b="$VSIZE_BYTES" 'BEGIN {print int(b / 1024 / 1024 / 1024)}')
printf '{"provider":"libvirt","format":"qcow2","virtual_size": %s}\n' "$VSIZE_GIB" > output/pkg/metadata.json
tar -czf "$BOX" -C output/pkg metadata.json box.img
rm -rf output/pkg

echo "Box written: packer/$BOX"
echo "Import with: vagrant box add folval/win10-ltsc-2021 packer/$BOX"
