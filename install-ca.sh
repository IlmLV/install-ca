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
# Usage: bash install-ca.sh [CA-URL-or-path] [--force|-f] [--yes|-y]
#   or:  curl -fsSL https://raw.githubusercontent.com/IlmLV/install-ca/main/install-ca.sh | bash -s -- <url> -y

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
FORCE=false
YES=false
CA_SOURCE_ARG=""

i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --force|-f) FORCE=true ;;
    --yes|-y)   YES=true ;;
    --url|-u)
      i=$((i + 1))
      if [[ $i -gt $# ]]; then
        echo "ERROR: ${arg} requires a value" >&2; exit 1
      fi
      if [[ -n "$CA_SOURCE_ARG" ]]; then
        echo "ERROR: Multiple CA sources provided: '$CA_SOURCE_ARG' and '${!i}'" >&2
        echo "Usage: bash install-ca.sh [CA-URL-or-path] [--url|-u <url>] [--force|-f] [--yes|-y]" >&2
        exit 1
      fi
      CA_SOURCE_ARG="${!i}"
      ;;
    --*|-*) echo "ERROR: Unknown option: $arg" >&2; exit 1 ;;
    *)
      if [[ -n "$CA_SOURCE_ARG" ]]; then
        echo "ERROR: Multiple positional arguments provided: '$CA_SOURCE_ARG' and '$arg'" >&2
        echo "Usage: bash install-ca.sh [CA-URL-or-path] [--url|-u <url>] [--force|-f] [--yes|-y]" >&2
        exit 1
      fi
      CA_SOURCE_ARG="$arg"
      ;;
  esac
  i=$((i + 1))
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

on_term() {
  echo ""
  echo "Terminated — exiting."
  exit 143
}

trap cleanup EXIT
trap on_interrupt INT
trap on_term TERM

# ── Helpers ───────────────────────────────────────────────────────────────────

confirm() {
  if [[ "$YES" == true ]]; then
    printf '%s [y/N] y\n' "$1"
    return 0
  fi
  reply=""
  if ! read -r -p "$1 [y/N] " reply </dev/tty; then
    reply=""
  fi
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
    done < <(find "$root" -name "cert9.db" -printf '%h\n' 2>/dev/null)
  done
  [[ ${#results[@]} -eq 0 ]] && return
  printf '%s\n' "${results[@]}" | sort -u
}

# ── 1. Resolve CA source ──────────────────────────────────────────────────────

if [[ -n "$CA_SOURCE_ARG" ]]; then
  CA_SOURCE="$CA_SOURCE_ARG"
else
  if ! read -r -p "Enter CA certificate URL or file path: " CA_SOURCE </dev/tty; then
    CA_SOURCE=""
  fi
fi

if [[ -z "$CA_SOURCE" ]]; then
  echo "ERROR: No CA source provided." >&2
  exit 1
fi

# ── 2. Fetch or copy the CA certificate ───────────────────────────────────────

CA_FILE="$WORK_DIR/ca.crt"

if [[ "$CA_SOURCE" =~ ^https?:// ]]; then
  echo "==> Fetching CA certificate from $CA_SOURCE ..."
  if ! curl_err=$(curl -fSsL --max-time 30 --connect-timeout 10 "$CA_SOURCE" -o "$CA_FILE" 2>&1); then
    echo "    WARNING: Secure download failed. The server's TLS certificate may be invalid or self-signed."
    echo "    Detail  : $curl_err"
    if confirm "    Retry without TLS certificate validation (insecure)?"; then
      curl -kfSsL --max-time 30 --connect-timeout 10 "$CA_SOURCE" -o "$CA_FILE"
    else
      echo "ERROR: Download aborted." >&2
      exit 1
    fi
  fi
else
  LOCAL_CA_SOURCE="$CA_SOURCE"
  if [[ "$LOCAL_CA_SOURCE" == "~" ]]; then
    LOCAL_CA_SOURCE="$HOME"
  elif [[ "$LOCAL_CA_SOURCE" == "~/"* ]]; then
    LOCAL_CA_SOURCE="$HOME/${LOCAL_CA_SOURCE#~/}"
  fi
  echo "==> Copying CA certificate from $LOCAL_CA_SOURCE ..."
  cp -- "$LOCAL_CA_SOURCE" "$CA_FILE"
fi

if ! openssl x509 -in "$CA_FILE" -noout 2>/dev/null; then
  echo "ERROR: File is not a valid PEM certificate." >&2
  exit 1
fi

# Verify the certificate has BasicConstraints CA:TRUE
_cert_text=$(openssl x509 -in "$CA_FILE" -noout -text 2>/dev/null)
if ! printf '%s' "$_cert_text" | grep -q "X509v3 Basic Constraints"; then
  echo "ERROR: The provided certificate does not contain a BasicConstraints extension and cannot be used as a CA certificate." >&2
  exit 1
fi
if ! printf '%s' "$_cert_text" | grep -qE "CA:(TRUE|true)"; then
  echo "ERROR: The provided certificate is not a CA certificate (BasicConstraints CA=FALSE). Only CA certificates can be installed into the root trust store." >&2
  exit 1
fi
unset _cert_text

echo "    Subject  : $(openssl x509 -in "$CA_FILE" -noout -subject 2>/dev/null | sed 's/^subject[[:space:]]*=[[:space:]]*//')"
echo "    NotAfter : $(openssl x509 -in "$CA_FILE" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"

# Derive CA_NAME from the certificate CN, fall back to full subject.
# Strip the leading "subject=" prefix emitted by OpenSSL and any leading "/"
# from old-style slash-delimited subjects (OpenSSL 1.x).
CA_SUBJECT=$(openssl x509 -in "$CA_FILE" -noout -subject 2>/dev/null \
  | sed 's/^subject[[:space:]]*=[[:space:]]*//' \
  | sed 's|^/||')
# sed -n with /p only prints when the CN pattern matches, so CA_CN is empty
# when there is no CN field — the fallback then uses the full stripped subject.
CA_CN=$(printf '%s' "$CA_SUBJECT" | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p' | sed 's/[[:space:]]*$//')
CA_NAME="${CA_CN:-$CA_SUBJECT}"

# Derive a safe filename from CA_NAME
_safe_name="$(printf '%s\n' "$CA_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
CA_FILENAME="${_safe_name:-custom-ca}.crt"
SYSTEM_CA_FILE="$SYSTEM_CA_DIR/$CA_FILENAME"

echo "    CA Name  : $CA_NAME"
echo "    CA File  : $SYSTEM_CA_FILE"

# ── 3. Check existing certificate in system store ────────────────────────────
echo ""
echo "==> Checking for existing certificate at $SYSTEM_CA_FILE ..."

if [[ -f "$SYSTEM_CA_FILE" ]]; then
  existing_end=$(openssl x509 -in "$SYSTEM_CA_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
  remote_end=$(openssl x509   -in "$CA_FILE"         -noout -enddate 2>/dev/null | cut -d= -f2)

  existing_ts=$(date -d "$existing_end" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$existing_end" +%s 2>/dev/null || true)
  remote_ts=$(date    -d "$remote_end"   +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$remote_end"   +%s 2>/dev/null || true)

  existing_fp=$(openssl x509 -in "$SYSTEM_CA_FILE" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  remote_fp=$(openssl x509   -in "$CA_FILE"         -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)

  echo "    Found    : $existing_fp"
  echo "    expires  : $existing_end"
  echo "    Remote   : $remote_fp"
  echo "    expires  : $remote_end"

  if [[ -z "$existing_ts" || -z "$remote_ts" ]]; then
    echo "    Status   : Cannot compare certificate dates — date parsing failed."
  elif [[ "$existing_fp" == "$remote_fp" ]]; then
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
_shared_nss_ready=true

if [[ ! -d "$SHARED_NSS" ]]; then
  echo ""
  echo "==> Shared NSS database"
  echo "    No shared NSS database found at $SHARED_NSS."
  if confirm "    Create it? (required for Chrome, Chromium, Edge — deb installs)"; then
    mkdir -p "$SHARED_NSS"
    certutil -d "sql:$SHARED_NSS" -N --empty-password
    echo "    Created."
  else
    echo "    Skipped — Chrome, Chromium, and Edge (deb) trust store will not be updated."
    _shared_nss_ready=false
  fi
fi

if [[ "$_shared_nss_ready" == true ]]; then
  install_to_nss_dbs \
    "Shared NSS database (Google Chrome, Chromium, Edge — deb installs)" \
    "$SHARED_NSS"
fi

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
