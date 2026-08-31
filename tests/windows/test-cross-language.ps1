# test-cross-language.ps1 — Python ↔ PowerShell vectors
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')

function Invoke-FrpPythonUtf8Stdin {
    # PS 5.1 pipes strings to native exes as UTF-16LE by default; Python expects UTF-8.
    # Write UTF-8 bytes directly to the child stdin BaseStream (no pipeline encoding).
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$StdinText,
        [hashtable]$Environment = @{}
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PythonExe
    $psi.Arguments = ($ArgumentList | ForEach-Object {
            if ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '\"') } else { $_ }
        }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
    }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $bytes = $utf8.GetBytes($StdinText)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.BaseStream.Flush()
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        throw ("python failed (exit {0}): {1}" -f $proc.ExitCode, $stderr.Trim())
    }
    return $stdout
}

function Get-FrpPythonExe {
    foreach ($name in @('python3', 'python')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    throw 'python3/python not found on PATH'
}

$crossDir = Join-Path $PSScriptRoot 'cross'
$gen = Join-Path $crossDir 'generate_python_vectors.py'
$verify = Join-Path $crossDir 'verify_ps_signature.py'
$vectorsPath = Join-Path $crossDir 'vectors.json'

try {
    Assert-FrpTrue (Test-Path -LiteralPath $gen) 'generator exists'
    $python = Get-FrpPythonExe
    & $python $gen
    if ($LASTEXITCODE -ne 0) { throw 'generator failed' }
    Assert-FrpTrue (Test-Path -LiteralPath $vectorsPath) 'vectors.json written'

    $v = Get-Content -LiteralPath $vectorsPath -Raw | ConvertFrom-Json

    # PowerShell decrypts Python ciphertext
    $pt = Unprotect-FrpTokenPbkdf2 -Ciphertext $v.token_ciphertext_python -Secret $v.secret
    Assert-FrpEqual $v.token $pt 'PS decrypts Python ciphertext'

    # Python decrypts PowerShell ciphertext (UTF-8 byte-safe stdin; no PS5.1 pipeline)
    $psCt = Protect-FrpTokenPbkdf2 -Token $v.token -Secret $v.secret
    $authPy = Join-Path $script:RepoRoot 'lib/frp_mgmt_auth.py'
    $pyPt = Invoke-FrpPythonUtf8Stdin -PythonExe $python `
        -ArgumentList @($authPy, 'decrypt-token') `
        -StdinText $psCt `
        -Environment @{ FRP_ENROLL_SECRET = $v.secret }
    Assert-FrpEqual $v.token $pyPt.Trim() 'Python decrypts PS ciphertext'

    # MAC derivation matches
    $mac = Get-FrpDerivedMacKey -Secret $v.secret -MachineId $v.machine_id
    Assert-FrpEqual $v.derive_mac_key $mac 'derive_mac_key match'

    # Canonical signed message matches Python
    $msg = Get-FrpSignedMessage -MachineId $v.machine_id -Body $v.body -Timestamp ([int64]$v.ts) -Nonce $v.nonce
    Assert-FrpEqual $v.signed_message $msg 'signed_message match'

    # PowerShell verifies Python signature
    Assert-FrpTrue (
        Test-FrpSignature -PublicPem $v.python_public_pem -Message $v.signed_message -SignatureBase64 $v.python_signature_b64
    ) 'PS verifies Python signature'

    # PowerShell signs; Python verifies
    $id = New-FrpEcdsaIdentity
    $sig = Protect-FrpSignMessage -PrivatePem $id.PrivatePem -Message $msg
    $pubFile = Join-Path $crossDir 'ps-pub.pem'
    [System.IO.File]::WriteAllText($pubFile, $id.PublicPem)
    & $python $verify --pubkey-pem $pubFile --body $v.body --ts $v.ts --nonce $v.nonce `
        --machine-id $v.machine_id --sig-b64 $sig
    if ($LASTEXITCODE -ne 0) { throw 'Python verify of PS signature failed' }

    # Canonical sample
    $sample = Get-FrpCanonicalJson -Object (@{ b = 1; a = 2; z = @('x', 'y'); n = $null; t = $true })
    Assert-FrpEqual $v.canonical_sample $sample 'canonical sample match'

    Write-FrpTestPass 'test-cross-language'
} finally {
    Remove-Item Env:FRP_ENROLL_SECRET -ErrorAction SilentlyContinue
    Remove-FrpWindowsTestRoot
}
