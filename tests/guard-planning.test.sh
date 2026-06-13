#!/usr/bin/env bash
# guard-planning: the run must fail fast unless the target repo carries an
# initialised .planning/ (config.json, STATE.md, ROADMAP.md). It must NEVER
# bootstrap (no gsd-new-project).
source "$(dirname "$0")/lib/common.sh"

echo "guard-planning"

SCRIPT="$(mktemp)"
extract_bash guard-planning "$SCRIPT"

run_guard() { # cwd -> exit code
  ( cd "$1" && bash "$SCRIPT" ) >/dev/null 2>&1
}

# 1. No .planning/ at all -> fail before any handoff could fire.
empty="$(mktemp -d)"
if run_guard "$empty"; then
  fail "no .planning/: guard should fail but exited 0"
else
  pass "no .planning/: guard fails fast"
fi

# 2. Partial .planning/ (missing ROADMAP.md) -> fail.
partial="$(mktemp -d)"
mkdir -p "$partial/.planning"
echo '{}' >"$partial/.planning/config.json"
echo '# state' >"$partial/.planning/STATE.md"
if run_guard "$partial"; then
  fail "missing ROADMAP.md: guard should fail but exited 0"
else
  pass "missing ROADMAP.md: guard fails"
fi

# 3. Complete .planning/ -> pass (roadmap existence only, not phase status).
ok="$(mktemp -d)"
mkdir -p "$ok/.planning"
echo '{}' >"$ok/.planning/config.json"
echo '# state' >"$ok/.planning/STATE.md"
echo '# roadmap' >"$ok/.planning/ROADMAP.md"
if run_guard "$ok"; then
  pass "complete .planning/: guard passes"
else
  fail "complete .planning/: guard should pass but failed"
fi

# 4. The guard must never INVOKE gsd-new-project (mentioning it in the failure
#    guidance is fine; running it is not). Exclude echo/comment lines.
if grep -i "new-project" "$SCRIPT" | grep -vqE '^\s*(#|echo)'; then
  fail "guard invokes project bootstrap (must never init)"
else
  pass "guard never invokes gsd-new-project"
fi

summary
