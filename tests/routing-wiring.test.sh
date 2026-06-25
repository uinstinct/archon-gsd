#!/usr/bin/env bash
# Routing wiring: with size-classify stubbed to `small` the quick handoff fires
# and the issue is auto-fixed; with `large` the issue is DECLINED — comment-large
# fires (a successful terminal leaf) and the quick handoff does not. The LLM's
# actual sizing judgment is NOT asserted — only that the Shell routes each scope
# to the right terminal: Engine handoff for `small`, decline comment for `large`.
source "$(dirname "$0")/lib/common.sh"

echo "routing-wiring"

EVAL="python3 $REPO_ROOT/tests/lib/eval_when.py"
Q_WHEN="$($WFPY field "$WF" handoff-quick when)"
L_WHEN="$($WFPY field "$WF" comment-large when)"

fires() { # when-expr scope-value -> 0 if guard true
  $EVAL "$1" size-classify scope "$2" >/dev/null 2>&1
}

# 1. scope=small -> quick handoff fires, decline does not.
if fires "$Q_WHEN" small && ! fires "$L_WHEN" small; then
  pass "scope=small routes to handoff-quick only"
else
  fail "scope=small did not route to handoff-quick only"
fi

# 2. scope=large -> decline fires, quick handoff does not.
if fires "$L_WHEN" large && ! fires "$Q_WHEN" large; then
  pass "scope=large routes to comment-large (declined) only"
else
  fail "scope=large did not route to comment-large only"
fi

# 3. Exactly one terminal fires per scope (mutual exclusivity).
for scope in small large; do
  n=0
  fires "$Q_WHEN" "$scope" && n=$((n + 1))
  fires "$L_WHEN" "$scope" && n=$((n + 1))
  if [ "$n" -eq 1 ]; then
    pass "exactly one route fires for scope=$scope"
  else
    fail "scope=$scope fired $n routes (expected 1)"
  fi
done

# 4. The quick handoff gates on the branch and the classifier (wiring, not order).
#    The decline gates on the classifier only — it deliberately creates no branch.
deps="$($WFPY deps "$WF" handoff-quick | tr '\n' ' ')"
if echo "$deps" | grep -q create-branch && echo "$deps" | grep -q size-classify; then
  pass "handoff-quick depends on create-branch and size-classify"
else
  fail "handoff-quick missing create-branch/size-classify deps (got: $deps)"
fi

ldeps="$($WFPY deps "$WF" comment-large | tr '\n' ' ')"
if echo "$ldeps" | grep -q size-classify; then
  pass "comment-large depends on size-classify"
else
  fail "comment-large missing size-classify dep (got: $ldeps)"
fi
if echo "$ldeps" | grep -q create-branch; then
  fail "comment-large must NOT depend on create-branch (declined = no branch)"
else
  pass "comment-large does not depend on create-branch"
fi

# 5. create-branch is gated on `small` so a declined `large` issue never gets an
#    orphan fix/issue-<N> branch with no commits.
CB_WHEN="$($WFPY field "$WF" create-branch when)"
if fires "$CB_WHEN" small && ! fires "$CB_WHEN" large; then
  pass "create-branch fires only for scope=small"
else
  fail "create-branch not gated on scope=small (when: $CB_WHEN)"
fi

# 6. create-pr depends solely on the quick handoff (declined large opens no PR).
prdeps="$($WFPY deps "$WF" create-pr | tr '\n' ' ')"
if echo "$prdeps" | grep -q handoff-quick; then
  pass "create-pr depends on handoff-quick"
else
  fail "create-pr missing handoff-quick dep (got: $prdeps)"
fi

# 7. The quick handoff invokes the right Engine command with the agreed flags:
#    granular flags (--research --validate), never --full. handoff-quick is a
#    prompt node (prompt: |), so read the command line from the raw YAML region.
quick_line="$(grep -A2 'id: handoff-quick' "$WF" | grep '/gsd-quick' || true)"
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

# 8. The decline is deterministic bash (no LLM spend, no Engine), and it must not
#    DISPATCH /gsd-phase — the whole point is that the phase loop does not auto-run
#    headless. The node may MENTION /gsd-phase in the comment prose (backticked),
#    but never invoke it as a slash command.
if $WFPY bash "$WF" comment-large >/dev/null 2>&1; then
  pass "comment-large is a deterministic bash node"
else
  fail "comment-large is not a bash node (decline must not spend LLM/Engine)"
fi
if grep -qE '^\s*/gsd[:-]phase' "$WF"; then
  fail "workflow dispatches /gsd-phase (large is declined, never auto-run)"
else
  pass "workflow never dispatches /gsd-phase"
fi

# 9. The Shell must not INVOKE gsd:do (the comments explain why it's avoided;
#    what matters is no slash-command dispatch to it).
if grep -qE '^\s*/gsd[:-]do' "$WF"; then
  fail "workflow invokes /gsd:do (routing must be Shell-owned)"
else
  pass "workflow never invokes gsd:do"
fi

summary
