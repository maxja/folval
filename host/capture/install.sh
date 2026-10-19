#!/usr/bin/env bash
# folval — (re)deploy the pcap capture service (host/capture/folval-capture.service).
# Run on the HOST as root: sudo ./host/capture/install.sh
#
# What it does:
#   1. copies the unit from this repo into /etc/systemd/system/
#   2. renders /etc/sysconfig/folval-capture (FOLVAL_CAPTURE_DIR=<repo>/captures/pcap
#      — systemd cannot expand ~/$USER, so the absolute path is baked in)
#   3. daemon-reload + restart (a restart starts a fresh date-stamped ring)
#
# Redeploy after any change to the unit file. If virbr1 does not exist yet
# (isolated network down), the unit waits in ExecStartPre and retries — that
# is normal; check 'systemctl status folval-capture' on the host.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
sysconfig=/etc/sysconfig/folval-capture

if [ "$(id -u)" -ne 0 ]; then
	echo "error: run as root: sudo $here/install.sh" >&2
	exit 1
fi

install -m 0644 "$here/folval-capture.service" /etc/systemd/system/folval-capture.service
printf 'FOLVAL_CAPTURE_DIR=%s/captures/pcap\n' "$repo" > "$sysconfig"
chown root:root "$sysconfig"
chmod 0644 "$sysconfig"

systemctl daemon-reload
systemctl restart folval-capture.service

echo "--- deployed folval-capture ---"
echo "unit:    /etc/systemd/system/folval-capture.service ($(stat -c %y /etc/systemd/system/folval-capture.service | cut -d' ' -f1))"
echo "capture: $sysconfig -> $(cat "$sysconfig")"
echo "state:   $(systemctl is-active folval-capture.service) (activating/waiting is fine if virbr1 is down)"
echo "--- current ring in $repo/captures/pcap ---"
ls -lt "$repo/captures/pcap" | head -5
