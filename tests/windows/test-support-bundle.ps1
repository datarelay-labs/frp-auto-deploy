# test-support-bundle.ps1 — redacted ZIP must not leak fixture secrets
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    $id = New-FrpEcdsaIdentity
    Save-FrpIdentityKey -PrivatePem $id.PrivatePem | Out-Null
    Save-FrpIdentityPublic -PublicPem $id.PublicPem | Out-Null
    $token = 'FRP_TOKEN_TEST_SHOULD_NEVER_APPEAR_IN_BUNDLE'
    Set-Content -LiteralPath (Get-FrpTomlPath) -Value @"
serverAddr = `"secret.example.test`"
auth.token = `"$token`"
metadatas.frp_ad_client_id = `"client-diag`"
metadatas.frp_ad_proof_schema = `"1`"
metadatas.frp_ad_proof = `"FRP_AD_PROOF_TEST_DO_NOT_LEAK_ABCDEF123456`"
"@
    $mid = Get-FrpOrCreateClientId
    Save-FrpClientState -AllocatorUrl 'https://example.test/enroll' -FrpServer 'example.test' `
        -FrpServerPort 7000 -Hostname 'bundle-host' -MachineId $mid -HostId 'bundle-host' `
        -Services @(@{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; local_ip = '127.0.0.1'; local_port = 3389; remote_port = 1; enabled = $true }) `
        -Transport 'tcp' | Out-Null

    # Inject a secret-looking field into state for scan coverage
    $statePath = Get-FrpStatePath
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state | Add-Member -NotePropertyName auth_token -NotePropertyValue $token -Force
    ($state | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $statePath

    $rc = Invoke-FrpSupportBundle -Anonymize
    Assert-FrpTrue ($rc -eq 0) 'support-bundle exit 0'

    $tempRoot = [System.IO.Path]::GetTempPath()
    if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = '/tmp' }
    # GUID-based exclusive names: frp-support-bundle-<32hex>.zip
    $zips = Get-ChildItem -LiteralPath $tempRoot -Filter 'frp-support-bundle-*.zip' |
        Sort-Object LastWriteTime -Descending
    Assert-FrpTrue ($zips.Count -gt 0) 'zip created'
    $zip = $zips[0].FullName
    Assert-FrpTrue ($zip -match 'frp-support-bundle-[0-9a-fA-F]{32}\.zip$') 'zip uses exclusive GUID name'

    # Collision must not delete preexisting unknown archives.
    $collide = Join-Path $tempRoot ('frp-support-bundle-' + [guid]::NewGuid().ToString('N') + '.zip')
    Set-Content -LiteralPath $collide -Value 'preexisting-marker'
    # New-FrpExclusiveTempPath skips existing paths; creating another bundle must leave marker intact.
    $rc2 = Invoke-FrpSupportBundle -Anonymize
    Assert-FrpTrue ($rc2 -eq 0) 'second support-bundle exit 0'
    Assert-FrpEqual 'preexisting-marker' ((Get-Content -LiteralPath $collide -Raw).Trim()) 'preexisting archive not deleted'
    Remove-Item -LiteralPath $collide -Force -ErrorAction SilentlyContinue

    $extract = Join-Path $tempRoot ("frp-bundle-scan-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $extract | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

    $names = Get-ChildItem -LiteralPath $extract -Recurse -File | ForEach-Object { $_.Name }
    Assert-FrpTrue ($names -contains 'frpc.redacted.toml') 'redacted toml present'
    Assert-FrpTrue ($names -contains 'client-state.redacted.json') 'redacted state present'
    Assert-FrpTrue (-not ($names -contains 'frpc.toml')) 'raw frpc.toml excluded'
    Assert-FrpTrue (-not ($names -contains 'client-state.json')) 'raw client-state.json excluded'

    $blob = (Get-ChildItem -LiteralPath $extract -Recurse -File |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    Assert-FrpTrue ($blob -notmatch [regex]::Escape($token)) 'token secret not in zip'
    Assert-FrpTrue ($blob -notmatch 'FRP_TOKEN_TEST_') 'FRP_TOKEN_TEST fixture not in zip'
    Assert-FrpTrue ($blob -notmatch 'FRP_AD_PROOF_TEST_DO_NOT_LEAK_') 'data-plane proof not in zip'
    Assert-FrpTrue ($blob -match 'frp_ad_client_id') 'client id diagnostic retained'
    Assert-FrpTrue ($blob -match 'frp_ad_proof_schema') 'proof schema diagnostic retained'
    Assert-FrpTrue ($blob -match 'metadatas\.frp_ad_proof = "\[redacted\]"') 'proof redacted marker present'
    Write-FrpTestPass 'WINDOWS_SUPPORT_BUNDLE_PROOF_REDACTED'
    Write-FrpTestPass 'WINDOWS_PROOF_REDACTION_TEST'

    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    # Clean GUID zips created by this test (best-effort).
    Get-ChildItem -LiteralPath $tempRoot -Filter 'frp-support-bundle-*.zip' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-FrpTestPass 'test-support-bundle'
} finally {
    Remove-FrpWindowsTestRoot
}
