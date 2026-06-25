# Archon-GSD

Integration that lets Archon's GitHub-issue automation hand the actual coding work to GSD instead of doing it natively. Archon stays the outer trigger/PR shell; GSD becomes the engine that plans and executes.

## Language

**Shell**:
Archon's role in this integration — the outer orchestration that fetches the GitHub issue, sets up the branch, and opens the pull request. Does no coding work itself.
_Avoid_: orchestrator, wrapper, host

**Engine**:
GSD's role — the part that researches, plans, and writes the code for an issue. Invoked by the Shell.
_Avoid_: worker, backend, executor (executor is a GSD-internal term)

**Workflow** (Archon):
A YAML DAG of nodes run by Archon's own runtime. `archon-fix-github-issue` is the one being re-pointed at the Engine.
_Avoid_: pipeline, job

**Node** (Archon):
One step in an Archon Workflow. Types: `command`, `prompt`, `bash`, `script`, `loop`, `approval`.

**Handoff node**:
The single Archon Node where the Shell invokes GSD. Replaces Archon's native investigate/plan/implement nodes.
_Avoid_: bridge, adapter

**Routing**:
The Shell's decision per issue — `small` runs the Engine via `gsd:quick`; `large` is **declined** (the Engine is not invoked) and the issue gets a Decline comment. Owned by an Archon classify node, NOT by gsd's own `gsd:do` dispatcher, because `gsd:do` prompts a human on ambiguity and the Shell runs headless. `gsd:phase` is no longer auto-invoked — see [ADR 0004](./docs/adr/0004-decline-large-issues-instead-of-auto-phase.md).
_Avoid_: dispatch, gsd:do (deliberately unused here)

**Decline**:
The Shell's terminal outcome for a `large`-routed issue: no branch, no Engine run, no PR — just a GitHub comment flagging the issue for a human. The router declined to auto-fix because `gsd:phase` headless is unreliable on big tasks.
_Avoid_: reject, skip, fail (it is a successful run, not an error)

**Headless**:
The unattended mode the Engine must run in under Archon — no human to answer prompts. Requires `mode:"yolo"`, all `gates:false`, `safety.*:false`, and skipping discuss. Any `AskUserQuestion` the Engine reaches is a stall, so the design avoids paths that call it.
_Avoid_: non-interactive, batch

**gsd:quick**:
GSD's minimal command for one small self-contained task. Honors only a subset of GSD config (research, verifier, code_review, security, use_worktrees, commit_docs, discuss_mode).

**gsd:phase**:
GSD's full plan/build/verify loop for complex work. Honors the full GSD config.

**GSD config**:
`.planning/config.json` in the target repo. The settings block driving Engine behavior. Distinct from any Archon config.
_Avoid_: settings file (ambiguous — Archon has its own)

**Custom image**:
The bespoke Archon container image carrying node≥22 and a container-global GSD install at `/home/appuser/.claude/`. The stock `oven/bun` image cannot run the Engine. See [ADR 0001](./docs/adr/0001-gsd-runtime-via-custom-archon-image.md).
_Avoid_: gsd image, patched image

**Headroom proxy**:
The sidecar service (its own service in `docker-compose.override.yml`, never the Archon `app` container) that transparently compresses every Claude Code → Anthropic call for token savings. Reached by the Engine via `ANTHROPIC_BASE_URL`; **requires** `ENABLE_TOOL_SEARCH=true` on the Shell's `app` service, or Claude Code materializes every tool schema into context and breaks the Engine's sub-agents. Replaces the former baked rtk binary. See [ADR 0003](./docs/adr/0003-token-compression-via-headroom-proxy.md).
_Avoid_: token killer, rtk, compressor

**Target repo**:
The repository an issue belongs to, cloned fresh by Archon into the container per run. Carries only its own `.planning/` (config + state) — the Engine runtime lives in the Custom image, not here.
_Avoid_: workspace, checkout

**Run transcript**:
The per-run JSONL file Archon's file-logger writes to `/.archon/workspaces/{owner}/{repo}/logs/{runId}.jsonl` in the `archon_data` volume. Holds the full agent trace — assistant text, tool calls, node start/complete/error. The superset source of truth for what a run did.
_Avoid_: logs (ambiguous — see Run events), output

**Run events**:
The DB rows Archon's UI renders for a run. A subset of the Run transcript; this is why the Command Center can show "only the input" while the transcript on disk holds everything.
_Avoid_: logs, history

A separate container (its own service in `docker-compose.override.yml`, never the Archon `app` container) that mounts `archon_data` read-only and streams every Run transcript to stdout, one prefixed line per event. It also mounts `archon_user_home` read-only and renders Claude Code session transcripts (`~/.claude/projects/**`), covering comment-triggered runs that aren't Workflow runs. Read-only observer; touches nothing Archon writes.
_Avoid_: log viewer, tailer
