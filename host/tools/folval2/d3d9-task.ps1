# folval2 D3D9 gate probe — task-based execution (interactive desktop required).
#
# Session rules encoded here (see .ai-memory/misconceptions.md):
#   - schtasks /Create via WinRM: ALWAYS /SC ONCE /ST 00:00 — anything else
#     silently fails through the PS arg-mangling layer
#   - /TR points at a cmd STUB FILE (Set-Content -Encoding Ascii), never inline
#   - /IT silently no-ops without a console session — autologon provides it
#   - result file: C:\re\d3d9-s1.txt ; delete before run, poll after
$ErrorActionPreference = 'Stop'

# 1. probe runner script (invoked by the task, writes result file)
Set-Content -Path C:\re\d3d9-probe1.ps1 -Encoding Ascii -Value @'
"adapter count / HAL probe — " + (Get-Date)
& C:\re\d3d9probe.exe
'@

# 2. cmd stub (schtasks /TR target)
Set-Content -Path C:\re\d3d9-run.cmd -Encoding Ascii -Value "@echo off`r`npowershell -ExecutionPolicy Bypass -File C:\re\d3d9-probe1.ps1 > C:\re\d3d9-task.log 2>&1`r`n"

# 3. task definition + run
schtasks /Create /F /TN d3d9probe /TR C:\re\d3d9-run.cmd /SC ONCE /ST 00:00 | Out-Null
Remove-Item C:\re\d3d9-s1.txt, C:\re\d3d9-task.log -ErrorAction SilentlyContinue
schtasks /Run /TN d3d9probe | Out-Null
"task d3d9probe triggered"
