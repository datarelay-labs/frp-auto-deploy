# test-mutation-lock.ps1 — exclusive mutation lock (update/uninstall/pause)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
$blocker = $null
try {
    $env:FRP_WINDOWS_MUTATION_LOCK_MS = '500'
    $winLib = $script:WindowsLib
    $testRoot = Get-FrpWindowsRoot
    $ready = Join-Path $testRoot 'mutation-lock-ready'
    $lockPath = Get-FrpMutationLockFilePath

    # Hold the lock on a background job so this thread cannot reenter.
    $blocker = Start-Job -ScriptBlock {
        param($TestRoot, $LibDir, $ReadyPath)
        $env:FRP_WINDOWS_ROOT = $TestRoot
        foreach ($mod in @(
                'FrpPaths.ps1', 'FrpCrypto.ps1', 'FrpTls.ps1', 'FrpClockSync.ps1', 'FrpState.ps1',
                'FrpConfig.ps1', 'FrpProcess.ps1', 'FrpBootstrap.ps1', 'FrpLifecycle.ps1'
            )) {
            . (Join-Path $LibDir $mod)
        }
        Invoke-FrpWithMutationLock -TimeoutMs 30000 -Script {
            # Prove the lock file is open exclusively before signaling.
            Set-Content -LiteralPath $ReadyPath -Value ((Get-Date).ToString('o'))
            Start-Sleep -Seconds 8
        }
    } -ArgumentList @($testRoot, $winLib, $ready)

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $ready)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            $jobOut = Receive-Job $blocker -ErrorAction SilentlyContinue | Out-String
            throw ("blocker never signaled lock held; state={0}; out={1}" -f $blocker.State, $jobOut)
        }
        Start-Sleep -Milliseconds 50
    }
    Assert-FrpEqual 'Running' ([string]$blocker.State) 'blocker job holds lock'
    Assert-FrpTrue (Test-Path -LiteralPath $lockPath) 'lock file exists while held'

    # update vs update — allow a couple retries for scheduler jitter, but require eventual reject.
    $threwUpdate = $false
    $lastErr = ''
    for ($i = 0; $i -lt 5; $i++) {
        try {
            Invoke-FrpWithMutationLock -TimeoutMs 300 -Script { 'should-not-run' } | Out-Null
        } catch {
            $threwUpdate = $true
            $lastErr = [string]$_.Exception.Message
            break
        }
        Start-Sleep -Milliseconds 100
    }
    Assert-FrpTrue $threwUpdate ("WINDOWS_MUTATION_LOCK update vs update (err=$lastErr)")
    Assert-FrpTrue ($lastErr -match 'mutation is in progress') 'clear operator error'
    Write-FrpTestPass 'WINDOWS_MUTATION_LOCK update vs update'

    # update vs uninstall
    $rcUninstall = Invoke-FrpClientUninstall
    Assert-FrpEqual 1 $rcUninstall 'uninstall blocked by mutation lock'
    Write-FrpTestPass 'WINDOWS_MUTATION_LOCK update vs uninstall'

    # update vs pause
    $rcPause = Invoke-FrpPauseRemoteAccess
    Assert-FrpEqual 1 $rcPause 'pause blocked by mutation lock'
    Write-FrpTestPass 'WINDOWS_MUTATION_LOCK update vs pause'

    # Read-only paths do not need the lock
    $st = Get-FrpClientStatus
    Assert-FrpTrue ($null -ne $st) 'status works without exclusive lock'

    Wait-Job $blocker -Timeout 20 | Out-Null
    Receive-Job $blocker -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $blocker -Force -ErrorAction SilentlyContinue
    $blocker = $null

    $ok = Invoke-FrpWithMutationLock -TimeoutMs 3000 -Script { 'ok' }
    Assert-FrpEqual 'ok' $ok 'mutation succeeds after release'

    Write-FrpTestPass 'WINDOWS_MUTATION_LOCK'
} finally {
    if ($null -ne $blocker) {
        try { Stop-Job $blocker -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Job $blocker -Force -ErrorAction SilentlyContinue } catch { }
    }
    Remove-Item Env:FRP_WINDOWS_MUTATION_LOCK_MS -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
