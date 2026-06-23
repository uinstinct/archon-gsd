# Token compression via the headroom proxy sidecar

**Status:** accepted (supersedes the baked `rtk` binary; refines the runtime of
[ADR 0001](./0001-gsd-runtime-via-custom-archon-image.md))

The image previously baked **rtk** (Rust Token Killer) — a binary on PATH the
agent *could* call — for token savings. We replace it with
[**headroom**](https://github.com/headroomlabs-ai/headroom), run as a transparent
**API-proxy sidecar** that compresses the payload of every Claude Code → Anthropic
call (60–95% savings). This ADR records why headroom is wired as a proxy sidecar
rather than baked, and the non-obvious requirements that wiring carries.

## Decision

Add a `headroom` service to `docker-compose.override.yml`
(`ghcr.io/chopratejas/headroom:latest`, `headroom proxy --host 0.0.0.0 --port
8787`, healthcheck on `/readyz`, a `headroom_workspace` volume). Point Claude Code
at it from the `app` service with two env vars:

- `ANTHROPIC_BASE_URL: http://headroom:8787`
- `ENABLE_TOOL_SEARCH: "true"`

The `app` service `depends_on` the proxy being **healthy**. Run **lean** — no
qdrant/neo4j memory stack. The baked rtk layer and `install-rtk.sh` are removed.

## Why this is non-obvious

1. **A proxy, not a baked binary.** rtk was passive (the agent had to invoke it).
   Headroom intercepts *every* call transparently — far higher leverage — but only
   if Claude Code is pointed at it. The env vars set on the `app` service reach the
   Claude Code subprocess because Archon's Claude provider passes `env: process.env`
   straight through when the Agent SDK spawns the `claude` binary.

2. **`ENABLE_TOOL_SEARCH=true` is mandatory, not optional** (headroom GH #746). When
   `ANTHROPIC_BASE_URL` is a custom host, Claude Code stops deferring MCP/system tool
   schemas and **materializes every one into its context window — breaking sub-agents
   and forcing compaction**. Headroom's own `wrap`/`init`/`install` paths all set this.
   It is acute here because the Engine is **sub-agent-heavy** (`gsd-phase` fans out):
   setting the base URL without this flag would *bloat* every run — the opposite of
   the goal. The two vars ship together or not at all; the wiring test
   (`tests/headroom-wiring.test.sh`) guards both.

3. **Auth passes through.** The proxy forwards the incoming request's `x-api-key` /
   `Authorization: Bearer` upstream to `https://api.anthropic.com` unchanged, so
   Archon's `CLAUDE_CODE_OAUTH_TOKEN` / `CLAUDE_API_KEY` keeps working — no proxy-side
   credentials needed.

4. **Fail closed.** Under headless GSD there is no human to notice a dead proxy. The
   `app` waits on the proxy's healthcheck via `depends_on: { condition:
   service_healthy }`, so a broken proxy stops runs rather than silently bypassing or
   stalling them. Adopters who want no compression comment out the two env vars, the
   `depends_on` block, and the `headroom` service.

## Considered alternatives

- **Bake headroom into the app image** (`pip install` + `headroom init` startup hook),
  mirroring how rtk was baked. Rejected: adds the Python/Rust runtime to the `app`
  image, and `init`'s auto-start-via-hook dance fights the headless constraint. A
  sidecar keeps the runtime out of the image and mirrors the existing `log-tail`
  sidecar pattern.
- **MCP server mode** (`headroom mcp install`). Rejected: exposes compression *tools*
  the agent must choose to call — no transparent savings — and adds tools to the
  agent surface the headless config deliberately trims.
- **Full memory stack now** (qdrant + neo4j for `headroom learn` / cross-agent
  memory). Deferred: the token compression that replaces rtk's purpose needs neither;
  the DBs add two heavyweight containers and credentials. A later ADR can add them.

## Consequence

The container smoke test (`Dockerfile.smoke` + `assert-runtime.sh`) gains **no**
headroom assertion: the proxy is a sidecar, not in the image, so there is nothing
baked to assert — the smoke test stays focused on the GSD runtime. Headroom wiring is
instead guarded by the fast `tests/headroom-wiring.test.sh` (replacing the deleted
`install-rtk.test.sh`). End-to-end validation — that a `gsd-phase` run's sub-agents
work through the proxy and traffic is actually compressed — lives in
[docs/e2e-run.md](../e2e-run.md).
