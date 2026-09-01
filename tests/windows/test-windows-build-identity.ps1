# test-windows-build-identity.ps1 — P1-S candidate/stable/dev version identity + reported_* + build_drift
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')

try {
    $SHA = 'ffffffffffffffffffffffffffffffffffffffff'
    $BUNDLE = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

    function Clear-FrpChannelEnv {
        foreach ($n in @(
                'FRP_RELEASE_CHANNEL', 'FRP_SOURCE_REF', 'FRP_EXPECTED_SOURCE_REF',
                'FRP_BUNDLE_SHA256', 'FRP_BUNDLE_FILE', 'FRP_VERSION_REQUIRE_VERIFIED_BUNDLE'
            )) {
            Remove-Item "Env:$n" -ErrorAction SilentlyContinue
        }
    }

    # --- stable → vPROJECT_VERSION ---
    Clear-FrpChannelEnv
    $env:FRP_RELEASE_CHANNEL = 'stable'
    Assert-FrpEqual 'stable' (Get-FrpReleaseChannel) 'stable channel'
    Assert-FrpEqual ("v{0}" -f (Get-FrpProjectVersion)) (Get-FrpReleaseGitRef) 'stable git ref'
    Write-FrpVersionFile -BundleSha256 $BUNDLE | Out-Null
    $meta = Get-FrpVersionMetadata
    Assert-FrpEqual 'stable' $meta['RELEASE_CHANNEL'] 'persisted stable channel'
    Assert-FrpEqual ("v{0}" -f (Get-FrpProjectVersion)) $meta['SOURCE_REF'] 'persisted stable SOURCE_REF'
    Assert-FrpEqual $BUNDLE $meta['BUNDLE_SHA256'] 'persisted stable bundle'
    Assert-FrpTrue ($meta.Contains('PROJECT_VERSION')) 'PROJECT_VERSION present'
    Assert-FrpTrue ($meta.Contains('FRP_VERSION')) 'FRP_VERSION present'
    Write-FrpTestPass 'STABLE_TO_V_PROJECT_VERSION'

    # --- dev → main ---
    Clear-FrpChannelEnv
    Remove-Item -LiteralPath (Get-FrpVersionPath) -Force -ErrorAction SilentlyContinue
    $env:FRP_RELEASE_CHANNEL = 'dev'
    Assert-FrpEqual 'dev' (Get-FrpReleaseChannel) 'dev channel'
    Assert-FrpEqual 'main' (Get-FrpReleaseGitRef) 'dev git ref'
    Write-FrpVersionFile -BundleSha256 $BUNDLE | Out-Null
    $meta = Get-FrpVersionMetadata
    Assert-FrpEqual 'dev' $meta['RELEASE_CHANNEL'] 'persisted dev channel'
    Assert-FrpEqual 'main' $meta['SOURCE_REF'] 'persisted dev SOURCE_REF'
    Write-FrpTestPass 'DEV_TO_MAIN'

    # --- candidate exact SHA ---
    Clear-FrpChannelEnv
    Remove-Item -LiteralPath (Get-FrpVersionPath) -Force -ErrorAction SilentlyContinue
    $env:FRP_RELEASE_CHANNEL = 'candidate'
    $env:FRP_SOURCE_REF = $SHA
    $env:FRP_BUNDLE_SHA256 = $BUNDLE
    Assert-FrpEqual $SHA (Get-FrpReleaseGitRef) 'candidate git ref'
    Write-FrpVersionFile | Out-Null
    $meta = Get-FrpVersionMetadata
    Assert-FrpEqual 'candidate' $meta['RELEASE_CHANNEL'] 'persisted candidate channel'
    Assert-FrpEqual $SHA $meta['SOURCE_REF'] 'persisted candidate SOURCE_REF'
    Assert-FrpEqual $BUNDLE $meta['BUNDLE_SHA256'] 'persisted candidate bundle'
    # Must not invent v2.1.1 / main for candidate
    Assert-FrpTrue ($meta['SOURCE_REF'] -ne ("v{0}" -f (Get-FrpProjectVersion))) 'candidate not tag'
    Assert-FrpTrue ($meta['SOURCE_REF'] -ne 'main') 'candidate not main'
    Write-FrpTestPass 'CANDIDATE_EXACT_SHA_PERSISTED'

    # --- candidate missing SHA ---
    Clear-FrpChannelEnv
    Remove-Item -LiteralPath (Get-FrpVersionPath) -Force -ErrorAction SilentlyContinue
    $env:FRP_RELEASE_CHANNEL = 'candidate'
    $threw = $false
    try { Write-FrpVersionFile | Out-Null } catch {
        $threw = $true
        Assert-FrpTrue ($_.Exception.Message -match 'SHA|SOURCE_REF|source ref') 'missing SHA message'
    }
    Assert-FrpTrue $threw 'candidate without SHA rejected'
    Write-FrpTestPass 'CANDIDATE_MISSING_SHA_REJECTED'

    # --- candidate main rejected ---
    Clear-FrpChannelEnv
    Remove-Item -LiteralPath (Get-FrpVersionPath) -Force -ErrorAction SilentlyContinue
    $env:FRP_RELEASE_CHANNEL = 'candidate'
    $env:FRP_SOURCE_REF = 'main'
    $threw = $false
    try { [void](Get-FrpReleaseGitRef) } catch { $threw = $true }
    Assert-FrpTrue $threw 'candidate main rejected via git ref'
    $threw = $false
    try { Write-FrpVersionFile | Out-Null } catch { $threw = $true }
    Assert-FrpTrue $threw 'candidate main rejected via version write'
    Write-FrpTestPass 'CANDIDATE_MAIN_REJECTED'

    # --- candidate malformed SHA ---
    Clear-FrpChannelEnv
    Remove-Item -LiteralPath (Get-FrpVersionPath) -Force -ErrorAction SilentlyContinue
    $env:FRP_RELEASE_CHANNEL = 'candidate'
    $env:FRP_SOURCE_REF = 'deadbeef'
    $threw = $false
    try { Write-FrpVersionFile | Out-Null } catch { $threw = $true }
    Assert-FrpTrue $threw 'malformed SHA rejected'
    Write-FrpTestPass 'CANDIDATE_MALFORMED_SHA_REJECTED'

    # --- unknown channel fail-closed (env) ---
    Clear-FrpChannelEnv
    $env:FRP_RELEASE_CHANNEL = 'not-a-channel'
    $threw = $false
    try { [void](Get-FrpReleaseChannel) } catch {
        $threw = $true
        Assert-FrpTrue ($_.Exception.Message -match 'stable, dev, or candidate') 'unknown channel message'
    }
    Assert-FrpTrue $threw 'unknown channel rejected'
    Write-FrpTestPass 'UNKNOWN_CHANNEL_FAIL_CLOSED'

    # --- reported_* mapping ---
    Clear-FrpChannelEnv
    Remove-Item -LiteralPath (Get-FrpVersionPath) -Force -ErrorAction SilentlyContinue
    $env:FRP_RELEASE_CHANNEL = 'candidate'
    $env:FRP_SOURCE_REF = $SHA
    $env:FRP_BUNDLE_SHA256 = $BUNDLE
    Write-FrpVersionFile | Out-Null
    $reported = Get-FrpReportedBuildFields
    Assert-FrpEqual (Get-FrpProjectVersion) $reported['reported_project_version'] 'reported project'
    Assert-FrpEqual 'candidate' $reported['reported_release_channel'] 'reported channel'
    Assert-FrpEqual $SHA $reported['reported_source_ref'] 'reported source ref'
    Assert-FrpEqual $BUNDLE $reported['reported_bundle_sha256'] 'reported bundle'
    Assert-FrpEqual (Get-FrpUpstreamVersion) $reported['reported_frp_version'] 'reported frp'
    Write-FrpTestPass 'REPORTED_BUILD_FIELDS'

    # --- enroll payload includes reported_* ---
    $payload = [ordered]@{
        machine_id = 'm1'
        hostname   = 'h1'
        services   = @()
    }
    foreach ($k in $reported.Keys) { $payload[$k] = $reported[$k] }
    Assert-FrpTrue ($payload.Contains('reported_source_ref')) 'enroll-shaped payload has source ref'
    Assert-FrpEqual $SHA $payload['reported_source_ref'] 'enroll-shaped source ref value'
    Write-FrpTestPass 'ENROLL_PAYLOAD_REPORTED_FIELDS'

    # --- build_drift ---
    $expected = Get-FrpVersionMetadata
    $clientCurrent = @{
        reported_project_version = $expected['PROJECT_VERSION']
        reported_release_channel = $expected['RELEASE_CHANNEL']
        reported_source_ref      = $expected['SOURCE_REF']
        reported_bundle_sha256   = $expected['BUNDLE_SHA256']
        reported_frp_version     = $expected['FRP_VERSION']
        build_reported_at        = '2099-01-01T00:00:00Z'
    }
    Assert-FrpEqual 'current' (Get-FrpBuildDriftClass -Client $clientCurrent -Expected $expected) 'drift current'

    $clientDrift = $clientCurrent.Clone()
    $clientDrift['reported_source_ref'] = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    Assert-FrpEqual 'drift' (Get-FrpBuildDriftClass -Client $clientDrift -Expected $expected) 'drift on SHA'

    $clientBundleDrift = $clientCurrent.Clone()
    $clientBundleDrift['reported_bundle_sha256'] = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    Assert-FrpEqual 'drift' (Get-FrpBuildDriftClass -Client $clientBundleDrift -Expected $expected) 'drift on bundle'

    Assert-FrpEqual 'unknown' (Get-FrpBuildDriftClass -Client @{} -Expected $expected) 'unknown empty'
    Assert-FrpEqual 'unknown' (Get-FrpBuildDriftClass -Client @{ reported_project_version = '2.1.1' } -Expected @{}) 'unknown no expected'
    Write-FrpTestPass 'BUILD_DRIFT_CLASSES'

    # --- Install-FrpWindowsBinary version write uses Write-FrpVersionFile fields ---
    Clear-FrpChannelEnv
    Remove-Item -LiteralPath (Get-FrpVersionPath) -Force -ErrorAction SilentlyContinue
    $env:FRP_RELEASE_CHANNEL = 'stable'
    $env:FRP_BUNDLE_SHA256 = $BUNDLE
    # Simulate post-binary version write path without network.
    Write-FrpVersionFile -FrpSha256WindowsAmd64 ('c' * 64) -BundleSha256 $BUNDLE | Out-Null
    $meta = Get-FrpVersionMetadata
    Assert-FrpTrue ($meta.Contains('RELEASE_CHANNEL')) 'binary path keeps channel'
    Assert-FrpTrue ($meta.Contains('SOURCE_REF')) 'binary path keeps SOURCE_REF'
    Assert-FrpTrue ($meta.Contains('BUNDLE_SHA256')) 'binary path keeps BUNDLE_SHA256'
    Assert-FrpEqual ('c' * 64) $meta['FRP_SHA256_WINDOWS_AMD64'] 'windows FRP digest retained'
    Write-FrpTestPass 'WINDOWS_BINARY_VERSION_PARITY_FIELDS'

    Write-FrpTestPass 'test-windows-build-identity'
} finally {
    foreach ($n in @(
            'FRP_RELEASE_CHANNEL', 'FRP_SOURCE_REF', 'FRP_EXPECTED_SOURCE_REF',
            'FRP_BUNDLE_SHA256', 'FRP_BUNDLE_FILE', 'FRP_VERSION_REQUIRE_VERIFIED_BUNDLE'
        )) {
        Remove-Item "Env:$n" -ErrorAction SilentlyContinue
    }
    Remove-FrpWindowsTestRoot
}
