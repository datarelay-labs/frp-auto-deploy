# test-process-control.ps1 — real frpc on Windows; fake process on Linux CI
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    Clear-FrpStalePid
    $st = Get-FrpClientStatus
    Assert-FrpTrue (-not $st.Running) 'not running'

    if (-not (Test-FrpIsWindowsHost)) {
        $env:FRP_WINDOWS_ALLOW_FAKE_PROCESS = '1'
        # Minimal toml so Start-FrpClient proceeds past config check
        New-Item -ItemType Directory -Path (Get-FrpConfigDir) -Force | Out-Null
        Set-Content -LiteralPath (Get-FrpTomlPath) -Value "serverAddr = `"127.0.0.1`"`n"
        New-Item -ItemType Directory -Path (Get-FrpBinDir) -Force | Out-Null
        Set-Content -LiteralPath (Get-FrpFrpcPath) -Value 'dummy'
        $pid1 = Start-FrpClient
        $st2 = Get-FrpClientStatus
        Assert-FrpTrue $st2.Running 'fake running'
        # Idempotent start
        $pid2 = Start-FrpClient
        Assert-FrpEqual $pid1 $pid2 'idempotent start'
        Stop-FrpClient | Out-Null
        Assert-FrpTrue (-not (Get-FrpClientStatus).Running) 'stopped'
        # Idempotent stop
        Stop-FrpClient | Out-Null
        Write-FrpTestPass 'test-process-control (fake)'
    } else {
        # Hash-verified real frpc.exe is required for Windows coverage. A live
        # FRP server is NOT required: immediate-exit failure is the isolated
        # unit-test path (full tunnel start remains E2E_ONLY).
        if (-not (Test-Path -LiteralPath (Get-FrpFrpcPath))) {
            Write-Host 'Provisioning hash-verified frpc.exe for process-control test...'
            Install-FrpWindowsBinary | Out-Null
        }
        Assert-FrpTrue (Test-Path -LiteralPath (Get-FrpFrpcPath)) 'frpc.exe present'
        $frpc = Get-FrpFrpcPath
        Assert-FrpTrue ($frpc.ToLower().EndsWith('frpc.exe')) 'frpc path leaf'

        New-Item -ItemType Directory -Path (Get-FrpConfigDir) -Force | Out-Null
        # Point at a closed local port so frpc exits immediately.
        Set-Content -LiteralPath (Get-FrpTomlPath) -Value @"
serverAddr = "127.0.0.1"
serverPort = 1
loginFailExit = true
"@

        $threw = $false
        try {
            Start-FrpClient | Out-Null
        } catch {
            $threw = $true
            Assert-FrpTrue ($_.Exception.Message -match 'exited immediately|failed to start|frpc') 'immediate-exit error text'
        }
        Assert-FrpTrue $threw 'Start-FrpClient fails closed on immediate exit'
        Assert-FrpTrue ($null -eq (Read-FrpPidMetadata)) 'metadata cleared after immediate exit'
        Assert-FrpTrue (-not (Get-FrpClientStatus).Running) 'not running after failed start'

        # Idempotent stop with no live process / stale metadata
        $stopped = Stop-FrpClient
        Assert-FrpTrue (-not $stopped) 'idempotent stop returns false'
        Write-FrpPidFile -ProcessId 999999 -ExePath $frpc
        $stopped2 = Stop-FrpClient
        Assert-FrpTrue (-not $stopped2) 'stale pid cleared without kill'
        Assert-FrpTrue ($null -eq (Read-FrpPidMetadata)) 'stale metadata cleared'
        Write-FrpTestPass 'test-process-control (windows frpc immediate-exit + stop)'
    }
} finally {
    Remove-Item Env:FRP_WINDOWS_ALLOW_FAKE_PROCESS -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
