# test-config.ps1
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    $services = @(
        [pscustomobject]@{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; local_ip = '127.0.0.1'; local_port = 3389; remote_port = 60001; enabled = $true }
    )
    $ca = Join-Path $env:FRP_WINDOWS_ROOT 'certs/dummy-ca.crt'
    New-Item -ItemType Directory -Path (Split-Path $ca -Parent) -Force | Out-Null
    Set-Content -LiteralPath $ca -Value "-----BEGIN CERTIFICATE-----`ndeadbeef`n-----END CERTIFICATE-----`n"

    $toml = New-FrpClientToml -ServerAddr '203.0.113.10' -ServerPort 443 -Token 'tok-deadbeef' `
        -HostId 'abcd1234' -Services $services -Transport 'wss' -TrustedCaFile $ca
    $text = Get-Content -LiteralPath $toml -Raw
    Assert-FrpTrue ($text -match 'serverPort = 443') 'port 443'
    Assert-FrpTrue ($text -match 'transport\.protocol = "wss"') 'wss'
    Assert-FrpTrue ($text -match 'auth\.token = "tok-deadbeef"') 'token'
    Assert-FrpTrue ($text -match 'localPort = 3389') 'rdp local'
    Assert-FrpTrue ($text -match 'remotePort = 60001') 'remote'
    Assert-FrpEqual 'tok\"oops' (Escape-FrpTomlString 'tok"oops') 'escape quote'

    $id = New-FrpEcdsaIdentity
    Save-FrpIdentityKey -PrivatePem $id.PrivatePem | Out-Null
    Save-FrpIdentityPublic -PublicPem $id.PublicPem | Out-Null
    $mid = Get-FrpOrCreateClientId
    $services2 = @(
        [pscustomobject]@{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; local_ip = '127.0.0.1'; local_port = 3389; remote_port = 60002; enabled = $true }
    )
    $toml2 = New-FrpClientToml -ServerAddr '203.0.113.10' -ServerPort 7000 -Token 'tok-proof' `
        -HostId 'host1' -Services $services2 -Transport 'tcp' -MachineId $mid
    Test-FrpClientTomlDataPlaneMetadata -TomlPath $toml2 -MachineId $mid -Services $services2 | Out-Null
    Write-FrpTestPass 'WINDOWS_PROOF_METADATA_VALIDATION'

    Write-FrpTestPass 'test-config'
} finally {
    Remove-FrpWindowsTestRoot
}
