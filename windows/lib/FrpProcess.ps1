# FrpProcess.ps1 — start/stop/status for project-managed frpc.

if ($script:FrpProcessLoaded) { return }
$script:FrpProcessLoaded = $true

function Read-FrpPidFile {
    $path = Get-FrpPidPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = ([System.IO.File]::ReadAllText($path)).Trim()
    $pidVal = 0
    if (-not [int]::TryParse($raw, [ref]$pidVal)) { return $null }
    if ($pidVal -le 0) { return $null }
    return $pidVal
}

function Write-FrpPidFile {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    Initialize-FrpDirectories
    $path = Get-FrpPidPath
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, ([string]$ProcessId) + "`n")
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Clear-FrpPidFile {
    $path = Get-FrpPidPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Test-FrpProcessAlive {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Clear-FrpStalePid {
    $pidVal = Read-FrpPidFile
    if ($null -eq $pidVal) { return }
    if (-not (Test-FrpProcessAlive -ProcessId $pidVal)) {
        Clear-FrpPidFile
    }
}

function Start-FrpClient {
    <#
    .SYNOPSIS
      Start frpc in the background from existing config. No re-enroll.
    #>
    param(
        [switch]$Force
    )
    Initialize-FrpDirectories
    Clear-FrpStalePid

    if (-not (Test-Path -LiteralPath (Get-FrpTomlPath))) {
        throw 'ERROR: frpc.toml is missing; enroll this client first (install-client.ps1 -ZeroTouch ...)'
    }
    if (-not (Test-Path -LiteralPath (Get-FrpFrpcPath))) {
        throw 'ERROR: frpc.exe is missing; run update or reinstall'
    }

    $existing = Read-FrpPidFile
    if ($null -ne $existing -and (Test-FrpProcessAlive -ProcessId $existing)) {
        if (-not $Force) {
            Write-Host ("frpc already running (pid {0})" -f $existing)
            return $existing
        }
        Stop-FrpClient | Out-Null
    }

    if (-not (Test-FrpIsWindowsHost)) {
        # Linux CI: spawn a disposable sleep process so stop won't kill the test host.
        if ($env:FRP_WINDOWS_ALLOW_FAKE_PROCESS -eq '1') {
            $sleepBin = $null
            foreach ($c in @('sleep', '/bin/sleep')) {
                if (Get-Command $c -ErrorAction SilentlyContinue) { $sleepBin = $c; break }
                if (Test-Path -LiteralPath $c) { $sleepBin = $c; break }
            }
            if (-not $sleepBin) { throw 'ERROR: sleep not available for fake process test' }
            $fake = Start-Process -FilePath $sleepBin -ArgumentList @('120') -PassThru -NoNewWindow
            Write-FrpPidFile -ProcessId $fake.Id
            Write-Host ("frpc fake-started under test pid {0}" -f $fake.Id)
            return $fake.Id
        }
        throw 'ERROR: starting frpc.exe requires Windows (or set FRP_WINDOWS_ALLOW_FAKE_PROCESS=1 for tests)'
    }

    $frpc = Get-FrpFrpcPath
    $toml = Get-FrpTomlPath
    $log = Get-FrpLogPath
    $argList = @('-c', $toml)
    # Window-close resilient: Hidden + not tied to console
    $p = Start-Process -FilePath $frpc -ArgumentList $argList -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $log
    if (-not $p -or $p.Id -le 0) {
        throw 'ERROR: failed to start frpc'
    }
    Write-FrpPidFile -ProcessId $p.Id
    Start-Sleep -Milliseconds 400
    if (-not (Test-FrpProcessAlive -ProcessId $p.Id)) {
        Clear-FrpPidFile
        throw 'ERROR: frpc exited immediately; check logs\frpc.log'
    }
    Write-Host ("frpc started (pid {0})" -f $p.Id)
    return $p.Id
}

function Stop-FrpClient {
    Clear-FrpStalePid
    $pidVal = Read-FrpPidFile
    if ($null -eq $pidVal) {
        Write-Host 'frpc is not running'
        return $false
    }
    if (-not (Test-FrpProcessAlive -ProcessId $pidVal)) {
        Clear-FrpPidFile
        Write-Host 'frpc is not running (cleared stale pid)'
        return $false
    }
    # Kill only the project-managed PID from our pid file.
    try {
        Stop-Process -Id $pidVal -Force -ErrorAction Stop
    } catch {
        throw ("ERROR: failed to stop frpc pid {0}" -f $pidVal)
    }
    Clear-FrpPidFile
    Write-Host ("frpc stopped (pid {0})" -f $pidVal)
    return $true
}

function Get-FrpClientStatus {
    Clear-FrpStalePid
    $pidVal = Read-FrpPidFile
    $running = $false
    if ($null -ne $pidVal -and (Test-FrpProcessAlive -ProcessId $pidVal)) {
        $running = $true
    }
    $enrolled = Test-FrpIsEnrolled
    $state = $null
    if (Test-Path -LiteralPath (Get-FrpStatePath)) {
        try { $state = Read-FrpClientState } catch { }
    }
    return [pscustomobject]@{
        Running   = $running
        Pid       = $pidVal
        Enrolled  = $enrolled
        StatePath = (Get-FrpStatePath)
        TomlPath  = (Get-FrpTomlPath)
        FrpcPath  = (Get-FrpFrpcPath)
        Server    = $(if ($state) { $state.frp_server } else { $null })
        Transport = $(if ($state) { $state.frp_transport } else { $null })
    }
}
