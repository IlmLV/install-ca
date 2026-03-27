#!/usr/bin/env bash
# Generate all test certificates at runtime — no private keys stored in the repo.
# Usage: bash generate-certs.sh [output-dir]
#   output-dir defaults to /workspace/tests/runtime-certs
#   set GENERATE_CERTS_QUIET=0 to print OpenSSL output

set -euo pipefail

OUT="${1:-/workspace/tests/runtime-certs}"
QUIET="${GENERATE_CERTS_QUIET:-1}"
mkdir -p "$OUT"

run_openssl() {
  if [[ "$QUIET" == "1" ]]; then
    local out
    if ! out="$(openssl "$@" 2>&1)"; then
      printf '%s\n' "$out" >&2
      return 1
    fi
    return 0
  fi

  openssl "$@"
}

# ── 1. Test CA (used by install-ca-cert.sh / install-ca-cert.ps1 tests) ───────
run_openssl req -x509 -newkey rsa:2048 -keyout "$OUT/test-ca.key" \
  -out "$OUT/test-ca.crt" -days 365 -nodes \
  -subj "/CN=Test CA/O=Test Org"

# ── 2. HTTPS test CA (signs the local HTTPS test server) ──────────────────────
run_openssl req -x509 -newkey rsa:2048 -keyout "$OUT/https-ca.key" \
  -out "$OUT/https-ca.crt" -days 365 -nodes \
  -subj "/CN=Test HTTPS CA"

# ── 3. HTTPS test server certificate signed by the HTTPS CA ──────────────────
run_openssl req -newkey rsa:2048 -keyout "$OUT/https-server.key" \
  -out "$OUT/https-server.csr" -nodes \
  -subj "/CN=localhost"

HTTPS_SERVER_EXT="$OUT/https-server.ext"
cat >"$HTTPS_SERVER_EXT" <<'EOF'
subjectAltName=DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
basicConstraints=CA:FALSE
EOF

run_openssl x509 -req -in "$OUT/https-server.csr" \
  -CA "$OUT/https-ca.crt" -CAkey "$OUT/https-ca.key" \
  -CAcreateserial -out "$OUT/https-server.crt" -days 365 \
  -extfile "$HTTPS_SERVER_EXT"

rm -f "$OUT/https-server.csr" "$OUT/https-ca.srl" "$HTTPS_SERVER_EXT" "$OUT/test-ca.key"

if [[ "$QUIET" != "1" ]]; then
  echo "Certificates generated in $OUT"
fi
