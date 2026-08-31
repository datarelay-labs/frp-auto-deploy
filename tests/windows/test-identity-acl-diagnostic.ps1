# test-identity-acl-diagnostic.ps1 — Identity permissions validate ACL, not mere existence
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    $key = Get-FrpIdentityKeyPath
    Assert-FrpEqual 'FAIL' (Test-FrpIdentityKeyAcl -Path $key) 'missing key FAIL'

    Set-Content -LiteralPath $key -Value 'secret-key-material' -NoNewline
    Restrict-FrpFileAcl -Path $key
    Assert-FrpEqual 'PASS' (Test-FrpIdentityKeyAcl -Path $key) 'secure ACL PASS'

    $env:FRP_WINDOWS_FORCE_ACL_INSECURE = '1'
    Assert-FrpEqual 'FAIL' (Test-FrpIdentityKeyAcl -Path $key) 'insecure FAIL'
    Remove-Item Env:FRP_WINDOWS_FORCE_ACL_INSECURE -ErrorAction SilentlyContinue

    $env:FRP_WINDOWS_FORCE_ACL_UNKNOWN = '1'
    Assert-FrpEqual 'UNKNOWN' (Test-FrpIdentityKeyAcl -Path $key) 'unknown UNKNOWN'
    Remove-Item Env:FRP_WINDOWS_FORCE_ACL_UNKNOWN -ErrorAction SilentlyContinue

    Write-FrpTestPass 'WINDOWS_IDENTITY_ACL_DIAGNOSTIC'
} finally {
    Remove-Item Env:FRP_WINDOWS_FORCE_ACL_INSECURE -ErrorAction SilentlyContinue
    Remove-Item Env:FRP_WINDOWS_FORCE_ACL_UNKNOWN -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
