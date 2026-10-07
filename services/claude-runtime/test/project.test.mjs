import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile, symlink } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { Sessions } from "../sessions.mjs";
import { ClaudeBridge } from "../bridge.mjs";
import { ToolPolicy } from "../permissions.mjs";
import { backgroundTasks, claudeSessionBusy, nativeTurns } from "../project-history.mjs";
import { ClaudeSessionFiles, projectFolderName } from "../session-file.mjs";

// Contract owner: project conversations continue the owner's native Claude Code
// session by exact UUID, read history from that transcript, and never receive
// Bot instructions or tools.
async function fixture(t, { transcripts = {} } = {}) {
  const gate = { current: null };
  const root = await mkdtemp(join(tmpdir(), "wonder-project-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const primary = join(root, "app"), secondary = join(root, "docs");
  await mkdir(primary); await mkdir(secondary);
  const sessions = await new Sessions(join(root, "sessions")).initialize();
  const frames = [], inputs = [], capturedOptions = [];
  const sdk = {
    tool: (name, _description, _schema, handler) => ({ name, handler }), createSdkMcpServer: ({ tools }) => ({ tools }),
    listSessions: async ({ dir }) => Object.entries(transcripts).filter(([, s]) => s.cwd === dir)
      .map(([sessionId, s]) => ({ sessionId, summary: s.title, lastModified: s.updatedAt, cwd: s.cwd })),
    getSessionInfo: async (id, { dir }) => transcripts[id]?.cwd === dir ? { sessionId: id, cwd: dir, lastModified: 1 } : undefined,
    getSessionMessages: async id => transcripts[id]?.messages ?? [],
    query: ({ prompt, options }) => {
      capturedOptions.push(options);
      const query = (async function* () {
        for await (const input of prompt) {
          inputs.push(input);
          yield { type: "system", subtype: "init", session_id: options.sessionId ?? options.resume };
          await gate.current?.promise;
          yield { type: "result", subtype: "success" }; // A leftover background notice.
          yield { type: "assistant", user_message_uuid: input.uuid,
            message: { id: "reply", content: [{ type: "text", text: "Answered the new prompt." }] } };
          yield { type: "result", subtype: "success", user_message_uuid: input.uuid };
          return;
        }
      })();
      query.initializationResult = async () => ({});
      query.accountInfo = async () => ({ apiProvider: "firstParty", subscriptionType: "Claude Max" });
      query.close = () => {};
      return query;
    },
  };
  const updates = { acquire: async () => ({ runtime: { sdk }, release: async () => {} }) };
  const bridge = new ClaudeBridge({ updates, sessions, send: async frame => { frames.push(frame); } });
  const policy = { mode: "workspace", approvalMode: "ask", readRoots: ["/"], writeRoots: [primary, secondary], deniedRoots: [] };
  const project = { cwd: primary, additionalDirectories: [secondary] };
  return { root, primary, secondary, sessions, bridge, frames, inputs, capturedOptions, policy, project, gate };
}

test("project turns use the native coding preset and name the transcript entry after the Wonder turn", async t => {
  const f = await fixture(t);
  const { thread } = await f.bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku",
    wonderPolicy: f.policy, wonderProject: f.project, developerInstructions: "You are a Bot", dynamicTools: [{ name: "wonder_ask_question" }] });
  const { turn } = await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Fix the build" }] });
  await new Promise(resolve => setImmediate(resolve));
  await f.bridge.active.get(thread.id)?.finished;
  const options = f.capturedOptions[0];
  // Projects run without a sandbox, so there is no sandbox guidance to add.
  assert.deepEqual(options.systemPrompt, { type: "preset", preset: "claude_code" });
  assert.deepEqual(options.sandbox, { enabled: false });
  assert.deepEqual(options.settingSources, ["user", "project", "local"]);
  assert.deepEqual(options.additionalDirectories, [f.secondary]);
  assert.deepEqual(options.mcpServers, {});
  assert.equal(options.sessionId, thread.sessionId);
  assert.equal(f.inputs[0].uuid, turn.id);
  const saved = f.sessions.get(thread.id).turns[0];
  assert.equal(saved.status, "completed");
  assert.ok(saved.items.some(item => item.type === "agentMessage" && item.text === "Answered the new prompt."));
  // A project cannot be moved to another folder by a later turn.
  await assert.rejects(f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "x" }],
    wonderProject: { cwd: f.secondary } }), /keeps its working folder/);
});

// Contract: the owner's approval and plan modes reach every turn as Claude
// Code's own permission mode, with no sandbox. Whatever Claude Code would ask
// reaches the owner; Full access never asks; Read only keeps a sandbox whose
// new hosts ask; and planning refuses writes and proposals to continue.
test("project approval and plan modes reach the SDK and Claude Code's prompts reach the owner", async t => {
  const f = await fixture(t);
  await assert.rejects(f.bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku", wonderProject: f.project,
    wonderPolicy: { ...f.policy, mode: "read_only", approvalMode: "auto" } }), /unsupported/);
  const { thread } = await f.bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });
  const settle = () => new Promise(resolve => setImmediate(resolve));
  const turn = async (modes, body) => {
    f.gate.current = Promise.withResolvers();
    const before = f.capturedOptions.length;
    await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Go" }],
      wonderPolicy: { ...f.policy, ...modes }, wonderProject: f.project });
    while (f.capturedOptions.length === before) await settle();
    const options = f.capturedOptions.at(-1);
    const hook = (tool_name, tool_input) => options.hooks.PreToolUse[0].hooks[0]({ tool_name, tool_input }).then(r => r.hookSpecificOutput);
    // Resolves the next approval request the owner would see.
    const approve = async (call, decision, check = () => {}) => {
      await settle();
      const request = f.frames.at(-1);
      assert.equal(request.method, "item/commandExecution/requestApproval");
      check(request.params);
      await f.bridge.receive({ id: request.id, result: { decision } });
      return call;
    };
    try { await body({ options, hook, approve }); }
    finally { f.gate.current.resolve(); await f.bridge.active.get(thread.id)?.finished; }
  };
  const inside = { file_path: join(f.primary, "a.txt"), content: "x" }, ctx = id => ({ toolUseID: id });
  const ran = (options, result) => {
    assert.deepEqual(options.sandbox, { enabled: false });
    assert.deepEqual(result, { behavior: "allow", updatedInput: { command: "echo hi" } });
  };
  const outside = { command: "git push", dangerouslyDisableSandbox: true };
  const network = (host, decision) => async ({ options, approve }) => {
    const call = options.canUseTool("SandboxNetworkAccess", { host }, ctx(`net-${host}`));
    return approve(call, decision, params => {
      assert.deepEqual(params.networkApprovalContext, { host, protocol: "https" });
      assert.ok(params.availableDecisions.some(d => d?.applyNetworkPolicyAmendment?.network_policy_amendment?.host === host));
    });
  };

  await turn({ approvalMode: "auto" }, async ({ options, hook, approve }) => {
    // Claude Code's classifier approves routine commands; an escalation asks the owner.
    assert.equal(options.permissionMode, "auto");
    assert.deepEqual(await hook("Bash", { command: "echo hi" }), undefined);
    ran(options, await approve(options.canUseTool("Bash", { command: "echo hi" }, ctx("auto-bash")), "accept",
      params => assert.equal(params.command, "echo hi")));
    const declined = await approve(options.canUseTool("Bash", { command: "git push" }, ctx("auto-push")), "decline");
    assert.equal(declined.behavior, "deny");
    assert.match(declined.message, /owner declined/);
    assert.equal((await hook("Write", inside)).permissionDecision, "allow");
    assert.equal((await options.canUseTool("Write", inside, ctx("auto-write"))).behavior, "allow");
    const web = options.canUseTool("WebFetch", { url: "https://example.com" }, ctx("auto-web"));
    assert.equal((await approve(web, "decline")).behavior, "deny");
  });
  await turn({ mode: "read_only", approvalMode: "ask", writeRoots: [] }, async ({ options, approve }) => {
    assert.equal(options.sandbox.enabled, true);
    // Leaving Read only's sandbox is the owner's decision.
    const declined = await approve(options.canUseTool("Bash", outside, ctx("ro-outside")), "decline",
      params => assert.match(params.reason, /outside the sandbox/));
    assert.match(declined.message, /outside the sandbox/);
    // A new host is allowed once, for the session, or saved to Claude Code's project settings.
    assert.deepEqual(await network("example.com", "accept")({ options, approve }), { behavior: "allow", updatedInput: { host: "example.com" } });
    assert.equal((await network("example.org", "acceptForSession")({ options, approve })).updatedPermissions[0].destination, "session");
    const saved = await network("example.net", { applyNetworkPolicyAmendment: { network_policy_amendment: { host: "example.net", action: "allow" } } })({ options, approve });
    assert.deepEqual(saved.updatedPermissions, [{ type: "addRules", rules: [{ toolName: "WebFetch", ruleContent: "domain:example.net" }], behavior: "allow", destination: "localSettings" }]);
    const refused = await network("evil.example", "decline")({ options, approve });
    assert.equal(refused.behavior, "deny");
    assert.match(refused.message, /did not allow evil\.example/);
  });
  await turn({ approvalMode: "accept_edits" }, async ({ options, approve }) => {
    assert.equal(options.permissionMode, "default");
    assert.equal((await options.canUseTool("Edit", inside, ctx("edit"))).behavior, "allow");
    ran(options, await approve(options.canUseTool("Bash", { command: "echo hi" }, ctx("ask-bash")), "accept"));
  });
  await turn({ approvalMode: "auto", planMode: true }, async ({ options, hook, approve }) => {
    assert.equal(options.permissionMode, "plan");
    assert.ok(options.tools.includes("ExitPlanMode"));
    for (const tool of ["Write", "Edit"]) {
      assert.equal((await hook(tool, inside)).permissionDecision, "deny");
      const denied = await options.canUseTool(tool, inside, ctx(`plan-${tool}`));
      assert.equal(denied.behavior, "deny");
      assert.match(denied.message, /Plan mode: describe the change instead of editing/);
    }
    const exit = await options.canUseTool("ExitPlanMode", { plan: "# Plan" }, ctx("plan-exit"));
    assert.equal(exit.behavior, "deny");
    assert.match(exit.message, /owner reviews the plan in Wonder/);
    // Even in Auto, planning asks before running a command.
    ran(options, await approve(options.canUseTool("Bash", { command: "echo hi" }, ctx("plan-bash")), "accept"));
  });
  await turn({ approvalMode: "ask" }, async ({ options }) => {
    assert.equal(options.permissionMode, "default");
    assert.ok(!options.tools.includes("ExitPlanMode"));
  });
  // Full access means no sandbox and no questions.
  await turn({ mode: "full_access", approvalMode: "full_access" }, async ({ options }) => {
    assert.deepEqual(options.sandbox, { enabled: false });
    assert.deepEqual(options.systemPrompt, { type: "preset", preset: "claude_code" });
    const before = f.frames.length;
    assert.equal((await options.canUseTool("Bash", outside, ctx("full-outside"))).behavior, "allow");
    assert.equal(f.frames.length, before);
  });
});

test("attaching resumes the exact native UUID and never invents a missing session", async t => {
  const id = "11111111-2222-4333-8444-555555555555";
  const f = await fixture(t);
  const params = { sessionId: id, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project };
  await assert.rejects(f.bridge.request("project/session/attach", params), /no longer available/);
  assert.equal(f.sessions.values.size, 0);
  const g = await fixture(t, { transcripts: {} });
  g.bridge.withSdk = action => action({ getSessionInfo: async () => ({ sessionId: id, cwd: g.primary, lastModified: 1 }) });
  const attached = await g.bridge.request("project/session/attach", { ...params, wonderPolicy: g.policy, wonderProject: { cwd: g.primary } });
  assert.equal(attached.thread.sessionId, id);
  const again = await g.bridge.request("project/session/attach", { ...params, wonderPolicy: g.policy, wonderProject: { cwd: g.primary } });
  assert.equal(again.thread.id, attached.thread.id);
  assert.equal(g.sessions.get(attached.thread.id).sdkStarted, true);
});

test("listing reads metadata only and keeps exact folders", async t => {
  const f = await fixture(t);
  const transcripts = { a: { cwd: f.primary, title: "Newer", updatedAt: 3000 }, b: { cwd: `${f.primary}-sibling`, title: "Other", updatedAt: 9000 },
    c: { cwd: f.secondary, title: "Docs", updatedAt: 1000 }, d: { cwd: f.primary, title: "Bot", updatedAt: 5000 } };
  const g = await fixture(t, { transcripts });
  Object.values(transcripts).forEach(s => { if (s.cwd === f.primary) s.cwd = g.primary; if (s.cwd === f.secondary) s.cwd = g.secondary; });
  const result = await g.bridge.request("project/sessions/list", { dirs: [g.primary, g.secondary], limit: 10, excludeSessionIds: ["d"] });
  assert.deepEqual(result.data.map(s => s.sessionId), ["a", "c"]);
  assert.equal(g.capturedOptions.length, 0);
});

test("native history includes Claude Code turns and reuses Wonder receipts by identity", () => {
  const turns = nativeTurns([
    { type: "user", uuid: "turn-1", message: { content: "From Wonder" } },
    { type: "assistant", uuid: "a1", message: { id: "msg-1", content: [{ type: "thinking", thinking: "..." }] } },
    { type: "assistant", uuid: "a2", message: { id: "msg-1", content: [{ type: "text", text: "Done" }] } },
    { type: "user", uuid: "cli-1", message: { content: [{ type: "text", text: "From the terminal" }] } },
    { type: "assistant", uuid: "a3", message: { id: "msg-2", content: [{ type: "tool_use", id: "tool-1", name: "Bash", input: { command: "ls" } }] } },
    { type: "user", uuid: "r1", message: { content: [{ type: "tool_result", tool_use_id: "tool-1", content: "ok" }] } },
    // A proposed plan is a plan item under the tool call's ID, like the live stream; a call without text shows nothing.
    { type: "assistant", uuid: "a4", message: { id: "msg-3", content: [{ type: "tool_use", id: "plan-1", name: "ExitPlanMode", input: { plan: "# Plan\n1. Fix it" } },
      { type: "tool_use", id: "plan-2", name: "ExitPlanMode", input: {} }] } },
    { type: "user", uuid: "r2", message: { content: [{ type: "tool_result", tool_use_id: "plan-1", is_error: true, content: "Owner reviews the plan" }] } },
  ], [{ id: "turn-1", status: "completed", items: [{ type: "userMessage", id: "u-1", clientId: "client-1", content: [] }] }]);
  assert.deepEqual(turns.map(t => t.id), ["turn-1", "cli-1"]);
  assert.deepEqual(turns[1].items.slice(2), [{ type: "plan", id: "plan-1", text: "# Plan\n1. Fix it", status: "completed" }]);
  assert.equal(turns[0].items[0].clientId, "client-1");
  // Same ID shape as the live stream: turn:message:content-block-index.
  assert.equal(turns[0].items[1].id, "turn-1:msg-1:1");
  // Shell commands use Codex's command row: the command and its output.
  assert.deepEqual(turns[1].items[1], { type: "commandExecution", id: "tool-1", command: "ls", status: "completed", success: true, aggregatedOutput: "ok" });
});

test("text between Claude tool calls is commentary; text after the last one is the reply", () => {
  const [turn] = nativeTurns([
    { type: "user", uuid: "turn-1", message: { content: "Fix it" } },
    { type: "assistant", uuid: "a1", message: { id: "m1", content: [{ type: "text", text: "Looking" },
      { type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } }] } },
    { type: "assistant", uuid: "a2", message: { id: "m2", content: [{ type: "text", text: "Now editing" },
      { type: "tool_use", id: "t2", name: "Read", input: { file_path: "/p/a" } }] } },
    { type: "assistant", uuid: "a3", message: { id: "m3", content: [{ type: "text", text: "Done" }] } },
  ]);
  const messages = turn.items.filter(item => item.type === "agentMessage");
  assert.deepEqual(messages.map(item => [item.text, item.phase]), [["Looking", "commentary"], ["Now editing", "commentary"], ["Done", undefined]]);
});

test("Claude file tools become file changes with patches, including failures", () => {
  const turns = nativeTurns([
    { type: "user", uuid: "turn-1", message: { content: "Edit" } },
    { type: "assistant", uuid: "a1", message: { id: "m1", content: [
      { type: "tool_use", id: "w", name: "Write", input: { file_path: "/p/new.txt", content: "one\ntwo\n" } },
      { type: "tool_use", id: "e", name: "Edit", input: { file_path: "/p/a.swift", old_string: "let a = 1", new_string: "let a = 2\nlet b = 3" } },
      { type: "tool_use", id: "m", name: "MultiEdit", input: { file_path: "/p/b.swift", edits: [{ old_string: "x", new_string: "y" }, { old_string: "z", new_string: "" }] } },
      { type: "tool_use", id: "r", name: "Read", input: { file_path: "/p/a.swift" } }] } },
    { type: "user", uuid: "r1", message: { content: [{ type: "tool_result", tool_use_id: "e", is_error: true, content: "String not found" }] } },
  ]);
  const [write, edit, multi, read] = turns[0].items.slice(1);
  assert.deepEqual(write.changes, [{ path: "/p/new.txt", kind: { type: "add" }, diff: "one\ntwo\n" }]);
  assert.equal(edit.changes[0].diff, "@@ @@\n-let a = 1\n+let a = 2\n+let b = 3");
  assert.equal(edit.status, "failed");
  assert.equal(edit.error.message, "String not found");
  assert.equal(multi.changes[0].diff, "@@ @@\n-x\n+y\n@@ @@\n-z");
  assert.equal(read.type, "mcpToolCall");
});

test("project search is allowed only where no protected folder can be traversed", async t => {
  const f = await fixture(t);
  const denied = join(f.primary, "secrets");
  await mkdir(denied);
  const policy = new ToolPolicy({ ...f.policy, cwd: f.primary, deniedRoots: [denied], project: true });
  assert.equal(await policy.decision("Grep", { path: f.secondary }), "allow");
  assert.equal(await policy.decision("Glob", { path: f.primary }), "deny");
  const bot = new ToolPolicy({ ...f.policy, cwd: f.primary, deniedRoots: [] });
  assert.equal(await bot.decision("Grep", { path: f.secondary }), "deny");
});

test("folder suggestions exclude programmatic sessions and keep the latest activity", async t => {
  const f = await fixture(t);
  let options;
  f.bridge.withSdk = action => action({ listSessions: async o => { options = o; return [
    { sessionId: "a", cwd: "/work/app", lastModified: 5000 }, { sessionId: "b", cwd: "/work/app", lastModified: 9000 },
    { sessionId: "c", cwd: "/work/site", lastModified: 7000 }, { sessionId: "d", cwd: "relative", lastModified: 9999 }]; } });
  const result = await f.bridge.request("project/folders/list", { limit: 5 });
  assert.equal(options.includeProgrammatic, false);
  assert.deepEqual(result.data, [{ cwd: "/work/app", updatedAt: 9 }, { cwd: "/work/site", updatedAt: 7 }]);
});

// Project inputs can read only their own Wonder media inside protected data.
// This exercises the same policy used by image conversion and native Read.
test("project attachments keep other conversations and Bot homes protected", async t => {
  const f = await fixture(t);
  const data = join(f.root, "private"), media = join(data, "project-media", "owned"), other = join(data, "bots", "other");
  await mkdir(media, { recursive: true }); await mkdir(other, { recursive: true });
  const file = join(media, "attachment"), secret = join(other, "secret");
  await writeFile(file, "attachment"); await writeFile(secret, "secret");
  const policy = new ToolPolicy({ ...f.policy, cwd: f.primary, workspace: media, deniedRoots: [data], project: true });
  assert.equal(await policy.permits(file), true);
  assert.equal(await policy.permits(file, true), false);
  assert.equal(await policy.permits(secret), false);
  assert.equal(await policy.decision("Grep", { path: media }), "deny");
  await symlink(secret, join(media, "escape"));
  assert.equal(await policy.permits(join(media, "escape")), false);
});

const notice = (toolUseId, status, summary) => ({ type: "user", uuid: `n-${toolUseId}`, isQueuedCommand: true,
  origin: { kind: "task-notification", producer: "session-task" },
  message: { content: `<task-notification>\n<task-id>b1</task-id>\n<tool-use-id>${toolUseId}</tool-use-id>\n<output-file>/tmp/x</output-file>\n<status>${status}</status>\n<summary>${summary}</summary>\n</task-notification>` } });

// Background-task notices and the interrupt marker are runtime events, not
// owner messages; tasks come from the tool calls and their notices.
test("native history hides runtime notices and records background tasks", () => {
  const messages = [
    { type: "user", uuid: "turn-1", origin: { kind: "human" }, message: { content: "Build and test" } },
    { type: "assistant", uuid: "a1", message: { id: "m1", content: [
      { type: "tool_use", id: "bg-1", name: "Bash", input: { command: "make", description: "Build the app", run_in_background: true } },
      { type: "tool_use", id: "bg-2", name: "Bash", input: { command: "make test", description: "Run tests", run_in_background: true } },
      { type: "tool_use", id: "agent-1", name: "Agent", input: { description: "Review code", subagent_type: "Explore", prompt: "Look" } },
      { type: "tool_use", id: "fg", name: "Bash", input: { command: "ls" } }] } },
    { type: "user", uuid: "r1", message: { content: [{ type: "tool_result", tool_use_id: "bg-1", content: "Command running in background" },
      { type: "tool_result", tool_use_id: "agent-1", content: [{ type: "text", text: "Looks fine" }] }] } },
    notice("bg-1", "completed", "Background command \"Build the app\" completed (exit code 0)"),
    { type: "user", uuid: "stop", message: { content: [{ type: "text", text: "[Request interrupted by user]" }] } },
    { type: "user", uuid: "turn-2", origin: { kind: "human" }, message: { content: "Continue" } },
  ];
  const turns = nativeTurns(messages, []);
  assert.deepEqual(turns.map(t => t.id), ["turn-1", "turn-2"]);
  assert.equal(turns[0].status, "interrupted");
  assert.ok(!JSON.stringify(turns).includes("task-notification"));
  const live = backgroundTasks(messages, true);
  assert.deepEqual(live.map(t => [t.id, t.kind, t.status]), [["agent-1", "agent", "completed"], ["bg-2", "command", "running"], ["bg-1", "command", "completed"]]);
  assert.equal(live[2].summary, "Background command \"Build the app\" completed (exit code 0)");
  assert.equal(live[0].role, "Explore");
  // Once the session stops working on the Mac, a task without a notice is unknown.
  assert.equal(backgroundTasks(messages, false).find(t => t.id === "bg-2").status, "unknown");
});

test("desktop session liveness reads only Claude Code's busy session records", async t => {
  const dir = await mkdtemp(join(tmpdir(), "wonder-claude-sessions-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const record = (pid, sessionId, status) => writeFile(join(dir, `${pid}.json`), JSON.stringify({ pid, sessionId, status }));
  await record(process.pid, "live", "busy");
  await writeFile(join(dir, `${process.pid}.abc.key`), "{}");
  assert.equal(await claudeSessionBusy("live", dir), true);
  await record(process.pid, "live", "idle");
  assert.equal(await claudeSessionBusy("live", dir), false);
  await rm(join(dir, `${process.pid}.json`));
  await record(2147483646, "dead", "busy");
  assert.equal(await claudeSessionBusy("dead", dir), false, "A record from an exited process is not running");
  assert.equal(await claudeSessionBusy("missing", join(dir, "absent")), false);
});

test("a desktop-busy Claude session shows its turn running elsewhere and refuses a second writer", async t => {
  const f = await fixture(t, { transcripts: {} });
  const dir = await mkdtemp(join(tmpdir(), "wonder-claude-sessions-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const sdkSessionId = "11111111-2222-3333-4444-555555555555";
  const messages = [{ type: "user", uuid: "turn-1", origin: { kind: "human" }, message: { content: "Working on the Mac" } },
    { type: "assistant", uuid: "a1", message: { id: "m1", content: [{ type: "text", text: "Starting" }] } }];
  const sdk = { getSessionMessages: async () => messages, getSessionInfo: async (id, { dir: cwd }) => ({ sessionId: id, cwd, lastModified: 1 }) };
  const bridge = new ClaudeBridge({ updates: { acquire: async () => ({ runtime: { sdk }, release: async () => {} }) },
    sessions: f.sessions, send: async () => {}, claudeSessionsDir: dir });
  const { thread } = await bridge.request("project/session/attach", { sessionId: sdkSessionId, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });
  await writeFile(join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: sdkSessionId, status: "busy" }));
  const { data } = await bridge.request("thread/turns/list", { threadId: thread.id, itemsView: "notLoaded" });
  assert.equal(data[0].status, "inProgress");
  assert.equal(data[0].runningElsewhere, true);
  await assert.rejects(bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Another" }] }), /working on this conversation on your Mac/);
  await writeFile(join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: sdkSessionId, status: "idle" }));
  const idle = await bridge.request("thread/turns/list", { threadId: thread.id, itemsView: "notLoaded" });
  assert.equal(idle.data[0].status, "completed");
  assert.equal(idle.data[0].runningElsewhere, undefined);
});

test("turns and agent tasks from before a compaction stay visible", async t => {
  const root = await mkdtemp(join(tmpdir(), "wonder-claude-projects-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cwd = "/work/My App", id = "11111111-2222-4333-8444-555555555555";
  const folder = join(root, projectFolderName(cwd));
  await mkdir(join(folder, id, "subagents"), { recursive: true });
  const rows = [
    { type: "user", uuid: "u1", parentUuid: null, message: { role: "user", content: "Research the bug" }, timestamp: "2026-10-01T00:00:00Z" },
    { type: "assistant", uuid: "a1", parentUuid: "u1", message: { id: "m1", content: [{ type: "tool_use", id: "tu-a", name: "Agent", input: { description: "Find it", prompt: "Look", subagent_type: "Explore" } }] } },
    { type: "assistant", uuid: "a2", parentUuid: "a1", message: { id: "m1", content: [{ type: "tool_use", id: "tu-b", name: "Bash", input: { command: "make" } }] } },
    // Parallel results branch off their own tool calls.
    { type: "user", uuid: "r1", parentUuid: "a1", message: { content: [{ type: "tool_result", tool_use_id: "tu-a", content: "Async agent launched successfully. agentId: x1" }] } },
    { type: "user", uuid: "r2", parentUuid: "a2", message: { content: [{ type: "tool_result", tool_use_id: "tu-b", content: "built" }] } },
    { type: "user", uuid: "side", parentUuid: "r2", isSidechain: true, message: { content: "child" } },
    { type: "user", uuid: "meta", parentUuid: "r2", isMeta: true, message: { content: "caveat" } },
    { type: "system", uuid: "b1", parentUuid: null, logicalParentUuid: "meta", subtype: "compact_boundary" },
    { type: "user", uuid: "s1", parentUuid: "b1", isCompactSummary: true, message: { content: "Summary" } },
    { type: "user", uuid: "u2", parentUuid: "s1", message: { role: "user", content: "Continue" } },
  ];
  await writeFile(join(folder, `${id}.jsonl`), rows.map(r => JSON.stringify(r)).join("\n") + "\n");
  await writeFile(join(folder, id, "subagents", "agent-x1.meta.json"), JSON.stringify({ agentType: "Explore", description: "Find it", toolUseId: "tu-a", requestShape: "background" }));
  await writeFile(join(folder, id, "subagents", "agent-x1.jsonl"), [
    { type: "user", timestamp: "2026-10-01T00:00:01Z", message: { content: "Look" } },
    { type: "assistant", message: { stop_reason: "end_turn", content: [{ type: "text", text: "Found" }] } }].map(r => JSON.stringify(r)).join("\n"));
  await writeFile(join(folder, id, "subagents", "agent-..%2f.meta.json"), "{}");
  const files = new ClaudeSessionFiles(root);
  const earlier = await files.earlierMessages(id, cwd, "u2");
  assert.deepEqual(earlier.map(m => m.uuid), ["u1", "a1", "a2", "r1", "r2"]);
  const recent = [{ type: "user", uuid: "u2", message: { content: "Continue" } }];
  assert.deepEqual(nativeTurns([...earlier, ...recent]).map(t => t.id), ["u1", "u2"]);
  const agents = await files.agentTasks(id, cwd);
  assert.deepEqual(agents.map(a => [a.agentId, a.finished, a.startedAt]), [["x1", true, "2026-10-01T00:00:01Z"]]);
  // The launch acknowledgement neither completes the agent nor becomes its result.
  const live = backgroundTasks(earlier, true, [{ ...agents[0], finished: false }]);
  assert.deepEqual(live.map(t => [t.id, t.kind, t.status, t.role, t.taskId]), [["tu-a", "agent", "running", "Explore", "x1"]]);
  assert.equal(live[0].result, null);
  assert.equal(backgroundTasks([], false, agents)[0].status, "completed");
  // Appending reads only the new line and keeps the parsed history.
  await writeFile(join(folder, `${id}.jsonl`), rows.concat([{ type: "user", uuid: "u3", parentUuid: "u2", message: { content: "More" } }]).map(r => JSON.stringify(r)).join("\n") + "\n");
  assert.deepEqual((await files.earlierMessages(id, cwd, "u3")).map(m => m.uuid), ["u1", "a1", "a2", "r1", "r2", "u2"]);
  assert.deepEqual(await files.earlierMessages("not-a-uuid", cwd, "u2"), []);
});

// Project dispatch must retain the registered adapter, not replace its MCP
// servers with an empty inventory. The peer is local and runs no model work.
test("Projects retain the host-owned native computer adapter", async t => {
  const f = await fixture(t);
  f.gate.current = Promise.withResolvers();
  const { thread } = await f.bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku",
    wonderPolicy: f.policy, wonderProject: f.project });
  await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Fixture" }],
    config: { "mcp_servers.cua_repl": { enabled: true, command: process.execPath,
      args: [fileURLToPath(new URL("fixtures/native-cua-peer.mjs", import.meta.url)), join(f.root, "peer.jsonl")],
      enabled_tools: ["js", "js_reset", "turn_ended"] } } });
  try {
    while (!f.capturedOptions.length) await new Promise(resolve => setImmediate(resolve));
    const options = f.capturedOptions[0];
    assert.equal(options.systemPrompt.preset, "claude_code");
    assert.match(options.systemPrompt.append, /fresh runtime/);
    assert.ok(options.mcpServers.cua_repl.tools.some(tool => tool.name === "js"));
    const input = { code: "fixture" };
    const ctx = { toolUseID: "owned", mcpServer: { name: "cua_repl", source: "sdk" } };
    assert.equal((await options.canUseTool("mcp__cua_repl__js", input, ctx)).behavior, "allow");
    assert.equal((await options.canUseTool("mcp__cua_repl__js", input,
      { ...ctx, mcpServer: { name: "cua_repl", source: "user" } })).behavior, "deny");
  } finally { f.gate.current.resolve(); await f.bridge.active.get(thread.id)?.finished; }
});
