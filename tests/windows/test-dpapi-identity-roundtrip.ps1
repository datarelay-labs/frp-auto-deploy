# test-dpapi-identity-roundtrip.ps1 — Save/Read DPAPI identity key round-trip
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')

try {
    $id = New-FrpEcdsaIdentity
    Assert-FrpTrue ($id.PrivatePem -match 'BEGIN') 'identity private PEM generated'

    $saved = Save-FrpIdentityKey -PrivatePem $id.PrivatePem
    Assert-FrpTrue (Test-Path -LiteralPath $saved) 'saved identity path exists'

    if (Test-FrpIsWindowsHost) {
        Assert-FrpTrue ($saved -match '\.dpapi$') 'Windows stores DPAPI blob'
        Assert-FrpTrue (Test-Path -LiteralPath (Join-Path (Get-FrpStateDir) 'client-identity.key.dpapi')) `
            'client-identity.key.dpapi exists'
        Assert-FrpTrue (-not (Test-Path -LiteralPath (Join-Path (Get-FrpStateDir) 'client-identity.key'))) `
            'no plaintext private key on Windows'
        Assert-FrpTrue (Initialize-FrpDpapi) 'DPAPI types available'
    }

    $roundTrip = Read-FrpIdentityKey
    Assert-FrpEqual $id.PrivatePem $roundTrip 'private key exact round-trip'

    Write-FrpTestPass 'test-dpapi-identity-roundtrip'
} finally {
    Remove-FrpWindowsTestRoot
}
