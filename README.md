# install-ca-cert

[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-blue)](https://github.com/IlmLV/install-ca-cert)
[![Bash](https://img.shields.io/badge/bash-4.0%2B-4EAA25?logo=gnubash&logoColor=white)](install-ca-cert.sh)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%2B-5391FE?logo=powershell&logoColor=white)](install-ca-cert.ps1)
[![License](https://img.shields.io/github/license/IlmLV/install-ca-cert)](LICENSE)
[![Stars](https://img.shields.io/github/stars/IlmLV/install-ca-cert?style=flat)](https://github.com/IlmLV/install-ca-cert/stargazers)

A cross-platform utility for installing a custom CA certificate into the OS system trust store and all major browser trust stores. Supports both Linux (Bash) and Windows (PowerShell).

---

## Features

- Accepts a CA certificate as a **URL** or **local file path** — or prompts interactively
- Derives the CA name and system filename automatically from the certificate subject
- **Compares the remote certificate against the currently installed one** before making any changes — shows fingerprint and expiry of both, reports whether an update is needed
- Exits early without changes if the certificate is already up-to-date (override with `--force` / `-Force`)
- Installs into **all relevant trust stores** in a single run — OS store and per-browser stores
- Prompts for confirmation before each store is modified
- Verifies the installation at the end

---

## Platform support

| Platform              | Script                | Requirements                                                                   |
| --------------------- | --------------------- | ------------------------------------------------------------------------------ |
| Linux (Debian/Ubuntu) | `install-ca-cert.sh`  | `bash`, `curl`, `openssl`, `sudo`, `libnss3-tools` (auto-installed if missing) |
| Windows               | `install-ca-cert.ps1` | PowerShell 5.1+, Administrator privileges, Firefox install (for Firefox step)  |

---

## Browser coverage

### Linux

| Browser              | Trust store used                                   |
| -------------------- | -------------------------------------------------- |
| Google Chrome (deb)  | Shared NSS at `~/.pki/nssdb`                       |
| Chromium (deb)       | Shared NSS at `~/.pki/nssdb`                       |
| Chromium (snap)      | Snap-isolated NSS under `~/snap/chromium/`         |
| Microsoft Edge (deb) | Shared NSS at `~/.pki/nssdb`                       |
| Vivaldi (deb)        | Shared NSS at `~/.pki/nssdb`                       |
| Brave (snap)         | Snap-isolated NSS under `~/snap/brave/`            |
| Firefox (deb)        | Per-profile `cert9.db` under `~/.mozilla/firefox/` |
| Firefox (snap)       | Per-profile `cert9.db` under `~/snap/firefox/`     |

> **Note:** The shared NSS database at `~/.pki/nssdb` is created automatically if it does not exist.

### Windows

| Browser        | Trust store used                                          |
| -------------- | --------------------------------------------------------- |
| Google Chrome  | Windows Certificate Store (`LocalMachine\Root`)           |
| Microsoft Edge | Windows Certificate Store (`LocalMachine\Root`)           |
| Vivaldi        | Windows Certificate Store (`LocalMachine\Root`)           |
| Brave          | Windows Certificate Store (`LocalMachine\Root`)           |
| Chromium       | Windows Certificate Store (`LocalMachine\Root`)           |
| Firefox        | Per-profile `cert9.db` via Firefox-bundled `certutil.exe` |

> **Note:** On Windows, all Chromium-based browsers delegate certificate trust to the OS store — a single write to `LocalMachine\Root` covers all of them.

---

## Quick install (one-liner)

Run directly from GitHub — no cloning required. Both scripts prompt interactively for the certificate URL or local file path.

### Linux

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IlmLV/install-ca-cert/main/install-ca-cert.sh)
```

### Windows

Open PowerShell **as Administrator**:

```powershell
irm https://raw.githubusercontent.com/IlmLV/install-ca-cert/main/install-ca-cert.ps1 | iex
```

---

## Usage (from a local copy)

### Linux

```bash
bash install-ca-cert.sh
```

`sudo` access is required for writing to `/usr/local/share/ca-certificates/` and running `update-ca-certificates`. The script will prompt for your password at that step.

### Windows

Open PowerShell **as Administrator**, then:

```powershell
powershell -File install-ca-cert.ps1
```

> **Note:** The system certificate store step is skipped if the script is not running as Administrator. The Firefox step does not require elevation.

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

**Linux system store**

The certificate is copied to `/usr/local/share/ca-certificates/<derived-name>.crt` and registered with `update-ca-certificates`. The filename is derived automatically from the certificate's Common Name (CN).

**Linux NSS databases**

NSS (`cert9.db`) databases are located by scanning known directories for each browser. Each discovered database is listed before the user is asked to confirm. The CA is added using `certutil` from the `libnss3-tools` package.

**Windows Certificate Store**

The certificate is added to `LocalMachine\Root` using the .NET `X509Store` API. This single store is read by all Chromium-based browsers on Windows.

**Firefox (both platforms)**

Firefox maintains its own NSS databases independent of the OS store. All profiles under the standard Firefox profile directory are discovered and listed. On Linux, `certutil` from `libnss3-tools` is used. On Windows, `certutil.exe` bundled with the Firefox installation is used.

---

## Files

| File                  | Description                   |
| --------------------- | ----------------------------- |
| `install-ca-cert.sh`  | Bash script for Linux         |
| `install-ca-cert.ps1` | PowerShell script for Windows |

> The scripts write a temporary `ca.crt` file to their own directory during execution. This file is listed in `.gitignore`.
