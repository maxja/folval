$ProgressPreference = 'SilentlyContinue'
# Block the Steam overlay PERMANENTLY: replace the DLL paths with non-empty
# directories - Steam's core-file validation repairs missing/renamed DLLs on
# every start (observed 2x on 2026-10-20) but cannot replace a directory
# with a file. Overlay injection then fails silently; game boots with
# Reset -> S_OK.
$s = 'C:\Program Files (x86)\Steam'
foreach ($f in 'GameOverlayRenderer.dll','GameOverlayRenderer64.dll') {
  $p = Join-Path $s $f
  if (Test-Path $p -PathType Leaf) {
    Move-Item $p "$p.folvalbak3" -Force
    Write-Output "moved file: $f"
  }
  if (-not (Test-Path $p)) {
    New-Item -ItemType Directory -Path $p | Out-Null
    Set-Content (Join-Path $p 'blocked.txt') 'folval overlay block 2026-10-20'
    Write-Output "dir-block: $f"
  } else {
    Write-Output "already blocked: $f"
  }
}
# also lowercase variants (loader may probe either case)
foreach ($f in 'gameoverlayrenderer.dll','gameoverlayrenderer64.dll') {
  $p = Join-Path $s $f
  if (Test-Path $p -PathType Leaf) { Move-Item $p "$p.folvalbak3" -Force; Write-Output "moved file: $f" }
}
Write-Output 'overlay dir-block in place'
