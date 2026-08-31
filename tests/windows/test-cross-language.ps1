# test-cross-language.ps1 — Python ↔ PowerShell vectors
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot '_import.ps1')

function Invoke-FrpPythonUtf8Stdin {
    # PS 5.1 Process.StandardInput StreamWriter emits UTF-8 BOM, which breaks
    # base64/ascii crypto payloads. Feed stdin from a BOM-free UTF-8 temp file.
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$StdinText,
        [hashtable]$Environment = @{}
    )
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $inFile = Join-Path ([System.IO.Path]::GetTempPath()) ('frp-py-in-' + [guid]::NewGuid().ToString('N') + '.txt')
    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ('frp-py-out-' + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ('frp-py-err-' + [guid]::NewGuid().ToString('N') + '.txt')
    $saved = @{}
    try {
        $clean = $StdinText.TrimStart([char]0xFEFF)
        [System.IO.File]::WriteAllText($inFile, $clean, $utf8)
        foreach ($key in $Environment.Keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key)
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
        }
        [Environment]::SetEnvironmentVariable('PYTHONUTF8', '1', 'Process')
        [Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'utf-8', 'Process')

        $argParts = @()
        foreach ($a in $ArgumentList) {
            if ($a -match '[\s"]') {
                $argParts += ('"{0}"' -f ($a -replace '"', '\"'))
            } else {
                $argParts += $a
            }
        }
        $argStr = $argParts -join ' '
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($env:OS -match 'Windows_NT') {
                $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
                $cmdline = '"{0}" {1} < "{2}" > "{3}" 2> "{4}"' -f $PythonExe, $argStr, $inFile, $outFile, $errFile
                & $cmdExe /c $cmdline | Out-Null
            } else {
                $bashCmd = "'" + ($PythonExe -replace "'", "'\\''") + "' " + $argStr +
                    " < '" + ($inFile -replace "'", "'\\''") + "'" +
                    " > '" + ($outFile -replace "'", "'\\''") + "'" +
                    " 2> '" + ($errFile -replace "'", "'\\''") + "'"
                & /bin/bash -c $bashCmd | Out-Null
            }
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($null -eq $code) { $code = 0 }
        $stdout = ''
        $stderr = ''
        if (Test-Path -LiteralPath $outFile) {
            $stdout = [System.IO.File]::ReadAllText($outFile, $utf8)
        }
        if (Test-Path -LiteralPath $errFile) {
            $stderr = [System.IO.File]::ReadAllText($errFile, $utf8)
        }
        if ($code -ne 0) {
            throw ("python failed (exit {0}): {1}" -f $code, $stderr.Trim())
        }
        return $stdout
    } finally {
        foreach ($key in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
        }
        Remove-Item -LiteralPath $inFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
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

    # Python decrypts PowerShell ciphertext (BOM-free UTF-8 stdin file redirect)
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
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($pubFile, $id.PublicPem, $utf8NoBom)
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
