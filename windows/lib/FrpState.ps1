# FrpState.ps1 — directories, client-id, identity storage, client-state.json.

if ((Test-Path variable:script:FrpStateLoaded) -and $script:FrpStateLoaded) { return }
$script:FrpStateLoaded = $true

function Initialize-FrpDirectories {
    $dirs = @(
        (Get-FrpWindowsRoot),
        (Get-FrpBinDir),
        (Get-FrpConfigDir),
        (Get-FrpStateDir),
        (Get-FrpCertsDir),
        (Get-FrpLogsDir),
        (Get-FrpToolsDir),
        (Get-FrpLibDir),
        (Get-FrpBackupDir)
    )
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    if (Test-FrpIsWindowsHost) {
        Restrict-FrpDirectoryAcl -Path (Get-FrpStateDir)
        Restrict-FrpDirectoryAcl -Path (Get-FrpConfigDir)
        Restrict-FrpDirectoryAcl -Path (Get-FrpCertsDir)
        # Harden backups before any sensitive snapshot copies can land there.
        Restrict-FrpDirectoryAcl -Path (Get-FrpBackupDir)
    }
}

function Restrict-FrpDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($env:FRP_WINDOWS_FAIL_ACL -eq '1') {
        throw 'ERROR: simulated ACL failure (FRP_WINDOWS_FAIL_ACL=1)'
    }
    if (-not (Test-FrpIsWindowsHost)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) {
            try { [void]$acl.RemoveAccessRule($rule) } catch { }
        }
        $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $prop = [System.Security.AccessControl.PropagationFlags]::None
        $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
        $type = [System.Security.AccessControl.AccessControlType]::Allow
        foreach ($id in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, $rights, $inherit, $prop, $type)
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        throw ("ERROR: failed to restrict directory ACL: {0}" -f $Path)
    }
}

function Restrict-FrpFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($env:FRP_WINDOWS_FAIL_ACL -eq '1') {
        throw 'ERROR: simulated ACL failure (FRP_WINDOWS_FAIL_ACL=1)'
    }
    if (Test-FrpIsWindowsHost) {
        try {
            $acl = Get-Acl -LiteralPath $Path
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($acl.Access)) {
                try { [void]$acl.RemoveAccessRule($rule) } catch { }
            }
            $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
            $type = [System.Security.AccessControl.AccessControlType]::Allow
            foreach ($id in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, $rights, $type)
                $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $Path -AclObject $acl
        } catch {
            throw ("ERROR: failed to restrict ACL on sensitive path: {0}" -f $Path)
        }
        return
    }
    # Linux / test host: chmod 600 best-effort
    try {
        & chmod 600 -- $Path 2>$null
    } catch { }
}

function Test-FrpIdentityKeyAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    # Returns: PASS | FAIL | UNKNOWN
    if (-not (Test-Path -LiteralPath $Path)) {
        return 'FAIL'
    }
    if ($env:FRP_WINDOWS_FORCE_ACL_UNKNOWN -eq '1') {
        return 'UNKNOWN'
    }
    if ($env:FRP_WINDOWS_FORCE_ACL_INSECURE -eq '1') {
        return 'FAIL'
    }
    if (Test-FrpIsWindowsHost) {
        try {
            $acl = Get-Acl -LiteralPath $Path
            $allowed = @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', 'SYSTEM', 'Administrators')
            foreach ($rule in @($acl.Access)) {
                if ($rule.AccessControlType -ne 'Allow') { continue }
                $id = [string]$rule.IdentityReference
                $ok = $false
                foreach ($a in $allowed) {
                    if ($id -eq $a -or $id.EndsWith('\' + $a)) { $ok = $true; break }
                }
                if (-not $ok) {
                    return 'FAIL'
                }
            }
            return 'PASS'
        } catch {
            return 'UNKNOWN'
        }
    }
    # Non-Windows test hosts: require owner-only mode bits (no group/other).
    try {
        $mode = & stat -c '%a' -- $Path 2>$null
        if (-not $mode) { return 'UNKNOWN' }
        $mode = [string]$mode
        if ($mode -match '^[0-7]+$' -and ($mode.EndsWith('00') -or $mode -eq '600' -or $mode -eq '400')) {
            return 'PASS'
        }
        return 'FAIL'
    } catch {
        return 'UNKNOWN'
    }
}

function Test-FrpMachineId {
    param([Parameter(Mandatory = $true)][string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    if ($Id.Length -lt 16 -or $Id.Length -gt 128) { return $false }
    if ($Id -match "[\r\n\x00/\\]") { return $false }
    # Mirror Linux canonical validator: leading alnum, then alnum/._:-
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]*$') { return $false }
    return $true
}

function Get-FrpOrCreateClientId {
    Initialize-FrpDirectories
    $path = Get-FrpClientIdPath
    if (Test-Path -LiteralPath $path) {
        $id = ([System.IO.File]::ReadAllText($path)).Trim()
        if (Test-FrpMachineId -Id $id) { return $id }
        throw ("ERROR: persisted client-id is invalid (length/charset); refuse to reuse: {0}" -f $path)
    }
    $id = New-FrpClientId
    if (-not (Test-FrpMachineId -Id $id)) {
        throw 'ERROR: generated client-id failed validation'
    }
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $id + "`n")
    Restrict-FrpFileAcl -Path $tmp
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Restrict-FrpFileAcl -Path $path
    return $id
}

function Test-FrpIsEnrolled {
    $statePath = Get-FrpStatePath
    $tomlPath = Get-FrpTomlPath
    $pubPath = Get-FrpIdentityPubPath
    $keyPath = Get-FrpIdentityKeyPath
    if (-not (Test-Path -LiteralPath $statePath)) { return $false }
    if (-not (Test-Path -LiteralPath $tomlPath)) { return $false }
    if (-not (Test-Path -LiteralPath $pubPath)) { return $false }
    # Windows plaintext-only identity is never enrolled (DPAPI required).
    if (Test-FrpWindowsPlaintextIdentityOnly) { return $false }
    if (-not (Test-Path -LiteralPath $keyPath)) { return $false }
    return $true
}

function Initialize-FrpDpapi {
    # Shared DPAPI availability gate for Save/Read-FrpIdentityKey.
    # Windows hosts must have System.Security ProtectedData types; fail closed otherwise.
    if ((Test-Path variable:script:FrpDpapiReady) -and $script:FrpDpapiReady) {
        return $true
    }
    if (-not (Test-FrpIsWindowsHost)) {
        return $false
    }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop | Out-Null
    } catch {
        throw ('ERROR: System.Security assembly unavailable; DPAPI required on Windows: {0}' -f $_.Exception.Message)
    }
    # Force runtime resolution only after Add-Type (Save previously referenced types too early).
    $probe = $null
    try {
        $probe = [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        $null = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        $null = [System.Security.Cryptography.ProtectedData]
    } catch {
        throw ('ERROR: DPAPI types unavailable; cannot persist identity key on Windows: {0}' -f $_.Exception.Message)
    }
    if ($null -eq $probe) {
        throw 'ERROR: DPAPI types unavailable; cannot persist identity key on Windows'
    }
    $script:FrpDpapiReady = $true
    return $true
}

function Save-FrpIdentityKey {
    param([Parameter(Mandatory = $true)][string]$PrivatePem)
    Initialize-FrpDirectories
    $stateDir = Get-FrpStateDir
    if (Initialize-FrpDpapi) {
        $path = Join-Path $stateDir 'client-identity.key.dpapi'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($PrivatePem)
        $scope = [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        try {
            $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, $scope)
        } catch {
            # Fall back to CurrentUser if LocalMachine DPAPI is unavailable.
            $protected = [System.Security.Cryptography.ProtectedData]::Protect(
                $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        [System.IO.File]::WriteAllBytes($path, $protected)
        Restrict-FrpFileAcl -Path $path
        return $path
    }
    # Non-Windows test hosts only. Production Windows never reaches here (Initialize-FrpDpapi fails closed).
    Write-Warning 'DPAPI unavailable; storing identity key as a plain file under the test root. Do not use this mode on production Windows hosts.'
    $path = Join-Path $stateDir 'client-identity.key'
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $PrivatePem)
    Restrict-FrpFileAcl -Path $tmp
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Restrict-FrpFileAcl -Path $path
    return $path
}

function Read-FrpIdentityKey {
    $dpapi = Get-FrpIdentityDpapiKeyPath
    $plain = Get-FrpIdentityPlainKeyPath
    if (Test-Path -LiteralPath $dpapi) {
        if (-not (Test-FrpIsWindowsHost)) {
            throw 'ERROR: DPAPI identity blob present on non-Windows host; cannot decrypt'
        }
        [void](Initialize-FrpDpapi)
        $protected = [System.IO.File]::ReadAllBytes($dpapi)
        try {
            $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $protected, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        } catch {
            $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    if (Test-FrpEnforceWindowsIdentityPolicy) {
        # Fail closed: never silently consume plaintext under Windows identity policy.
        if (Test-Path -LiteralPath $plain) {
            throw 'ERROR: plaintext client-identity.key is not accepted on Windows; use DPAPI (.dpapi) or ConvertTo-FrpDpapiIdentity'
        }
        throw 'ERROR: management identity is missing'
    }
    if (Test-Path -LiteralPath $plain) {
        return [System.IO.File]::ReadAllText($plain)
    }
    throw 'ERROR: management identity is missing'
}

function ConvertTo-FrpDpapiIdentity {
    <#
    .SYNOPSIS
      Explicit one-shot migration: plaintext identity -> DPAPI. Never called from Read.
    #>
    if (-not (Test-FrpIsWindowsHost)) {
        throw 'ERROR: DPAPI migration is only supported on Windows'
    }
    $plain = Get-FrpIdentityPlainKeyPath
    $dpapi = Get-FrpIdentityDpapiKeyPath
    if (Test-Path -LiteralPath $dpapi) {
        throw 'ERROR: DPAPI identity already exists; refuse to overwrite'
    }
    if (-not (Test-Path -LiteralPath $plain)) {
        throw 'ERROR: plaintext client-identity.key not found'
    }
    $aclResult = Test-FrpIdentityKeyAcl -Path $plain
    if ($aclResult -ne 'PASS') {
        throw ("ERROR: plaintext identity ACL is not secure ({0}); refuse migration" -f $aclResult)
    }
    $pem = [System.IO.File]::ReadAllText($plain)
    if ([string]::IsNullOrWhiteSpace($pem)) {
        throw 'ERROR: plaintext identity is empty'
    }
    $saved = Save-FrpIdentityKey -PrivatePem $pem
    $roundTrip = Read-FrpIdentityKey
    if ($roundTrip -ne $pem) {
        if (Test-Path -LiteralPath $saved) {
            Remove-Item -LiteralPath $saved -Force -ErrorAction SilentlyContinue
        }
        throw 'ERROR: DPAPI round-trip mismatch; plaintext retained'
    }
    Restrict-FrpFileAcl -Path $saved
    Remove-Item -LiteralPath $plain -Force
    return $saved
}

function Get-FrpMutationLockTimeoutMs {
    if ($env:FRP_WINDOWS_MUTATION_LOCK_MS -and $env:FRP_WINDOWS_MUTATION_LOCK_MS.Trim().Length -gt 0) {
        try { return [int]$env:FRP_WINDOWS_MUTATION_LOCK_MS } catch { }
    }
    return 30000
}

function Get-FrpMutationMutexName {
    if (Test-FrpIsWindowsHost) {
        return 'Global\FrpAutoDeployClientMutation'
    }
    # .NET on non-Windows: avoid backslash in mutex names.
    return 'FrpAutoDeployClientMutation'
}

function Get-FrpMutationLockFilePath {
    return (Join-Path (Get-FrpWindowsRoot) 'client-mutation.lock')
}

function Invoke-FrpWithMutationLock {
    <#
    .SYNOPSIS
      Exclusive lock around client mutations (update/pause/resume/restart/uninstall/install).
      Windows: named Mutex. Non-Windows test hosts: exclusive lock file (named Mutex is not
      cross-process on Unix).
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [int]$TimeoutMs = -1
    )
    if ($TimeoutMs -lt 0) { $TimeoutMs = Get-FrpMutationLockTimeoutMs }

    if (-not (Test-FrpIsWindowsHost)) {
        Initialize-FrpDirectories
        $lockPath = Get-FrpMutationLockFilePath
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        $stream = $null
        while ($true) {
            try {
                $stream = [System.IO.File]::Open(
                    $lockPath,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::None
                )
                break
            } catch {
                if ([DateTime]::UtcNow -ge $deadline) {
                    throw 'ERROR: another frp-auto-deploy client mutation is in progress; try again later'
                }
                Start-Sleep -Milliseconds 50
            }
        }
        try {
            return & $Script
        } finally {
            if ($null -ne $stream) {
                try { $stream.Dispose() } catch { }
            }
        }
    }

    $mutex = $null
    $acquired = $false
    try {
        $createdNew = $false
        $name = Get-FrpMutationMutexName
        $mutex = New-Object System.Threading.Mutex($false, $name, [ref]$createdNew)
        try {
            $acquired = $mutex.WaitOne($TimeoutMs)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw 'ERROR: another frp-auto-deploy client mutation is in progress; try again later'
        }
        return & $Script
    } finally {
        if ($acquired -and $null -ne $mutex) {
            try { [void]$mutex.ReleaseMutex() } catch { }
        }
        if ($null -ne $mutex) {
            try { $mutex.Dispose() } catch { }
        }
    }
}

function Remove-FrpOldUpdateBackups {
    param([int]$Keep = 5)
    if ($Keep -lt 1) { $Keep = 1 }
    $root = Get-FrpBackupDir
    if (-not (Test-Path -LiteralPath $root)) { return }
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'update-*' } |
        Sort-Object -Property Name)
    $extra = $dirs.Count - $Keep
    if ($extra -le 0) { return }
    for ($i = 0; $i -lt $extra; $i++) {
        Remove-Item -LiteralPath $dirs[$i].FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-FrpUpdateBackupSnapshot {
    <#
    .SYNOPSIS
      Create ACL-hardened update-* backup dir, then copy sensitive files.
      Aborts before any copy if directory ACL hardening fails.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$SnapshotMap
    )
    Initialize-FrpDirectories
    $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $backupRoot = Join-Path (Get-FrpBackupDir) ("update-" + $stamp)
    if (Test-Path -LiteralPath $backupRoot) {
        throw ("ERROR: update backup path already exists: {0}" -f $backupRoot)
    }
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    # Restrict dir ACL BEFORE copying secrets (frpc.toml etc.).
    try {
        Restrict-FrpDirectoryAcl -Path $backupRoot
    } catch {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    foreach ($name in @($SnapshotMap.Keys)) {
        $src = [string]$SnapshotMap[$name]
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dest = Join-Path $backupRoot $name
        Copy-Item -LiteralPath $src -Destination $dest -Force
        Restrict-FrpFileAcl -Path $dest
    }
    Remove-FrpOldUpdateBackups -Keep 5
    return $backupRoot
}

function Save-FrpIdentityPublic {
    param([Parameter(Mandatory = $true)][string]$PublicPem)
    Initialize-FrpDirectories
    $path = Get-FrpIdentityPubPath
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $PublicPem)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Save-FrpIdentityMac {
    param([Parameter(Mandatory = $true)][string]$MacKeyHex)
    Initialize-FrpDirectories
    $path = Get-FrpIdentityMacPath
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $MacKeyHex.Trim() + "`n")
    Restrict-FrpFileAcl -Path $tmp
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Restrict-FrpFileAcl -Path $path
}

function Read-FrpIdentityMac {
    $path = Get-FrpIdentityMacPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw 'ERROR: management MAC key is missing'
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function ConvertTo-FrpServiceMap {
    param($Services)
    $map = [ordered]@{}
    if ($null -eq $Services) { return $map }
    if ($Services -is [System.Collections.IDictionary]) {
        foreach ($k in $Services.Keys) {
            $item = $Services[$k]
            $rec = ConvertTo-FrpServiceRecord -Item $item -DefaultId ([string]$k)
            $map[$rec.id] = $rec
        }
        return $map
    }
    # ConvertFrom-Json object map: { rdp = {...}; ssh = {...} }
    if ($Services -is [System.Management.Automation.PSCustomObject] -or ($Services.PSObject -and $Services.PSObject.Properties)) {
        $props = @($Services.PSObject.Properties | Where-Object { $_.MemberType -match 'NoteProperty|Property' })
        $looksLikeMap = $false
        if ($props.Count -gt 0) {
            $first = $props[0].Value
            if ($null -ne $first -and -not ($first -is [string]) -and -not ($first -is [ValueType])) {
                $looksLikeMap = $true
            }
        }
        if ($looksLikeMap) {
            foreach ($p in $props) {
                $rec = ConvertTo-FrpServiceRecord -Item $p.Value -DefaultId ([string]$p.Name)
                $map[$rec.id] = $rec
            }
            return $map
        }
    }
    foreach ($item in @($Services)) {
        $rec = ConvertTo-FrpServiceRecord -Item $item -DefaultId $null
        $map[$rec.id] = $rec
    }
    return $map
}

function ConvertTo-FrpServiceRecord {
    param($Item, $DefaultId)
    $ht = @{}
    if ($Item -is [System.Collections.IDictionary]) {
        foreach ($k in $Item.Keys) { $ht[[string]$k] = $Item[$k] }
    } else {
        foreach ($p in $Item.PSObject.Properties) { $ht[$p.Name] = $p.Value }
    }
    $sid = [string]$ht['id']
    if (-not $sid) { $sid = [string]$DefaultId }
    if (-not $sid) { throw 'ERROR: service id is required' }
    $preset = [string]$ht['preset']
    if (-not $preset) { $preset = 'custom' }
    $preset = $preset.Trim().ToLowerInvariant()
    # Client-side convenience: rdp is a first-class TCP 3389 preset.
    if ($preset -eq 'rdp') {
        if (-not $ht['local_port']) { $ht['local_port'] = 3389 }
        if (-not $ht['local_ip']) { $ht['local_ip'] = '127.0.0.1' }
        if (-not $ht['name']) { $ht['name'] = 'RDP' }
    }
    $rec = [ordered]@{
        id         = $sid.ToLowerInvariant()
        name       = $(if ($ht['name']) { [string]$ht['name'] } else { $sid })
        preset     = $preset
        protocol   = 'tcp'
        local_ip   = $(if ($ht['local_ip']) { [string]$ht['local_ip'] } else { '127.0.0.1' })
        local_port = [int]$ht['local_port']
        enabled    = $(if ($null -eq $ht['enabled']) { $true } else { [bool]$ht['enabled'] })
    }
    if ($null -ne $ht['remote_port'] -and [string]$ht['remote_port'] -ne '') {
        $rec['remote_port'] = [int]$ht['remote_port']
    }
    if ($preset -eq 'ssh' -and $ht['ssh_user']) {
        $rec['ssh_user'] = [string]$ht['ssh_user']
    }
    return $rec
}

function Get-FrpEnrollServiceList {
    <#
    .SYNOPSIS
      Build enrollment request service objects (rdp is a first-class server preset).
    #>
    param($Services)
    $list = New-Object System.Collections.ArrayList
    $map = ConvertTo-FrpServiceMap -Services $Services
    foreach ($sid in $map.Keys) {
        $item = $map[$sid]
        if ($item.enabled -eq $false) { continue }
        $preset = [string]$item.preset
        $out = [ordered]@{
            id         = [string]$item.id
            name       = [string]$item.name
            protocol   = 'tcp'
            local_ip   = [string]$item.local_ip
            local_port = [int]$item.local_port
            preset     = $preset
        }
        if ($preset -eq 'ssh' -and $item.ssh_user) {
            $out['ssh_user'] = [string]$item.ssh_user
        }
        [void]$list.Add([pscustomobject]$out)
    }
    return ,$list.ToArray()
}

function Save-FrpClientState {
    param(
        [Parameter(Mandatory = $true)][string]$AllocatorUrl,
        [Parameter(Mandatory = $true)][string]$FrpServer,
        [Parameter(Mandatory = $true)][int]$FrpServerPort,
        [Parameter(Mandatory = $true)][string]$Hostname,
        [Parameter(Mandatory = $true)][string]$MachineId,
        [Parameter(Mandatory = $true)][string]$HostId,
        [Parameter(Mandatory = $true)]$Services,
        [string]$Transport = 'tcp',
        [string]$ProjectVersion,
        [string]$FrpVersion,
        [string]$InstallStatus,
        $ManagementTimeOffsetSec = $null
    )
    Initialize-FrpDirectories
    $transport = ([string]$Transport).Trim().ToLowerInvariant()
    if (-not $transport) { $transport = 'tcp' }
    if ($transport -ne 'tcp' -and $transport -ne 'wss') {
        throw 'ERROR: unsupported FRP transport'
    }
    $map = ConvertTo-FrpServiceMap -Services $Services
    # Ensure no secrets in state
    foreach ($sid in @($map.Keys)) {
        foreach ($bad in @('token', 'secret', 'enrollment_secret', 'private_key', 'token_ciphertext')) {
            if ($map[$sid].Contains($bad)) {
                throw 'ERROR: client-state.json must not contain secrets'
            }
        }
    }
    $enabledAny = $false
    foreach ($sid in $map.Keys) {
        if ($map[$sid].enabled -ne $false) { $enabledAny = $true; break }
    }
    $state = [ordered]@{
        schema_version   = 1
        allocator_url    = $AllocatorUrl
        frp_server       = $FrpServer
        frp_server_port  = [int]$FrpServerPort
        frp_transport    = $transport
        hostname         = $Hostname
        machine_id       = $MachineId
        host_id          = $HostId
        services         = $map
        management_only  = (-not $enabledAny)
        project_version  = $(if ($ProjectVersion) { $ProjectVersion } else { Get-FrpProjectVersion })
        frp_version      = $(if ($FrpVersion) { $FrpVersion } else { Get-FrpUpstreamVersion })
        platform         = 'windows'
        install_status   = $(if ($InstallStatus) { $InstallStatus } elseif (-not $enabledAny) { 'management_only' } else { 'installed' })
    }
    $offset = $null
    if (Get-Command Test-FrpValidateOffset -ErrorAction SilentlyContinue) {
        $offset = Test-FrpValidateOffset -Value $ManagementTimeOffsetSec
    } elseif ($null -ne $ManagementTimeOffsetSec) {
        try { $offset = [int64]$ManagementTimeOffsetSec } catch { $offset = $null }
    }
    if ($null -ne $offset) {
        $state['management_time_offset_sec'] = [int64]$offset
    }
    $path = Get-FrpStatePath
    $json = Get-FrpCanonicalJson -Object $state
    # Pretty-print for operators (canonical used only for crypto). Use ConvertTo-Json carefully.
    $pretty = ($state | ConvertTo-Json -Depth 8)
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $pretty + "`n")
    Restrict-FrpFileAcl -Path $tmp
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Restrict-FrpFileAcl -Path $path
    return $path
}

function Read-FrpClientState {
    $path = Get-FrpStatePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw 'ERROR: client-state.json is missing'
    }
    $raw = [System.IO.File]::ReadAllText($path)
    return ($raw | ConvertFrom-Json)
}



function Get-FrpInstallStatus {
    if (-not (Test-Path -LiteralPath (Get-FrpStatePath))) { return $null }
    try {
        $state = Read-FrpClientState
        return [string]$state.install_status
    } catch {
        return $null
    }
}

function Set-FrpInstallStatus {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('enrolling', 'enrolled_incomplete', 'installed', 'management_only')]
        [string]$Status
    )
    $path = Get-FrpStatePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw 'ERROR: client-state.json is missing; cannot set install_status'
    }
    $state = Read-FrpClientState
    $ht = ConvertTo-FrpPlainObject $state
    $ht['install_status'] = $Status
    if ($Status -eq 'management_only') {
        $ht['management_only'] = $true
    }
    $pretty = ($ht | ConvertTo-Json -Depth 8)
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $pretty + "`n")
    Restrict-FrpFileAcl -Path $tmp
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Restrict-FrpFileAcl -Path $path
}

function Test-FrpIsInstallComplete {
    $status = Get-FrpInstallStatus
    return ($status -eq 'installed' -or $status -eq 'management_only')
}

function Test-FrpCanResumeInstall {
    if (-not (Test-FrpIsEnrolled)) { return $false }
    $status = Get-FrpInstallStatus
    return ($status -eq 'enrolled_incomplete')
}

function Save-FrpEnrollRecovery {
    <#
    .SYNOPSIS
      Persist zero-touch post-redeem recovery journal (no bootstrap ticket).
      Windows: DPAPI-sealed blob + secret ACL. Non-Windows tests: plaintext 0600.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AllocatorUrl,
        [Parameter(Mandatory = $true)][string]$MachineId,
        [Parameter(Mandatory = $true)][string]$Hostname,
        [Parameter(Mandatory = $true)][string]$EnrollmentId,
        [Parameter(Mandatory = $true)][string]$EnrollmentSecret,
        [Parameter(Mandatory = $true)]$Services,
        [string]$CaSha256,
        [string]$IdentityKeyRef
    )
    Initialize-FrpDirectories
    if ([string]::IsNullOrWhiteSpace($EnrollmentId) -or [string]::IsNullOrWhiteSpace($EnrollmentSecret)) {
        throw 'ERROR: recovery journal requires enrollment credentials'
    }
    if ([string]::IsNullOrWhiteSpace($MachineId) -or [string]::IsNullOrWhiteSpace($AllocatorUrl)) {
        throw 'ERROR: recovery journal requires machine_id and allocator_url'
    }
    $payload = [ordered]@{
        schema_version     = 1
        allocator_url      = $AllocatorUrl
        machine_id         = $MachineId
        hostname           = $Hostname
        enrollment_id      = $EnrollmentId
        enrollment_secret  = $EnrollmentSecret
        services           = @($Services)
        ca_sha256          = $(if ($CaSha256) { $CaSha256.Trim().ToLowerInvariant() } else { '' })
        identity_key_ref   = $(if ($IdentityKeyRef) { $IdentityKeyRef } else { (Get-FrpIdentityKeyPath) })
    }
    $json = ($payload | ConvertTo-Json -Depth 8) + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    if (Initialize-FrpDpapi) {
        $path = Get-FrpEnrollRecoveryDpapiPath
        $scope = [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        try {
            $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, $scope)
        } catch {
            $protected = [System.Security.Cryptography.ProtectedData]::Protect(
                $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllBytes($tmp, $protected)
        Restrict-FrpFileAcl -Path $tmp
        Move-Item -LiteralPath $tmp -Destination $path -Force
        Restrict-FrpFileAcl -Path $path
        # Remove any leftover plaintext journal.
        $plain = Get-FrpEnrollRecoveryPlainPath
        if (Test-Path -LiteralPath $plain) {
            Remove-Item -LiteralPath $plain -Force -ErrorAction SilentlyContinue
        }
        return $path
    }

    if (Test-FrpIsWindowsHost) {
        throw 'ERROR: DPAPI required to persist enroll recovery journal on Windows; no plaintext fallback'
    }
    Write-Warning 'DPAPI unavailable; storing enroll recovery journal as a plain file under the test root. Do not use this mode on production Windows hosts.'
    $path = Get-FrpEnrollRecoveryPlainPath
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json)
    Restrict-FrpFileAcl -Path $tmp
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Restrict-FrpFileAcl -Path $path
    return $path
}

function Read-FrpEnrollRecovery {
    <#
    .SYNOPSIS
      Load recovery journal. Fail closed on corrupt/malformed/missing required fields.
      Must not contain a bootstrap ticket.
    #>
    $dpapi = Get-FrpEnrollRecoveryDpapiPath
    $plain = Get-FrpEnrollRecoveryPlainPath
    $raw = $null

    if (Test-Path -LiteralPath $dpapi) {
        if (-not (Test-FrpIsWindowsHost)) {
            throw 'ERROR: DPAPI recovery journal present on non-Windows host; cannot decrypt'
        }
        [void](Initialize-FrpDpapi)
        $protected = [System.IO.File]::ReadAllBytes($dpapi)
        try {
            $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $protected, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        } catch {
            $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
    } elseif (Test-Path -LiteralPath $plain) {
        if (Test-FrpIsWindowsHost) {
            throw 'ERROR: plaintext enroll-recovery.json is not accepted on Windows; DPAPI required'
        }
        $raw = [System.IO.File]::ReadAllText($plain)
    } else {
        throw 'ERROR: enroll recovery journal is missing'
    }

    try {
        $data = $raw | ConvertFrom-Json
    } catch {
        throw 'ERROR: enroll recovery journal is not valid JSON'
    }
    if ($null -eq $data -or $data -isnot [System.Management.Automation.PSObject]) {
        throw 'ERROR: enroll recovery journal is malformed'
    }
    if ([int]$data.schema_version -ne 1) {
        throw 'ERROR: unsupported enroll recovery journal schema'
    }
    foreach ($bad in @('bootstrap_ticket', 'ticket', 'FRP_BOOTSTRAP_TICKET')) {
        if ($data.PSObject.Properties.Name -contains $bad -and $data.$bad) {
            throw 'ERROR: enroll recovery journal must not contain a bootstrap ticket'
        }
    }
    foreach ($req in @('allocator_url', 'machine_id', 'enrollment_id', 'enrollment_secret')) {
        if (($data.PSObject.Properties.Name -notcontains $req) -or
            [string]::IsNullOrWhiteSpace([string]$data.$req)) {
            throw ("ERROR: enroll recovery journal missing {0}" -f $req)
        }
    }
    if (($data.PSObject.Properties.Name -notcontains 'services') -or ($null -eq $data.services)) {
        throw 'ERROR: enroll recovery journal missing services'
    }
    return @{
        AllocatorUrl     = [string]$data.allocator_url
        MachineId        = [string]$data.machine_id
        Hostname         = [string]$data.hostname
        EnrollmentId     = [string]$data.enrollment_id
        EnrollmentSecret = [string]$data.enrollment_secret
        Services         = @($data.services)
        CaSha256         = [string]$data.ca_sha256
        IdentityKeyRef   = [string]$data.identity_key_ref
    }
}

function Remove-FrpEnrollRecovery {
    foreach ($path in @((Get-FrpEnrollRecoveryDpapiPath), (Get-FrpEnrollRecoveryPlainPath))) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-FrpHasEnrollRecovery {
    return (
        (Test-Path -LiteralPath (Get-FrpEnrollRecoveryDpapiPath)) -or
        (Test-Path -LiteralPath (Get-FrpEnrollRecoveryPlainPath))
    )
}

function Test-FrpCanResumeFromRecovery {
    if (-not (Test-FrpHasEnrollRecovery)) { return $false }
    if (Test-FrpIsEnrolled) { return $false }
    try {
        $rec = Read-FrpEnrollRecovery
        if ([string]::IsNullOrWhiteSpace($rec.EnrollmentId) -or
            [string]::IsNullOrWhiteSpace($rec.EnrollmentSecret) -or
            [string]::IsNullOrWhiteSpace($rec.MachineId)) {
            return $false
        }
        return $true
    } catch {
        # Present but corrupt: caller should fail closed, not treat as absent.
        throw
    }
}

function Get-FrpEnabledServiceCount {
    param($Services)
    if ($null -eq $Services) { return 0 }
    $map = ConvertTo-FrpServiceMap -Services $Services
    $n = 0
    foreach ($sid in $map.Keys) {
        if ($map[$sid].enabled -ne $false) { $n++ }
    }
    return $n
}

function Merge-FrpAllocatedPorts {
    param($LocalServices, $AllocatedList)
    $map = ConvertTo-FrpServiceMap -Services $LocalServices
    foreach ($a in @($AllocatedList)) {
        $sid = [string]$a.id
        if (-not $map.Contains($sid)) { continue }
        $map[$sid]['remote_port'] = [int]$a.remote_port
    }
    return $map
}
