#!/usr/bin/env bash
# Install a CA certificate into system and browser trust stores
#
# Browsers handled:
#   - System trust store          (/usr/local/share/ca-certificates + update-ca-certificates)
#   - Google Chrome (deb)         uses shared NSS at ~/.pki/nssdb
#   - Chromium (deb/snap)         uses shared NSS at ~/.pki/nssdb / snap-isolated .pki/nssdb
#   - Microsoft Edge (deb)        uses shared NSS at ~/.pki/nssdb
#   - Brave (snap)                snap-isolated .pki/nssdb per version
#   - Firefox (deb/non-snap)      per-profile cert9.db under ~/.mozilla/firefox/
#   - Firefox (snap)              per-profile cert9.db under ~/snap/firefox/
#
# Usage: bash install-ca-cert.sh [CA-URL-or-path] [--force|-f] [--yes|-y]
#   or:  bash <(curl -fsSL https://raw.githubusercontent.com/IlmLV/install-ca-cert/main/install-ca-cert.sh)

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
FORCE=false
YES=false
CA_SOURCE_ARG=""

for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    --yes|-y)   YES=true ;;
    --*) echo "ERROR: Unknown option: $arg" >&2; exit 1 ;;
    *) CA_SOURCE_ARG="$arg" ;;
  esac
done

WORK_DIR="$(mktemp -d)"
SYSTEM_CA_DIR="/usr/local/share/ca-certificates"

cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

on_interrupt() {
  echo ""
  echo "Interrupted — exiting."
  exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# ── Helpers ───────────────────────────────────────────────────────────────────

confirm() {
  if [[ "$YES" == true ]]; then
    echo "$1 [y/N] y"
    return 0
  fi
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Add CA to a single NSS sql: database directory
add_to_nss_db() {
  local db_dir="$1"
  certutil -d "sql:$db_dir" -D -n "$CA_NAME" 2>/dev/null || true
  certutil -d "sql:$db_dir" -A -n "$CA_NAME" -t "CT,," -i "$CA_FILE"
}

# Install CA into a list of NSS database directories with a confirmation prompt
install_to_nss_dbs() {
  local label="$1"; shift
  local dirs=("$@")

  echo ""
  echo "==> $label"

  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "    No NSS databases found — skipping."
    return
  fi

  for db in "${dirs[@]}"; do
    echo "    $db"
  done

  if confirm "    Add '$CA_NAME' to the above databases?"; then
    for db in "${dirs[@]}"; do
      add_to_nss_db "$db"
      echo "    OK: $db"
    done
  else
    echo "    Skipped."
  fi
}

# Collect cert9.db parent dirs from a list of search roots (deduped, sorted)
find_nss_dbs() {
  local results=()
  for root in "$@"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r d; do
      [[ -n "$d" ]] && results+=("$d")
    done < <(find "$root" -name "cert9.db" -exec dirname {} \; 2>/dev/null)
  done
  [[ ${#results[@]} -eq 0 ]] && return
  printf '%s\n' "${results[@]}" | sort -u
}

# ── 1. Resolve CA source ──────────────────────────────────────────────────────

if [[ -n "$CA_SOURCE_ARG" ]]; then
  CA_SOURCE="$CA_SOURCE_ARG"
else
  read -r -p "Enter CA certificate URL or file path: " CA_SOURCE
fi

if [[ -z "$CA_SOURCE" ]]; then
  echo "ERROR: No CA source provided." >&2
  exit 1
fi

# ── 2. Fetch or copy the CA certificate ───────────────────────────────────────

CA_FILE="$WORK_DIR/ca.crt"

if [[ "$CA_SOURCE" =~ ^https?:// ]]; then
  echo "==> Fetching CA certificate from $CA_SOURCE ..."
  if ! curl_err=$(curl -fsSL "$CA_SOURCE" -o "$CA_FILE" 2>&1); then
    echo "    WARNING: Secure download failed. The server's TLS certificate may be invalid or self-signed."
    echo "    Detail  : $curl_err"
    if confirm "    Retry without TLS certificate validation (insecure)?"; then
      curl -kfsSL "$CA_SOURCE" -o "$CA_FILE"
    else
      echo "ERROR: Download aborted." >&2
      exit 1
    fi
  fi
else
  echo "==> Copying CA certificate from $CA_SOURCE ..."
  cp "$CA_SOURCE" "$CA_FILE"
fi

if ! openssl x509 -in "$CA_FILE" -noout 2>/dev/null; then
  echo "ERROR: File is not a valid PEM certificate." >&2
  exit 1
fi

echo "    $(openssl x509 -in "$CA_FILE" -noout -subject -enddate | tr '\n' '  ')"

# Derive CA_NAME from the certificate CN, fall back to full subject
CA_SUBJECT=$(openssl x509 -in "$CA_FILE" -noout -subject 2>/dev/null)
CA_CN=$(printf '%s' "$CA_SUBJECT" | sed 's/.*CN\s*=\s*//' | sed 's/,.*//')
CA_NAME="${CA_CN:-$CA_SUBJECT}"

# Derive a safe filename from CA_NAME
_safe_name="$(echo "$CA_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
CA_FILENAME="${_safe_name}.crt"
SYSTEM_CA_FILE="$SYSTEM_CA_DIR/$CA_FILENAME"

echo "    CA Name  : $CA_NAME"
echo "    CA File  : $SYSTEM_CA_FILE"

# ── 3. Check existing certificate in system store ────────────────────────────
echo ""
echo "==> Checking for existing certificate at $SYSTEM_CA_FILE ..."

if [[ -f "$SYSTEM_CA_FILE" ]]; then
  existing_end=$(openssl x509 -in "$SYSTEM_CA_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
  remote_end=$(openssl x509   -in "$CA_FILE"         -noout -enddate 2>/dev/null | cut -d= -f2)

  existing_ts=$(date -d "$existing_end" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$existing_end" +%s)
  remote_ts=$(date    -d "$remote_end"   +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$remote_end"   +%s)

  existing_fp=$(openssl x509 -in "$SYSTEM_CA_FILE" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  remote_fp=$(openssl x509   -in "$CA_FILE"         -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)

  echo "    Found    : $existing_fp"
  echo "    expires  : $existing_end"
  echo "    Remote   : $remote_fp"
  echo "    expires  : $remote_end"

  if [[ "$existing_fp" == "$remote_fp" ]]; then
    if [[ "$FORCE" == true ]]; then
      echo "    Status   : Already up-to-date but --force was specified, continuing."
    else
      echo "    Status   : Already up-to-date (same certificate). Nothing to do."
      exit 0
    fi
  elif (( remote_ts > existing_ts )); then
    days=$(( (remote_ts - existing_ts) / 86400 ))
    echo "    Status   : Remote certificate is newer by $days day(s) — update recommended."
  elif (( remote_ts < existing_ts )); then
    days=$(( (existing_ts - remote_ts) / 86400 ))
    echo "    Status   : WARNING — installed certificate expires $days day(s) LATER than the remote one."
  else
    echo "    Status   : Different certificate with the same expiry date."
  fi
else
  echo "    Status   : No existing certificate found — fresh install."
fi

# ── 4. System trust store ─────────────────────────────────────────────────────
echo ""
echo "==> System trust store"
echo "    sudo cp $CA_FILE $SYSTEM_CA_FILE"
echo "    sudo update-ca-certificates"

if confirm "    Proceed?"; then
  sudo cp "$CA_FILE" "$SYSTEM_CA_FILE"
  sudo update-ca-certificates
  echo "    Done."
else
  echo "    Skipped."
fi

# ── 5. Ensure certutil is available ──────────────────────────────────────────
if ! command -v certutil &>/dev/null; then
  echo ""
  echo "==> certutil not found — required for NSS database updates."
  echo "    sudo apt-get install -y libnss3-tools"
  if confirm "    Proceed?"; then
    sudo apt-get install -y libnss3-tools
  else
    echo "    Cannot continue without certutil." >&2
    exit 1
  fi
fi

# ── 6. Shared NSS database ────────────────────────────────────────────────────
#
#  Used by deb-installed browsers that delegate to the OS NSS store:
#    - Google Chrome
#    - Chromium
#    - Microsoft Edge
#
SHARED_NSS="$HOME/.pki/nssdb"
if [[ ! -d "$SHARED_NSS" ]]; then
  echo ""
  echo "    Creating shared NSS database at $SHARED_NSS ..."
  mkdir -p "$SHARED_NSS"
  certutil -d "sql:$SHARED_NSS" -N --empty-password
fi

install_to_nss_dbs \
  "Shared NSS database (Google Chrome, Chromium, Edge — deb installs)" \
  "$SHARED_NSS"

# ── 7. Brave (snap) ───────────────────────────────────────────────────────────
#
#  Brave snap is isolated from the shared NSS database and maintains its own
#  .pki/nssdb per installed snap version under ~/snap/brave/.
#
mapfile -t BRAVE_DIRS < <(find_nss_dbs "$HOME/snap/brave")

install_to_nss_dbs "Brave (snap)" "${BRAVE_DIRS[@]}"

# ── 8. Chromium (snap) ────────────────────────────────────────────────────────
mapfile -t CHROMIUM_SNAP_DIRS < <(find_nss_dbs "$HOME/snap/chromium")

install_to_nss_dbs "Chromium (snap)" "${CHROMIUM_SNAP_DIRS[@]}"

# ── 9. Firefox ────────────────────────────────────────────────────────────────
#
#  Firefox stores the CA in each profile's cert9.db rather than a shared store.
#  Both the deb install (~/.mozilla/firefox/) and the snap install
#  (~/snap/firefox/) are handled.
#
mapfile -t FIREFOX_DIRS < <(find_nss_dbs \
  "$HOME/.mozilla/firefox" \
  "$HOME/snap/firefox")

install_to_nss_dbs "Firefox (all profiles — deb + snap)" "${FIREFOX_DIRS[@]}"

# ── 10. Verify ────────────────────────────────────────────────────────────────
echo ""
echo "==> Verifying system trust ..."
SYSTEM_CA_PATH="/etc/ssl/certs"
if openssl verify -CApath "$SYSTEM_CA_PATH" "$CA_FILE" &>/dev/null; then
  echo "    System trust: OK"
else
  echo "    System trust: FAILED (check that update-ca-certificates succeeded and that the CA is present in $SYSTEM_CA_PATH)"
fi

echo ""
echo "==> All done. Fully quit and restart any open browsers for changes to take effect."
