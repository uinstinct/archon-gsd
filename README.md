# archon-gsd

Re-points Archon's `archon-fix-github-issue` workflow so **Archon is a thin Shell**
(fetch the issue, guard the precondition, create the branch, open the draft PR,
report back) and **GSD is the Engine** (research, plan, execute, verify, review).
Archon stays the trigger and PR author; GSD does everything in between. None of
Archon's native investigate / plan / implement / validate / review nodes run.

See [CONTEXT.md](./CONTEXT.md) for the shared vocabulary (Shell, Engine, Routing,
Headless, Custom image, Target repo, GSD config).

## How it works

The override workflow ([`.archon/workflows/archon-fix-github-issue.yaml`](./.archon/workflows/archon-fix-github-issue.yaml))
shadows Archon's bundled default by exact filename. Its node map:

| node | type | role |
|------|------|------|
| `extract-issue-number` | prompt | resolve the issue number |
| `fetch-issue` | bash | `gh issue view` |
| `guard-planning` | bash | fail fast unless `.planning/` (config + STATE + ROADMAP) exists; never bootstraps |
| `create-branch` | bash | `git switch -c fix/issue-<N>` off `BASE_BRANCH` |
| `size-classify` | prompt (small model) | emit `{ scope: small \| large, task }` |
| `handoff-quick` | prompt | `/gsd-quick --research --validate <task>` when `scope == small` |
| `handoff-phase` | prompt | `/gsd-phase <task>` when `scope == large` |
| `create-pr` | prompt | push branch + open draft PR, body from GSD's summary |
| `verify-pr-base` | bash | re-target the PR base if it drifted |
| `report` | prompt | comment on the issue from GSD's summary |

Routing is **Shell-owned** — a classify node picks the route and the Shell calls
the GSD command directly. GSD's own `gsd:do` dispatcher is deliberately unused
because it prompts a human on ambiguity, which would stall a headless run.

## Runtime

GSD runs inside a **custom Archon image** (node ≥ 22 + a container-global GSD
install under the appuser home), built from [`docker/Dockerfile`](./docker/Dockerfile)
on top of the `archon` base. Decision recorded in
[ADR 0001](./docs/adr/0001-gsd-runtime-via-custom-archon-image.md).

Each **target repo** carries only its own `.planning/` (GSD config + state +
roadmap) and must include the [headless config](./docs/headless-config.md) keys
so the Engine never waits on a human.

## Repo layout

```
.archon/workflows/archon-fix-github-issue.yaml  the Shell→Engine override
docker/Dockerfile                               custom Archon image (FROM archon)
docker/Dockerfile.smoke                         CI image proving the install script
docker/install-gsd-runtime.sh                   shared node>=22 + GSD install
tests/                                          deterministic guard/branch/routing tests
tests/smoke/assert-runtime.sh                   container smoke assertions
docs/headless-config.md                         mandatory target-repo config
docs/e2e-run.md                                 manual end-to-end procedure
docs/adr/0001-*.md                              runtime/install decision
CONTEXT.md                                       domain glossary
```

## Tests

```bash
bash tests/run-all.sh                                   # guard / branch / routing (deterministic)
docker build -f docker/Dockerfile.smoke -t archon-gsd-smoke .
docker run --rm archon-gsd-smoke                        # container smoke test
```

CI runs both on every push/PR ([.github/workflows/ci.yml](./.github/workflows/ci.yml)).
The full live path is validated manually — see [docs/e2e-run.md](./docs/e2e-run.md).
