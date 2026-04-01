#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

apt-get update
apt-get install -y --no-install-recommends \
  bats \
  ca-certificates \
  curl \
  gnupg \
  debian-archive-keyring \
  libnss3-tools \
  openssl \
  sudo \
  wget
rm -rf /var/lib/apt/lists/*

install -d /etc/apt/keyrings

download_and_verify_gpg_key() {
  local url="$1"
  local expected_fpr="$2"
  local target="$3"

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  curl -fsSL "$url" -o "$tmp"

  # Extract the first fingerprint from the key file
  local actual_fpr
  actual_fpr="$(gpg --show-keys --with-colons "$tmp" | awk -F: '/^fpr:/ {print $10; exit}')"

  if [ -z "$actual_fpr" ]; then
    echo "ERROR: Unable to extract fingerprint from key downloaded from $url" >&2
    exit 1
  fi

  if [ "$actual_fpr" != "$expected_fpr" ]; then
    echo "ERROR: Fingerprint mismatch for key from $url" >&2
    echo "       Expected: $expected_fpr" >&2
    echo "       Actual:   $actual_fpr" >&2
    exit 1
  fi

  # Convert to a keyring suitable for APT
  gpg --dearmor -o "$target" "$tmp"
}

# Install Google Chrome (deb)
# Google Linux package signing key fingerprint (from official documentation)
GOOGLE_LINUX_KEY_FPR="EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796"
download_and_verify_gpg_key \
  "https://dl.google.com/linux/linux_signing_key.pub" \
  "$GOOGLE_LINUX_KEY_FPR" \
  "/etc/apt/keyrings/google-linux.gpg"
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-linux.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
  > /etc/apt/sources.list.d/google-chrome.list

# Install Microsoft Edge (deb)
# Microsoft package repository key fingerprint (from official documentation)
MICROSOFT_EDGE_KEY_FPR="BC528686B50D79E339D3721CEB3E94ADBE1229CF"
download_and_verify_gpg_key \
  "https://packages.microsoft.com/keys/microsoft.asc" \
  "$MICROSOFT_EDGE_KEY_FPR" \
  "/etc/apt/keyrings/microsoft.gpg"
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main" \
  > /etc/apt/sources.list.d/microsoft-edge.list

# Install Brave (deb)
# Brave browser APT archive key fingerprint (from official documentation)
BRAVE_BROWSER_KEY_FPR="DBF1A116C220B8C7164F98230686B78420038257"
download_and_verify_gpg_key \
  "https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg" \
  "$BRAVE_BROWSER_KEY_FPR" \
  "/etc/apt/keyrings/brave-browser-archive-keyring.gpg"
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
  > /etc/apt/sources.list.d/brave-browser-release.list

# Install Firefox (Mozilla APT repo)
# Mozilla APT repository signing key fingerprint (from official documentation)
MOZILLA_APT_KEY_FPR="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
download_and_verify_gpg_key \
  "https://packages.mozilla.org/apt/repo-signing-key.gpg" \
  "$MOZILLA_APT_KEY_FPR" \
  "/etc/apt/keyrings/mozilla.gpg"
echo "deb [signed-by=/etc/apt/keyrings/mozilla.gpg] https://packages.mozilla.org/apt mozilla main" \
  > /etc/apt/sources.list.d/mozilla.list
cat >/etc/apt/preferences.d/mozilla-firefox <<'EOF'
Package: firefox*
Pin: origin packages.mozilla.org
Pin-Priority: 1001
EOF

apt-get update
apt-get install -y --no-install-recommends \
  google-chrome-stable \
  microsoft-edge-stable \
  brave-browser

if ! apt-get install -y --no-install-recommends firefox; then
  apt-get install -y --no-install-recommends firefox-esr
fi

# Chromium (deb). Ubuntu noble provides a snap stub, so pull a real deb from Debian.
cat >/etc/apt/sources.list.d/debian-bookworm.list <<'EOF'
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian bookworm main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian-security bookworm-security main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian bookworm-updates main
EOF
cat >/etc/apt/preferences.d/chromium <<'EOF'
Package: chromium*
Pin: release n=bookworm
Pin-Priority: 1001
EOF
apt-get update
if ! apt-get install -y --no-install-recommends chromium chromium-common chromium-sandbox; then
  echo "WARNING: debian chromium install failed; falling back to Ubuntu stub" >&2
  apt-get install -y --no-install-recommends chromium || true
  apt-get install -y --no-install-recommends chromium-browser || true
fi
rm -f /etc/apt/sources.list.d/debian-bookworm.list /etc/apt/preferences.d/chromium

rm -rf /var/lib/apt/lists/*

# Script runs as root inside the container — allow sudo without a password
echo "root ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/root-nopasswd
chmod 0440 /etc/sudoers.d/root-nopasswd
