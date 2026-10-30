#!/usr/bin/env bash
# Session 14 host prep — run with sudo:
#   sudo bash host/vfio/session14-prep.sh
#
# 1) Stage the virtio-win ISO where the qemu user can read it
#    (it lives under /home/maxja/... which qemu cannot traverse —
#    domain start failed with "Could not open ... Permission denied").
# 2) Fix folval-vfio-psp.service ordering cycle discovered at the
#    Oct 27 06:30 boot: After=multi-user.target + Before=virtqemud.service
#    formed a cycle (multi-user after virtqemud), so systemd DELETED the
#    start job and the PSP stayed on ccp until libvirt rescued it at
#    domain start. Anchor on systemd-modules-load instead.
set -euo pipefail

echo "--- staging virtio ISO"
install -m 644 tmp/virtio-win-0.1.302.iso /var/lib/libvirt/images/virtio-win-0.1.302.iso

echo "--- fixing folval-vfio-psp.service ordering"
sed -i 's|^After=multi-user.target$|After=systemd-modules-load.service|' \
  /etc/systemd/system/folval-vfio-psp.service
systemctl daemon-reload

echo "--- verify"
ls -la /var/lib/libvirt/images/virtio-win-0.1.302.iso
grep -E '^(After|Before)=' /etc/systemd/system/folval-vfio-psp.service
echo "OK"
