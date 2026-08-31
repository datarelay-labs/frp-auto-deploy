# test-clock-skew.ps1 — application-layer clock-skew tolerance (Windows client)
#
# NOTE: TLS multi-year OS clock skew remains a platform limitation. These tests
# exercise FRP management timestamp offset correction only; they never change
# the OS clock / NTP and never disable TLS verification. Extremely large OS
# skew (years) can still break TLS certificate validity windows independently
# of FRP's MAX_CLOCK_SKEW=300 application window.

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')

try {
    Assert-FrpEqual 300 $script:FrpMaxClockSkewSec 'MAX_CLOCK_SKEW remains 300'

    $skews = @(0, 600, -600, 3600, -3600, 86400, -86400)  # 0m, ±10m, +/-1h, +/-24h
    $labels = @('0m', '+10m', '-10m', '+1h', '-1h', '+24h', '-24h')
    for ($i = 0; $i -lt $skews.Count; $i++) {
        $skew = [int64]$skews[$i]
        $label = $labels[$i]
        $localNow = [int64]1700000000
        $serverNow = $localNow  # "true" server time
        # Simulate local clock = server + skew (positive skew = local ahead)
        $fakeLocal = $serverNow + $skew
        $offset = Get-FrpOffsetFromServerTime -ServerTime $serverNow -LocalTime $fakeLocal
        Assert-FrpEqual (-$skew) $offset ("offset calc $label")
        $corrected = Get-FrpManagementTimestamp -Offset $offset -Now $fakeLocal
        Assert-FrpEqual $serverNow $corrected ("corrected ts $label")
        # Uncorrected local timestamp would fall outside MAX_CLOCK_SKEW when |skew| > 300
        if ([Math]::Abs($skew) -gt 300) {
            Assert-FrpTrue ([Math]::Abs($fakeLocal - $serverNow) -gt $script:FrpMaxClockSkewSec) `
                ("uncorrected $label exceeds MAX_CLOCK_SKEW")
        }
        Write-FrpTestPass ("CLOCK_SKEW_OFFSET_$label")
    }

    Assert-FrpTrue (Test-FrpShouldWarnOffset -Offset 400) 'warn above 300'
    Assert-FrpTrue (-not (Test-FrpShouldWarnOffset -Offset 2)) 'no warn small'
    $warn = Format-FrpSkewWarning -Offset 3600
    Assert-FrpTrue ($warn -match 'operating-system clock was not changed') 'warn never implies OS clock change'
    Assert-FrpTrue ($warn -match 'server-relative time') 'warn mentions server-relative'

    Assert-FrpTrue (Test-FrpIsClockSkewError -Message 'request timestamp outside allowed window') 'skew detect'
    Assert-FrpTrue (Test-FrpIsClockSkewError -Message 'invalid timestamp') 'invalid ts detect'
    Assert-FrpTrue (-not (Test-FrpIsClockSkewError -Message 'invalid signature')) 'non-skew'

    # Challenge signature format (clock-independent)
    $secret = 'enroll-secret-deadbeef0123456789'
    $body = '{"machine_id":"m1"}'
    $cid = 'aabbccddeeff0011'
    $nonce = ('ab' * 32)
    $chalSig = Get-FrpEnrollmentChallengeSignature -Secret $secret -ChallengeId $cid -Nonce $nonce -Body $body
    $expected = Get-FrpHmacHex -Secret $secret -Message ("${cid}`n${nonce}`n${body}")
    Assert-FrpEqual $expected $chalSig 'challenge signature'
    $legacySig = Get-FrpEnrollmentSignature -Secret $secret -Timestamp '1700000000' -Body $body
    Assert-FrpTrue ($chalSig -ne $legacySig) 'challenge != legacy signature'

    # Persist management_time_offset_sec in client state
    $mid = Get-FrpOrCreateClientId
    Save-FrpClientState -AllocatorUrl 'https://example.test/enroll' -FrpServer 'example.test' `
        -FrpServerPort 7000 -Hostname 'skew-host' -MachineId $mid -HostId 'skew' `
        -Services @(@{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; local_ip = '127.0.0.1'; local_port = 3389; remote_port = 1; enabled = $true }) `
        -Transport 'tcp' -ManagementTimeOffsetSec (-3600) | Out-Null
    $loaded = Get-FrpManagementTimeOffsetFromState
    Assert-FrpEqual (-3600) $loaded 'offset stored in state'
    $merged = Merge-FrpManagementTimeOffset -StatePath (Get-FrpStatePath) -Offset (-3500) -Force
    Assert-FrpTrue $merged 'force merge offset'
    Assert-FrpEqual (-3500) (Get-FrpManagementTimeOffsetFromState) 'offset refreshed'

    # Legacy fallback: challenge 404 → legacy timestamp path (mocked HTTPS exchange)
    $script:FrpClockSkewMockMode = 'challenge-404'
    $script:FrpClockSkewMockCalls = New-Object System.Collections.ArrayList
    function Invoke-FrpHttpsExchange {
        param(
            [Parameter(Mandatory = $true)][string]$Method,
            [Parameter(Mandatory = $true)][string]$Url,
            [string]$Body,
            [hashtable]$Headers,
            [string]$CaPath,
            [int]$TimeoutSec = 30
        )
        [void]$script:FrpClockSkewMockCalls.Add(@{ Method = $Method; Url = $Url; Headers = $Headers; Body = $Body })
        if ($Url -match '/enroll/challenge') {
            return @{ StatusCode = 404; Body = '{"error":"not found"}' }
        }
        if ($Url -match '/time') {
            return @{ StatusCode = 200; Body = ('{{"server_time":{0}}}' -f ([int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))) }
        }
        # Legacy enroll: verify X-Timestamp present, challenge headers absent
        Assert-FrpTrue ($Headers.ContainsKey('X-Timestamp')) 'legacy uses X-Timestamp'
        Assert-FrpTrue (-not $Headers.ContainsKey('X-Enrollment-Challenge-ID')) 'no challenge id on legacy'
        $secret = 'enroll-secret-deadbeef0123456789'
        # Build a minimal valid-looking HMAC response the enroll verifier accepts
        $payload = [ordered]@{
            frp_server      = 'example.test'
            frp_server_port = 7000
            frp_transport   = 'tcp'
            services        = @(@{ id = 'rdp'; remote_port = 18200 })
            token_ciphertext = (Protect-FrpTokenPbkdf2 -Token 'tok' -Secret $secret)
            server_time     = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        }
        $canon = Get-FrpCanonicalJson -Object $payload
        $payload['response_hmac'] = Get-FrpHmacHex -Secret $secret -Message $canon
        return @{ StatusCode = 200; Body = (Get-FrpCanonicalJson -Object $payload) }
    }

    $enroll = Invoke-FrpEnroll -AllocatorUrl 'https://example.test/enroll' `
        -EnrollmentId 'abcdef0123456789' -EnrollmentSecret 'enroll-secret-deadbeef0123456789' `
        -MachineId 'machine-skew-test' -Hostname 'skew-host' `
        -Services @(@{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; protocol = 'tcp'; local_ip = '127.0.0.1'; local_port = 3389 })
    Assert-FrpEqual 'example.test' $enroll.FrpServer 'legacy fallback enroll'
    Assert-FrpTrue ($null -ne $enroll.ManagementTimeOffsetSec -or $null -ne $enroll.ServerTime) 'offset from response'
    Write-FrpTestPass 'LEGACY_CHALLENGE_404_FALLBACK'

    # Challenge path with application-layer skew (mocked): challenge succeeds regardless of local skew
    $script:FrpClockSkewMockMode = 'challenge-ok'
    function Invoke-FrpHttpsExchange {
        param(
            [Parameter(Mandatory = $true)][string]$Method,
            [Parameter(Mandatory = $true)][string]$Url,
            [string]$Body,
            [hashtable]$Headers,
            [string]$CaPath,
            [int]$TimeoutSec = 30
        )
        if ($Url -match '/enroll/challenge') {
            $now = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
            return @{
                StatusCode = 200
                Body       = (Get-FrpCanonicalJson -Object ([ordered]@{
                            challenge_id = '1122334455667788'
                            nonce        = ('cd' * 32)
                            server_time  = $now
                            expires_at   = ($now + 120)
                        }))
            }
        }
        Assert-FrpTrue ($Headers.ContainsKey('X-Enrollment-Challenge-ID')) 'challenge id header'
        Assert-FrpTrue ($Headers.ContainsKey('X-Enrollment-Challenge-Nonce')) 'challenge nonce header'
        Assert-FrpTrue (-not $Headers.ContainsKey('X-Timestamp')) 'challenge path omits X-Timestamp'
        $secret = 'enroll-secret-deadbeef0123456789'
        $payload = [ordered]@{
            frp_server       = 'example.test'
            frp_server_port  = 7000
            frp_transport    = 'tcp'
            services         = @(@{ id = 'rdp'; remote_port = 18201 })
            token_ciphertext = (Protect-FrpTokenPbkdf2 -Token 'tok2' -Secret $secret)
            server_time      = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        }
        $canon = Get-FrpCanonicalJson -Object $payload
        $payload['response_hmac'] = Get-FrpHmacHex -Secret $secret -Message $canon
        return @{ StatusCode = 200; Body = (Get-FrpCanonicalJson -Object $payload) }
    }

    foreach ($skew in $skews) {
        # Offset simulates skewed local clock relative to server_time in challenge
        $enroll2 = Invoke-FrpEnroll -AllocatorUrl 'https://example.test/enroll' `
            -EnrollmentId 'abcdef0123456789' -EnrollmentSecret 'enroll-secret-deadbeef0123456789' `
            -MachineId 'machine-skew-chal' -Hostname 'skew-host' `
            -Services @(@{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; protocol = 'tcp'; local_ip = '127.0.0.1'; local_port = 3389 }) `
            -ManagementTimeOffsetSec (-1 * [int64]$skew)
        Assert-FrpEqual 'example.test' $enroll2.FrpServer ("challenge enroll skew=$skew")
    }
    Write-FrpTestPass 'CHALLENGE_SKEW_ENROLLMENT_ALL_OFFSETS'

    # Clock-skew recovery: legacy path retries once after /time sync
    $script:FrpLegacyFailOnce = $true
    $script:FrpLegacyAttempts = 0
    function Invoke-FrpHttpsExchange {
        param(
            [Parameter(Mandatory = $true)][string]$Method,
            [Parameter(Mandatory = $true)][string]$Url,
            [string]$Body,
            [hashtable]$Headers,
            [string]$CaPath,
            [int]$TimeoutSec = 30
        )
        if ($Url -match '/enroll/challenge') {
            return @{ StatusCode = 404; Body = '{"error":"not found"}' }
        }
        if ($Url -match '/time$') {
            return @{ StatusCode = 200; Body = ('{{"server_time":{0}}}' -f ([int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))) }
        }
        $script:FrpLegacyAttempts++
        if ($script:FrpLegacyFailOnce) {
            $script:FrpLegacyFailOnce = $false
            return @{ StatusCode = 403; Body = '{"error":"request timestamp outside allowed window","error_class":"AUTH_FAILED"}' }
        }
        $secret = 'enroll-secret-deadbeef0123456789'
        $payload = [ordered]@{
            frp_server       = 'example.test'
            frp_server_port  = 7000
            frp_transport    = 'tcp'
            services         = @(@{ id = 'rdp'; remote_port = 18202 })
            token_ciphertext = (Protect-FrpTokenPbkdf2 -Token 'tok3' -Secret $secret)
            server_time      = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        }
        $canon = Get-FrpCanonicalJson -Object $payload
        $payload['response_hmac'] = Get-FrpHmacHex -Secret $secret -Message $canon
        return @{ StatusCode = 200; Body = (Get-FrpCanonicalJson -Object $payload) }
    }
    $enroll3 = Invoke-FrpEnroll -AllocatorUrl 'https://example.test/enroll' `
        -EnrollmentId 'abcdef0123456789' -EnrollmentSecret 'enroll-secret-deadbeef0123456789' `
        -MachineId 'machine-skew-retry' -Hostname 'skew-host' `
        -Services @(@{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; protocol = 'tcp'; local_ip = '127.0.0.1'; local_port = 3389 })
    Assert-FrpEqual 2 $script:FrpLegacyAttempts 'exactly one recovery retry'
    Assert-FrpEqual 'example.test' $enroll3.FrpServer 'recovered after skew'
    Write-FrpTestPass 'CLOCK_SKEW_MAX_ONE_RETRY'

    Write-Host 'NOTE: TLS multi-year OS clock skew limitation remains (cert validity independent of MAX_CLOCK_SKEW=300).'
    Write-FrpTestPass 'test-clock-skew'
} finally {
    Remove-FrpWindowsTestRoot
}
