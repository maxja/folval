#!/usr/bin/env bash
# Persistent guest->host staging routes (both were lost at the host reboot).
# Run with sudo:  sudo bash host/vfio/staging-routes.sh
set -euo pipefail

ZONE=$(firewall-cmd --get-zone-of-interface=virbr1 2>/dev/null || true)
ZONE=${ZONE:-libvirt}
echo "virbr1 zone: $ZONE"

# 1) allow guest -> host:8080 directly (the staging server's real port)
firewall-cmd --permanent --zone="$ZONE" --add-port=8080/tcp

# 2) persistent port-80 DNAT -> 8080 (legacy route used by existing guest scripts)
firewall-cmd --permanent --zone="$ZONE" --add-forward-port=port=80:proto=tcp:toport=8080

firewall-cmd --reload >/dev/null
echo "--- $ZONE zone now:"
firewall-cmd --zone="$ZONE" --list-all | sed -n '1,8p'
echo OK
