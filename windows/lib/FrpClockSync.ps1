# FrpClockSync.ps1 — server-relative management time (application-layer; never changes OS clock).

if ((Test-Path variable:script:FrpClockSyncLoaded) -and $script:FrpClockSyncLoaded) { return }
$script:FrpClockSyncLoaded = $true

$script:FrpMaxOffsetSec = 86400 * 366
$script:FrpWarnOffsetSec = 300
$script:FrpMinWriteDeltaSec = 2
# Server MAX_CLOCK_SKEW is 300s; do not enlarge client-side tolerance beyond that window.
$script:FrpMaxClockSkewSec = 300

function Test-FrpValidateOffset {
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        $offset = [int64]$Value
    } catch {
        return $null
    }
    if ([Math]::Abs($offset) -gt $script:FrpMaxOffsetSec) { return $null }
    return $offset
}

function Get-FrpUnixNow {
    return [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
}

function Get-FrpManagementTimestamp {
    <#
    .SYNOPSIS
      Unix timestamp for management signatures using optional stored offset.
      Does not modify the OS clock.
    #>
    param(
        $Offset,
        [long]$Now = -1
    )
    if ($Now -lt 0) { $Now = Get-FrpUnixNow }
    $off = Test-FrpValidateOffset -Value $Offset
    if ($null -eq $off) { return $Now }
    return ($Now + [int64]$off)
}

function Get-FrpOffsetFromServerTime {
    param(
        [Parameter(Mandatory = $true)]$ServerTime,
        [long]$LocalTime = -1
    )
    if ($LocalTime -lt 0) { $LocalTime = Get-FrpUnixNow }
    try {
        $st = [int64]$ServerTime
    } catch {
        return $null
    }
    return (Test-FrpValidateOffset -Value ($st - $LocalTime))
}

function Test-FrpShouldWarnOffset {
    param($Offset)
    $off = Test-FrpValidateOffset -Value $Offset
    return ($null -ne $off -and [Math]::Abs([int64]$off) -gt $script:FrpWarnOffsetSec)
}

function Format-FrpSkewWarning {
    param($Offset)
    $off = Test-FrpValidateOffset -Value $Offset
    if ($null -eq $off) { return '' }
    $abs = [Math]::Abs([int64]$off)
    $minutes = [int]($abs / 60)
    if ($minutes -ge 60) {
        $approx = '{0} hour(s)' -f ([int]($abs / 3600))
    } else {
        $approx = '{0} minute(s)' -f [Math]::Max(1, $minutes)
    }
    $direction = if ([int64]$off -gt 0) { 'ahead of' } else { 'behind' }
    return @(
        "WARNING: Local system clock differs from the FRP server by approximately $approx."
        "The local clock is $direction the server."
        'FRP management requests will use server-relative time.'
        'The operating-system clock was not changed.'
    ) -join "`n"
}

function Write-FrpMaybeSkewWarning {
    param($Offset)
    if (-not (Test-FrpShouldWarnOffset -Offset $Offset)) { return }
    $text = Format-FrpSkewWarning -Offset $Offset
    if ($text) { Write-Host $text }
}

function Get-FrpManagementTimeOffsetFromState {
    param([string]$StatePath)
    if (-not $StatePath) { $StatePath = Get-FrpStatePath }
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $data = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not ($data.PSObject.Properties.Name -contains 'management_time_offset_sec')) {
        return $null
    }
    return (Test-FrpValidateOffset -Value $data.management_time_offset_sec)
}

function Merge-FrpManagementTimeOffset {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        $Offset,
        [switch]$Force
    )
    $off = Test-FrpValidateOffset -Value $Offset
    if ($null -eq $off) { return $false }
    if (-not (Test-Path -LiteralPath $StatePath)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $StatePath -Raw
        $data = $raw | ConvertFrom-Json
    } catch {
        return $false
    }
    $ht = ConvertTo-FrpPlainObject $data
    $current = $null
    if ($ht.ContainsKey('management_time_offset_sec')) {
        $current = Test-FrpValidateOffset -Value $ht['management_time_offset_sec']
    }
    if (-not $Force -and $null -ne $current -and [Math]::Abs([int64]$current - [int64]$off) -le $script:FrpMinWriteDeltaSec) {
        return $false
    }
    $ht['management_time_offset_sec'] = [int64]$off
    $pretty = ($ht | ConvertTo-Json -Depth 8)
    $tmp = "$StatePath.tmp"
    [System.IO.File]::WriteAllText($tmp, $pretty + "`n")
    if (Get-Command Restrict-FrpFileAcl -ErrorAction SilentlyContinue) {
        Restrict-FrpFileAcl -Path $tmp
    }
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
    if (Get-Command Restrict-FrpFileAcl -ErrorAction SilentlyContinue) {
        Restrict-FrpFileAcl -Path $StatePath
    }
    return $true
}

function Test-FrpIsClockSkewError {
    param([string]$Message)
    $text = ([string]$Message).ToLowerInvariant()
    return ($text -match 'timestamp outside allowed window' -or $text -match 'invalid timestamp')
}

function Invoke-FrpFetchServerTime {
    param(
        [Parameter(Mandatory = $true)][string]$AllocatorUrl
    )
    $origin = Get-FrpAllocatorOrigin -AllocatorUrl $AllocatorUrl
    $result = Invoke-FrpHttpsExchange -Method GET -Url "$origin/time"
    if ([int]$result.StatusCode -ne 200) {
        throw ("ERROR: GET /time failed (HTTP {0})" -f $result.StatusCode)
    }
    $data = $result.Body | ConvertFrom-Json
    if ($null -eq $data.server_time) {
        throw 'ERROR: /time response missing server_time'
    }
    return [int64]$data.server_time
}

function Sync-FrpManagementOffset {
    <#
    .SYNOPSIS
      Refresh management_time_offset_sec from GET /time. Never changes OS clock/NTP.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AllocatorUrl,
        [string]$StatePath
    )
    if (-not $StatePath) { $StatePath = Get-FrpStatePath }
    $serverTime = Invoke-FrpFetchServerTime -AllocatorUrl $AllocatorUrl
    $localNow = Get-FrpUnixNow
    $offset = Get-FrpOffsetFromServerTime -ServerTime $serverTime -LocalTime $localNow
    if ($null -eq $offset) {
        throw 'ERROR: computed management time offset is out of range'
    }
    if (Test-Path -LiteralPath $StatePath) {
        [void](Merge-FrpManagementTimeOffset -StatePath $StatePath -Offset $offset -Force)
    }
    return [int64]$offset
}
