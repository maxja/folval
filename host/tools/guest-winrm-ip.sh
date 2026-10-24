#!/bin/bash
# folval — run PowerShell in the guest over WinRM at an EXPLICIT address
# (bypasses vagrant's address resolution, which needs the isolated NIC up).
# Usage: bash host/tools/guest-winrm-ip.sh <ip> <script.ps1>
#        bash host/tools/guest-winrm-ip.sh <ip> -c '<ps>'
set -euo pipefail
cd "$(dirname "$0")/../.."
IP="${1:?ip}"; shift
if [[ "${1:-}" == "-c" ]]; then
    script_b64=$(printf '%s' "${2:?usage: guest-winrm-ip.sh <ip> -c '<ps>' | <script.ps1>}" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
else
    script_b64=$(iconv -f UTF-8 -t UTF-16LE "${1:?usage: guest-winrm-ip.sh <ip> -c '<ps>' | <script.ps1>}" | base64 -w0)
fi
export GEM_HOME=$HOME/.vagrant.d/gems/4.0.7 GEM_PATH=$HOME/.vagrant.d/gems/4.0.7
exec ruby -r winrm -e 'begin
  conn = WinRM::Connection.new(endpoint: "http://" + ARGV[0] + ":5985/wsman",
                               user: "vagrant", password: "vagrant",
                               no_ssl_peer_verification: true)
  ps = "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand " + ARGV[1]
  sh = conn.shell(:powershell)
  out = sh.run(ps)
  $stdout.write(out.stdout)
  $stderr.write(out.stderr)
  exit(out.exitcode.zero? ? 0 : out.exitcode)
ensure
  sh.close rescue nil
end' "$IP" "$script_b64"
