#Requires -Version 5.1
<#
.SYNOPSIS
  Compact Windows zero-touch join launcher.

  Downloads bootstrap-client.ps1 from an exact immutable source, verifies
  SHA256 against SHA256SUMS, then executes with -File (never irm|iex).

  Join descriptor is an opaque credential (frpj1.<base64url JSON>), not
  command obfuscation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Join
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function ConvertFrom-FrpJoinDescriptor {
    param([Parameter(Mandatory = $true)][string]$Raw)
    $text = ([string]$Raw).Trim()
    if ($text -notmatch '^frpj1\.(.+)$') {
        throw 'ERROR: join descriptor must start with frpj1.'
    }
    $b64 = $Matches[1].Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) {
        2 { $b64 += '==' }
        3 { $b64 += '=' }
        1 { throw 'ERROR: join descriptor encoding is invalid' }
    }
    try {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    } catch {
        throw 'ERROR: join descriptor is not valid'
    }
    $parts = $decoded.Split('|')
    if ($parts.Count -lt 3) {
        throw 'ERROR: join descriptor is missing required fields'
    }
    $alloc = [string]$parts[0]
    $ca = [string]$parts[1]
    $ticket = [string]$parts[2]
    $channel = ''
    $sourceRef = ''
    $platform = 'windows'
    if ($parts.Count -eq 5) {
        # allocator|ca|ticket|channel|source_ref
        $channel = [string]$parts[3]
        $sourceRef = [string]$parts[4]
    } elseif ($parts.Count -ge 6) {
        # legacy: allocator|ca|ticket|platform|channel|source_ref
        $platform = if ($parts[3]) { [string]$parts[3] } else { 'windows' }
        $channel = [string]$parts[4]
        $sourceRef = [string]$parts[5]
    } elseif ($parts.Count -eq 4) {
        $channel = [string]$parts[3]
    }
    if ($platform -ne 'windows') {
        throw 'ERROR: this launcher only supports platform=windows'
    }
    if (-not $alloc -or -not $ca -or -not $ticket) {
        throw 'ERROR: join descriptor is missing required fields'
    }
    if ($alloc -notmatch '^https://') {
        throw 'ERROR: allocator URL must be https://'
    }
    if ($ca -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'ERROR: allocator CA fingerprint must be 64 hex characters'
    }
    if ($channel) {
        $channel = $channel.Trim().ToLowerInvariant()
        if ($channel -notin @('stable', 'dev', 'candidate')) {
            throw 'ERROR: release channel in join descriptor is invalid'
        }
    }
    if ($channel -eq 'candidate') {
        if ($sourceRef -notmatch '^[0-9a-f]{40}$') {
            throw 'ERROR: candidate source ref must be an exact 40-char commit SHA'
        }
    }
    return @{
        AllocatorUrl = $alloc
        CaSha256     = $ca.ToLowerInvariant()
        Ticket       = $ticket
        Channel      = $channel
        SourceRef    = $sourceRef
        Platform     = $platform
    }
}

function Get-FrpGithubRawBaseFromJoin {
    param($Desc)
    $owner = 'datarelay-labs'
    $repo = 'frp-auto-deploy'
    if ($Desc.Channel -eq 'candidate' -and $Desc.SourceRef) {
        $ref = $Desc.SourceRef
    } elseif ($Desc.Channel -eq 'dev') {
        $ref = 'main'
    } elseif ($Desc.SourceRef -match '^v\d+\.\d+\.\d+$') {
        $ref = $Desc.SourceRef
    } elseif ($Desc.SourceRef -match '^[0-9a-f]{40}$') {
        $ref = $Desc.SourceRef
    } else {
        throw 'ERROR: join descriptor is missing a usable source identity'
    }
    return ("https://raw.githubusercontent.com/{0}/{1}/{2}" -f $owner, $repo, $ref)
}

$desc = ConvertFrom-FrpJoinDescriptor -Raw $Join
$base = Get-FrpGithubRawBaseFromJoin -Desc $desc
$sumsUrl = "$base/SHA256SUMS"
$bootstrapUrl = "$base/dist/bootstrap-client.ps1"

$dir = Join-Path $env:TEMP ('frp-join-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
try {
    $sumsPath = Join-Path $dir 'SHA256SUMS'
    $scriptPath = Join-Path $dir 'bootstrap-client.ps1'
    $wc = New-Object Net.WebClient
    try {
        $wc.DownloadFile($sumsUrl, $sumsPath)
        $wc.DownloadFile($bootstrapUrl, $scriptPath)
    } finally {
        $wc.Dispose()
    }

    $want = $null
    Get-Content -LiteralPath $sumsPath | ForEach-Object {
        if ($_ -match '^([0-9a-fA-F]{64})\s+dist/bootstrap-client\.ps1\s*$') {
            $want = $Matches[1].ToLowerInvariant()
        }
    }
    if (-not $want) {
        throw 'ERROR: bootstrap-client.ps1 hash missing from SHA256SUMS'
    }
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $scriptPath).Hash.ToLowerInvariant()
    if ($got -ne $want) {
        throw 'ERROR: bootstrap-client.ps1 SHA256 mismatch'
    }

    $env:FRP_ALLOCATOR_URL = $desc.AllocatorUrl
    $env:FRP_ALLOCATOR_CA_SHA256 = $desc.CaSha256
    $env:FRP_BOOTSTRAP_TICKET = $desc.Ticket
    $env:FRP_ZERO_TOUCH = '1'
    $env:FRP_PLATFORM = 'windows'
    if ($desc.Channel) {
        $env:FRP_RELEASE_CHANNEL = $desc.Channel
    }
    if ($desc.SourceRef) {
        $env:FRP_SOURCE_REF = $desc.SourceRef
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ZeroTouch
    $rc = $LASTEXITCODE
    exit $rc
} finally {
    Remove-Item Env:FRP_BOOTSTRAP_TICKET -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_ALLOCATOR_URL -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_ALLOCATOR_CA_SHA256 -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_ZERO_TOUCH -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_PLATFORM -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_RELEASE_CHANNEL -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_SOURCE_REF -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
