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

function Test-FrpOutputSkipped {
    param([object[]]$Output)
    foreach ($line in @($Output)) {
        $text = [string]$line
        if ($text -match '^\s*SKIP(\s|$)') {
            return $true
        }
    }
    return $false
}

$hostExe = Get-FrpHostPowerShellExe
Write-Host ("Host PowerShell engine : {0}" -f $hostExe)
Write-Host ("Host PowerShell version: {0}" -f $PSVersionTable.PSVersion)
Write-Host ("Host PSEdition         : {0}" -f $PSVersionTable.PSEdition)

# Auto-discover test-*.ps1 so newly added suites cannot be omitted silently.
$tests = @(
    Get-ChildItem -LiteralPath $root -Filter 'test-*.ps1' -File |
        Sort-Object Name |
        ForEach-Object { $_.Name }
)
if ($tests.Count -lt 1) {
    Write-Host 'FAIL: no test-*.ps1 files discovered'
    exit 1
}

Write-Host '=== frp-auto-deploy Windows client tests ==='
Write-Host ("Discovered {0} test script(s)" -f $tests.Count)
foreach ($t in $tests) {
    $path = Join-Path $root $t
    Write-Host ""
    Write-Host "--- $t ---"
    try {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $hostExe -NoProfile -File $path 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($null -eq $code) { $code = 0 }
        $output | ForEach-Object { Write-Host $_ }
        if ($code -ne 0) {
            Write-Host "FAIL $t (exit $code)"
            $tail = (($output | Out-String) -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 12) -join ' | '
            Write-Host ("::error file=tests/windows/{0}::FAIL {0} exit={1} :: {2}" -f $t, $code, $tail)
            $failed++
        } elseif (Test-FrpOutputSkipped -Output $output) {
            Write-Host "SKIP counted for $t"
            $skipped++
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
Write-Host ("Summary: passed={0} failed={1} skipped={2}" -f $passed, $failed, $skipped)
if ($failed -gt 0) { exit 1 }
exit 0
