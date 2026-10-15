#!/bin/bash
# Dry-run check: validate the guest-exec JSON lab.sh would send for
# vm/debloat.ps1 (structure + payload size) without touching the guest.
cd "$(dirname "$0")/../.."
script_b64=$(iconv -f UTF-8 -t UTF-16LE vm/debloat.ps1 | base64 -w0)
printf '{"execute":"guest-exec","arguments":{"path":"C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe","arg":["-NoProfile","-ExecutionPolicy","Bypass","-EncodedCommand","%s"],"capture-output":true}}' "$script_b64" > /tmp/exec.json
python3 - "$script_b64" <<'EOF'
import json, sys
d = json.load(open('/tmp/exec.json'))
b64 = d['arguments']['arg'][4]
assert b64 == sys.argv[1], 'payload mismatch between bash and file'
print('JSON_OK path=%s b64len=%d' % (d['arguments']['path'], len(b64)))
EOF
