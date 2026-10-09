// Native Claude Code transcripts are authoritative for project conversations.
// Project SDK session messages into the same turn/item shapes as the live
// stream so Wonder reconciles both by stable IDs instead of duplicating them.
import { readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { applyClaudeToolResult, claudeToolItem, markCommentary, planItem, toolContent } from "./projection.mjs";

const textOf = content => typeof content === "string" ? content
  : Array.isArray(content) ? content.filter(b => b?.type === "text").map(b => b.text ?? "").join("\n") : "";
const tag = (text, name) => text.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))?.[1]?.trim() || null;
const bounded = (value, limit) => typeof value === "string" && value.trim() ? value.trim().slice(0, limit) : null;

// Claude Code delivers background-task completions as queued "user" messages.
// They are runtime events, not words written by the owner.
export function taskNotification(entry) {
  if (entry?.type !== "user") return null;
  const text = textOf(entry.message?.content);
  if (entry.origin?.kind !== "task-notification" && !text.trimStart().startsWith("<task-notification>")) return null;
  const body = tag(text, "task-notification") ?? text;
  return { taskId: tag(body, "task-id"), toolUseId: tag(body, "tool-use-id"), status: tag(body, "status"),
    summary: tag(body, "summary"), outputFile: tag(body, "output-file") };
}
const syntheticUser = entry => Boolean(entry?.origin?.kind && entry.origin.kind !== "human") || taskNotification(entry) !== null;
// Claude Code's desktop app appends each paste to the prompt wrapped as
// `<pasted_content id="x">...</pasted_content id="x">` (the closing tag repeats
// the id). The tags are transport markup; the owner sees the pasted words.
export const unwrapPastes = text => !text.includes("<pasted_content") ? text : text.replace(
  /<pasted_content id="([^"]*)">\n?([\s\S]*?)\n?<\/pasted_content id="\1">/g, (_, _id, body) => body).trim();
const interruptMarker = text => /^\[Request interrupted by user/.test(text.trim());
// A `!` shell command or slash command run in Claude Code is one user entry
// (`<bash-input>` or `<command-name>`) and its output a second one
// (`<bash-stdout>`, `<local-command-stdout>`, ...). The output belongs to the
// command's turn; the phone renders the joined markup as one command card.
const commandOutput = text => /^<(bash-stdout|bash-stderr|local-command-stdout|local-command-stderr)>/.test(text.trimStart());

// The prompt that opens a turn: a human message, not a tool result, background
// notice or interruption marker. `nativeTurns` splits history at the same entries.
const opensTurn = entry => {
  if (entry?.type !== "user" || entry.parent_tool_use_id) return false;
  const content = entry.message?.content;
  if (Array.isArray(content) && content.some(b => b?.type === "tool_result")) return false;
  const text = unwrapPastes(textOf(content));
  return Boolean(text.trim()) && !syntheticUser(entry) && !interruptMarker(text) && !commandOutput(text);
};

// The last transcript entry that belongs to the turn `turnId` (the uuid of the
// prompt that opened it), so a fork can end exactly where that turn ends.
export function turnEndMessageId(messages, turnId) {
  let found = false, last = null;
  for (const entry of messages) {
    if (opensTurn(entry)) { if (found) break; found = entry.uuid === turnId; }
    if (found && !entry.parent_tool_use_id && typeof entry.uuid === "string") last = entry.uuid;
  }
  return last;
}

// Wonder-originated turns reuse the owner's receipt from the bridge journal.
export function nativeTurns(messages, journal = [], active = false) {
  const turns = [], known = new Map(journal.map(turn => [turn.id, turn]));
  const blockIndex = new Map(), tools = new Map();
  let turn = null;
  for (const entry of messages) {
    const content = entry?.message?.content;
    if (entry?.parent_tool_use_id) continue; // Child-agent detail stays in its own activity.
    if (entry?.type === "user") {
      const results = Array.isArray(content) ? content.filter(b => b?.type === "tool_result") : [];
      for (const block of results) {
        const item = tools.get(block.tool_use_id);
        if (!item) continue;
        applyClaudeToolResult(item, block, entry.tool_use_result);
        if (item.type === "mcpToolCall") delete item.result;
      }
      const text = unwrapPastes(textOf(content));
      if (results.length || !text.trim() || syntheticUser(entry)) continue;
      if (interruptMarker(text)) { if (turn) turn.interrupted = true; continue; }
      const prompt = turn?.items[0];
      if (commandOutput(text) && prompt?.type === "userMessage" && prompt.content?.[0]?.type === "text") {
        prompt.content = [{ ...prompt.content[0], text: `${prompt.content[0].text}\n${text.trim()}` }];
        continue;
      }
      const receipt = known.get(entry.uuid);
      const user = receipt?.items?.find(i => i.type === "userMessage");
      turn = { id: entry.uuid, status: "completed", error: null, items: [user
        ? { ...user }
        : { type: "userMessage", id: entry.uuid, content: [{ type: "text", text }] }] };
      turns.push(turn);
      continue;
    }
    if (entry?.type !== "assistant" || !turn || !Array.isArray(content)) continue;
    const messageId = entry.message?.id ?? entry.uuid;
    for (const block of content) {
      const index = blockIndex.get(messageId) ?? 0;
      blockIndex.set(messageId, index + 1);
      if (block?.type === "text" && block.text) {
        turn.items.push({ type: "agentMessage", id: `${turn.id}:${messageId}:${index}`, text: block.text, status: "completed" });
      } else if (block?.type === "tool_use" && block.name === "ExitPlanMode") {
        // Same item ID as the live stream, so history and events reconcile.
        const plan = planItem(block, "completed");
        if (plan) turn.items.push(plan);
      } else if (block?.type === "tool_use" && !["Agent", "Task"].includes(block.name)) {
        const item = claudeToolItem(block, "completed")
          ?? { type: "mcpToolCall", id: block.id, server: "Claude", tool: block.name, arguments: block.input ?? {}, status: "completed" };
        tools.set(block.id, item);
        turn.items.push(item);
      }
    }
  }
  for (const t of turns) markCommentary(t.items);
  const last = turns.at(-1);
  for (const t of turns) if (t.interrupted) { t.status = "interrupted"; delete t.interrupted; }
  if (last && active) {
    last.status = "inProgress";
    // A call still waiting for its result is running, not done.
    for (const item of last.items) if (tools.get(item.id) === item && item.success === undefined) item.status = "inProgress";
  }
  // Preserve the durable outcome of Wonder's own turns (failed, interrupted).
  for (const t of turns) {
    const receipt = known.get(t.id);
    if (receipt && receipt.status !== "inProgress" && !(t === last && active)) { t.status = receipt.status; t.error = receipt.error ?? null; }
  }
  return turns;
}

export function sessionSummary(info) {
  const title = (info.customTitle || info.summary || info.firstPrompt || "Claude session").replace(/\s+/g, " ").trim().slice(0, 200);
  return { sessionId: info.sessionId, title, cwd: info.cwd ?? null,
    createdAt: Math.floor((info.createdAt ?? info.lastModified) / 1000), updatedAt: Math.floor(info.lastModified / 1000) };
}

const taskStatus = status => ({ completed: "completed", failed: "failed", error: "failed", killed: "interrupted",
  stopped: "interrupted", cancelled: "interrupted" })[String(status ?? "").toLowerCase()] ?? "running";

// Agent tasks and background commands, newest first, for the agent-task list.
// A task still marked running in a session that is no longer working on the
// Mac lost its completion notice; its state is unknown, not running.
export function backgroundTasks(messages, live = false, agentFiles = []) {
  const tasks = new Map();
  // Claude Code's task files outlive compaction; transcript entries refine them.
  for (const file of [...agentFiles].sort((a, b) => String(a.startedAt ?? "").localeCompare(String(b.startedAt ?? "")))) {
    tasks.set(file.toolUseId, { id: file.toolUseId, kind: "agent", background: file.background,
      title: bounded(file.description, 200) ?? "Agent task", role: bounded(file.agentType, 80),
      status: file.finished ? "completed" : "running", request: null, summary: null, result: null,
      outputFile: null, taskId: file.agentId, startedAt: file.startedAt ?? null });
  }
  for (const entry of messages) {
    if (entry?.parent_tool_use_id) continue;
    const content = entry?.message?.content;
    if (entry?.type === "assistant" && Array.isArray(content)) {
      for (const block of content) {
        if (block?.type !== "tool_use" || typeof block.id !== "string") continue;
        const agent = ["Agent", "Task"].includes(block.name);
        const known = tasks.get(block.id);
        const background = block.input?.run_in_background === true || known?.background === true;
        if (!agent && !background) continue;
        tasks.set(block.id, { ...known, id: block.id, kind: agent ? "agent" : "command", background,
          title: bounded(block.input?.description, 200) ?? known?.title
            ?? (agent ? "Agent task" : bounded(block.input?.command?.split?.("\n")[0], 80) ?? "Background command"),
          role: agent ? bounded(block.input?.subagent_type, 80) ?? known?.role ?? null : null, status: known?.status ?? "running",
          request: bounded(agent ? block.input?.prompt : block.input?.command, 8000),
          summary: null, result: null, outputFile: null, taskId: known?.taskId ?? null, startedAt: entry.timestamp ?? known?.startedAt ?? null });
      }
    }
    if (entry?.type !== "user") continue;
    for (const block of Array.isArray(content) ? content : []) {
      const task = block?.type === "tool_result" ? tasks.get(block.tool_use_id) : null;
      if (!task) continue;
      const text = bounded(toolContent(block.content).filter(c => c.type === "inputText").map(c => c.text).join("\n"), 32_000);
      // Claude Code may run an agent in the background without the explicit flag;
      // its immediate result only acknowledges the launch.
      if (task.kind === "agent" && /^Async agent launched/i.test(text ?? "")) {
        task.background = true;
        task.taskId ??= text.match(/\bagentId: ([A-Za-z0-9_-]{1,64})/)?.[1] ?? null;
        continue;
      }
      // A background command's launch names the task ID that stop_task needs.
      if (task.kind === "command" && task.background && block.is_error !== true)
        task.taskId ??= text?.match(/\bbackground with ID: ([A-Za-z0-9_-]{1,64})/)?.[1] ?? null;
      // A background launch only acknowledges the start; the notice carries its outcome.
      if (block.is_error === true) { task.status = "failed"; task.result = text; }
      else if (!task.background) { task.status = "completed"; task.result = text; }
    }
    const notice = taskNotification(entry);
    if (!notice?.toolUseId) continue;
    // A resumed agent (SendMessage) notifies again under the resuming call's
    // tool-use ID with the same task ID; it is the same task, not a new one.
    let task = tasks.get(notice.toolUseId)
      ?? (notice.taskId ? [...tasks.values()].find(t => t.taskId === notice.taskId) : undefined);
    if (!task) {
      // The launch scrolled out of the readable transcript; the notice still names the task.
      const agent = /^Agent "/.test(notice.summary ?? "");
      task = { id: notice.toolUseId, kind: agent ? "agent" : "command", background: true,
        title: bounded(notice.summary?.match(/"([^"]{1,200})"/)?.[1], 200) ?? "Background task", role: null,
        status: "running", request: null, summary: null, result: null, outputFile: null, taskId: null, startedAt: entry.timestamp ?? null };
      tasks.set(notice.toolUseId, task);
    }
    Object.assign(task, { status: taskStatus(notice.status), summary: bounded(notice.summary, 2000),
      outputFile: notice.outputFile, taskId: notice.taskId ?? task.taskId, updatedAt: entry.timestamp ?? task.updatedAt ?? null });
  }
  const list = [...tasks.values()]
    .map(task => ({ ...task, updatedAt: task.updatedAt ?? task.startedAt ?? null }))
    .map((task, order) => ({ task, order }))
    .sort((a, b) => String(b.task.startedAt ?? "").localeCompare(String(a.task.startedAt ?? "")) || b.order - a.order)
    .map(({ task }) => task).slice(0, 100);
  if (!live) for (const task of list) if (task.status === "running") task.status = "unknown";
  return list;
}

// Claude Code records each running interactive session (desktop or terminal)
// in ~/.claude/sessions/<pid>.json with a busy/idle status. Only these JSON
// records are read; key files beside them are never opened.
export async function claudeSessionBusy(sessionId, dir = join(homedir(), ".claude", "sessions")) {
  let names;
  try { names = await readdir(dir); } catch { return false; }
  for (const name of names.filter(n => /^[0-9]{1,10}\.json$/.test(n)).slice(0, 256)) {
    let record;
    try { record = JSON.parse(await readFile(join(dir, name), "utf8")); } catch { continue; }
    if (record?.sessionId !== sessionId || `${record.pid}.json` !== name || !Number.isSafeInteger(record.pid)) continue;
    if (record.entrypoint === "sdk-ts") continue; // An Agent SDK run, such as Wonder's own.
    try { process.kill(record.pid, 0); } catch (error) { if (error.code !== "EPERM") continue; }
    if (record.status === "busy") return true;
  }
  return false;
}
