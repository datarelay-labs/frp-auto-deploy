# test-zero-touch-command.ps1 — validate installer parameter patterns + compact join launcher
$ErrorActionPreference = 'Stop'

function Assert-FrpTrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}
function Write-FrpTestPass { param([string]$Name) Write-Host "PASS $Name" }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$install = Join-Path $root 'windows\install-client.ps1'
Assert-FrpTrue (Test-Path -LiteralPath $install) 'install-client.ps1 exists'
$text = Get-Content -LiteralPath $install -Raw
Assert-FrpTrue ($text -match 'ZeroTouch') 'ZeroTouch param'
Assert-FrpTrue ($text -match 'AllocatorUrl') 'AllocatorUrl param'
Assert-FrpTrue ($text -match 'CaSha256') 'CaSha256 param'
Assert-FrpTrue ($text -match 'BootstrapTicket') 'BootstrapTicket param'
Assert-FrpTrue ($text -notmatch '(?i)Invoke-RestMethod\s*\|\s*Invoke-Expression') 'no irm|iex invocation'
Assert-FrpTrue ($text -match 'No irm\|iex' -or $text -match 'never.*irm') 'documents no irm|iex'

$boot = Get-Content -LiteralPath (Join-Path $root 'windows\lib\FrpBootstrap.ps1') -Raw
Assert-FrpTrue ($boot -match 'already enrolled') 'enroll once messaging'
Assert-FrpTrue ($boot -match 'Clear-FrpSecretEnv') 'secret env cleanup'
Assert-FrpTrue ($boot -match 'ProgramData\\frp-auto-deploy\\tools\\frp-client\.cmd' -or $boot -match 'Get-FrpToolsDir') 'full tools path guidance'

$join = Join-Path $root 'windows\windows-join.ps1'
Assert-FrpTrue (Test-Path -LiteralPath $join) 'windows-join.ps1 exists'
$joinText = Get-Content -LiteralPath $join -Raw
Assert-FrpTrue ($joinText -match 'frpj1\.') 'join descriptor prefix'
Assert-FrpTrue ($joinText -match '-File') 'join uses -File'
Assert-FrpTrue ($joinText -notmatch '(?i)Invoke-Expression') 'join no iex'
Assert-FrpTrue ($joinText -match 'SHA256SUMS') 'join verifies SHA256SUMS'
Assert-FrpTrue ($joinText -match 'FRP_RELEASE_CHANNEL') 'join propagates channel'
Assert-FrpTrue ($joinText -match 'FRP_SOURCE_REF') 'join propagates source ref'

$tls = Get-Content -LiteralPath (Join-Path $root 'windows\lib\FrpTls.ps1') -Raw
Assert-FrpTrue ($tls -match 'ExpectedHost') 'dotnet TLS uses explicit ExpectedHost'
Assert-FrpTrue ($tls -match 'Get-FrpWebExceptionDetail') 'dotnet TLS diagnostic helper'
Assert-FrpTrue ($tls -match 'FRP_WINDOWS_FORCE_DOTNET_HTTP') 'force .NET HTTP env hook present'

Write-FrpTestPass 'test-zero-touch-command'
