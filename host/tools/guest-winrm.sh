#!/bin/bash
# folval — run a PowerShell script in the guest over WinRM (fallback when
# qemu-ga is wedged). Usage: bash host/tools/guest-winrm.sh <script.ps1>
set -euo pipefail
cd "$(dirname "$0")/../.."

script_b64=$(iconv -f UTF-8 -t UTF-16LE "$1" | base64 -w0)
vagrant winrm -c "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $script_b64"
