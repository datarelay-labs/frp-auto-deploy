# test-pid-ownership.ps1 — PID metadata + refuse kill on mismatched process
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
        Assert-FrpTrue (Test-FrpProcessAlive -ProcessId $managedPid -ValidateOwnership -ExpectedExe $meta.exe) 'owned alive'
        Stop-FrpClient | Out-Null
    }

    # On Windows and Linux CI: point metadata at unrelated live process with
    # frpc expected exe => ownership fail => no kill. Use current $PID.
    $unrelated = $PID
    Write-FrpPidFile -ProcessId $unrelated -ExePath (Get-FrpFrpcPath)
    Assert-FrpTrue (-not (Test-FrpProcessOwned -ProcessId $unrelated -ExpectedExe (Get-FrpFrpcPath))) 'host process not owned frpc'
    $stopped = Stop-FrpClient
    Assert-FrpTrue (-not $stopped) 'did not kill unrelated'
    Assert-FrpTrue ($null -ne (Get-Process -Id $unrelated -ErrorAction SilentlyContinue)) 'unrelated still alive'
    Assert-FrpTrue ($null -eq (Read-FrpPidMetadata)) 'metadata cleared'

    Write-FrpTestPass 'test-pid-ownership'
} finally {
    Remove-Item Env:FRP_WINDOWS_ALLOW_FAKE_PROCESS -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
