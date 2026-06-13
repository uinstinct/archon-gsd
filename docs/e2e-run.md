# End-to-end run (manual)

Validate the whole Shell → Engine → PR path against a fixture repo and a fixture
GitHub issue before trusting the workflow on real issues. This is a **documented
procedure, not CI** — live Claude + `gh` make it too slow and flaky to gate on.
The deterministic plumbing (guard, branch, routing) and the image are covered by
CI (`tests/run-all.sh`, `docker/Dockerfile.smoke`); this exercises the parts CI
deliberately does not: real GSD execution and real PR creation.

## Prerequisites

- The custom image is built and wired into Archon's stack via the
  `docker-compose.override.yml` + `Dockerfile.user` drop-in (see the README,
  "Add archon-gsd to an existing Archon setup"): copy them plus
  `install-gsd-runtime.sh` into the Archon checkout, then
  `docker compose -f docker-compose.yml build && docker compose up -d`. Confirm
  the runtime with the smoke test (it builds the same install script):
  `docker build -f docker/Dockerfile.smoke -t archon-gsd-smoke . && docker run --rm archon-gsd-smoke`.
- A **fixture target repo** on GitHub that:
  - is GSD-initialised — committed `.planning/config.json`, `.planning/STATE.md`,
    `.planning/ROADMAP.md` (so `guard-planning` passes);
  - has the **headless config** keys in `.planning/config.json`
    (see [headless-config.md](./headless-config.md));
  - carries this override workflow so it shadows the bundled default — copy
    `.archon/workflows/archon-fix-github-issue.yaml` into the fixture repo's
    `.archon/workflows/` (repo scope), or place it container-global at
    `~/.archon/workflows/` in the image so every cloned repo gets it.
- A **fixture issue** in that repo — open two, one obviously small (a typo / a
  one-line fix) and one obviously large (a multi-file feature) to exercise both
  routes.
- `gh` authenticated for the fixture repo; Claude credentials available to the
  Archon container.

## Run

Trigger the workflow through the `archon` CLI against the fixture issue, e.g.:

```bash
archon run archon-fix-github-issue "fix issue #<N>"
```

(Use whatever invocation your Archon deployment uses to run a workflow by name
against an issue; the workflow name is `archon-fix-github-issue`.)

## What to assert

Per route (run once with the small issue, once with the large one):

1. **Guard** — with a *non*-initialised repo, the run fails at `guard-planning`
   before any handoff fires, with the "not GSD-initialised" guidance. (Optional:
   temporarily remove `.planning/ROADMAP.md` to see this.)
2. **Branch** — a `fix/issue-<N>` branch exists, based on the base branch.
3. **Routing** — the small issue ran `handoff-quick` (`/gsd-quick --research
   --validate`); the large issue ran `handoff-phase` (`/gsd-phase`). Check the
   run log for which handoff node executed.
4. **Engine work** — GSD's commits are on the branch, and its outputs exist under
   `.planning/` (quick: `.planning/quick/<slug>/SUMMARY.md`; phase: phase
   summaries + updated `STATE.md`).
5. **PR** — a **draft** PR is open, based on the base branch, body assembled from
   GSD's summary, linking the issue (`Fixes #<N>`).
6. **Report** — a completion comment is posted on the issue, summarising what the
   Engine did and linking the PR.
7. **No double work** — the run log shows none of Archon's native
   investigate / plan / implement / validate / review nodes ran.

## If the in-prompt handoff doesn't dispatch

The handoff nodes send a bare `/gsd-quick` / `/gsd-phase` so the Claude SDK
dispatches it as a command resolved from the container-global install. If a run
shows the slash command treated as prose instead of executed, switch the handoff
to the documented `bash` fallback (run `claude -p "/gsd-quick --research
--validate <task>"` against the same install) — see the comment on the handoff
nodes in `.archon/workflows/archon-fix-github-issue.yaml`.
