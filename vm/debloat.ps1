# folval Phase 3 - quiet-guest provisioner (D6 scope).
# Idempotent: safe to re-run; each step checks current state first and
# reports OK (changed), SKIP (already in shape), or GONE (target absent).
# Runs as Administrator over WinRM. No parameters - single fixed policy.
#
# Scope rationale (D6): this cuts DNS/pcap/Frida-trace noise, it is NOT a
# security boundary. The host nftables ruleset (Phase 2) is the sole
# egress boundary; this script deliberately never touches the Windows
# firewall - blocking guest-side would hide egress attempts from the wire.

$ErrorActionPreference = 'Stop'
Write-Output "== folval debloat (quiet guest) =="

function Set-ServiceState {
    param($Name, $TargetStartup)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Output "GONE service $Name (not installed)"; return }
    if ($svc.StartType -eq $TargetStartup) { Write-Output "SKIP service $Name already $TargetStartup"; return }
    if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    }
    Set-Service -Name $Name -StartupType $TargetStartup
    Write-Output "OK   service $Name -> $TargetStartup"
}

# 1. Noisy services off (WU off per D6; reversible by re-provisioning).
Set-ServiceState -Name 'DiagTrack'        -TargetStartup 'Disabled'
Set-ServiceState -Name 'dmwappushservice' -TargetStartup 'Disabled'
Set-ServiceState -Name 'wuauserv'         -TargetStartup 'Disabled'

# 2. Telemetry policy -> Security (0), the quietest value on LTSC.
$tel = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
if ((Get-ItemProperty -Path $tel -ErrorAction SilentlyContinue).AllowTelemetry -eq 0) {
    Write-Output 'SKIP AllowTelemetry already 0'
} else {
    New-Item -Path $tel -Force | Out-Null
    Set-ItemProperty -Path $tel -Name AllowTelemetry -Value 0 -Type DWord
    Write-Output 'OK   AllowTelemetry -> 0 (Security)'
}

# 3. Telemetry scheduled tasks off (verify existence; absent -> GONE).
$tasks = 'Consolidator','UsbCeip','KernelCeip','MareBackup'
foreach ($t in $tasks) {
    $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if (-not $task) { Write-Output "GONE task $t"; continue }
    if ($task.State -eq 'Disabled') { Write-Output "SKIP task $t already disabled"; continue }
    # Name-only lookup can hit other-task-path clones; pass the exact path.
    # Some tasks throw 0x80070002 from the CIM cmdlet even when found - fall
    # back to schtasks.exe which handles them.
    try {
        Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop | Out-Null
    } catch {
        schtasks.exe /Change /TN ($task.TaskPath + $task.TaskName) /Disable | Out-Null
        if ("$LASTEXITCODE" -ne 0) { Write-Output "FAIL task $t (schtasks exit $LASTEXITCODE)"; continue }
    }
    Write-Output "OK   task $t -> disabled"
}

# 4. SMB1 client off (D6 retained directive; harmless hermetically).
if ((Get-SmbClientConfiguration).EnableSMB1Protocol) {
    Set-SmbClientConfiguration -EnableSMB1Protocol $false -Confirm:$false
    Write-Output 'OK   SMB1 client -> disabled'
} else {
    Write-Output 'SKIP SMB1 client already disabled'
}

# 5. Assertion: firewall profiles stay vanilla (read-only proof for the gate;
#    this script must never write firewall state).
Write-Output '== firewall profiles (must remain DefaultOutboundAction=Allow) =='
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultOutboundAction | Format-Table -AutoSize | Out-String -Width 120 | Write-Output

Write-Output '== debloat complete =='
