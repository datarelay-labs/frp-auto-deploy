# FrpPaths.ps1 — filesystem layout for the Windows FRP client.
# Dot-source only. Respects FRP_WINDOWS_ROOT for non-Windows / test hosts.

if ((Test-Path variable:script:FrpPathsLoaded) -and $script:FrpPathsLoaded) { return }
$script:FrpPathsLoaded = $true

function Test-FrpIsWindowsHost {
    $edition = $null
    if ($PSVersionTable.ContainsKey('PSEdition')) {
        $edition = [string]$PSVersionTable['PSEdition']
    }
    if ($edition -eq 'Core') {
        $isWin = $false
        try { $isWin = [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction Stop) } catch { $isWin = $false }
        return $isWin
    }
    return ($env:OS -match 'Windows_NT')
}

function Get-FrpWindowsRoot {
    if ($env:FRP_WINDOWS_ROOT -and $env:FRP_WINDOWS_ROOT.Trim().Length -gt 0) {
        return $env:FRP_WINDOWS_ROOT.Trim().TrimEnd('\', '/')
    }
    if (-not (Test-FrpIsWindowsHost)) {
        $fallback = '/tmp/frp-auto-deploy-windows-test'
        return $fallback
    }
    return (Join-Path $env:ProgramData 'frp-auto-deploy')
}

function Get-FrpBinDir { Join-Path (Get-FrpWindowsRoot) 'bin' }
function Get-FrpConfigDir { Join-Path (Get-FrpWindowsRoot) 'config' }
function Get-FrpStateDir { Join-Path (Get-FrpWindowsRoot) 'state' }
function Get-FrpCertsDir { Join-Path (Get-FrpWindowsRoot) 'certs' }
function Get-FrpLogsDir { Join-Path (Get-FrpWindowsRoot) 'logs' }
function Get-FrpToolsDir { Join-Path (Get-FrpWindowsRoot) 'tools' }
function Get-FrpLibDir { Join-Path (Get-FrpWindowsRoot) 'lib' }
function Get-FrpBackupDir { Join-Path (Get-FrpWindowsRoot) 'backups' }

function Get-FrpFrpcPath { Join-Path (Get-FrpBinDir) 'frpc.exe' }
function Get-FrpTomlPath { Join-Path (Get-FrpConfigDir) 'frpc.toml' }
function Get-FrpStatePath { Join-Path (Get-FrpStateDir) 'client-state.json' }
function Get-FrpClientIdPath { Join-Path (Get-FrpStateDir) 'client-id' }
function Test-FrpEnforceWindowsIdentityPolicy {
    # Production: Windows hosts require DPAPI. Tests may set FRP_WINDOWS_ENFORCE_DPAPI_IDENTITY=1
    # on non-Windows to exercise fail-closed plaintext rejection without enabling full DPAPI/ACL.
    if ($env:FRP_WINDOWS_ENFORCE_DPAPI_IDENTITY -eq '1') { return $true }
    return (Test-FrpIsWindowsHost)
}

function Get-FrpIdentityKeyPath {
    $root = Get-FrpStateDir
    $dpapi = Join-Path $root 'client-identity.key.dpapi'
    $plain = Join-Path $root 'client-identity.key'
    if (Test-Path -LiteralPath $dpapi) { return $dpapi }
    # Windows (or enforced policy): never treat plaintext as a usable identity path.
    if (Test-FrpEnforceWindowsIdentityPolicy) { return $dpapi }
    if (Test-Path -LiteralPath $plain) { return $plain }
    return $plain
}

function Get-FrpIdentityPlainKeyPath {
    Join-Path (Get-FrpStateDir) 'client-identity.key'
}

function Get-FrpIdentityDpapiKeyPath {
    Join-Path (Get-FrpStateDir) 'client-identity.key.dpapi'
}

function Test-FrpWindowsPlaintextIdentityOnly {
    # True when Windows identity policy is active, plaintext exists, and no DPAPI blob.
    if (-not (Test-FrpEnforceWindowsIdentityPolicy)) { return $false }
    $plain = Get-FrpIdentityPlainKeyPath
    $dpapi = Get-FrpIdentityDpapiKeyPath
    return ((Test-Path -LiteralPath $plain) -and -not (Test-Path -LiteralPath $dpapi))
}
function Get-FrpIdentityPubPath { Join-Path (Get-FrpStateDir) 'client-identity.pub' }
function Get-FrpIdentityMacPath { Join-Path (Get-FrpStateDir) 'client-identity.mac' }
function Get-FrpAllocatorCaPath { Join-Path (Get-FrpCertsDir) 'allocator-ca.crt' }
function Get-FrpLogPath { Join-Path (Get-FrpLogsDir) 'frpc.log' }
function Get-FrpPidPath { Join-Path (Get-FrpLogsDir) 'frpc.pid' }
function Get-FrpVersionPath { Join-Path (Get-FrpWindowsRoot) 'version' }

function Get-FrpEnrollRecoveryPlainPath {
    Join-Path (Get-FrpStateDir) 'enroll-recovery.json'
}

function Get-FrpEnrollRecoveryDpapiPath {
    Join-Path (Get-FrpStateDir) 'enroll-recovery.json.dpapi'
}

function Get-FrpEnrollRecoveryPath {
    $dpapi = Get-FrpEnrollRecoveryDpapiPath
    $plain = Get-FrpEnrollRecoveryPlainPath
    if (Test-Path -LiteralPath $dpapi) { return $dpapi }
    if (Test-FrpIsWindowsHost) { return $dpapi }
    if (Test-Path -LiteralPath $plain) { return $plain }
    # Non-Windows tests may use plaintext; production Windows always prefers DPAPI path.
    if (Test-FrpIsWindowsHost) { return $dpapi }
    return $plain
}

function Get-FrpProjectVersion {
    if ($env:PROJECT_VERSION -and $env:PROJECT_VERSION.Trim().Length -gt 0) {
        return $env:PROJECT_VERSION.Trim()
    }
    return '2.1.1'
}

function Get-FrpUpstreamVersion {
    if ($env:FRP_VERSION -and $env:FRP_VERSION.Trim().Length -gt 0) {
        return $env:FRP_VERSION.Trim()
    }
    return '0.70.1'
}

function Get-FrpWindowsAmd64Sha256 {
    if ($env:FRP_SHA256_WINDOWS_AMD64 -and $env:FRP_SHA256_WINDOWS_AMD64.Trim().Length -gt 0) {
        return $env:FRP_SHA256_WINDOWS_AMD64.Trim().ToLowerInvariant()
    }
    return '531f3cd3cc41c0b4f077b54fe6b7dd83c0ff727e7f0bf412a4c78fa279165de5'
}

function Get-FrpWindowsAmd64Url {
    $ver = Get-FrpUpstreamVersion
    if ($env:FRP_WINDOWS_DOWNLOAD_URL -and $env:FRP_WINDOWS_DOWNLOAD_URL.Trim().Length -gt 0) {
        return $env:FRP_WINDOWS_DOWNLOAD_URL.Trim()
    }
    return "https://github.com/fatedier/frp/releases/download/v${ver}/frp_${ver}_windows_amd64.zip"
}

function Get-FrpGithubOwner {
    if ($env:FRP_GITHUB_OWNER -and $env:FRP_GITHUB_OWNER.Trim().Length -gt 0) {
        return $env:FRP_GITHUB_OWNER.Trim()
    }
    return 'datarelay-labs'
}

function Get-FrpGithubRepo {
    if ($env:FRP_GITHUB_REPO -and $env:FRP_GITHUB_REPO.Trim().Length -gt 0) {
        return $env:FRP_GITHUB_REPO.Trim()
    }
    return 'frp-auto-deploy'
}

function Get-FrpGithubRawHost {
    if ($env:FRP_GITHUB_RAW_HOST -and $env:FRP_GITHUB_RAW_HOST.Trim().Length -gt 0) {
        return $env:FRP_GITHUB_RAW_HOST.Trim()
    }
    return 'raw.githubusercontent.com'
}

function Read-FrpKvFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -notmatch '=') { continue }
        $idx = $line.IndexOf('=')
        $k = $line.Substring(0, $idx).Trim()
        if ($k -eq $Key) {
            return $line.Substring($idx + 1).Trim()
        }
    }
    return ''
}

function Get-FrpVersionMetadata {
    param([string]$Path)
    if (-not $Path) { $Path = Get-FrpVersionPath }
    $out = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -notmatch '=') { continue }
        $idx = $line.IndexOf('=')
        $k = $line.Substring(0, $idx).Trim()
        if (-not $k) { continue }
        $out[$k] = $line.Substring($idx + 1).Trim()
    }
    return $out
}

function Get-FrpNormalizeReleaseChannel {
    param([string]$Channel)
    $ch = ([string]$Channel).Trim().ToLowerInvariant()
    if (-not $ch) { $ch = 'stable' }
    switch ($ch) {
        { $_ -in @('dev', 'main', 'development') } { return 'dev' }
        'candidate' { return 'candidate' }
        'stable' { return 'stable' }
        default { return 'stable' }
    }
}

function Get-FrpParseKnownReleaseChannel {
    param([string]$Channel)
    $ch = ([string]$Channel).Trim().ToLowerInvariant()
    switch ($ch) {
        { $_ -in @('dev', 'main', 'development') } { return 'dev' }
        'candidate' { return 'candidate' }
        'stable' { return 'stable' }
        default {
            throw 'ERROR: FRP_RELEASE_CHANNEL must be stable, dev, or candidate'
        }
    }
}

function Test-FrpExactCommitSha {
    param([string]$Ref)
    return ([string]$Ref -match '^[0-9a-f]{40}$')
}

function Get-FrpRequireExactCommitSha {
    param(
        [string]$Ref,
        [string]$Label = 'FRP_SOURCE_REF'
    )
    if (-not (Test-FrpExactCommitSha -Ref $Ref)) {
        throw ("ERROR: {0} must be an exact 40-char lowercase commit SHA for candidate channel" -f $Label)
    }
    if ($Ref -eq 'main') {
        throw 'ERROR: candidate channel must not use mutable main'
    }
    return $Ref
}

function Get-FrpResolveCandidateSourceRef {
    $ref = ''
    if ($env:FRP_SOURCE_REF -and $env:FRP_SOURCE_REF.Trim().Length -gt 0) {
        $ref = $env:FRP_SOURCE_REF.Trim()
    } elseif ($env:FRP_EXPECTED_SOURCE_REF -and $env:FRP_EXPECTED_SOURCE_REF.Trim().Length -gt 0) {
        $ref = $env:FRP_EXPECTED_SOURCE_REF.Trim()
    } else {
        $ref = Read-FrpKvFile -Path (Get-FrpVersionPath) -Key 'SOURCE_REF'
    }
    return (Get-FrpRequireExactCommitSha -Ref $ref -Label 'FRP_SOURCE_REF')
}

function Get-FrpPersistedReleaseChannel {
    $ch = Read-FrpKvFile -Path (Get-FrpVersionPath) -Key 'RELEASE_CHANNEL'
    if (-not $ch) { return '' }
    return (Get-FrpNormalizeReleaseChannel -Channel $ch)
}

function Get-FrpReleaseChannel {
    if ($env:FRP_RELEASE_CHANNEL -and $env:FRP_RELEASE_CHANNEL.Trim().Length -gt 0) {
        return (Get-FrpParseKnownReleaseChannel -Channel $env:FRP_RELEASE_CHANNEL)
    }
    $persisted = Get-FrpPersistedReleaseChannel
    if ($persisted) { return $persisted }
    return 'stable'
}

function Get-FrpReleaseGitRef {
    $ch = Get-FrpReleaseChannel
    switch ($ch) {
        'dev' { return 'main' }
        'candidate' { return (Get-FrpResolveCandidateSourceRef) }
        default { return ("v{0}" -f (Get-FrpProjectVersion)) }
    }
}

function Get-FrpGithubRawUrl {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $rel = $RelativePath.TrimStart('/')
    $ref = Get-FrpReleaseGitRef
    return ("https://{0}/{1}/{2}/{3}/{4}" -f `
        (Get-FrpGithubRawHost), (Get-FrpGithubOwner), (Get-FrpGithubRepo), $ref, $rel)
}

function Get-FrpDefaultWindowsClientInstallerUrl {
    return (Get-FrpGithubRawUrl -RelativePath 'dist/bootstrap-client.ps1')
}

function Get-FrpDefaultReleaseSha256SumsUrl {
    return (Get-FrpGithubRawUrl -RelativePath 'SHA256SUMS')
}

function Write-FrpVersionFile {
    <#
    .SYNOPSIS
      Persist Linux-parity build identity (channel/ref/bundle) plus Windows FRP zip digest.
    #>
    param(
        [string]$Path,
        [string]$FrpSha256WindowsAmd64,
        [string]$BundleSha256
    )
    if (-not $Path) { $Path = Get-FrpVersionPath }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($env:FRP_RELEASE_CHANNEL -and $env:FRP_RELEASE_CHANNEL.Trim().Length -gt 0) {
        $channel = Get-FrpNormalizeReleaseChannel -Channel $env:FRP_RELEASE_CHANNEL
    } else {
        $existing = Read-FrpKvFile -Path $Path -Key 'RELEASE_CHANNEL'
        if ($existing) {
            $channel = Get-FrpNormalizeReleaseChannel -Channel $existing
        } else {
            $channel = Get-FrpReleaseChannel
        }
    }

    if ($channel -eq 'dev') {
        $sourceRef = 'main'
    } elseif ($channel -eq 'candidate') {
        $sourceRef = ''
        if ($env:FRP_SOURCE_REF -and $env:FRP_SOURCE_REF.Trim().Length -gt 0) {
            $sourceRef = $env:FRP_SOURCE_REF.Trim()
        } elseif ($env:FRP_EXPECTED_SOURCE_REF -and $env:FRP_EXPECTED_SOURCE_REF.Trim().Length -gt 0) {
            $sourceRef = $env:FRP_EXPECTED_SOURCE_REF.Trim()
        }
        if (-not $sourceRef) {
            $sourceRef = Read-FrpKvFile -Path $Path -Key 'SOURCE_REF'
        }
        $sourceRef = Get-FrpRequireExactCommitSha -Ref $sourceRef -Label 'FRP_SOURCE_REF'
    } else {
        $sourceRef = ("v{0}" -f (Get-FrpProjectVersion))
    }

    $bundle = $BundleSha256
    if (-not $bundle -and $env:FRP_BUNDLE_SHA256 -and $env:FRP_BUNDLE_SHA256.Trim().Length -gt 0) {
        $bundle = $env:FRP_BUNDLE_SHA256.Trim()
    }
    if ($env:FRP_VERSION_REQUIRE_VERIFIED_BUNDLE -eq '1') {
        if ($bundle -notmatch '^[0-9a-fA-F]{64}$') {
            $bundle = ''
        }
    } else {
        if (-not $bundle -and $env:FRP_BUNDLE_FILE -and (Test-Path -LiteralPath $env:FRP_BUNDLE_FILE)) {
            if (Get-Command Get-FrpSha256HexOfFile -ErrorAction SilentlyContinue) {
                $bundle = Get-FrpSha256HexOfFile -Path $env:FRP_BUNDLE_FILE
            }
        }
        if (-not $bundle) {
            $bundle = Read-FrpKvFile -Path $Path -Key 'BUNDLE_SHA256'
        }
    }
    if ($bundle -and $bundle -match '^[0-9a-fA-F]{64}$') {
        $bundle = $bundle.ToLowerInvariant()
    } elseif ($bundle) {
        # Keep non-hex only when not requiring verified bundle (should be rare).
        $bundle = $bundle.Trim()
    } else {
        $bundle = ''
    }

    $frpSha = $FrpSha256WindowsAmd64
    if (-not $frpSha) {
        $frpSha = Read-FrpKvFile -Path $Path -Key 'FRP_SHA256_WINDOWS_AMD64'
    }
    if (-not $frpSha -and $env:FRP_SHA256_WINDOWS_AMD64) {
        $frpSha = $env:FRP_SHA256_WINDOWS_AMD64.Trim()
    }
    if ($frpSha) { $frpSha = $frpSha.ToLowerInvariant() }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("PROJECT_VERSION=$(Get-FrpProjectVersion)")
    [void]$lines.Add("FRP_VERSION=$(Get-FrpUpstreamVersion)")
    [void]$lines.Add("RELEASE_CHANNEL=$channel")
    [void]$lines.Add("SOURCE_REF=$sourceRef")
    if ($bundle) {
        [void]$lines.Add("BUNDLE_SHA256=$bundle")
    }
    if ($frpSha) {
        [void]$lines.Add("FRP_SHA256_WINDOWS_AMD64=$frpSha")
    }
    $tmp = Join-Path $dir ('.version.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $Path
}

function Get-FrpReportedBuildFields {
    <#
    .SYNOPSIS
      Map version-file identity to server reported_* fields (Linux enroll/mgmt parity).
    #>
    param([string]$Path)
    if (-not $Path) { $Path = Get-FrpVersionPath }
    $meta = Get-FrpVersionMetadata -Path $Path
    $mapping = [ordered]@{
        PROJECT_VERSION = 'reported_project_version'
        RELEASE_CHANNEL = 'reported_release_channel'
        SOURCE_REF      = 'reported_source_ref'
        BUNDLE_SHA256   = 'reported_bundle_sha256'
        FRP_VERSION     = 'reported_frp_version'
    }
    $out = [ordered]@{}
    foreach ($src in $mapping.Keys) {
        $val = ''
        if ($meta.Contains($src)) { $val = [string]$meta[$src] }
        $val = $val.Trim()
        if ($val) {
            $out[$mapping[$src]] = $val
        }
    }
    return $out
}

function Get-FrpBuildDriftClass {
    <#
    .SYNOPSIS
      Mirror lib/frp_client_registry.py build_drift_class for Windows tests/helpers.
    #>
    param(
        $Client,
        $Expected = $null
    )
    if ($null -eq $Client) { return 'unknown' }
    $clientMap = @{}
    if ($Client -is [System.Collections.IDictionary]) {
        foreach ($k in $Client.Keys) { $clientMap[[string]$k] = $Client[$k] }
    } else {
        foreach ($p in $Client.PSObject.Properties) { $clientMap[$p.Name] = $p.Value }
    }
    $reportedAt = [string]$clientMap['build_reported_at']
    $project = ([string]$clientMap['reported_project_version']).Trim()
    if ((-not $project) -and (-not $reportedAt)) { return 'unknown' }

    if ($null -eq $Expected) {
        $Expected = Get-FrpVersionMetadata
    }
    $exp = @{}
    if ($Expected -is [System.Collections.IDictionary]) {
        foreach ($k in $Expected.Keys) { $exp[[string]$k] = $Expected[$k] }
    } else {
        foreach ($p in $Expected.PSObject.Properties) { $exp[$p.Name] = $p.Value }
    }

    $expProject = ([string]$exp['PROJECT_VERSION']).Trim()
    $expChannel = ([string]$exp['RELEASE_CHANNEL']).Trim()
    $expRef = ([string]$exp['SOURCE_REF']).Trim()
    $expBundle = ([string]$exp['BUNDLE_SHA256']).Trim()
    $expFrp = ([string]$exp['FRP_VERSION']).Trim()
    if (-not $expProject) { return 'unknown' }

    $drift = $false
    if ($project -and $expProject -and ($project -ne $expProject)) { $drift = $true }
    $channel = ([string]$clientMap['reported_release_channel']).Trim()
    if ($channel -and $expChannel -and ($channel -ne $expChannel)) { $drift = $true }
    $ref = ([string]$clientMap['reported_source_ref']).Trim()
    if ($ref -and $expRef -and ($ref -ne $expRef)) { $drift = $true }
    $bundle = ([string]$clientMap['reported_bundle_sha256']).Trim()
    if ($bundle -and $expBundle -and ($bundle -ne $expBundle)) { $drift = $true }
    $frp = ([string]$clientMap['reported_frp_version']).Trim()
    if ($frp -and $expFrp -and ($frp -ne $expFrp)) { $drift = $true }

    if ($drift) { return 'drift' }
    if ($project) { return 'current' }
    return 'unknown'
}

