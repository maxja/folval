#!/bin/bash
# igpu-preinit.sh — warm-start the Raphael iGPU (1002:164e) before vfio handoff.
#
# Theory: the Windows WDDM driver fails StartDevice because the device reaches
# the guest stone-cold (no option ROM; host firmware never initialized it).
# Host amdgpu CAN initialize it (kernel parses ATOM tables via the platform
# firmware volume). Sequence: amdgpu init -> unbind -> vfio rebind (warm).
#
# Verdicts:
#   amdgpu init FAILS  -> the iGPU isn't initializable even on the host;
#                         the whole iGPU passthrough path is dead on this
#                         platform. Stop; use WARP (already ~3-5x faster at 8 vCPU).
#   amdgpu init OK     -> rebind vfio warm, then start the VM and test the
#                         guest driver (install persists; enable-cycle if needed).
#
# Run as root while the lab VM is OFF:  sudo bash host/tools/igpu-preinit.sh
set -u
DEV=0000:10:00.0
DID="1002 164e"
VFIOD=/sys/bus/pci/drivers/vfio-pci
AMDD=/sys/bus/pci/drivers/amdgpu

say() { echo "[$(date '+%H:%M:%S')] $*"; }

# never leave the device unbound on exit (VM needs it in vfio)
cleanup() {
  cur2=$(basename "$(readlink -f /sys/bus/pci/devices/$DEV/driver 2>/dev/null)" 2>/dev/null)
  if [ -z "$cur2" ] || [ "$cur2" = "driver" ]; then
    echo "$DEV" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null && say "cleanup: restored vfio-pci binding"
  fi
}
trap cleanup EXIT

# --- guard: VM must be off ---
state=$(virsh -c qemu:///system domstate folly-n-valor_default 2>/dev/null)
if [ "$state" != "shut off" ]; then
  echo "REFUSING: VM state is '$state' — shut it down first." >&2
  exit 1
fi
# --- guard: device must be present ---
[ -d "/sys/bus/pci/devices/$DEV" ] || { echo "REFUSING: $DEV not present"; exit 1; }

cur=$(basename "$(readlink -f /sys/bus/pci/devices/$DEV/driver)" 2>/dev/null)
say "current driver: ${cur:-none}"

dmesg_mark() { dmesg | grep -iE "amdgpu|atom|psp|gfx" | tail -n "${1:-5}"; }

# --- 1. unbind from vfio-pci (if bound) ---
if [ "$cur" = "vfio-pci" ]; then
  echo "$DEV" > "$VFIOD/unbind" || { say "vfio unbind failed"; exit 1; }
  say "unbound from vfio-pci"
fi

# --- 2. bind amdgpu ---
if ! grep -q "$DID" "$AMDD"/{bind,uevent} 2>/dev/null; then :; fi
modprobe amdgpu 2>/dev/null || true
echo "$DID" > "$AMDD/bind" || { say "amdgpu bind FAILED — device id not accepted (driver too old?)"; dmesg_mark; exit 1; }
say "bound to amdgpu — waiting for init"

# --- 3. wait for init verdict (up to 30 s) ---
ok=""; fail=""
for i in $(seq 1 30); do
  sleep 1
  if dmesg | tail -n 60 | grep -iE "amdgpu.*(ring|VRAM|fb pinned|Display Core|amdgpu.*GPU reset|KMS)" >/dev/null; then ok=1; break; fi
  if dmesg | tail -n 60 | grep -iE "amdgpu.*(ERROR|failed to|firmware.*fail|Cannot|no ATOM|no BIOS)" >/dev/null; then fail=1; break; fi
done

echo "--- amdgpu dmesg tail ---"
dmesg_mark 15
echo "------------------------"

if [ -n "$fail" ] && [ -z "$ok" ]; then
  say "VERDICT: amdgpu could NOT initialize the iGPU — passthrough path dead. Restoring vfio."
  echo "$DEV" > "$AMDD/unbind" 2>/dev/null
  echo "$DEV" > "$VFIOD/bind" 2>/dev/null
  lspci -nnk -s 10:00.0 | tail -2
  exit 2
fi

say "amdgpu initialized the device (or timed out neutral); draining 3 s, then handing to vfio WARM"
sleep 3

# --- 4. hand off warm: unbind amdgpu, rebind vfio-pci ---
echo "$DEV" > "$AMDD/unbind" || say "WARN: amdgpu unbind failed"
sleep 1
echo "$DEV" > "$VFIOD/bind" || { say "vfio rebind FAILED — device now UNBOUND"; exit 1; }
say "vfio-pci bound (warm device). dmesg note any reset below:"
dmesg | tail -n 5 | grep -iE "vfio|reset" || true
lspci -nnk -s 10:00.0 | tail -2
say "NEXT: start the VM and test the guest driver."
