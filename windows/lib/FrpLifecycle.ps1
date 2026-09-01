# FrpLifecycle.ps1 — pause/resume/restart/test/logs/support-bundle helpers.

if ((Test-Path variable:script:FrpLifecycleLoaded) -and $script:FrpLifecycleLoaded) { return }
$script:FrpLifecycleLoaded = $true

function Get-FrpPauseMarkerPath {
    Join-Path (Get-FrpStateDir) 'remote-access-paused.json'
}

function Test-FrpRemoteAccessPaused {
    $path = Get-FrpPauseMarkerPath
    return (Test-Path -LiteralPath $path)
}

function Write-FrpPauseMarker {
    param([bool]$AutostartWasEnabled = $false)
    Initialize-FrpDirectories
    $path = Get-FrpPauseMarkerPath
    $payload = @{
        schema_version = 1
        paused         = $true
        paused_at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        autostart_was_enabled = [bool]$AutostartWasEnabled
    } | ConvertTo-Json -Depth 4
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $payload + "`n")
    Restrict-FrpFileAcl -Path $tmp
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Restrict-FrpFileAcl -Path $path
}

function Clear-FrpPauseMarker {
    $path = Get-FrpPauseMarkerPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Invoke-FrpPauseRemoteAccess {
    try {
        return Invoke-FrpWithMutationLock -Script {
            if (-not (Test-FrpIsEnrolled)) {
                Write-Host 'ERROR: not enrolled'
                return 1
            }
            if (Test-FrpRemoteAccessPaused) {
                Write-Host 'Remote access is already paused.'
                return 0
            }
            $wasRunning = $false
            try {
                $st = Get-FrpClientStatus
                $wasRunning = [bool]$st.Running
                Stop-FrpClient | Out-Null
            } catch {
                Write-Host ("ERROR: failed to stop frpc: {0}" -f $_.Exception.Message)
                return 1
            }
            Write-FrpPauseMarker -AutostartWasEnabled:$wasRunning
            Write-Host 'Remote access paused.'
            Write-Host 'Use frpctl resume to reconnect.'
            return 0
        }
    } catch {
        Write-Host $_.Exception.Message
        return 1
    }
}

function Invoke-FrpResumeRemoteAccess {
    try {
        return Invoke-FrpWithMutationLock -Script {
            if (-not (Test-FrpIsEnrolled)) {
                Write-Host 'ERROR: not enrolled'
                return 1
            }
            $path = Get-FrpPauseMarkerPath
            $autostart = $false
            if (Test-Path -LiteralPath $path) {
                try {
                    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                    $autostart = [bool]$data.autostart_was_enabled
                } catch { }
                Clear-FrpPauseMarker
            }
            if ($autostart) {
                Start-FrpClient | Out-Null
            } else {
                Write-Host 'Autostart was not active before pause; frpc was not started.'
            }
            Write-Host 'Remote access resumed.'
            return 0
        }
    } catch {
        Write-Host $_.Exception.Message
        return 1
    }
}

function Invoke-FrpRestartConnection {
    try {
        return Invoke-FrpWithMutationLock -Script {
            if (Test-FrpRemoteAccessPaused) {
                Write-Host 'ERROR: client remote access is paused.'
                Write-Host "Use 'frpctl resume' to reconnect."
                return 1
            }
            Stop-FrpClient | Out-Null
            Start-FrpClient | Out-Null
            Write-Host 'FRP connection restarted.'
            return 0
        }
    } catch {
        Write-Host $_.Exception.Message
        return 1
    }
}

function Invoke-FrpClientTest {
    Write-Host 'FRP Client Connectivity Test'
    Write-Host '============================'
    Write-Host ''
    $failed = $false
    if (Test-FrpIsEnrolled) { Write-Host 'Local state              PASS' } else { Write-Host 'Local state              FAIL'; $failed = $true }
    if (Test-FrpWindowsPlaintextIdentityOnly) {
        Write-Host 'Management identity      FAIL (plaintext-only; DPAPI required on Windows)'
        $failed = $true
    } elseif (Test-Path -LiteralPath (Get-FrpIdentityPubPath)) {
        Write-Host 'Management identity      PASS'
    } else {
        Write-Host 'Management identity      FAIL'
        $failed = $true
    }
    $key = Get-FrpIdentityKeyPath
    if (Test-FrpWindowsPlaintextIdentityOnly) {
        Write-Host 'Identity permissions     FAIL (plaintext-only rejected on Windows)'
        $failed = $true
    } else {
        $aclResult = Test-FrpIdentityKeyAcl -Path $key
        if ($aclResult -eq 'PASS') {
            Write-Host 'Identity permissions     PASS'
        } elseif ($aclResult -eq 'UNKNOWN') {
            Write-Host 'Identity permissions     UNKNOWN'
        } else {
            Write-Host 'Identity permissions     FAIL'
            $failed = $true
        }
    }
    if (Test-Path -LiteralPath (Get-FrpTomlPath)) { Write-Host 'FRP configuration        PASS' } else { Write-Host 'FRP configuration        FAIL'; $failed = $true }
    if (Test-FrpRemoteAccessPaused) {
        Write-Host 'Remote access            PAUSED'
    } else {
        Write-Host 'Remote access            ACTIVE'
    }
    $st = Get-FrpClientStatus
    if ($st.Running) { Write-Host 'frpc process             PASS' } else { Write-Host 'frpc process             WARN' }
    Write-Host ''
    Write-Host 'External public reachability : NOT TESTED'
    Write-Host ''
    if ($failed) {
        Write-Host 'RESULT=FAIL'
        return 1
    }
    Write-Host 'RESULT=PASS'
    return 0
}

function Show-FrpClientLogs {
    param([int]$Lines = 100, [switch]$Follow)
    $log = Join-Path (Get-FrpLogsDir) 'frpc.log'
    if (-not (Test-Path -LiteralPath $log)) {
        Write-Host 'No project-managed frpc log found.'
        return 0
    }
    if ($Follow) {
        # Redact each emitted line/chunk; do not buffer the infinite stream.
        Get-Content -LiteralPath $log -Wait -Tail $Lines | ForEach-Object {
            Write-Output (Protect-FrpRedactText -Text ([string]$_))
        }
        return 0
    }
    Get-Content -LiteralPath $log -Tail $Lines | ForEach-Object {
        Write-Output (Protect-FrpRedactText -Text ([string]$_))
    }
    return 0
}

function Protect-FrpRedactText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $out = $Text
    $out = [regex]::Replace($out, '(?im)^(auth\.)?token\s*=\s*.+$', 'auth.token = "[redacted]"')
    $out = [regex]::Replace($out, '(?im)^token\s*=\s*.+$', 'token = "[redacted]"')
    $out = [regex]::Replace($out, '(?im)^metadatas\.frp_ad_proof\s*=\s*.+$', 'metadatas.frp_ad_proof = "[redacted]"')
    $out = [regex]::Replace($out, '(?i)(Authorization\s*[:=]\s*).+$', '$1[redacted]')
    $out = [regex]::Replace($out, '(?i)Enrollment\s+Code\s*[:=]\s*\S+', 'Enrollment Code: [redacted]')
    $out = [regex]::Replace($out, '(?i)(password|passwd|secret|private[_-]?key|enrollment[_-]?code|bootstrap[_-]?ticket|mgmt_mac_key|auth_token|server_token)\s*[:=]\s*\S+', '$1=[redacted]')
    $out = [regex]::Replace($out, 'BEGIN [A-Z ]*PRIVATE KEY[\s\S]*?END [A-Z ]*PRIVATE KEY', '[redacted private key]')
    $out = [regex]::Replace($out, 'FRP_TOKEN_TEST_[A-Za-z0-9_\-]+', '[redacted]')
    $out = [regex]::Replace($out, 'btck\.[0-9a-f]{16}\.[A-Za-z0-9]+', '[redacted]')
    $out = [regex]::Replace($out, 'bt1\.[0-9a-f]{16}\.[0-9a-fA-F]+', '[redacted]')
    return $out
}

function Protect-FrpRedactJsonObject {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [pscustomobject]) {
        $Obj = ConvertTo-FrpPlainObject $Obj
    }
    if ($Obj -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in $Obj.Keys) {
            $k = [string]$key
            if ($k -match '(?i)^(token|secret|password|passwd|private.?key|authorization|enrollment.?code|bootstrap|hmac|auth_token|server_token|frp_ad_proof)$') {
                $out[$k] = '[redacted]'
            } else {
                $out[$k] = Protect-FrpRedactJsonObject -Obj $Obj[$key]
            }
        }
        return $out
    }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
        $list = @()
        foreach ($item in $Obj) { $list += ,(Protect-FrpRedactJsonObject -Obj $item) }
        return $list
    }
    if ($Obj -is [string]) { return (Protect-FrpRedactText -Text $Obj) }
    return $Obj
}

function Test-FrpPathIsReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } catch {
        return $false
    }
}

function New-FrpExclusiveTempPath {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [string]$Extension = ''
    )
    $tempRoot = [System.IO.Path]::GetTempPath()
    if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = '/tmp' }
    # Refuse to follow a reparse-point temp root.
    if (Test-FrpPathIsReparsePoint -Path $tempRoot) {
        throw 'ERROR: temp root is a reparse point; refuse support-bundle write'
    }
    for ($i = 0; $i -lt 8; $i++) {
        $guid = [guid]::NewGuid().ToString('N')
        $name = "{0}-{1}{2}" -f $Prefix, $guid, $Extension
        $candidate = Join-Path $tempRoot $name
        if (Test-Path -LiteralPath $candidate) { continue }
        if (Test-FrpPathIsReparsePoint -Path $candidate) { continue }
        return $candidate
    }
    throw 'ERROR: failed to allocate exclusive temp path for support bundle'
}

function Invoke-FrpSupportBundle {
    param([switch]$Anonymize)
    Initialize-FrpDirectories
    $out = New-FrpExclusiveTempPath -Prefix 'frp-support-bundle' -Extension '.zip'
    $stage = New-FrpExclusiveTempPath -Prefix 'frp-support-stage'
    # Never delete preexisting unknown paths on name collision — allocate fresh or abort.
    if (Test-Path -LiteralPath $stage) {
        Write-Host ("ERROR: support bundle stage path already exists: {0}" -f $stage)
        return 1
    }
    if (Test-Path -LiteralPath $out) {
        Write-Host ("ERROR: support bundle output path already exists: {0}" -f $out)
        return 1
    }
    New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
    if (Test-FrpIsWindowsHost) {
        try { Restrict-FrpDirectoryAcl -Path $stage } catch { }
    }
    $items = @()

    try {
        $ver = Get-FrpVersionPath
        if (Test-Path -LiteralPath $ver) {
            $dest = Join-Path $stage 'version.txt'
            Copy-Item -LiteralPath $ver -Destination $dest -Force
            $items += $dest
        }

        $statePath = Get-FrpStatePath
        if (Test-Path -LiteralPath $statePath) {
            $raw = Get-Content -LiteralPath $statePath -Raw
            $obj = $raw | ConvertFrom-Json
            if (Get-Command ConvertTo-FrpPlainObject -ErrorAction SilentlyContinue) {
                $obj = ConvertTo-FrpPlainObject $obj
            }
            $redacted = Protect-FrpRedactJsonObject -Obj $obj
            if ($Anonymize -and $redacted -is [System.Collections.IDictionary]) {
                foreach ($k in @('hostname', 'frp_server', 'public_host', 'host_id')) {
                    if ($redacted.Contains($k)) { $redacted[$k] = '[anonymized]' }
                }
            }
            $dest = Join-Path $stage 'client-state.redacted.json'
            ($redacted | ConvertTo-Json -Depth 12) + "`n" | Set-Content -LiteralPath $dest -NoNewline
            $items += $dest
        }

        $toml = Get-FrpTomlPath
        if (Test-Path -LiteralPath $toml) {
            $text = Protect-FrpRedactText -Text (Get-Content -LiteralPath $toml -Raw)
            if ($Anonymize) {
                $text = [regex]::Replace($text, '(?im)^(serverAddr|server_addr)\s*=\s*.+$', 'serverAddr = "[anonymized]"')
            }
            $dest = Join-Path $stage 'frpc.redacted.toml'
            Set-Content -LiteralPath $dest -Value $text -NoNewline
            $items += $dest
        }

        $log = Join-Path (Get-FrpLogsDir) 'frpc.log'
        if (Test-Path -LiteralPath $log) {
            $text = Protect-FrpRedactText -Text (Get-Content -LiteralPath $log -Raw)
            $dest = Join-Path $stage 'frpc.redacted.log'
            Set-Content -LiteralPath $dest -Value $text -NoNewline
            $items += $dest
        }

        if ($items.Count -eq 0) {
            Write-Host 'ERROR: nothing to bundle'
            return 1
        }
        if (Test-Path -LiteralPath $out) {
            Write-Host ("ERROR: support bundle output appeared during staging: {0}" -f $out)
            return 1
        }
        if (Test-FrpPathIsReparsePoint -Path $out) {
            Write-Host 'ERROR: support bundle output path is a reparse point'
            return 1
        }
        Compress-Archive -LiteralPath $items -DestinationPath $out -Force
        Restrict-FrpFileAcl -Path $out
        Write-Host ("Support bundle written to: {0}" -f $out)
        return 0
    } finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-FrpClientUninstall {
    try {
        return Invoke-FrpWithMutationLock -Script {
            Write-Host 'LOCAL SOFTWARE REMOVED, SERVER RESERVATIONS PRESERVED'
            Write-Host 'This removes local frpc binaries, config, state, and tools.'
            Write-Host 'Public port reservations on the server remain until an administrator releases them.'
            $root = Get-FrpWindowsRoot
            # Fail-closed: stop must succeed (or process already gone) before removing credentials.
            try {
                Stop-FrpClient | Out-Null
            } catch {
                Write-Host ("ERROR: failed to stop frpc before uninstall: {0}" -f $_.Exception.Message)
                return 1
            }
            $st = Get-FrpClientStatus
            if ($st.Running) {
                Write-Host 'ERROR: frpc still running; refusing to remove credentials'
                return 1
            }
            if (-not (Test-Path -LiteralPath $root)) {
                Write-Host 'Nothing to remove (already uninstalled).'
                return 0
            }
            try {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Host ("ERROR: failed to remove local install: {0}" -f $_.Exception.Message)
                if (Test-Path -LiteralPath $root) {
                    Write-Host 'Remaining items:'
                    Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
                        ForEach-Object { Write-Host ("  {0}" -f $_.FullName) }
                }
                return 1
            }
            if (Test-Path -LiteralPath $root) {
                Write-Host 'ERROR: local install directory still present after Remove-Item'
                Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { Write-Host ("  {0}" -f $_.FullName) }
                return 1
            }
            Write-Host ("Removed: {0}" -f $root)
            return 0
        }
    } catch {
        Write-Host $_.Exception.Message
        return 1
    }
}
