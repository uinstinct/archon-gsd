#!/usr/bin/env bash
# Container smoke assertions — run inside a built image as the container user.
# Proves the Engine runtime is present and usable: node >= 22, gsd-tools.cjs
# actually runs, and the gsd-quick / gsd-phase commands resolve under the user's
# home (the Claude SDK 'user' setting source). Paths verified against a real
# `@opengsd/gsd-core --claude --global` install.
set -uo pipefail

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1" >&2; }

echo "container-smoke (as $(id -un), HOME=$HOME)"

# 1. node >= 22 is present (the stock Archon image purges node).
if command -v node >/dev/null 2>&1; then
  ver="$(node --version)"; major="${ver#v}"; major="${major%%.*}"
  if [ "${major:-0}" -ge 22 ]; then
    pass "node $ver present (>= 22)"
  else
    fail "node $ver present but < 22"
  fi
else
  fail "node not found on PATH"
fi

# 2. gsd-tools.cjs runs (a no-project subcommand returns clean JSON, exit 0).
TOOLS="$HOME/.claude/gsd-core/bin/gsd-tools.cjs"
if [ -f "$TOOLS" ]; then
  if out="$(node "$TOOLS" current-timestamp 2>/dev/null)" && echo "$out" | grep -q '"timestamp"'; then
    pass "gsd-tools.cjs runs (current-timestamp)"
  else
    fail "gsd-tools.cjs present but did not run"
  fi
else
  fail "gsd-tools.cjs not found at $TOOLS"
fi

# 3. The gsd_run launcher is on hand beside gsd-tools.cjs.
if [ -x "$HOME/.claude/gsd-core/bin/gsd_run" ]; then
  pass "gsd_run launcher present"
else
  fail "gsd_run launcher missing"
fi

# 4. The Engine commands resolve under the user home (hyphen form for Claude).
for cmd in gsd-quick gsd-phase; do
  skill="$HOME/.claude/skills/$cmd/SKILL.md"
  if [ -f "$skill" ] && grep -q "name: $cmd" "$skill"; then
    pass "$cmd resolves under \$HOME/.claude (skill)"
  else
    fail "$cmd not found under \$HOME/.claude"
  fi
done

# 5. rtk (Rust Token Killer) is on PATH and runs — proving /usr/local/bin/rtk is
#    readable/executable by appuser (it lives outside the shadowed home volume).
if command -v rtk >/dev/null 2>&1; then
  if rtk --version >/dev/null 2>&1; then
    pass "rtk present and runs ($(rtk --version 2>/dev/null | head -n1))"
  else
    fail "rtk on PATH but --version failed"
  fi
else
  fail "rtk not found on PATH"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
