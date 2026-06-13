# Run GSD inside a custom Archon container image, installed container-global

**Status:** accepted

We run Archon via its Docker setup. The Engine (GSD) must execute inside the same container Archon's Claude SDK runs in, so GSD has to be present *in the container*, not on the host.

## Decision

Bake GSD into a **custom Archon image** and install it **container-global** at `/home/appuser/.claude/` (the `archon_user_home` volume), discovered via the SDK's `settingSources: 'user'`. Target repos commit only their own `.planning/` (config.json + STATE.md + ROADMAP.md).

## Why this is non-obvious

1. **Host `~/.claude` is not mounted.** Archon clones the target repo fresh into `/.archon/workspaces/<repo>` and runs the Claude SDK in-container with `settingSources: ['project','user']`. A normal host-global `npx @opengsd/gsd-core` install is invisible. (`packages/providers/src/claude/provider.ts`)
2. **The stock image has no `node`.** Runtime base is `oven/bun:1.3.11-slim`; `Dockerfile:104` runs `apt-get purge -y nodejs npm`. GSD's `gsd_run() { node gsd-tools.cjs … }` is hardwired to `node ≥22`, so the image must re-add it.

## Considered alternatives

- **Project-carried (`settingSources:'project'`)** — vendor `.claude/commands/gsd/` + `.claude/gsd-core/` into every target repo. Rejected: GSD ends up in every repo's git history and drifts per repo. Container-global keeps repos clean at the cost of maintaining container state.

## Consequence

A `node→bun` shim was *not* chosen; bun-running `gsd-tools.cjs` is unverified (needs node≥22 + `@anthropic-ai/claude-agent-sdk`). If the custom-image node install proves heavy, revisit the shim.
