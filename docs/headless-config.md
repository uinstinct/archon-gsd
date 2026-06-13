# Headless GSD config (target repo `.planning/config.json`)

The Engine runs unattended under the Shell — there is no human to answer a
prompt. GSD ships defaulting to `mode: "interactive"` with every gate and safety
confirmation **on**, so left as-is each step would block. Every **target repo**
must therefore carry these keys in its `.planning/config.json`. They are
**additive** to whatever else the repo configures; they only force unattended
execution. See CONTEXT.md ("Headless") and the workflow's `handoff-*` nodes.

```jsonc
{
  // ... the repo's own GSD config ...

  "mode": "yolo",

  "gates": {
    "confirm_project": false,
    "confirm_phases": false,
    "confirm_roadmap": false,
    "confirm_breakdown": false,
    "confirm_plan": false,
    "execute_next_plan": false,
    "issues_review": false,
    "confirm_transition": false
  },

  "safety": {
    "always_confirm_destructive": false,
    "always_confirm_external_services": false
  }
}
```

## Why each block

- **`mode: "yolo"`** — GSD's fully unattended mode. `interactive` (the default)
  pauses at decision points.
- **`gates.*: false`** — every confirmation gate (project/phases/roadmap/
  breakdown/plan/execute/issues-review/transition) is a human checkpoint. All
  off so the plan/build/verify loop runs end to end.
- **`safety.*: false`** — `always_confirm_destructive` and
  `always_confirm_external_services` each raise an `AskUserQuestion`. Any
  `AskUserQuestion` the Engine reaches is a stall, so both are off.

## What is intentionally NOT forced here

- **Discussion** is skipped on the quick route by the handoff flags
  (`/gsd-quick --research --validate`, which omits `--discuss`), not by config.
  On the phase route, discussion follows the repo's `workflow.discuss_mode`.
- **Research / verification** on the quick route come from the handoff flags
  (`--research --validate`); the corresponding config keys are inert there. On
  the phase route they follow the repo's `workflow.*` config natively.
- **Branching** is Shell-owned. GSD's `git.branching_strategy` stays `none`
  (and `git.quick_branch_template` `null`); the `create-branch` node makes
  `fix/issue-<N>` so the Engine commits onto the feature branch.

## Optional: worktree tuning

If the repo sets `workflow.use_worktrees: true`, parallel execution can degrade
to sequential in Archon's fresh clone when the branch looks diverged from the
remote head. Pointing the worktree base ref at `HEAD` avoids that. This is a
tuning nicety, not required for correctness.
