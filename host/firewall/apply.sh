#!/usr/bin/env bash
# folval — idempotent nftables apply for the Phase 2 isolation boundary.
# Run on the HOST as root: sudo ./host/firewall/apply.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ruleset="$here/folval.nft"

if ! command -v nft >/dev/null 2>&1; then
	echo "error: nft not found" >&2
	exit 1
fi

# Idempotent: clear any previous folval table, then load fresh.
nft delete table inet folval 2>/dev/null || true
nft -f "$ruleset"

echo "--- active folval table ---"
nft list table inet folval
echo "--- ok: Phase 2 boundary active on bridge: $(grep -oP 'define BR_IF\s+= "\K[^"]+' "$ruleset") ---"
