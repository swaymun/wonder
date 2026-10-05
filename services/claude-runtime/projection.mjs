// Claude's wire messages stop here. The daemon owns durable delivery and presentation.
export const BRIDGE_PROTOCOL = 1;
export const HAIKU_MODEL = "claude-haiku-4-5-20251001";

export function toolContent(content) {
  if (typeof content === "string") return [{ type: "inputText", text: content }];
  if (!Array.isArray(content)) return [];
  return content.flatMap(block => {
    if (block.type === "text") return [{ type: "inputText", text: String(block.text ?? "") }];
    if (block.type === "image" && block.source?.type === "base64") {
      return [{ type: "inputImage", imageUrl: `data:${block.source.media_type};base64,${block.source.data}` }];
    }
    if (block.type === "image" && typeof block.data === "string") {
      return [{ type: "inputImage", imageUrl: `data:${block.mimeType};base64,${block.data}` }];
    }
    if (["resource", "resource_link"].includes(block.type)) return [block];
    return [];
  });
}

export function questionRequest(input, requestId) {
  if (!Array.isArray(input?.questions) || input.questions.length < 1 || input.questions.length > 4) throw new Error("Invalid Claude question count");
  const seen = new Set();
  const questions = input.questions.map((q, i) => {
    if (typeof q.question !== "string" || !q.question.trim() || q.question.length > 4000 || seen.has(q.question)) throw new Error("Invalid or duplicate Claude question");
    seen.add(q.question);
    if (!Array.isArray(q.options) || q.options.length < 2 || q.options.length > 4) throw new Error("Invalid Claude question options");
    const labels = new Set();
    const options = q.options.map(o => {
      if (typeof o.label !== "string" || !o.label.trim() || o.label.length > 500 || labels.has(o.label)) throw new Error("Invalid or duplicate Claude option");
      labels.add(o.label);
      return { label: o.label, description: typeof o.description === "string" ? o.description.slice(0, 4000) : null };
    });
    return { id: `${requestId}:${i}`, header: typeof q.header === "string" ? q.header.slice(0, 80) : null,
      question: q.question, options, multiSelect: q.multiSelect === true, isOther: true, isSecret: false };
  });
  return { kind: "question", agentFamily: "claude", questions, isBlocking: true };
}

export function questionAnswer(original, normalized, response) {
  const keys = Object.keys(response?.answers ?? {});
  if (keys.length !== normalized.questions.length || keys.some(k => !normalized.questions.some(q => q.id === k))) throw new Error("Answer does not match the pending question");
  const answers = {};
  for (const q of normalized.questions) {
    const values = response.answers[q.id]?.answers;
    if (!Array.isArray(values) || !values.length || values.length > 8 || (!q.multiSelect && values.length !== 1)
      || values.some(v => typeof v !== "string" || !v.trim() || v.length > 8000) || new Set(values).size !== values.length) throw new Error("Invalid question answer");
    // Current SDK accepts the documented array form; retain commas inside labels.
    answers[q.question] = q.multiSelect ? values : values[0];
  }
  return { ...original, answers };
}

// ExitPlanMode carries the proposed plan as markdown. The conversation shows it
// as a plan item shaped like Codex's ({ type, id, text }); a call without plan
// text has nothing to show and produces no row.
// Claude Code's shell and file tools use the same rows as Codex: a command
// with its output, or a file change with its patch.
const lines = text => String(text ?? "").replace(/\n$/, "").split("\n");
const hunk = (before, after) => ["@@ @@", ...(before === "" ? [] : lines(before).map(l => `-${l}`)),
  ...(after === "" ? [] : lines(after).map(l => `+${l}`))].join("\n");
export function claudeToolItem(block, status) {
  const input = block?.input ?? {};
  if (block?.name === "Bash" && typeof input.command === "string" && input.command.trim()) {
    return { type: "commandExecution", id: block.id, command: input.command, status };
  }
  const path = typeof input.file_path === "string" && input.file_path ? input.file_path : null;
  if (!path) return null;
  if (block.name === "Write" && typeof input.content === "string") {
    return { type: "fileChange", id: block.id, status, changes: [{ path, kind: { type: "add" }, diff: input.content }] };
  }
  if (block.name === "Edit" && typeof input.old_string === "string" && typeof input.new_string === "string") {
    return { type: "fileChange", id: block.id, status, changes: [{ path, kind: { type: "update" }, diff: hunk(input.old_string, input.new_string) }] };
  }
  if (block.name === "MultiEdit" && Array.isArray(input.edits)) {
    const edits = input.edits.filter(e => typeof e?.old_string === "string" && typeof e?.new_string === "string");
    if (edits.length) return { type: "fileChange", id: block.id, status,
      changes: [{ path, kind: { type: "update" }, diff: edits.map(e => hunk(e.old_string, e.new_string)).join("\n") }] };
  }
  return null;
}
// Apply a tool result to a projected item, in place.
export function applyClaudeToolResult(item, block) {
  item.success = block.is_error !== true;
  const contentItems = toolContent(block.content);
  const text = contentItems.filter(c => c.type === "inputText").map(c => c.text).join("\n");
  if (item.type === "commandExecution") {
    item.aggregatedOutput = text;
    item.status = item.success ? "completed" : "failed";
    return;
  }
  if (item.type === "fileChange") {
    item.status = item.success ? "completed" : "failed";
    if (!item.success) item.error = { message: text || "Edit failed" };
    return;
  }
  item.contentItems = contentItems;
  item.result = { content: block.content ?? [] };
  item.status = item.success ? "completed" : "failed";
  if (!item.success) item.error = { message: text || "Tool failed" };
}

// Text written between tool calls is progress, like Codex commentary; only
// text after the turn's last tool call is the reply. Returns changed items.
export function markCommentary(items) {
  const changed = [];
  let workAfter = false;
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const item = items[index];
    if (item.type === "agentMessage") {
      if (workAfter && item.phase !== "commentary") { item.phase = "commentary"; changed.push(item); }
    } else if (!["userMessage", "plan"].includes(item.type)) workAfter = true;
  }
  return changed;
}

export function planItem(block, status) {
  const text = typeof block?.input?.plan === "string" ? block.input.plan : "";
  return text.trim() ? { type: "plan", id: block.id, text, status } : null;
}

export function usageWindow(type, source, timestamp = Date.now()) {
  const definitions = { five_hour: ["5-hour limit", 300], seven_day: ["Weekly limit", 10080],
    seven_day_sonnet: ["Weekly · Sonnet", 10080], seven_day_opus: ["Weekly · Opus", 10080] };
  const definition = definitions[type];
  if (!definition || !source || typeof source.utilization !== "number" || !Number.isFinite(source.utilization)) return null;
  // SDK event utilization is a fraction; the account endpoint uses a percentage.
  const usedPercent = Math.max(0, Math.min(100, source.utilization * (source.format === "percent" ? 1 : 100)));
  const reset = typeof source.resetsAt === "number" ? source.resetsAt : Date.parse(source.resets_at) / 1000;
  return { id: type, label: definition[0], usedPercent, remainingPercent: 100 - usedPercent,
    windowDurationMins: definition[1], ...(Number.isFinite(reset) && reset > 0 ? { resetsAt: Math.floor(reset) } : {}), checkedAtMs: timestamp };
}

export class TurnProjection {
  constructor({ threadId, turnId, emit, onSession = () => {}, onUsage = () => {}, onChild = () => {}, internal = false, promptUuid = null }) {
    Object.assign(this, { threadId, turnId, emit, onSession, onUsage, onChild, internal, promptUuid });
    this.items = new Map(); this.textByMessage = new Map(); this.blocks = new Map(); this.agentTools = new Map();
    this.messageId = null; this.terminal = false; this.completedTexts = new Set();
  }
  notify(method, params = {}, threadId = this.threadId, turnId = this.turnId) {
    this.emit({ method, params: { threadId, turnId, ...params, agentFamily: "claude" } });
  }
  start() { this.notify("turn/started", { turn: { id: this.turnId, status: "inProgress", items: [] } }); }
  startItem(item) {
    if (this.items.has(item.id)) return this.items.get(item.id);
    this.items.set(item.id, item);
    this.notify("item/started", { item: { ...item } });
    return item;
  }
  finishItem(item) {
    if (item.status === "completed" || item.status === "failed") return;
    item.status = item.success === false ? "failed" : "completed";
    this.notify("item/completed", { item: { ...item } });
  }
  accept(message) {
    if (this.terminal) return;
    if (message.type === "system" && message.subtype === "init") this.onSession(message.session_id);
    if (message.type === "rate_limit_event") {
      const window = usageWindow(message.rate_limit_info?.rateLimitType, message.rate_limit_info);
      if (window) this.onUsage(window);
      return;
    }
    if (message.parent_tool_use_id) { if (!this.internal) this.onChild(message); return; }
    if (message.type === "system" && ["task_started", "task_progress", "task_notification"].includes(message.subtype)) {
      if (!this.internal) this.onChild(message);
      return;
    }
    if (message.type === "stream_event") this.stream(message.event);
    if (message.type === "assistant") {
      const id = message.message?.id;
      for (const block of message.message?.content ?? []) {
        if (block.type === "text" && !this.internal) this.completeText(id, block.text);
        if (block.type === "tool_use") this.startTool(block);
      }
    }
    if (message.type === "user" && Array.isArray(message.message?.content)) {
      // Runtime synthetic user instructions are not messages written by the owner.
      for (const block of message.message.content) if (block.type === "tool_result") this.toolResult(block, message.tool_use_result);
    }
    if (message.type === "result") {
      // A resumed session can first finish work queued before this prompt
      // (for example a background-task notice). Only the result that answers
      // this prompt ends the turn.
      const answered = [message.user_message_uuid, ...(message.user_message_uuids ?? [])].filter(Boolean);
      if (this.promptUuid && answered.length && !answered.includes(this.promptUuid)) return;
      this.structuredOutput = message.structured_output;
      const success = message.subtype === "success" && !message.is_error;
      this.finish(success ? "completed" : "failed", success ? undefined : (message.errors?.[0] ?? message.result ?? "Claude could not complete this response."));
    }
  }
  stream(event) {
    if (!event) return;
    if (event.type === "message_start") { this.messageId = event.message?.id; this.blocks.clear(); }
    if (event.type === "content_block_start") {
      if (event.content_block?.type === "text" && !this.internal) {
        const id = `${this.turnId}:${this.messageId}:${event.index}`;
        const item = this.startItem({ type: "agentMessage", id, text: event.content_block.text ?? "", status: "inProgress" });
        this.blocks.set(event.index, item);
        const texts = this.textByMessage.get(this.messageId) ?? [];
        texts.push(item); this.textByMessage.set(this.messageId, texts);
      }
    }
    if (event.type === "content_block_delta" && event.delta?.type === "text_delta" && !this.internal) {
      const item = this.blocks.get(event.index);
      if (!item || typeof event.delta.text !== "string") return;
      item.text += event.delta.text;
      this.notify("item/agentMessage/delta", { itemId: item.id, delta: event.delta.text });
    }
  }
  completeText(messageId, text) {
    if (typeof text !== "string") return;
    const key = `${messageId}\0${text}`;
    if (this.completedTexts.has(key)) return;
    this.completedTexts.add(key);
    let item = (this.textByMessage.get(messageId) ?? []).find(i => i.status === "inProgress" && (i.text === text || text.startsWith(i.text)));
    if (!item) item = this.startItem({ type: "agentMessage", id: `${this.turnId}:${messageId}:text:${this.completedTexts.size}`, text: "", status: "inProgress" });
    item.text = text; this.finishItem(item);
  }
  startTool(block) {
    if (["Agent", "Task"].includes(block.name)) {
      // The verified task lifecycle supplies the existing agent activity row.
      // Launch acknowledgements contain internal IDs/paths, not a user reply.
      this.agentTools.set(block.id, block);
      return;
    }
    if (block.name === "ExitPlanMode") {
      // The owner reads the plan in the conversation; the tool result is not a row.
      const plan = planItem(block, "inProgress");
      if (plan) this.finishItem(this.startItem(plan));
      return;
    }
    // Text before this tool call was progress; restate it as commentary.
    for (const item of markCommentary([...this.items.values(), { type: "tool" }])) {
      if (item.status === "completed") this.notify("item/completed", { item: { ...item } });
    }
    const wonder = block.name?.startsWith("mcp__wonder__") ? block.name.slice("mcp__wonder__".length) : null;
    const native = block.name?.startsWith("mcp__cua_repl__") ? block.name.slice("mcp__cua_repl__".length) : null;
    this.startItem(wonder
      ? { type: "dynamicToolCall", id: block.id, tool: wonder, arguments: block.input, status: "inProgress" }
      : (!native && claudeToolItem(block, "inProgress"))
        || { type: "mcpToolCall", id: block.id, server: native ? "cua_repl" : "Claude", tool: native ?? block.name, arguments: block.input, status: "inProgress" });
  }
  toolResult(block, result) {
    if (this.agentTools.has(block.tool_use_id)) {
      if (!this.internal) this.onChild({ type: "agent_result", tool_use_id: block.tool_use_id, result, is_error: block.is_error, content: block.content });
      return;
    }
    const item = this.items.get(block.tool_use_id);
    if (!item || ["completed", "failed"].includes(item.status)) return;
    applyClaudeToolResult(item, block);
    item.status = "inProgress"; // finishItem publishes the terminal state.
    this.finishItem(item);
  }
  finish(status, error) {
    if (this.terminal) return;
    this.terminal = true;
    for (const item of this.items.values()) {
      if (item.type === "agentMessage") this.finishItem(item);
      else if (item.status === "inProgress") { item.success = false; item.error = { message: "Action did not return a confirmed result." }; this.finishItem(item); }
    }
    this.result = { id: this.turnId, status, ...(this.structuredOutput === undefined ? {} : { structuredOutput: this.structuredOutput }), items: [...this.items.values()], error: error ? { message: String(error).slice(0, 2000) } : null };
    this.notify("turn/completed", { turn: this.result });
  }
}
