#!/usr/bin/env bun
// Log sidecar — streams Archon Run transcripts and Claude Code session logs
// to stdout, one prefixed line per event. See issue #4 and CONTEXT.md
// ("Log sidecar", "Run transcript").
//
// Pure read-only observer: it reads the `archon_data` volume mounted read-only
// at /.archon and the `archon_user_home` volume mounted read-only at /.home,
// never the database, never the `app` container. The transcripts are the JSONL
// files Archon's file-logger and the Claude SDK already write; this only
// renders them. The workflow event schema mirrors Archon's `WorkflowEvent`
// (packages/workflows/src/logger.ts). The Claude session schema is the JSONL
// the Claude Code SDK writes under ~/.claude/projects/** — covering
// comment-triggered agent runs that never become Workflow runs.
//
// Every emitted line carries a compact `[runId|node]` prefix so concurrent,
// interleaved runs on one stdout stream stay attributable. `runId` is the
// transcript's run id (event `workflow_id` or `sessionId`, falling back to the
// filename); `node` is the current DAG node (workflow) or gitBranch / subagent
// tag (Claude session).
//
// Modes (env):
//   LOG_TAIL_FOLLOW   default true — dump existing transcripts, then live-follow.
//                     set 0/false/no/off for one-shot: dump existing and exit
//                     (used by the deterministic process-seam test).
//   LOG_TAIL_ROOT     mount root to scan for Workflow transcripts. Default /.archon.
//   LOG_TAIL_HOME     home-volume root to scan for Claude sessions. Default /.home.
//   LOG_TAIL_POLL_MS  follow poll interval in ms. Default 1000.
import { readdirSync, statSync, openSync, readSync, closeSync } from 'node:fs';
import { join, basename, relative, sep } from 'node:path';

const ROOT = process.env.LOG_TAIL_ROOT || '/.archon';
const FOLLOW = !/^(0|false|no|off)$/i.test(process.env.LOG_TAIL_FOLLOW ?? 'true');
const POLL_MS = Number(process.env.LOG_TAIL_POLL_MS || 1000);
const HOME_ROOT = process.env.LOG_TAIL_HOME || '/.home';

const ASSISTANT_MAX = 500; // collapse/truncate verbose assistant text to one line
const TOOL_VAL_MAX = 60; // per-arg cap in a tool input summary
const TOOL_SUMMARY_MAX = 200; // whole tool input summary cap

const oneLine = (s: string): string => s.replace(/\s+/g, ' ').trim();
const trunc = (s: string, max: number): string => (s.length > max ? s.slice(0, max) + '…' : s);

// A `logs/` dir holds real Archon Workflow transcripts only at one of these
// shapes RELATIVE TO the scan root: top-level `logs/`, the cwd-scoped
// `.archon/logs/`, or the project-scoped `workspaces/{owner}/{repo}/logs/`.
// Anchoring `workspaces` at the root rejects `logs/` dirs nested deeper inside a
// cloned target repo's tree (e.g. this repo's own tests/fixtures/log-sidecar/**).
function isWorkflowLogsDir(root: string, dir: string): boolean {
  const segs = relative(root, dir).split(sep).filter(Boolean);
  if (segs.length === 1 && segs[0] === 'logs') return true;
  if (segs.length === 2 && segs[0] === '.archon' && segs[1] === 'logs') return true;
  if (segs.length === 4 && segs[0] === 'workspaces' && segs[3] === 'logs') return true;
  return false;
}

// Workflow transcripts: *.jsonl inside an accepted `logs` dir under the root.
function findWorkflowLogs(root: string): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = join(dir, e.name);
      if (e.isDirectory()) walk(full);
      else if (
        e.isFile() &&
        e.name.endsWith('.jsonl') &&
        basename(dir) === 'logs' &&
        isWorkflowLogsDir(root, dir)
      )
        out.push(full);
    }
  };
  walk(root);
  return out.sort();
}

// Claude Code session transcripts: every *.jsonl under <homeRoot>/.claude/projects
// (includes nested per-session dirs and their subagents/). Missing base dir → [].
function findClaudeLogs(homeRoot: string): string[] {
  const base = join(homeRoot, '.claude', 'projects');
  const out: string[] = [];
  const walk = (dir: string) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = join(dir, e.name);
      if (e.isDirectory()) walk(full);
      else if (e.isFile() && e.name.endsWith('.jsonl')) out.push(full);
    }
  };
  walk(base);
  return out.sort();
}

// Compact summary of a tool_input object: `key=val, key=val`, each value
// one-lined and capped, the whole thing capped — so tool calls render without
// raw JSON noise.
function summarizeInput(input: unknown): string {
  if (!input || typeof input !== 'object') return '';
  const parts: string[] = [];
  for (const [k, v] of Object.entries(input as Record<string, unknown>)) {
    const raw = typeof v === 'string' ? v : JSON.stringify(v);
    parts.push(`${k}=${trunc(oneLine(String(raw ?? '')), TOOL_VAL_MAX)}`);
  }
  return trunc(parts.join(', '), TOOL_SUMMARY_MAX);
}

// Render one event's body (without the prefix). Returns null for event types
// that produce no line.
function renderBody(ev: any): string | null {
  switch (ev.type) {
    case 'workflow_start':
      return `▶ workflow ${ev.workflow_name ?? '?'}${
        ev.content ? ` | input: ${trunc(oneLine(ev.content), ASSISTANT_MAX)}` : ''
      }`;
    case 'assistant':
      return `assistant: ${trunc(oneLine(ev.content ?? ''), ASSISTANT_MAX)}`;
    case 'tool':
      return `→ ${ev.tool_name ?? '?'}(${summarizeInput(ev.tool_input)})`;
    case 'node_start':
      return `● ▷ node ${ev.step}${ev.content ? ` (${ev.content})` : ''}`;
    case 'node_complete':
      return `● ✓ node ${ev.step}${ev.duration_ms !== undefined ? ` (${ev.duration_ms}ms)` : ''}`;
    case 'node_skipped':
      return `● ⊘ node ${ev.step} skipped${ev.content ? `: ${oneLine(ev.content)}` : ''}`;
    case 'node_error':
      return `● ✗ node ${ev.step} error: ${oneLine(ev.error ?? '')}`;
    case 'validation': {
      const m = ev.result === 'pass' ? '✓' : ev.result === 'fail' ? '✗' : '•';
      return `${m} validation ${ev.check}: ${ev.result}${ev.error ? ` — ${oneLine(ev.error)}` : ''}`;
    }
    case 'workflow_complete':
      return '■ workflow complete';
    case 'workflow_error':
      return `✖ workflow error: ${oneLine(ev.error ?? '')}`;
    default:
      return null;
  }
}

interface FileState {
  kind: 'workflow' | 'claude';
  offset: number; // bytes consumed so far
  leftover: Buffer; // partial trailing line not yet terminated by \n
  runId: string; // filename fallback when an event lacks workflow_id / sessionId
  currentNode: string; // most recent node_start step (workflow) or gitBranch (claude)
}

const states = new Map<string, FileState>();

function getState(path: string, kind: FileState['kind']): FileState {
  let s = states.get(path);
  if (!s) {
    s = {
      kind,
      offset: 0,
      leftover: Buffer.alloc(0),
      runId: basename(path).replace(/\.jsonl$/, ''),
      currentNode: '-',
    };
    states.set(path, s);
  }
  return s;
}

interface Item {
  runId: string;
  node: string;
  body: string;
}

// Workflow event → at most one prefixed line. Identical behavior to the prior
// inline logic: node_start updates currentNode; lifecycle events carry their own
// node in `step`, everything else inherits the run's current node.
function renderWorkflow(ev: any, s: FileState): Item[] {
  if (ev.type === 'node_start' && ev.step) s.currentNode = ev.step;
  const body = renderBody(ev);
  if (body === null) return [];
  const runId = ev.workflow_id || s.runId;
  const node =
    ev.type === 'node_start' ||
    ev.type === 'node_complete' ||
    ev.type === 'node_skipped' ||
    ev.type === 'node_error'
      ? ev.step ?? s.currentNode
      : s.currentNode;
  return [{ runId, node, body }];
}

// Claude Code session event → zero or more prefixed lines. node = `subagent` for
// sidechain lines, else the line's gitBranch (tracked across the file), else
// `claude`. Renders assistant/user text, tool_use (name + input summary), and
// FAILED tool_result; skips thinking, images, and successful tool_result (noise).
function renderClaude(ev: any, s: FileState): Item[] {
  const msg = ev.message;
  if (!msg || (ev.type !== 'assistant' && ev.type !== 'user')) return [];
  if (ev.gitBranch && !ev.isSidechain) s.currentNode = ev.gitBranch;
  const node = ev.isSidechain
    ? 'subagent'
    : ev.gitBranch || (s.currentNode !== '-' ? s.currentNode : 'claude');
  const runId = ev.sessionId || s.runId;
  const label = ev.type === 'assistant' ? 'assistant' : 'user';
  const items: Item[] = [];
  const content = msg.content;
  if (typeof content === 'string') {
    if (content.trim()) items.push({ runId, node, body: `${label}: ${trunc(oneLine(content), ASSISTANT_MAX)}` });
    return items;
  }
  if (!Array.isArray(content)) return items;
  for (const b of content) {
    if (b.type === 'text' && typeof b.text === 'string' && b.text.trim()) {
      items.push({ runId, node, body: `${label}: ${trunc(oneLine(b.text), ASSISTANT_MAX)}` });
    } else if (b.type === 'tool_use') {
      items.push({ runId, node, body: `→ ${b.name ?? '?'}(${summarizeInput(b.input)})` });
    } else if (b.type === 'tool_result' && b.is_error) {
      const c = typeof b.content === 'string' ? b.content : JSON.stringify(b.content);
      items.push({ runId, node, body: `← ERROR ${trunc(oneLine(c ?? ''), ASSISTANT_MAX)}` });
    }
  }
  return items;
}

function processLine(line: string, s: FileState) {
  if (!line.trim()) return;
  let ev: any;
  try {
    ev = JSON.parse(line);
  } catch {
    return; // skip malformed lines rather than crash the stream
  }
  const items = s.kind === 'claude' ? renderClaude(ev, s) : renderWorkflow(ev, s);
  for (const it of items) process.stdout.write(`[${it.runId}|${it.node}] ${it.body}\n`);
}

// Read any bytes that appeared since the last offset and render complete lines;
// a trailing partial line is buffered until its newline arrives (so an
// in-progress transcript is followed incrementally).
function pump(path: string, kind: FileState['kind']) {
  const s = getState(path, kind);
  let size: number;
  try {
    size = statSync(path).size;
  } catch {
    return;
  }
  if (size <= s.offset) return;
  const len = size - s.offset;
  const buf = Buffer.alloc(len);
  let fd: number | undefined;
  try {
    fd = openSync(path, 'r');
    readSync(fd, buf, 0, len, s.offset);
  } catch {
    if (fd !== undefined) closeSync(fd);
    return;
  }
  closeSync(fd);
  s.offset = size;
  const data = Buffer.concat([s.leftover, buf]);
  const lastNl = data.lastIndexOf(0x0a);
  if (lastNl === -1) {
    s.leftover = data;
    return;
  }
  const complete = data.subarray(0, lastNl + 1).toString('utf8');
  s.leftover = data.subarray(lastNl + 1);
  for (const line of complete.split('\n')) processLine(line, s);
}

// Initial dump: every existing transcript (workflow then Claude session), fully.
for (const f of findWorkflowLogs(ROOT)) pump(f, 'workflow');
for (const f of findClaudeLogs(HOME_ROOT)) pump(f, 'claude');

// Follow: re-scan both roots for transcripts that appear mid-flight (new files
// start at offset 0, so their backlog is dumped too) and read growth from known
// ones. In one-shot mode nothing keeps the event loop alive, so the process
// exits naturally after the dump above — flushing stdout cleanly.
if (FOLLOW) {
  setInterval(() => {
    for (const f of findWorkflowLogs(ROOT)) pump(f, 'workflow');
    for (const f of findClaudeLogs(HOME_ROOT)) pump(f, 'claude');
  }, POLL_MS);
}
