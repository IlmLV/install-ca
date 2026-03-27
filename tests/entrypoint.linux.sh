#!/usr/bin/env bash
set -euo pipefail

CERTS_DIR="/workspace/tests/runtime-certs"

# Generate all test certificates at runtime
bash /workspace/tests/generate-certs.sh "$CERTS_DIR"

# Export paths for BATS tests
export TEST_CERT="$CERTS_DIR/test-ca.crt"
export HTTPS_CA="$CERTS_DIR/https-ca.crt"

openssl s_server -quiet -accept 8443 \
  -cert "$CERTS_DIR/https-server.crt" \
  -key "$CERTS_DIR/https-server.key" \
  -www >/dev/null 2>&1 &
https_pid=$!

trap 'kill "$https_pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  (exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null && break || sleep 0.1
done

bats /workspace/tests/linux.bats
