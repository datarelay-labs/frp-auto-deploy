# run-all.ps1 — Windows client test suite.
# Preserves the host engine: Windows PowerShell 5.1 uses powershell.exe;
# PowerShell 7+ / Linux CI uses pwsh. Do not hard-code pwsh.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$failed = 0
$passed = 0
$skipped = 0

function Get-FrpHostPowerShellExe {
    try {
        $procPath = (Get-Process -Id $PID -ErrorAction Stop).Path
        if ($procPath) { return $procPath }
    } catch { }
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return 'powershell.exe'
    }
    return 'pwsh'
}

$hostExe = Get-FrpHostPowerShellExe
Write-Host ("Host PowerShell engine : {0}" -f $hostExe)
Write-Host ("Host PowerShell version: {0}" -f $PSVersionTable.PSVersion)
Write-Host ("Host PSEdition         : {0}" -f $PSVersionTable.PSEdition)

$tests = @(
    'test-crypto.ps1',
    'test-token-decrypt.ps1',
    'test-canonical-sign.ps1',
    'test-config.ps1',
    'test-security.ps1',
    'test-tls-hostname-negative.ps1',
    'test-persistence.ps1',
    'test-dpapi-identity-roundtrip.ps1',
    'test-process-control.ps1',
    'test-zero-touch-command.ps1',
    'test-rdp-service.ps1',
    'test-zero-service.ps1',
    'test-install-start-failure.ps1',
    'test-partial-resume.ps1',
    'test-update-rollback.ps1',
    'test-pid-ownership.ps1',
    'test-acl-fail-closed.ps1',
    'test-multi-service.ps1',
    'test-ca-pinning.ps1',
    'test-clock-skew.ps1',
    'test-uninstall.ps1',
    'test-support-bundle.ps1',
    'test-logs-redaction.ps1',
    'test-identity-acl-diagnostic.ps1',
    'test-cross-language.ps1'
)


Write-Host '=== frp-auto-deploy Windows client tests ==='
foreach ($t in $tests) {
    $path = Join-Path $root $t
    Write-Host ""
    Write-Host "--- $t ---"
    try {
        $output = & $hostExe -NoProfile -File $path 2>&1
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        $output | ForEach-Object { Write-Host $_ }
        if ($code -ne 0) {
            Write-Host "FAIL $t (exit $code)"
            $tail = (($output | Out-String) -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 12) -join ' | '
            Write-Host ("::error file=tests/windows/{0}::FAIL {0} exit={1} :: {2}" -f $t, $code, $tail)
            $failed++
        } else {
            $passed++
        }
    } catch {
        Write-Host "FAIL $t : $($_.Exception.Message)"
        Write-Host ("::error file=tests/windows/{0}::FAIL {0} exception :: {1}" -f $t, $_.Exception.Message)
        $failed++
    }
}

Write-Host ''
Write-Host ("Summary: passed={0} failed={1}" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
