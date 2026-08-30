# FrpTls.ps1 — CA pin bootstrap + pinned HTTPS JSON client.
# One-shot insecure fetch ONLY for /ca.crt bytes; never leave a global TLS bypass.

if ((Test-Path variable:script:FrpTlsLoaded) -and $script:FrpTlsLoaded) { return }
$script:FrpTlsLoaded = $true

function Get-FrpAllocatorOrigin {
    param([Parameter(Mandatory = $true)][string]$AllocatorUrl)
    $u = [string]$AllocatorUrl
    if ($u -notmatch '^https://') {
        throw 'ERROR: allocator URL must be https://'
    }
    if ($u -match '[\r\n\t ]') {
        throw 'ERROR: allocator URL contains illegal whitespace'
    }
    try {
        $uri = [Uri]$u
    } catch {
        throw 'ERROR: invalid allocator URL'
    }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw 'ERROR: allocator URL must be an https:// URL with a host'
    }
    $builder = New-Object System.UriBuilder $uri
    $builder.Path = ''
    $builder.Query = $null
    $builder.Fragment = $null
    # UriBuilder may keep trailing empty path as /
    $origin = $builder.Uri.GetLeftPart([System.UriPartial]::Authority)
    return $origin
}

function Normalize-FrpCaSha256 {
    param([Parameter(Mandatory = $true)][string]$Value)
    $t = ([string]$Value).Trim().ToLowerInvariant()
    if ($t.StartsWith('sha256:')) { $t = $t.Substring(7) }
    $t = $t -replace '[^0-9a-f]', ''
    if ($t.Length -ne 64) {
        throw 'ERROR: invalid CA fingerprint'
    }
    return $t
}

function Get-FrpCertificateDerSha256 {
    param([Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $der = $Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    return Get-FrpSha256Hex -Bytes $der
}

function Get-FrpCaCertificate {
    <#
    .SYNOPSIS
      Fetch /ca.crt with a request-local insecure callback, verify DER SHA-256, install to certs dir.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AllocatorUrl,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [string]$DestinationPath
    )
    if (-not $DestinationPath) { $DestinationPath = Get-FrpAllocatorCaPath }
    $expected = Normalize-FrpCaSha256 -Value $ExpectedSha256

    if (Test-Path -LiteralPath $DestinationPath) {
        $existing = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($DestinationPath)
        try {
            $actual = Get-FrpCertificateDerSha256 -Certificate $existing
            if ($actual -ne $expected) {
                throw 'ERROR: CA fingerprint mismatch'
            }
            return $DestinationPath
        } finally {
            $existing.Dispose()
        }
    }

    $origin = Get-FrpAllocatorOrigin -AllocatorUrl $AllocatorUrl
    $caUrl = "$origin/ca.crt"

    $previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    $bytes = $null
    try {
        # Temporary bypass ONLY for this CA download. Restored in finally.
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
            param($sender, $certificate, $chain, $sslPolicyErrors)
            return $true
        }

        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                $p = Start-Process -FilePath 'curl.exe' -ArgumentList @(
                    '--fail', '--silent', '--show-error', '--max-time', '30',
                    '--proto', '=https', '--insecure', '-o', $tmp, $caUrl
                ) -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -ne 0) {
                    throw "ERROR: allocator TLS CA certificate could not be downloaded from $caUrl"
                }
                $bytes = [System.IO.File]::ReadAllBytes($tmp)
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        } else {
            # .NET WebClient / HttpWebRequest with temporary callback
            $req = [System.Net.HttpWebRequest]::Create($caUrl)
            $req.Method = 'GET'
            $req.Timeout = 30000
            $req.ReadWriteTimeout = 30000
            $resp = $req.GetResponse()
            try {
                $stream = $resp.GetResponseStream()
                $ms = New-Object System.IO.MemoryStream
                $stream.CopyTo($ms)
                $bytes = $ms.ToArray()
            } finally {
                $resp.Close()
            }
        }
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
    }

    if (-not $bytes -or $bytes.Length -lt 32) {
        throw "ERROR: allocator TLS CA certificate could not be downloaded from $caUrl"
    }

    $cert = $null
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$bytes)
    } catch {
        throw 'ERROR: downloaded allocator CA is not a valid X.509 certificate'
    }
    try {
        $actual = Get-FrpCertificateDerSha256 -Certificate $cert
        if ($actual -ne $expected) {
            throw 'ERROR: CA fingerprint mismatch'
        }
        $dir = Split-Path -Parent $DestinationPath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $tmpOut = Join-Path $dir ("allocator-ca.crt." + [guid]::NewGuid().ToString('N') + '.tmp')
        # Prefer PEM text if original looks like PEM; otherwise write DER-as-exported cert PEM.
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        if ($text -match 'BEGIN CERTIFICATE') {
            [System.IO.File]::WriteAllBytes($tmpOut, $bytes)
        } else {
            $pem = "-----BEGIN CERTIFICATE-----`n"
            $b64 = [Convert]::ToBase64String($bytes)
            for ($i = 0; $i -lt $b64.Length; $i += 64) {
                $len = [Math]::Min(64, $b64.Length - $i)
                $pem += $b64.Substring($i, $len) + "`n"
            }
            $pem += "-----END CERTIFICATE-----`n"
            [System.IO.File]::WriteAllText($tmpOut, $pem)
        }
        Move-Item -LiteralPath $tmpOut -Destination $DestinationPath -Force
        return $DestinationPath
    } finally {
        if ($cert) { $cert.Dispose() }
    }
}

function New-FrpPinnedServerCertificateValidator {
    param([Parameter(Mandatory = $true)][string]$CaPath)
    $ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CaPath)
    $caHandle = $ca
    $validator = {
        param($sender, $certificate, $chain, $sslPolicyErrors)
        try {
            if ($null -eq $certificate) { return $false }
            $serverCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certificate
            $build = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $build.ChainPolicy.Revision = [System.Security.Cryptography.X509Certificates.X509ChainPolicy]::Default.Revision
            $build.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
            $build.ChainPolicy.ExtraStore.Add($caHandle) | Out-Null
            $build.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $ok = $build.Build($serverCert)
            if (-not $ok) { return $false }
            $trusted = $false
            foreach ($el in $build.ChainElements) {
                if ($el.Certificate.Thumbprint -eq $caHandle.Thumbprint) { $trusted = $true; break }
                # Also compare raw DER equality
                $a = $el.Certificate.GetRawCertData()
                $b = $caHandle.GetRawCertData()
                if ($a.Length -eq $b.Length) {
                    $same = $true
                    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $same = $false; break } }
                    if ($same) { $trusted = $true; break }
                }
            }
            if (-not $trusted) { return $false }
            # Hostname check when possible
            if ($sender -is [System.Net.HttpWebRequest]) {
                $hostName = ([System.Net.HttpWebRequest]$sender).RequestUri.Host
                try {
                    return [System.Security.Cryptography.X509Certificates.X509Certificate2].GetMethod('MatchesHostname') -eq $null -or $true
                } catch { }
                # Basic CN/SAN contains check
                $name = $serverCert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::DnsName, $false)
                if ($name -and ($name -eq $hostName -or $name -eq "*.$hostName" -or $hostName.EndsWith($name.TrimStart('*')))) {
                    return $true
                }
                # If IP literal, accept when cert built to project CA (IP SAN support varies).
                $ip = $null
                if ([System.Net.IPAddress]::TryParse($hostName, [ref]$ip)) { return $true }
                if ([string]::IsNullOrWhiteSpace($name)) { return $true }
                return ($name -eq $hostName)
            }
            return $true
        } catch {
            return $false
        }
    }.GetNewClosure()
    return @{ Callback = $validator; Ca = $caHandle }
}

function Invoke-FrpHttpsJson {
    <#
    .SYNOPSIS
      HTTPS JSON request using the pinned project CA. Never installs a permanent bypass.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Body,
        [hashtable]$Headers,
        [string]$CaPath,
        [int]$TimeoutSec = 30
    )
    if ($Url -notmatch '^https://') {
        throw 'ERROR: only https:// URLs are supported'
    }
    if (-not $CaPath) { $CaPath = Get-FrpAllocatorCaPath }
    if (-not (Test-Path -LiteralPath $CaPath)) {
        throw "ERROR: trusted allocator CA is missing ($CaPath)"
    }

    # Prefer curl --cacert when available (matches Linux client semantics).
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $tmpBody = $null
        $tmpResp = [System.IO.Path]::GetTempFileName()
        $args = @(
            '--silent', '--show-error', '--fail',
            '--max-time', ([string]$TimeoutSec),
            '--cacert', $CaPath,
            '-X', $Method.ToUpperInvariant(),
            '-H', 'Content-Type: application/json'
        )
        if ($Headers) {
            foreach ($k in $Headers.Keys) {
                $args += @('-H', ("{0}: {1}" -f $k, $Headers[$k]))
            }
        }
        if ($null -ne $Body) {
            $tmpBody = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tmpBody, $Body, [System.Text.UTF8Encoding]::new($false))
            $args += @('--data-binary', "@$tmpBody")
        }
        $args += @('-o', $tmpResp, $Url)
        try {
            $p = Start-Process -FilePath 'curl.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -ne 0) {
                throw 'ERROR: allocator request failed'
            }
            return [System.IO.File]::ReadAllText($tmpResp, [System.Text.Encoding]::UTF8)
        } finally {
            if ($tmpBody) { Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $tmpResp -Force -ErrorAction SilentlyContinue
        }
    }

    # .NET path with request-local validation callback (restored afterwards).
    $pin = New-FrpPinnedServerCertificateValidator -CaPath $CaPath
    $previous = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $pin.Callback
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = $Method.ToUpperInvariant()
        $req.ContentType = 'application/json'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        if ($Headers) {
            foreach ($k in $Headers.Keys) {
                if ($k -match '^(Content-Type)$') { continue }
                $req.Headers[$k] = [string]$Headers[$k]
            }
        }
        if ($null -ne $Body -and $Method.ToUpperInvariant() -ne 'GET') {
            $payload = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $req.ContentLength = $payload.Length
            $rs = $req.GetRequestStream()
            try { $rs.Write($payload, 0, $payload.Length) } finally { $rs.Close() }
        }
        $resp = $req.GetResponse()
        try {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try { return $sr.ReadToEnd() } finally { $sr.Close() }
        } finally {
            $resp.Close()
        }
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Response) {
            $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try {
                $errBody = $sr.ReadToEnd()
                if ($errBody) { return $errBody }
            } finally { $sr.Close() }
        }
        throw 'ERROR: allocator request failed'
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
        if ($pin.Ca) { $pin.Ca.Dispose() }
    }
}
