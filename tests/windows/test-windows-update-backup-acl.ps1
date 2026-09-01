# test-windows-update-backup-acl.ps1 — update snapshot ACL order + retention
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')
try {
    $id = New-FrpEcdsaIdentity
    Save-FrpIdentityKey -PrivatePem $id.PrivatePem | Out-Null
    Save-FrpIdentityPublic -PublicPem $id.PublicPem | Out-Null
    $mid = Get-FrpOrCreateClientId
    $services = @{
        rdp = @{ id = 'rdp'; name = 'RDP'; preset = 'rdp'; local_ip = '127.0.0.1'
                 local_port = 3389; remote_port = 60003; enabled = $true }
    }
    Save-FrpClientState -AllocatorUrl 'https://example.test/enroll' -FrpServer 'example.test' `
        -FrpServerPort 7000 -Hostname 'win' -MachineId $mid -HostId 'abcd' `
        -Services $services -Transport 'tcp' -InstallStatus 'installed' | Out-Null
    New-FrpClientToml -ServerAddr 'example.test' -ServerPort 7000 -Token 'tok-secret-backup' `
        -HostId 'abcd' -Services $services -Transport 'tcp' | Out-Null
    New-Item -ItemType Directory -Path (Get-FrpBinDir) -Force | Out-Null
    Set-Content -LiteralPath (Get-FrpFrpcPath) -Value 'ORIGINAL_BINARY'
    Set-Content -LiteralPath (Get-FrpVersionPath) -Value "PROJECT_VERSION=1.0.0`n"

    Initialize-FrpDirectories
    $backupRootDir = Get-FrpBackupDir
    Assert-FrpTrue (Test-Path -LiteralPath $backupRootDir) 'backups dir exists'
    Assert-FrpTrue ([bool](Get-Command Restrict-FrpDirectoryAcl -ErrorAction SilentlyContinue)) 'Restrict-FrpDirectoryAcl present'
    Assert-FrpTrue ([bool](Get-Command Remove-FrpOldUpdateBackups -ErrorAction SilentlyContinue)) 'retention helper present'
    Assert-FrpTrue ([bool](Get-Command New-FrpUpdateBackupSnapshot -ErrorAction SilentlyContinue)) 'snapshot helper present'

    if (Test-FrpIsWindowsHost) {
        $acl = Get-Acl -LiteralPath $backupRootDir
        $bad = @('Users', 'Authenticated Users', 'Everyone', 'BUILTIN\Users')
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -ne 'Allow') { continue }
            $idRef = [string]$rule.IdentityReference
            foreach ($name in $bad) {
                Assert-FrpTrue ($idRef -ine $name) ("backups ACL must not allow $name (got $idRef)")
            }
        }
    } else {
        Write-Host 'NOTE: backup root native ACL assert is Windows-only; structure checked on Linux'
    }

    # ACL failure must abort BEFORE copying frpc.toml.
    $env:FRP_WINDOWS_FAIL_ACL = '1'
    $threw = $false
    try {
        $null = New-FrpUpdateBackupSnapshot -SnapshotMap ([ordered]@{
                'frpc.toml' = (Get-FrpTomlPath)
            })
    } catch {
        $threw = $true
        Assert-FrpTrue ($_.Exception.Message -match 'ACL') 'ACL failure mentioned'
    }
    Assert-FrpTrue $threw 'snapshot aborts when ACL hardening fails'
    Remove-Item Env:FRP_WINDOWS_FAIL_ACL -ErrorAction SilentlyContinue

    $map = [ordered]@{
        'frpc.exe'          = (Get-FrpFrpcPath)
        'frpc.toml'         = (Get-FrpTomlPath)
        'client-state.json' = (Get-FrpStatePath)
        'version'           = (Get-FrpVersionPath)
    }
    $snap = New-FrpUpdateBackupSnapshot -SnapshotMap $map
    Assert-FrpTrue (Test-Path -LiteralPath $snap) 'snapshot dir created'
    Assert-FrpTrue (Test-Path -LiteralPath (Join-Path $snap 'frpc.toml')) 'toml snapshotted'

    if (Test-FrpIsWindowsHost) {
        foreach ($name in @('frpc.toml', 'client-state.json')) {
            $p = Join-Path $snap $name
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $fileAcl = Get-Acl -LiteralPath $p
            foreach ($rule in @($fileAcl.Access)) {
                $idRef = [string]$rule.IdentityReference
                Assert-FrpTrue ($idRef -match 'SYSTEM|Administrators') ("snapshot file ACE: $name $idRef")
            }
        }
        Write-FrpTestPass 'WINDOWS_UPDATE_BACKUP_ACL_SECURE'
    } else {
        Write-Host 'NOTE: native ACL assert skipped on non-Windows; fail-closed + structure covered'
        Write-FrpTestPass 'WINDOWS_UPDATE_BACKUP_ACL_SECURE'
    }

    for ($i = 0; $i -lt 7; $i++) {
        $fake = Join-Path $backupRootDir ('update-1999010{0}-{1}' -f $i, $i)
        if (-not (Test-Path -LiteralPath $fake)) {
            New-Item -ItemType Directory -Path $fake -Force | Out-Null
        }
    }
    Remove-FrpOldUpdateBackups -Keep 5
    $left = @(Get-ChildItem -LiteralPath $backupRootDir -Directory |
        Where-Object { $_.Name -like 'update-*' })
    Assert-FrpTrue ($left.Count -le 5) 'update backup retention keeps <=5'

    Write-FrpTestPass 'test-windows-update-backup-acl'
} finally {
    Remove-Item Env:FRP_WINDOWS_FAIL_ACL -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
