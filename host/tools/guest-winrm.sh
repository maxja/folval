#!/bin/bash
# folval — run PowerShell in the guest over WinRM (fallback when qemu-ga is
# wedged). Usage:
#   bash host/tools/guest-winrm.sh <script.ps1>   # run a local script file
#   bash host/tools/guest-winrm.sh -c '<ps>'      # run an inline command
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ "${1:-}" == "-c" ]]; then
    script_b64=$(printf '%s' "${2:?usage: guest-winrm.sh -c '<powershell>'}" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
else
    script_b64=$(iconv -f UTF-8 -t UTF-16LE "${1:?usage: guest-winrm.sh <script.ps1> | -c '<powershell>'}" | base64 -w0)
fi
vagrant winrm -c "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $script_b64"
