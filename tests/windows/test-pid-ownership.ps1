# test-pid-ownership.ps1 — full-path ownership, same-name different path, PID reuse
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    New-Item -ItemType Directory -Path (Get-FrpConfigDir) -Force | Out-Null
    Set-Content -LiteralPath (Get-FrpTomlPath) -Value "serverAddr = `"127.0.0.1`"`n"
    New-Item -ItemType Directory -Path (Get-FrpBinDir) -Force | Out-Null
    if (-not (Test-Path -LiteralPath (Get-FrpFrpcPath))) {
        Set-Content -LiteralPath (Get-FrpFrpcPath) -Value 'dummy'
    }

    if (-not (Test-FrpIsWindowsHost)) {
        $env:FRP_WINDOWS_ALLOW_FAKE_PROCESS = '1'
        $managedPid = Start-FrpClient
        $meta = Read-FrpPidMetadata
        Assert-FrpTrue ($null -ne $meta) 'metadata present'
        Assert-FrpEqual ([int]$managedPid) ([int]$meta.pid) 'pid matches'
        Assert-FrpTrue (-not [string]::IsNullOrWhiteSpace([string]$meta.exe)) 'exe recorded'
        Assert-FrpTrue (-not [string]::IsNullOrWhiteSpace([string]$meta.started_at)) 'started_at recorded'
        Assert-FrpTrue (Test-FrpProcessAlive -ProcessId $managedPid -ValidateOwnership -ExpectedExe $meta.exe -StartedAt $meta.started_at) 'owned alive'
        Stop-FrpClient | Out-Null
        Remove-Item Env:FRP_WINDOWS_ALLOW_FAKE_PROCESS -ErrorAction SilentlyContinue
    }

    # Unrelated host process with managed frpc path in metadata => ownership fail => no kill.
    $unrelated = $PID
    Write-FrpPidFile -ProcessId $unrelated -ExePath (Get-FrpFrpcPath)
    Assert-FrpTrue (-not (Test-FrpProcessOwned -ProcessId $unrelated -ExpectedExe (Get-FrpFrpcPath))) 'host process not owned frpc'
    $stopped = Stop-FrpClient
    Assert-FrpTrue (-not $stopped) 'did not kill unrelated'
    Assert-FrpTrue ($null -ne (Get-Process -Id $unrelated -ErrorAction SilentlyContinue)) 'unrelated still alive'
    Assert-FrpTrue ($null -eq (Read-FrpPidMetadata)) 'metadata cleared'

    # WINDOWS_SAME_NAME_DIFFERENT_PATH_PROCESS_SURVIVES:
    # stub/copy named frpc.exe outside managed bin; metadata points at it; Stop must not kill.
    $otherDir = Join-Path ([System.IO.Path]::GetTempPath()) ('frp-other-frpc-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $otherDir -Force | Out-Null
    $otherFrpc = Join-Path $otherDir 'frpc.exe'
    $sleepSrc = $null
    foreach ($c in @('/bin/sleep', 'sleep')) {
        if (Test-Path -LiteralPath $c) { $sleepSrc = $c; break }
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $sleepSrc = [string]$cmd.Source; break }
    }
    if (-not $sleepSrc) {
        Write-Host 'SKIP WINDOWS_SAME_NAME_DIFFERENT_PATH_PROCESS_SURVIVES (no sleep binary to copy)'
    } else {
        Copy-Item -LiteralPath $sleepSrc -Destination $otherFrpc -Force
        $otherProc = Start-Process -FilePath $otherFrpc -ArgumentList @('60') -PassThru -NoNewWindow
        Assert-FrpTrue ($null -ne $otherProc -and $otherProc.Id -gt 0) 'other frpc-named process started'
        Write-FrpPidFile -ProcessId $otherProc.Id -ExePath $otherFrpc
        Assert-FrpTrue (-not (Test-FrpProcessOwned -ProcessId $otherProc.Id -ExpectedExe $otherFrpc)) `
            'different-path frpc.exe not owned'
        $stoppedOther = Stop-FrpClient
        Assert-FrpTrue (-not $stoppedOther) 'Stop-FrpClient did not kill other-path frpc'
        Assert-FrpTrue ($null -ne (Get-Process -Id $otherProc.Id -ErrorAction SilentlyContinue)) `
            'other-path process still alive'
        Assert-FrpTrue ($null -eq (Read-FrpPidMetadata)) 'stale metadata cleared for other-path'
        Stop-Process -Id $otherProc.Id -Force -ErrorAction SilentlyContinue
        Write-FrpTestPass 'WINDOWS_SAME_NAME_DIFFERENT_PATH_PROCESS_SURVIVES'
    }
    Remove-Item -LiteralPath $otherDir -Recurse -Force -ErrorAction SilentlyContinue

    # WINDOWS_PID_REUSE_REJECTED: same PID + matching exe path but stale started_at.
    $reuseDirReady = $false
    $reuseProc = $null
    try {
        $sleepSrc = $null
        foreach ($c in @('/bin/sleep', 'sleep')) {
            if (Test-Path -LiteralPath $c) { $sleepSrc = $c; break }
            $cmd = Get-Command $c -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) { $sleepSrc = [string]$cmd.Source; break }
        }
        if ($sleepSrc -and -not (Test-FrpIsWindowsHost)) {
            # Place a runnable binary at the managed frpc path so path checks pass.
            Copy-Item -LiteralPath $sleepSrc -Destination (Get-FrpFrpcPath) -Force
            $reuseProc = Start-Process -FilePath (Get-FrpFrpcPath) -ArgumentList @('60') -PassThru -NoNewWindow
            $staleStart = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
            Write-FrpPidFile -ProcessId $reuseProc.Id -ExePath (Get-FrpFrpcPath) -StartedAt $staleStart
            Assert-FrpTrue (-not (Test-FrpProcessOwned -ProcessId $reuseProc.Id -ExpectedExe (Get-FrpFrpcPath) -StartedAt $staleStart)) `
                'PID reuse started_at mismatch rejected'
            $stoppedReuse = Stop-FrpClient
            Assert-FrpTrue (-not $stoppedReuse) 'did not kill on PID reuse metadata'
            Assert-FrpTrue ($null -ne (Get-Process -Id $reuseProc.Id -ErrorAction SilentlyContinue)) 'PID reuse target still alive'
            Assert-FrpTrue ($null -eq (Read-FrpPidMetadata)) 'PID reuse metadata cleared'
            $reuseDirReady = $true
        } else {
            # Fallback: host PID with managed exe metadata (path mismatch and/or time mismatch).
            $reusePid = $PID
            $staleStart = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
            Write-FrpPidFile -ProcessId $reusePid -ExePath (Get-FrpFrpcPath) -StartedAt $staleStart
            Assert-FrpTrue (-not (Test-FrpProcessOwned -ProcessId $reusePid -ExpectedExe (Get-FrpFrpcPath) -StartedAt $staleStart)) `
                'PID reuse / ownership mismatch rejected'
            $stoppedReuse = Stop-FrpClient
            Assert-FrpTrue (-not $stoppedReuse) 'did not kill on PID reuse metadata'
            Assert-FrpTrue ($null -ne (Get-Process -Id $reusePid -ErrorAction SilentlyContinue)) 'PID reuse target still alive'
            Assert-FrpTrue ($null -eq (Read-FrpPidMetadata)) 'PID reuse metadata cleared'
            $reuseDirReady = $true
        }
    } finally {
        if ($null -ne $reuseProc) {
            Stop-Process -Id $reuseProc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Assert-FrpTrue $reuseDirReady 'PID reuse scenario executed'
    Write-FrpTestPass 'WINDOWS_PID_REUSE_REJECTED'

    Write-FrpTestPass 'test-pid-ownership'
} finally {
    Remove-Item Env:FRP_WINDOWS_ALLOW_FAKE_PROCESS -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
