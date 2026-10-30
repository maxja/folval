# folval2 GPU readiness — restart the AMD GPU device until problem code clears.
#
# Session rules encoded here (see .ai-memory/misconceptions.md):
#   - Cold boot: Radeon starts 43; pnputil /restart-device fixes to OK (stable config)
#   - AMD-only-VGA = 43 stuck; restart CANNOT recover that config
#   - Requires console session (autologon vagrant/vagrant provides it)
$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_1002&DEV_164E*' } | Select-Object -First 1
$prob = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
"gpu before: problem=$prob"
if ($prob -ne 0) {
    pnputil /restart-device "$($dev.InstanceId)" | Out-Null
    Start-Sleep 10
    $dev2 = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_1002&DEV_164E*' } | Select-Object -First 1
    $prob2 = (Get-PnpDeviceProperty -InstanceId $dev2.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    "gpu after restart: problem=$prob2"
}
"--- unknown devices remaining ---"
Get-PnpDevice -PresentOnly | Where-Object { $_.Status -eq 'Error' } | ForEach-Object { $_.Name }
