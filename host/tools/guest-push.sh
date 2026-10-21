#!/bin/bash
# Push a file to the guest runtime dir C:\re\ via the gateway /push/ staging.
# Usage: host/tools/guest-push.sh <local-file> [remote-name]   (default: basename)
set -euo pipefail
cd "$(dirname "$0")/../.."
f="$1"; name="${2:-$(basename "$f")}"
dest="C:\\re\\$name"
cp "$f" "host/push/$name"
bash host/tools/guest-run.sh -c "Invoke-WebRequest -UseBasicParsing 'http://192.168.100.1/push/$name' -OutFile '$dest' -TimeoutSec 120; (Get-Item '$dest').Length"
