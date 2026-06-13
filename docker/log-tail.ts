#!/usr/bin/env bun
// Log sidecar — streams Archon Run transcripts to stdout, one prefixed line
// per event. See issue #4 and CONTEXT.md ("Log sidecar", "Run transcript").
//
// Pure read-only observer: it reads the `archon_data` volume mounted read-only
// at /.archon, never the database, never the `app` container. The transcripts
// are the JSONL files Archon's file-logger already writes; this only renders
// them. The event schema mirrors Archon's `WorkflowEvent`
// (packages/workflows/src/logger.ts).
//
// Every emitted line carries a compact `[runId|node]` prefix so concurrent,
// interleaved runs on one stdout stream stay attributable. `runId` is the
// transcript's run id (event `workflow_id`, falling back to the filename);
// `node` is the current DAG node, derived from the most recent `node_start`.
//
// Modes (env):
//   LOG_TAIL_FOLLOW   default true — dump existing transcripts, then live-follow.
//                     set 0/false/no/off for one-shot: dump existing and exit
//                     (used by the deterministic process-seam test).
//   LOG_TAIL_ROOT     mount root to scan. Default /.archon.
//   LOG_TAIL_POLL_MS  follow poll interval in ms. Default 1000.
import { readdirSync, statSync, openSync, readSync, closeSync } from 'node:fs';
import { join, basename } from 'node:path';

const ROOT = process.env.LOG_TAIL_ROOT || '/.archon';
const FOLLOW = !/^(0|false|no|off)$/i.test(process.env.LOG_TAIL_FOLLOW ?? 'true');
const POLL_MS = Number(process.env.LOG_TAIL_POLL_MS || 1000);

const ASSISTANT_MAX = 500; // collapse/truncate verbose assistant text to one line
const TOOL_VAL_MAX = 60; // per-arg cap in a tool input summary
const TOOL_SUMMARY_MAX = 200; // whole tool input summary cap

const oneLine = (s: string): string => s.replace(/\s+/g, ' ').trim();
const trunc = (s: string, max: number): string => (s.length > max ? s.slice(0, max) + '…' : s);

// Discover transcripts: any *.jsonl directly inside a directory named `logs`,
// anywhere beneath the mount. Covers both the project-scoped
// workspaces/{owner}/{repo}/logs/ layout and the cwd-scoped .archon/logs/
// fallback (hidden dirs are walked too). Sorted for deterministic dumps.
function findLogFiles(root: string): string[] {
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
      else if (e.isFile() && e.name.endsWith('.jsonl') && basename(dir) === 'logs') out.push(full);
    }
  };
  walk(root);
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
  offset: number; // bytes consumed so far
  leftover: Buffer; // partial trailing line not yet terminated by \n
  runId: string; // filename fallback when an event lacks workflow_id
  currentNode: string; // most recent node_start step
}

const states = new Map<string, FileState>();

function getState(path: string): FileState {
  let s = states.get(path);
  if (!s) {
    s = {
      offset: 0,
      leftover: Buffer.alloc(0),
      runId: basename(path).replace(/\.jsonl$/, ''),
      currentNode: '-',
    };
    states.set(path, s);
  }
  return s;
}

function processLine(line: string, s: FileState) {
  if (!line.trim()) return;
  let ev: any;
  try {
    ev = JSON.parse(line);
  } catch {
    return; // skip malformed lines rather than crash the stream
  }
  if (ev.type === 'node_start' && ev.step) s.currentNode = ev.step;
  const body = renderBody(ev);
  if (body === null) return;
  const runId = ev.workflow_id || s.runId;
  // Lifecycle events carry their own node in `step`; everything else inherits
  // the run's current node from the last node_start.
  const node =
    ev.type === 'node_start' ||
    ev.type === 'node_complete' ||
    ev.type === 'node_skipped' ||
    ev.type === 'node_error'
      ? ev.step ?? s.currentNode
      : s.currentNode;
  process.stdout.write(`[${runId}|${node}] ${body}\n`);
}

// Read any bytes that appeared since the last offset and render complete lines;
// a trailing partial line is buffered until its newline arrives (so an
// in-progress transcript is followed incrementally).
function pump(path: string) {
  const s = getState(path);
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

// Initial dump: every existing transcript, in sorted order, fully.
for (const f of findLogFiles(ROOT)) pump(f);

// Follow: re-scan for transcripts that appear mid-flight (new files start at
// offset 0, so their backlog is dumped too) and read growth from known ones.
// In one-shot mode nothing keeps the event loop alive, so the process exits
// naturally here after the dump above — flushing stdout cleanly.
if (FOLLOW) {
  setInterval(() => {
    for (const f of findLogFiles(ROOT)) pump(f);
  }, POLL_MS);
}
