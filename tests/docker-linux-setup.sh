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

# Install Google Chrome (deb)
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-linux.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-linux.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
  > /etc/apt/sources.list.d/google-chrome.list

# Install Microsoft Edge (deb)
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main" \
  > /etc/apt/sources.list.d/microsoft-edge.list

# Install Brave (deb)
curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
  -o /etc/apt/keyrings/brave-browser-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
  > /etc/apt/sources.list.d/brave-browser-release.list

# Install Firefox (Mozilla APT repo)
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg | gpg --dearmor -o /etc/apt/keyrings/mozilla.gpg
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
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian bookworm main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian-security bookworm-security main
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian bookworm-updates main
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
