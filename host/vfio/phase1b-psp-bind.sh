#!/usr/bin/env bash
# folval2 Phase 1b: bind the PSP (10:00.2, 1022:1649) to vfio-pci + dracut cleanup.
#
# WHY THIS EXISTS: on Fedora 45 the ccp driver is BUILT INTO the kernel
# (modules.builtin), so it claims 10:00.2 during kernel init — vfio-pci.ids,
# softdep, and blacklist can never win for a built-in driver. The standard
# remedy is a runtime driver_override + unbind/bind, repeated every boot via
# a oneshot service. Run once with sudo:
#
#   sudo bash host/vfio/phase1b-psp-bind.sh
#
# Effects (idempotent):
#   1. Removes the stale 'vfio_virqfd' token from /etc/dracut.conf.d/vfio.conf
#      (module merged into vfio since kernel 6.2; its absence made dracut -f
#      error out on 2026-10-26 — image was still produced, but future runs
#      would keep failing).
#   2. Installs + enables folval-vfio-psp.service: unbinds ccp from 10:00.2,
#      sets driver_override=vfio-pci, binds — at every boot.
#   3. Runs the service NOW (no reboot needed).
#   4. Validates the Phase 1 gate.
#
# TRADEOFF (accepted 2026-10-26): host fTPM (/sys/class/tpm/tpm0) disappears
# while PSP is passed through — host root is NOT LUKS-encrypted, nothing
# depends on it; the VM gains an fTPM instead.
#
# Rollback: systemctl disable --now folval-vfio-psp.service; reboot
# (ccp reclaims 10:00.2, tpm0 returns).
set -euo pipefail

DEV=0000:10:00.2

[ "$(id -u)" = 0 ] || { echo "ERROR: run with sudo"; exit 1; }

echo "== 1/4 clean stale vfio_virqfd from /etc/dracut.conf.d/vfio.conf =="
if grep -q "vfio_virqfd" /etc/dracut.conf.d/vfio.conf 2>/dev/null; then
  cp /etc/dracut.conf.d/vfio.conf /etc/dracut.conf.d/vfio.conf.pre-folval2
  sed -i 's/ vfio_virqfd//' /etc/dracut.conf.d/vfio.conf
  echo "patched:"; cat /etc/dracut.conf.d/vfio.conf
else
  echo "already clean"
fi

echo "== 2/4 install folval-vfio-psp.service =="
cat > /etc/systemd/system/folval-vfio-psp.service <<'EOF'
[Unit]
Description=folval2 Phase 1: bind PSP 10:00.2 (1022:1649) to vfio-pci
# ccp is built-in on Fedora and grabs the PSP during kernel init; a runtime
# driver_override is the only way to take it. Must run before any VM starts.
After=multi-user.target
Before=libvirtd.service virtqemud.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0000:10:00.2 > /sys/bus/pci/devices/0000:10:00.2/driver/unbind; echo vfio-pci > /sys/bus/pci/devices/0000:10:00.2/driver_override; echo 0000:10:00.2 > /sys/bus/pci/drivers/vfio-pci/bind'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable folval-vfio-psp.service

echo "== 3/4 run it now (live unbind/bind) =="
systemctl start folval-vfio-psp.service
systemctl status folval-vfio-psp.service --no-pager -n 3 || true

echo "== 4/4 Phase 1 gate =="
for fn in 10:00.0 10:00.1 10:00.2; do
  drv=$(lspci -k -s "$fn" | awk -F': ' '/Kernel driver in use/{print $2}')
  echo "  $fn driver: ${drv:-NONE}"
done
[ -d /sys/class/tpm ] && echo "NOTE: host tpm0 still visible (unexpected)" || echo "OK: host fTPM released (expected)"
echo
echo "GATE GREEN (all three vfio-pci) => Phase 2: cd $(dirname "$0")/../.. && ./lab.sh vm:build2"
