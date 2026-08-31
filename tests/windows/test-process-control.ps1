# test-process-control.ps1 — real frpc on Windows; fake process on Linux CI
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    Clear-FrpStalePid
    $st = Get-FrpClientStatus
    Assert-FrpTrue (-not $st.Running) 'not running'

    if (-not (Test-FrpIsWindowsHost)) {
        $env:FRP_WINDOWS_ALLOW_FAKE_PROCESS = '1'
        New-Item -ItemType Directory -Path (Get-FrpConfigDir) -Force | Out-Null
        Set-Content -LiteralPath (Get-FrpTomlPath) -Value "serverAddr = `"127.0.0.1`"`n"
        New-Item -ItemType Directory -Path (Get-FrpBinDir) -Force | Out-Null
        Set-Content -LiteralPath (Get-FrpFrpcPath) -Value 'dummy'
        $pid1 = Start-FrpClient
        $st2 = Get-FrpClientStatus
        Assert-FrpTrue $st2.Running 'fake running'
        $pid2 = Start-FrpClient
        Assert-FrpEqual $pid1 $pid2 'idempotent start'
        Stop-FrpClient | Out-Null
        Assert-FrpTrue (-not (Get-FrpClientStatus).Running) 'stopped'
        Stop-FrpClient | Out-Null
        Write-FrpTestPass 'test-process-control (fake)'
    } else {
        if (-not (Test-Path -LiteralPath (Get-FrpFrpcPath))) {
            Write-Host 'Provisioning hash-verified frpc.exe for process-control test...'
            Install-FrpWindowsBinary | Out-Null
        }
        Assert-FrpTrue (Test-Path -LiteralPath (Get-FrpFrpcPath)) 'frpc.exe present'
        $frpc = Get-FrpFrpcPath
        Assert-FrpTrue ($frpc.ToLower().EndsWith('frpc.exe')) 'frpc path leaf'

        New-Item -ItemType Directory -Path (Get-FrpConfigDir) -Force | Out-Null
        Set-Content -LiteralPath (Get-FrpTomlPath) -Value @"
serverAddr = "127.0.0.1"
serverPort = 1
loginFailExit = true
"@

        $started = $false
        $immediateExit = $false
        try {
            $pid1 = Start-FrpClient
            $started = $true
        } catch {
            $immediateExit = $true
            Assert-FrpTrue ($_.Exception.Message -match 'exited immediately|failed to start|frpc') 'immediate-exit error text'
            Assert-FrpTrue ($null -eq (Read-FrpPidMetadata)) 'metadata cleared after immediate exit'
        }

        if ($started) {
            # Process stayed alive briefly without a real server — still exercise lifecycle.
            Assert-FrpTrue ((Get-FrpClientStatus).Running) 'frpc running'
            $pid2 = Start-FrpClient
            Assert-FrpEqual $pid1 $pid2 'idempotent start'
            $stopped = Stop-FrpClient
            Assert-FrpTrue $stopped 'stopped'
            Assert-FrpTrue (-not (Get-FrpClientStatus).Running) 'not running after stop'
            Write-FrpTestPass 'test-process-control (windows frpc start/stop)'
        } else {
            Assert-FrpTrue $immediateExit 'immediate-exit path taken'
            Write-FrpTestPass 'test-process-control (windows frpc immediate-exit)'
        }

        # Idempotent stop + stale pid ownership clear (no live server required)
        $stopped2 = Stop-FrpClient
        Assert-FrpTrue (-not $stopped2) 'idempotent stop returns false'
        Write-FrpPidFile -ProcessId 999999 -ExePath $frpc
        $stopped3 = Stop-FrpClient
        Assert-FrpTrue (-not $stopped3) 'stale pid cleared without kill'
        Assert-FrpTrue ($null -eq (Read-FrpPidMetadata)) 'stale metadata cleared'
        Write-FrpTestPass 'test-process-control (windows stop/stale)'
    }
} finally {
    Remove-Item Env:FRP_WINDOWS_ALLOW_FAKE_PROCESS -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
