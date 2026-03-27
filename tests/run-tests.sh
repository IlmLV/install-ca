#!/usr/bin/env bash
# Run containerized tests locally.
# Usage: bash tests/run-tests.sh [linux-ubuntu] [linux-debian]
#   With no arguments, all suites are run.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SUITES=("$@")
if [[ ${#SUITES[@]} -eq 0 ]]; then
  SUITES=(linux-ubuntu linux-debian)
fi

PASS=()
FAIL=()

run_suite() {
  local name="$1"
  local tag="install-ca-cert-test-$name"
  local dockerfile=""

  case "$name" in
    linux-ubuntu) dockerfile="tests/Dockerfile.ubuntu" ;;
    linux-debian) dockerfile="tests/Dockerfile.debian" ;;
  esac

  echo ""
  local status_prefix="== $name == "
  printf '%sbuilding... ' "$status_prefix"
  if ! build_out="$(docker build -q -f "$dockerfile" -t "$tag" . 2>&1)"; then
    echo "FAIL"
    echo "ERROR: docker build failed for $name" >&2
    printf '%s\n' "$build_out" >&2
    FAIL+=("$name (build failed)")
    return
  fi
  echo "OK"
  if docker run --rm -t "$tag"; then
    PASS+=("$name")
    echo "run: OK"
  else
    FAIL+=("$name")
    echo "run: FAIL"
    echo "ERROR: docker run failed for $name" >&2
  fi
}

for suite in "${SUITES[@]}"; do
  case "$suite" in
    linux-ubuntu|linux-debian) run_suite "$suite" ;;
    *) echo "Unknown suite: $suite (valid: linux-ubuntu, linux-debian)" >&2; exit 1 ;;
  esac
done

echo ""
echo "== results =="
for s in "${PASS[@]+"${PASS[@]}"}"; do echo "  PASS  $s"; done
for s in "${FAIL[@]+"${FAIL[@]}"}"; do echo "  FAIL  $s"; done

[[ ${#FAIL[@]} -eq 0 ]]
