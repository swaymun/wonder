import { open } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { z } from "zod";
import { BRIDGE_PROTOCOL, HAIKU_MODEL, TurnProjection, questionRequest, questionAnswer } from "./projection.mjs";
import { baseOptions, inspectSdk, isSubscription } from "./sdk-runtime.mjs";
import { ToolPolicy, closeCommandSandbox } from "./permissions.mjs";

const BUILTINS = ["Read", "Write", "Edit", "NotebookEdit", "Bash", "WebFetch", "WebSearch",
  "AskUserQuestion", "Agent", "TodoWrite", "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop"];

function page(data, params) {
  const fingerprint = createHash("sha256").update(JSON.stringify(data)).digest("hex").slice(0, 16);
  const [expected, offsetText] = String(params.cursor ?? `${fingerprint}:0`).split(":");
  const offset = Number(offsetText);
  if (expected !== fingerprint || !Number.isSafeInteger(offset) || offset < 0 || offset > data.length) throw new Error("Claude history changed. Refresh the conversation.");
  const limit = Number.isSafeInteger(params.limit) ? Math.max(1, Math.min(params.limit, 200)) : 50;
  return { data: data.slice(offset, offset + limit), nextCursor: offset + limit < data.length ? `${fingerprint}:${offset + limit}` : null };
}

export function selectedModel(value) {
  if (value === "claude:haiku" || value === HAIKU_MODEL) return HAIKU_MODEL;
  if (typeof value !== "string" || !/^claude:[a-zA-Z0-9._\[\]-]{1,100}$/.test(value)) throw new Error("Choose a Claude model for this Bot.");
  const model = value.slice("claude:".length);
  if (model === "default") throw new Error("Choose an explicit Claude model.");
  return model;
}

function sdkToolResult(result) {
  const content = (result?.contentItems ?? []).flatMap(block => {
    if (block.type === "inputText") return [{ type: "text", text: block.text }];
    if (block.type === "inputImage") {
      const image = /^data:(image\/(?:png|jpeg|webp|gif));base64,([A-Za-z0-9+/=]+)$/.exec(block.imageUrl ?? "");
      if (image) return [{ type: "image", mimeType: image[1], data: image[2] }];
    }
    return [];
  });
  return { content: content.length ? content : [{ type: "text", text: "The action returned no displayable result." }], isError: result?.success !== true };
}

async function sdkInput(input, policy) {
  if (!Array.isArray(input) || !input.length) throw new Error("Claude requires a message.");
  const content = [];
  for (const block of input) {
    if (block.type === "text" && typeof block.text === "string") content.push({ type: "text", text: block.text });
    else if (block.type === "localImage") {
      if (!await policy.permits(block.path)) throw new Error("The attached image is outside this Bot's file access.");
      const file = await open(block.path, "r");
      let bytes;
      try {
        const stat = await file.stat();
        if (!stat.isFile() || stat.size > 20 * 1024 * 1024) throw new Error("The attached image is too large for Claude.");
        if (!await policy.permits(block.path)) throw new Error("The attached image's location changed.");
        bytes = Buffer.alloc(stat.size);
        let count = 0;
        while (count < bytes.length) {
          const { bytesRead } = await file.read(bytes, count, bytes.length - count, count);
          if (!bytesRead) throw new Error("The attached image changed while it was being read.");
          count += bytesRead;
        }
        if ((await file.stat()).size !== stat.size) throw new Error("The attached image changed while it was being read.");
      } finally { await file.close(); }
      // Wonder's authenticated attachment files use opaque IDs without an
      // extension. Match their bytes rather than trusting a filename suffix.
      const mime = bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])) ? "image/png"
        : bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255 ? "image/jpeg"
        : ["GIF87a", "GIF89a"].includes(bytes.subarray(0, 6).toString()) ? "image/gif"
        : bytes.subarray(0, 4).toString() === "RIFF" && bytes.subarray(8, 12).toString() === "WEBP" ? "image/webp" : null;
      if (!mime) throw new Error("This image format is not supported by Claude.");
      content.push({ type: "image", source: { type: "base64", media_type: mime, data: bytes.toString("base64") } });
    } else throw new Error("This attachment type is not supported by Claude. Dictation can send its transcript as text.");
  }
  return content;
}

export class ClaudeBridge {
  constructor({ updates, sessions, send, inspect = inspectSdk, onFatal = () => {} }) {
    Object.assign(this, { updates, sessions, send, inspect, onFatal });
    this.active = new Map(); this.pending = new Map(); this.inspection = null; this.inspectionAt = 0;
  }
  async catalog(refresh = false) {
    if (refresh || !this.inspection || Date.now() - this.inspectionAt > 60_000) {
      const lease = await this.updates.acquire();
      try { this.inspection = await this.inspect(lease.runtime, { includeUsage: true, connectors: true }); this.inspectionAt = Date.now(); }
      finally { await lease.release(); }
    }
    return this.inspection;
  }
  async receive(frame) {
    if (!frame || typeof frame !== "object") throw new Error("Invalid runtime frame");
    if (!frame.method && frame.id != null) {
      const pending = this.pending.get(frame.id);
      if (!pending) return;
      this.pending.delete(frame.id); pending.cleanup();
      if (frame.error) pending.reject(new Error("The action was cancelled in Wonder.")); else pending.resolve(frame.result);
      return;
    }
    if (frame.id == null) return;
    try { await this.send({ id: frame.id, result: await this.request(frame.method, frame.params ?? {}) }); }
    catch (error) { await this.send({ id: frame.id, error: { code: -32000, message: error.message } }); }
  }
  async request(method, params) {
    if (method === "initialize") return { userAgent: "Wonder Claude bridge", wonderBridge: { protocolVersion: BRIDGE_PROTOCOL, family: "claude" }, capabilities: { experimentalApi: true } };
    if (method === "account/read") {
      const catalog = await this.catalog(params.refresh);
      return { account: catalog.connected ? { type: "claudeSubscription", planType: catalog.subscription } : null, requiresOpenaiAuth: false,
        agentFamily: "claude", connected: catalog.connected, runtime: this.updates.status() };
    }
    if (method === "model/list") {
      const catalog = await this.catalog();
      return { data: catalog.models.filter(m => m.id !== "default").sort((a, b) => Number(b.id === "haiku") - Number(a.id === "haiku")).map(m => ({ id: `claude:${m.id}`, model: `claude:${m.id}`,
        displayName: m.id === "haiku" ? "Haiku 4.5" : m.name, description: m.description, hidden: false,
        agentFamily: "claude", isDefault: m.id === "haiku", supportedReasoningEfforts: (m.efforts ?? []).map(effort => ({ reasoningEffort: effort, description: `${effort[0].toUpperCase()}${effort.slice(1)}` })), defaultReasoningEffort: null })), nextCursor: null };
    }
    if (method === "account/rateLimits/read") {
      const catalog = await this.catalog(true);
      if (!catalog.windows) throw new Error("Claude usage is temporarily unavailable. Refresh to try again.");
      return { agentFamily: "claude", windows: catalog.windows };
    }
    if (["app/installed", "app/read", "mcpServerStatus/list"].includes(method)) {
      const session = params.threadId ? this.sessions.get(params.threadId) : null;
      const running = session && this.active.get(session.id);
      const servers = running?.query ? await running.query.mcpServerStatus() : (await this.catalog(params.forceRefetch || params.forceRefresh)).servers;
      const visible = servers.filter(s => s.source !== "sdk" && s.name !== "wonder");
      if (method === "mcpServerStatus/list") return { data: visible, nextCursor: null };
      return { apps: visible.map(s => ({ id: `claude:${s.name}`, runtimeName: s.name, name: s.name,
        installUrl: "https://claude.ai/settings/connectors", enabled: s.status !== "disabled", callable: s.status === "connected", isEnabled: s.status !== "disabled", isAccessible: s.status === "connected" })), nextCursor: null };
    }
    if (method === "thread/start") {
      selectedModel(params.model);
      const policy = new ToolPolicy({ ...params.wonderPolicy, cwd: params.cwd, tools: params.dynamicTools?.map(t => t.name) ?? [] });
      if (!await policy.permits(params.cwd)) throw new Error("Claude's workspace is outside the allowed scope.");
      const session = await this.sessions.create(params);
      await this.send({ method: "thread/started", params: { thread: this.sessions.describe(session), agentFamily: "claude" } });
      return { thread: this.sessions.describe(session), model: params.model };
    }
    if (method === "thread/list") return page([...this.sessions.values.values()].filter(s => !params.sourceKinds || s.parent).map(s => this.sessions.describe(s)), params);
    const session = this.sessions.get(params.threadId);
    if (method === "thread/read") return { thread: this.sessions.describe(session, params.includeTurns === true) };
    if (method === "thread/turns/list") return page([...session.turns].reverse().map(t => params.itemsView === "notLoaded" ? { ...t, items: [] } : t), params);
    if (method === "thread/items/list") {
      const turns = params.turnId ? session.turns.filter(t => t.id === params.turnId) : [...session.turns].reverse();
      return page(turns.flatMap(t => t.items.map(item => ({ turnId: t.id, item }))), params);
    }
    if (["thread/resume", "thread/settings/update"].includes(method)) {
      if (this.active.has(session.id)) {
        if (method === "thread/resume") return { thread: this.sessions.describe(session, params.excludeTurns !== true), model: session.options.model };
        throw new Error("Wait for Claude to finish before changing this conversation.");
      }
      if (params.model) selectedModel(params.model);
      const next = { ...session.options, ...params };
      new ToolPolicy({ ...next.wonderPolicy, cwd: next.cwd });
      session.options = next; await this.sessions.save(session);
      return { thread: this.sessions.describe(session, true), model: next.model };
    }
    if (method === "turn/start") {
      const options = { ...session.options, ...params };
      selectedModel(options.model);
      const policy = new ToolPolicy({ ...options.wonderPolicy, cwd: options.cwd,
        internal: options.wonderInternal === true, structuredOutput: Boolean(options.outputSchema), tools: options.dynamicTools?.map(t => t.name) ?? [] });
      const content = await sdkInput(params.input, policy);
      const { turn, duplicate } = await this.sessions.accept(session, params);
      if (!duplicate) {
        const run = { turn, abort: new AbortController(), query: null, children: new Map(), stopped: false, authorizedTools: new Map(), toolResults: new Map() };
        this.active.set(session.id, run);
        // Return the durable receipt before the SDK can produce an event.
        run.finished = new Promise((resolve, reject) => setImmediate(() => {
          this.execute(session, run, options, policy, content).then(resolve, reject);
        }));
        run.finished.catch(() => this.onFatal());
      }
      return { turn };
    }
    if (method === "turn/interrupt") {
      const run = this.active.get(session.id);
      if (run && run.turn.id === params.turnId) { run.stopped = true; run.abort.abort(); run.query?.close(); }
      return {};
    }
    // No silent no-ops for features that the SDK cannot faithfully provide.
    throw new Error("This action is not available for Claude yet.");
  }
  serverCall(method, params, signal) {
    if (signal?.aborted) return Promise.reject(new Error("Claude action cancelled."));
    const id = `claude-request-${randomUUID()}`;
    return new Promise((resolve, reject) => {
      const abort = () => { this.pending.delete(id); cleanup(); reject(new Error("Claude action cancelled.")); };
      const cleanup = () => signal?.removeEventListener("abort", abort);
      signal?.addEventListener("abort", abort, { once: true });
      this.pending.set(id, { resolve, reject, cleanup });
      Promise.resolve(this.send({ id, method, params })).catch(error => { this.pending.delete(id); cleanup(); reject(error); });
    });
  }
  async permission(session, run, policy, name, input, context) {
    const base = { threadId: session.id, turnId: run.turn.id, itemId: context.toolUseID, agentFamily: "claude" };
    const deny = message => ({ behavior: "deny", message });
    if (await policy.decision(name, input) === "deny") return deny("This action is outside this Bot's allowed access.");
    if (name === "AskUserQuestion") {
      const request = questionRequest(input, context.requestId ?? context.toolUseID);
      const answer = await this.serverCall("item/tool/requestUserInput", { ...base, ...request }, context.signal ?? run.abort.signal);
      return { behavior: "allow", updatedInput: questionAnswer(input, request, answer) };
    }
    if (name.startsWith("mcp__wonder__") && policy.tools.has(name.slice(13))) {
      if (context.mcpServer?.source !== "sdk" || context.mcpServer?.name !== "wonder") return deny("The tool's Wonder origin could not be verified.");
      const key = JSON.stringify([name.slice(13), input]);
      const calls = run.authorizedTools.get(key) ?? [];
      if (!calls.includes(context.toolUseID)) calls.push(context.toolUseID);
      run.authorizedTools.set(key, calls);
      return { behavior: "allow", updatedInput: input }; // The daemon owns these tools' approval and scope checks.
    }
    const decision = await policy.decision(name, input);
    const allow = async () => ({ behavior: "allow", updatedInput: name === "Bash" ? await policy.commandInput(input) : input });
    if (decision === "allow" || (name.startsWith("mcp__") && policy.approvalMode === "full_access")) return allow();
    const response = await this.serverCall("item/commandExecution/requestApproval", { ...base,
      command: name === "Bash" ? String(input.command ?? "") : `${name}: ${JSON.stringify(input)}`,
      cwd: policy.cwd, reason: context.title ?? "Allow Claude to perform this action?",
      availableDecisions: ["accept", "decline", "cancel"] }, context.signal ?? run.abort.signal);
    return response?.decision === "accept" ? allow() : deny("The owner declined this action.");
  }
  async execute(session, run, options, policy, content) {
    let lease, query;
    const done = Promise.withResolvers(), submit = Promise.withResolvers();
    const output = [];
    const projection = new TurnProjection({ threadId: session.id, turnId: run.turn.id, internal: policy.internal,
      emit: event => output.push(event), onSession: id => { session.sdkSessionId = id; session.sdkStarted = true; },
      onChild: message => run.childMessages.push(message) });
    run.childMessages = [];
    const flush = async (terminal = false) => {
      while (output.length && (terminal || output[0].method !== "turn/completed")) await this.send(output.shift());
    };
    try {
      projection.start(); await flush();
      lease = await this.updates.acquire();
      const { sdk } = lease.runtime;
      const tools = (options.wonderPlanning ? [] : options.dynamicTools ?? []).map(spec => sdk.tool(spec.name, spec.description,
        z.fromJSONSchema(spec.inputSchema).shape, async (input) => {
          const callId = run.authorizedTools.get(JSON.stringify([spec.name, input]))?.shift();
          if (!callId) throw new Error("The Wonder tool call could not be correlated with its permission check.");
          if (!run.toolResults.has(callId)) run.toolResults.set(callId, this.serverCall("item/tool/call", { threadId: session.id, turnId: run.turn.id,
            callId, tool: spec.name, arguments: input, agentFamily: "claude" }, run.abort.signal));
          const result = await run.toolResults.get(callId);
          const response = sdkToolResult(result);
          if (policy.internal && spec.name === "wonder_ask_question" && result?.success === true) {
            const posted = response.content.some(c => { try { return JSON.parse(c.text).posted === true; } catch { return false; } });
            if (posted) run.initialized = true;
          }
          return response;
        }));
      const model = selectedModel(options.model);
      const sdkOptions = { ...baseOptions(lease.runtime), cwd: options.cwd, model, abortController: run.abort,
        systemPrompt: [options.developerInstructions ?? "You are a helpful Wonder Bot.", ...Object.values(options.additionalContext ?? {}).filter(v => v?.kind === "application" && typeof v.value === "string").map(v => v.value)].join("\n\n"),
        tools: policy.internal || options.wonderPlanning ? [] : BUILTINS,
        mcpServers: tools.length ? { wonder: sdk.createSdkMcpServer({ name: "wonder", version: "1.0.0", tools }) } : {},
        canUseTool: (name, input, context) => this.permission(session, run, policy, name, input, context),
        hooks: { PreToolUse: [{ hooks: [(input) => policy.beforeTool(input)] }],
          PostToolUse: [{ hooks: [async () => run.initialized ? { continue: false, stopReason: "The optional question was posted. Initialization is complete." } : {}] }] },
        permissionMode: "default", sandbox: policy.sandbox(), includePartialMessages: true,
        persistSession: true, verbatimPrompts: true, maxTurns: 64,
        settings: { ...baseOptions(lease.runtime).settings, availableModels: [model], enforceAvailableModels: true,
          disableClaudeAiConnectors: options.wonderConnectors !== true || options.wonderPlanning === true },
        ...(model === HAIKU_MODEL ? { thinking: { type: "disabled" } } : options.effort ? { effort: options.effort } : {}),
        ...(options.outputSchema ? { outputFormat: { type: "json_schema", schema: options.outputSchema } } : {}),
        ...(session.sdkStarted ? { resume: session.sdkSessionId } : { sessionId: session.sdkSessionId }) };
      // A killed process can have persisted an SDK transcript before our init
      // event was saved. Query the exact owned UUID before deciding to resume.
      if (!session.sdkStarted && typeof sdk.getSessionInfo === "function") {
        if (await sdk.getSessionInfo(session.sdkSessionId, { dir: options.cwd })) {
          delete sdkOptions.sessionId; sdkOptions.resume = session.sdkSessionId; session.sdkStarted = true;
        }
      }
      query = sdk.query({ prompt: (async function* () {
        await submit.promise;
        if (!run.abort.signal.aborted) yield { type: "user", session_id: session.sdkSessionId, parent_tool_use_id: null,
          message: { role: "user", content } };
        await done.promise;
      })(), options: sdkOptions });
      run.query = query;
      await query.initializationResult();
      if (!isSubscription(await query.accountInfo())) throw new Error("Sign in to a Claude subscription on your Mac before using this Bot.");
      submit.resolve();
      for await (const message of query) {
        projection.accept(message);
        if (message.type === "system" && message.subtype === "init") await this.sessions.save(session);
        while (run.childMessages.length) await this.child(session, run, run.childMessages.shift());
        await flush();
        // Complete internal setup deterministically; the SDK must not manufacture
        // a follow-up user request merely to elicit a visible greeting.
        if (run.initialized && message.type === "user" && message.message?.content?.some(b => b.type === "tool_result")) {
          projection.finish("completed"); await flush(); break;
        }
        if (projection.terminal) break;
      }
      if (!projection.terminal) projection.finish(run.initialized ? "completed" : run.stopped ? "interrupted" : "failed", run.initialized ? undefined : "Claude stopped before returning a complete response.");
    } catch (error) {
      projection.finish(run.initialized ? "completed" : run.stopped ? "interrupted" : "failed", run.initialized ? undefined : error.message);
    } finally {
      submit.resolve(); done.resolve(); query?.close(); run.abort.abort();
      for (const child of run.children.values()) {
        if (!child.projection.terminal) child.projection.finish(run.stopped ? "interrupted" : "failed", "The parent response ended before this task confirmed completion.");
        await child.flush();
      }
      projection.result.items = [...run.turn.items.filter(i => i.type === "userMessage"), ...projection.result.items];
      Object.assign(run.turn, projection.result);
      await this.sessions.save(session);
      await flush(true); this.active.delete(session.id);
      await lease?.release();
    }
  }
  async child(parent, run, message) {
    const toolId = message.parent_tool_use_id ?? message.tool_use_id;
    if (!toolId || message.ambient || message.skip_transcript) return;
    if (message.subtype === "task_started" && message.task_type !== "local_agent") return;
    let child = run.children.get(toolId);
    if (!child) {
      const depth = message.spawn_depth ?? 1;
      if (depth < 1 || depth > 16) return;
      const session = await this.sessions.create(parent.options, { threadId: parent.id, depth,
        name: String(message.description ?? "Helper").slice(0, 100), role: message.subagent_type ?? "Helper" });
      const turn = { id: randomUUID(), status: "inProgress", items: [] }; session.turns.push(turn);
      const output = [];
      const projection = new TurnProjection({ threadId: session.id, turnId: turn.id, emit: event => output.push(event) });
      child = { session, turn, projection, flush: async () => {
        const terminal = output.findLast(e => e.method === "turn/completed")?.params.turn;
        if (terminal) { Object.assign(turn, terminal); await this.sessions.save(session); }
        while (output.length) await this.send(output.shift());
      } };
      run.children.set(toolId, child);
      await this.sessions.save(session);
      await this.send({ method: "thread/started", params: { thread: this.sessions.describe(session), agentFamily: "claude" } });
      projection.start();
    }
    if (message.parent_tool_use_id) child.projection.accept({ ...message, parent_tool_use_id: null });
    if (message.subtype === "task_notification") child.projection.finish(message.status === "completed" ? "completed" : message.status === "stopped" ? "interrupted" : "failed");
    await child.flush();
  }
  async close() {
    for (const run of this.active.values()) { run.stopped = true; run.abort.abort(); run.query?.close(); }
    await Promise.allSettled([...this.active.values()].map(run => run.finished));
    for (const pending of this.pending.values()) { pending.cleanup(); pending.reject(new Error("Wonder closed the Claude runtime.")); }
    this.pending.clear();
    await closeCommandSandbox();
  }
}
