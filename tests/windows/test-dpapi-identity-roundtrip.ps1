# test-dpapi-identity-roundtrip.ps1 — DPAPI pass + plaintext fail-closed
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')

try {
    $id = New-FrpEcdsaIdentity
    Assert-FrpTrue ($id.PrivatePem -match 'BEGIN') 'identity private PEM generated'

    $saved = Save-FrpIdentityKey -PrivatePem $id.PrivatePem
    Assert-FrpTrue (Test-Path -LiteralPath $saved) 'saved identity path exists'

    if (Test-FrpIsWindowsHost) {
        Assert-FrpTrue ($saved -match '\.dpapi$') 'Windows stores DPAPI blob'
        Assert-FrpTrue (Test-Path -LiteralPath (Get-FrpIdentityDpapiKeyPath)) `
            'client-identity.key.dpapi exists'
        Assert-FrpTrue (-not (Test-Path -LiteralPath (Get-FrpIdentityPlainKeyPath))) `
            'no plaintext private key on Windows'
        Assert-FrpTrue (Initialize-FrpDpapi) 'DPAPI types available'
    }

    $roundTrip = Read-FrpIdentityKey
    Assert-FrpEqual $id.PrivatePem $roundTrip 'private key exact round-trip'
    Write-FrpTestPass 'WINDOWS_DPAPI_IDENTITY_PASS'

    # --- plaintext-only must fail closed under Windows identity policy ---
    Remove-FrpWindowsTestRoot
    $env:FRP_WINDOWS_ROOT = Join-Path ([System.IO.Path]::GetTempPath()) ('frp-win-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $env:FRP_WINDOWS_ROOT -Force | Out-Null
    Initialize-FrpDirectories

    $plain = Get-FrpIdentityPlainKeyPath
    $dpapi = Get-FrpIdentityDpapiKeyPath
    New-Item -ItemType Directory -Path (Get-FrpStateDir) -Force | Out-Null
    Set-Content -LiteralPath $plain -Value $id.PrivatePem
    Assert-FrpTrue (-not (Test-Path -LiteralPath $dpapi)) 'no dpapi blob for reject test'

    # Enforce Windows DPAPI policy even on Linux CI hosts.
    $env:FRP_WINDOWS_ENFORCE_DPAPI_IDENTITY = '1'
    Assert-FrpTrue (Test-FrpWindowsPlaintextIdentityOnly) 'plaintext-only detected'
    Assert-FrpTrue ((Get-FrpIdentityKeyPath) -eq $dpapi) 'path API does not return plaintext'
    Assert-FrpTrue (-not (Test-FrpIsEnrolled)) 'enrolled false for plaintext-only'

    $threw = $false
    try {
        $null = Read-FrpIdentityKey
    } catch {
        $threw = $true
        Assert-FrpTrue ($_.Exception.Message -match 'plaintext|DPAPI|not accepted') 'reject mentions plaintext/DPAPI'
    }
    Assert-FrpTrue $threw 'Read-FrpIdentityKey fail-closed on plaintext-only'
    Write-FrpTestPass 'WINDOWS_PLAINTEXT_IDENTITY_REJECTED'
} finally {
    Remove-Item Env:FRP_WINDOWS_ENFORCE_DPAPI_IDENTITY -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
