# One-shot NCSI diagnostics: DNS view, end-to-end HTTP through DNAT, profile.
Resolve-DnsName www.msftconnecttest.com -Server 192.168.100.1 |
    Select-Object Name, Type, IPAddress | Format-Table -AutoSize | Out-String

try {
    $r = Invoke-WebRequest -UseBasicParsing http://www.msftconnecttest.com/connecttest.txt -TimeoutSec 10
    "IWR: HTTP " + $r.StatusCode + " body=[" + $r.Content + "]"
} catch {
    "IWR-FAILED: " + $_.Exception.Message
}

Get-NetConnectionProfile | Select-Object InterfaceAlias, IPv4Connectivity |
    Format-Table -AutoSize | Out-String
