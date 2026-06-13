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
| `guard-planning` | bash | **entry node** — fail fast unless `.planning/` (config + STATE + ROADMAP) exists; never bootstraps. Runs before any LLM/`gh` spend. |
| `extract-issue-number` | prompt | resolve the issue number |
| `fetch-issue` | bash | `gh issue view` |
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
install under the appuser home), baked on top of the `archon` base via Archon's
own [`Dockerfile.user`](./docker/Dockerfile.user) extension slot, selected by a
[`docker-compose.override.yml`](./docker-compose.override.yml) — so a plain
`docker compose up` builds and runs it. Decisions recorded in
[ADR 0001](./docs/adr/0001-gsd-runtime-via-custom-archon-image.md) (why baked +
container-global) and [ADR 0002](./docs/adr/0002-deploy-via-dockerfile-user-and-compose-override.md)
(why the Dockerfile.user + compose-override mechanism).

Each **target repo** carries only its own `.planning/` (GSD config + state +
roadmap) and must include the [headless config](./docs/headless-config.md) keys
so the Engine never waits on a human.

## Add archon-gsd to an existing Archon setup

You run Archon from its own checkout with `docker compose up`. To bake the Engine
into Archon's `app` image, drop three files into that checkout **root** (next to
Archon's `docker-compose.yml`) — all are gitignored by Archon, so your copy stays
local:

| copy this repo's… | to your Archon checkout as… |
|-------------------|-----------------------------|
| `docker-compose.override.yml` | `docker-compose.override.yml` |
| `docker/Dockerfile.user` | `Dockerfile.user` |
| `docker/install-gsd-runtime.sh` | `install-gsd-runtime.sh` |

Then build the base image first (the override's `Dockerfile.user` is `FROM
archon`, so `archon` must exist before it builds), and bring the stack up:

```bash
docker compose -f docker-compose.yml build   # base `archon` (override excluded)
docker compose up -d                          # builds Dockerfile.user, runs the stack
```

Compose auto-merges `docker-compose.override.yml`, so the second command needs no
flags. node ≥ 22 + GSD are baked into the `app` image — no per-boot cost. Override
the Engine version via the `GSD_VERSION` build arg in `docker-compose.override.yml`.

The Engine runtime persists in the `archon_user_home` volume; each **target repo**
still needs its own committed `.planning/` (see above). The override workflow
reaches target repos either container-global at `~/.archon/workflows/` or
per-repo — see [docs/e2e-run.md](./docs/e2e-run.md).

## Repo layout

```
.archon/workflows/archon-fix-github-issue.yaml  the Shell→Engine override
docker-compose.override.yml                     drops the Engine into Archon's `app` image
docker/Dockerfile.user                          custom Archon image (FROM archon)
docker/Dockerfile.smoke                         CI image proving the install script
docker/install-gsd-runtime.sh                   shared node>=22 + GSD install
tests/                                          deterministic guard/branch/routing tests
tests/smoke/assert-runtime.sh                   container smoke assertions
docs/headless-config.md                         mandatory target-repo config
docs/e2e-run.md                                 manual end-to-end procedure
docs/adr/0001-*.md                              runtime/install decision
docs/adr/0002-*.md                              build/deploy mechanism decision
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
