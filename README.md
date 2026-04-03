# install-ca-cert

[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-blue)](https://github.com/IlmLV/install-ca-cert)
[![Tests](https://github.com/IlmLV/install-ca-cert/actions/workflows/test.yml/badge.svg)](https://github.com/IlmLV/install-ca-cert/actions/workflows/test.yml)
[![Bash](https://img.shields.io/badge/bash-4.0%2B-4EAA25?logo=gnubash&logoColor=white)](install-ca-cert.sh)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%2B-5391FE?logo=powershell&logoColor=white)](install-ca-cert.ps1)
[![License](https://img.shields.io/github/license/IlmLV/install-ca-cert)](LICENSE)
[![Stars](https://img.shields.io/github/stars/IlmLV/install-ca-cert?style=flat)](https://github.com/IlmLV/install-ca-cert/stargazers)

Modern systems maintain multiple independent certificate trust stores — one for the OS, and separate ones for each browser. **install-ca-cert** handles all of them in a single run on Linux (Debian/Ubuntu) and Windows, so a custom CA is trusted everywhere without manual per-store setup.

---

## Features

- Accepts a CA certificate as a **URL** or **local file path** — or prompts interactively
- Derives the CA name and filename automatically from the certificate subject
- Compares the certificate against any existing installation before making changes — reports fingerprint, expiry, and whether an update is needed
- Exits early without changes if the certificate is already up-to-date (override with `-f`)
- Prompts for confirmation before each store is modified (suppress with `-y`)
- Verifies the installation at the end

---

## Platform support

| Platform | Script | Requirements |
| -------- | ------ | ------------ |
| ![Linux](https://img.shields.io/badge/Debian%20%7C%20Ubuntu-FCC624?logo=linux&logoColor=black) | `install-ca-cert.sh` | `bash`, `curl`, `openssl`, `sudo`, `libnss3-tools` (auto-installed if missing) |
| ![Windows](https://img.shields.io/badge/Windows-0078D4?logo=windows&logoColor=white) | `install-ca-cert.ps1` | PowerShell 5.1+, Administrator privileges |

---

## Browser coverage

| Browser        | 🐧 Linux                                                           | 🪟 Windows                                |
| -------------- | ------------------------------------------------------------------ | ----------------------------------------- |
| Google Chrome  | Shared NSS `~/.pki/nssdb`                                          | Windows Certificate Store¹                |
| Chromium       | Shared NSS `~/.pki/nssdb` (deb) · snap NSS `~/snap/chromium/`      | Windows Certificate Store¹                |
| Microsoft Edge | Shared NSS `~/.pki/nssdb`                                          | Windows Certificate Store¹                |
| Brave          | Snap NSS `~/snap/brave/`                                           | Windows Certificate Store¹                |
| Firefox        | Per-profile `cert9.db` (`~/.mozilla/firefox/` · `~/snap/firefox/`) | Per-profile `cert9.db` via `certutil.exe` |

> ¹ `LocalMachine\Root` — one write covers all Chromium-based browsers on Windows.
>
> The shared NSS database `~/.pki/nssdb` is created automatically on Linux if it does not exist.

---

## Usage

| Flag               | Long form             | Description                                             |
| ------------------ | --------------------- | ------------------------------------------------------- |
| `-u <url-or-path>` | `--url <url-or-path>` | Certificate URL or local file path                      |
| `-y`               | `--yes`               | Auto-approve all prompts                                |
| `-f`               | `--force`             | Reinstall even if the certificate is already up-to-date |

### 🐧 Linux

**Interactive** — prompts for the certificate URL or file path:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IlmLV/install-ca-cert/main/install-ca-cert.sh)
```

**Non-interactive** — certificate URL and auto-approve provided upfront:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IlmLV/install-ca-cert/main/install-ca-cert.sh) -u https://example.com/ca.crt -y
```

> `sudo` is required for writing to `/usr/local/share/ca-certificates/`. The script will prompt for your password at that step.

### 🪟 Windows

**Interactive** — prompts for the certificate URL or file path:
```powershell
irm https://raw.githubusercontent.com/IlmLV/install-ca-cert/main/install-ca-cert.ps1 | iex
```

**Non-interactive** — certificate URL and auto-approve provided upfront:
```powershell
iex "& {$(irm https://raw.githubusercontent.com/IlmLV/install-ca-cert/main/install-ca-cert.ps1)} -u 'https://example.com/ca.crt' -y"
```

> Requires PowerShell 5.1+ and Administrator privileges.

---

## How it works

### Certificate comparison

Before modifying any trust store, the script checks whether the certificate is already installed:

1. Fetches or copies the certificate from the provided source
2. Validates it is a well-formed PEM certificate
3. Looks up any existing certificate with the same subject in the system trust store
4. Compares SHA-256 fingerprints and expiry dates, and reports one of:
   - **Already up-to-date** — exits without changes
   - **Remote is newer** — recommends update, proceeds to install
   - **Installed is newer** — warns that the remote cert expires sooner than what is installed
   - **Fresh install** — no existing certificate found

### Trust store locations

#### 🐧 Linux system store

The certificate is copied to `/usr/local/share/ca-certificates/<derived-name>.crt` and registered with `update-ca-certificates`. The filename is derived automatically from the certificate's Common Name (CN).

#### 🐧 Linux NSS databases

NSS (`cert9.db`) databases are located by scanning known directories for each browser. Each discovered database is listed before the user is asked to confirm. The CA is added using `certutil` from the `libnss3-tools` package.

#### 🪟 Windows Certificate Store

The certificate is added to `LocalMachine\Root` using the .NET `X509Store` API. This single store is read by all Chromium-based browsers on Windows.

#### 🦊 Firefox (both platforms)

Firefox maintains its own NSS databases independent of the OS store. All profiles under the standard Firefox profile directory are discovered and listed. On Linux, `certutil` from `libnss3-tools` is used. On Windows, `certutil.exe` bundled with the Firefox installation is used.

---

## Files

```
install-ca-cert/
├── install-ca-cert.sh          # Bash script for Linux
├── install-ca-cert.ps1         # PowerShell script for Windows
└── tests/
    ├── run-tests.sh            # Runs Docker-containerized test suites
    ├── linux.bats              # Bats test suite for install-ca-cert.sh
    ├── windows.ps1             # Pester test suite for install-ca-cert.ps1
    ├── Dockerfile.debian       # Debian test container image
    ├── Dockerfile.ubuntu       # Ubuntu test container image
    ├── docker-linux-setup.sh   # Installs browsers and tooling inside the test container
    ├── entrypoint.linux.sh     # Container entry point — runs cert generation and Bats suite
    ├── generate-certs.sh       # Generates test certificates at runtime (Bash)
    └── generate-certs.ps1      # Generates test certificates at runtime (PowerShell)
```

---

## Running tests

### 🐧 Linux

Requires Docker.

```bash
# Run all suites (Debian + Ubuntu)
bash tests/run-tests.sh

# Run a specific suite
bash tests/run-tests.sh linux-ubuntu
bash tests/run-tests.sh linux-debian
```

### 🪟 Windows

Requires [Pester](https://pester.dev) and PowerShell 5.1+.

```powershell
Invoke-Pester tests/windows.ps1
```

---

## License

This project is licensed under the [MIT License](LICENSE).
