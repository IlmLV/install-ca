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

# Install Vivaldi (deb)
curl -fsSL https://repo.vivaldi.com/archive/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/vivaldi.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/vivaldi.gpg] https://repo.vivaldi.com/archive/deb/ stable main" \
  > /etc/apt/sources.list.d/vivaldi.list

# Install Brave (deb)
curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
  -o /etc/apt/keyrings/brave-browser-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
  > /etc/apt/sources.list.d/brave-browser-release.list

# Install Firefox (Mozilla APT repo)
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg | gpg --dearmor -o /etc/apt/keyrings/mozilla.gpg
echo "deb [signed-by=/etc/apt/keyrings/mozilla.gpg] https://packages.mozilla.org/apt mozilla main" \
  > /etc/apt/sources.list.d/mozilla.list

apt-get update
apt-get install -y --no-install-recommends \
  google-chrome-stable \
  microsoft-edge-stable \
  vivaldi-stable \
  brave-browser

if ! apt-get install -y --no-install-recommends firefox; then
  apt-get install -y --no-install-recommends firefox-esr
fi

# Chromium (prefer real package, fallback to Chrome wrapper if unavailable)
if ! apt-get install -y --no-install-recommends chromium; then
  cat >/usr/local/bin/chromium <<'EOF'
#!/usr/bin/env bash
exec google-chrome "$@"
EOF
  chmod +x /usr/local/bin/chromium
fi

rm -rf /var/lib/apt/lists/*

# Script runs as root inside the container — allow sudo without a password
echo "root ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/root-nopasswd
chmod 0440 /etc/sudoers.d/root-nopasswd
