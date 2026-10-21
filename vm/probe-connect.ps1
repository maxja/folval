foreach ($t in @(@('dnat-443', 443), @('direct-8443', 8443))) {
  $c = New-Object Net.Sockets.TcpClient
  $ok = $c.ConnectAsync('192.168.100.1', $t[1]).Wait(3000)
  if ($ok -and $c.Connected) {
    Write-Output ($t[0] + ': TCP connect OK')
    $c.Close()
  } else { Write-Output ($t[0] + ': connect FAILED/TIMEOUT') }
}
