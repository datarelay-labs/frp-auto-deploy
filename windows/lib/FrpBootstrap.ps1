# FrpBootstrap.ps1 — zero-touch redeem → enroll → decrypt → config → download → start.

if ((Test-Path variable:script:FrpBootstrapLoaded) -and $script:FrpBootstrapLoaded) { return }
$script:FrpBootstrapLoaded = $true

# When this file lives in windows/lib, package root is windows/
if (-not $script:FrpWindowsSrcRoot) {
    if ($PSScriptRoot) {
        $script:FrpWindowsSrcRoot = Split-Path -Parent $PSScriptRoot
    }
}

function Clear-FrpSecretEnv {
    foreach ($name in @(
            'FRP_BOOTSTRAP_TICKET', 'FRP_ENROLL_SECRET', 'FRP_ENROLLMENT_SECRET',
            'FRP_TOKEN', 'FRP_SERVER_TOKEN', 'MGMT_ENROLL_SECRET'
        )) {
        if (Test-Path "Env:$name") {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
    }
}

function Expand-FrpZipSafe {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$DestinationDir,
        [Parameter(Mandatory = $true)][string]$EntryName
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $target = $null
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName -replace '\\', '/'
            if ($name.EndsWith('/')) { continue }
            $leaf = Split-Path -Leaf $name
            if ($leaf -ieq $EntryName) {
                # Zip-slip: reject absolute / parent traversal
                if ($name.Contains('..') -or $name.StartsWith('/') -or $name -match '^[A-Za-z]:') {
                    throw 'ERROR: unsafe zip entry rejected'
                }
                $target = $entry
                break
            }
        }
        if (-not $target) {
            throw ("ERROR: {0} not found in FRP archive" -f $EntryName)
        }
        if (-not (Test-Path -LiteralPath $DestinationDir)) {
            New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
        }
        $outPath = Join-Path $DestinationDir $EntryName
        $tmp = "$outPath.tmp"
        $fs = [System.IO.File]::Create($tmp)
        try {
            $es = $target.Open()
            try { $es.CopyTo($fs) } finally { $es.Dispose() }
        } finally { $fs.Dispose() }
        Move-Item -LiteralPath $tmp -Destination $outPath -Force
        return $outPath
    } finally {
        $zip.Dispose()
    }
}

function Install-FrpWindowsBinary {
    param(
        [string]$DownloadUrl,
        [string]$ExpectedSha256
    )
    Initialize-FrpDirectories
    if (-not $DownloadUrl) { $DownloadUrl = Get-FrpWindowsAmd64Url }
    if (-not $ExpectedSha256) { $ExpectedSha256 = Get-FrpWindowsAmd64Sha256 }
    $expected = $ExpectedSha256.Trim().ToLowerInvariant()
    if ($DownloadUrl -notmatch '^https://') {
        throw 'ERROR: FRP download URL must be https://'
    }

    $binDir = Get-FrpBinDir
    $dest = Get-FrpFrpcPath
    if ((Test-Path -LiteralPath $dest) -and $env:FRP_WINDOWS_SKIP_DOWNLOAD -eq '1') {
        return $dest
    }

    $tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) ("frp-win-" + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        Write-Host 'Downloading FRP Windows amd64 package...'
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            $p = Start-Process -FilePath 'curl.exe' -ArgumentList @(
                '--fail', '--silent', '--show-error', '--location',
                '--proto', '=https', '--proto-redir', '=https',
                '-o', $tmpZip, $DownloadUrl
            ) -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -ne 0) { throw 'ERROR: FRP download failed' }
        } else {
            # PS 5.1 / 7 compatible
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            try { $wc.DownloadFile($DownloadUrl, $tmpZip) } finally { $wc.Dispose() }
        }
        $actual = Get-FrpSha256HexOfFile -Path $tmpZip
        if ($actual -ne $expected) {
            throw 'ERROR: FRP package SHA256 mismatch'
        }
        Expand-FrpZipSafe -ZipPath $tmpZip -DestinationDir $binDir -EntryName 'frpc.exe' | Out-Null
        if (-not (Test-Path -LiteralPath $dest)) {
            throw 'ERROR: frpc.exe extract failed'
        }
        # Persist Linux-parity build identity + Windows FRP package digest.
        Write-FrpVersionFile -FrpSha256WindowsAmd64 $expected | Out-Null
        return $dest
    } finally {
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    }
}

function Get-FrpWindowsProjectManagedRelativePaths {
    <#
    .SYNOPSIS
      Relative paths under a windows/ package root that project-update may replace.
      Identity, ports, pause marker, frpc.toml, and frpc.exe are intentionally excluded.
    #>
    return @(
        'lib/FrpPaths.ps1',
        'lib/FrpCrypto.ps1',
        'lib/FrpTls.ps1',
        'lib/FrpClockSync.ps1',
        'lib/FrpState.ps1',
        'lib/FrpConfig.ps1',
        'lib/FrpProcess.ps1',
        'lib/FrpBootstrap.ps1',
        'lib/FrpLifecycle.ps1',
        'tools/FrpClient.ps1',
        'tools/FrpCtl.ps1',
        'tools/frp-client.cmd',
        'tools/frpctl.cmd',
        'tools/frpcli.cmd',
        'install-client.ps1',
        'README.md'
    )
}

function Get-FrpWindowsProjectOptionalRelativePaths {
    <#
    .SYNOPSIS
      Explicitly optional managed paths (none today). Kept for future use so
      Install-FrpWindowsProjectTree never treats required files as optional.
    #>
    return @()
}

function Assert-FrpWindowsManagedTreeComplete {
    param(
        [Parameter(Mandatory = $true)][string]$SourceWindowsRoot
    )
    $optional = @{}
    foreach ($rel in (Get-FrpWindowsProjectOptionalRelativePaths)) {
        $optional[$rel] = $true
    }
    $missing = @()
    foreach ($rel in (Get-FrpWindowsProjectManagedRelativePaths)) {
        if ($optional.ContainsKey($rel)) { continue }
        $src = Join-Path $SourceWindowsRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $src)) {
            $missing += $rel
        }
    }
    if ($missing.Count -gt 0) {
        throw ("ERROR: Windows project source is missing required managed file(s): {0}" -f ($missing -join ', '))
    }
}

function Expand-FrpWindowsBootstrapTree {
    <#
    .SYNOPSIS
      Materialize the embedded windows/ tree from a verified bootstrap-client.ps1
      without executing the script (no Invoke-Expression / irm|iex).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BootstrapPath,
        [Parameter(Mandatory = $true)][string]$DestinationDir
    )
    if (-not (Test-Path -LiteralPath $BootstrapPath)) {
        throw ("ERROR: bootstrap artifact missing: {0}" -f $BootstrapPath)
    }
    $text = [System.IO.File]::ReadAllText($BootstrapPath)
    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }
    $destRoot = (Resolve-Path -LiteralPath $DestinationDir).Path
    # Single-quoted so $out/$tmp/$b64 are literal regex text, not PowerShell expansions.
    $pattern = '(?ms)\$out\s*=\s*Join-Path\s+\$tmp\s+''(?<rel>windows/[^'']+)''\s*\r?\n\s*\$b64\s*=\s*@''(?<b64>.*?)''@\s*\r?\n\s*\[IO\.File\]::WriteAllBytes'
    $matches = [regex]::Matches($text, $pattern)
    if ($matches.Count -lt 1) {
        throw 'ERROR: verified bootstrap does not contain an extractable windows/ payload'
    }
    $written = 0
    foreach ($m in $matches) {
        $rel = $m.Groups['rel'].Value -replace '\\', '/'
        if ($rel.StartsWith('/') -or $rel.Contains('..') -or -not $rel.StartsWith('windows/')) {
            throw ("ERROR: bootstrap payload path refused: {0}" -f $rel)
        }
        $b64 = ($m.Groups['b64'].Value -replace '\s', '')
        if ([string]::IsNullOrWhiteSpace($b64)) {
            throw ("ERROR: empty bootstrap payload for {0}" -f $rel)
        }
        $bytes = [Convert]::FromBase64String($b64)
        $out = Join-Path $destRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $outFull = [System.IO.Path]::GetFullPath($out)
        if (-not $outFull.StartsWith($destRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("ERROR: bootstrap extract path escapes destination: {0}" -f $rel)
        }
        $parent = Split-Path -Parent $outFull
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::WriteAllBytes($outFull, $bytes)
        $written++
    }
    $windowsRoot = Join-Path $destRoot 'windows'
    if (-not (Test-Path -LiteralPath $windowsRoot)) {
        throw 'ERROR: bootstrap extract did not produce a windows/ directory'
    }
    Assert-FrpWindowsManagedTreeComplete -SourceWindowsRoot $windowsRoot
    return $windowsRoot
}

function Install-FrpWindowsProjectTree {
    <#
    .SYNOPSIS
      Copy managed PowerShell modules/tools from a windows/ source tree into the install root.
      Does not touch identity, state, config, pause marker, or frpc.exe.
      Required managed files must all be present; missing files fail closed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SourceWindowsRoot
    )
    if (-not (Test-Path -LiteralPath $SourceWindowsRoot)) {
        throw ("ERROR: Windows project source missing: {0}" -f $SourceWindowsRoot)
    }
    Assert-FrpWindowsManagedTreeComplete -SourceWindowsRoot $SourceWindowsRoot
    Initialize-FrpDirectories
    $root = Get-FrpWindowsRoot
    $optional = @{}
    foreach ($rel in (Get-FrpWindowsProjectOptionalRelativePaths)) {
        $optional[$rel] = $true
    }
    foreach ($rel in (Get-FrpWindowsProjectManagedRelativePaths)) {
        $src = Join-Path $SourceWindowsRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $src)) {
            if ($optional.ContainsKey($rel)) { continue }
            throw ("ERROR: Windows project source is missing required managed file: {0}" -f $rel)
        }
        $dest = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dest -Force
    }
    return $root
}

function Get-FrpSha256SumsEntry {
    param(
        [Parameter(Mandatory = $true)][string]$SumsPath,
        [Parameter(Mandatory = $true)][string]$ArtifactName
    )
    if (-not (Test-Path -LiteralPath $SumsPath)) {
        throw 'ERROR: SHA256SUMS metadata file is missing'
    }
    foreach ($line in [System.IO.File]::ReadAllLines($SumsPath)) {
        $parts = $line.Trim() -split '\s+', 2
        if ($parts.Count -lt 2) { continue }
        if ($parts[1] -eq $ArtifactName -and $parts[0] -match '^[0-9a-fA-F]{64}$') {
            return $parts[0].ToLowerInvariant()
        }
    }
    throw ("ERROR: update integrity metadata does not contain {0}" -f $ArtifactName)
}

function Test-FrpUrlHasSourceRef {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Ref
    )
    try {
        $u = [Uri]$Url
    } catch {
        return $false
    }
    $parts = @($u.AbsolutePath.Split('/') | Where-Object { $_ -and $_.Length -gt 0 } |
        ForEach-Object { [Uri]::UnescapeDataString($_) })
    return ($parts -contains $Ref)
}

function Get-FrpWindowsProjectUpdateRemoteDownloadMode {
    <#
    .SYNOPSIS
      Decide how remote Windows project-update artifacts may be fetched.
      Returns 'mock' or 'curl'. Refuses WebClient fallback (HTTPS redirect policy).
    .PARAMETER CurlAvailable
      Optional override for tests: $true / $false. When omitted, detects curl.exe.
    #>
    param(
        [object]$CurlAvailable = $null
    )
    if ($env:FRP_WINDOWS_PROJECT_UPDATE_MOCK_DIR -and
        (Test-Path -LiteralPath $env:FRP_WINDOWS_PROJECT_UPDATE_MOCK_DIR)) {
        return 'mock'
    }
    if ($env:FRP_WINDOWS_PROJECT_UPDATE_FORCE_NO_CURL -eq '1') {
        $hasCurl = $false
    } elseif ($null -ne $CurlAvailable) {
        $hasCurl = [bool]$CurlAvailable
    } else {
        $hasCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
    }
    if ($hasCurl) {
        return 'curl'
    }
    throw (
        'ERROR: remote project update requires curl.exe for HTTPS-only redirect policy. ' +
        'Install curl.exe, or use a local source directory (-SourceDir / FRP_WINDOWS_PROJECT_SOURCE).'
    )
}

function Resolve-FrpWindowsProjectUpdateIdentity {
    <#
    .SYNOPSIS
      Resolve release channel + source ref for Windows project update (candidate fail-closed).
    #>
    $channel = ''
    if ($env:FRP_RELEASE_CHANNEL -and $env:FRP_RELEASE_CHANNEL.Trim().Length -gt 0) {
        $channel = Get-FrpParseKnownReleaseChannel -Channel $env:FRP_RELEASE_CHANNEL
    } elseif ((Get-FrpPersistedReleaseChannel)) {
        $channel = Get-FrpPersistedReleaseChannel
    } else {
        $channel = Get-FrpReleaseChannel
    }

    $sourceRef = ''
    if ($env:FRP_EXPECTED_SOURCE_REF -and $env:FRP_EXPECTED_SOURCE_REF.Trim().Length -gt 0) {
        $sourceRef = $env:FRP_EXPECTED_SOURCE_REF.Trim()
    } elseif ($channel -eq 'dev') {
        $sourceRef = 'main'
    } elseif ($channel -eq 'candidate') {
        if ($env:FRP_SOURCE_REF -and $env:FRP_SOURCE_REF.Trim().Length -gt 0) {
            $sourceRef = $env:FRP_SOURCE_REF.Trim()
        } else {
            $sourceRef = Read-FrpKvFile -Path (Get-FrpVersionPath) -Key 'SOURCE_REF'
        }
        $sourceRef = Get-FrpRequireExactCommitSha -Ref $sourceRef -Label 'SOURCE_REF'
    } else {
        $sourceRef = ("v{0}" -f (Get-FrpProjectVersion))
    }
    if ($channel -eq 'candidate') {
        $sourceRef = Get-FrpRequireExactCommitSha -Ref $sourceRef -Label 'SOURCE_REF'
    }
    return @{
        Channel   = $channel
        SourceRef = $sourceRef
    }
}

function ConvertTo-FrpBootstrapServices {
    param(
        [Parameter(Mandatory = $true)]$Data
    )
    if ($Data.PSObject.Properties.Name -notcontains 'services') {
        throw 'ERROR: bootstrap response is missing services'
    }
    if ($null -eq $Data.services) {
        throw 'ERROR: bootstrap response services is null'
    }
    $rawServices = $Data.services
    if ($rawServices -is [string]) {
        throw 'ERROR: bootstrap response services must be an array'
    }
    if ($rawServices -is [System.Collections.IDictionary]) {
        throw 'ERROR: bootstrap response services must be an array'
    }
    # Empty Object[] is management-only and must be accepted as-is (do not invent RDP).
    # A bare PSCustomObject is treated as a PS 5.1 single-element unwrap, not a map.
    if ($rawServices -is [System.Array] -or $rawServices -is [System.Collections.IList]) {
        return @($rawServices)
    }
    if ($rawServices -is [System.Management.Automation.PSObject]) {
        return @($rawServices)
    }
    throw 'ERROR: bootstrap response services must be an array'
}

function Invoke-FrpBootstrapRedeem {
    param(
        [Parameter(Mandatory = $true)][string]$AllocatorUrl,
        [Parameter(Mandatory = $true)][string]$Ticket,
        [Parameter(Mandatory = $true)][string]$MachineId,
        [Parameter(Mandatory = $true)][string]$Hostname
    )
    $origin = Get-FrpAllocatorOrigin -AllocatorUrl $AllocatorUrl
    $url = "$origin/bootstrap/redeem"
    $payload = [ordered]@{
        ticket     = $Ticket
        machine_id = $MachineId
        hostname   = $Hostname
    }
    # Compact JSON (no spaces) matching Linux client
    $body = Get-FrpCanonicalJson -Object $payload
    $respText = Invoke-FrpHttpsJson -Method POST -Url $url -Body $body
    $data = $respText | ConvertFrom-Json
    if ($data.error) {
        $cls = [string]$data.error_class
        if (-not $cls) { $cls = 'BOOTSTRAP_REDEEM_FAILED' }
        throw ("ERROR: {0} [{1}]" -f [string]$data.error, $cls)
    }
    $code = [string]$data.enrollment_code
    if (-not $code -or -not $code.Contains('.')) {
        throw 'ERROR: bootstrap response is missing enrollment data'
    }
    $parts = $code.Split('.', 2)
    $services = ConvertTo-FrpBootstrapServices -Data $data
    return @{
        EnrollmentId     = $parts[0]
        EnrollmentSecret = $parts[1]
        Services         = $services
    }
}

function Invoke-FrpEnrollChallenge {
    param(
        [Parameter(Mandatory = $true)][string]$AllocatorUrl,
        [Parameter(Mandatory = $true)][string]$EnrollmentId
    )
    $origin = Get-FrpAllocatorOrigin -AllocatorUrl $AllocatorUrl
    $url = "$origin/enroll/challenge"
    $headers = @{ 'X-Enrollment-ID' = $EnrollmentId }
    $result = Invoke-FrpHttpsExchange -Method POST -Url $url -Headers $headers
    $code = [int]$result.StatusCode
    if ($code -eq 404) {
        return @{ Legacy = $true }
    }
    if ($code -ne 200) {
        $err = 'failed'
        try {
            $parsed = $result.Body | ConvertFrom-Json
            if ($parsed.error) { $err = [string]$parsed.error }
        } catch { }
        throw ("ERROR: allocator rejected enrollment challenge: {0}" -f $err)
    }
    $data = $result.Body | ConvertFrom-Json
    if (-not $data.challenge_id -or -not $data.nonce) {
        throw 'ERROR: enrollment challenge response is incomplete'
    }
    return @{
        Legacy       = $false
        ChallengeId  = [string]$data.challenge_id
        Nonce        = [string]$data.nonce
        ServerTime   = $(if ($null -ne $data.server_time) { [int64]$data.server_time } else { $null })
        ExpiresAt    = $(if ($null -ne $data.expires_at) { [int64]$data.expires_at } else { $null })
    }
}

function Invoke-FrpEnroll {
    param(
        [Parameter(Mandatory = $true)][string]$AllocatorUrl,
        [Parameter(Mandatory = $true)][string]$EnrollmentId,
        [Parameter(Mandatory = $true)][string]$EnrollmentSecret,
        [Parameter(Mandatory = $true)][string]$MachineId,
        [Parameter(Mandatory = $true)][string]$Hostname,
        [Parameter(Mandatory = $true)]$Services,
        [string]$PublicPem,
        $ManagementTimeOffsetSec = $null
    )
    $enrollServices = Get-FrpEnrollServiceList -Services $Services
    $payload = [ordered]@{
        machine_id = $MachineId
        hostname   = $Hostname
        services   = @($enrollServices)
    }
    if ($PublicPem) {
        $payload['mgmt_pubkey'] = $PublicPem
        $payload['mgmt_alg'] = 'ecdsa-p256-sha256'
    }
    # Seed build identity for fleet inventory (Linux enroll/mgmt reported_* parity).
    try {
        if (-not (Test-Path -LiteralPath (Get-FrpVersionPath))) {
            Write-FrpVersionFile | Out-Null
        }
    } catch {
        # Candidate without SHA must fail closed before talking to the allocator.
        throw
    }
    $reported = Get-FrpReportedBuildFields
    foreach ($k in $reported.Keys) {
        $payload[$k] = $reported[$k]
    }
    $body = Get-FrpCanonicalJson -Object $payload

    $offset = Test-FrpValidateOffset -Value $ManagementTimeOffsetSec
    if ($null -eq $offset) {
        $offset = Get-FrpManagementTimeOffsetFromState
    }

    $challenge = Invoke-FrpEnrollChallenge -AllocatorUrl $AllocatorUrl -EnrollmentId $EnrollmentId
    $useLegacy = [bool]$challenge.Legacy
    $clockRetry = 0
    $respText = $null
    $data = $null

    while ($true) {
        if (-not $useLegacy) {
            if ($null -ne $challenge.ServerTime) {
                $offset = Get-FrpOffsetFromServerTime -ServerTime $challenge.ServerTime
                Write-FrpMaybeSkewWarning -Offset $offset
            }
            $sig = Get-FrpEnrollmentChallengeSignature -Secret $EnrollmentSecret `
                -ChallengeId $challenge.ChallengeId -Nonce $challenge.Nonce -Body $body
            $headers = @{
                'X-Enrollment-ID'               = $EnrollmentId
                'X-Enrollment-Challenge-ID'     = $challenge.ChallengeId
                'X-Enrollment-Challenge-Nonce'  = $challenge.Nonce
                'X-Signature'                   = $sig
            }
            $exchange = Invoke-FrpHttpsExchange -Method POST -Url $AllocatorUrl -Body $body -Headers $headers
            $respText = $exchange.Body
            if ([int]$exchange.StatusCode -lt 200 -or [int]$exchange.StatusCode -ge 300) {
                $errMsg = "HTTP $($exchange.StatusCode)"
                try {
                    $errObj = $respText | ConvertFrom-Json
                    if ($errObj.error) { $errMsg = [string]$errObj.error }
                } catch { }
                throw ("ERROR: allocator rejected enrollment: {0}" -f $errMsg)
            }
            $data = $respText | ConvertFrom-Json
            if ($data.error) {
                throw ("ERROR: allocator rejected enrollment: {0}" -f [string]$data.error)
            }
            break
        }

        # Legacy X-Timestamp enrollment (servers without /enroll/challenge).
        $ts = Get-FrpManagementTimestamp -Offset $offset
        $sig = Get-FrpEnrollmentSignature -Secret $EnrollmentSecret -Timestamp ([string]$ts) -Body $body
        $headers = @{
            'X-Enrollment-ID' = $EnrollmentId
            'X-Timestamp'     = [string]$ts
            'X-Signature'     = $sig
        }
        $exchange = Invoke-FrpHttpsExchange -Method POST -Url $AllocatorUrl -Body $body -Headers $headers
        $respText = $exchange.Body
        try {
            $data = $respText | ConvertFrom-Json
        } catch {
            throw 'ERROR: allocator returned malformed JSON'
        }
        if (([int]$exchange.StatusCode -lt 200 -or [int]$exchange.StatusCode -ge 300) -or $data.error) {
            $errMsg = if ($data.error) { [string]$data.error } else { "HTTP $($exchange.StatusCode)" }
            if ((Test-FrpIsClockSkewError -Message $errMsg) -and $clockRetry -eq 0) {
                try {
                    $offset = Sync-FrpManagementOffset -AllocatorUrl $AllocatorUrl
                } catch {
                    # Fall through to reject if /time is unavailable.
                }
                $clockRetry = 1
                continue
            }
            throw ("ERROR: allocator rejected enrollment: {0}" -f $errMsg)
        }
        break
    }

    # Verify response HMAC over payload without response_hmac field
    $received = [string]$data.response_hmac
    $copy = ConvertTo-FrpPlainObject $data
    if ($copy.ContainsKey('response_hmac')) { $copy.Remove('response_hmac') }
    $canonical = Get-FrpCanonicalJson -Object $copy
    $expected = Get-FrpHmacHex -Secret $EnrollmentSecret -Message $canonical
    if (-not $received -or -not (Test-FrpFixedTimeEquals -Left $received -Right $expected -IgnoreCase)) {
        throw 'ERROR: allocator response HMAC verification failed'
    }
    if (-not $data.token_ciphertext) {
        throw 'ERROR: allocator response is missing token_ciphertext'
    }
    $transport = [string]$data.frp_transport
    if (-not $transport) { $transport = 'tcp' }
    $transport = $transport.Trim().ToLowerInvariant()
    if ($transport -ne 'tcp' -and $transport -ne 'wss') {
        throw 'ERROR: allocator returned an unsupported FRP transport'
    }

    $serverTime = $null
    if ($null -ne $data.server_time) {
        try { $serverTime = [int64]$data.server_time } catch { $serverTime = $null }
    }
    if ($null -ne $serverTime) {
        $offset = Get-FrpOffsetFromServerTime -ServerTime $serverTime
        Write-FrpMaybeSkewWarning -Offset $offset
    }

    return @{
        FrpServer                 = [string]$data.frp_server
        FrpServerPort             = [int]$data.frp_server_port
        FrpTransport              = $transport
        TokenCiphertext           = [string]$data.token_ciphertext
        Services                  = @($data.services)
        MgmtStatus                = [string]$data.mgmt_status
        ServerTime                = $serverTime
        ManagementTimeOffsetSec   = $offset
    }
}

function Get-FrpDefaultServices {
    param(
        [string]$Platform = 'windows',
        [string]$ServicesJson,
        [string]$SshUser
    )
    if ($ServicesJson) {
        $parsed = $ServicesJson | ConvertFrom-Json
        return @($parsed)
    }
    if ($Platform -eq 'windows') {
        return @(
            [pscustomobject]@{
                id         = 'rdp'
                name       = 'RDP'
                preset     = 'rdp'
                protocol   = 'tcp'
                local_ip   = '127.0.0.1'
                local_port = 3389
                enabled    = $true
            }
        )
    }
    if ([string]::IsNullOrWhiteSpace($SshUser)) {
        throw 'ERROR: non-windows default SSH service requires explicit -SshUser / ssh_user (no default root)'
    }
    $ssh = [pscustomobject]@{
        id         = 'ssh'
        name       = 'SSH'
        preset     = 'ssh'
        protocol   = 'tcp'
        local_ip   = '127.0.0.1'
        local_port = 22
        enabled    = $true
        ssh_user   = $SshUser
    }
    return @($ssh)
}

function Complete-FrpZeroTouchPostEnroll {
    param(
        [switch]$SkipStart,
        [switch]$SkipDownload,
        [object]$Services
    )
    $enabledCount = Get-FrpEnabledServiceCount -Services $Services
    if (-not $Services) {
        try {
            $st = Read-FrpClientState
            $Services = $st.services
            $enabledCount = Get-FrpEnabledServiceCount -Services $Services
            if ($st.management_only -eq $true) { $enabledCount = 0 }
        } catch { }
    }

    Set-FrpInstallStatus -Status 'enrolled_incomplete'

    if ($env:FRP_WINDOWS_FAIL_AFTER_ENROLL -eq '1') {
        throw 'ERROR: simulated failure after enroll (FRP_WINDOWS_FAIL_AFTER_ENROLL=1)'
    }

    if (-not $SkipDownload) {
        if ($env:FRP_WINDOWS_SKIP_DOWNLOAD -eq '1') {
            Write-Host 'Skipping FRP download (FRP_WINDOWS_SKIP_DOWNLOAD=1)'
        } else {
            Install-FrpWindowsBinary | Out-Null
        }
    }

    # Install managed project modules/tools into ProgramData from package windows/.
    if ($script:FrpWindowsSrcRoot) {
        Install-FrpWindowsProjectTree -SourceWindowsRoot $script:FrpWindowsSrcRoot | Out-Null
    }
    # Persist channel/ref/bundle identity even when FRP download was skipped.
    try {
        Write-FrpVersionFile | Out-Null
    } catch {
        throw
    }

    if ($enabledCount -le 0) {
        Write-Host 'Management-only enrollment: no public services; skipping frpc start.'
        Set-FrpInstallStatus -Status 'management_only'
        Write-Host ''
        Write-Host 'Enrollment complete (management-only). Use frp-client info for details.'
        Write-Host 'ENROLL ONCE / RUN MANY TIMES: later starts use existing identity and ports.'
        return 0
    }

    if ($env:FRP_WINDOWS_FAIL_BEFORE_START -eq '1') {
        throw 'ERROR: simulated failure before start (FRP_WINDOWS_FAIL_BEFORE_START=1)'
    }

    if (-not $SkipStart) {
        Start-FrpClient | Out-Null
    }

    Set-FrpInstallStatus -Status 'installed'
    Write-Host ''
    Write-Host 'Enrollment complete. Use frp-client info for connection details.'
    Write-Host 'ENROLL ONCE / RUN MANY TIMES: later starts use existing identity and ports.'
    return 0
}

function Invoke-FrpZeroTouch {
    param(
        [Parameter(Mandatory = $true)][string]$AllocatorUrl,
        [Parameter(Mandatory = $true)][string]$CaSha256,
        [Parameter(Mandatory = $true)][string]$BootstrapTicket,
        [string]$Platform = 'windows',
        [string]$ServicesJson,
        [string]$SshUser,
        [string]$Hostname,
        [switch]$SkipStart,
        [switch]$SkipDownload,
        [switch]$UseLocalDefaults
    )

    try {
        return Invoke-FrpWithMutationLock -Script {
            if (Test-FrpIsEnrolled) {
                if (Test-FrpCanResumeInstall) {
                    Write-Host 'Resuming incomplete install (same identity and ports; ticket not re-redeemed)...'
                    return (Complete-FrpZeroTouchPostEnroll -SkipStart:$SkipStart -SkipDownload:$SkipDownload)
                }
                if (Test-FrpIsInstallComplete) {
                    Write-Host 'ERROR: this machine is already enrolled.'
                    Write-Host 'ENROLL ONCE: refuse re-ticket path. Use: frp-client start'
                    Write-Host 'To replace this install, uninstall locally first (server reservations are preserved).'
                    return 2
                }
                # Legacy enrolled installs without install_status: treat as complete / refuse re-ticket
                Write-Host 'ERROR: this machine is already enrolled.'
                Write-Host 'ENROLL ONCE: refuse re-ticket path. Use: frp-client start'
                Write-Host 'To replace this install, uninstall locally first (server reservations are preserved).'
                return 2
            }

            if ($AllocatorUrl -notmatch '^https://') {
                throw 'ERROR: plain HTTP allocator URL is not supported; HTTPS is required'
            }

            Initialize-FrpDirectories

            $resumeRecovery = $false
            $recovery = $null
            if (Test-FrpHasEnrollRecovery) {
                try {
                    $resumeRecovery = Test-FrpCanResumeFromRecovery
                    if ($resumeRecovery) {
                        $recovery = Read-FrpEnrollRecovery
                    }
                } catch {
                    throw ("ERROR: enroll recovery journal is unusable; refuse to continue: {0}" -f $_.Exception.Message)
                }
            }

            if (-not $resumeRecovery) {
                if ([string]::IsNullOrWhiteSpace($CaSha256)) {
                    throw 'ERROR: zero-touch setup requires FRP_ALLOCATOR_CA_SHA256 / -CaSha256'
                }
                if ([string]::IsNullOrWhiteSpace($BootstrapTicket)) {
                    throw 'ERROR: bootstrap ticket is missing'
                }
            } else {
                if ([string]::IsNullOrWhiteSpace($CaSha256) -and $recovery.CaSha256) {
                    $CaSha256 = [string]$recovery.CaSha256
                }
                if ([string]::IsNullOrWhiteSpace($CaSha256)) {
                    throw 'ERROR: zero-touch resume requires FRP_ALLOCATOR_CA_SHA256 / -CaSha256'
                }
            }

            Write-Host 'Bootstrapping allocator CA (pin verify)...'
            Get-FrpCaCertificate -AllocatorUrl $AllocatorUrl -ExpectedSha256 $CaSha256 | Out-Null

            $machineId = Get-FrpOrCreateClientId
            if (-not $Hostname) {
                $Hostname = $env:COMPUTERNAME
                if (-not $Hostname) { $Hostname = [System.Net.Dns]::GetHostName() }
            }
            $Hostname = ([string]$Hostname).Trim()

            $enrollmentId = $null
            $enrollmentSecret = $null
            $services = @()

            if ($resumeRecovery) {
                if ($recovery.MachineId -ne $machineId) {
                    throw 'ERROR: enroll recovery journal is for a different machine; refuse to continue'
                }
                Write-Host 'Resuming incomplete zero-touch enrollment (same identity and ports; ticket not re-redeemed)...'
                $enrollmentId = $recovery.EnrollmentId
                $enrollmentSecret = $recovery.EnrollmentSecret
                $services = @($recovery.Services)
                # Ensure management identity from the interrupted attempt is reused.
                if (-not (Test-Path -LiteralPath (Get-FrpIdentityKeyPath)) -and
                    -not (Test-Path -LiteralPath (Get-FrpIdentityPlainKeyPath))) {
                    throw 'ERROR: management identity missing for recovery resume; refuse to continue'
                }
            } else {
                Write-Host 'Redeeming bootstrap ticket...'
                $redeem = Invoke-FrpBootstrapRedeem -AllocatorUrl $AllocatorUrl -Ticket $BootstrapTicket `
                    -MachineId $machineId -Hostname $Hostname

                # Ticket redeem is authoritative. Empty services = management-only.
                # Get-FrpDefaultServices is only for explicit local guided UX.
                $services = @($redeem.Services)
                if ($UseLocalDefaults) {
                    $services = Get-FrpDefaultServices -Platform $Platform -ServicesJson $ServicesJson -SshUser $SshUser
                } elseif (-not [string]::IsNullOrWhiteSpace($ServicesJson) -and @($services).Count -eq 0) {
                    $services = Get-FrpDefaultServices -Platform $Platform -ServicesJson $ServicesJson -SshUser $SshUser
                }
                # else: keep ticket services as-is (including empty)

                Write-Host 'Generating management identity...'
                $id = New-FrpEcdsaIdentity
                Save-FrpIdentityKey -PrivatePem $id.PrivatePem | Out-Null
                Save-FrpIdentityPublic -PublicPem $id.PublicPem | Out-Null

                $enrollmentId = $redeem.EnrollmentId
                $enrollmentSecret = $redeem.EnrollmentSecret

                # Persist recovery journal BEFORE /enroll so a post-enroll crash can resume
                # without a second bootstrap ticket. Never stores the raw bootstrap ticket.
                Save-FrpEnrollRecovery -AllocatorUrl $AllocatorUrl -MachineId $machineId `
                    -Hostname $Hostname -EnrollmentId $enrollmentId -EnrollmentSecret $enrollmentSecret `
                    -Services $services -CaSha256 $CaSha256 | Out-Null
            }

            $pubPem = $null
            if (Test-Path -LiteralPath (Get-FrpIdentityPubPath)) {
                $pubPem = [System.IO.File]::ReadAllText((Get-FrpIdentityPubPath))
            }

            Write-Host 'Enrolling with allocator...'
            $enroll = Invoke-FrpEnroll -AllocatorUrl $AllocatorUrl `
                -EnrollmentId $enrollmentId -EnrollmentSecret $enrollmentSecret `
                -MachineId $machineId -Hostname $Hostname -Services $services -PublicPem $pubPem

            # Crash-window simulation: after successful enroll, before durable client-state commit.
            if ($env:FRP_WINDOWS_FAIL_AFTER_ENROLL -eq '1') {
                throw 'ERROR: simulated failure after enroll (FRP_WINDOWS_FAIL_AFTER_ENROLL=1)'
            }

            $token = Unprotect-FrpTokenPbkdf2 -Ciphertext $enroll.TokenCiphertext -Secret $enrollmentSecret
            $mac = Get-FrpDerivedMacKey -Secret $enrollmentSecret -MachineId $machineId
            Save-FrpIdentityMac -MacKeyHex $mac | Out-Null

            $merged = Merge-FrpAllocatedPorts -LocalServices $services -AllocatedList $enroll.Services
            $hostId = ($machineId.Substring(0, [Math]::Min(12, $machineId.Length)))

            $enabledCount = Get-FrpEnabledServiceCount -Services $merged
            $initialStatus = $(if ($enabledCount -le 0) { 'enrolled_incomplete' } else { 'enrolled_incomplete' })

            Save-FrpClientState -AllocatorUrl $AllocatorUrl -FrpServer $enroll.FrpServer `
                -FrpServerPort $enroll.FrpServerPort -Hostname $Hostname -MachineId $machineId `
                -HostId $hostId -Services $merged -Transport $enroll.FrpTransport `
                -InstallStatus $initialStatus `
                -ManagementTimeOffsetSec $enroll.ManagementTimeOffsetSec | Out-Null

            New-FrpClientToml -ServerAddr $enroll.FrpServer -ServerPort $enroll.FrpServerPort `
                -Token $token -HostId $hostId -Services $merged -Transport $enroll.FrpTransport `
                -MachineId $machineId | Out-Null

            # Wipe plaintext token from local variable ASAP
            $token = $null
            $enrollmentSecret = $null

            $rc = Complete-FrpZeroTouchPostEnroll -SkipStart:$SkipStart -SkipDownload:$SkipDownload -Services $merged
            if ($rc -eq 0) {
                Remove-FrpEnrollRecovery
            }
            return $rc
        }
    } finally {
        Clear-FrpSecretEnv
    }
}
