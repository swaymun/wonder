import { mkdir, readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { writeJson } from "./runtime-updates.mjs";

const validId = id => typeof id === "string" && /^claude-[0-9a-f-]{36}$/.test(id);

// The daemon owns the visible transcript. This bounded private journal owns
// SDK session bindings and accepted-turn receipts for safe crash recovery.
export class Sessions {
  constructor(root) { this.root = root; this.values = new Map(); this.writes = new Map(); }
  async initialize() {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    for (const file of await readdir(this.root)) {
      if (!file.endsWith(".json") || !validId(file.slice(0, -5))) continue;
      const session = JSON.parse(await readFile(join(this.root, file), "utf8"));
      if (session.schemaVersion !== 1 || !validId(session.id) || !Array.isArray(session.turns)) throw new Error("Claude session storage is incompatible");
      this.values.set(session.id, session);
      session.receipts ??= {};
      let interrupted = false;
      for (const turn of session.turns) {
        if (turn.status === "inProgress") {
          turn.status = "interrupted";
          turn.error = { message: "Claude stopped before this response completed. Continue in the conversation." };
          interrupted = true;
        }
        if (turn.clientUserMessageId) session.receipts[turn.clientUserMessageId] = { id: turn.id, status: turn.status };
      }
      if (interrupted) await this.save(session);
    }
    return this;
  }
  get(id) {
    const session = this.values.get(id);
    if (!session) throw new Error("This Claude conversation is unavailable. Its saved messages are still in Wonder.");
    return session;
  }
  async create(options, parent = null) {
    const session = { schemaVersion: 1, id: `claude-${randomUUID()}`, sdkSessionId: randomUUID(),
      sdkStarted: false, createdAt: Math.floor(Date.now() / 1000), options, parent, turns: [], receipts: {} };
    await this.save(session);
    this.values.set(session.id, session);
    return session;
  }
  async save(session) {
    if (!validId(session.id)) throw new Error("Invalid Claude conversation ID");
    for (const turn of session.turns) if (turn.clientUserMessageId) session.receipts[turn.clientUserMessageId] = { id: turn.id, status: turn.status };
    const snapshot = structuredClone(session);
    const previous = this.writes.get(session.id) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(() => writeJson(join(this.root, `${session.id}.json`), snapshot));
    this.writes.set(session.id, next);
    try { await next; } finally { if (this.writes.get(session.id) === next) this.writes.delete(session.id); }
  }
  describe(session, includeTurns = false) {
    const active = session.turns.at(-1)?.status === "inProgress";
    return { id: session.id, sessionId: session.sdkSessionId, agentFamily: "claude", cwd: session.options.cwd,
      createdAt: session.createdAt, updatedAt: session.updatedAt ?? session.createdAt,
      status: { type: active ? "active" : "idle", activeFlags: [] },
      canAcceptDirectInput: !session.parent, modelProvider: "anthropic",
      ...(session.parent ? { parentThreadId: session.parent.threadId, source: { subAgent: { thread_spawn: {
        parent_thread_id: session.parent.threadId, depth: session.parent.depth,
        agent_nickname: session.parent.name, agent_role: session.parent.role } } } } : { source: "sdk" }),
      turns: includeTurns ? session.turns : [] };
  }
  async accept(session, params) {
    if (session.parent) throw new Error("Continue child-agent work in its parent conversation.");
    const previous = params.clientUserMessageId && session.turns.find(t => t.clientUserMessageId === params.clientUserMessageId);
    if (previous) return { turn: previous, duplicate: true };
    const receipt = params.clientUserMessageId && session.receipts[params.clientUserMessageId];
    if (receipt) return { turn: { ...receipt, items: [] }, duplicate: true };
    if (session.turns.some(t => t.status === "inProgress")) throw new Error("Claude is already working in this conversation.");
    const turn = { id: randomUUID(), clientUserMessageId: params.clientUserMessageId ?? null, status: "inProgress", items: [{
      type: "userMessage", id: randomUUID(), clientId: params.clientUserMessageId ?? null, content: params.input ?? [] }], error: null };
    session.turns.push(turn);
    // Older visible history is retained by Wonder's SQLite transcript.
    if (session.turns.length > 200) session.turns.splice(0, session.turns.length - 200);
    session.updatedAt = Math.floor(Date.now() / 1000);
    await this.save(session);
    return { turn, duplicate: false };
  }
}
