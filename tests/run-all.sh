#!/usr/bin/env bash
# Run every deterministic Shell-plumbing test. The container smoke test lives
# under tests/smoke/ and runs separately (it needs a built image).
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
rc=0

for t in "$DIR"/*.test.sh; do
  echo "=============================================="
  bash "$t" || rc=1
done

echo "=============================================="
if [ "$rc" -eq 0 ]; then
  echo "ALL DETERMINISTIC TESTS PASSED"
else
  echo "DETERMINISTIC TESTS FAILED" >&2
fi
exit "$rc"
