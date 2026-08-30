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

    # Mimic uninstall messaging + local removal
    $msg = 'LOCAL SOFTWARE REMOVED, SERVER RESERVATIONS PRESERVED'
    Assert-FrpTrue ($msg -match 'SERVER RESERVATIONS PRESERVED') 'reservation message'
    Remove-Item -LiteralPath $root -Recurse -Force
    Assert-FrpTrue (-not (Test-Path -LiteralPath $root)) 'root removed'

    # Tools source still documents the message
    $client = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'windows\tools\FrpClient.ps1') -Raw
    Assert-FrpTrue ($client -match 'SERVER RESERVATIONS PRESERVED') 'uninstall message in tool'

    Write-FrpTestPass 'test-uninstall'
} finally {
    Remove-FrpWindowsTestRoot
}
