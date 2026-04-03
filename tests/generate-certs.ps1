# Generate test certificates at runtime — no private keys stored in the repo.
# Usage: powershell -File generate-certs.ps1 -OutputDir <path>
#   OutputDir defaults to $env:TEMP\test-certs-<guid>
param(
    [string]$OutputDir = (Join-Path ([IO.Path]::GetTempPath()) "test-certs-$([guid]::NewGuid().ToString('N'))")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# ── Test CA (used by install-ca.ps1 tests) ────────────────────────────────────
$testCert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject "CN=Test CA, O=Test Org" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddYears(1) `
    -KeyUsage CertSign, CRLSign `
    -TextExtension @("2.5.29.19={critical}{text}CA=true")

try {
    $certBytes = $testCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    # Use None to avoid InsertLineBreaks inserting \r\n; manually wrap at 64 chars with \n.
    $b64 = [Convert]::ToBase64String($certBytes, [System.Base64FormattingOptions]::None)
    $b64Lines = ($b64 -split '(.{1,64})' | Where-Object { $_ }) -join "`n"
    $pemContent = "-----BEGIN CERTIFICATE-----`n$b64Lines`n-----END CERTIFICATE-----`n"
    [IO.File]::WriteAllText((Join-Path $OutputDir 'test-ca.crt'), $pemContent, [Text.Encoding]::ASCII)
} finally {
    # Always remove from cert store — it was only needed for export
    Remove-Item "Cert:\CurrentUser\My\$($testCert.Thumbprint)" -Force -ErrorAction SilentlyContinue
}

# ── Leaf certificate (no CA extensions) — used to verify non-CA cert rejection ─
$leafCert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject "CN=Test Leaf" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddYears(1) `
    -TextExtension @("2.5.29.19={text}CA=false")    # 2.5.29.19 = BasicConstraints OID

try {
    $leafBytes = $leafCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $leafB64 = [Convert]::ToBase64String($leafBytes, [System.Base64FormattingOptions]::None)
    $leafB64Lines = ($leafB64 -split '(.{1,64})' | Where-Object { $_ }) -join "`n"
    $leafPemContent = "-----BEGIN CERTIFICATE-----`n$leafB64Lines`n-----END CERTIFICATE-----`n"
    [IO.File]::WriteAllText((Join-Path $OutputDir 'leaf.crt'), $leafPemContent, [Text.Encoding]::ASCII)
} finally {
    Remove-Item "Cert:\CurrentUser\My\$($leafCert.Thumbprint)" -Force -ErrorAction SilentlyContinue
}

# ── HTTPS test CA + server cert (requires openssl in PATH) ───────────────────
if (Get-Command openssl -ErrorAction SilentlyContinue) {
    $ext = $null
    try {
        $out = & openssl req -x509 -newkey rsa:2048 -keyout "$OutputDir\https-ca.key" `
            -out "$OutputDir\https-ca.crt" -days 365 -nodes `
            -subj "/CN=Test HTTPS CA" `
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" `
            -addext "keyUsage=critical,keyCertSign,cRLSign" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "openssl failed to generate https-ca.crt (exit $LASTEXITCODE)`n$out" }

        $out = & openssl req -newkey rsa:2048 -keyout "$OutputDir\https-server.key" `
            -out "$OutputDir\https-server.csr" -nodes `
            -subj "/CN=localhost" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "openssl failed to generate https-server.csr (exit $LASTEXITCODE)`n$out" }

        $ext = [IO.Path]::GetTempFileName()
        Set-Content $ext "subjectAltName=DNS:localhost,IP:127.0.0.1`nextendedKeyUsage=serverAuth`nkeyUsage=digitalSignature,keyEncipherment`nbasicConstraints=CA:FALSE" -Encoding ASCII

        $out = & openssl x509 -req -in "$OutputDir\https-server.csr" `
            -CA "$OutputDir\https-ca.crt" -CAkey "$OutputDir\https-ca.key" `
            -CAcreateserial -out "$OutputDir\https-server.crt" -days 365 `
            -extfile $ext 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "openssl failed to sign https-server.crt (exit $LASTEXITCODE)`n$out" }
    } finally {
        if ($ext) { Remove-Item $ext -Force -ErrorAction SilentlyContinue }
        Remove-Item "$OutputDir\https-server.csr", "$OutputDir\https-ca.key", "$OutputDir\https-ca.srl" -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Certificates generated in $OutputDir"
