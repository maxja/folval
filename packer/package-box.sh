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
# NB: parse the JSON properly. QEMU >= 9 (?) "children" blocks each carry
# their own "virtual-size" (the file child's = on-disk size, NOT the disk's
# virtual size) BEFORE the top-level key — a grep | head -n1 grabbed the
# child value and declared virtual_size: 10 for a 60 GiB image, making
# vagrant-libvirt create a 10G domain volume under a 60 GiB Windows install
# (see misconceptions log 2026-10-12).
VSIZE_BYTES=$(qemu-img info --output=json "$DISK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')
[[ "$VSIZE_BYTES" =~ ^[0-9]+$ ]] || { echo "ERROR: could not read virtual size of $DISK." >&2; exit 1; }
VSIZE_GIB=$(awk -v b="$VSIZE_BYTES" 'BEGIN {print int(b / 1024 / 1024 / 1024)}')
printf '{"provider":"libvirt","format":"qcow2","virtual_size": %s}\n' "$VSIZE_GIB" > output/pkg/metadata.json
tar -czf "$BOX" -C output/pkg metadata.json box.img
rm -rf output/pkg

echo "Box written: packer/$BOX"
echo "Import with: vagrant box add folval/win10-ltsc-2021 packer/$BOX"
