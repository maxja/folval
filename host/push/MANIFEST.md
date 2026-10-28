# host/push/ — local-only staging artifacts

Everything in this directory is gitignored (large binaries). This manifest makes
it reproducible: file, origin, expected SHA256. Rebuild any entry before use.

## Game VM disk (Proxmox migration, Phase A — 2026-10-28)

| File | SHA256 | Notes |
|---|---|---|
| `folval2.qcow2` | `54e8b9d5fc3dbe4fd36fc8f03fb79d0b4e5b839a364d8fa5650f6738e90d4211` | 20.5GiB compressed / 60GiB virtual. Full folval2 box image (Win10 LTSC 21H2, virtio stack, autologon, WinRM, PSP driver, NVIDIA 582.99 driver-store staged as oem24, qemu-ga Running/Automatic, d3d9probe tooling). Converted from `/var/lib/libvirt/images/folly-n-valor_folval2.img` after final prep boot. |

## NVIDIA Quadro P1000 driver

| File | SHA256 | Notes |
|---|---|---|
| `582.99-quadro-rtx-desktop-notebook-win10-win11-64bit-international-dch-whql.exe` | `1c5614b38fb015e5c1218da22c41caf103800d9c1b963b531dda5f0e88ce09d8` | DCH, WHQL. DEV_1CB1 (Quadro P1000) verified present in package INFs. Source: nvidia.com driver download (580-branch still covers Pascal). |

## AMD PSP driver (Microsoft Update Catalog, "AMD PSP" Win10 x64 cab)

| File | SHA256 | Notes |
|---|---|---|
| `psp/amdpsp.inf` | `34025a9d80237a52623d09c2930e17215d402d52b093987bec537d5bc394e67e` | DriverVer 06/11/2021, 5.17.0.0; matches PCI\VEN_1022&DEV_1649 |
| `psp/amdpsp.cat` | `e53a242aae63abd098de895c86bbc7dce72b8483bb4a52eccbead42a78e4579e` | |
| `psp/amdpsp.sys` | `a9653d348502dffb89ca22d87f6520de9aa4ccee65979645f96678b9ec9f3c4a` | |
| `psp/amdtee_api32.dll` | `32b76c03fe42205aa472dc5b822ffb65d027ec5927b94d682ea74e4eba5a4ef6` | **Required** — pnputil validates every INF-referenced file |
| `psp/amdtee_api64.dll` | `e8f4d9b1d55877aaec83b793b6334eabefdb0b9f96a4797f8971c8d35bf07a16` | |

## Serving

The staging HTTP server serves this tree: `python3 -m http.server 8080 --bind
192.168.100.1 --directory host` (run from repo root). Guest route: port-80 DNAT
or direct :8080 — both open persistently via `host/vfio/staging-routes.sh`.
LAN-facing access additionally needs `host/tools/brain-lan-open.sh` (sudo, once).

## Known transfer pitfalls

- Guest curl.exe is 7.55.1: NO `--retry-all-errors` (added 7.71) — rejected
  pre-connect; loop retries manually instead.
- GB-sized downloads: use guest `curl.exe -C -` resume, not Invoke-WebRequest.
- Host `/tmp` is a 31GiB tmpfs — no 35GB temp files there.
- `python3 -m http.server` under nohup dies silently eventually; check
  `ss -tlnp | grep 8080` (beware: llama.cpp also listens on 127.0.0.1:8080 —
  the staging server binds 192.168.100.1).
