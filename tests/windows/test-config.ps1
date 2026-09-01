# test-config.ps1
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    $services = @(
        [pscustomobject]@{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; local_ip = '127.0.0.1'; local_port = 3389; remote_port = 60001; enabled = $true }
    )
    $ca = Join-Path $env:FRP_WINDOWS_ROOT 'certs/dummy-ca.crt'
    New-Item -ItemType Directory -Path (Split-Path $ca -Parent) -Force | Out-Null
    Set-Content -LiteralPath $ca -Value "-----BEGIN CERTIFICATE-----`ndeadbeef`n-----END CERTIFICATE-----`n"

    $toml = New-FrpClientToml -ServerAddr '203.0.113.10' -ServerPort 443 -Token 'tok-deadbeef' `
        -HostId 'abcd1234' -Services $services -Transport 'wss' -TrustedCaFile $ca
    $text = Get-Content -LiteralPath $toml -Raw
    Assert-FrpTrue ($text -match 'serverPort = 443') 'port 443'
    Assert-FrpTrue ($text -match 'transport\.protocol = "wss"') 'wss'
    Assert-FrpTrue ($text -match 'auth\.token = "tok-deadbeef"') 'token'
    Assert-FrpTrue ($text -match 'localPort = 3389') 'rdp local'
    Assert-FrpTrue ($text -match 'remotePort = 60001') 'remote'
    Assert-FrpEqual 'tok\"oops' (Escape-FrpTomlString 'tok"oops') 'escape quote'

    $id = New-FrpEcdsaIdentity
    Save-FrpIdentityKey -PrivatePem $id.PrivatePem | Out-Null
    Save-FrpIdentityPublic -PublicPem $id.PublicPem | Out-Null
    $mid = Get-FrpOrCreateClientId
    $services2 = @(
        [pscustomobject]@{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; local_ip = '127.0.0.1'; local_port = 3389; remote_port = 60002; enabled = $true }
    )
    $toml2 = New-FrpClientToml -ServerAddr '203.0.113.10' -ServerPort 7000 -Token 'tok-proof' `
        -HostId 'host1' -Services $services2 -Transport 'tcp' -MachineId $mid
    Test-FrpClientTomlDataPlaneMetadata -TomlPath $toml2 -MachineId $mid -Services $services2 -HostId 'host1' | Out-Null
    Write-FrpTestPass 'WINDOWS_PROOF_METADATA_VALIDATION'

    $servicesMap = @(
        [pscustomobject]@{ id = 'ssh'; name = 'SSH'; preset = 'ssh'; local_ip = '127.0.0.1'; local_port = 22; remote_port = 6001; enabled = $true },
        [pscustomobject]@{ id = 'web'; name = 'WEB'; preset = 'http'; local_ip = '127.0.0.1'; local_port = 80; remote_port = 6002; enabled = $true }
    )
    $tomlOk = New-FrpClientToml -ServerAddr '203.0.113.10' -ServerPort 7000 -Token 'tok-proof' `
        -HostId 'host1' -Services $servicesMap -Transport 'tcp' -MachineId $mid
    Test-FrpClientTomlDataPlaneMetadata -TomlPath $tomlOk -MachineId $mid -Services $servicesMap -HostId 'host1' | Out-Null
    Write-FrpTestPass 'CORRECT_PROXY_SERVICE_MAPPING'

    $swapped = @"
serverAddr = "203.0.113.10"
serverPort = 7000
auth.method = "token"
auth.token = "tok-proof"
clientID = "$mid"
metadatas.frp_ad_client_id = "$mid"
metadatas.frp_ad_proof_schema = "1"
metadatas.frp_ad_proof = "placeholder"

[[proxies]]
name = "host1-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6001
metadatas.frp_ad_service_id = "web"

[[proxies]]
name = "host1-web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = 6002
metadatas.frp_ad_service_id = "ssh"
"@
    # Use a valid proof from a correct render, then mutate mapping only.
    $okText = [System.IO.File]::ReadAllText($tomlOk)
    if ($okText -match '(?m)^metadatas\.frp_ad_proof\s*=\s*"([^"]+)"') {
        $swapped = $swapped.Replace('placeholder', $Matches[1])
    }
    $badPath = Join-Path (Split-Path $tomlOk -Parent) 'swapped.toml'
    [System.IO.File]::WriteAllText($badPath, $swapped)
    $threw = $false
    try {
        Test-FrpClientTomlDataPlaneMetadata -TomlPath $badPath -MachineId $mid -Services $servicesMap -HostId 'host1' | Out-Null
    } catch { $threw = $true }
    Assert-FrpTrue $threw 'SWAPPED_SERVICE_IDS_REJECTED'
    Write-FrpTestPass 'SWAPPED_SERVICE_IDS_REJECTED'

    $wrongPort = $okText -replace 'remotePort = 6001', 'remotePort = 6009'
    $wp = Join-Path (Split-Path $tomlOk -Parent) 'wrong-port.toml'
    [System.IO.File]::WriteAllText($wp, $wrongPort)
    $threw = $false
    try {
        Test-FrpClientTomlDataPlaneMetadata -TomlPath $wp -MachineId $mid -Services $servicesMap -HostId 'host1' | Out-Null
    } catch { $threw = $true }
    Assert-FrpTrue $threw 'WRONG_REMOTE_PORT_MAPPING_REJECTED'
    Write-FrpTestPass 'WRONG_REMOTE_PORT_MAPPING_REJECTED'

    $dup = $okText + @"

[[proxies]]
name = "host1-ssh-dup"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6011
metadatas.frp_ad_service_id = "ssh"
"@
    $dp = Join-Path (Split-Path $tomlOk -Parent) 'dup.toml'
    [System.IO.File]::WriteAllText($dp, $dup)
    $threw = $false
    try {
        Test-FrpClientTomlDataPlaneMetadata -TomlPath $dp -MachineId $mid -Services $servicesMap -HostId 'host1' | Out-Null
    } catch { $threw = $true }
    Assert-FrpTrue $threw 'DUPLICATE_SERVICE_MAPPING_REJECTED'
    Write-FrpTestPass 'DUPLICATE_SERVICE_MAPPING_REJECTED'

    $missing = ($okText -split "`n" | Where-Object { $_ -notmatch 'metadatas\.frp_ad_service_id = "web"' }) -join "`n"
    $mp = Join-Path (Split-Path $tomlOk -Parent) 'missing.toml'
    [System.IO.File]::WriteAllText($mp, $missing)
    $threw = $false
    try {
        Test-FrpClientTomlDataPlaneMetadata -TomlPath $mp -MachineId $mid -Services $servicesMap -HostId 'host1' | Out-Null
    } catch { $threw = $true }
    Assert-FrpTrue $threw 'MISSING_SERVICE_MAPPING_REJECTED'
    Write-FrpTestPass 'MISSING_SERVICE_MAPPING_REJECTED'

    $withDisabled = @(
        [pscustomobject]@{ id = 'ssh'; name = 'SSH'; preset = 'ssh'; local_ip = '127.0.0.1'; local_port = 22; remote_port = 6001; enabled = $true },
        [pscustomobject]@{ id = 'web'; name = 'WEB'; preset = 'http'; local_ip = '127.0.0.1'; local_port = 80; remote_port = 6002; enabled = $false }
    )
    $tomlDis = New-FrpClientToml -ServerAddr '203.0.113.10' -ServerPort 7000 -Token 'tok-proof' `
        -HostId 'host1' -Services $withDisabled -Transport 'tcp' -MachineId $mid
    Test-FrpClientTomlDataPlaneMetadata -TomlPath $tomlDis -MachineId $mid -Services $withDisabled -HostId 'host1' | Out-Null
    Write-FrpTestPass 'DISABLED_SERVICE_NOT_REQUIRED'

    $empty = @()
    $tomlEmpty = New-FrpClientToml -ServerAddr '203.0.113.10' -ServerPort 7000 -Token 'tok-proof' `
        -HostId 'host1' -Services $empty -Transport 'tcp' -MachineId $mid
    Test-FrpClientTomlDataPlaneMetadata -TomlPath $tomlEmpty -MachineId $mid -Services $empty -HostId 'host1' | Out-Null
    Write-FrpTestPass 'MANAGEMENT_ONLY_ZERO_PROXY_VALID'

    Write-FrpTestPass 'test-config'
} finally {
    Remove-FrpWindowsTestRoot
}
