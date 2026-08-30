# test-rdp-service.ps1
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    $svcs = Get-FrpDefaultServices -Platform 'windows'
    Assert-FrpEqual 1 @($svcs).Count 'one default service'
    Assert-FrpEqual 'rdp' $svcs[0].id 'rdp id'
    Assert-FrpEqual 3389 ([int]$svcs[0].local_port) 'rdp port'

    $enrollList = Get-FrpEnrollServiceList -Services $svcs
    Assert-FrpEqual 'rdp' $enrollList[0].preset 'rdp is first-class API preset'

    $mid = Get-FrpOrCreateClientId
    $map = Merge-FrpAllocatedPorts -LocalServices $svcs -AllocatedList @(@{ id = 'rdp'; remote_port = 60100 })
    Assert-FrpEqual 60100 ([int]$map['rdp'].remote_port) 'merged port'
    Assert-FrpEqual 'rdp' $map['rdp'].preset 'local preset kept'

    Save-FrpClientState -AllocatorUrl 'https://example.test/enroll' -FrpServer 'example.test' `
        -FrpServerPort 7000 -Hostname 'win' -MachineId $mid -HostId 'h' -Services $map -Transport 'tcp' | Out-Null
    # info rendering bits
    $state = Read-FrpClientState
    Assert-FrpTrue ($null -ne $state.services) 'services in state'

    Write-FrpTestPass 'test-rdp-service'
} finally {
    Remove-FrpWindowsTestRoot
}
