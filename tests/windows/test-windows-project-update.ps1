# test-windows-project-update.ps1 — P2-V project vs FRP update; fixture module replace + rollback
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')

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

    # Seed installed project modules (old marker).
    $libDest = Join-Path (Get-FrpLibDir) 'FrpPaths.ps1'
    New-Item -ItemType Directory -Path (Get-FrpLibDir) -Force | Out-Null
    Set-Content -LiteralPath $libDest -Value "# OLD_MODULE_MARKER`n# stub FrpPaths`n"
    $toolsDest = Join-Path (Get-FrpToolsDir) 'FrpClient.ps1'
    New-Item -ItemType Directory -Path (Get-FrpToolsDir) -Force | Out-Null
    Set-Content -LiteralPath $toolsDest -Value "# OLD_CLIENT_TOOL`n"

    $origState = (Get-Content -LiteralPath (Get-FrpStatePath) -Raw)
    $origToml = (Get-Content -LiteralPath (Get-FrpTomlPath) -Raw)
    $origExe = (Get-Content -LiteralPath (Get-FrpFrpcPath) -Raw).Trim()
    $origPub = (Get-Content -LiteralPath (Get-FrpIdentityPubPath) -Raw)

    # Fixture source tree with updated module.
    $fixtureRoot = Join-Path $env:FRP_WINDOWS_ROOT 'fixture-windows'
    $fixtureLib = Join-Path $fixtureRoot 'lib'
    New-Item -ItemType Directory -Path $fixtureLib -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixtureLib 'FrpPaths.ps1') -Value "# NEW_MODULE_MARKER`n# updated FrpPaths`n"
    $fixtureTools = Join-Path $fixtureRoot 'tools'
    New-Item -ItemType Directory -Path $fixtureTools -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixtureTools 'FrpClient.ps1') -Value "# NEW_CLIENT_TOOL`n"

    # Extract Invoke-FrpClientProjectUpdate from FrpClient.ps1
    $clientPath = Join-Path $script:RepoRoot 'windows/tools/FrpClient.ps1'
    $clientText = Get-Content -LiteralPath $clientPath -Raw
    Assert-FrpTrue ($clientText -match 'update project') 'help documents update project'
    Assert-FrpTrue ($clientText -match 'Invoke-FrpClientProjectUpdate') 'project update function exists'

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

    # Also need Resolve helpers already loaded via modules.
    $DownloadUrl = $null
    $ExpectedSha256 = $bundleSha
    $MetadataUrl = $null
    $SourceDir = $fixtureRoot

    $rc = Invoke-FrpClientProjectUpdate -SourceWindowsRoot $fixtureRoot -ExpectedBundleSha256 $bundleSha
    Assert-FrpEqual 0 $rc 'project update succeeds'

    $updated = Get-Content -LiteralPath $libDest -Raw
    Assert-FrpTrue ($updated -match 'NEW_MODULE_MARKER') 'module updated from fixture'
    Assert-FrpTrue ((Get-Content -LiteralPath $toolsDest -Raw) -match 'NEW_CLIENT_TOOL') 'tool updated'
    Assert-FrpEqual $origState (Get-Content -LiteralPath (Get-FrpStatePath) -Raw) 'state unchanged'
    Assert-FrpEqual $origToml (Get-Content -LiteralPath (Get-FrpTomlPath) -Raw) 'toml unchanged'
    Assert-FrpEqual $origExe ((Get-Content -LiteralPath (Get-FrpFrpcPath) -Raw).Trim()) 'frpc.exe unchanged'
    Assert-FrpEqual $origPub (Get-Content -LiteralPath (Get-FrpIdentityPubPath) -Raw) 'identity pub unchanged'

    $ver = Get-FrpVersionMetadata
    Assert-FrpEqual 'dev' $ver['RELEASE_CHANNEL'] 'channel preserved/written'
    Assert-FrpEqual 'main' $ver['SOURCE_REF'] 'dev source ref'
    Assert-FrpEqual $bundleSha $ver['BUNDLE_SHA256'] 'bundle sha persisted'
    Write-FrpTestPass 'PROJECT_UPDATE_FIXTURE_MODULE'

    # Pause state preserved
    Write-FrpPauseMarker -AutostartWasEnabled:$false
    Assert-FrpTrue (Test-FrpRemoteAccessPaused) 'paused before update'
    # Reset module to old, update again
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

    # Command model: update (frp) vs update project documented in help text
    $helpStart = $clientText.IndexOf("function Show-FrpClientHelp")
    Assert-FrpTrue ($helpStart -ge 0) 'help function'
    Assert-FrpTrue ($clientText -match "Update target: FRP binary" -or $clientText -match 'update frp') 'frp update documented'
    Write-FrpTestPass 'UPDATE_COMMAND_MODEL_SPLIT'

    Write-FrpTestPass 'test-windows-project-update'
} finally {
    Remove-Item Env:FRP_WINDOWS_FAIL_AFTER_PROJECT_REPLACE -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_RELEASE_CHANNEL -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_SOURCE_REF -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_BUNDLE_SHA256 -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
