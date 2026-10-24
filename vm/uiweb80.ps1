param([string]$Root = "$(if ($env:FOLVAL_GAMEDATA) { $env:FOLVAL_GAMEDATA } else { (Get-ChildItem 'C:\Program Files (x86)\Steam\steamapps\common\*\GameData' -Directory | Select-Object -First 1).FullName })")
$ProgressPreference = 'SilentlyContinue'
# Minimal static file server on :80 for the game's local webview
# (lobbyPageUrl http://localhost/gamedata/UI/...). The engine's own
# ConnectServer is bound-but-dead after certain boots; this replaces it.
# Root: the title's GameData dir (name elided per repo policy) — first match
# under the default Steam library; override with -Root or FOLVAL_GAMEDATA.
# NOTE: param() MUST stay the first statement (only comments may precede) —
# else PowerShell parses it as a command ('param' is not recognized) and all
# arguments are silently ignored (defaults still bind via the side-effecting
# argument expression, which masked the bug for weeks).
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://+:80/')
$listener.Start()
"MIME server: $Root on :80"
$mime = @{ '.html'='text/html'; '.htm'='text/html'; '.js'='application/javascript';
           '.css'='text/css'; '.png'='image/png'; '.jpg'='image/jpeg'; '.jpeg'='image/jpeg';
           '.gif'='image/gif'; '.json'='application/json'; '.xml'='application/xml';
           '.swf'='application/x-shockwave-flash'; '.mp3'='audio/mpeg'; '.ogg'='audio/ogg';
           '.ttf'='application/octet-stream'; '.woff'='application/font-woff' }
while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
    $path = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath)
    # The engine's lobbyPageUrl is http://localhost/gamedata/UI/... but the
    # files live under <root>\Data\UI\... — map the /gamedata/ prefix to the
    # Data subfolder (naive as-is mapping 404s and the CEF UI dies at +10s).
    if ($path -like '/gamedata/*') { $path = '/Data' + $path.Substring('/gamedata'.Length) }
    $rel = $path.TrimStart('/') -replace '/', '\'
    $file = Join-Path $Root $rel
    if ((Test-Path $file -PathType Leaf) -and ((Resolve-Path $file).Path -like "$Root*")) {
      $buf = [IO.File]::ReadAllBytes($file)
      $ext = [IO.Path]::GetExtension($file).ToLower()
      $ctx.Response.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
      $ctx.Response.ContentLength64 = $buf.Length
      $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    } else {
      $ctx.Response.StatusCode = 404
      $w = [Text.Encoding]::UTF8.GetBytes("nope: $path")
      $ctx.Response.OutputStream.Write($w, 0, $w.Length)
    }
    $ctx.Response.Close()
  } catch { }
}
