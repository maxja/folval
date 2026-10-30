# folval2 PSP driver install — amdpsp.inf 5.17.0.0 from Microsoft Update Catalog.
# Source: WU catalog "AMD PSP" Win10 x64 cab (2026-10); staged host/push/psp/.
# Rule learned 2026-10-28: pnputil validates EVERY INF-referenced file —
# amdtee_api32.dll is referenced and MUST be present or /add-driver fails
# with "cannot find the file specified".
"=== PSP driver install ==="
pnputil /add-driver C:\re\psp\amdpsp.inf /install | Select-String -Pattern 'Added|Driver package|success|failed'
"=== PSP device state ==="
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_1022&DEV_1649*' } | ForEach-Object {
    $prob = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    "{0}  [{1}] problem={2}" -f $_.Name, $_.Status, $prob
}
