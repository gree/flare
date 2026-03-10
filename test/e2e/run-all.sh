#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL=0
FAIL=0

run_test() {
  local name="$1" script="$2"
  echo "=== Running: ${name} ==="
  if bash "${script}"; then
    TOTAL=$((TOTAL + 1))
  else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
  fi
}

run_test "Cluster Replication" "$SCRIPT_DIR/test-cluster-replication.sh"

echo ""
echo "Tests: ${TOTAL}, Failures: ${FAIL}"
[ "${FAIL}" -eq 0 ]
