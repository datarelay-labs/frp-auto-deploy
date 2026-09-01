# test-windows-same-name-path-ownership.ps1
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    New-Item -ItemType Directory -Path (Get-FrpBinDir) -Force | Out-Null
    New-Item -ItemType Directory -Path (Get-FrpConfigDir) -Force | Out-Null
    Set-Content -LiteralPath (Get-FrpTomlPath) -Value "serverAddr = `"127.0.0.1`"`n"
    if (-not (Test-Path -LiteralPath (Get-FrpFrpcPath))) {
        Set-Content -LiteralPath (Get-FrpFrpcPath) -Value 'managed-frpc-stub'
    }

    $otherDir = Join-Path $env:FRP_WINDOWS_ROOT 'other-product'
    New-Item -ItemType Directory -Path $otherDir -Force | Out-Null
    $otherExe = Join-Path $otherDir 'frpc.exe'
    # Prefer a real runnable binary for path ownership probes.
    $sleepBin = (Get-Command sleep -ErrorAction SilentlyContinue)
    if ($sleepBin) {
        Copy-Item -LiteralPath $sleepBin.Source -Destination $otherExe -Force
    } else {
        Set-Content -LiteralPath $otherExe -Value 'other-frpc'
    }

    $env:FRP_WINDOWS_ALLOW_FAKE_PROCESS = '1'
    # Start a long-lived process and pretend metadata points at otherExe leaf name path.
    # On Linux CI we use sleep as the live process; ownership must still reject because
    # canonical path != managed Get-FrpFrpcPath.
    $proc = Start-Process -FilePath 'sleep' -ArgumentList '30' -PassThru
    try {
        Write-FrpPidFile -ProcessId $proc.Id -ExePath $otherExe
        Assert-FrpTrue (-not (Test-FrpProcessOwned -ProcessId $proc.Id -ExpectedExe $otherExe)) `
            'other-path frpc.exe is not project-owned'
        $stopped = Stop-FrpClient
        Assert-FrpTrue (-not $stopped) 'stop did not claim foreign process'
        Assert-FrpTrue ($null -ne (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) `
            'WINDOWS_SAME_NAME_DIFFERENT_PATH_PROCESS_SURVIVES'
        Assert-FrpTrue ($null -eq (Read-FrpPidMetadata)) 'stale metadata cleared'

        # PID reuse / start-time mismatch: write metadata with wrong started_at.
        Write-FrpPidFile -ProcessId $proc.Id -ExePath (Get-FrpFrpcPath)
        $meta = Read-FrpPidMetadata
        $meta.started_at = '2000-01-01T00:00:00Z'
        $meta | ConvertTo-Json -Compress | Set-Content -LiteralPath (Get-FrpPidPath)
        Assert-FrpTrue (-not (Test-FrpProcessOwned -ProcessId $proc.Id -ExpectedExe (Get-FrpFrpcPath) -StartedAt $meta.started_at)) `
            'WINDOWS_PID_REUSE_REJECTED'
        Write-FrpTestPass 'WINDOWS_SAME_NAME_DIFFERENT_PATH_PROCESS_SURVIVES'
        Write-FrpTestPass 'WINDOWS_PID_REUSE_REJECTED'
    } finally {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
} finally {
    Remove-Item Env:FRP_WINDOWS_ALLOW_FAKE_PROCESS -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
