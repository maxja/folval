# folval2 monitor enumeration — D3D9 only enumerates desktop-attached adapters.
# WmiMonitorID present + non-empty = a sink exists on the (emulated) connector.
$m = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue
if ($m) {
    $m | ForEach-Object {
        $n = ($_.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ''
        "monitor: '$n'"
    }
} else {
    "monitors: none"
}
