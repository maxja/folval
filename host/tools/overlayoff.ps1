$ProgressPreference = 'SilentlyContinue'
# 1. stop Steam cleanly (it repairs overlay DLLs on start otherwise)
foreach ($n in 'steam','steamwebhelper','steamservice','PublicLauncher') {
  Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force
}
Start-Sleep -Seconds 2

# 2. disable in-game overlay in config.vdf — survives restarts (key is
#    "EnableInGameOverlay" under InstallConfigStore/.../Steam; most configs
#    have it set to 1. If absent we skip -replace and rely on DLL renames.)
$vdf = 'C:\Program Files (x86)\Steam\config\config.vdf'
if (Test-Path $vdf) {
  $txt = Get-Content $vdf -Raw
  Copy-Item $vdf "$vdf.folvalbak" -Force
  if ($txt -match '"EnableInGameOverlay"\s+"1"') {
    $txt = $txt -replace '"EnableInGameOverlay"\s+"1"', '"EnableInGameOverlay" "0"'
    Set-Content $vdf $txt -NoNewline
    Write-Output 'config.vdf: EnableInGameOverlay 1 -> 0'
  } elseif ($txt -match '"EnableInGameOverlay"') {
    Write-Output 'config.vdf: EnableInGameOverlay already != 1'
  } else {
    Write-Output 'config.vdf: key absent - relying on DLL renames only'
  }
} else { Write-Output 'config.vdf not found' }

# 3. re-rename the repaired overlay DLLs (belt+braces; .bak2 so the original
#    folvalbak from 2026-10-19 is preserved as evidence of the first rename)
$s = 'C:\Program Files (x86)\Steam'
foreach ($f in 'GameOverlayRenderer.dll','gameoverlayrenderer.dll','GameOverlayRenderer64.dll','gameoverlayrenderer64.dll') {
  $p = Join-Path $s $f
  if (Test-Path $p) {
    Move-Item $p "$p.folvalbak2" -Force
    Write-Output "renamed: $f"
  }
}
Write-Output 'overlay: config disabled + dlls renamed; restart Steam via ui-start'
