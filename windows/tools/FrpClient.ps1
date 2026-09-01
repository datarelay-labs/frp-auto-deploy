#Requires -Version 5.1
<#
.SYNOPSIS
  frp-client lifecycle tool for Windows (start/stop/status/info/update/uninstall/doctor/autostart).

.NOTES
  Update is split to match Linux product semantics:
    update | update frp       — upstream frpc.exe only
    update project | project-update — PowerShell modules/tools (verified SHA256)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'status', 'info', 'update', 'uninstall', 'doctor', 'autostart',
        'pause', 'resume', 'restart', 'test', 'logs', 'support-bundle', 'help', 'project-update')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$SubCommand,

    [switch]$Check,
    [switch]$Force,
    [string]$DownloadUrl,
    [string]$ExpectedSha256,
    [string]$SourceDir,
    [string]$MetadataUrl
)

$ErrorActionPreference = 'Stop'

function Import-FrpWindowsModules {
    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add((Join-Path $PSScriptRoot '..\lib'))
    if ($env:FRP_WINDOWS_ROOT) {
        [void]$roots.Add((Join-Path $env:FRP_WINDOWS_ROOT 'lib'))
    }
    [void]$roots.Add((Join-Path $env:ProgramData 'frp-auto-deploy\lib'))
    # When running from repo
    [void]$roots.Add((Join-Path $PSScriptRoot '..\lib'))

    $libDir = $null
    foreach ($r in $roots) {
        $full = [System.IO.Path]::GetFullPath($r)
        if (Test-Path -LiteralPath (Join-Path $full 'FrpPaths.ps1')) {
            $libDir = $full
            break
        }
    }
    if (-not $libDir) {
        throw 'ERROR: cannot locate windows/lib modules'
    }
    foreach ($mod in @(
            'FrpPaths.ps1', 'FrpCrypto.ps1', 'FrpTls.ps1', 'FrpClockSync.ps1', 'FrpState.ps1',
            'FrpConfig.ps1', 'FrpProcess.ps1', 'FrpBootstrap.ps1', 'FrpLifecycle.ps1'
        )) {
        . (Join-Path $libDir $mod)
    }
}

Import-FrpWindowsModules
try { Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue | Out-Null } catch { }

function Show-FrpClientHelp {
    @'
frp-client (Windows)

  start       Start frpc from existing config (no re-enroll)
  stop        Stop project-managed frpc
  status      Running / enrolled summary
  info        Connection details (RDP/SSH/HTTP)
  update | update frp
              Update upstream frpc.exe only (preserve identity/ports); -Check for dry run
  update project | project-update
              Update PowerShell modules/tools from verified immutable source (SHA256);
              preserve identity/ports/pause/config; transactional rollback; candidate exact SHA
  pause       Pause remote FRP access (identity/ports preserved)
  resume      Resume remote FRP access
  restart     Restart frpc without re-enroll
  test        Read-only connectivity test
  logs        Show frpc.log [--lines N] [--follow]
  support-bundle  Create diagnostic bundle (no secrets)
  uninstall   Remove local software (SERVER RESERVATIONS PRESERVED)
  doctor      Basic local checks
  autostart   Optional autostart helper (stub)

'@ | Write-Host
}

function Show-FrpClientInfo {
    if (-not (Test-Path -LiteralPath (Get-FrpStatePath))) {
        Write-Host 'ERROR: not enrolled (client-state.json missing)'
        return 1
    }
    $state = Read-FrpClientState
    $server = [string]$state.frp_server
    Write-Host ("FRP Server: {0}" -f $server)
    Write-Host ("Transport: {0}" -f $state.frp_transport)
    Write-Host ("Machine ID: {0}" -f $state.machine_id)
    Write-Host ''
    Write-Host 'Services:'
    Write-Host ''
    $services = $state.services
    $items = @()
    if ($services -is [System.Collections.IDictionary]) {
        foreach ($k in $services.Keys) {
            $rec = $services[$k]
            $items += $rec
        }
    } else {
        foreach ($p in $services.PSObject.Properties) {
            $items += $p.Value
        }
    }
    foreach ($item in $items) {
        $enabled = $true
        if ($null -ne $item.enabled) { $enabled = [bool]$item.enabled }
        if (-not $enabled) { continue }
        $sid = [string]$item.id
        $name = [string]$item.name
        $preset = [string]$item.preset
        if (-not $preset) { $preset = 'custom' }
        $remote = $item.remote_port
        $localIp = [string]$item.local_ip
        $localPort = $item.local_port
        Write-Host ("{0} ({1})" -f $sid, $name)
        Write-Host ("  Target : {0}:{1}" -f $localIp, $localPort)
        Write-Host ("  Public : {0}:{1}" -f $server, $remote)
        $isRdp = ($preset -eq 'rdp') -or ($sid -eq 'rdp') -or ([int]$localPort -eq 3389 -and $preset -eq 'custom')
        if ($isRdp) {
            Write-Host '  Connect:'
            Write-Host ("    mstsc /v:{0}:{1}" -f $server, $remote)
        } elseif ($preset -eq 'ssh') {
            $user = [string]$item.ssh_user
            if ($user) {
                Write-Host '  Connect:'
                Write-Host ("    ssh -p {0} {1}@{2}" -f $remote, $user, $server)
            } else {
                Write-Host '  SSH user: legacy / unspecified'
            }
        } elseif ($preset -eq 'http') {
            Write-Host '  URL:'
            Write-Host ("    http://{0}:{1}" -f $server, $remote)
        } elseif ($preset -eq 'https') {
            Write-Host '  URL:'
            Write-Host ("    https://{0}:{1}" -f $server, $remote)
        } else {
            Write-Host '  Connect:'
            Write-Host ("    {0}:{1}" -f $server, $remote)
        }
        Write-Host ''
    }
    return 0
}

function Invoke-FrpClientUpdate {
    <#
    .SYNOPSIS
      Update upstream frpc.exe only (not project PowerShell modules).
    #>
    param([switch]$CheckOnly)
    $url = $DownloadUrl
    if (-not $url) { $url = Get-FrpWindowsAmd64Url }
    $sha = $ExpectedSha256
    if (-not $sha) { $sha = Get-FrpWindowsAmd64Sha256 }
    if ($CheckOnly) {
        Write-Host 'Update target: FRP binary (frpc.exe)'
        Write-Host ("Would download: {0}" -f $url)
        Write-Host ("Expected SHA256: {0}" -f $sha)
        Write-Host 'Identity, ports, and frpc.toml token would be preserved.'
        Write-Host 'For PowerShell modules/tools use: frp-client update project'
        return 0
    }
    try {
        return Invoke-FrpWithMutationLock -Script {
            Initialize-FrpDirectories
            $snapshotMap = [ordered]@{
                'frpc.exe'          = (Get-FrpFrpcPath)
                'frpc.toml'         = (Get-FrpTomlPath)
                'client-state.json' = (Get-FrpStatePath)
                'version'           = (Get-FrpVersionPath)
            }
            # Create dir → restrict ACL → only then copy secrets. ACL failure aborts before copy.
            $backupRoot = New-FrpUpdateBackupSnapshot -SnapshotMap $snapshotMap
            $wasRunning = $false
            try {
                $st = Get-FrpClientStatus
                if ($st.Running) {
                    $wasRunning = $true
                    Stop-FrpClient | Out-Null
                }
                Install-FrpWindowsBinary -DownloadUrl $url -ExpectedSha256 $sha | Out-Null
                if ($env:FRP_WINDOWS_FAIL_AFTER_BINARY_REPLACE -eq '1') {
                    throw 'ERROR: simulated failure after binary replace (FRP_WINDOWS_FAIL_AFTER_BINARY_REPLACE=1)'
                }
                # Preserve identity/ports: do not rewrite state or toml here.
                if ($env:FRP_WINDOWS_FAIL_AFTER_METADATA_WRITE -eq '1') {
                    throw 'ERROR: simulated failure after metadata write (FRP_WINDOWS_FAIL_AFTER_METADATA_WRITE=1)'
                }
                if ($wasRunning -and -not (Test-FrpRemoteAccessPaused)) {
                    if ($env:FRP_WINDOWS_FAIL_BEFORE_RESTART -eq '1') {
                        throw 'ERROR: simulated failure before restart (FRP_WINDOWS_FAIL_BEFORE_RESTART=1)'
                    }
                    Start-FrpClient | Out-Null
                }
                Write-Host 'FRP update complete (identity and port reservations preserved).'
                return 0
            } catch {
                Write-Host ("ERROR: FRP update failed: {0}" -f $_.Exception.Message)
                Write-Host 'Attempting full rollback from backup...'
                $rollbackOk = $true
                try {
                    foreach ($name in @('frpc.exe', 'frpc.toml', 'client-state.json', 'version')) {
                        $bak = Join-Path $backupRoot $name
                        if (-not (Test-Path -LiteralPath $bak)) { continue }
                        $dest = $snapshotMap[$name]
                        $destDir = Split-Path -Parent $dest
                        if (-not (Test-Path -LiteralPath $destDir)) {
                            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                        }
                        Copy-Item -LiteralPath $bak -Destination $dest -Force
                    }
                    if ($wasRunning -and -not (Test-FrpRemoteAccessPaused)) {
                        Start-FrpClient | Out-Null
                    }
                    Write-Host 'Rollback restored snapshotted files and prior run state.'
                } catch {
                    $rollbackOk = $false
                    Write-Host ("ERROR: rollback failed: {0}" -f $_.Exception.Message)
                    Write-Host 'RECOVERY_REQUIRED=YES'
                }
                if (-not $rollbackOk) {
                    Write-Host 'RECOVERY_REQUIRED=YES'
                }
                return 1
            }
        }
    } catch {
        Write-Host $_.Exception.Message
        return 1
    }
}

function Invoke-FrpClientProjectUpdate {
    <#
    .SYNOPSIS
      Update PowerShell modules/tools from a verified immutable source.
      Preserves identity, ports, pause marker, frpc.toml, and frpc.exe.
    #>
    param(
        [switch]$CheckOnly,
        [string]$SourceWindowsRoot,
        [string]$ArtifactUrl,
        [string]$SumsUrl,
        [string]$ExpectedBundleSha256
    )
    try {
        $identity = Resolve-FrpWindowsProjectUpdateIdentity
    } catch {
        Write-Host $_.Exception.Message
        return 1
    }
    $channel = [string]$identity.Channel
    $sourceRef = [string]$identity.SourceRef

    $srcRoot = $SourceWindowsRoot
    if (-not $srcRoot -and $env:FRP_WINDOWS_PROJECT_SOURCE) {
        $srcRoot = $env:FRP_WINDOWS_PROJECT_SOURCE.Trim()
    }
    $url = $ArtifactUrl
    if (-not $url) { $url = $DownloadUrl }
    if (-not $url -and $env:FRP_WINDOWS_PROJECT_UPDATE_URL) {
        $url = $env:FRP_WINDOWS_PROJECT_UPDATE_URL.Trim()
    }
    $metaUrl = $SumsUrl
    if (-not $metaUrl) { $metaUrl = $MetadataUrl }
    if (-not $metaUrl -and $env:FRP_WINDOWS_PROJECT_METADATA_URL) {
        $metaUrl = $env:FRP_WINDOWS_PROJECT_METADATA_URL.Trim()
    }
    $expected = $ExpectedBundleSha256
    if (-not $expected) { $expected = $ExpectedSha256 }
    if (-not $expected -and $env:FRP_BUNDLE_SHA256) {
        $expected = $env:FRP_BUNDLE_SHA256.Trim().ToLowerInvariant()
    }

    if ($CheckOnly) {
        Write-Host 'Update target: project (PowerShell modules/tools)'
        Write-Host ("Release channel: {0}" -f $channel)
        Write-Host ("Source ref: {0}" -f $sourceRef)
        if ($srcRoot) {
            Write-Host ("Would install from local source: {0}" -f $srcRoot)
        } else {
            if (-not $url) { $url = Get-FrpDefaultWindowsClientInstallerUrl }
            if (-not $metaUrl) { $metaUrl = Get-FrpDefaultReleaseSha256SumsUrl }
            Write-Host ("Would download: {0}" -f $url)
            Write-Host ("Integrity metadata: {0}" -f $metaUrl)
        }
        if ($expected) { Write-Host ("Expected BUNDLE_SHA256: {0}" -f $expected) }
        Write-Host 'Identity, ports, pause state, frpc.toml, and frpc.exe would be preserved.'
        return 0
    }

    try {
        return Invoke-FrpWithMutationLock -Script {
            Initialize-FrpDirectories

            $tmpDir = $null
            $bundlePath = $null
            $verifiedSha = $expected
            $installFrom = $srcRoot

            try {
                if (-not $installFrom) {
                    if (-not $url) { $url = Get-FrpDefaultWindowsClientInstallerUrl }
                    if (-not $metaUrl) { $metaUrl = Get-FrpDefaultReleaseSha256SumsUrl }
                    if ($url -notmatch '^https://' -or $metaUrl -notmatch '^https://') {
                        throw 'ERROR: project update URLs must be https://'
                    }
                    if (-not (Test-FrpUrlHasSourceRef -Url $url -Ref $sourceRef) -or
                        -not (Test-FrpUrlHasSourceRef -Url $metaUrl -Ref $sourceRef)) {
                        throw ("ERROR: project update artifact and metadata URLs must use source ref {0}" -f $sourceRef)
                    }
                    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('frp-win-proj-' + [guid]::NewGuid().ToString('N'))
                    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
                    $sumsPath = Join-Path $tmpDir 'SHA256SUMS'
                    $bundlePath = Join-Path $tmpDir 'bootstrap-client.ps1'
                    Write-Host 'Downloading Windows project update artifact...'
                    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                        $p1 = Start-Process -FilePath 'curl.exe' -ArgumentList @(
                            '--fail', '--silent', '--show-error', '--location', '--proto', '=https',
                            '-o', $sumsPath, $metaUrl
                        ) -Wait -PassThru -NoNewWindow
                        if ($p1.ExitCode -ne 0) { throw 'ERROR: failed to download project update integrity metadata' }
                        $p2 = Start-Process -FilePath 'curl.exe' -ArgumentList @(
                            '--fail', '--silent', '--show-error', '--location', '--proto', '=https',
                            '-o', $bundlePath, $url
                        ) -Wait -PassThru -NoNewWindow
                        if ($p2.ExitCode -ne 0) { throw 'ERROR: failed to download the project update bundle' }
                    } else {
                        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                        $wc = New-Object System.Net.WebClient
                        try {
                            $wc.DownloadFile($metaUrl, $sumsPath)
                            $wc.DownloadFile($url, $bundlePath)
                        } finally { $wc.Dispose() }
                    }
                    $fromSums = Get-FrpSha256SumsEntry -SumsPath $sumsPath -ArtifactName 'dist/bootstrap-client.ps1'
                    if ($verifiedSha -and ($verifiedSha.ToLowerInvariant() -ne $fromSums)) {
                        throw 'ERROR: FRP_BUNDLE_SHA256 does not match SHA256SUMS entry for dist/bootstrap-client.ps1'
                    }
                    $verifiedSha = $fromSums
                    $actual = Get-FrpSha256HexOfFile -Path $bundlePath
                    if ($actual -ne $verifiedSha) {
                        throw 'ERROR: downloaded project update failed SHA256 verification'
                    }
                    $env:FRP_BUNDLE_SHA256 = $verifiedSha
                    if ($env:FRP_WINDOWS_PROJECT_SOURCE -and (Test-Path -LiteralPath $env:FRP_WINDOWS_PROJECT_SOURCE)) {
                        $installFrom = $env:FRP_WINDOWS_PROJECT_SOURCE.Trim()
                    } else {
                        throw 'ERROR: verified project bootstrap artifact, but no windows/ source tree was provided; set -SourceDir or FRP_WINDOWS_PROJECT_SOURCE to the extracted windows package root'
                    }
                } else {
                    if (-not (Test-Path -LiteralPath $installFrom)) {
                        throw ("ERROR: project source directory missing: {0}" -f $installFrom)
                    }
                    if (-not $verifiedSha) {
                        # Local/fixture path: hash a marker file if provided, else hash SourceDir stamp file.
                        if ($env:FRP_BUNDLE_FILE -and (Test-Path -LiteralPath $env:FRP_BUNDLE_FILE)) {
                            $verifiedSha = Get-FrpSha256HexOfFile -Path $env:FRP_BUNDLE_FILE
                        } elseif ($expected) {
                            $verifiedSha = $expected.ToLowerInvariant()
                        }
                    }
                }

                $snapshotMap = [ordered]@{}
                foreach ($rel in (Get-FrpWindowsProjectManagedRelativePaths)) {
                    $dest = Join-Path (Get-FrpWindowsRoot) ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
                    $snapName = ($rel -replace '/', '__')
                    $snapshotMap[$snapName] = $dest
                }
                $snapshotMap['version'] = (Get-FrpVersionPath)
                $snapshotMap['frpc.toml'] = (Get-FrpTomlPath)
                $snapshotMap['client-state.json'] = (Get-FrpStatePath)
                $pausePath = Get-FrpPauseMarkerPath
                if (Test-Path -LiteralPath $pausePath) {
                    $snapshotMap['remote-access-paused.json'] = $pausePath
                }

                $backupRoot = New-FrpUpdateBackupSnapshot -SnapshotMap $snapshotMap
                $wasRunning = $false
                $wasPaused = Test-FrpRemoteAccessPaused
                try {
                    $st = Get-FrpClientStatus
                    if ($st.Running) {
                        $wasRunning = $true
                        Stop-FrpClient | Out-Null
                    }

                    # Capture protected identity fingerprints before mutation.
                    $stateBefore = $null
                    if (Test-Path -LiteralPath (Get-FrpStatePath)) {
                        $stateBefore = (Get-Content -LiteralPath (Get-FrpStatePath) -Raw)
                    }
                    $tomlBefore = $null
                    if (Test-Path -LiteralPath (Get-FrpTomlPath)) {
                        $tomlBefore = (Get-Content -LiteralPath (Get-FrpTomlPath) -Raw)
                    }

                    Install-FrpWindowsProjectTree -SourceWindowsRoot $installFrom | Out-Null
                    if ($env:FRP_WINDOWS_FAIL_AFTER_PROJECT_REPLACE -eq '1') {
                        throw 'ERROR: simulated failure after project replace (FRP_WINDOWS_FAIL_AFTER_PROJECT_REPLACE=1)'
                    }

                    $tomlRefresh = $false
                    if (Update-FrpClientDataPlaneMetadataIfNeeded) {
                        $tomlRefresh = $true
                        Write-Host 'Refreshed frpc.toml with data-plane authorization metadata.'
                    }

                    $prevChannel = $env:FRP_RELEASE_CHANNEL
                    $prevRef = $env:FRP_SOURCE_REF
                    $prevBundle = $env:FRP_BUNDLE_SHA256
                    try {
                        $env:FRP_RELEASE_CHANNEL = $channel
                        if ($channel -eq 'candidate') {
                            $env:FRP_SOURCE_REF = $sourceRef
                        } elseif ($channel -eq 'dev') {
                            Remove-Item Env:FRP_SOURCE_REF -ErrorAction SilentlyContinue
                        }
                        if ($verifiedSha) {
                            $env:FRP_BUNDLE_SHA256 = $verifiedSha
                        }
                        Write-FrpVersionFile -BundleSha256 $verifiedSha | Out-Null
                    } finally {
                        if ($null -ne $prevChannel) { $env:FRP_RELEASE_CHANNEL = $prevChannel }
                        else { Remove-Item Env:FRP_RELEASE_CHANNEL -ErrorAction SilentlyContinue }
                        if ($null -ne $prevRef) { $env:FRP_SOURCE_REF = $prevRef }
                        else { Remove-Item Env:FRP_SOURCE_REF -ErrorAction SilentlyContinue }
                        if ($null -ne $prevBundle) { $env:FRP_BUNDLE_SHA256 = $prevBundle }
                        else { Remove-Item Env:FRP_BUNDLE_SHA256 -ErrorAction SilentlyContinue }
                    }

                    # Identity/ports/config must remain byte-stable.
                    if ($null -ne $stateBefore) {
                        $stateAfter = Get-Content -LiteralPath (Get-FrpStatePath) -Raw
                        if ($stateAfter -ne $stateBefore) {
                            throw 'ERROR: protected client state changed during project update'
                        }
                    }
                    if ($null -ne $tomlBefore -and -not $tomlRefresh) {
                        $tomlAfter = Get-Content -LiteralPath (Get-FrpTomlPath) -Raw
                        if ($tomlAfter -ne $tomlBefore) {
                            throw 'ERROR: protected frpc.toml changed during project update'
                        }
                    }
                    if ($wasPaused -and -not (Test-FrpRemoteAccessPaused)) {
                        throw 'ERROR: pause state was cleared during project update'
                    }

                    if ($wasRunning -and -not (Test-FrpRemoteAccessPaused)) {
                        Start-FrpClient | Out-Null
                    }
                    Write-Host 'Project update complete (identity, ports, and pause state preserved).'
                    return 0
                } catch {
                    Write-Host ("ERROR: project update failed: {0}" -f $_.Exception.Message)
                    Write-Host 'Attempting full rollback from backup...'
                    $rollbackOk = $true
                    try {
                        foreach ($name in @($snapshotMap.Keys)) {
                            $bak = Join-Path $backupRoot $name
                            if (-not (Test-Path -LiteralPath $bak)) { continue }
                            $dest = $snapshotMap[$name]
                            $destDir = Split-Path -Parent $dest
                            if (-not (Test-Path -LiteralPath $destDir)) {
                                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                            }
                            Copy-Item -LiteralPath $bak -Destination $dest -Force
                        }
                        if ($wasRunning -and -not (Test-FrpRemoteAccessPaused)) {
                            Start-FrpClient | Out-Null
                        }
                        Write-Host 'Rollback restored snapshotted project files and prior run state.'
                    } catch {
                        $rollbackOk = $false
                        Write-Host ("ERROR: rollback failed: {0}" -f $_.Exception.Message)
                        Write-Host 'RECOVERY_REQUIRED=YES'
                    }
                    if (-not $rollbackOk) {
                        Write-Host 'RECOVERY_REQUIRED=YES'
                    }
                    return 1
                }
            } finally {
                if ($tmpDir -and (Test-Path -LiteralPath $tmpDir)) {
                    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {
        Write-Host $_.Exception.Message
        return 1
    }
}


function Invoke-FrpClientDoctor {
    $issues = 0
    Write-Host 'frp-client doctor (basic)'
    Write-Host ("Root: {0}" -f (Get-FrpWindowsRoot))
    if (Test-FrpWindowsPlaintextIdentityOnly) {
        Write-Host 'Identity: FAIL plaintext-only (DPAPI required on Windows)'
        $issues++
    }
    if (Test-FrpIsEnrolled) {
        Write-Host 'Enrolled: yes'
    } else {
        Write-Host 'Enrolled: no'
        $issues++
    }
    foreach ($p in @((Get-FrpTomlPath), (Get-FrpStatePath), (Get-FrpAllocatorCaPath), (Get-FrpIdentityPubPath))) {
        if (Test-Path -LiteralPath $p) {
            Write-Host ("OK  {0}" -f $p)
        } else {
            Write-Host ("MISS {0}" -f $p)
            $issues++
        }
    }
    $keyPath = Get-FrpIdentityKeyPath
    if (Test-Path -LiteralPath $keyPath) {
        Write-Host ("OK  {0}" -f $keyPath)
    } else {
        Write-Host ("MISS {0}" -f $keyPath)
        $issues++
    }
    if (Test-Path -LiteralPath (Get-FrpFrpcPath)) {
        Write-Host ("OK  {0}" -f (Get-FrpFrpcPath))
    } else {
        Write-Host ("MISS {0}" -f (Get-FrpFrpcPath))
        $issues++
    }
    $st = Get-FrpClientStatus
    Write-Host ("Running: {0} pid={1}" -f $st.Running, $st.Pid)
    if ($issues -gt 0) {
        Write-Host ("Doctor found {0} issue(s)" -f $issues)
        return 1
    }
    Write-Host 'Doctor: basic checks passed'
    return 0
}

function Invoke-FrpClientAutostart {
    Write-Host 'Autostart: not configured'
    Write-Host 'Optional Task Scheduler / Windows Service registration is not part of the MVP.'
    Write-Host 'After reboot, run: frp-client start'
    return 0
}

switch ($Command) {
    'help' { Show-FrpClientHelp; exit 0 }
    'start' {
        if (-not (Test-FrpIsEnrolled)) {
            Write-Host 'ERROR: not enrolled; run install-client.ps1 -ZeroTouch first'
            exit 1
        }
        Start-FrpClient -Force:$Force | Out-Null
        exit 0
    }
    'stop' { Stop-FrpClient | Out-Null; exit 0 }
    'status' {
        $st = Get-FrpClientStatus
        Write-Host ("enrolled={0}" -f $st.Enrolled)
        Write-Host ("running={0}" -f $st.Running)
        if ($null -ne $st.Pid) { Write-Host ("pid={0}" -f $st.Pid) }
        if ($st.Server) { Write-Host ("server={0}" -f $st.Server) }
        if ($st.Transport) { Write-Host ("transport={0}" -f $st.Transport) }
        exit 0
    }
    'info' { exit (Show-FrpClientInfo) }
    'update' {
        $sub = ''
        if ($SubCommand) { $sub = $SubCommand.Trim().ToLowerInvariant() }
        if ($sub -eq 'project') {
            exit (Invoke-FrpClientProjectUpdate -CheckOnly:$Check -SourceWindowsRoot $SourceDir `
                    -ArtifactUrl $DownloadUrl -SumsUrl $MetadataUrl -ExpectedBundleSha256 $ExpectedSha256)
        }
        if (-not $sub -or $sub -eq 'frp') {
            exit (Invoke-FrpClientUpdate -CheckOnly:$Check)
        }
        Write-Host ("ERROR: unknown update target '{0}' (use 'frp' or 'project')" -f $SubCommand)
        exit 1
    }
    'project-update' {
        exit (Invoke-FrpClientProjectUpdate -CheckOnly:$Check -SourceWindowsRoot $SourceDir `
                -ArtifactUrl $DownloadUrl -SumsUrl $MetadataUrl -ExpectedBundleSha256 $ExpectedSha256)
    }
    'pause' { exit (Invoke-FrpPauseRemoteAccess) }
    'resume' { exit (Invoke-FrpResumeRemoteAccess) }
    'restart' { exit (Invoke-FrpRestartConnection) }
    'test' { exit (Invoke-FrpClientTest) }
    'logs' {
        $lines = 100
        $follow = $false
        if ($env:FRP_LOG_LINES) { $lines = [int]$env:FRP_LOG_LINES }
        exit (Show-FrpClientLogs -Lines $lines -Follow:$follow)
    }
    'support-bundle' { exit (Invoke-FrpSupportBundle) }
    'uninstall' { exit (Invoke-FrpClientUninstall) }
    'doctor' { exit (Invoke-FrpClientDoctor) }
    'autostart' { exit (Invoke-FrpClientAutostart) }
    default { Show-FrpClientHelp; exit 1 }
}
