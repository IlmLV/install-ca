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
# Usage (file): powershell -File install-ca.ps1 [-CASource|-u <url-or-path>] [-Force|-f] [-Yes|-y]
# Usage (iex interactive):      irm https://raw.githubusercontent.com/IlmLV/install-ca/main/install-ca.ps1 | iex
# Usage (iex non-interactive):  irm https://raw.githubusercontent.com/IlmLV/install-ca/main/install-ca.ps1 | iex; Install '<url>' -y

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Install {
param(
    [Alias('u')][string]$CASource = "",
    [Alias('f')][switch]$Force,
    [Alias('y')][switch]$Yes
)

$global:__Install_InstallCalled = $true

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Error "PowerShell 5.1+ is required." -ErrorAction Continue
    return 1
}

# PowerShell 5.x compatibility — $IsWindows is not defined in Windows PowerShell 5.x
if (-not (Get-Variable 'IsWindows' -Scope Global -ErrorAction SilentlyContinue)) {
    $IsWindows = $true  # Windows PowerShell 5.x runs only on Windows
}

# Ensure TLS 1.2 is available (PowerShell 5.x / .NET Framework defaults to TLS 1.0)
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# ── Elevation check ───────────────────────────────────────────────────────────
if ($IsWindows) {
    $id        = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "This script must be run as Administrator. Right-click PowerShell and select 'Run as Administrator', then try again." -ErrorAction Continue
        return 1
    }
}

$tempDir = [IO.Path]::GetTempPath()
$caFileName = "ca_{0}.crt" -f ([guid]::NewGuid().ToString("N"))
$CA_FILE = Join-Path $tempDir $caFileName

# ── Ctrl+C handler ────────────────────────────────────────────────────────────
# Initialise to safe defaults so the finally block can reference these variables
# even if console setup fails (e.g., non-interactive/headless environments).
$originalTreatControlCAsInput = $false
$cancelKeyPressSourceId       = "install-ca-cancelkeypress-$([guid]::NewGuid().ToString('N'))"
$cancelKeyPressSubscription   = $null
try {
    $originalTreatControlCAsInput = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $false
    $cancelKeyPressSubscription = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -SourceIdentifier $cancelKeyPressSourceId -Action {
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
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -SkipCertificateCheck -TimeoutSec 30
    } else {
        # PowerShell 5.x: bypass certificate validation via ServicePointManager
        $origCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -TimeoutSec 30
        } finally {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $origCallback
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
    return 1
}

# ── 2. Fetch or copy the CA certificate ───────────────────────────────────────

Write-Host ""
if ($CA_SOURCE -match '^https?://') {
    Write-Host "==> Fetching CA certificate from $CA_SOURCE ..."
    $downloadOk = $false
    try {
        Invoke-WebRequest -Uri $CA_SOURCE -OutFile $CA_FILE -TimeoutSec 30
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
            return 1
        }
    }
} else {
    Write-Host "==> Copying CA certificate from $CA_SOURCE ..."
    Copy-Item -LiteralPath $CA_SOURCE -Destination $CA_FILE -Force
}

try {
    # X509Certificate2(string) on .NET 7+ (required by PS7+) handles both PEM and DER
    # via the OS certificate APIs (CryptQueryObject on Windows), which are lenient about
    # line endings and encoding variants.  This is more compatible than CreateFromPemFile
    # whose managed PEM parser is stricter about line-ending consistency.
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CA_FILE)
} catch {
    Write-Error "File is not a valid certificate." -ErrorAction Continue
    return 1
}

Write-Host "    Subject  : $($cert.Subject)"
Write-Host "    NotAfter : $($cert.NotAfter)"

# ── Verify the certificate is a CA certificate ───────────────────────────────
$basicConstraintsExtensionRaw = $cert.Extensions | Where-Object {
    $_.Oid.Value -eq '2.5.29.19'
} | Select-Object -First 1
if ($null -eq $basicConstraintsExtensionRaw) {
    Write-Error "The provided certificate does not contain a BasicConstraints extension and cannot be used as a CA certificate." -ErrorAction Continue
    return 1
}
$basicConstraintsExtension = $basicConstraintsExtensionRaw -as [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]
if ($null -eq $basicConstraintsExtension) {
    $basicConstraintsExtension = New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension $basicConstraintsExtensionRaw, $basicConstraintsExtensionRaw.Critical
}
if (-not $basicConstraintsExtension.CertificateAuthority) {
    Write-Error "The provided certificate is not a CA certificate (BasicConstraints CA=FALSE). Only CA certificates can be installed into the root trust store." -ErrorAction Continue
    return 1
}

# Advisory KeyUsage check — warn if keyCertSign is absent but do not block installation.
# BasicConstraints CA=TRUE is the authoritative check; real-world root CAs sometimes omit
# or encode KeyUsage differently, so a hard failure here breaks legitimate use-cases.
$keyUsageExtensionRaw = $cert.Extensions | Where-Object {
    $_.Oid.Value -eq '2.5.29.15'
} | Select-Object -First 1
if ($null -eq $keyUsageExtensionRaw) {
    Write-Warning "The provided certificate does not have a KeyUsage extension. Proceeding, but verify the certificate is a suitable CA certificate."
} else {
    $keyUsageExtension = $keyUsageExtensionRaw -as [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]
    if ($null -eq $keyUsageExtension) {
        $keyUsageExtension = New-Object System.Security.Cryptography.X509Certificates.X509KeyUsageExtension $keyUsageExtensionRaw, $keyUsageExtensionRaw.Critical
    }
    $requiredKeyUsage = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign
    if (($keyUsageExtension.KeyUsages -band $requiredKeyUsage) -eq 0) {
        Write-Warning "The provided certificate's KeyUsage does not include keyCertSign. Proceeding, but verify the certificate is a suitable CA certificate."
    }
}

# Derive CA_NAME from the CN field of the subject
$CA_NAME = if ($cert.Subject -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $cert.Subject }

Write-Host "    CA Name  : $CA_NAME"

# ── Non-Windows short-circuit ────────────────────────────────────────────────
if (-not $IsWindows) {
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
            return 1
        }
        Write-Host "    Installed: $systemCaFile"
    } else {
        Write-Host ""
        Write-Host "==> Windows-specific steps skipped (non-Windows platform)."
    }
    Write-Host ""
    Write-Host "==> All done. Fully quit and restart any open browsers for changes to take effect."
    return 0
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
    # Prefer an exact thumbprint match (certificate already installed),
    # and only fall back to Subject/NotAfter for "newer/older" comparisons.
    $existing = $checkStore.Certificates |
                Where-Object { $_.Thumbprint -eq $cert.Thumbprint } |
                Select-Object -First 1

    if (-not $existing) {
        $existing = @($checkStore.Certificates | Where-Object { $_.Subject -eq $cert.Subject }) |
                    Sort-Object NotAfter -Descending | Select-Object -First 1
    }
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
            return 0
        }
    } elseif ($cert.NotAfter -gt $existing.NotAfter) {
        $days = [int]($cert.NotAfter - $existing.NotAfter).TotalDays
        Write-Host "    Status   : Remote certificate is newer by $days day(s) — update recommended."
    } elseif ($cert.NotAfter -lt $existing.NotAfter) {
        $days = [int]($existing.NotAfter - $cert.NotAfter).TotalDays
        Write-Host "    Status   : WARNING — Installed certificate expires $days day(s) LATER than the remote one."
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
        # First, check for an existing certificate with the same thumbprint
        $existingThumbprintCerts = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
        if ($existingThumbprintCerts) {
            Write-Host "    Certificate with the same thumbprint is already present in LocalMachine\Root. Skipping add to avoid duplicate."
        } else {
            # Optionally clean up older certificates with the same subject but different thumbprints
            $subjectMatches = $store.Certificates | Where-Object { $_.Subject -eq $cert.Subject }
            if ($subjectMatches) {
                if ($Force) {
                    foreach ($old in $subjectMatches) {
                        if ($old.Thumbprint -ne $cert.Thumbprint) {
                            Write-Host "    Removing existing certificate with same subject but different thumbprint $($old.Thumbprint) from LocalMachine\Root."
                            $store.Remove($old)
                        }
                    }
                } else {
                    Write-Host "    Warning: Existing certificate(s) with the same subject are present in LocalMachine\Root."
                    Write-Host "             To replace older certificates with the new one, re-run this script with -Force."
                }
            }
            $store.Add($cert)
            Write-Host "    Done."
        }
    } finally {
        $store.Close()
    }
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
    # Only proceed with Firefox-specific steps if Firefox is actually installed.
    $ffExe = @(
        "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $ffExe) {
        Write-Host "    Firefox is not installed — skipping."
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
return 0
} finally {
    try {
        [Console]::TreatControlCAsInput = $originalTreatControlCAsInput
    } catch {
        # Ignore failures restoring console state
    }

    if ($null -ne $cancelKeyPressSubscription) {
        try {
            Unregister-Event -SourceIdentifier $cancelKeyPressSourceId -ErrorAction SilentlyContinue
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
}

function ConvertTo-InstallArguments {
    param(
        [string[]]$Arguments
    )

    $result = @{
        CASource = ""
        Force = $false
        Yes = $false
    }

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        switch ($arg) {
            '--url' { if ($i + 1 -ge $Arguments.Count) { throw "Missing value for $arg" }; $i++; $result.CASource = $Arguments[$i] }
            '-u' { if ($i + 1 -ge $Arguments.Count) { throw "Missing value for $arg" }; $i++; $result.CASource = $Arguments[$i] }
            '-CASource' { if ($i + 1 -ge $Arguments.Count) { throw "Missing value for $arg" }; $i++; $result.CASource = $Arguments[$i] }
            '--force' { $result.Force = $true }
            '-f' { $result.Force = $true }
            '-Force' { $result.Force = $true }
            '--yes' { $result.Yes = $true }
            '-y' { $result.Yes = $true }
            '-Yes' { $result.Yes = $true }
            default {
                if ([string]::IsNullOrWhiteSpace($result.CASource)) {
                    $result.CASource = $arg
                } else {
                    throw "Unknown argument: $arg"
                }
            }
        }
    }

    return $result
}

$invokedAsDotSource = $MyInvocation.InvocationName -eq '.'
$runningFromFile = -not [string]::IsNullOrWhiteSpace($PSCommandPath)
$shouldAutoRun = $runningFromFile -or ($args.Count -gt 0)

if (-not $shouldAutoRun) {
    if (-not $invokedAsDotSource) {
        $global:__Install_InstallCalled = $false

        if ($global:__Install_OnIdleSub) {
            try { Unregister-Event -SubscriptionId $global:__Install_OnIdleSub.Id -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Id $global:__Install_OnIdleSub.Id -Force -ErrorAction SilentlyContinue } catch { }
            $global:__Install_OnIdleSub = $null
        }

        $global:__Install_OnIdleSub = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
            if (-not $global:__Install_InstallCalled) {
                try {
                    $code = Install
                    if ($null -eq $code) { $code = 0 }
                    $global:LASTEXITCODE = [int]$code
                } catch {
                    Write-Error $_
                }
            }

            if ($global:__Install_OnIdleSub) {
                try { Unregister-Event -SubscriptionId $global:__Install_OnIdleSub.Id -ErrorAction SilentlyContinue } catch { }
                try { Remove-Job -Id $global:__Install_OnIdleSub.Id -Force -ErrorAction SilentlyContinue } catch { }
                $global:__Install_OnIdleSub = $null
            }
        }
    }
    return
}

$parsed = ConvertTo-InstallArguments -Arguments $args
$exitCode = Install -CASource $parsed.CASource -Force:$parsed.Force -Yes:$parsed.Yes
if ($null -eq $exitCode) { $exitCode = 0 }

if ($runningFromFile -and -not $invokedAsDotSource) {
    exit ([int]$exitCode)
}

$global:LASTEXITCODE = [int]$exitCode
return
