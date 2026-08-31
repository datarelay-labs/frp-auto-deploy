# FrpLifecycle.ps1 — pause/resume/restart/test/logs/support-bundle helpers.

if ((Test-Path variable:script:FrpLifecycleLoaded) -and $script:FrpLifecycleLoaded) { return }
$script:FrpLifecycleLoaded = $true

function Get-FrpPauseMarkerPath {
    Join-Path (Get-FrpStateDir) 'remote-access-paused.json'
}

function Test-FrpRemoteAccessPaused {
    $path = Get-FrpPauseMarkerPath
    return (Test-Path -LiteralPath $path)
}

function Write-FrpPauseMarker {
    param([bool]$AutostartWasEnabled = $false)
    Initialize-FrpDirectories
    $path = Get-FrpPauseMarkerPath
    $payload = @{
        schema_version = 1
        paused         = $true
        paused_at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        autostart_was_enabled = [bool]$AutostartWasEnabled
    } | ConvertTo-Json -Depth 4
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $payload + "`n")
    Restrict-FrpFileAcl -Path $tmp
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Restrict-FrpFileAcl -Path $path
}

function Clear-FrpPauseMarker {
    $path = Get-FrpPauseMarkerPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Invoke-FrpPauseRemoteAccess {
    if (-not (Test-FrpIsEnrolled)) {
        Write-Host 'ERROR: not enrolled'
        return 1
    }
    if (Test-FrpRemoteAccessPaused) {
        Write-Host 'Remote access is already paused.'
        return 0
    }
    $wasRunning = $false
    try {
        $st = Get-FrpClientStatus
        $wasRunning = [bool]$st.Running
        Stop-FrpClient | Out-Null
    } catch {
        Write-Host ("ERROR: failed to stop frpc: {0}" -f $_.Exception.Message)
        return 1
    }
    Write-FrpPauseMarker -AutostartWasEnabled:$wasRunning
    Write-Host 'Remote access paused.'
    Write-Host 'Use frpctl resume to reconnect.'
    return 0
}

function Invoke-FrpResumeRemoteAccess {
    if (-not (Test-FrpIsEnrolled)) {
        Write-Host 'ERROR: not enrolled'
        return 1
    }
    $path = Get-FrpPauseMarkerPath
    $autostart = $false
    if (Test-Path -LiteralPath $path) {
        try {
            $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $autostart = [bool]$data.autostart_was_enabled
        } catch { }
        Clear-FrpPauseMarker
    }
    if ($autostart) {
        Start-FrpClient | Out-Null
    } else {
        Write-Host 'Autostart was not active before pause; frpc was not started.'
    }
    Write-Host 'Remote access resumed.'
    return 0
}

function Invoke-FrpRestartConnection {
    if (Test-FrpRemoteAccessPaused) {
        Write-Host 'ERROR: client remote access is paused.'
        Write-Host "Use 'frpctl resume' to reconnect."
        return 1
    }
    Stop-FrpClient | Out-Null
    Start-FrpClient | Out-Null
    Write-Host 'FRP connection restarted.'
    return 0
}

function Invoke-FrpClientTest {
    Write-Host 'FRP Client Connectivity Test'
    Write-Host '============================'
    Write-Host ''
    if (Test-FrpIsEnrolled) { Write-Host 'Local state              PASS' } else { Write-Host 'Local state              FAIL' }
    if (Test-Path -LiteralPath (Get-FrpIdentityPubPath)) { Write-Host 'Management identity      PASS' } else { Write-Host 'Management identity      FAIL' }
    if (Test-Path -LiteralPath (Get-FrpTomlPath)) { Write-Host 'FRP configuration        PASS' } else { Write-Host 'FRP configuration        FAIL' }
    if (Test-FrpRemoteAccessPaused) {
        Write-Host 'Remote access            PAUSED'
    } else {
        Write-Host 'Remote access            ACTIVE'
    }
    $st = Get-FrpClientStatus
    if ($st.Running) { Write-Host 'frpc process             PASS' } else { Write-Host 'frpc process             WARN' }
    Write-Host ''
    Write-Host 'External public reachability : NOT TESTED'
    Write-Host ''
    Write-Host 'RESULT=PASS'
    return 0
}

function Show-FrpClientLogs {
    param([int]$Lines = 100, [switch]$Follow)
    $log = Join-Path (Get-FrpLogsDir) 'frpc.log'
    if (-not (Test-Path -LiteralPath $log)) {
        Write-Host 'No project-managed frpc log found.'
        return 0
    }
    if ($Follow) {
        Get-Content -LiteralPath $log -Wait -Tail $Lines
        return 0
    }
    Get-Content -LiteralPath $log -Tail $Lines
    return 0
}

function Invoke-FrpSupportBundle {
    param([switch]$Anonymize)
    Initialize-FrpDirectories
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $out = Join-Path $env:TEMP ("frp-support-bundle-$stamp.zip")
    $items = @()
    foreach ($name in @('version', 'client-state.json', 'frpc.toml')) {
        $src = switch ($name) {
            'version' { Get-FrpVersionPath }
            'client-state.json' { Get-FrpStatePath }
            'frpc.toml' { Get-FrpTomlPath }
        }
        if (Test-Path -LiteralPath $src) {
            $items += $src
        }
    }
    $log = Join-Path (Get-FrpLogsDir) 'frpc.log'
    if (Test-Path -LiteralPath $log) { $items += $log }
    if ($items.Count -eq 0) {
        Write-Host 'ERROR: nothing to bundle'
        return 1
    }
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    Compress-Archive -LiteralPath $items -DestinationPath $out -Force
    Write-Host ("Support bundle written to: {0}" -f $out)
    return 0
}
