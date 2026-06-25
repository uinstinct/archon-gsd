# Decline large issues instead of auto-running gsd:phase

The `archon-fix-github-issue` workflow no longer routes `large`-scoped issues to
the Engine's `/gsd-phase` plan/build/verify loop. Instead the Shell **declines**:
it posts a GitHub comment flagging the issue for a human and ends the run. Only
`small` issues are auto-fixed (via `/gsd-quick`).

## Why

`gsd:phase` running headless is unreliable on big, multi-file tasks — an
unattended full plan/build/verify loop can ship a bad PR no human reviewed
first. Flagging the issue for a human is safer than auto-shipping low-confidence
multi-file work. Small, self-contained changes remain low-risk enough to
auto-fix, so the `/gsd-quick` path is unchanged.

## Consequences

- A `large` route is a **successful** terminal state, not a failure: no branch,
  no PR, no `report` node — just the Decline comment. The small-branch nodes are
  skipped via `when:` (not errored).
- Reversible: re-add the `handoff-phase` node and restore `create-pr`'s
  dependency on it to resume auto-phase if headless reliability improves.
