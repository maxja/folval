#!/usr/bin/env bash
# Open brain ports to the LAN zone (persistent) — needed once the game VM lives
# on the Proxmox box: it must reach staging (:8080) and the SNI gateway (:8443).
# Run with sudo:  sudo bash host/tools/brain-lan-open.sh
set -euo pipefail

# detect the zone of the default-route interface (LAN), not virbr1's zone
LAN_IF=$(ip route show default | awk '{print $5; exit}')
ZONE=$(firewall-cmd --get-zone-of-interface="$LAN_IF" 2>/dev/null || true)
ZONE=${ZONE:-public}
echo "LAN interface: $LAN_IF (zone: $ZONE)"

firewall-cmd --permanent --zone="$ZONE" --add-port=8080/tcp
firewall-cmd --permanent --zone="$ZONE" --add-port=8443/tcp
firewall-cmd --reload >/dev/null
echo "--- $ZONE zone ports now:"
firewall-cmd --zone="$ZONE" --list-ports
echo OK
