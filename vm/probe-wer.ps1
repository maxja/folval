Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000} -MaxEvents 3 -ErrorAction SilentlyContinue |
  ForEach-Object {
    $m = $_.Message -split "`r?`n"
    Write-Output ($m | Where-Object { $_ -match 'mqelserver|Faulting|Exception' } | Select-Object -First 6)
    Write-Output '---'
  }
