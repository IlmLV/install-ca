#Requires -Version 5.1
# Install a CA certificate into system and browser trust stores
#
# Browsers handled:
#   - System trust store   (Windows Certificate Store — LocalMachine\Root)
#   - Google Chrome        uses Windows Certificate Store
#   - Microsoft Edge       uses Windows Certificate Store
#   - Brave                uses Windows Certificate Store
#   - Chromium             uses Windows Certificate Store
#   - Firefox              cert9.db via certutil.exe, or ImportEnterpriseRoots registry policy
#
# Usage: powershell -File install-ca-cert.ps1 [-CASource <url-or-path>] [-Force] [-Yes]
#   or:  irm https://raw.githubusercontent.com/IlmLV/install-ca-cert/main/install-ca-cert.ps1 | iex

param(
    [string]$CASource = "",
    [switch]$Force,
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$IsWindowsPlatform = $false
try {
    $IsWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows
    )
} catch {
    $IsWindowsPlatform = $env:OS -eq 'Windows_NT'
}

# ── Elevation check ───────────────────────────────────────────────────────────
if ($IsWindowsPlatform) {
    $id        = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "This script must be run as Administrator. Right-click PowerShell and select 'Run as Administrator', then try again." -ErrorAction Continue
        exit 1
    }
}

$tempDir = [IO.Path]::GetTempPath()
if ([string]::IsNullOrWhiteSpace($tempDir)) {
    $tempDir = $env:TEMP
}
if ([string]::IsNullOrWhiteSpace($tempDir)) {
    throw "Unable to determine temp directory."
}
$caFileName = "ca_{0}.crt" -f ([guid]::NewGuid().ToString("N"))
$CA_FILE = Join-Path $tempDir $caFileName

# ── Ctrl+C handler ────────────────────────────────────────────────────────────
# Initialise to safe defaults so the finally block can reference these variables
# even if console setup fails (e.g., non-interactive/headless environments).
$originalTreatControlCAsInput = $false
$cancelKeyPressSubscription   = $null
try {
    $originalTreatControlCAsInput = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $false
    $cancelKeyPressSubscription = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action {
        Write-Host ""
        Write-Host "Interrupted — exiting."
        Remove-Item -LiteralPath $Event.MessageData -Force -ErrorAction SilentlyContinue
        [Environment]::Exit(130)
    } -MessageData $CA_FILE
} catch {
    # Console not available (non-interactive or redirected I/O) — skip Ctrl+C handler.
}

# ── Helpers ───────────────────────────────────────────────────────────────

function Confirm-Action([string]$Prompt) {
    if ($Yes) {
        Write-Host "$Prompt [y/N] y"
        return $true
    }
    try {
        $reply = Read-Host "$Prompt [y/N]"
    } catch {
        # Non-interactive or input unavailable — treat as a declined confirmation.
        return $false
    }
    return $reply -match '^[Yy]$'
}

# Download without validating server TLS (the CA is not yet trusted)
function Invoke-InsecureDownload([string]$Uri, [string]$OutFile) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -SkipCertificateCheck
    } else {
        # PowerShell 5.1 fallback.
        # A ScriptBlock cannot run on .NET thread-pool threads (no Runspace), so we use
        # Add-Type to compile a real delegate that bypasses certificate validation.
        if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
            Add-Type -TypeDefinition @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts {
    public static readonly RemoteCertificateValidationCallback Callback =
        delegate(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; };
}
"@
        }
        $cb    = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        $proto = [System.Net.ServicePointManager]::SecurityProtocol
        [System.Net.ServicePointManager]::SecurityProtocol             = [System.Net.SecurityProtocolType]::Tls12
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [TrustAllCerts]::Callback
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile
        } finally {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $cb
            [System.Net.ServicePointManager]::SecurityProtocol                    = $proto
        }
    }
}

# Add CA to a single NSS sql: database directory using Firefox's certutil.exe
function Add-ToNssDb([string]$CertUtil, [string]$DbDir, [string]$CaName, [string]$CaFile) {
    & $CertUtil -d "sql:$DbDir" -D -n $CaName 2>$null
    & $CertUtil -d "sql:$DbDir" -A -n $CaName -t "CT,," -i $CaFile
    if ($LASTEXITCODE -ne 0) { throw "certutil failed for $DbDir" }
}

# ── 1. Resolve CA source ──────────────────────────────────────────────────────
$cert = $null
try {
if (-not [string]::IsNullOrWhiteSpace($CASource)) {
    $CA_SOURCE = $CASource
} else {
    try {
        $CA_SOURCE = Read-Host "Enter CA certificate URL or file path"
    } catch {
        # In non-interactive sessions, Read-Host can throw a terminating error.
        # Treat this as if no input was provided so we can emit a friendly message.
        $CA_SOURCE = ""
    }
}

if ([string]::IsNullOrWhiteSpace($CA_SOURCE)) {
    Write-Error "No CA source provided." -ErrorAction Continue
    exit 1
}

# ── 2. Fetch or copy the CA certificate ───────────────────────────────────────

Write-Host ""
if ($CA_SOURCE -match '^https?://') {
    Write-Host "==> Fetching CA certificate from $CA_SOURCE ..."
    $downloadOk = $false
    try {
        Invoke-WebRequest -Uri $CA_SOURCE -OutFile $CA_FILE
        $downloadOk = $true
    } catch {
        Write-Host "    WARNING: Secure download failed. The server's TLS certificate may be invalid or self-signed."
        Write-Host "    Detail  : $($_.Exception.Message)"
    }
    if (-not $downloadOk) {
        if (Confirm-Action "    Retry without TLS certificate validation (insecure)?") {
            Invoke-InsecureDownload -Uri $CA_SOURCE -OutFile $CA_FILE
        } else {
            Write-Error "Download aborted." -ErrorAction Continue
            exit 1
        }
    }
} else {
    Write-Host "==> Copying CA certificate from $CA_SOURCE ..."
    Copy-Item -LiteralPath $CA_SOURCE -Destination $CA_FILE -Force
}

try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CA_FILE
} catch {
    Write-Error "File is not a valid certificate." -ErrorAction Continue
    exit 1
}

Write-Host "    Subject  : $($cert.Subject)"
Write-Host "    NotAfter : $($cert.NotAfter)"

# Derive CA_NAME from the CN field of the subject
$CA_NAME = if ($cert.Subject -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $cert.Subject }

Write-Host "    CA Name  : $CA_NAME"

# ── Non-Windows short-circuit ────────────────────────────────────────────────
if (-not $IsWindowsPlatform) {
    if ($env:INSTALL_CA_CERT_TEST_LINUX -eq '1') {
        $safeName = ($CA_NAME.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'custom-ca' }
        $systemCaFile = "/usr/local/share/ca-certificates/$safeName.crt"

        Write-Host ""
        Write-Host "==> Linux system trust store (test mode)"
        Copy-Item -LiteralPath $CA_FILE -Destination $systemCaFile -Force
        $ucOutput = & update-ca-certificates 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "update-ca-certificates failed (exit $LASTEXITCODE): $ucOutput" -ErrorAction Continue
        }
        Write-Host "    Installed: $systemCaFile"
    } else {
        Write-Host ""
        Write-Host "==> Windows-specific steps skipped (non-Windows platform)."
    }
    Write-Host ""
    Write-Host "==> All done. Fully quit and restart any open browsers for changes to take effect."
    exit 0
}

# ── 3. Check existing certificate in system store ────────────────────────────

Write-Host ""
Write-Host "==> Checking for existing certificate in LocalMachine\Root ..."

$checkStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
    [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
)
$checkStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
$existing = $null
try {
    $existing = @($checkStore.Certificates | Where-Object { $_.Subject -eq $cert.Subject }) |
                Sort-Object NotAfter -Descending | Select-Object -First 1
} finally {
    $checkStore.Close()
}

if ($existing) {
    Write-Host "    Found    : $($existing.Thumbprint)"
    Write-Host "    expires  : $($existing.NotAfter)"
    Write-Host "    Remote   : $($cert.Thumbprint)"
    Write-Host "    expires  : $($cert.NotAfter)"

    if ($existing.Thumbprint -eq $cert.Thumbprint) {
        if ($Force) {
            Write-Host "    Status   : Already up-to-date but -Force was specified, continuing."
        } else {
            Write-Host "    Status   : Already up-to-date (same certificate). Nothing to do."
            exit 0
        }
    } elseif ($cert.NotAfter -gt $existing.NotAfter) {
        $days = [int]($cert.NotAfter - $existing.NotAfter).TotalDays
        Write-Host "    Status   : Remote certificate is newer by $days day(s) — update recommended."
    } elseif ($cert.NotAfter -lt $existing.NotAfter) {
        $days = [int]($existing.NotAfter - $cert.NotAfter).TotalDays
        Write-Warning "    Status   : Installed certificate expires $days day(s) LATER than the remote one."
    } else {
        Write-Host "    Status   : Different certificate with the same expiry date."
    }
} else {
    Write-Host "    Status   : No existing certificate found — fresh install."
}

# ── 4. System trust store (Windows Certificate Store) ────────────────────────
#
#  Adding to LocalMachine\Root covers all Chromium-based browsers on Windows
#  (Chrome, Edge, Brave, Chromium) because they delegate to the OS store.

Write-Host ""
Write-Host "==> Windows Certificate Store — LocalMachine\Root"
Write-Host "    (covers Chrome, Edge, Brave, Chromium)"

if (Confirm-Action "    Add '$CA_NAME' to the Windows Root CA store?") {
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $store.Add($cert)
    } finally {
        $store.Close()
    }
    Write-Host "    Done."
} else {
    Write-Host "    Skipped."
}

# ── 5. Firefox ────────────────────────────────────────────────────────────────
#
#  Two approaches, tried in order:
#   a) certutil.exe (ships with most Firefox installs) — updates the NSS cert9.db directly.
#   b) ImportEnterpriseRoots policy — a registry key that tells Firefox to delegate
#      trust to the Windows Certificate Store.

Write-Host ""
Write-Host "==> Firefox"

$ffCertRegKey = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\Certificates'
$hasEnterpriseRoots = (Test-Path $ffCertRegKey) -and
    ((Get-ItemProperty $ffCertRegKey -Name 'ImportEnterpriseRoots' -ErrorAction SilentlyContinue).ImportEnterpriseRoots -eq 1)

if ($hasEnterpriseRoots) {
    Write-Host "    ImportEnterpriseRoots policy is set — Firefox trusts the Windows store."
    Write-Host "    No additional action needed."
} else {
    # Try certutil first
    $certutil = $null
    $ffInstallPaths = @(
        "$env:ProgramFiles\Mozilla Firefox\certutil.exe",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\certutil.exe"
    )
    foreach ($p in $ffInstallPaths) {
        if (Test-Path $p) { $certutil = $p; break }
    }

    if ($certutil) {
        Write-Host "    Using certutil: $certutil"

        $ffDirs = @()
        $ffProfileRoot = "$env:APPDATA\Mozilla\Firefox\Profiles"
        if (Test-Path $ffProfileRoot) {
            $ffDirs = @(Get-ChildItem -Path $ffProfileRoot -Filter "cert9.db" -Recurse -ErrorAction SilentlyContinue |
                       Select-Object -ExpandProperty DirectoryName |
                       Sort-Object -Unique)
        }

        if ($ffDirs.Count -eq 0) {
            Write-Host "    No Firefox profiles found — skipping."
        } else {
            Write-Host "    Found profiles:"
            $ffDirs | ForEach-Object { Write-Host "      $_" }

            if (Confirm-Action "    Add '$CA_NAME' to the above Firefox profiles?") {
                foreach ($db in $ffDirs) {
                    Add-ToNssDb -CertUtil $certutil -DbDir $db -CaName $CA_NAME -CaFile $CA_FILE
                    Write-Host "    OK: $db"
                }
            } else {
                Write-Host "    Skipped."
            }
        }
    } else {
        # certutil not available — fall back to the enterprise-roots registry policy
        Write-Host "    certutil.exe not found in Firefox install directories."
        Write-Host "    Falling back to ImportEnterpriseRoots policy (makes Firefox trust the Windows store)."

        if (Confirm-Action "    Set ImportEnterpriseRoots policy so Firefox trusts the Windows store?") {
            if (-not (Test-Path $ffCertRegKey)) {
                New-Item -Path $ffCertRegKey -Force | Out-Null
            }
            Set-ItemProperty -Path $ffCertRegKey -Name 'ImportEnterpriseRoots' -Value 1 -Type DWord
            Write-Host "    Done — Firefox will now import roots from the Windows Certificate Store."
        } else {
            Write-Host "    Skipped."
        }
    }
}

# ── 6. Verify ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "==> Verifying system trust ..."

$verifyStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
    [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
)
$verifyStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
$found = $null
try {
    $found = $verifyStore.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
} finally {
    $verifyStore.Close()
}

if ($found) {
    Write-Host "    System trust: OK (found in LocalMachine\Root)"
} else {
    Write-Host "    System trust: NOT FOUND in LocalMachine\Root"
}

Write-Host ""
Write-Host "==> All done. Fully quit and restart any open browsers for changes to take effect."
} finally {
    try {
        [Console]::TreatControlCAsInput = $originalTreatControlCAsInput
    } catch {
        # Ignore failures restoring console state
    }

    if ($null -ne $cancelKeyPressSubscription) {
        try {
            Unregister-Event -SourceIdentifier $cancelKeyPressSubscription.Name -ErrorAction SilentlyContinue
        } catch {
            # Ignore failures unregistering event
        }
        try {
            Remove-Job -Id $cancelKeyPressSubscription.Id -Force -ErrorAction SilentlyContinue
        } catch {
            # Ignore failures removing job
        }
    }

    if ($null -ne $cert) {
        try { $cert.Dispose() } catch { }
    }

    Remove-Item -LiteralPath $CA_FILE -Force -ErrorAction SilentlyContinue
}
