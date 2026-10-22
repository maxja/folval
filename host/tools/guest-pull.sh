#!/bin/bash
# folval — pull a file out of the guest over WinRM, byte-exact (base64).
# Usage:
#   bash host/tools/guest-pull.sh <guest-path> <out-path> [--strip-cr]
#
# --strip-cr removes CR bytes (Windows text files, e.g. SSLKEYLOGFILE output,
# arrive CRLF — tshark's keylog parser silently loads ZERO secrets from a
# CRLF file; the tell is tls.app_data returning raw ciphertext, every record
# exactly +24B = GCM explicit-nonce 8 + tag 16).
set -euo pipefail
cd "$(dirname "$0")/../.."

GUEST_PATH="${1:?usage: guest-pull.sh <guest-path> <out-path> [--strip-cr]}"
OUT_PATH="${2:?usage: guest-pull.sh <guest-path> <out-path> [--strip-cr]}"
STRIP="${3:-}"

PS="[Convert]::ToBase64String([IO.File]::ReadAllBytes('$GUEST_PATH'))"
B64=$(bash host/tools/guest-winrm.sh -c "$PS" 2>/dev/null | tr -d '\r\n ')

if [[ -n "$B64" ]]; then
    printf '%s' "$B64" | base64 -d > "$OUT_PATH"
else
    echo "guest-pull: empty payload for $GUEST_PATH (file missing?)" >&2
    exit 1
fi

if [[ "$STRIP" == "--strip-cr" ]]; then
    tr -d '\r' < "$OUT_PATH" > "$OUT_PATH.tmp" && mv "$OUT_PATH.tmp" "$OUT_PATH"
fi

echo "guest-pull: $GUEST_PATH -> $OUT_PATH ($(stat -c%s "$OUT_PATH")B$([[ "$STRIP" == "--strip-cr" ]] && echo ', CR-stripped'))"
