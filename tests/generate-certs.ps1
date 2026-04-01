# Generate test certificates at runtime — no private keys stored in the repo.
# Usage: pwsh -File generate-certs.ps1 -OutputDir <path>
#   OutputDir defaults to $env:TEMP\test-certs-<guid>
param(
    [string]$OutputDir = (Join-Path ([IO.Path]::GetTempPath()) "test-certs-$([guid]::NewGuid().ToString('N'))")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# ── Test CA (used by install-ca-cert.ps1 tests) ───────────────────────────────
$testCert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject "CN=Test CA, O=Test Org" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddYears(1) `
    -TextExtension @(
        "2.5.29.19={critical}{text}CA=true",
        "2.5.29.15={critical}{text}CertSign,CRLSign"
    )

try {
    $certBytes = $testCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $b64 = [Convert]::ToBase64String($certBytes, 'InsertLineBreaks')
    Set-Content -Path (Join-Path $OutputDir 'test-ca.crt') `
        -Value "-----BEGIN CERTIFICATE-----`n$b64`n-----END CERTIFICATE-----" `
        -Encoding ASCII
} finally {
    # Always remove from cert store — it was only needed for export
    Remove-Item "Cert:\CurrentUser\My\$($testCert.Thumbprint)" -Force -ErrorAction SilentlyContinue
}

# ── HTTPS test CA + server cert (requires openssl in PATH) ───────────────────
if (Get-Command openssl -ErrorAction SilentlyContinue) {
    $ext = $null
    try {
        & openssl req -x509 -newkey rsa:2048 -keyout "$OutputDir\https-ca.key" `
            -out "$OutputDir\https-ca.crt" -days 365 -nodes `
            -subj "/CN=Test HTTPS CA" `
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" `
            -addext "keyUsage=critical,keyCertSign,cRLSign" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "openssl failed to generate https-ca.crt (exit $LASTEXITCODE)" }

        & openssl req -newkey rsa:2048 -keyout "$OutputDir\https-server.key" `
            -out "$OutputDir\https-server.csr" -nodes `
            -subj "/CN=localhost" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "openssl failed to generate https-server.csr (exit $LASTEXITCODE)" }

        $ext = [IO.Path]::GetTempFileName()
        Set-Content $ext "subjectAltName=DNS:localhost,IP:127.0.0.1`nextendedKeyUsage=serverAuth`nkeyUsage=digitalSignature,keyEncipherment`nbasicConstraints=CA:FALSE" -Encoding ASCII

        & openssl x509 -req -in "$OutputDir\https-server.csr" `
            -CA "$OutputDir\https-ca.crt" -CAkey "$OutputDir\https-ca.key" `
            -CAcreateserial -out "$OutputDir\https-server.crt" -days 365 `
            -extfile $ext 2>$null
        if ($LASTEXITCODE -ne 0) { throw "openssl failed to sign https-server.crt (exit $LASTEXITCODE)" }
    } finally {
        if ($ext) { Remove-Item $ext -Force -ErrorAction SilentlyContinue }
        Remove-Item "$OutputDir\https-server.csr", "$OutputDir\https-ca.key", "$OutputDir\https-ca.srl" -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Certificates generated in $OutputDir"
