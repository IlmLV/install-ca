#!/usr/bin/env bash
set -euo pipefail

openssl s_server -quiet -accept 8443 \
  -cert /workspace/tests/fixtures/https-server.crt \
  -key /workspace/tests/fixtures/https-server.key \
  -www >/dev/null 2>&1 &
https_pid=$!

trap 'kill "$https_pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  (exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null && break || sleep 0.1
done
bats /workspace/tests/linux.bats 2>&1 | awk '
/^1\.\./ { next }
/^ok [0-9]+ / { sub(/^ok [0-9]+ /, ""); print "  [+] " $0; next }
/^not ok [0-9]+ / { sub(/^not ok [0-9]+ /, ""); print "  [-] " $0; next }
/^#/ { print "  " $0; next }
{ print }
'
