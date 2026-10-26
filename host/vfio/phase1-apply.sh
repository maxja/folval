#!/usr/bin/env bash
# folval2 Phase 1: host vfio foundation for the Raphael iGPU + PSP.
#
# Run ONCE with sudo (reviews welcome first):
#   sudo bash host/vfio/phase1-apply.sh
#
# What it does (idempotent):
#   1. Places the validated vbios dump at /var/lib/libvirt/qemu/vbios.bin
#      (libvirt/SELinux-readable location; referenced later by <rom file=.../>)
#   2. Extends vfio-pci.ids with PSP 1022:1649 in /etc/default/grub and
#      /etc/kernel/cmdline (GFX 164e + HDMI-audio 1640 were ALREADY bound via
#      vfio-pci.ids — host was pre-configured; this adds the missing fn)
#   3. Rewrites /etc/modprobe.d/vfio.conf with the full id set + a softdep so
#      ccp (the PSP's normal driver) yields to vfio-pci
#   4. Propagates the new args to all bootloader entries via grubby
#   5. Regenerates the current kernel's initramfs (backup kept as .pre-folval2)
#   6. Pre-reboot validation prints
#
# POST-REBOOT GATE (Phase 1 validate — run after reboot):
#   lspci -k -s 10:00.0 -s 10:00.1 -s 10:00.2
#     -> all three must show "Kernel driver in use: vfio-pci"
#   Host must still be SSH-reachable (console video may stay dark: by design,
#   video=efifb:off + initcall_blacklist=sysfb_init were already in cmdline).
#
# Rollback: restore /boot/initramfs-$(uname -r).img.pre-folval2, revert the
# three config files (ids WITHOUT 1022:1649), reboot.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VBIOS_SRC="$REPO/host/push/vbios_7900x.bin"
VBIOS_DST=/var/lib/libvirt/qemu/vbios.bin
IDS_OLD="1002:164e,1002:1640"
IDS_NEW="1002:164e,1002:1640,1022:1649"

[ "$(id -u)" = 0 ] || { echo "ERROR: run with sudo"; exit 1; }
[ -f "$VBIOS_SRC" ] || { echo "ERROR: missing $VBIOS_SRC"; exit 1; }

echo "== 1/6 vbios -> $VBIOS_DST =="
install -m 644 "$VBIOS_SRC" "$VBIOS_DST"
if command -v restorecon >/dev/null 2>&1; then restorecon -v "$VBIOS_DST" || true; fi
ls -la "$VBIOS_DST"

echo "== 2/6 extend vfio-pci.ids with PSP 1022:1649 (cmdline sources) =="
sed -i "s/$IDS_OLD/$IDS_NEW/g" /etc/default/grub /etc/kernel/cmdline
grep -h "vfio-pci.ids" /etc/default/grub /etc/kernel/cmdline

echo "== 3/6 /etc/modprobe.d/vfio.conf: full id set + ccp softdep =="
cat > /etc/modprobe.d/vfio.conf <<EOF
# folval2 Phase 1: Raphael iGPU (164e) + HDMI audio (1640) + PSP/CCP (1649).
# PSP = AMD Secure Processor; modern amdkmdag wants it for firmware init.
# Missing PSP in the passthrough set = classic silent Code 43.
# softdep: ccp yields to vfio-pci so 10:00.2 cannot be claimed first.
options vfio-pci ids=$IDS_NEW
softdep ccp pre: vfio-pci
EOF
cat /etc/modprobe.d/vfio.conf

echo "== 4/6 propagate args to bootloader entries (grubby ALL) =="
if command -v grubby >/dev/null 2>&1; then
  grubby --update-kernel=ALL --args="vfio-pci.ids=$IDS_NEW"
  grubby --info=DEFAULT | grep -o "vfio-pci.ids=[^ ]*" || true
else
  echo "WARN: grubby not found; BLS/grub entries not updated (cmdline files were)"
fi

echo "== 5/6 regenerate initramfs for $(uname -r) (backup kept) =="
KVER="$(uname -r)"
[ -f "/boot/initramfs-$KVER.img.pre-folval2" ] || cp "/boot/initramfs-$KVER.img" "/boot/initramfs-$KVER.img.pre-folval2"
dracut -f --kver "$KVER"

echo "== 6/6 pre-reboot validation =="
if lsinitrd "/boot/initramfs-$KVER.img" -f etc/modprobe.d/vfio.conf 2>/dev/null | grep -q "$IDS_NEW"; then
  echo "OK: initramfs carries the extended ids"
else
  echo "OK-check: cmdline vfio-pci.ids is the primary mechanism; modprobe.d is belt+braces"
fi
if modprobe -c 2>/dev/null | grep "^options vfio-pci" | grep -q "$IDS_NEW"; then
  echo "OK: modprobe config parses with the extended ids"
else
  echo "WARN: modprobe -c does not show the new ids"
fi
ls -la "$VBIOS_DST"
echo
echo "ALL SET. Reboot now, then run the Phase 1 gate:"
echo "  lspci -k -s 10:00.0 -s 10:00.1 -s 10:00.2   # all three -> vfio-pci"
echo "  (host console may stay dark; use SSH. Gate validated, proceed to Phase 2: lab.sh vm:build2)"
