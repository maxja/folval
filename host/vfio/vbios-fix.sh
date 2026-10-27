#!/usr/bin/env bash
# FIX: restore the good vbios (previous run replaced it with an 87-byte
# false-positive fragment), then re-extract with FULL validation:
# candidate ROM must carry PCIR with vendor 1002 / device 164e and a sane
# image length before it is accepted.
# Run with sudo:  sudo bash host/vfio/vbios-fix.sh
set -euo pipefail
python3 - <<'EOF'
import struct, hashlib, shutil

path = '/var/lib/libvirt/qemu/vbios.bin'
cur = open(path, 'rb').read()
print("current:", len(cur), "bytes", hashlib.sha256(cur).hexdigest()[:20])

if len(cur) < 10000:
    shutil.copy(path + '.pre-uma', path)
    cur = open(path, 'rb').read()
    print("current was garbage -> restored .pre-uma:", len(cur), "bytes")

data = open('/sys/firmware/acpi/tables/VFCT','rb').read()
valid = None
off = 0
while True:
    sig = data.find(b'\x55\xaa', off)
    if sig < 0:
        break
    off = sig + 1
    try:
        pcir_off = struct.unpack('<H', data[sig+0x18:sig+0x1a])[0]
        if pcir_off < 0x18 or pcir_off > 0x100:
            continue
        pcir = data[sig+pcir_off:sig+pcir_off+0x14]
        if len(pcir) < 0x14 or pcir[:4] != b'PCIR':
            continue
        vendor, dev = struct.unpack('<HH', pcir[4:8])
        img_len = struct.unpack('<H', pcir[0x10:0x12])[0]
        if vendor == 0x1002 and dev == 0x164e and 0x8000 <= img_len <= 0x20000 and sig + img_len <= len(data):
            valid = (sig, img_len)
            break
    except Exception:
        continue

if valid is None:
    print("no valid 1002:164e ROM found in VFCT — deployed vbios left unchanged")
else:
    sig, img_len = valid
    rom = data[sig:sig+img_len]
    print("valid ROM at offset", sig, "-", img_len, "bytes", hashlib.sha256(rom).hexdigest()[:20])
    if rom == cur:
        print("same as deployed — nothing to do")
    else:
        shutil.copy(path, path + '.prev')
        open(path, 'wb').write(rom)
        print("REPLACED deployed vbios (backup: vbios.bin.prev) — VM needs full stop/start")
EOF
