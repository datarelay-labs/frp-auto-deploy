# test-uninstall.ps1
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    $id = New-FrpEcdsaIdentity
    Save-FrpIdentityKey -PrivatePem $id.PrivatePem | Out-Null
    Save-FrpIdentityPublic -PublicPem $id.PublicPem | Out-Null
    Set-Content -LiteralPath (Get-FrpTomlPath) -Value 'serverAddr = "x"'
    $mid = Get-FrpOrCreateClientId
    Save-FrpClientState -AllocatorUrl 'https://example.test/enroll' -FrpServer 'example.test' `
        -FrpServerPort 7000 -Hostname 'h' -MachineId $mid -HostId 'h' `
        -Services @(@{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; local_ip = '127.0.0.1'; local_port = 3389; remote_port = 1; enabled = $true }) `
        -Transport 'tcp' | Out-Null

    $root = Get-FrpWindowsRoot
    Assert-FrpTrue (Test-Path -LiteralPath $root) 'root exists'

    $rc = Invoke-FrpClientUninstall
    Assert-FrpTrue ($rc -eq 0) 'uninstall exit 0'
    Assert-FrpTrue (-not (Test-Path -LiteralPath $root)) 'root removed'

    # Idempotent second uninstall (nothing left → success)
    $rc2 = Invoke-FrpClientUninstall
    Assert-FrpTrue ($rc2 -eq 0) 'second uninstall exit 0'

    # Tools source still documents the message and fail-closed stop
    $client = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'windows\tools\FrpClient.ps1') -Raw
    Assert-FrpTrue ($client -match 'SERVER RESERVATIONS PRESERVED') 'uninstall message in tool'
    Assert-FrpTrue ($client -match 'administrator releases them') 'port release wording'
    Assert-FrpTrue ($client -match 'refusing to remove credentials') 'fail-closed stop gate'
    Assert-FrpTrue ($client -match 'Remaining items') 'lists remaining on Remove-Item failure'

    Write-FrpTestPass 'test-uninstall'
} finally {
    Remove-FrpWindowsTestRoot
}
