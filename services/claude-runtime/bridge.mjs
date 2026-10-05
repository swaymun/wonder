import { open } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { z } from "zod";
import { BRIDGE_PROTOCOL, HAIKU_MODEL, TurnProjection, questionRequest, questionAnswer } from "./projection.mjs";
import { baseOptions, inspectSdk, isSubscription } from "./sdk-runtime.mjs";
import { ToolPolicy, closeCommandSandbox, toolCallKey } from "./permissions.mjs";
import { createNativeCua } from "./native-cua.mjs";
import { backgroundTasks, claudeSessionBusy, nativeTurns, sessionSummary } from "./project-history.mjs";
import { lstat, realpath, stat } from "node:fs/promises";
import { basename, isAbsolute } from "node:path";

const BUILTINS = ["Read", "Write", "Edit", "NotebookEdit", "Bash", "WebFetch", "WebSearch",
  "AskUserQuestion", "Agent", "ToolSearch", "TodoWrite", "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop"];

// A project conversation is an owner's normal Claude Code session in one of
// their folders. It never receives Bot instructions, tools or connectors.
async function projectContext(value) {
  if (!value || typeof value !== "object") return null;
  const { cwd, additionalDirectories = [] } = value;
  if (!isAbsolute(cwd ?? "") || !Array.isArray(additionalDirectories) || additionalDirectories.length > 15
    || additionalDirectories.some(d => typeof d !== "string" || !isAbsolute(d) || d === cwd))
    throw new Error("The project folders are invalid. Edit the project in Wonder.");
  for (const dir of [cwd, ...additionalDirectories]) {
    const info = await stat(dir).catch(() => null);
    if (!info?.isDirectory()) throw new Error("A project folder is missing on this Mac. Edit the project in Wonder.");
  }
  return { cwd, additionalDirectories: [...new Set(additionalDirectories)] };
}

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

function modelDisplayName(model) {
  // Keep selection aliases stable, but label the model they resolve to today.
  // Haiku is intentionally pinned by selectedModel, regardless of its alias.
  const resolved = model.id === "haiku" ? HAIKU_MODEL : model.resolvedModel ?? model.id;
  const match = /^claude-([a-z]+)-(\d{1,2})(?:-(\d{1,2}))?(?:-\d{8})?(?:\[1m\])?$/.exec(resolved);
  if (!match) return model.name;
  const [, family, major, minor] = match;
  return `${family[0].toUpperCase()}${family.slice(1)} ${major}${minor ? `.${minor}` : ""}`;
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
  constructor({ updates, sessions, send, inspect = inspectSdk, onFatal = () => {}, claudeSessionsDir = undefined }) {
    Object.assign(this, { updates, sessions, send, inspect, onFatal, claudeSessionsDir });
    this.active = new Map(); this.pending = new Map(); this.inspection = null; this.inspectionAt = 0;
  }
  async catalog(refresh = false) {
    // Account, model and app requests can arrive together during startup.
    // Share discovery so an older empty response cannot replace a newer list.
    if (this.inspecting) return this.inspecting;
    if (!refresh && this.inspection && Date.now() - this.inspectionAt <= 60_000) return this.inspection;
    this.inspecting = (async () => {
      const lease = await this.updates.acquire();
      try { this.inspection = await this.inspect(lease.runtime, { includeUsage: true, connectors: true }); this.inspectionAt = Date.now(); return this.inspection; }
      finally { await lease.release(); }
    })();
    try { return await this.inspecting; }
    finally { this.inspecting = null; }
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
        displayName: modelDisplayName(m), description: m.description, hidden: false,
        agentFamily: "claude", isDefault: m.id === "haiku", supportedReasoningEfforts: (m.efforts ?? []).map(effort => ({ reasoningEffort: effort, description: `${effort[0].toUpperCase()}${effort.slice(1)}` })), defaultReasoningEffort: null })), nextCursor: null };
    }
    if (method === "account/rateLimits/read") {
      const catalog = await this.catalog(true);
      if (!catalog.windows) throw new Error("Claude usage is temporarily unavailable. Refresh to try again.");
      return { agentFamily: "claude", windows: catalog.windows, additionalUsageAvailable: catalog.additionalUsageAvailable ?? null };
    }
    if (["app/installed", "app/read", "mcpServerStatus/list"].includes(method)) {
      const session = params.threadId ? this.sessions.get(params.threadId) : null;
      const running = session && this.active.get(session.id);
      const servers = running?.query ? await running.query.mcpServerStatus() : (await this.catalog(params.forceRefetch || params.forceRefresh)).servers;
      const visible = servers.filter(s => s.source !== "sdk" && s.name !== "wonder");
      if (method === "mcpServerStatus/list") return { data: visible, nextCursor: null };
      return { apps: visible.map(s => ({ id: `claude:${s.name}`, runtimeName: s.name,
        name: s.source === "claudeai" ? s.name.replace(/^claude\.ai(?:\s*[:/·-]\s*|\s+)/i, "") : s.name,
        installUrl: "https://claude.ai/settings/connectors", enabled: s.status !== "disabled", callable: s.status === "connected", isEnabled: s.status !== "disabled", isAccessible: s.status === "connected" })), nextCursor: null };
    }
    if (method === "project/sessions/list") return this.projectSessions(params);
    if (method === "project/folders/list") return this.projectFolders(params);
    if (method === "project/session/attach") return this.attachProjectSession(params);
    if (method === "thread/start") {
      selectedModel(params.model);
      if (params.wonderProject) params.wonderProject = await projectContext(params.wonderProject);
      const policy = new ToolPolicy({ ...params.wonderPolicy, cwd: params.cwd, tools: params.dynamicTools?.map(t => t.name) ?? [] });
      if (!await policy.permits(params.cwd)) throw new Error("Claude's workspace is outside the allowed scope.");
      const session = await this.sessions.create(params);
      await this.send({ method: "thread/started", params: { thread: this.sessions.describe(session), agentFamily: "claude" } });
      return { thread: this.sessions.describe(session), model: params.model };
    }
    if (method === "thread/list") return page([...this.sessions.values.values()].filter(s => !params.sourceKinds || s.parent).map(s => this.sessions.describe(s)), params);
    const session = this.sessions.get(params.threadId);
    if (session.options.wonderProject && ["thread/turns/list", "thread/items/list"].includes(method)) {
      // The native transcript includes turns written by Claude Code on the Mac.
      const turns = await this.projectTurns(session);
      if (method === "thread/turns/list") return page([...turns].reverse().map(t => params.itemsView === "notLoaded" ? { ...t, items: [] } : t), params);
      const selected = params.turnId ? turns.filter(t => t.id === params.turnId) : params.sortDirection === "asc" ? turns : [...turns].reverse();
      return page(selected.flatMap(t => t.items.map(item => ({ turnId: t.id, item }))), params);
    }
    if (session.options.wonderProject && method === "thread/backgroundTasks/list") {
      const { messages, desktop } = await this.projectMessages(session);
      const tasks = backgroundTasks(messages, desktop || this.active.has(session.id));
      return { data: tasks.map(({ request, result, outputFile, ...summary }) => summary) };
    }
    if (session.options.wonderProject && method === "thread/backgroundTask/read") return this.backgroundTask(session, params.taskId);
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
      // Two writers on one Claude Code session would interleave its transcript.
      if (session.options.wonderProject && session.sdkStarted && !this.active.has(session.id)
        && await claudeSessionBusy(session.sdkSessionId, this.claudeSessionsDir))
        throw new Error("Claude is working on this conversation on your Mac. Send your message when it finishes.");
      if (session.options.wonderProject && params.wonderProject) params.wonderProject = await projectContext(params.wonderProject);
      const options = { ...session.options, ...params };
      if (options.wonderProject && options.wonderProject.cwd !== session.options.wonderProject?.cwd)
        throw new Error("A project conversation keeps its working folder.");
      selectedModel(options.model);
      const policy = new ToolPolicy({ ...options.wonderPolicy, cwd: options.wonderProject?.cwd ?? options.cwd,
        project: Boolean(options.wonderProject), internal: options.wonderInternal === true, structuredOutput: Boolean(options.outputSchema),
        tools: options.wonderProject ? [] : options.dynamicTools?.map(t => t.name) ?? [] });
      const content = await sdkInput(params.input, policy);
      const { turn, duplicate } = await this.sessions.accept(session, params);
      if (!duplicate) {
        const run = { turn, abort: new AbortController(), query: null, children: new Map(), childTasks: new Map(), stopped: false, authorizedTools: new Map(), toolResults: new Map() };
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
  async withSdk(action) {
    const lease = await this.updates.acquire();
    try { return await action(lease.runtime.sdk); }
    finally { await lease.release(); }
  }
  // Metadata only: listing reads transcript headers and starts no model work.
  async projectSessions(params) {
    const dirs = Array.isArray(params.dirs) ? [...new Set(params.dirs)] : [];
    if (!dirs.length || dirs.length > 32 || dirs.some(d => typeof d !== "string" || !isAbsolute(d))) throw new Error("Choose project folders to list.");
    const limit = Number.isSafeInteger(params.limit) ? Math.max(1, Math.min(params.limit, 100)) : 20;
    const offset = Number.isSafeInteger(params.offset) ? Math.max(0, Math.min(params.offset, 5000)) : 0;
    const excluded = new Set(Array.isArray(params.excludeSessionIds) ? params.excludeSessionIds : []);
    return this.withSdk(async sdk => {
      const seen = new Map();
      for (const dir of dirs) {
        const sessions = await sdk.listSessions({ dir, includeWorktrees: false, includeProgrammatic: true, limit: offset + limit + 1 });
        for (const info of sessions) {
          // `dir` also matches worktrees in some runtimes; require the exact folder.
          if (info.cwd !== dir || excluded.has(info.sessionId)) continue;
          if (!seen.has(info.sessionId)) seen.set(info.sessionId, sessionSummary(info));
        }
      }
      const all = [...seen.values()].sort((a, b) => b.updatedAt - a.updatedAt || a.sessionId.localeCompare(b.sessionId));
      return { data: all.slice(offset, offset + limit), hasMore: all.length > offset + limit };
    });
  }
  // Suggestions for explicit inclusion: recent interactive Claude Code folders.
  // SDK-originated sessions (including Bots) are not suggested.
  async projectFolders(params) {
    const limit = Number.isSafeInteger(params.limit) ? Math.max(1, Math.min(params.limit, 50)) : 20;
    return this.withSdk(async sdk => {
      const folders = new Map();
      for (const info of await sdk.listSessions({ limit: 200, includeWorktrees: false, includeProgrammatic: false })) {
        if (!info.cwd || !isAbsolute(info.cwd)) continue;
        const updatedAt = Math.floor(info.lastModified / 1000);
        if ((folders.get(info.cwd) ?? -1) < updatedAt) folders.set(info.cwd, updatedAt);
      }
      return { data: [...folders].sort((a, b) => b[1] - a[1]).slice(0, limit).map(([cwd, updatedAt]) => ({ cwd, updatedAt })) };
    });
  }
  async attachProjectSession(params) {
    if (typeof params.sessionId !== "string" || !/^[0-9a-f-]{36}$/.test(params.sessionId)) throw new Error("Invalid Claude session.");
    const project = await projectContext(params.wonderProject);
    selectedModel(params.model);
    new ToolPolicy({ ...params.wonderPolicy, cwd: project.cwd });
    const existing = [...this.sessions.values.values()].find(s => s.sdkSessionId === params.sessionId && !s.parent);
    if (existing) {
      if (existing.options.wonderProject?.cwd !== project.cwd) throw new Error("This Claude session belongs to another folder.");
      return { thread: this.sessions.describe(existing) };
    }
    const info = await this.withSdk(sdk => sdk.getSessionInfo(params.sessionId, { dir: project.cwd }));
    // Never create a replacement: a missing transcript is a recoverable error.
    if (!info || info.cwd !== project.cwd) throw new Error("This Claude session is no longer available on your Mac.");
    const session = await this.sessions.create({ ...params, wonderProject: project, cwd: project.cwd }, null, { sdkSessionId: params.sessionId, sdkStarted: true });
    return { thread: this.sessions.describe(session) };
  }
  async projectMessages(session) {
    if (!session.sdkStarted) return { messages: [], desktop: false };
    const messages = await this.withSdk(sdk => sdk.getSessionMessages(session.sdkSessionId, { dir: session.options.wonderProject.cwd }));
    // A turn started on the Mac (Claude desktop or terminal) is running there.
    const desktop = !this.active.has(session.id) && await claudeSessionBusy(session.sdkSessionId, this.claudeSessionsDir);
    return { messages, desktop };
  }
  async projectTurns(session) {
    if (!session.sdkStarted) return session.turns;
    const { messages, desktop } = await this.projectMessages(session);
    const turns = nativeTurns(messages, session.turns, this.active.has(session.id) || desktop);
    if (desktop && turns.length) turns.at(-1).runningElsewhere = true;
    return turns;
  }
  // Read-only detail for one agent task or background command.
  async backgroundTask(session, taskId) {
    if (typeof taskId !== "string" || !taskId || taskId.length > 256) throw new Error("Choose an agent task.");
    const { messages, desktop } = await this.projectMessages(session);
    const task = backgroundTasks(messages, desktop || this.active.has(session.id)).find(t => t.id === taskId);
    if (!task) throw new Error("This agent task is no longer in the conversation.");
    const sections = [];
    if (task.request) sections.push(task.kind === "agent" ? `Task\n\n${task.request}` : `Command\n\n\`\`\`\n${task.request}\n\`\`\``);
    if (task.summary) sections.push(task.summary);
    if (task.result) sections.push(task.result);
    const output = task.kind === "command" ? await this.taskOutput(session, task) : null;
    if (output) sections.push(`Latest output\n\n\`\`\`\n${output}\n\`\`\``);
    const { request, result, outputFile, ...summary } = task;
    return { task: summary, items: sections.map((text, index) => ({ type: "agentMessage", id: `${task.id}:${index}`, text, status: "completed" })) };
  }
  // Only Claude Code's own task output file for this exact session and task.
  async taskOutput(session, task) {
    const path = task.outputFile;
    if (typeof path !== "string" || !task.taskId || !/^[A-Za-z0-9_-]{1,64}$/.test(task.taskId)) return null;
    if (!/^\/(private\/)?tmp\/claude-[0-9]+\//.test(path) || basename(path) !== `${task.taskId}.output`
      || !path.includes(`/${session.sdkSessionId}/tasks/`)) return null;
    try {
      const info = await lstat(path);
      if (!info.isFile() || (await realpath(path)) !== (path.startsWith("/tmp/") ? `/private${path}` : path)) return null;
      const handle = await open(path, "r");
      try {
        const length = Math.min(info.size, 32 * 1024);
        const buffer = Buffer.alloc(length);
        await handle.read(buffer, 0, length, info.size - length);
        const text = buffer.toString("utf8").replace(/^[^\n]*\n/, info.size > length ? "" : "$&").replace(/\u001b\[[0-9;]*[A-Za-z]/g, "");
        return text.trim() ? text.trimEnd() : null;
      } finally { await handle.close(); }
    } catch { return null; }
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
    if (name === "mcp__wonder__wonder_computer_use") return deny("The old computer tool is retired. Use native cua_repl when available.");
    if (name.startsWith("mcp__cua_repl__")) {
      return run.nativeCua?.authorize(name, input, context)
        ? { behavior: "allow", updatedInput: input }
        : deny("Native computer use is unavailable for this turn.");
    }
    const decision = await policy.decision(name, input);
    if (decision === "deny") return deny(policy.denial(name));
    if (name === "AskUserQuestion") {
      const request = questionRequest(input, context.requestId ?? context.toolUseID);
      const answer = await this.serverCall("item/tool/requestUserInput", { ...base, ...request }, context.signal ?? run.abort.signal);
      return { behavior: "allow", updatedInput: questionAnswer(input, request, answer) };
    }
    if (name.startsWith("mcp__wonder__") && policy.tools.has(name.slice(13))) {
      if (context.mcpServer?.source !== "sdk" || context.mcpServer?.name !== "wonder") return deny("The tool's Wonder origin could not be verified.");
      const key = toolCallKey(name.slice(13), input);
      const calls = run.authorizedTools.get(key) ?? [];
      if (!calls.includes(context.toolUseID)) calls.push(context.toolUseID);
      run.authorizedTools.set(key, calls);
      return { behavior: "allow", updatedInput: input }; // The daemon owns these tools' approval and scope checks.
    }
    // Bash is allowed only here, wrapped in the host-owned command sandbox, in
    // every approval mode; the PreToolUse hook never allows it directly.
    const allow = async () => ({ behavior: "allow", updatedInput: name === "Bash" ? await policy.commandInput(input) : input });
    if (decision === "allow" || (name.startsWith("mcp__") && policy.bypassesApproval)) return allow();
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
      onChild: message => { if (!options.wonderPlanning) run.childMessages.push(message); } });
    run.childMessages = [];
    const flush = async (terminal = false) => {
      // Child cleanup may append its last parent activity after the parent's
      // result. Publish all item updates before the terminal turn snapshot.
      if (terminal) output.sort((a, b) => Number(a.method === "turn/completed") - Number(b.method === "turn/completed"));
      while (output.length && (terminal || output[0].method !== "turn/completed")) await this.send(output.shift());
    };
    try {
      projection.start(); await flush();
      lease = await this.updates.acquire();
      const { sdk } = lease.runtime;
      const tools = (options.wonderPlanning || options.wonderProject ? [] : options.dynamicTools ?? [])
        .filter(spec => spec.name !== "wonder_computer_use")
        .map(spec => sdk.tool(spec.name, spec.description,
        z.fromJSONSchema(spec.inputSchema).shape, async (input) => {
          const callId = run.authorizedTools.get(toolCallKey(spec.name, input))?.shift();
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
      const project = options.wonderProject;
      const base = baseOptions(lease.runtime, { connectors: !project && options.wonderConnectors === true && !options.wonderPlanning && !policy.internal });
      const computer = project ? null : options.config?.["mcp_servers.cua_repl"];
      let computerUnavailable = false;
      if (computer?.enabled === true && !options.wonderPlanning && !policy.internal) {
        try {
          run.nativeCua = await createNativeCua({ sdk, server: computer, environment: base.env,
            sessionId: session.sdkSessionId, threadId: session.id, turnId: run.turn.id, signal: run.abort.signal,
            requestElicitation: (params, signal) => this.serverCall("mcpServer/elicitation/request", params, signal) });
        } catch (error) {
          run.abort.signal.throwIfAborted();
          computerUnavailable = true;
        }
      }
      const sdkOptions = { ...base, cwd: options.cwd, model, abortController: run.abort,
        systemPrompt: [options.developerInstructions ?? "You are a helpful Wonder Bot.",
          ...(run.nativeCua ? ["This response has a fresh cua_repl runtime. Follow its first-call instructions and initialize an app or browser before using it. JavaScript variables from earlier responses are not available."] : []),
          ...(computerUnavailable ? ["Native computer use could not connect for this turn. If asked to control the computer, report that it is unavailable; do not substitute another implementation."] : []),
          ...Object.values(options.additionalContext ?? {}).filter(v => v?.kind === "application" && typeof v.value === "string").map(v => v.value)].join("\n\n"),
        tools: policy.internal || options.wonderPlanning ? [] : BUILTINS,
        mcpServers: { ...(tools.length ? { wonder: sdk.createSdkMcpServer({ name: "wonder", version: "1.0.0", tools }) } : {}),
          ...(run.nativeCua ? { cua_repl: run.nativeCua.server } : {}) },
        canUseTool: (name, input, context) => this.permission(session, run, policy, name, input, context),
        hooks: { PreToolUse: [{ hooks: [(input) => policy.beforeTool(input)] }],
          PostToolUse: [{ hooks: [async () => run.initialized ? { continue: false, stopReason: "The optional question was posted. Initialization is complete." } : {}] }] },
        permissionMode: policy.planMode ? "plan" : "default", sandbox: policy.sandbox(), includePartialMessages: true,
        // Ordinary tasks run until completion, cancellation, or the subscription limit.
        // A fixed tool-turn cap otherwise abandons valid long-running work.
        persistSession: true, verbatimPrompts: true,
        settings: { ...base.settings, availableModels: [model], enforceAvailableModels: true },
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
      if (project) {
        // Normal Claude Code behavior and project configuration, still bounded
        // by Wonder's PreToolUse/canUseTool policy and command sandbox.
        Object.assign(sdkOptions, { systemPrompt: { type: "preset", preset: "claude_code" },
          settingSources: ["user", "project", "local"], additionalDirectories: project.additionalDirectories,
          // Planning ends by proposing its plan through ExitPlanMode, which the
          // policy turns into a plan for the owner to review in Wonder.
          tools: [...BUILTINS, "Glob", "Grep", ...(policy.planMode ? ["ExitPlanMode"] : [])], mcpServers: {}, strictMcpConfig: false,
          settings: { ...sdkOptions.settings, disableClaudeAiConnectors: true } });
        delete sdkOptions.hooks.PostToolUse;
      }
      query = sdk.query({ prompt: (async function* () {
        await submit.promise;
        // Project turns name their transcript entry after the Wonder turn so
        // native history and live events reconcile by the same identity.
        if (!run.abort.signal.aborted) yield { type: "user", session_id: session.sdkSessionId, parent_tool_use_id: null,
          ...(project ? { uuid: run.turn.id } : {}), message: { role: "user", content } };
        await done.promise;
      })(), options: sdkOptions });
      run.query = query;
      await query.initializationResult();
      if (!isSubscription(await query.accountInfo())) throw new Error("Sign in to a Claude subscription on your Mac before using this Bot.");
      submit.resolve();
      for await (const message of query) {
        projection.accept(message);
        if (message.type === "system" && message.subtype === "init") await this.sessions.save(session);
        while (run.childMessages.length) await this.child(session, run, run.childMessages.shift(), projection);
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
      try { await run.nativeCua?.close(); }
      catch { process.stderr.write("Native computer-use cleanup could not be confirmed.\n"); }
      // Finish descendants first so each owner's durable snapshot includes its
      // children's final state, including when the whole query is interrupted.
      for (const child of [...run.children.values()].reverse()) {
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
  async child(parent, run, message, parentProjection) {
    const taskId = message.task_id ?? message.result?.agentId;
    const toolId = message.parent_tool_use_id ?? message.tool_use_id ?? run.childTasks.get(taskId)
      ?? (message.subtype === "task_started" && taskId ? `task:${taskId}` : null);
    if (!toolId || message.ambient || message.skip_transcript) return;
    let child = run.children.get(toolId);
    if (!child) {
      // Progress and completion events also belong to shell/MCP/housekeeping
      // tasks. Only a visible local-agent start establishes child ownership.
      if (message.type !== "system" || message.subtype !== "task_started" || message.task_type !== "local_agent") {
        if (message.type === "agent_result" && message.is_error) {
          const call = parentProjection.agentTools.get(toolId);
          const item = parentProjection.startItem({ type: "subAgentActivity", id: toolId,
            agentNickname: call?.input?.description ?? "Agent", kind: "failed", status: "inProgress", success: false,
            error: { message: typeof message.content === "string" ? message.content.slice(0, 2000) : "The agent could not start." } });
          parentProjection.finishItem(item);
        }
        return;
      }
      const owner = [...run.children.values()].find(c => c.projection.agentTools.has(toolId));
      if (owner) { parent = owner.session; parentProjection = owner.projection; }
      const expectedDepth = (parent.parent?.depth ?? 0) + 1;
      const depth = message.spawn_depth ?? expectedDepth;
      if (!Number.isInteger(depth) || depth !== expectedDepth || depth > 16) return;
      const session = await this.sessions.create(parent.options, { threadId: parent.id, depth,
        name: String(message.description ?? "Helper").slice(0, 100), role: message.subagent_type ?? "Helper" });
      const turn = { id: randomUUID(), status: "inProgress", items: [] }; session.turns.push(turn);
      const output = [];
      const projection = new TurnProjection({ threadId: session.id, turnId: turn.id, emit: event => output.push(event),
        onChild: message => run.childMessages.push(message) });
      const activity = { type: "subAgentActivity", id: toolId, agentThreadId: session.id,
        agentNickname: session.parent.name, agentRole: session.parent.role, kind: "started", status: "running" };
      child = { session, turn, projection, flush: async () => {
        const terminal = output.findLast(e => e.method === "turn/completed")?.params.turn;
        // History reads while the task is running must see the same items as
        // the stream. Persist once at completion, not once per text delta.
        if (turn.items.length !== projection.items.size) turn.items = [...projection.items.values()];
        if (terminal) {
          Object.assign(turn, terminal); await this.sessions.save(session);
          activity.status = terminal.status; activity.kind = terminal.status;
          if (terminal.error) activity.error = terminal.error;
          parentProjection.notify("item/completed", { item: { ...activity } });
        }
        while (output.length) await this.send(output.shift());
        await owner?.flush();
      } };
      run.children.set(toolId, child);
      if (taskId) run.childTasks.set(taskId, toolId);
      await this.sessions.save(session);
      await this.send({ method: "thread/started", params: { thread: this.sessions.describe(session), agentFamily: "claude" } });
      parentProjection.startItem(activity);
      projection.start();
    }
    if (message.parent_tool_use_id) child.projection.accept({ ...message, parent_tool_use_id: null });
    const completedResult = message.type === "agent_result" && !message.is_error && message.result?.status === "completed";
    if (message.subtype === "task_notification" || completedResult || (message.type === "agent_result" && message.is_error)) {
      if (!child.projection.terminal) {
        const status = completedResult ? "completed" : message.status === "completed" ? "completed" : message.status === "stopped" ? "interrupted" : "failed";
        const summary = completedResult ? message.result.content?.filter(b => b.type === "text").map(b => b.text).join("\n\n") : message.summary;
        // Foreground agents sometimes emit only the task report, without child
        // assistant frames. Never parse the model-directed tool-result trailer.
        if (typeof summary === "string" && summary.trim() && ![...child.projection.items.values()].some(i => i.type === "agentMessage" && i.text.trim() === summary.trim()))
          child.projection.completeText(`task:${toolId}:result`, summary);
        child.projection.finish(status, status === "failed" ? summary ?? "The agent task failed." : undefined);
      }
    }
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
