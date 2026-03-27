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
    -Subject "CN=Test CA, O=Test Org" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddYears(1)

$certBytes = $testCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$b64 = [Convert]::ToBase64String($certBytes, 'InsertLineBreaks')
Set-Content -Path (Join-Path $OutputDir 'test-ca.crt') `
    -Value "-----BEGIN CERTIFICATE-----`n$b64`n-----END CERTIFICATE-----" `
    -Encoding ASCII

# Remove from cert store — only needed for export
Remove-Item "Cert:\CurrentUser\My\$($testCert.Thumbprint)" -Force -ErrorAction SilentlyContinue

Write-Host "Certificates generated in $OutputDir"
