# Deploy the custom image via Archon's Dockerfile.user + compose override

**Status:** accepted (refines the build/deploy mechanism of [ADR 0001](./0001-gsd-runtime-via-custom-archon-image.md))

ADR 0001 decided to **bake** node ≥ 22 + a container-global GSD install into a
custom Archon image. This ADR records *how* that image is built and deployed: as
Archon's own `app` image, via Archon's supported `Dockerfile.user` extension slot
selected by a `docker-compose.override.yml` — **not** as a separately-tagged
`archon-gsd` image built with a standalone `docker build`.

## Decision

Ship `docker-compose.override.yml` + `docker/Dockerfile.user` (FROM archon,
running the shared `install-gsd-runtime.sh`) as drop-in templates. The user copies
them — plus `install-gsd-runtime.sh` — into their Archon checkout root. Compose
auto-merges the override, so `docker compose up` builds and runs the GSD-enabled
`app` image. The standalone `docker/Dockerfile` (`docker build -t archon-gsd`) is
removed.

## Why this is non-obvious

1. **Archon already blesses this path.** Archon ships `docker-compose.override.example.yml`
   and `Dockerfile.user.example` for exactly this — both gitignored, auto-merged,
   documented. Using them keeps customizations local and survives Archon upgrades.
2. **It matches the user's actual workflow** (`docker compose up`) with one command
   and no manual image build/wire step, while staying **baked** (zero per-boot cost).

## Considered alternatives

- **Standalone `archon-gsd` image** (the old `docker/Dockerfile`, `docker build -t
  archon-gsd`, then point the `app` service at it). Rejected: an extra manual build
  + wiring step outside Compose, duplicating what Archon's override slot already does.
- **Pure `docker-compose.override.yml`, no Dockerfile (runtime install).** An override
  that installs node + GSD at container start via an `entrypoint:` wrapper, eliminating
  the Dockerfile entirely. Rejected: to add node *without* a build, the override must
  **replace Archon's `docker-entrypoint.sh`** (gosu drop, volume chown, git safe.dir,
  GH_TOKEN cred helper, CLAUDE_BIN_PATH glibc pinning, setup-auth) with a wrapper that
  re-execs it — brittle against Archon changes — and pay a full `apt`/NodeSource node
  install on **every cold `docker compose up`** (the container layer is ephemeral; only
  the `archon_user_home` GSD install persists). Baking pays that cost once at build.

## Consequence

CI coverage is unaffected: `install-gsd-runtime.sh` is still proven by
`docker/Dockerfile.smoke`, which the production `Dockerfile.user` reuses verbatim.
Because `Dockerfile.user` is `FROM archon`, the base `archon` image must be built
before the override builds — hence the two-step (`docker compose -f
docker-compose.yml build`, then `docker compose up`).
