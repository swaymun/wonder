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
  constructor({ threadId, turnId, emit, onSession = () => {}, onUsage = () => {}, onChild = () => {}, internal = false }) {
    Object.assign(this, { threadId, turnId, emit, onSession, onUsage, onChild, internal });
    this.items = new Map(); this.textByMessage = new Map(); this.blocks = new Map();
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
    if (message.parent_tool_use_id) { this.onChild(message); return; }
    if (message.type === "system" && ["task_started", "task_progress", "task_notification"].includes(message.subtype)) { this.onChild(message); return; }
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
      for (const block of message.message.content) if (block.type === "tool_result") this.toolResult(block);
    }
    if (message.type === "result") {
      this.structuredOutput = message.structured_output;
      const success = message.subtype === "success" && !message.is_error;
      this.finish(success ? "completed" : "failed", success ? undefined : (message.errors?.[0] ?? "Claude could not complete this response."));
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
    const wonder = block.name?.startsWith("mcp__wonder__") ? block.name.slice("mcp__wonder__".length) : null;
    this.startItem(wonder
      ? { type: "dynamicToolCall", id: block.id, tool: wonder, arguments: block.input, status: "inProgress" }
      : { type: "mcpToolCall", id: block.id, server: "Claude", tool: block.name, arguments: block.input, status: "inProgress" });
  }
  toolResult(block) {
    const item = this.items.get(block.tool_use_id);
    if (!item || ["completed", "failed"].includes(item.status)) return;
    item.success = block.is_error !== true;
    item.contentItems = toolContent(block.content);
    item.result = { content: block.content ?? [] };
    if (!item.success) item.error = { message: item.contentItems.filter(c => c.type === "inputText").map(c => c.text).join("\n") || "Tool failed" };
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
