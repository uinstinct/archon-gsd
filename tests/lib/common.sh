#!/usr/bin/env bash
# Shared helpers for the Shell-plumbing tests.
#
# These tests assert what the Shell *produces* — a guarded failure, a feature
# branch, a routed handoff — by running the workflow's own bash node bodies and
# inspecting its `when:` guards. They never run the Archon runtime and never
# assert the content of LLM output. See docs/e2e-run.md for the live path.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
WF="$REPO_ROOT/.archon/workflows/archon-fix-github-issue.yaml"
WFPY="python3 $REPO_ROOT/tests/lib/wf.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1" >&2; }

summary() {
  echo ""
  echo "  $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

# Extract a node's bash body to a runnable script file.
extract_bash() {
  local node="$1" out="$2"
  $WFPY bash "$WF" "$node" >"$out"
}

# Replace an Archon `$node.output[.field]` substitution token with a literal
# value, mirroring what the executor does before a bash node runs. Exact string
# replacement (not regex) so the hyphenated token survives untouched.
subst() {
  local file="$1" token="$2" value="$3"
  python3 - "$file" "$token" "$value" <<'PY'
import sys
path, token, value = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(data.replace(token, value))
PY
}

# A throwaway git repo with one commit on $BASE_BRANCH. Echoes its path.
make_git_fixture() {
  local base="${1:-main}"
  local dir
  dir="$(mktemp -d)"
  (
    cd "$dir"
    git init -q -b "$base"
    git config user.email test@example.com
    git config user.name test
    echo seed >seed.txt
    git add seed.txt
    git commit -qm seed
  )
  echo "$dir"
}
