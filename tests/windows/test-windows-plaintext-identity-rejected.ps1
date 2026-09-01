# test-windows-plaintext-identity-rejected.ps1
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    New-Item -ItemType Directory -Path (Get-FrpStateDir) -Force | Out-Null
    New-Item -ItemType Directory -Path (Get-FrpConfigDir) -Force | Out-Null
    Set-Content -LiteralPath (Get-FrpTomlPath) -Value "serverAddr = `"127.0.0.1`"`n"
    Set-Content -LiteralPath (Get-FrpIdentityPubPath) -Value "-----BEGIN PUBLIC KEY-----`ntest`n-----END PUBLIC KEY-----`n"
    '{"host_id":"x"}' | Set-Content -LiteralPath (Get-FrpStatePath)

    $plain = Join-Path (Get-FrpStateDir) 'client-identity.key'
    $begin = '-----BEGIN ' + 'PRIVATE KEY-----'
    $end = '-----END ' + 'PRIVATE KEY-----'
    Set-Content -LiteralPath $plain -Value ($begin + "`nPLAIN`n" + $end + "`n")

    # Force Windows identity policy even on Linux pwsh cross hosts.
    $env:FRP_WINDOWS_ENFORCE_DPAPI_IDENTITY = '1'

    Assert-FrpTrue (Test-FrpWindowsPlaintextIdentityOnly) 'plaintext-only detected'
    Assert-FrpTrue (-not (Test-FrpIsEnrolled)) 'plaintext-only not enrolled'

    $failed = $false
    try {
        $null = Read-FrpIdentityKey
    } catch {
        $failed = $true
        Assert-FrpTrue ($_.Exception.Message -match 'plaintext') 'fail-closed message'
    }
    Assert-FrpTrue $failed 'Read-FrpIdentityKey rejected plaintext'

    Write-FrpTestPass 'WINDOWS_PLAINTEXT_IDENTITY_REJECTED'
} finally {
    Remove-Item Env:FRP_WINDOWS_ENFORCE_DPAPI_IDENTITY -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
