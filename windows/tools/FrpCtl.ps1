#Requires -Version 5.1
<#
.SYNOPSIS
  Canonical Windows frpctl entry (lifecycle + frp-client passthrough).
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'

function Import-FrpCtlModules {
    $libDir = Join-Path $PSScriptRoot '..\lib'
    foreach ($mod in @(
            'FrpPaths.ps1', 'FrpCrypto.ps1', 'FrpTls.ps1', 'FrpState.ps1',
            'FrpConfig.ps1', 'FrpProcess.ps1', 'FrpBootstrap.ps1', 'FrpLifecycle.ps1'
        )) {
        . (Join-Path $libDir $mod)
    }
}

Import-FrpCtlModules

$cmd = if ($Args.Count -gt 0) { $Args[0].ToLowerInvariant() } else { 'help' }
$rest = @()
if ($Args.Count -gt 1) { $rest = $Args[1..($Args.Count - 1)] }

switch ($cmd) {
    'pause' { exit (Invoke-FrpPauseRemoteAccess) }
    'resume' { exit (Invoke-FrpResumeRemoteAccess) }
    'restart' { exit (Invoke-FrpRestartConnection) }
    'test' { exit (Invoke-FrpClientTest) }
    'logs' {
        $lines = 100
        $follow = $false
        for ($i = 0; $i -lt $rest.Count; $i++) {
            if ($rest[$i] -eq '--lines' -and ($i + 1) -lt $rest.Count) {
                $lines = [int]$rest[$i + 1]
                $i++
            } elseif ($rest[$i] -eq '--follow') {
                $follow = $true
            }
        }
        exit (Show-FrpClientLogs -Lines $lines -Follow:$follow)
    }
    'support-bundle' {
        $anon = $rest -contains '--anonymize'
        exit (Invoke-FrpSupportBundle -Anonymize:$anon)
    }
    'uninstall' {
        $yes = $rest -contains '--yes'
        if (-not $yes) {
            @'
Uninstall FRP Auto Deploy from this client?

This will:
  - stop remote FRP access
  - disable automatic startup
  - remove local FRP software
  - remove local management identity
  - remove local configuration/state

This will NOT:
  - delete the server-side Client record
  - release public port reservations
  - delete server-side Groups/Tags/Audit history

Type "uninstall" to continue:
'@ | Write-Host
            $confirm = Read-Host
            if ($confirm -ne 'uninstall') {
                Write-Host 'Uninstall cancelled.'
                exit 1
            }
        }
        & (Join-Path $PSScriptRoot 'FrpClient.ps1') uninstall
        exit $LASTEXITCODE
    }
    'status' {
        if (Test-FrpRemoteAccessPaused) {
            Write-Host 'Remote access : PAUSED'
            Write-Host 'frpc          : stopped'
        } else {
            Write-Host 'Remote access : ACTIVE'
        }
        & (Join-Path $PSScriptRoot 'FrpClient.ps1') status
        exit $LASTEXITCODE
    }
    'help' {
        @'
frpctl (Windows)

  pause | resume | restart
  test | logs [--lines N] [--follow]
  support-bundle [--anonymize]
  uninstall [--yes]
  status

frpcli is an alias for frpctl.
'@ | Write-Host
        exit 0
    }
    default {
        & (Join-Path $PSScriptRoot 'FrpClient.ps1') @Args
        exit $LASTEXITCODE
    }
}
