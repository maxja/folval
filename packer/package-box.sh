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
VSIZE_BYTES="$(qemu-img info --output=json "$DISK" | sed -n 's/.*"virtual-size": \([0-9]*\).*/\1/p')"
[[ -n "$VSIZE_BYTES" ]] || { echo "ERROR: could not read virtual size of $DISK." >&2; exit 1; }
VSIZE_GIB="$(( VSIZE_BYTES / 1024 / 1024 / 1024 ))"
printf '{"provider":"libvirt","format":"qcow2","virtual_size": %s}\n' "$VSIZE_GIB" > output/pkg/metadata.json
tar -czf "$BOX" -C output/pkg metadata.json box.img
rm -rf output/pkg

echo "Box written: packer/$BOX"
echo "Import with: vagrant box add folval/win10-ltsc-2021 packer/$BOX"
