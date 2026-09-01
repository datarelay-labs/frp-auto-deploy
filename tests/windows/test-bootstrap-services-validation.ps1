# test-bootstrap-services-validation.ps1 — redeem services field validation
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')

try {
    # Empty array: management-only accepted, do not invent RDP.
    $emptyData = '{"enrollment_code":"id.secret","services":[]}' | ConvertFrom-Json
    $empty = ConvertTo-FrpBootstrapServices -Data $emptyData
    Assert-FrpEqual 0 @($empty).Count 'empty services count'
    Assert-FrpTrue ($null -eq (@($empty) | Where-Object { $_.name -eq 'rdp' -or $_.type -eq 'rdp' })) 'no invented rdp'

    # Populated array accepted.
    $oneData = '{"enrollment_code":"id.secret","services":[{"name":"rdp","type":"tcp"}]}' | ConvertFrom-Json
    $one = ConvertTo-FrpBootstrapServices -Data $oneData
    Assert-FrpEqual 1 @($one).Count 'one service'

    # Missing services rejected.
    $missingThrown = $false
    try {
        $missingData = '{"enrollment_code":"id.secret"}' | ConvertFrom-Json
        ConvertTo-FrpBootstrapServices -Data $missingData | Out-Null
    } catch {
        $missingThrown = $_.Exception.Message -match 'missing services'
    }
    Assert-FrpTrue $missingThrown 'missing services rejected'

    # Null services rejected.
    $nullThrown = $false
    try {
        $nullData = '{"enrollment_code":"id.secret","services":null}' | ConvertFrom-Json
        ConvertTo-FrpBootstrapServices -Data $nullData | Out-Null
    } catch {
        $nullThrown = $_.Exception.Message -match 'null'
    }
    Assert-FrpTrue $nullThrown 'null services rejected'

    # String rejected.
    $strThrown = $false
    try {
        $strData = '{"enrollment_code":"id.secret","services":"oops"}' | ConvertFrom-Json
        ConvertTo-FrpBootstrapServices -Data $strData | Out-Null
    } catch {
        $strThrown = $_.Exception.Message -match 'array'
    }
    Assert-FrpTrue $strThrown 'string services rejected'

    $src = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'windows/lib/FrpBootstrap.ps1') -Raw
    Assert-FrpTrue ($src -notmatch 'services\.Count\s+-lt\s+0') 'removed Count -lt 0'
    Assert-FrpTrue ($src -match 'ConvertTo-FrpBootstrapServices') 'uses shared validator'

    Write-FrpTestPass 'test-bootstrap-services-validation'
} finally {
    Remove-FrpWindowsTestRoot
}
