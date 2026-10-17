<#
.SYNOPSIS
    One-shot provisioning of Frida instrumentation for the RE guest (Phase 4a).
.DESCRIPTION
    Idempotent. Fetches pinned artifacts (Python 3.11.5 embed, frida-server
    17.24.1) from the lab gateway /push/ route, installs them to C:\python3 and
    C:\frida, opens the guest firewall for 27042 from the lab subnet, and
    registers a SYSTEM scheduled task (boot-persistent) that runs frida-server
    listening on 0.0.0.0:27042.
.NOTES
    Persistence is a scheduled task, not a Windows service: frida-server is a
    console app that never completes the SCM handshake, so `sc create` always
    times out (1053) and the service is marked FAILED. The ONSTART SYSTEM
    task is the equivalent without adding wrapper binaries (e.g. nssm).
    Run: bash host/tools/guest-run.sh vm/setup_frida.ps1
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PushBase     = "http://192.168.100.1/push"
$PythonVer    = "3.11.5"
$FridaVer     = "17.24.1"
$PythonDir    = "C:\python3"
$FridaDir     = "C:\frida"
$FridaExe     = "$FridaDir\frida-server.exe"
$TaskName     = "FridaServer"
$Listen       = "0.0.0.0:27042"
$LabSubnet    = "192.168.100.0/24"

Write-Output "== folval frida setup (Phase 4a) =="

# 1. Pinned artifacts (fetch from gateway /push/ if not already staged)
New-Item -ItemType Directory -Path C:\temp -Force | Out-Null
$artifacts = @(
    "python-$PythonVer-embed-amd64.zip",
    "frida-server-$FridaVer-windows-x86_64.exe"
)
foreach ($a in $artifacts) {
    $local = "C:\temp\$a"
    if (Test-Path $local) {
        Write-Output "SKIP staged $local"
    } else {
        Write-Output "GET  $PushBase/$a"
        Invoke-WebRequest -Uri "$PushBase/$a" -OutFile $local -UseBasicParsing
    }
}

# 2. Python (portable embed)
if (Test-Path "$PythonDir\python.exe") {
    Write-Output "SKIP python $PythonVer"
} else {
    Write-Output "INST python $PythonVer -> $PythonDir"
    New-Item -ItemType Directory -Path $PythonDir -Force | Out-Null
    Expand-Archive -Path "C:\temp\python-$PythonVer-embed-amd64.zip" -DestinationPath $PythonDir -Force
}

# 3. frida-server
if (Test-Path $FridaExe) {
    Write-Output "SKIP frida-server $FridaVer"
} else {
    Write-Output "INST frida-server $FridaVer -> $FridaExe"
    New-Item -ItemType Directory -Path $FridaDir -Force | Out-Null
    Copy-Item -Path "C:\temp\frida-server-$FridaVer-windows-x86_64.exe" -Destination $FridaExe -Force
}

# 4. Guest firewall: allow inbound 27042 from the lab subnet only
netsh advfirewall firewall delete rule name=$TaskName 2>$null | Out-Null
netsh advfirewall firewall add rule name=$TaskName dir=in action=allow protocol=TCP localport=27042 remoteip=$LabSubnet | Out-Null
Write-Output "OK   firewall rule $TaskName (inbound 27042 from $LabSubnet)"

# 5. Boot-persistent runner: SYSTEM task at boot, run level HIGHEST
sc.exe delete $TaskName 2>$null | Out-Null   # remove any broken service from earlier attempts
$taskCmd = "`"$FridaExe`" -l $Listen"
schtasks.exe /Create /TN $TaskName /TR $taskCmd /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
Write-Output "OK   scheduled task $TaskName (ONSTART, SYSTEM, HIGHEST)"

# 6. Start now via the task scheduler (detached from this WinRM session)
schtasks.exe /Run /TN $TaskName | Out-Null
Start-Sleep -Seconds 3

# 7. Verify
if (netstat -an | Select-String "0.0.0.0:27042" ) {
    Write-Output "OK   frida-server listening on $Listen"
} else {
    Write-Output "FAIL frida-server not listening on $Listen"
    exit 1
}
Write-Output "== frida setup complete =="
