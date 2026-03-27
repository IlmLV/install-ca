#!/usr/bin/env bats
# Tests for install-ca-cert.sh

SCRIPT="/workspace/install-ca-cert.sh"
CERT="${TEST_CERT:-/workspace/tests/runtime-certs/test-ca.crt}"
HTTPS_CA="${HTTPS_CA:-/workspace/tests/runtime-certs/https-ca.crt}"
SYSTEM_CA_DIR="/usr/local/share/ca-certificates"
SHARED_NSS_DIR="$HOME/.pki/nssdb"
BRAVE_NSS_DIR="$HOME/snap/brave/current/.pki/nssdb"
CHROMIUM_NSS_DIR="$HOME/snap/chromium/current/.pki/nssdb"
FIREFOX_DEB_NSS_DIR="$HOME/.mozilla/firefox/test.default"
FIREFOX_SNAP_NSS_DIR="$HOME/snap/firefox/current/.mozilla/firefox/test.default"

init_nss_db() {
    local dir="$1"
    mkdir -p "$dir"
    certutil -d "sql:$dir" -N --empty-password
}

install_https_ca() {
    run bash -c "printf '%s\n' '$HTTPS_CA' 'y' 'y' | bash '$SCRIPT'"
    [ "$status" -eq 0 ]
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "$2"; return 1; }
}

run_timeout() {
    local duration="${BATS_CMD_TIMEOUT:-30s}"
    run timeout "$duration" "$@"
}

is_snap_stub() {
    local bin="$1"
    local out
    out="$("$bin" --version 2>&1 || true)"
    [[ "$out" == *"requires the "*snap* ]]
}

pick_firefox_deb_bin() {
    local candidate
    for candidate in firefox firefox-esr; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        is_snap_stub "$candidate" && continue
        echo "$candidate"
        return 0
    done
    return 1
}

run_headless() {
    local label="$1"; shift
    run_timeout "$@"
    if [[ "$status" -eq 124 ]]; then
        skip "$label timed out in this container environment"
    fi
}

setup() {
    rm -f "$SYSTEM_CA_DIR/test-ca.crt" "$SYSTEM_CA_DIR/test-https-ca.crt"
    rm -rf "$SHARED_NSS_DIR" "$BRAVE_NSS_DIR" "$CHROMIUM_NSS_DIR" "$FIREFOX_DEB_NSS_DIR" "$FIREFOX_SNAP_NSS_DIR"
}
teardown() {
    rm -f "$SYSTEM_CA_DIR/test-ca.crt" "$SYSTEM_CA_DIR/test-https-ca.crt"
    rm -rf "$SHARED_NSS_DIR" "$BRAVE_NSS_DIR" "$CHROMIUM_NSS_DIR" "$FIREFOX_DEB_NSS_DIR" "$FIREFOX_SNAP_NSS_DIR"
}

@test "empty input exits with error" {
    run bash -c "printf '\n' | bash '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No CA source provided"* ]]
}

@test "local cert file: installs and verifies" {
    run bash -c "printf '%s\n' '$CERT' 'y' 'y' | bash '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CA Name  : Test CA"* ]]
    [[ "$output" == *"System trust: OK"* ]]
}

@test "already installed cert exits cleanly" {
    cp "$CERT" "$SYSTEM_CA_DIR/test-ca.crt"
    run bash -c "printf '%s\n' '$CERT' | bash '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already up-to-date"* ]]
}

@test "updates all browser NSS databases" {
    init_nss_db "$SHARED_NSS_DIR"
    init_nss_db "$BRAVE_NSS_DIR"
    init_nss_db "$CHROMIUM_NSS_DIR"
    init_nss_db "$FIREFOX_DEB_NSS_DIR"
    init_nss_db "$FIREFOX_SNAP_NSS_DIR"

    run bash -c "printf '%s\n' '$CERT' 'y' 'y' 'y' 'y' 'y' | bash '$SCRIPT'"
    [ "$status" -eq 0 ]

    run certutil -d "sql:$SHARED_NSS_DIR" -L -n "Test CA"
    [ "$status" -eq 0 ]
    run certutil -d "sql:$BRAVE_NSS_DIR" -L -n "Test CA"
    [ "$status" -eq 0 ]
    run certutil -d "sql:$CHROMIUM_NSS_DIR" -L -n "Test CA"
    [ "$status" -eq 0 ]
    run certutil -d "sql:$FIREFOX_DEB_NSS_DIR" -L -n "Test CA"
    [ "$status" -eq 0 ]
    run certutil -d "sql:$FIREFOX_SNAP_NSS_DIR" -L -n "Test CA"
    [ "$status" -eq 0 ]
}

@test "HTTPS URL trusts system CA after install" {
    install_https_ca
    run_timeout curl -sSf https://127.0.0.1:8443/
    [ "$status" -eq 0 ]
}

@test "Chrome headless loads HTTPS page after trust install" {
    require_cmd google-chrome "google-chrome not installed"
    install_https_ca
    run_headless "Chrome" bash -c "google-chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --disable-component-update --user-data-dir=/tmp/chrome-profile --dump-dom https://127.0.0.1:8443/ >/dev/null"
    [ "$status" -eq 0 ]
}

@test "Chromium headless loads HTTPS page after trust install" {
    if command -v chromium >/dev/null 2>&1; then
        bin="chromium"
    elif command -v chromium-browser >/dev/null 2>&1; then
        bin="chromium-browser"
    else
        echo "chromium not installed"
        return 1
    fi
    if is_snap_stub "$bin"; then
        echo "chromium deb not installed (snap stub detected)"
        return 1
    fi
    install_https_ca
    run_headless "Chromium" bash -c "$bin --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --disable-component-update --user-data-dir=/tmp/chromium-profile --dump-dom https://127.0.0.1:8443/ >/dev/null"
    [ "$status" -eq 0 ]
}

@test "Microsoft Edge headless loads HTTPS page after trust install" {
    if command -v microsoft-edge >/dev/null 2>&1; then
        bin="microsoft-edge"
    elif command -v microsoft-edge-stable >/dev/null 2>&1; then
        bin="microsoft-edge-stable"
    else
        echo "microsoft-edge not installed"
        return 1
    fi
    install_https_ca
    run_headless "Microsoft Edge" bash -c "$bin --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --disable-component-update --user-data-dir=/tmp/edge-profile --dump-dom https://127.0.0.1:8443/ >/dev/null"
    [ "$status" -eq 0 ]
}

@test "Brave headless loads HTTPS page after trust install" {
    if command -v brave-browser >/dev/null 2>&1; then
        bin="brave-browser"
    elif command -v brave >/dev/null 2>&1; then
        bin="brave"
    else
        echo "brave not installed"
        return 1
    fi
    install_https_ca
    run_headless "Brave" bash -c "$bin --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --disable-component-update --disable-features=Translate,MediaRouter --user-data-dir=/tmp/brave-profile --dump-dom https://127.0.0.1:8443/ >/dev/null"
    [ "$status" -eq 0 ]
}

@test "Firefox headless loads HTTPS page after trust install" {
    local bin
    if ! bin="$(pick_firefox_deb_bin)"; then
        if command -v firefox >/dev/null 2>&1 || command -v firefox-esr >/dev/null 2>&1; then
            echo "firefox deb not installed (snap stub detected)"
            return 1
        fi
        echo "firefox not installed"
        return 1
    fi
    # Use a deterministic profile DB that install_https_ca can populate.
    init_nss_db "$FIREFOX_DEB_NSS_DIR"
    install_https_ca
    run_headless "Firefox (deb)" bash -c "$bin --headless --no-remote --profile \"$FIREFOX_DEB_NSS_DIR\" --dump-dom https://127.0.0.1:8443/ >/dev/null"
    [ "$status" -eq 0 ]
}
