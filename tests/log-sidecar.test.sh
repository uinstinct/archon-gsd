#!/usr/bin/env bash
# Log-sidecar process-seam test. Runs docker/log-tail.ts black-box at its CLI
# seam in one-shot (no-follow) mode against fixture transcripts, asserting only
# the bytes it writes to stdout. Mirrors the Dockerfile.smoke approach: the
# stock `oven/bun` image, the script bind-mounted read-only, fixtures mounted
# read-only at /.archon — no host Bun, no JS test runner. The live
# new-file-appears follow path stays manual (see Out of Scope in issue #4).
source "$(dirname "$0")/lib/common.sh"

echo "log-sidecar"

BUN_IMAGE="oven/bun:1.3.11-slim"
SCRIPT="$REPO_ROOT/docker/log-tail.ts"
FIX="$REPO_ROOT/tests/fixtures/log-sidecar"
FIXHOME="$REPO_ROOT/tests/fixtures/log-sidecar-home"

# Skip cleanly where docker is unavailable so the deterministic suite still
# passes locally; CI always has docker (same as the smoke test).
if ! command -v docker >/dev/null 2>&1; then
  echo "  SKIP - docker not available; sidecar process-seam test needs it"
  summary
  exit $?
fi

out="$(docker run --rm \
  -e LOG_TAIL_FOLLOW=0 \
  -e LOG_TAIL_HOME=/.home \
  -v "$FIX":/.archon:ro \
  -v "$FIXHOME":/.home:ro \
  -v "$SCRIPT":/log-tail.ts:ro \
  "$BUN_IMAGE" bun /log-tail.ts 2>/dev/null)" || {
  fail "sidecar did not run under $BUN_IMAGE"
  summary
  exit $?
}

has() { printf '%s\n' "$out" | grep -qF "$1"; }

# 1. Every output line carries the [runId|node] prefix.
bad="$(printf '%s\n' "$out" | grep -cvE '^\[[^|]+\|[^]]*\] .' || true)"
if [ "$bad" -eq 0 ]; then
  pass "every line carries a [runId|node] prefix"
else
  fail "$bad line(s) lack the [runId|node] prefix"
fi

# 2. Both transcripts are surfaced (project-scoped and cwd-scoped logs dirs).
if has '[run-aaa111|' && has '[run-bbb222|'; then
  pass "both run transcripts surfaced (project- and cwd-scoped logs/)"
else
  fail "a run transcript was not surfaced"
fi

# 3. Run attribution: a line's content maps to its own run, not the other's.
if has '[run-aaa111|handoff-quick] → Bash(command=git status)'; then
  pass "tool line attributes to the correct run + node"
else
  fail "tool line missing or misattributed"
fi

# 4. assistant renders as a readable line under the current node.
if has '[run-aaa111|size-classify] assistant: The issue is small and self-contained.'; then
  pass "assistant renders as a single readable line"
else
  fail "assistant line not rendered as expected"
fi

# 5. tool renders compactly (name + input summary), not raw JSON.
if has '→ Edit(file_path=/repo/src/x.ts, old_string=a, new_string=b)'; then
  pass "tool renders as name(input summary)"
else
  fail "tool not rendered as name(input summary)"
fi

# 6. node lifecycle markers are distinct (start / complete / skipped / error).
if has '● ▷ node guard-planning' \
  && has '● ✓ node handoff-quick (4200ms)' \
  && has '[run-bbb222|create-branch] ● ⊘ node create-branch skipped: branch already exists' \
  && has '[run-bbb222|handoff-phase] ● ✗ node handoff-phase error: engine crashed'; then
  pass "node start/complete/skipped/error render as distinct markers"
else
  fail "node lifecycle markers missing or wrong"
fi

# 7. workflow_start / validation / workflow_complete / workflow_error render.
if has '[run-aaa111|-] ▶ workflow archon-fix-github-issue | input: Fix #4: add the log sidecar' \
  && has '[run-aaa111|handoff-quick] ✓ validation tests: pass' \
  && has '[run-aaa111|handoff-quick] ■ workflow complete' \
  && has '[run-bbb222|handoff-phase] ✖ workflow error: run failed'; then
  pass "workflow_start/validation/complete/error render as concise lines"
else
  fail "workflow-level lines missing or wrong"
fi

# 8. Long assistant text is collapsed/truncated on one line (tail dropped, … added).
long_line="$(printf '%s\n' "$out" | grep -F '[run-aaa111|handoff-quick] assistant: AAAA' || true)"
if printf '%s' "$long_line" | grep -qF '…' && ! printf '%s' "$long_line" | grep -qF 'ZZTAILMARKERZZ'; then
  pass "long assistant text truncated (… present, tail dropped)"
else
  fail "long assistant text not truncated as expected"
fi

# 9. Multi-line assistant content is collapsed onto a single output line.
nlines="$(printf '%s\n' "$out" | grep -cF '[run-bbb222|handoff-phase] assistant: Planning the change across multiple lines of reasoning.' || true)"
if [ "$nlines" -eq 1 ]; then
  pass "multi-line assistant content collapsed to one line"
else
  fail "multi-line assistant content not collapsed to one line"
fi
# 10. Claude Code session logs are rendered with the same [runId|node] prefix.
if has '[sess-ccc333|fix/issue-9] user: @archon run the spec'; then pass 10; else fail 10 "missing claude user line"; fi

# 11. Claude assistant text, tool_use, and failed tool_result render.
if has "[sess-ccc333|fix/issue-9] assistant: I'll run the spec now." && has '[sess-ccc333|fix/issue-9] → Bash(command=npx playwright test)'; then pass 11; else fail 11 "missing claude assistant/tool lines"; fi

# 12. Claude sidechain lines render under `subagent` node.
if has '[sess-ccc333|subagent] assistant: subagent thinking out loud'; then pass 12; else fail 12 "missing claude sidechain line"; fi

# 13. Failed tool_result surfaces; successful tool_result is skipped (noise).
if has '[sess-ccc333|fix/issue-9] ← ERROR Exit code 127 playwright: command not found'; then pass 13; else fail 13 "missing claude error tool_result"; fi

# 14. Thinking, successful tool_result, and meta events are skipped.
if ! has 'OK big output' && ! has 'secret' && ! has 'queue-operation'; then pass 14; else fail 14 "skipped content leaked into output"; fi

summary
