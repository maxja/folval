$ProgressPreference = 'SilentlyContinue'
$s = 'C:\Program Files (x86)\Steam'
foreach ($f in 'gameoverlayrenderer.dll','gameoverlayrenderer64.dll') {
  $p = Join-Path $s $f
  if (Test-Path $p) {
    Rename-Item -Path $p -NewName ($f + '.folvalbak') -Force
    Write-Output ("renamed: " + $f)
  } elseif (Test-Path ($p + '.folvalbak')) {
    Write-Output ("already disabled: " + $f)
  } else { Write-Output ("not found: " + $f) }
}
# stop Steam cleanly-ish (client + helpers)
foreach ($n in 'steam','steamwebhelper','steamservice') {
  Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force
  Write-Output ("stopped: " + $n)
}
