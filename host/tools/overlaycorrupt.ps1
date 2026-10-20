$ProgressPreference = 'SilentlyContinue'
# overlaycorrupt.ps1 - post-Steam-start neutralization.
# Steam's startup validation restores/repairs the overlay DLLs (it defeats
# renames AND ACL-armored dir blocks). But validation only runs at START:
# truncating the DLLs after Steam settles breaks LoadLibrary inside the game
# (injection fails gracefully -> Reset -> S_OK) and Steam won't notice until
# its next restart (when this runs again via the dispatcher).
$s = 'C:\Program Files (x86)\Steam'
foreach ($f in 'GameOverlayRenderer.dll','gameoverlayrenderer.dll','GameOverlayRenderer64.dll','gameoverlayrenderer64.dll') {
  $p = Join-Path $s $f
  if (Test-Path $p -PathType Leaf) {
    $len = (Get-Item $p -Force).Length
    if ($len -gt 0) {
      Set-Content -LiteralPath $p -Value $null -Force   # truncate to 0 bytes
      Write-Output "corrupted: $f (was $len)"
    }
  } elseif (Test-Path $p -PathType Container) {
    # leftover dir block from an earlier scheme: remove marker, dir can stay
    Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  }
}
