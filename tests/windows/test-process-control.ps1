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
        # Provision hash-verified frpc.exe when missing so Windows CI does not
        # silently skip critical process coverage.
        if (-not (Test-Path -LiteralPath (Get-FrpFrpcPath))) {
            Write-Host 'Provisioning hash-verified frpc.exe for process-control test...'
            Install-FrpWindowsBinary | Out-Null
        }
        if (-not (Test-Path -LiteralPath (Get-FrpFrpcPath))) {
            throw 'ERROR: frpc.exe missing after Install-FrpWindowsBinary'
        }
        New-Item -ItemType Directory -Path (Get-FrpConfigDir) -Force | Out-Null
        if (-not (Test-Path -LiteralPath (Get-FrpTomlPath))) {
            Set-Content -LiteralPath (Get-FrpTomlPath) -Value "serverAddr = `"127.0.0.1`"`nserverPort = 7000`n"
        }
        $pid1 = Start-FrpClient
        Assert-FrpTrue ((Get-FrpClientStatus).Running) 'frpc running'
        $pid2 = Start-FrpClient
        Assert-FrpEqual $pid1 $pid2 'idempotent start'
        $stopped = Stop-FrpClient
        Assert-FrpTrue $stopped 'stopped'
        Assert-FrpTrue (-not (Get-FrpClientStatus).Running) 'not running after stop'
        Stop-FrpClient | Out-Null
        Write-FrpTestPass 'test-process-control (windows frpc)'
    }
} finally {
    Remove-Item Env:FRP_WINDOWS_ALLOW_FAKE_PROCESS -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
