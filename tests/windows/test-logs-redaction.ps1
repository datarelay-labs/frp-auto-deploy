# test-logs-redaction.ps1 — frpctl logs must redact secrets (normal + follow fixture)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    $log = Join-Path (Get-FrpLogsDir) 'frpc.log'
    @(
        'auth.token = SUPERSECRETTOKEN123',
        'password=hunter2',
        'Authorization: Bearer abc.def',
        'Enrollment Code: deadbeefcafebabe',
        'bootstrap_ticket=btck.0123456789abcdef.payload',
        'normal line ok'
    ) | Set-Content -LiteralPath $log

    $out = Show-FrpClientLogs -Lines 50 | Out-String
    Assert-FrpTrue ($out -notmatch 'SUPERSECRETTOKEN123') 'token redacted'
    Assert-FrpTrue ($out -notmatch 'hunter2') 'password redacted'
    Assert-FrpTrue ($out -notmatch 'Bearer abc') 'Authorization redacted'
    Assert-FrpTrue ($out -notmatch 'deadbeefcafebabe') 'enrollment code redacted'
    Assert-FrpTrue ($out -notmatch 'btck\.0123456789abcdef') 'bootstrap ticket redacted'
    Assert-FrpTrue ($out -match 'normal line ok') 'benign line present'
    Assert-FrpTrue ($out -match '\[redacted\]') 'redaction markers present'

    $followOut = Get-Content -LiteralPath $log | ForEach-Object {
        Protect-FrpRedactText -Text ([string]$_)
    } | Out-String
    Assert-FrpTrue ($followOut -notmatch 'SUPERSECRETTOKEN123|hunter2|deadbeefcafebabe') 'follow redaction'
    Write-FrpTestPass 'WINDOWS_LOGS_REDACTION'
} finally {
    Remove-FrpWindowsTestRoot
}
