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
install), baked on top of the `archon` base via Archon's own
[`Dockerfile.user`](./docker/Dockerfile.user) extension slot, selected by a
[`docker-compose.override.yml`](./docker-compose.override.yml). Decisions recorded
in [ADR 0001](./docs/adr/0001-gsd-runtime-via-custom-archon-image.md) (why baked +
container-global) and [ADR 0002](./docs/adr/0002-deploy-via-dockerfile-user-and-compose-override.md)
(why the Dockerfile.user + compose-override mechanism).

Archon mounts the `archon_user_home` named volume over `/home/appuser`, which
**shadows** the GSD install baked there — and Docker's empty-volume seeding does
not fire reliably under Archon's entrypoint. So the image stashes a pristine GSD
tree at `/opt/gsd-home/.claude` (outside the volume) and a seed entrypoint
([`gsd-seed-entrypoint.sh`](./docker/gsd-seed-entrypoint.sh)) copies it into the
live volume on every boot before exec'ing Archon's own entrypoint. This makes the
Claude SDK resolve `/gsd-quick` and `/gsd-phase` regardless of volume state — no
`down -v` needed on redeploy.

Each **target repo** carries only its own `.planning/` (GSD config + state +
roadmap) and must include the [headless config](./docs/headless-config.md) keys
so the Engine never waits on a human.

## Add archon-gsd to an existing Archon setup

You run Archon from its own checkout with `docker compose up`. A working
integration needs three things in place — the Engine baked into the image, the
override workflow reachable from target repos, and each target repo prepared.

### 1. Bake the Engine into Archon's `app` image

Drop three files into your Archon checkout **root** (next to Archon's
`docker-compose.yml`) — all are gitignored by Archon, so your copy stays local:

| copy this repo's… | to your Archon checkout as… |
|-------------------|-----------------------------|
| `docker-compose.override.yml` | `docker-compose.override.yml` |
| `docker/Dockerfile.user` | `Dockerfile.user` |
| `docker/install-gsd-runtime.sh` | `install-gsd-runtime.sh` |
| `docker/gsd-seed-entrypoint.sh` | `gsd-seed-entrypoint.sh` |

Build the base image first (the override's `Dockerfile.user` is `FROM archon`, so
`archon` must exist before it builds), then build the extension and bring the
stack up:

```bash
docker compose -f docker-compose.yml build   # base `archon` (override excluded)
docker compose up -d --build                  # builds Dockerfile.user extension, runs the stack
```

`--build` is required: `docker compose up` alone will **not** rebuild the `app`
image once `archon` exists, so it would silently run the plain base without GSD.
Compose auto-merges `docker-compose.override.yml`, so no `-f` flag is needed on the
second command. node ≥ 22 + GSD are baked into the `app` image — no per-boot cost.
Override the Engine version via the `GSD_VERSION` build arg in
`docker-compose.override.yml`. The seed entrypoint re-populates GSD into the
`archon_user_home` volume on every boot, so rebuilds need no `down -v`.

### 2. Make the override workflow reach target repos

The Shell→Engine workflow must shadow Archon's bundled `archon-fix-github-issue`.
Place [`.archon/workflows/archon-fix-github-issue.yaml`](./.archon/workflows/archon-fix-github-issue.yaml)
either:

- **container-global** at `~/.archon/workflows/` in the image (every cloned target
  repo inherits it), or
- **per target repo** — commit it under that repo's `.archon/workflows/`.

### 3. Prepare each target repo

Every repo an issue belongs to must be GSD-initialised and headless:

- commit `.planning/config.json`, `.planning/STATE.md`, `.planning/ROADMAP.md`
  (the `guard-planning` entry node fails fast without them — it never bootstraps);
- set the [headless config](./docs/headless-config.md) keys in
  `.planning/config.json` so the Engine never waits on a human.

### 4. Verify

Confirm the baked runtime with the smoke test (it exercises the same install
script the image runs), then drive the full path per [docs/e2e-run.md](./docs/e2e-run.md):

```bash
docker build -f docker/Dockerfile.smoke -t archon-gsd-smoke . && docker run --rm archon-gsd-smoke
```

## Repo layout

```
.archon/workflows/archon-fix-github-issue.yaml  the Shell→Engine override
docker-compose.override.yml                     drops the Engine into Archon's `app` image
docker/Dockerfile.user                          custom Archon image (FROM archon)
docker/Dockerfile.smoke                         CI image proving the install script
docker/install-gsd-runtime.sh                   shared node>=22 + GSD install (+ /opt stash)
docker/gsd-seed-entrypoint.sh                   seeds GSD into the home volume on boot
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
