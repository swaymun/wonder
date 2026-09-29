import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Sessions } from "../sessions.mjs";
import { ClaudeBridge } from "../bridge.mjs";

// Contract owner: the bridge's subscription-to-durable-turn boundary. Replayed
// requests and restarts cannot spend a second model turn or report false success.
async function fixture(t, { authenticated = true, messages = [] } = {}) {
  const root = await mkdtemp(join(tmpdir(), "wonder-bridge-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const sessions = await new Sessions(join(root, "sessions")).initialize();
  const frames = [], inputs = [], capturedOptions = [];
  const runtime = { sdk: {
    query: ({ prompt, options }) => {
      capturedOptions.push(options);
      const query = (async function* () {
        for await (const input of prompt) {
          inputs.push(input);
          yield { type: "system", subtype: "init", session_id: options.sessionId ?? options.resume };
          for await (const message of messages) yield message;
          return;
        }
      })();
      query.initializationResult = async () => ({});
      query.accountInfo = async () => ({ apiProvider: "firstParty", subscriptionType: authenticated ? "Claude Pro" : null });
      query.close = () => {};
      return query;
    },
  } };
  const updates = { acquire: async () => ({ runtime, release: async () => {} }) };
  const bridge = new ClaudeBridge({ updates, sessions, send: async frame => {
    if (frame.method === "turn/completed") {
      const durable = JSON.parse(await readFile(join(root, "sessions", `${frame.params.threadId}.json`)));
      assert.equal(durable.turns.find(t => t.id === frame.params.turnId).status, frame.params.turn.status);
    }
    frames.push(structuredClone(frame));
  } });
  const params = { cwd: root, model: "claude:haiku", wonderPolicy: {
    mode: "read_only", approvalMode: "ask", readRoots: [root], writeRoots: [], deniedRoots: [] } };
  const { thread } = await bridge.request("thread/start", params);
  const finish = async () => { await new Promise(resolve => setImmediate(resolve)); await bridge.active.get(thread.id)?.finished; };
  return { root, sessions, bridge, thread, frames, inputs, capturedOptions, finish };
}

// Resuming a stored session must not resurrect the retired custom computer
// tool. Native computer access must come from the host-registered adapter.
test("resumed sessions cannot expose or invoke the retired computer tool", async t => {
  const f = await fixture(t, { messages: [{ type: "result", subtype: "success" }] });
  f.sessions.get(f.thread.id).options.dynamicTools = [{ name: "wonder_computer_use" }];
  await f.bridge.request("turn/start", { threadId: f.thread.id, input: [{ type: "text", text: "Continue" }] });
  await f.finish();
  assert.equal(f.sessions.get(f.thread.id).turns[0].status, "completed");
  assert.deepEqual(f.capturedOptions[0].mcpServers, {});
  const result = await f.capturedOptions[0].canUseTool("mcp__wonder__wonder_computer_use", { action: "key" },
    { toolUseID: "legacy", mcpServer: { name: "wonder", source: "sdk" } });
  assert.equal(result.behavior, "deny");
  assert.match(result.message, /retired/);
  for (const approvalMode of ["ask", "full_access"]) {
    const options = f.sessions.get(f.thread.id).options;
    options.wonderPolicy.approvalMode = approvalMode;
    await f.bridge.request("turn/start", { threadId: f.thread.id, input: [{ type: "text", text: "Continue" }] });
    await f.finish();
    const result = await f.capturedOptions.at(-1).canUseTool("mcp__cua_repl__js", { code: "await cua.getState();" },
      { toolUseID: "unregistered", mcpServer: { name: "cua_repl", source: "sdk" } });
    assert.equal(result.behavior, "deny");
  }
});

// Catalog labels must describe actual execution without changing saved model or
// MCP identities. Older SDKs and unfamiliar future IDs keep their runtime label.
test("model labels use resolved versions while preserving selections and pinned Haiku", async t => {
  const f = await fixture(t);
  const cases = [
    ["opus", "claude-opus-5-5", "Opus", "Opus 5.5"],
    ["sonnet", "claude-sonnet-5", "Sonnet", "Sonnet 5"],
    ["haiku", "claude-haiku-9", "Haiku", "Haiku 4.5"],
    ["claude-fable-5-1[1m]", "claude-fable-5-1", "Fable", "Fable 5.1"],
    ["claude-opus-4-1-20250805", undefined, "Opus", "Opus 4.1"],
    ["claude-sonnet-5-20260901", undefined, "Sonnet", "Sonnet 5"],
    ["legacy-alias", undefined, "Legacy model", "Legacy model"],
    ["future-alias", "claude-next-special", "Next special", "Next special"],
  ];
  f.bridge.inspect = async () => ({ models: [
    { id: "default", name: "Default" },
    ...cases.map(([id, resolvedModel, name]) => ({ id, resolvedModel, name, efforts: ["low", "high"] })),
  ] });
  const { data } = await f.bridge.request("model/list", {});
  assert.equal(data.length, cases.length);
  assert.equal(data[0].id, "claude:haiku");
  for (const [id, , , expected] of cases) {
    const model = data.find(m => m.id === `claude:${id}`);
    assert.equal(model.model, `claude:${id}`);
    assert.equal(model.displayName, expected);
    assert.deepEqual(model.supportedReasoningEfforts.map(e => e.reasoningEffort), ["low", "high"]);
  }
  assert.equal(f.inputs.length, 0);
});

test("connector labels strip the Claude account prefix without changing MCP identity", async t => {
  const f = await fixture(t);
  const servers = [
    { name: "claude.ai Gmail", source: "claudeai", status: "connected" },
    { name: "Claude.ai: Google Calendar", source: "claudeai", status: "disabled" },
    { name: "claude.ai in a custom name", source: "user", status: "connected" },
    { name: "Custom claude.ai Gmail", source: "claudeai", status: "failed" },
    { name: "wonder", source: "sdk", status: "connected" },
  ];
  f.bridge.inspect = async () => ({ servers });
  for (const method of ["app/installed", "app/read"]) {
    const { apps } = await f.bridge.request(method, {});
    assert.deepEqual(apps.map(a => a.name), ["Gmail", "Google Calendar", "claude.ai in a custom name", "Custom claude.ai Gmail"]);
    assert.equal(apps[0].id, "claude:claude.ai Gmail");
    assert.equal(apps[0].runtimeName, "claude.ai Gmail");
    assert.equal(apps[0].callable, true);
    assert.equal(apps[1].enabled, false);
    assert.equal(apps[3].callable, false);
  }
  assert.deepEqual((await f.bridge.request("mcpServerStatus/list", {})).data, servers.slice(0, 4));
  assert.equal(f.inputs.length, 0);
});

test("duplicate delivery executes once and commits the terminal receipt before publishing", async t => {
  const f = await fixture(t, { messages: [
    { type: "assistant", message: { id: "reply", content: [{ type: "text", text: "Hello" }] } },
    { type: "result", subtype: "success" },
  ] });
  const params = { threadId: f.thread.id, clientUserMessageId: "same", input: [{ type: "text", text: "Hi" }] };
  const first = await f.bridge.request("turn/start", params);
  const duplicate = await f.bridge.request("turn/start", params);
  assert.equal(first.turn.id, duplicate.turn.id);
  await f.finish();
  assert.equal(f.inputs.length, 1);
  assert.equal(f.sessions.get(f.thread.id).turns[0].status, "completed");
  const persisted = JSON.parse(await readFile(join(f.root, "sessions", `${f.thread.id}.json`)));
  assert.equal(persisted.turns[0].status, "completed");
  assert.equal(f.frames.filter(e => e.method === "turn/completed").length, 1);
  const restarted = await new Sessions(join(f.root, "sessions")).initialize();
  assert.equal(restarted.get(f.thread.id).turns[0].status, "completed");
  assert.equal(f.capturedOptions[0].model, "claude-haiku-4-5-20251001");
});

// Contract: only actual agent tasks reach the existing agent roster/activity
// renderer. SDK background launches are acknowledgements, not completed work;
// task IDs still identify completion when the optional tool ID is absent.
test("agent lifecycle links the parent activity to a readable child without launch metadata", async t => {
  let f;
  const messages = (async function* () {
    yield { type: "assistant", message: { content: [{ type: "tool_use", id: "agent-call", name: "Agent",
      input: { description: "Review guide", subagent_type: "general-purpose", run_in_background: true, prompt: "Private task instructions" } }] } };
    yield { type: "system", subtype: "task_started", task_type: "local_agent", task_id: "agent-task",
      tool_use_id: "agent-call", description: "Review guide", spawn_depth: 1, is_backgrounded: true };
    yield { type: "user", tool_use_result: { status: "async_launched", isAsync: true, agentId: "agent-task" },
      message: { content: [{ type: "tool_result", tool_use_id: "agent-call", content: "Internal launch metadata and output file path" }] } };
    yield { type: "assistant", parent_tool_use_id: "agent-call", message: { id: "child-reply", content: [{ type: "text", text: "Checked the guide." }] } };
    const child = [...f.sessions.values.values()].find(s => s.parent);
    const live = await f.bridge.request("thread/read", { threadId: child.id, includeTurns: true });
    assert.equal(live.thread.status.type, "active");
    assert.equal(live.thread.turns[0].items[0].text, "Checked the guide.");
    yield { type: "system", subtype: "task_notification", task_id: "agent-task", status: "completed", summary: "Checked the guide." };
    yield { type: "system", subtype: "task_notification", task_id: "agent-task", tool_use_id: "agent-call", status: "completed", summary: "Checked the guide." };
    yield { type: "result", subtype: "success" };
  })();
  f = await fixture(t, { messages });
  await f.bridge.request("turn/start", { threadId: f.thread.id, input: [{ type: "text", text: "Review" }] });
  await f.finish();
  const children = [...f.sessions.values.values()].filter(s => s.parent);
  assert.equal(children.length, 1);
  const child = children[0];
  assert.equal(child.turns[0].status, "completed");
  assert.equal(child.turns[0].items.filter(i => i.type === "agentMessage").length, 1);
  const activity = f.sessions.get(f.thread.id).turns[0].items.filter(i => i.type !== "userMessage");
  assert.equal(activity.length, 1);
  assert.equal(activity[0].type, "subAgentActivity");
  assert.equal(activity[0].agentThreadId, child.id);
  assert.equal(activity[0].agentNickname, "Review guide");
  assert.equal(activity[0].status, "completed");
  assert.doesNotMatch(JSON.stringify(f.frames), /Internal launch metadata|Private task instructions/);
  assert.equal(f.frames.filter(e => e.method === "turn/completed" && e.params.threadId === child.id).length, 1);
  const restarted = await new Sessions(join(f.root, "sessions")).initialize();
  assert.equal(restarted.get(child.id).turns[0].items[0].text, "Checked the guide.");
  await assert.rejects(f.bridge.request("turn/start", { threadId: child.id, input: [{ type: "text", text: "Change" }] }), /parent conversation/);
});

test("shell, ambient and unknown task events never create phantom agents", async t => {
  const messages = [];
  for (const [id, fields] of [["shell", { task_type: "local_bash" }], ["quiet", { task_type: "local_agent", ambient: true }],
    ["hidden", { task_type: "local_agent", skip_transcript: true }], ["future", { task_type: "future_task" }]]) {
    messages.push({ type: "system", subtype: "task_started", task_id: id, tool_use_id: id, ...fields },
      { type: "system", subtype: "task_progress", task_id: id, tool_use_id: id, description: "Working" },
      { type: "assistant", parent_tool_use_id: id, message: { id, content: [{ type: "text", text: "Hidden helper text" }] } },
      { type: "system", subtype: "task_notification", task_id: id, tool_use_id: id, status: "completed", summary: "Done" });
  }
  messages.push({ type: "system", subtype: "task_notification", task_id: "orphan", tool_use_id: "orphan", status: "completed", summary: "Done" },
    { type: "result", subtype: "success" });
  const f = await fixture(t, { messages });
  await f.bridge.request("turn/start", { threadId: f.thread.id, input: [{ type: "text", text: "Check" }] });
  await f.finish();
  assert.equal(f.sessions.values.size, 1);
  assert.doesNotMatch(JSON.stringify(f.frames), /Hidden helper text/);
});

test("foreground helpers retain their final report and failed or stopped tasks stay honest", async t => {
  for (const [status, expected] of [["completed", "completed"], ["failed", "failed"], ["stopped", "interrupted"]]) {
    const f = await fixture(t, { messages: [
      { type: "system", subtype: "task_started", task_type: "local_agent", task_id: "task", tool_use_id: "call", description: "Check", is_backgrounded: false },
      // Foreground SDK captures may omit the child assistant message entirely.
      { type: "system", subtype: "task_notification", task_id: "task", status, summary: "Final task report" },
      { type: "result", subtype: "success" },
    ] });
    await f.bridge.request("turn/start", { threadId: f.thread.id, input: [{ type: "text", text: "Check" }] });
    await f.finish();
    const child = [...f.sessions.values.values()].find(s => s.parent);
    assert.equal(child.turns[0].status, expected);
    assert.equal(child.turns[0].items[0].text, "Final task report");
    const activity = f.sessions.get(f.thread.id).turns[0].items.find(i => i.type === "subAgentActivity");
    assert.equal(activity.status, expected);
  }
});

test("structured agent results complete a task without exposing the model-directed trailer", async t => {
  const f = await fixture(t, { messages: [
    { type: "assistant", message: { content: [{ type: "tool_use", id: "call", name: "Agent", input: { description: "Review" } }] } },
    { type: "system", subtype: "task_started", task_type: "local_agent", task_id: "task", tool_use_id: "call", description: "Review" },
    { type: "user", tool_use_result: { status: "completed", agentId: "task", content: [{ type: "text", text: "Clean report" }] },
      message: { content: [{ type: "tool_result", tool_use_id: "call", content: "Clean report\nInternal agentId and usage trailer" }] } },
    { type: "result", subtype: "success" },
  ] });
  await f.bridge.request("turn/start", { threadId: f.thread.id, input: [{ type: "text", text: "Check" }] });
  await f.finish();
  const child = [...f.sessions.values.values()].find(s => s.parent);
  assert.equal(child.turns[0].status, "completed");
  assert.equal(child.turns[0].items[0].text, "Clean report");
  assert.doesNotMatch(JSON.stringify(f.frames), /usage trailer/);
});

test("nested agents belong to their actual parent and unfinished work is never shown as completed", async t => {
  for (const finished of [true, false]) {
    const f = await fixture(t, { messages: [
      { type: "system", subtype: "task_started", task_type: "local_agent", task_id: "outer", tool_use_id: "outer-call", description: "Research", spawn_depth: 1 },
      { type: "assistant", parent_tool_use_id: "outer-call", message: { content: [{ type: "tool_use", id: "inner-call", name: "Agent", input: { description: "Check source" } }] } },
      { type: "system", subtype: "task_started", task_type: "local_agent", task_id: "inner", tool_use_id: "inner-call", description: "Check source", spawn_depth: 2 },
      ...(finished ? [{ type: "system", subtype: "task_notification", task_id: "inner", status: "completed", summary: "Source checked" }] : []),
      { type: "result", subtype: "success" },
    ] });
    await f.bridge.request("turn/start", { threadId: f.thread.id, input: [{ type: "text", text: "Check" }] });
    await f.finish();
    const children = [...f.sessions.values.values()].filter(s => s.parent);
    const outer = children.find(s => s.parent.depth === 1), inner = children.find(s => s.parent.depth === 2);
    assert.equal(inner.parent.threadId, outer.id);
    assert.equal(outer.parent.threadId, f.thread.id);
    assert.equal(inner.turns[0].status, finished ? "completed" : "failed");
    assert.equal(outer.turns[0].status, "failed");
    assert.equal(outer.turns[0].items[0].agentThreadId, inner.id);
    assert.equal(outer.turns[0].items[0].status, finished ? "completed" : "failed");
    const restarted = await new Sessions(join(f.root, "sessions")).initialize();
    assert.equal(restarted.get(outer.id).turns[0].items[0].status, finished ? "completed" : "failed");
    assert.equal(f.frames.at(-1).method, "turn/completed");
    assert.equal(f.frames.at(-1).params.threadId, f.thread.id);
    assert.equal(f.frames.at(-1).params.turn.items.find(i => i.type === "subAgentActivity").status, "failed");
  }
});
test("failed runtime results remain failed while the next message resumes the same SDK session", async t => {
  const messages = [{ type: "result", subtype: "error_max_turns", is_error: true, errors: ["Reached maximum number of turns (64)"] }];
  const f = await fixture(t, { messages });
  await f.bridge.request("turn/start", { threadId: f.thread.id, clientUserMessageId: "first", input: [{ type: "text", text: "Hi" }] });
  await f.finish();
  const restarted = await new Sessions(join(f.root, "sessions")).initialize();
  assert.equal(restarted.get(f.thread.id).turns[0].status, "failed");
  assert.equal(f.frames.at(-1).params.turn.status, "failed");
  f.bridge.sessions = restarted;
  messages.splice(0, 1, { type: "result", subtype: "success" });
  await f.bridge.request("turn/start", { threadId: f.thread.id, clientUserMessageId: "continue", input: [{ type: "text", text: "Continue" }] });
  await f.finish();
  assert.equal(f.capturedOptions[1].resume, f.capturedOptions[0].sessionId);
  assert.equal(f.inputs.length, 2);
  assert.deepEqual(restarted.get(f.thread.id).turns.map(turn => turn.status), ["failed", "completed"]);
});
test("missing subscription fails before the generator can submit a prompt", async t => {
  const f = await fixture(t, { authenticated: false });
  await f.bridge.request("turn/start", { threadId: f.thread.id, input: [{ type: "text", text: "Hi" }] });
  await f.finish();
  assert.equal(f.inputs.length, 0);
  assert.equal(f.sessions.get(f.thread.id).turns[0].status, "failed");
});
test("a restart interrupts accepted work and its receipt prevents duplicate submission", async t => {
  const f = await fixture(t);
  await f.sessions.accept(f.sessions.get(f.thread.id), { clientUserMessageId: "accepted-before-crash" });
  const restarted = await new Sessions(join(f.root, "sessions")).initialize();
  const session = restarted.get(f.thread.id);
  assert.equal(session.turns[0].status, "interrupted");
  const receipt = await restarted.accept(session, { clientUserMessageId: "accepted-before-crash" });
  assert.equal(receipt.duplicate, true);
  assert.equal(session.turns.length, 1);
});
test("question response only reaches its exact outstanding request", async t => {
  const f = await fixture(t);
  const signal = new AbortController();
  const result = f.bridge.serverCall("item/tool/requestUserInput", { threadId: f.thread.id }, signal.signal);
  const id = f.frames.at(-1).id;
  await f.bridge.receive({ id: "different", result: { answers: {} } });
  assert.equal(f.bridge.pending.size, 1);
  await f.bridge.receive({ id, result: { answers: { q: { answers: ["A", "B"] } } } });
  assert.deepEqual(await result, { answers: { q: { answers: ["A", "B"] } } });
  assert.equal(f.bridge.pending.size, 0);
});

test("account connector calls wait for the owning Bot approval", async t => {
  const f = await fixture(t);
  const { ToolPolicy } = await import("../permissions.mjs");
  const session = f.sessions.get(f.thread.id);
  const policy = new ToolPolicy({ ...session.options.wonderPolicy, cwd: session.options.cwd });
  const run = { turn: { id: "connector-turn" }, abort: new AbortController() };
  const before = f.frames.length;
  assert.equal((await f.bridge.permission(session, run, policy, "ToolSearch", { query: "gmail labels" },
    { toolUseID: "search-labels" })).behavior, "allow");
  assert.equal(f.frames.length, before);
  for (const decision of ["decline", "accept"]) {
    let settled = false;
    const result = f.bridge.permission(session, run, policy, "mcp__claude_ai_Gmail__list_labels", {},
      { toolUseID: `labels-${decision}`, mcpServer: { name: "claude.ai Gmail", source: "claudeai" } });
    result.then(() => { settled = true; });
    await new Promise(resolve => setImmediate(resolve));
    const request = f.frames.at(-1);
    assert.equal(request.method, "item/commandExecution/requestApproval");
    assert.equal(request.params.threadId, f.thread.id);
    assert.equal(settled, false);
    await f.bridge.receive({ id: request.id, result: { decision } });
    assert.equal((await result).behavior, decision === "accept" ? "allow" : "deny");
  }
});

test("concurrent account and model reads share discovery and retry after failure", async t => {
  const f = await fixture(t), done = Promise.withResolvers();
  let calls = 0;
  f.bridge.inspect = async () => { calls++; await done.promise; throw new Error("offline"); };
  const account = f.bridge.request("account/read", { refresh: true });
  const models = f.bridge.request("model/list", {});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls, 1);
  done.resolve();
  const first = await Promise.allSettled([account, models]);
  assert.ok(first.every(r => r.status === "rejected" && r.reason.message === "offline"));
  f.bridge.inspect = async () => { calls++; return { connected: true, subscription: "Claude Pro", models: [], servers: [] }; };
  assert.deepEqual(await f.bridge.request("model/list", {}), { data: [], nextCursor: null });
  assert.equal(calls, 2);
});

// Contract: uploaded opaque image IDs and application-owned Bot context reach
// the SDK together, while an active history read never replaces turn settings.
test("opaque image attachments and Bot context survive the normalized input boundary", async t => {
  const f = await fixture(t, { messages: [{ type: "result", subtype: "success", structured_output: { ok: true } }] });
  const path = join(f.root, "attachment-id");
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJXcAAAAASUVORK5CYII=", "base64");
  await writeFile(path, png);
  const { turn } = await f.bridge.request("turn/start", { threadId: f.thread.id, input: [{ type: "localImage", path }],
    additionalContext: { profile: { kind: "application", value: "The owner named this Bot Atlas." } }, outputSchema: { type: "object" } });
  const restored = await f.bridge.request("thread/resume", { threadId: f.thread.id, developerInstructions: "Unexpected replacement" });
  assert.equal(restored.thread.status.type, "active");
  await f.finish();
  assert.equal(f.inputs[0].message.content[0].source.media_type, "image/png");
  assert.equal(f.inputs[0].message.content[0].source.data, png.toString("base64"));
  assert.match(f.capturedOptions[0].systemPrompt, /named this Bot Atlas/);
  assert.doesNotMatch(f.capturedOptions[0].systemPrompt, /Unexpected replacement/);
  const schemaTool = await f.capturedOptions[0].hooks.PreToolUse[0].hooks[0]({ tool_name: "StructuredOutput", tool_input: { ok: true } });
  assert.equal(schemaTool.hookSpecificOutput.permissionDecision, "allow");
  assert.deepEqual(f.sessions.get(f.thread.id).turns.find(t => t.id === turn.id).structuredOutput, { ok: true });
});
