foreach ($t in @(@('direct','192.168.100.10'), @('via-forward','192.168.100.1'))) {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $c.Connect($t[1], 8443)
    $s = $c.GetStream()
    $s.WriteTimeout = 3000
    $s.ReadTimeout = 3000
    $b = [Text.Encoding]::ASCII.GetBytes("GET / HTTP/1.0`r`n`r`n")
    $s.Write($b, 0, $b.Length)
    $buf = New-Object byte[] 256
    try {
      $r = $s.Read($buf, 0, 256)
      $hex = ($buf[0..([Math]::Max($r,1)-1)] | ForEach-Object { $_.ToString('x2') }) -join ' '
      Write-Output ($t[0] + ': read ' + $r + ' bytes: ' + $hex.Substring(0, [Math]::Min(48, $hex.Length)))
    } catch { Write-Output ($t[0] + ': connected, no response within 3s') }
    $c.Close()
  } catch { Write-Output ($t[0] + ': connect failed: ' + $_.Exception.Message) }
}
