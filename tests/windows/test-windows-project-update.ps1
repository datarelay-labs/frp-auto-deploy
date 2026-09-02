# test-windows-project-update.ps1 — verified-artifact identity + rollback + completeness
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')

function New-FrpCompleteWindowsFixture {
    param(
        [Parameter(Mandatory = $true)][string]$DestWindowsRoot,
        [string]$Marker = 'FIXTURE_MARKER'
    )
    if (Test-Path -LiteralPath $DestWindowsRoot) {
        Remove-Item -LiteralPath $DestWindowsRoot -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'windows') -Destination $DestWindowsRoot -Recurse -Force
    $pathsPath = Join-Path $DestWindowsRoot 'lib/FrpPaths.ps1'
    $raw = Get-Content -LiteralPath $pathsPath -Raw
    Set-Content -LiteralPath $pathsPath -Value ("# {0}`n{1}" -f $Marker, $raw)
}

try {
    $id = New-FrpEcdsaIdentity
    Save-FrpIdentityKey -PrivatePem $id.PrivatePem | Out-Null
    Save-FrpIdentityPublic -PublicPem $id.PublicPem | Out-Null
    $mid = Get-FrpOrCreateClientId
    $services = @{
        rdp = @{
            id = 'rdp'; name = 'RDP'; preset = 'rdp'; local_ip = '127.0.0.1'
            local_port = 3389; remote_port = 60003; enabled = $true
        }
    }
    Save-FrpClientState -AllocatorUrl 'https://example.test/enroll' -FrpServer 'example.test' `
        -FrpServerPort 7000 -Hostname 'win' -MachineId $mid -HostId 'abcd' `
        -Services $services -Transport 'tcp' -InstallStatus 'installed' | Out-Null
    New-FrpClientToml -ServerAddr 'example.test' -ServerPort 7000 -Token 'tok-original' `
        -HostId 'abcd' -Services $services -Transport 'tcp' -MachineId $mid | Out-Null
    New-Item -ItemType Directory -Path (Get-FrpBinDir) -Force | Out-Null
    Set-Content -LiteralPath (Get-FrpFrpcPath) -Value 'ORIGINAL_BINARY'
    $env:FRP_RELEASE_CHANNEL = 'dev'
    $bundleSha = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
    $env:FRP_BUNDLE_SHA256 = $bundleSha
    Write-FrpVersionFile -FrpSha256WindowsAmd64 ('e' * 64) | Out-Null

    # Seed installed project modules from a complete tree (old marker).
    $seedOld = Join-Path $env:FRP_WINDOWS_ROOT 'seed-old-windows'
    New-FrpCompleteWindowsFixture -DestWindowsRoot $seedOld -Marker 'OLD_MODULE_MARKER'
    Install-FrpWindowsProjectTree -SourceWindowsRoot $seedOld | Out-Null

    $libDest = Join-Path (Get-FrpLibDir) 'FrpPaths.ps1'
    $toolsDest = Join-Path (Get-FrpToolsDir) 'FrpClient.ps1'
    $origState = (Get-Content -LiteralPath (Get-FrpStatePath) -Raw)
    $origToml = (Get-Content -LiteralPath (Get-FrpTomlPath) -Raw)
    $origExe = (Get-Content -LiteralPath (Get-FrpFrpcPath) -Raw).Trim()
    $origPub = (Get-Content -LiteralPath (Get-FrpIdentityPubPath) -Raw)

    # Local/dev SourceDir fixture with updated marker (complete managed inventory).
    $fixtureRoot = Join-Path $env:FRP_WINDOWS_ROOT 'fixture-windows'
    New-FrpCompleteWindowsFixture -DestWindowsRoot $fixtureRoot -Marker 'NEW_MODULE_MARKER'

    $clientPath = Join-Path $script:RepoRoot 'windows/tools/FrpClient.ps1'
    $clientText = Get-Content -LiteralPath $clientPath -Raw
    Assert-FrpTrue ($clientText -match 'update project') 'help documents update project'
    Assert-FrpTrue ($clientText -match 'Invoke-FrpClientProjectUpdate') 'project update function exists'
    Assert-FrpTrue ($clientText -match 'Expand-FrpWindowsBootstrapTree|FRP_WINDOWS_PROJECT_UPDATE_MOCK_DIR') `
        'remote path materializes verified bootstrap'

    $start = $clientText.IndexOf('function Invoke-FrpClientProjectUpdate')
    Assert-FrpTrue ($start -ge 0) 'found Invoke-FrpClientProjectUpdate'
    $brace = 0
    $started = $false
    $end = -1
    for ($i = $start; $i -lt $clientText.Length; $i++) {
        $ch = $clientText[$i]
        if ($ch -eq '{') { $brace++; $started = $true }
        elseif ($ch -eq '}') {
            $brace--
            if ($started -and $brace -eq 0) { $end = $i; break }
        }
    }
    Assert-FrpTrue ($end -gt $start) 'balanced project-update function'
    Invoke-Expression $clientText.Substring($start, $end - $start + 1)

    $DownloadUrl = $null
    $ExpectedSha256 = $bundleSha
    $MetadataUrl = $null
    $SourceDir = $fixtureRoot

    $rc = Invoke-FrpClientProjectUpdate -SourceWindowsRoot $fixtureRoot -ExpectedBundleSha256 $bundleSha
    Assert-FrpEqual 0 $rc 'project update succeeds'

    $updated = Get-Content -LiteralPath $libDest -Raw
    Assert-FrpTrue ($updated -match 'NEW_MODULE_MARKER') 'module updated from fixture'
    Assert-FrpEqual $origState (Get-Content -LiteralPath (Get-FrpStatePath) -Raw) 'state unchanged'
    Assert-FrpEqual $origToml (Get-Content -LiteralPath (Get-FrpTomlPath) -Raw) 'toml unchanged'
    Assert-FrpEqual $origExe ((Get-Content -LiteralPath (Get-FrpFrpcPath) -Raw).Trim()) 'frpc.exe unchanged'
    Assert-FrpEqual $origPub (Get-Content -LiteralPath (Get-FrpIdentityPubPath) -Raw) 'identity pub unchanged'

    $ver = Get-FrpVersionMetadata
    Assert-FrpEqual 'dev' $ver['RELEASE_CHANNEL'] 'channel preserved/written'
    Assert-FrpEqual 'main' $ver['SOURCE_REF'] 'dev source ref'
    Assert-FrpEqual $bundleSha $ver['BUNDLE_SHA256'] 'bundle sha persisted'
    Write-FrpTestPass 'PROJECT_UPDATE_FIXTURE_MODULE'
    Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_SHA_IDENTITY'

    # Missing managed file rejected before mutation
    $incomplete = Join-Path $env:FRP_WINDOWS_ROOT 'incomplete-windows'
    New-FrpCompleteWindowsFixture -DestWindowsRoot $incomplete -Marker 'INCOMPLETE'
    Remove-Item -LiteralPath (Join-Path $incomplete 'lib/FrpCrypto.ps1') -Force
    $beforeIncomplete = Get-Content -LiteralPath $libDest -Raw
    $threwMissing = $false
    try {
        Install-FrpWindowsProjectTree -SourceWindowsRoot $incomplete | Out-Null
    } catch {
        $threwMissing = $true
        Assert-FrpTrue ($_.Exception.Message -match 'missing required managed') 'missing-file error'
    }
    Assert-FrpTrue $threwMissing 'missing managed file rejected'
    Assert-FrpEqual $beforeIncomplete (Get-Content -LiteralPath $libDest -Raw) 'no mutation on missing file'
    Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_MISSING_MANAGED_FILE_REJECTED'

    # Pause state preserved
    Write-FrpPauseMarker -AutostartWasEnabled:$false
    Assert-FrpTrue (Test-FrpRemoteAccessPaused) 'paused before update'
    Set-Content -LiteralPath $libDest -Value "# OLD_AGAIN`n"
    $rc2 = Invoke-FrpClientProjectUpdate -SourceWindowsRoot $fixtureRoot -ExpectedBundleSha256 $bundleSha
    Assert-FrpEqual 0 $rc2 'project update while paused'
    Assert-FrpTrue (Test-FrpRemoteAccessPaused) 'pause preserved'
    Assert-FrpTrue ((Get-Content -LiteralPath $libDest -Raw) -match 'NEW_MODULE_MARKER') 'module updated while paused'
    Clear-FrpPauseMarker
    Write-FrpTestPass 'PROJECT_UPDATE_PAUSE_PRESERVED'

    # Rollback on simulated failure
    Set-Content -LiteralPath $libDest -Value "# PRE_FAIL_MARKER`n"
    $preFail = Get-Content -LiteralPath $libDest -Raw
    $env:FRP_WINDOWS_FAIL_AFTER_PROJECT_REPLACE = '1'
    $rc3 = Invoke-FrpClientProjectUpdate -SourceWindowsRoot $fixtureRoot -ExpectedBundleSha256 $bundleSha
    Assert-FrpEqual 1 $rc3 'project update fails when hooked'
    Assert-FrpEqual $preFail.Trim() ((Get-Content -LiteralPath $libDest -Raw).Trim()) 'module rolled back'
    Assert-FrpEqual $origState (Get-Content -LiteralPath (Get-FrpStatePath) -Raw) 'state intact after rollback'
    Assert-FrpEqual $origToml (Get-Content -LiteralPath (Get-FrpTomlPath) -Raw) 'toml intact after rollback'
    Assert-FrpEqual $origExe ((Get-Content -LiteralPath (Get-FrpFrpcPath) -Raw).Trim()) 'exe intact after rollback'
    Remove-Item Env:FRP_WINDOWS_FAIL_AFTER_PROJECT_REPLACE -ErrorAction SilentlyContinue
    Write-FrpTestPass 'PROJECT_UPDATE_ROLLBACK'
    Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_ROLLBACK'

    # Candidate exact SHA required for project update identity
    Remove-Item Env:FRP_RELEASE_CHANNEL -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_SOURCE_REF -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_BUNDLE_SHA256 -ErrorAction SilentlyContinue
    $env:FRP_RELEASE_CHANNEL = 'candidate'
    $threw = $false
    try {
        $null = Resolve-FrpWindowsProjectUpdateIdentity
    } catch {
        $threw = $true
    }
    Assert-FrpTrue $threw 'candidate project update without SHA rejected'
    $env:FRP_SOURCE_REF = 'ffffffffffffffffffffffffffffffffffffffff'
    $ident = Resolve-FrpWindowsProjectUpdateIdentity
    Assert-FrpEqual 'candidate' $ident.Channel 'candidate channel resolved'
    Assert-FrpEqual 'ffffffffffffffffffffffffffffffffffffffff' $ident.SourceRef 'candidate SHA resolved'
    Write-FrpTestPass 'PROJECT_UPDATE_CANDIDATE_SHA'

    # --- Remote verified-bundle path (mocked HTTPS) ---
    $markSrc = Join-Path $env:FRP_WINDOWS_ROOT 'bundle-src-windows'
    New-FrpCompleteWindowsFixture -DestWindowsRoot $markSrc -Marker 'VERIFIED_BUNDLE_UNIQUE_MARKER'
    # Build a real bootstrap-client.ps1 embedding this marked tree via temporary windows/ swap.
    $windowsOrig = Join-Path $script:RepoRoot 'windows'
    $windowsBackup = Join-Path $env:FRP_WINDOWS_ROOT 'windows-backup-for-bundle'
    Copy-Item -LiteralPath $windowsOrig -Destination $windowsBackup -Recurse -Force
    try {
        Remove-Item -LiteralPath $windowsOrig -Recurse -Force
        Copy-Item -LiteralPath $markSrc -Destination $windowsOrig -Recurse -Force
        & python3 (Join-Path $script:RepoRoot 'scripts/build-bundles.py') | Out-Null
    } finally {
        Remove-Item -LiteralPath $windowsOrig -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $windowsBackup -Destination $windowsOrig -Recurse -Force
    }
    $builtBundle = Join-Path $script:RepoRoot 'dist/bootstrap-client.ps1'
    Assert-FrpTrue (Test-Path -LiteralPath $builtBundle) 'bootstrap-client.ps1 built'
    $verifiedHex = Get-FrpSha256HexOfFile -Path $builtBundle

    $mockDir = Join-Path $env:FRP_WINDOWS_ROOT 'mock-download'
    New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
    Copy-Item -LiteralPath $builtBundle -Destination (Join-Path $mockDir 'bootstrap-client.ps1') -Force
    Set-Content -LiteralPath (Join-Path $mockDir 'SHA256SUMS') -Value ("{0}  dist/bootstrap-client.ps1`n" -f $verifiedHex)

    # Reset installed tree to OLD marker before remote update.
    Install-FrpWindowsProjectTree -SourceWindowsRoot $seedOld | Out-Null
    Assert-FrpTrue ((Get-Content -LiteralPath $libDest -Raw) -match 'OLD_MODULE_MARKER') 'seeded old before remote'

    $env:FRP_RELEASE_CHANNEL = 'dev'
    Remove-Item Env:FRP_WINDOWS_PROJECT_SOURCE -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_BUNDLE_SHA256 -ErrorAction SilentlyContinue
    $ExpectedSha256 = $null
    $env:FRP_WINDOWS_PROJECT_UPDATE_MOCK_DIR = $mockDir
    $remoteUrl = 'https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.ps1'
    $sumsUrl = 'https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/SHA256SUMS'
    $rcRemote = Invoke-FrpClientProjectUpdate -ArtifactUrl $remoteUrl -SumsUrl $sumsUrl
    Assert-FrpEqual 0 $rcRemote 'remote verified project update succeeds'
    Assert-FrpTrue ((Get-Content -LiteralPath $libDest -Raw) -match 'VERIFIED_BUNDLE_UNIQUE_MARKER') `
        'installed module came from verified bootstrap'
    $verRemote = Get-FrpVersionMetadata
    Assert-FrpEqual $verifiedHex $verRemote['BUNDLE_SHA256'] 'BUNDLE_SHA256 equals verified artifact'
    Write-FrpTestPass 'WINDOWS_REMOTE_PROJECT_UPDATE_FROM_VERIFIED_BUNDLE'
    Write-FrpTestPass 'WINDOWS_VERIFIED_ARTIFACT_EQUALS_INSTALLED_SOURCE'
    Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_SHA_IDENTITY'

    # Tamper rejected before mutation
    Install-FrpWindowsProjectTree -SourceWindowsRoot $seedOld | Out-Null
    $beforeTamper = Get-Content -LiteralPath $libDest -Raw
    Add-Content -LiteralPath (Join-Path $mockDir 'bootstrap-client.ps1') -Value "`n# tampered`n"
    $rcTamper = Invoke-FrpClientProjectUpdate -ArtifactUrl $remoteUrl -SumsUrl $sumsUrl
    Assert-FrpEqual 1 $rcTamper 'tampered artifact rejected'
    Assert-FrpEqual $beforeTamper (Get-Content -LiteralPath $libDest -Raw) 'no mutation after tamper'
    Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_TAMPER_REJECTED'
    Remove-Item Env:FRP_WINDOWS_PROJECT_UPDATE_MOCK_DIR -ErrorAction SilentlyContinue

    # --- HTTPS-only curl policy + no-curl fail-closed (decision path exercised) ---
    Assert-FrpTrue ($clientText -match "--proto',\s*'=https'") `
        'project update curl uses --proto =https'
    Assert-FrpTrue ($clientText -match "--proto-redir',\s*'=https'") `
        'project update curl uses --proto-redir =https'
    Assert-FrpTrue ($clientText -notmatch 'System\.Net\.WebClient') `
        'project update must not use WebClient fallback'
    Assert-FrpTrue ($clientText -match 'Get-FrpWindowsProjectUpdateRemoteDownloadMode') `
        'project update uses isolated download-mode decision'
    Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_CURL_PROTO_HTTPS'
    Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_CURL_PROTO_REDIR_HTTPS'

    $curlMode = Get-FrpWindowsProjectUpdateRemoteDownloadMode -CurlAvailable $true
    Assert-FrpEqual 'curl' $curlMode 'curl-available decision returns curl'
    $refuseThrew = $false
    $refuseMsg = ''
    try {
        $null = Get-FrpWindowsProjectUpdateRemoteDownloadMode -CurlAvailable $false
    } catch {
        $refuseThrew = $true
        $refuseMsg = [string]$_.Exception.Message
    }
    Assert-FrpTrue $refuseThrew 'no-curl decision throws'
    Assert-FrpTrue ($refuseMsg -match 'curl\.exe' -and $refuseMsg -match 'HTTPS-only') `
        'no-curl decision error is actionable'

    Install-FrpWindowsProjectTree -SourceWindowsRoot $seedOld | Out-Null
    $beforeNoCurl = Get-Content -LiteralPath $libDest -Raw
    $env:FRP_RELEASE_CHANNEL = 'dev'
    $env:FRP_WINDOWS_PROJECT_UPDATE_FORCE_NO_CURL = '1'
    Remove-Item Env:FRP_WINDOWS_PROJECT_UPDATE_MOCK_DIR -ErrorAction SilentlyContinue
    $rcNoCurl = Invoke-FrpClientProjectUpdate -ArtifactUrl $remoteUrl -SumsUrl $sumsUrl
    Assert-FrpEqual 1 $rcNoCurl 'remote project update fails closed without curl'
    Assert-FrpEqual $beforeNoCurl (Get-Content -LiteralPath $libDest -Raw) `
        'no mutation when remote update refuses without curl'
    Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_NO_CURL_FAILS_CLOSED'

    $rcLocalNoCurl = Invoke-FrpClientProjectUpdate -SourceWindowsRoot $fixtureRoot `
        -ExpectedBundleSha256 $bundleSha
    Assert-FrpEqual 0 $rcLocalNoCurl 'local source project update works without curl'
    Assert-FrpTrue ((Get-Content -LiteralPath $libDest -Raw) -match 'NEW_MODULE_MARKER') `
        'local source update applied without curl'
    Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_LOCAL_SOURCE_NO_CURL_STILL_ALLOWED'
    Remove-Item Env:FRP_WINDOWS_PROJECT_UPDATE_FORCE_NO_CURL -ErrorAction SilentlyContinue

    # Command model: update (frp) vs update project documented in help text
    Assert-FrpTrue ($clientText -match "Update target: FRP binary" -or $clientText -match 'update frp') 'frp update documented'
    Write-FrpTestPass 'UPDATE_COMMAND_MODEL_SPLIT'

    $psVer = $PSVersionTable.PSVersion.Major
    if ($psVer -ge 7) {
        Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_PS7'
    } else {
        Write-FrpTestPass 'WINDOWS_PROJECT_UPDATE_PS51'
    }

    Write-FrpTestPass 'test-windows-project-update'
} finally {
    Remove-Item Env:FRP_WINDOWS_FAIL_AFTER_PROJECT_REPLACE -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_WINDOWS_PROJECT_UPDATE_MOCK_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_WINDOWS_PROJECT_UPDATE_FORCE_NO_CURL -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_RELEASE_CHANNEL -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_SOURCE_REF -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_BUNDLE_SHA256 -ErrorAction SilentlyContinue
    # Restore repo windows/ + regenerate clean bundles after fixture swap.
    try {
        & python3 (Join-Path $script:RepoRoot 'scripts/build-bundles.py') | Out-Null
    } catch {}
    Remove-FrpWindowsTestRoot
}
