#Requires -Version 5.1
<#
.SYNOPSIS
  frp-client lifecycle tool for Windows (start/stop/status/info/update/uninstall/doctor/autostart).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'status', 'info', 'update', 'uninstall', 'doctor', 'autostart', 'help')]
    [string]$Command = 'help',

    [switch]$Check,
    [switch]$Force,
    [string]$DownloadUrl,
    [string]$ExpectedSha256
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
            'FrpPaths.ps1', 'FrpCrypto.ps1', 'FrpTls.ps1', 'FrpState.ps1',
            'FrpConfig.ps1', 'FrpProcess.ps1', 'FrpBootstrap.ps1'
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
  update      Update frpc.exe (preserve identity/ports); --check for dry run
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
    param([switch]$CheckOnly)
    $url = $DownloadUrl
    if (-not $url) { $url = Get-FrpWindowsAmd64Url }
    $sha = $ExpectedSha256
    if (-not $sha) { $sha = Get-FrpWindowsAmd64Sha256 }
    if ($CheckOnly) {
        Write-Host ("Would download: {0}" -f $url)
        Write-Host ("Expected SHA256: {0}" -f $sha)
        Write-Host 'Identity, ports, and frpc.toml token would be preserved.'
        return 0
    }
    Initialize-FrpDirectories
    $backupRoot = Join-Path (Get-FrpBackupDir) ("update-" + (Get-Date -Format 'yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($rel in @('bin\frpc.exe', 'config\frpc.toml', 'state\client-state.json', 'version')) {
        $src = Join-Path (Get-FrpWindowsRoot) $rel
        if (Test-Path -LiteralPath $src) {
            $dst = Join-Path $backupRoot (Split-Path -Leaf $rel)
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
    try {
        $wasRunning = $false
        $st = Get-FrpClientStatus
        if ($st.Running) {
            $wasRunning = $true
            Stop-FrpClient | Out-Null
        }
        Install-FrpWindowsBinary -DownloadUrl $url -ExpectedSha256 $sha | Out-Null
        # Preserve identity/ports: do not touch state or toml
        if ($wasRunning) {
            Start-FrpClient | Out-Null
        }
        Write-Host 'Update complete (identity and port reservations preserved).'
        return 0
    } catch {
        Write-Host ("ERROR: update failed: {0}" -f $_.Exception.Message)
        Write-Host 'Attempting rollback from backup...'
        try {
            $bakExe = Join-Path $backupRoot 'frpc.exe'
            if (Test-Path -LiteralPath $bakExe) {
                Copy-Item -LiteralPath $bakExe -Destination (Get-FrpFrpcPath) -Force
            }
            Write-Host 'Rollback restored frpc.exe (best effort).'
        } catch {
            Write-Host 'ERROR: rollback failed'
        }
        return 1
    }
}

function Invoke-FrpClientUninstall {
    Write-Host 'LOCAL SOFTWARE REMOVED, SERVER RESERVATIONS PRESERVED'
    Write-Host 'This removes local frpc binaries, config, state, and tools.'
    Write-Host 'Public port reservations on the server remain until an administrator revokes them.'
    try { Stop-FrpClient | Out-Null } catch { }
    $root = Get-FrpWindowsRoot
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ("Removed: {0}" -f $root)
    return 0
}

function Invoke-FrpClientDoctor {
    $issues = 0
    Write-Host 'frp-client doctor (basic)'
    Write-Host ("Root: {0}" -f (Get-FrpWindowsRoot))
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
    'update' { exit (Invoke-FrpClientUpdate -CheckOnly:$Check) }
    'uninstall' { exit (Invoke-FrpClientUninstall) }
    'doctor' { exit (Invoke-FrpClientDoctor) }
    'autostart' { exit (Invoke-FrpClientAutostart) }
    default { Show-FrpClientHelp; exit 1 }
}
