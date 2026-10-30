# folval2 device problem-code snapshot (GPU + PSP + any error devices).
# PSP = PCI\VEN_1022&DEV_1649 (amdpsp 5.17.0.0 installed 2026-10-28, problem=0 expected).
"=== GPU (VEN_1002 DEV_164E) ==="
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_1002&DEV_164E*' } | ForEach-Object {
    $prob = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    "{0}  [{1}] problem={2}" -f $_.Name, $_.Status, $prob
}
"=== PSP (VEN_1022 DEV_1649) ==="
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_1022&DEV_1649*' } | ForEach-Object {
    $prob = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    "{0}  [{1}] problem={2}" -f $_.Name, $_.Status, $prob
}
"=== error devices ==="
(Get-PnpDevice -PresentOnly | Where-Object { $_.Status -eq 'Error' } | Measure-Object).Count
