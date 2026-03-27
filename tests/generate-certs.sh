#!/usr/bin/env bash
# Generate all test certificates at runtime — no private keys stored in the repo.
# Usage: bash generate-certs.sh [output-dir]
#   output-dir defaults to /workspace/tests/runtime-certs

set -euo pipefail

OUT="${1:-/workspace/tests/runtime-certs}"
mkdir -p "$OUT"

# ── 1. Test CA (used by install-ca-cert.sh / install-ca-cert.ps1 tests) ───────
openssl req -x509 -newkey rsa:2048 -keyout "$OUT/test-ca.key" \
  -out "$OUT/test-ca.crt" -days 365 -nodes \
  -subj "/CN=Test CA/O=Test Org"

# ── 2. HTTPS test CA (signs the local HTTPS test server) ──────────────────────
openssl req -x509 -newkey rsa:2048 -keyout "$OUT/https-ca.key" \
  -out "$OUT/https-ca.crt" -days 365 -nodes \
  -subj "/CN=Test HTTPS CA"

# ── 3. HTTPS test server certificate signed by the HTTPS CA ──────────────────
openssl req -newkey rsa:2048 -keyout "$OUT/https-server.key" \
  -out "$OUT/https-server.csr" -nodes \
  -subj "/CN=localhost"

openssl x509 -req -in "$OUT/https-server.csr" \
  -CA "$OUT/https-ca.crt" -CAkey "$OUT/https-ca.key" \
  -CAcreateserial -out "$OUT/https-server.crt" -days 365

rm -f "$OUT/https-server.csr" "$OUT/https-ca.srl"

echo "Certificates generated in $OUT"
