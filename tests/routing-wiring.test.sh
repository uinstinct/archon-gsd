#!/usr/bin/env bash
# Routing wiring: with size-classify stubbed to `small` the quick handoff fires
# and the phase handoff does not; with `large` the reverse. The LLM's actual
# sizing judgment is NOT asserted — only that the Shell routes each scope to the
# right Engine command.
source "$(dirname "$0")/lib/common.sh"

echo "routing-wiring"

EVAL="python3 $REPO_ROOT/tests/lib/eval_when.py"
Q_WHEN="$($WFPY field "$WF" handoff-quick when)"
P_WHEN="$($WFPY field "$WF" handoff-phase when)"

fires() { # when-expr scope-value -> 0 if guard true
  $EVAL "$1" size-classify scope "$2" >/dev/null 2>&1
}

# 1. scope=small -> quick fires, phase does not.
if fires "$Q_WHEN" small && ! fires "$P_WHEN" small; then
  pass "scope=small routes to handoff-quick only"
else
  fail "scope=small did not route to handoff-quick only"
fi

# 2. scope=large -> phase fires, quick does not.
if fires "$P_WHEN" large && ! fires "$Q_WHEN" large; then
  pass "scope=large routes to handoff-phase only"
else
  fail "scope=large did not route to handoff-phase only"
fi

# 3. Exactly one handoff fires per scope (mutual exclusivity).
for scope in small large; do
  n=0
  fires "$Q_WHEN" "$scope" && n=$((n + 1))
  fires "$P_WHEN" "$scope" && n=$((n + 1))
  if [ "$n" -eq 1 ]; then
    pass "exactly one handoff fires for scope=$scope"
  else
    fail "scope=$scope fired $n handoffs (expected 1)"
  fi
done

# 4. Both handoffs gate on the branch and the classifier (wiring, not order).
for node in handoff-quick handoff-phase; do
  deps="$($WFPY deps "$WF" "$node" | tr '\n' ' ')"
  if echo "$deps" | grep -q create-branch && echo "$deps" | grep -q size-classify; then
    pass "$node depends on create-branch and size-classify"
  else
    fail "$node missing create-branch/size-classify deps (got: $deps)"
  fi
done

# 5. Each handoff invokes the right Engine command with the agreed flags.
#    Quick = granular flags (--research --validate), never --full. Handoffs are
#    prompt nodes (prompt: |), so read the command line from the raw YAML region.
quick_line="$(grep -A2 'id: handoff-quick' "$WF" | grep '/gsd-quick' || true)"
phase_line="$(grep -A2 'id: handoff-phase' "$WF" | grep '/gsd-phase' || true)"

if echo "$quick_line" | grep -q -- '--research' && echo "$quick_line" | grep -q -- '--validate'; then
  pass "handoff-quick uses /gsd-quick --research --validate"
else
  fail "handoff-quick missing /gsd-quick --research --validate (got: $quick_line)"
fi
if echo "$quick_line" | grep -q -- '--full'; then
  fail "handoff-quick must not use --full (use granular flags)"
else
  pass "handoff-quick does not use --full"
fi
if echo "$phase_line" | grep -q '/gsd-phase'; then
  pass "handoff-phase uses /gsd-phase"
else
  fail "handoff-phase missing /gsd-phase (got: $phase_line)"
fi

# 6. The Shell must not INVOKE gsd:do (the comments explain why it's avoided;
#    what matters is no slash-command dispatch to it).
if grep -qE '^\s*/gsd[:-]do' "$WF"; then
  fail "workflow invokes /gsd:do (routing must be Shell-owned)"
else
  pass "workflow never invokes gsd:do"
fi

summary
