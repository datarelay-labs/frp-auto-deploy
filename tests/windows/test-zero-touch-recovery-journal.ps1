# test-zero-touch-recovery-journal.ps1 — crash before durable normal state; resume via recovery journal
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')

try {
    $script:FrpRedeemCalls = 0
    $script:FrpEnrollCalls = 0
    $script:FrpMockEnrollSecret = 'enroll-secret-deadbeef0123456789abcdef'
    $script:FrpMockEnrollId = 'aabbccddeeff0011'
    $script:FrpMockServices = @(
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

    function Get-FrpCaCertificate {
        param(
            [Parameter(Mandatory = $true)][string]$AllocatorUrl,
            [Parameter(Mandatory = $true)][string]$ExpectedSha256,
            [string]$DestinationPath
        )
        if (-not $DestinationPath) { $DestinationPath = Get-FrpAllocatorCaPath }
        Initialize-FrpDirectories
        $dir = Split-Path -Parent $DestinationPath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # Minimal PEM placeholder; pin verify skipped by mock.
        [System.IO.File]::WriteAllText($DestinationPath, "-----BEGIN CERTIFICATE-----`nMIIB`n-----END CERTIFICATE-----`n")
        return $DestinationPath
    }

    function Invoke-FrpBootstrapRedeem {
        param(
            [Parameter(Mandatory = $true)][string]$AllocatorUrl,
            [Parameter(Mandatory = $true)][string]$Ticket,
            [Parameter(Mandatory = $true)][string]$MachineId,
            [Parameter(Mandatory = $true)][string]$Hostname
        )
        $script:FrpRedeemCalls++
        if ($script:FrpRedeemCalls -gt 1) {
            throw 'ERROR: bootstrap ticket already used [BOOTSTRAP_TICKET_USED]'
        }
        return @{
            EnrollmentId     = $script:FrpMockEnrollId
            EnrollmentSecret = $script:FrpMockEnrollSecret
            Services         = $script:FrpMockServices
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
        $script:FrpEnrollCalls++
        $ct = Protect-FrpTokenPbkdf2 -Token 'tok-recover' -Secret $EnrollmentSecret
        return @{
            FrpServer               = 'example.test'
            FrpServerPort           = 7000
            FrpTransport            = 'tcp'
            TokenCiphertext         = $ct
            Services                = @(@{ id = 'rdp'; remote_port = 60042 })
            MgmtStatus              = 'enrolled'
            ServerTime              = $null
            ManagementTimeOffsetSec = 0
        }
    }

    # --- Unit: journal round-trip + refuse ticket field ---
    $mid = Get-FrpOrCreateClientId
    $id = New-FrpEcdsaIdentity
    Save-FrpIdentityKey -PrivatePem $id.PrivatePem | Out-Null
    Save-FrpIdentityPublic -PublicPem $id.PublicPem | Out-Null
    Save-FrpEnrollRecovery -AllocatorUrl 'https://example.test/enroll' -MachineId $mid `
        -Hostname 'win-recover' -EnrollmentId $script:FrpMockEnrollId `
        -EnrollmentSecret $script:FrpMockEnrollSecret `
        -Services $script:FrpMockServices -CaSha256 ('a' * 64) | Out-Null
    Assert-FrpTrue (Test-FrpHasEnrollRecovery) 'journal present'
    $loaded = Read-FrpEnrollRecovery
    Assert-FrpEqual $script:FrpMockEnrollId $loaded.EnrollmentId 'enroll id round-trip'
    Assert-FrpEqual $script:FrpMockEnrollSecret $loaded.EnrollmentSecret 'enroll secret round-trip'
    Assert-FrpEqual $mid $loaded.MachineId 'machine id round-trip'
    Assert-FrpTrue (Test-FrpCanResumeFromRecovery) 'can resume from recovery'
    Remove-FrpEnrollRecovery
    Assert-FrpTrue (-not (Test-FrpHasEnrollRecovery)) 'journal removed'
    Write-FrpTestPass 'JOURNAL_ROUNDTRIP'

    # Corrupt journal fail-closed
    $plain = Get-FrpEnrollRecoveryPlainPath
    [System.IO.File]::WriteAllText($plain, '{not-json')
    Restrict-FrpFileAcl -Path $plain
    $threwCorrupt = $false
    try { [void](Read-FrpEnrollRecovery) } catch { $threwCorrupt = $true }
    Assert-FrpTrue $threwCorrupt 'corrupt journal throws'
    $threwResume = $false
    try { [void](Test-FrpCanResumeFromRecovery) } catch { $threwResume = $true }
    Assert-FrpTrue $threwResume 'corrupt journal resume fail-closed'
    Remove-FrpEnrollRecovery
    Write-FrpTestPass 'CORRUPT_JOURNAL_FAIL_CLOSED'

    # --- Crash window before durable normal state (not pre-seeded enrolled_incomplete) ---
    Remove-FrpWindowsTestRoot
    $env:FRP_WINDOWS_ROOT = Join-Path ([System.IO.Path]::GetTempPath()) ('frp-win-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $env:FRP_WINDOWS_ROOT -Force | Out-Null
    Initialize-FrpDirectories
    $script:FrpRedeemCalls = 0
    $script:FrpEnrollCalls = 0

    $env:FRP_WINDOWS_FAIL_AFTER_ENROLL = '1'
    $env:FRP_WINDOWS_SKIP_DOWNLOAD = '1'
    $crashed = $false
    try {
        Invoke-FrpZeroTouch -AllocatorUrl 'https://example.test/enroll' `
            -CaSha256 ('b' * 64) -BootstrapTicket 'bt1.deadbeef.deadbeef' `
            -SkipStart -SkipDownload -Hostname 'win-recover' | Out-Null
    } catch {
        $crashed = $true
        Assert-FrpTrue ([string]$_.Exception.Message -match 'FAIL_AFTER_ENROLL') 'fail-after-enroll message'
    }
    Assert-FrpTrue $crashed 'first run crashes after enroll'
    Assert-FrpEqual 1 $script:FrpRedeemCalls 'redeem once on first attempt'
    Assert-FrpEqual 1 $script:FrpEnrollCalls 'enroll once on first attempt'
    Assert-FrpTrue (Test-FrpHasEnrollRecovery) 'journal written before enroll crash'
    Assert-FrpTrue (-not (Test-Path -LiteralPath (Get-FrpStatePath))) 'no client-state yet'
    Assert-FrpTrue (-not (Test-FrpIsEnrolled)) 'not enrolled durable state'
    $midCrash = Get-FrpOrCreateClientId
    $pubBefore = [System.IO.File]::ReadAllText((Get-FrpIdentityPubPath))
    Remove-Item Env:FRP_WINDOWS_FAIL_AFTER_ENROLL -ErrorAction SilentlyContinue
    Write-FrpTestPass 'CRASH_BEFORE_DURABLE_STATE'

    # Resume: no second redeem; same identity / machine / ports
    New-Item -ItemType Directory -Path (Get-FrpBinDir) -Force | Out-Null
    Set-Content -LiteralPath (Get-FrpFrpcPath) -Value 'dummy'
    $rc = Invoke-FrpZeroTouch -AllocatorUrl 'https://example.test/enroll' `
        -CaSha256 ('b' * 64) -BootstrapTicket 'bt1.deadbeef.deadbeef' `
        -SkipStart -SkipDownload -Hostname 'win-recover'
    Assert-FrpEqual 0 $rc 'resume succeeds'
    Assert-FrpEqual 1 $script:FrpRedeemCalls 'no second redeem'
    Assert-FrpEqual 2 $script:FrpEnrollCalls 're-enroll on resume'
    Assert-FrpTrue (-not (Test-FrpHasEnrollRecovery)) 'journal deleted after success'
    Assert-FrpEqual 'installed' (Get-FrpInstallStatus) 'installed after resume'
    Assert-FrpEqual $midCrash (Get-FrpOrCreateClientId) 'same client id'
    $pubAfter = [System.IO.File]::ReadAllText((Get-FrpIdentityPubPath))
    Assert-FrpEqual $pubBefore $pubAfter 'same management identity'
    $st = Read-FrpClientState
    Assert-FrpEqual 60042 ([int]$st.services.rdp.remote_port) 'same public port'
    Write-FrpTestPass 'RESUME_WITHOUT_RE_TICKET'

    # Installed refuses re-ticket
    $rc2 = Invoke-FrpZeroTouch -AllocatorUrl 'https://example.test/enroll' `
        -CaSha256 ('b' * 64) -BootstrapTicket 'bt1.deadbeef.deadbeef' `
        -SkipStart -SkipDownload
    Assert-FrpEqual 2 $rc2 'refuse when installed'
    Assert-FrpEqual 1 $script:FrpRedeemCalls 'still no extra redeem'
    Write-FrpTestPass 'INSTALLED_REFUSES_RE_TICKET'

    Write-FrpTestPass 'test-zero-touch-recovery-journal'
} finally {
    Remove-Item Env:FRP_WINDOWS_FAIL_AFTER_ENROLL -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_WINDOWS_SKIP_DOWNLOAD -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
