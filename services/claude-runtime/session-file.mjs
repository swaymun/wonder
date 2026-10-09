// Claude Code's own session files, read-only. The SDK's message reader starts
// at the latest compaction, so turns before it (and the agent tasks launched
// there) would vanish from Wonder. This reader keeps the earlier chain and the
// per-task metadata Claude Code stores beside the transcript.
import { lstat, open, readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileEditResult } from "./projection.mjs";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_SESSION_BYTES = 512 * 1024 * 1024;
const CACHED_FILES = 4;
const MAX_TASK_FILES = 200;

// Claude Code names a project folder after its path with every other character replaced.
export const projectFolderName = cwd => cwd.replace(/[^a-zA-Z0-9]/g, "-");

export class ClaudeSessionFiles {
  constructor(root = join(homedir(), ".claude", "projects")) {
    Object.assign(this, { root, paths: new Map(), files: new Map() });
  }

  async locate(sessionId, cwd) {
    if (!UUID.test(sessionId)) return null;
    const known = this.paths.get(sessionId);
    if (known && await regularFile(known)) return known;
    const direct = typeof cwd === "string" ? join(this.root, projectFolderName(cwd), `${sessionId}.jsonl`) : null;
    if (direct && await regularFile(direct)) { this.paths.set(sessionId, direct); return direct; }
    // Long paths are shortened by Claude Code; find the session by its UUID instead.
    let folders = [];
    try { folders = (await readdir(this.root, { withFileTypes: true })).filter(d => d.isDirectory()).slice(0, 2000); } catch { return null; }
    for (const folder of folders) {
      const path = join(this.root, folder.name, `${sessionId}.jsonl`);
      if (await regularFile(path)) { this.paths.set(sessionId, path); return path; }
    }
    return null;
  }

  // Parsed lines, read incrementally: an append reads only the new bytes.
  async entries(path) {
    let info;
    try { info = await lstat(path); } catch { return null; }
    if (!info.isFile() || info.size > MAX_SESSION_BYTES) return null;
    let cached = this.files.get(path);
    if (!cached || cached.ino !== info.ino || info.size < cached.offset) {
      cached = { ino: info.ino, offset: 0, remainder: "", rows: [], byId: new Map(), stamp: "" };
    }
    if (info.size > cached.offset) {
      const handle = await open(path, "r");
      try {
        const buffer = Buffer.alloc(info.size - cached.offset);
        const { bytesRead } = await handle.read(buffer, 0, buffer.length, cached.offset);
        const lines = (cached.remainder + buffer.subarray(0, bytesRead).toString("utf8")).split("\n");
        cached.remainder = lines.pop();
        cached.offset += bytesRead;
        for (const line of lines) {
          if (!line) continue;
          let row;
          try { row = JSON.parse(line); } catch { continue; }
          if (!row || typeof row !== "object") continue;
          row.index = cached.rows.length;
          cached.rows.push(row);
          if (typeof row.uuid === "string") cached.byId.set(row.uuid, row);
        }
      } finally { await handle.close(); }
    }
    cached.stamp = `${info.ino}:${info.size}:${info.mtimeMs}`;
    this.files.delete(path);
    this.files.set(path, cached);
    while (this.files.size > CACHED_FILES) this.files.delete(this.files.keys().next().value);
    return cached;
  }

  // The SDK's reader drops Claude Code's `toolUseResult`; file edits keep
  // theirs here, by message uuid, so history counts the lines really changed.
  async fileEdits(sessionId, cwd) {
    const path = await this.locate(sessionId, cwd);
    const file = path ? await this.entries(path) : null;
    const edits = new Map();
    for (const row of file?.rows ?? []) {
      const edit = row.type === "user" && typeof row.uuid === "string" ? fileEditResult(row.toolUseResult) : null;
      if (edit) edits.set(row.uuid, edit);
    }
    return edits;
  }

  // Messages before the transcript point where the SDK's reader begins.
  async earlierMessages(sessionId, cwd, firstUuid) {
    const path = await this.locate(sessionId, cwd);
    const file = path && typeof firstUuid === "string" ? await this.entries(path) : null;
    const start = file?.byId.get(firstUuid);
    if (!start) return [];
    const keep = new Set(), seen = new Set([start.uuid]);
    let current = start;
    for (;;) {
      const next = current.parentUuid ?? current.logicalParentUuid;
      current = typeof next === "string" ? file.byId.get(next) : null;
      if (!current || seen.has(current.uuid)) break;
      seen.add(current.uuid);
      keep.add(current.uuid);
    }
    if (!keep.size) return [];
    // Parallel tool calls branch: keep sibling blocks of the same assistant
    // message and the tool results answering them.
    const messageIds = new Set();
    for (const id of keep) { const row = file.byId.get(id); if (row.type === "assistant" && row.message?.id) messageIds.add(row.message.id); }
    for (const row of file.rows) {
      if (row.index >= start.index) break;
      if (row.isSidechain || typeof row.uuid !== "string" || keep.has(row.uuid)) continue;
      if (row.type === "assistant" && messageIds.has(row.message?.id)) keep.add(row.uuid);
      else if (row.type === "user" && keep.has(row.parentUuid) && Array.isArray(row.message?.content)
        && row.message.content.some(block => block?.type === "tool_result")) keep.add(row.uuid);
    }
    const messages = [];
    for (const row of file.rows) {
      if (row.index >= start.index) break;
      if (!keep.has(row.uuid) || row.isSidechain) continue;
      const message = sdkShape(row, sessionId);
      if (message) messages.push(message);
    }
    return messages;
  }

  // What the newest assistant message ran with, as Claude Code recorded it.
  // `native` is false for turns Wonder's own SDK session wrote ("sdk-ts"), so
  // only a turn from the desktop app or terminal changes a thread's settings.
  async latestSettings(sessionId, cwd) {
    const path = await this.locate(sessionId, cwd);
    const file = path ? await this.entries(path) : null;
    for (let i = (file?.rows.length ?? 0) - 1; i >= 0; i--) {
      const row = file.rows[i], model = row.message?.model;
      if (row.type !== "assistant" || row.isSidechain || typeof model !== "string" || !model || model.startsWith("<")) continue;
      const text = value => typeof value === "string" && value ? value : null;
      return { turnId: row.uuid, native: row.entrypoint !== "sdk-ts", model,
        effort: text(row.effort), speed: text(row.message?.usage?.speed) };
    }
    return null;
  }

  // Claude Code's per-task metadata: subagents/agent-<id>.meta.json beside the transcript.
  async agentTasks(sessionId, cwd) {
    const path = await this.locate(sessionId, cwd);
    if (!path) return [];
    const dir = join(path.slice(0, -".jsonl".length), "subagents");
    let names;
    try { names = await readdir(dir); } catch { return []; }
    const tasks = [];
    for (const name of names.filter(n => /^agent-[A-Za-z0-9_-]{1,64}\.meta\.json$/.test(n)).slice(0, MAX_TASK_FILES)) {
      const agentId = name.slice("agent-".length, -".meta.json".length);
      const meta = await smallJson(join(dir, name));
      if (!meta || typeof meta.toolUseId !== "string") continue;
      const transcript = await transcriptEnds(join(dir, `agent-${agentId}.jsonl`));
      tasks.push({ agentId, toolUseId: meta.toolUseId, agentType: typeof meta.agentType === "string" ? meta.agentType : null,
        description: typeof meta.description === "string" ? meta.description : null,
        background: meta.requestShape === "background", startedAt: transcript.startedAt, finished: transcript.finished });
    }
    return tasks;
  }

  async stamp(sessionId, cwd) {
    const path = await this.locate(sessionId, cwd);
    if (!path) return null;
    try { const info = await lstat(path); return `${path}:${info.ino}:${info.size}:${info.mtimeMs}`; } catch { return null; }
  }
}

function sdkShape(row, sessionId) {
  const base = { uuid: row.uuid, session_id: sessionId, parent_tool_use_id: null, timestamp: row.timestamp ?? null };
  if (row.type === "assistant" && row.message) return { ...base, type: "assistant", message: row.message };
  if (row.type === "user" && row.message && !row.isMeta && !row.isCompactSummary) {
    const edit = fileEditResult(row.toolUseResult);
    return { ...base, type: "user", message: row.message, ...(row.origin ? { origin: row.origin } : {}), ...(edit ? { tool_use_result: edit } : {}) };
  }
  // Task completions are stored as queued-command attachments; the SDK presents them as user notices.
  const attachment = row.attachment;
  if (row.type === "attachment" && attachment?.type === "queued_command" && attachment.commandMode === "task-notification"
    && typeof attachment.prompt === "string") {
    return { ...base, type: "user", message: { role: "user", content: attachment.prompt }, origin: { kind: "task-notification" } };
  }
  return null;
}

async function regularFile(path) {
  try { return (await lstat(path)).isFile(); } catch { return false; }
}

async function smallJson(path) {
  try {
    const info = await lstat(path);
    if (!info.isFile() || info.size > 64 * 1024) return null;
    return JSON.parse(await readFile(path, "utf8"));
  } catch { return null; }
}

// The first timestamp and whether the agent's last message ended its turn.
async function transcriptEnds(path) {
  const result = { startedAt: null, finished: false };
  let handle;
  try {
    const info = await lstat(path);
    if (!info.isFile()) return result;
    handle = await open(path, "r");
    const head = Buffer.alloc(Math.min(info.size, 16 * 1024));
    await handle.read(head, 0, head.length, 0);
    result.startedAt = head.toString("utf8").match(/"timestamp":"([^"]{10,40})"/)?.[1] ?? null;
    const length = Math.min(info.size, 64 * 1024);
    const tail = Buffer.alloc(length);
    await handle.read(tail, 0, length, info.size - length);
    const lines = tail.toString("utf8").split("\n").filter(Boolean).reverse();
    for (const line of lines) {
      let row;
      try { row = JSON.parse(line); } catch { continue; }
      if (row.type === "assistant") { result.finished = row.message?.stop_reason === "end_turn"; break; }
      if (row.type === "user") break;
    }
  } catch {} finally { await handle?.close(); }
  return result;
}
