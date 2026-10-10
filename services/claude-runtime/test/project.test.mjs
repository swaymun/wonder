import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile, symlink } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { Sessions } from "../sessions.mjs";
import { ClaudeBridge, withLiveRoster } from "../bridge.mjs";
import { ToolPolicy } from "../permissions.mjs";
import { backgroundTasks, claudeSessionBusy, claudeSessionState, mainTurnRunning, nativeTurns, sessionSummary, turnEndMessageId } from "../project-history.mjs";
import { ClaudeSessionFiles, projectFolderName } from "../session-file.mjs";
import { TurnProjection } from "../projection.mjs";

// Contract owner: project conversations continue the owner's native Claude Code
// session by exact UUID, read history from that transcript, and never receive
// Bot instructions or tools.
async function fixture(t, { transcripts = {}, claudeSessionsDir = undefined } = {}) {
  const gate = { current: null };
  const root = await mkdtemp(join(tmpdir(), "wonder-project-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const primary = join(root, "app"), secondary = join(root, "docs");
  await mkdir(primary); await mkdir(secondary);
  const sessions = await new Sessions(join(root, "sessions")).initialize();
  const frames = [], inputs = [], capturedOptions = [], interrupts = [], closes = [];
  const lingers = { current: false }; // The fake process stays up after a reply, as Claude Code does.
  const emitQueue = [], emitWaiters = [];
  const emits = { push: message => (emitWaiters.shift() ?? (m => emitQueue.push(m)))(message),
    next: () => emitQueue.length ? Promise.resolve(emitQueue.shift()) : new Promise(resolve => emitWaiters.push(resolve)) };
  const sdk = {
    tool: (name, _description, _schema, handler) => ({ name, handler }), createSdkMcpServer: ({ tools }) => ({ tools }),
    listSessions: async ({ dir }) => Object.entries(transcripts).filter(([, s]) => s.cwd === dir)
      .map(([sessionId, s]) => ({ sessionId, summary: s.title, lastModified: s.updatedAt, cwd: s.cwd })),
    getSessionInfo: async (id, { dir }) => transcripts[id]?.cwd === dir ? { sessionId: id, cwd: dir, lastModified: 1 } : undefined,
    getSessionMessages: async id => transcripts[id]?.messages ?? [],
    query: ({ prompt, options }) => {
      capturedOptions.push(options);
      let interrupted = false;
      const query = (async function* () {
        const prompts = prompt[Symbol.asyncIterator]();
        let nextPrompt = prompts.next(), nextEmit = null;
        for (;;) {
          // Messages the process produces on its own, such as an agent finishing.
          nextEmit ??= emits.next();
          const got = await Promise.race([nextPrompt, nextEmit.then(message => ({ emitted: message }))]);
          if (got.emitted) { nextEmit = null; yield got.emitted; continue; }
          if (got.done) return;
          const input = got.value;
          inputs.push(input);
          yield { type: "system", subtype: "init", session_id: options.sessionId ?? options.resume };
          // While held, the process can still report what an agent does.
          for (let held = gate.current; held;) {
            nextEmit ??= emits.next();
            const event = await Promise.race([held.promise.then(() => null), nextEmit]);
            if (!event) break;
            nextEmit = null; yield event;
          }
          if (interrupted) { // Like Claude Code: the interrupt result, then the process stays up.
            interrupted = false;
            yield { type: "result", subtype: "error_during_execution", is_error: true, user_message_uuid: input.uuid };
            nextPrompt = prompts.next();
            continue;
          }
          yield { type: "result", subtype: "success" }; // A leftover background notice.
          yield { type: "assistant", user_message_uuid: input.uuid,
            message: { id: "reply", content: [{ type: "text", text: "Answered the new prompt." }] } };
          yield { type: "result", subtype: "success", user_message_uuid: input.uuid };
          if (!lingers.current) return;
          nextPrompt = prompts.next();
        }
      })();
      query.initializationResult = async () => ({});
      query.accountInfo = async () => ({ apiProvider: "firstParty", subscriptionType: "Claude Max" });
      query.close = () => { closes.push(1); };
      query.interrupt = async () => { interrupts.push(1); interrupted = true; gate.current?.resolve(); };
      return query;
    },
  };
  const updates = { acquire: async () => ({ runtime: { sdk }, release: async () => {} }) };
  const bridge = new ClaudeBridge({ updates, sessions, send: async frame => { frames.push(frame); }, claudeSessionsDir, yieldCheckMs: 20 });
  const policy = { mode: "workspace", approvalMode: "ask", readRoots: ["/"], writeRoots: [primary, secondary], deniedRoots: [] };
  const project = { cwd: primary, additionalDirectories: [secondary] };
  return { root, primary, secondary, sessions, bridge, frames, inputs, capturedOptions, interrupts, closes, lingers, emits, policy, project, gate };
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
  // Projects offer a per-task Stop, so a turn interrupt may spare background agents.
  assert.equal(options.perTaskStopAffordance, true);
  assert.equal(options.sessionId, thread.sessionId);
  assert.equal(f.inputs[0].uuid, turn.id);
  const saved = f.sessions.get(thread.id).turns[0];
  assert.equal(saved.status, "completed");
  assert.ok(saved.items.some(item => item.type === "agentMessage" && item.text === "Answered the new prompt."));
  // A project cannot be moved to another folder by a later turn.
  await assert.rejects(f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "x" }],
    wonderProject: { cwd: f.secondary } }), /keeps its working folder/);
});

// Contract: a Project turn offers Claude the daemon's thread tools under the
// `wonder` server, and nothing else the daemon happens to register; a call
// round-trips through the daemon only after its permission check.
test("project turns expose only the thread tools and route them through the daemon", async t => {
  const f = await fixture(t);
  const names = ["wonder_thread_list", "wonder_thread_read", "wonder_thread_send", "wonder_thread_wait", "wonder_delegate"];
  const spec = name => ({ name, description: name, inputSchema: { type: "object", properties: { limit: { type: "integer" } } } });
  const { thread } = await f.bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });
  f.gate.current = Promise.withResolvers();
  await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Delegate it" }],
    dynamicTools: [...names.map(spec), spec("wonder_ask_question"), spec("wonder_computer_use")] });
  while (!f.capturedOptions.length) await new Promise(resolve => setImmediate(resolve));
  const options = f.capturedOptions[0];
  assert.deepEqual(options.mcpServers.wonder.tools.map(tool => tool.name), names);
  const list = options.mcpServers.wonder.tools[0].handler;
  const origin = { name: "wonder", source: "sdk" };
  assert.equal((await options.canUseTool("mcp__wonder__wonder_thread_list", {}, { toolUseID: "forged", mcpServer: { name: "wonder", source: "user" } })).behavior, "deny");
  assert.equal((await options.canUseTool("mcp__wonder__wonder_thread_list", { limit: 5 }, { toolUseID: "call-1", mcpServer: origin })).behavior, "allow");
  const answered = list({ limit: 5 });
  await new Promise(resolve => setImmediate(resolve));
  const call = f.frames.find(frame => frame.method === "item/tool/call");
  assert.equal(call.params.tool, "wonder_thread_list");
  assert.equal(call.params.callId, "call-1");
  assert.deepEqual(call.params.arguments, { limit: 5 });
  await f.bridge.receive({ id: call.id, result: { success: true, contentItems: [{ type: "inputText", text: '{"threads":[]}' }] } });
  assert.equal((await answered).isError, false);
  f.gate.current.resolve();
  await f.bridge.active.get(thread.id)?.finished;
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

test("images the owner attaches in Claude Code reach the prompt, bounded", () => {
  // Shapes recorded by Claude Code and the Claude desktop app: base64 image
  // blocks beside or instead of the typed words (paste ids shortened).
  const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
  const image = (media_type, data = png) => ({ type: "image", source: { type: "base64", media_type, data } });
  const turns = nativeTurns([
    { type: "user", uuid: "u1", imagePasteIds: [1], origin: { kind: "human" },
      message: { role: "user", content: [image("image/webp"), { type: "text", text: "What is in [Image #1]?" }] } },
    { type: "assistant", uuid: "a1", message: { id: "m1", content: [{ type: "text", text: "A cat." }] } },
    // An image alone is still a prompt; the reply belongs to it, not the turn before.
    { type: "user", uuid: "u2", imagePasteIds: [1, 2], message: { role: "user", content: [image("image/png"), image("image/png", "A".repeat(11_184_816))] } },
    { type: "assistant", uuid: "a2", message: { id: "m2", content: [{ type: "tool_use", id: "t1", name: "Read", input: { file_path: "/p/shot.png" } }] } },
    // A tool's image result is the tool's output, not something the owner attached.
    { type: "user", uuid: "r1", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: [image("image/png")] }] } },
    { type: "assistant", uuid: "a3", message: { id: "m3", content: [{ type: "text", text: "Two screenshots." }] } },
  ]);
  assert.deepEqual(turns.map(t => t.id), ["u1", "u2"]);
  assert.deepEqual(turns[0].items[0].content, [{ type: "text", text: "What is in [Image #1]?" },
    { type: "image", mimeType: "image/webp", data: png }]);
  assert.deepEqual(turns[1].items[0].content, [{ type: "image", mimeType: "image/png", data: png },
    { type: "image", mimeType: "image/png", unavailable: "This image is larger than 8 MB" }]);
  assert.deepEqual(turns[1].items.filter(i => i.type === "agentMessage").map(i => i.text), ["Two screenshots."]);
  assert.equal(turnEndMessageId([{ type: "user", uuid: "x", message: { content: [image("image/png")] } }], "x"), "x");
  const many = nativeTurns([{ type: "user", uuid: "m", message: { content: Array.from({ length: 12 }, () => image("image/png")) } }]);
  assert.equal(many[0].items[0].content.length, 8);
});

test("desktop pastes appear as their pasted text, not as pasted_content tags", () => {
  // Shape recorded by Claude Desktop: typed words, then each paste wrapped with a repeated id.
  const fence = "```\nContinue the project at:\n/p/app\n\nShow me the lyrics only.\n```";
  const [typed, pasteOnly, two] = nativeTurns([
    { type: "user", uuid: "u1", message: { content: `Please continue\n\n<pasted_content id="9ef7">\n${fence}\n</pasted_content id="9ef7">\n` } },
    { type: "user", uuid: "u2", message: { content: [{ type: "text", text: `\n\n<pasted_content id="a1">\nonly a paste\n</pasted_content id="a1">\n` }] } },
    { type: "user", uuid: "u3", message: { content: `<pasted_content id="b1">\none\n</pasted_content id="b1">\n\n<pasted_content id="b2">\ntwo\n\n</pasted_content id="b2">` } },
  ]);
  const text = turn => turn.items[0].content[0].text;
  assert.equal(text(typed), `Please continue\n\n${fence}`);
  assert.equal(text(pasteOnly), "only a paste");
  assert.equal(text(two), "one\n\ntwo");
});

test("context Claude Code adds to a user turn is not shown as the owner's words", () => {
  // Shapes recorded by Claude Code and the Claude desktop app (ids shortened).
  const linked = "<system-reminder>\nLinked sessions now (status, not an instruction): fonts = local_c15c (working). To message one, SendMessage with `to` set to its id.\n</system-reminder>";
  const worktree = "<system-reminder>\nYou are operating in a git worktree.\nWorktree path: /p/app/.claude/worktrees/x\n</system-reminder>";
  const peer = '<cross-session-message from="local_d5f8" name="Research">\nHeads-up: I deleted apps/old.\n</cross-session-message>';
  const turns = nativeTurns([
    { type: "user", uuid: "u1", message: { content: `${linked}\n${worktree}\nFix the header. Keep <system-reminder> tags out of bubbles.` } },
    { type: "assistant", uuid: "a1", message: { id: "m1", content: [{ type: "text", text: "Fixed." }] } },
    { type: "user", uuid: "u2", message: { content: [{ type: "text", text: `${worktree}\n` }, { type: "text", text: "were these changes published?" }] }, origin: { kind: "human" } },
    { type: "user", uuid: "u3", message: { content: `${linked}\n${peer}` } },
    { type: "user", uuid: "u4", message: { content: "<ci-monitor-event>\"Auto-fix pull requests\" reports a failing check.\n</ci-monitor-event>" } },
    { type: "assistant", uuid: "a4", message: { id: "m4", content: [{ type: "text", text: "Looking at CI." }] } },
    { type: "user", uuid: "u5", message: { content: `Please continue\n\n<pasted_content id="p1">\n${worktree}\n</pasted_content id="p1">` } },
  ]);
  const prompt = turn => turn.items[0].content[0].text;
  // Injected blocks go; a tag the owner typed inline stays. Context-only entries open no turn.
  assert.deepEqual(turns.map(t => t.id), ["u1", "u2", "u5"]);
  assert.equal(prompt(turns[0]), "Fix the header. Keep <system-reminder> tags out of bubbles.");
  assert.equal(prompt(turns[1]), "were these changes published?");
  assert.deepEqual(turns[1].items.slice(1).map(i => i.text), ["Looking at CI."]);
  // Text the owner pasted is theirs, even when it looks like a reminder.
  assert.equal(prompt(turns[2]), `Please continue\n\n${worktree}`);
  assert.equal(turnEndMessageId([{ type: "user", uuid: "u3", message: { content: linked } }], "u3"), null);
  assert.equal(sessionSummary({ sessionId: "s", firstPrompt: `${worktree}\nRename the app`, lastModified: 1000 }).title, "Rename the app");
});

test("a shell or slash command and its output form one turn whose prompt keeps the command markup", () => {
  // Shapes recorded by Claude Code: `!` runs, local and prompt slash commands (meta entries are filtered upstream).
  const messages = [
    { type: "user", uuid: "c1", message: { content: "<bash-input>git status --short</bash-input>" } },
    { type: "user", uuid: "c1o", message: { content: "<bash-stdout> M README.md</bash-stdout><bash-stderr></bash-stderr>" } },
    { type: "user", uuid: "c2", message: { content: "<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args></command-args>" } },
    { type: "user", uuid: "c2o", message: { content: "<local-command-stdout>Set model to \u001b[1mOpus\u001b[22m</local-command-stdout>" } },
    { type: "user", uuid: "c3", message: { content: "<command-message>review is running…</command-message>\n<command-name>/review</command-name>\n<command-args>42</command-args>" } },
    { type: "assistant", uuid: "a3", message: { id: "m3", content: [{ type: "text", text: "Reviewed." }] } },
  ];
  const turns = nativeTurns(messages);
  assert.deepEqual(turns.map(t => t.id), ["c1", "c2", "c3"]);
  assert.equal(turns[0].items[0].content[0].text, "<bash-input>git status --short</bash-input>\n<bash-stdout> M README.md</bash-stdout><bash-stderr></bash-stderr>");
  assert.match(turns[1].items[0].content[0].text, /<command-name>\/model<\/command-name>[\s\S]*\n<local-command-stdout>Set model to/);
  assert.equal(turns[2].items.at(-1).text, "Reviewed.");
  // Forking at the shell command keeps its output.
  assert.equal(turnEndMessageId(messages, "c1"), "c1o");
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

// Shapes copied from a real Claude Code transcript: Edit records the hunk it
// applied (3 context lines, 14 added, 3 context), Write of a new file records
// "create". The pill must read +14 -0 and +2 -0, not the tool input's counts.
const historyHunk = { oldStart: 19, oldLines: 6, newStart: 19, newLines: 20, lines: [
  "             .fetch_optional(&self.pool).await", "     }", " ",
  ...Array.from({ length: 14 }, (_, i) => `+    line ${i}`), "     pub async fn next() {", "         todo!()", "     }"] };
const fileEditRows = () => [
  { type: "user", uuid: "turn-1", message: { content: "Edit" } },
  { type: "assistant", uuid: "a1", message: { id: "m1", content: [
    { type: "tool_use", id: "e", name: "Edit", input: { file_path: "/p/history.rs", old_string: "a\nb\nc\nd\ne\nf", new_string: "x".repeat(20).split("").join("\n") } },
    { type: "tool_use", id: "w", name: "Write", input: { file_path: "/p/new.rs", content: "one\ntwo\n" } },
    { type: "tool_use", id: "o", name: "Write", input: { file_path: "/p/old.rs", content: "kept\nnew\n" } },
    { type: "tool_use", id: "x", name: "Edit", input: { file_path: "/p/other.rs", old_string: "a", new_string: "b" } }] } },
  { type: "user", uuid: "r-e", message: { content: [{ type: "tool_result", tool_use_id: "e", content: "ok" }] },
    toolUseResult: { filePath: "/p/history.rs", oldString: "…", newString: "…", originalFile: null, structuredPatch: [historyHunk], userModified: false, replaceAll: false } },
  { type: "user", uuid: "r-w", message: { content: [{ type: "tool_result", tool_use_id: "w", content: "ok" }] },
    toolUseResult: { type: "create", filePath: "/p/new.rs", content: "one\ntwo\n", structuredPatch: [], originalFile: null } },
  { type: "user", uuid: "r-o", message: { content: [{ type: "tool_result", tool_use_id: "o", content: "ok" }] },
    toolUseResult: { type: "update", filePath: "/p/old.rs", content: "kept\nnew\n", originalFile: "kept\nold\n",
      structuredPatch: [{ oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [" kept", "-old", "+new"] }] } },
  // A result naming another file is not this edit's record.
  { type: "user", uuid: "r-x", message: { content: [{ type: "tool_result", tool_use_id: "x", content: "ok" }] },
    toolUseResult: { filePath: "/p/elsewhere.rs", structuredPatch: [{ oldStart: 1, oldLines: 0, newStart: 1, newLines: 9, lines: ["+z"] }] } },
];
const counts = diff => ["+", "-"].map(m => diff.split("\n").filter(l => l.startsWith(m)).length);

test("Claude file edits count the hunks Claude Code applied, from the transcript and live", async t => {
  // History: the SDK reader drops toolUseResult, so the session file restores it by uuid.
  const root = await mkdtemp(join(tmpdir(), "claude-edits-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const session = "11111111-2222-4333-8444-555555555555";
  await mkdir(join(root, projectFolderName("/p")));
  await writeFile(join(root, projectFolderName("/p"), `${session}.jsonl`), fileEditRows().map(r => JSON.stringify(r)).join("\n") + "\n");
  const edits = await new ClaudeSessionFiles(root).fileEdits(session, "/p");
  assert.deepEqual([...edits.keys()], ["r-e", "r-w", "r-o", "r-x"]);
  const fromSdk = fileEditRows().map(({ toolUseResult, ...row }) => edits.has(row.uuid) ? { ...row, tool_use_result: edits.get(row.uuid) } : row);
  const [edit, write, overwrite, other] = nativeTurns(fromSdk)[0].items.slice(1);
  assert.deepEqual(counts(edit.changes[0].diff), [14, 0]);
  assert.ok(edit.changes[0].diff.startsWith("@@ -19,6 +19,20 @@\n             .fetch_optional"));
  assert.deepEqual(write.changes[0], { path: "/p/new.rs", kind: { type: "add" }, diff: "one\ntwo\n" });
  assert.deepEqual([overwrite.changes[0].kind, counts(overwrite.changes[0].diff)], [{ type: "update" }, [1, 1]]);
  assert.equal(other.changes[0].diff, "@@ @@\n-a\n+b");

  // Live: the SDK hands the same record to the turn as tool_use_result.
  const events = [];
  const live = new TurnProjection({ threadId: "t", turnId: "turn", emit: e => events.push(e) });
  live.start();
  const [, assistant, editResult] = fileEditRows();
  live.accept({ ...assistant, type: "assistant" });
  live.accept({ type: "user", message: editResult.message, tool_use_result: editResult.toolUseResult });
  const done = events.find(e => e.method === "item/completed" && e.params.item.id === "e").params.item;
  assert.deepEqual(counts(done.changes[0].diff), [14, 0]);
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
  // A finished turn that grows (Claude's reply when a background task ends) changes its count.
  assert.deepEqual([idle.data[0].items, idle.data[0].itemCount], [[], 2]);
  messages.push({ type: "user", origin: { kind: "task-notification" }, message: { content: "<task-notification></task-notification>" } },
    { type: "assistant", uuid: "a2", message: { id: "m2", content: [{ type: "text", text: "The task finished" }] } });
  bridge.transcripts.clear();
  const grown = await bridge.request("thread/turns/list", { threadId: thread.id, itemsView: "notLoaded" });
  assert.deepEqual([grown.data[0].id, grown.data[0].itemCount], ["turn-1", 3]);
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

// Shape recorded by Claude Code: a resumed background agent notifies again under
// the resuming call's tool-use ID but keeps its task ID.
test("a resumed agent's later notice updates its task instead of adding a command row", () => {
  const agentNotice = (id, toolUseId, status, summary) => ({ type: "user", uuid: id,
    message: { content: `<task-notification>\n<task-id>a0b1c2</task-id>\n<tool-use-id>${toolUseId}</tool-use-id>\n<status>${status}</status>\n<summary>${summary}</summary>\n</task-notification>` } });
  const messages = [
    { type: "user", uuid: "turn-1", message: { content: "Go" } },
    { type: "assistant", uuid: "a1", timestamp: "2026-10-06T20:12:08Z", message: { id: "m1", content: [
      { type: "tool_use", id: "tu-agent", name: "Agent", input: { description: "Readiness pass", subagent_type: "general-purpose", prompt: "Do it", run_in_background: true } },
      { type: "tool_use", id: "tu-bg", name: "Bash", input: { command: "make build\nmake test", run_in_background: true } }] } },
    { type: "user", uuid: "r1", message: { content: [{ type: "tool_result", tool_use_id: "tu-agent",
      content: [{ type: "text", text: "Async agent launched successfully.\nagentId: a0b1c2 (internal ID)" }] }] } },
    agentNotice("n1", "tu-agent", "completed", 'Agent "Readiness pass" finished'),
    { type: "assistant", uuid: "a2", message: { id: "m2", content: [{ type: "tool_use", id: "tu-resume", name: "SendMessage", input: { to: "a0b1c2" } }] } },
    agentNotice("n2", "tu-resume", "failed", 'Agent "Readiness pass" failed: API error'),
  ];
  const tasks = backgroundTasks(messages, true);
  assert.deepEqual(tasks.map(t => [t.id, t.kind, t.title, t.status]), [
    ["tu-bg", "command", "make build", "running"], ["tu-agent", "agent", "Readiness pass", "failed"]]);
  // Without the launch in view, a notice that names an agent still makes an agent row.
  assert.equal(backgroundTasks([agentNotice("n3", "tu-gone", "completed", 'Agent "Old pass" finished')], true)[0].kind, "agent");
});

test("a running agent's unanswered tool call is in progress, answered ones are done", () => {
  const [turn] = nativeTurns([
    { type: "user", uuid: "p", message: { content: "Look" } },
    { type: "assistant", uuid: "a1", message: { id: "m1", content: [
      { type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } },
      { type: "tool_use", id: "t2", name: "Grep", input: { pattern: "x" } }] } },
    { type: "user", uuid: "r1", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] } },
  ], [], true);
  assert.deepEqual(turn.items.slice(1).map(i => [i.id, i.status]), [["t1", "completed"], ["t2", "inProgress"]]);
  const [done] = nativeTurns([
    { type: "user", uuid: "p", message: { content: "Look" } },
    { type: "assistant", uuid: "a1", message: { id: "m1", content: [{ type: "tool_use", id: "t2", name: "Grep", input: {} }] } },
  ], [], false);
  assert.equal(done.items[1].status, "completed");
});

test("Latest settings come from the newest assistant message and say who wrote it", async t => {
  const root = await mkdtemp(join(tmpdir(), "wonder-settings-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cwd = join(root, "app"), id = "11111111-2222-3333-4444-555555555555";
  const folder = join(root, projectFolderName(cwd));
  await mkdir(folder, { recursive: true });
  const assistant = (uuid, extra) => ({ type: "assistant", uuid, message: { model: "claude-opus-5-5", usage: { speed: "standard" } }, ...extra });
  const write = rows => writeFile(join(folder, `${id}.jsonl`), rows.map(r => JSON.stringify(r)).join("\n") + "\n");
  await write([assistant("a1", { entrypoint: "claude-desktop", effort: "xhigh" }),
    { type: "assistant", uuid: "a2", message: { model: "<synthetic>" }, entrypoint: "claude-desktop" },
    assistant("side", { isSidechain: true, effort: "low" })]);
  const files = new ClaudeSessionFiles(root);
  assert.deepEqual(await files.latestSettings(id, cwd), { turnId: "a1", native: true, model: "claude-opus-5-5", effort: "xhigh", speed: "standard" });
  await write([assistant("a1", { entrypoint: "claude-desktop", effort: "xhigh" }), assistant("a3", { entrypoint: "sdk-ts" })]);
  assert.deepEqual(await files.latestSettings(id, cwd), { turnId: "a3", native: false, model: "claude-opus-5-5", effort: null, speed: "standard" });
  assert.equal(await files.latestSettings("not-a-uuid", cwd), null);
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

const forkMessages = [
  { type: "user", uuid: "turn-1", origin: { kind: "human" }, message: { content: "First ask" } },
  { type: "assistant", uuid: "a1", message: { id: "m1", content: [{ type: "tool_use", id: "tu1", name: "Bash", input: { command: "ls" } }] } },
  { type: "user", uuid: "r1", message: { content: [{ type: "tool_result", tool_use_id: "tu1", content: "files" }] } },
  { type: "assistant", uuid: "a2", message: { id: "m2", content: [{ type: "text", text: "Done one" }] } },
  { type: "user", uuid: "turn-2", origin: { kind: "human" }, message: { content: "Second ask" } },
  { type: "assistant", uuid: "a3", message: { id: "m3", content: [{ type: "text", text: "Done two" }] } },
];

test("a fork ends at the last entry of the chosen turn, never inside the next one", () => {
  assert.deepEqual(nativeTurns(forkMessages).map(t => t.id), ["turn-1", "turn-2"]);
  assert.equal(turnEndMessageId(forkMessages, "turn-1"), "a2");
  assert.equal(turnEndMessageId(forkMessages, "turn-2"), "a3");
  assert.equal(turnEndMessageId(forkMessages, "r1"), null, "a tool result does not open a turn");
  assert.equal(turnEndMessageId(forkMessages, "missing"), null);
});

test("forking copies the native session through the chosen turn and leaves the source alone", async t => {
  const f = await fixture(t);
  const id = "11111111-2222-4333-8444-555555555555", forked = [];
  const claudeSessionsDir = await mkdtemp(join(tmpdir(), "wonder-claude-sessions-"));
  t.after(() => rm(claudeSessionsDir, { recursive: true, force: true }));
  const sdk = { getSessionMessages: async () => forkMessages, getSessionInfo: async (sessionId, { dir }) => ({ sessionId, cwd: dir, lastModified: 1 }),
    forkSession: async (sessionId, options) => { forked.push({ sessionId, options }); return { sessionId: "99999999-8888-4777-8666-555555555555" }; } };
  const bridge = new ClaudeBridge({ updates: { acquire: async () => ({ runtime: { sdk }, release: async () => {} }) },
    sessions: f.sessions, send: async () => {}, claudeSessionsDir });
  const { thread } = await bridge.request("project/session/attach", { sessionId: id, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });

  const first = await bridge.request("project/session/fork", { threadId: thread.id, lastTurnId: "turn-1", title: "Plan (fork)" });
  assert.equal(first.sessionId, "99999999-8888-4777-8666-555555555555");
  assert.deepEqual(forked[0], { sessionId: id, options: { dir: f.primary, upToMessageId: "a2", title: "Plan (fork)" } });
  await bridge.request("project/session/fork", { threadId: thread.id });
  assert.deepEqual(forked[1].options, { dir: f.primary }, "the latest turn copies the whole session");
  await assert.rejects(bridge.request("project/session/fork", { threadId: thread.id, lastTurnId: "gone" }), /no longer in this conversation/);
  assert.equal(forked.length, 2);
  assert.equal(f.sessions.get(thread.id).sdkSessionId, id, "the source keeps its session");

  bridge.active.set(thread.id, {});
  await assert.rejects(bridge.request("project/session/fork", { threadId: thread.id }), /Wait for Claude to finish/);
  bridge.active.delete(thread.id);
  const draft = await bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });
  await assert.rejects(bridge.request("project/session/fork", { threadId: draft.thread.id }), /Send a message first/);
});

// Contract: Wonder stops an agent task or background command only while it
// drives the session, through Claude Code's own stop_task control. A session
// running in Claude on the Mac keeps its own controls.
test("stopping an agent task or background command needs a session Wonder drives", async t => {
  const f = await fixture(t);
  const dir = await mkdtemp(join(tmpdir(), "wonder-claude-sessions-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const sdkSessionId = "11111111-2222-3333-4444-555555555555";
  const messages = [
    { type: "user", uuid: "turn-1", origin: { kind: "human" }, message: { content: "Go" } },
    { type: "assistant", uuid: "a1", timestamp: "2026-10-06T20:00:00Z", message: { id: "m1", content: [
      { type: "tool_use", id: "tu-agent", name: "Agent", input: { description: "Audit", subagent_type: "Explore", prompt: "Look", run_in_background: true } },
      { type: "tool_use", id: "tu-cmd", name: "Bash", input: { command: "make watch", run_in_background: true } },
      { type: "tool_use", id: "tu-done", name: "Bash", input: { command: "make", run_in_background: true } }] } },
    { type: "user", uuid: "r1", message: { content: [
      { type: "tool_result", tool_use_id: "tu-agent", content: [{ type: "text", text: "Async agent launched successfully.\nagentId: a0b1c2" }] },
      { type: "tool_result", tool_use_id: "tu-cmd", content: "Command running in background with ID: bwatch1. Output is being written to: /tmp/x" },
      { type: "tool_result", tool_use_id: "tu-done", content: "Command running in background with ID: bdone1." }] } },
    { type: "user", uuid: "n1", message: { content: "<task-notification>\n<task-id>bdone1</task-id>\n<tool-use-id>tu-done</tool-use-id>\n<status>completed</status>\n<summary>done</summary>\n</task-notification>" } },
  ];
  const sdk = { getSessionMessages: async () => messages, getSessionInfo: async (id, { dir: cwd }) => ({ sessionId: id, cwd, lastModified: 1 }) };
  const bridge = new ClaudeBridge({ updates: { acquire: async () => ({ runtime: { sdk }, release: async () => {} }) },
    sessions: f.sessions, send: async () => {}, claudeSessionsDir: dir });
  const { thread } = await bridge.request("project/session/attach", { sessionId: sdkSessionId, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });
  const list = async () => Object.fromEntries((await bridge.request("thread/backgroundTasks/list", { threadId: thread.id })).data.map(task => [task.id, task]));
  const stop = taskId => bridge.request("thread/backgroundTask/stop", { threadId: thread.id, taskId });

  // Nothing is running without a live session: states are unknown and Stop is refused.
  assert.equal((await list())["tu-cmd"].canStop, false);
  assert.equal((await stop("tu-cmd")).outcome, "notRunning");

  // Running in Claude on the Mac: explain instead of stopping.
  await writeFile(join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: sdkSessionId, status: "busy" }));
  const elsewhere = await list();
  assert.deepEqual([elsewhere["tu-cmd"].status, elsewhere["tu-cmd"].canStop, elsewhere["tu-cmd"].runningElsewhere], ["running", false, true]);
  assert.equal((await stop("tu-cmd")).outcome, "runningElsewhere");
  await writeFile(join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: sdkSessionId, status: "idle" }));

  // Wonder drives the session: running tasks with a task ID can stop; finished ones cannot.
  const stopped = [];
  bridge.active.set(thread.id, { turn: { id: "t" }, query: { stopTask: async id => { stopped.push(id); } } });
  const tasks = await list();
  assert.deepEqual(["tu-agent", "tu-cmd", "tu-done"].map(id => [tasks[id].status, tasks[id].canStop]),
    [["running", true], ["running", true], ["completed", false]]);
  assert.ok(!("taskId" in tasks["tu-cmd"]), "SDK task IDs stay inside the bridge");
  assert.equal((await stop("tu-done")).outcome, "notRunning");
  assert.equal((await stop("nope")).outcome, "notFound");
  assert.deepEqual(stopped, []);
  const result = await stop("tu-agent");
  assert.deepEqual(stopped, ["a0b1c2"]);
  assert.deepEqual([result.outcome, result.task.status], ["stopped", "interrupted"]);
  assert.equal((await list())["tu-agent"].status, "interrupted");
  await stop("tu-cmd");
  assert.deepEqual(stopped, ["a0b1c2", "bwatch1"]);
  assert.equal((await stop("tu-cmd")).outcome, "notRunning");
  assert.deepEqual(stopped, ["a0b1c2", "bwatch1"]);
  bridge.active.delete(thread.id);
});

// Like Claude Desktop, interrupting a reply ends the reply but spares running
// agents; the user stops each from the task list, and the next message joins
// the same Claude process instead of ending it.
const agentTranscript = (...extra) => [
  { type: "user", uuid: "turn-1", origin: { kind: "human" }, message: { content: "Go" } },
  { type: "assistant", uuid: "a1", timestamp: "2026-10-06T20:00:00Z", message: { id: "m1", content: [
    { type: "tool_use", id: "tu-agent", name: "Agent", input: { description: "Audit", subagent_type: "Explore", prompt: "Look", run_in_background: true } }] } },
  { type: "user", uuid: "r1", message: { content: [
    { type: "tool_result", tool_use_id: "tu-agent", content: [{ type: "text", text: "Async agent launched successfully.\nagentId: a0b1c2" }] }] } },
  { type: "user", uuid: "stop", message: { content: [{ type: "text", text: "[Request interrupted by user]" }] } },
  ...extra];
const settle = async (check) => { for (let i = 0; i < 400 && !check(); i++) await new Promise(resolve => setTimeout(resolve, 5)); };

async function interruptedAgent(t) {
  const f = await fixture(t);
  f.lingers.current = true;
  const { thread } = await f.bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });
  f.gate.current = Promise.withResolvers();
  const { turn } = await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Run it" }] });
  await settle(() => f.bridge.active.get(thread.id)?.query);
  const run = f.bridge.active.get(thread.id);
  f.emits.push({ type: "system", subtype: "task_started", task_type: "local_agent", task_id: "a0b1c2", tool_use_id: "tu-agent", description: "Audit" });
  await settle(() => run.children.size);
  await f.bridge.request("turn/interrupt", { threadId: thread.id, turnId: turn.id });
  await run.finished;
  let transcript = agentTranscript();
  f.bridge.projectMessages = async () => ({ messages: transcript, desktop: false });
  const stopped = [];
  f.bridge.lingering.get(thread.id).query.stopTask = async id => { stopped.push(id); };
  const list = async () => Object.fromEntries((await f.bridge.request("thread/backgroundTasks/list", { threadId: thread.id })).data.map(task => [task.id, task]));
  return { f, thread, stopped, list, setTranscript: value => { transcript = value; } };
}

test("interrupting a project turn spares a running agent and its card", async t => {
  const { f, thread, list } = await interruptedAgent(t);
  assert.equal(f.interrupts.length, 1);
  assert.equal(f.closes.length, 0, "the interrupt must not kill the Claude process");
  assert.equal(f.sessions.get(thread.id).turns.at(-1).status, "interrupted");
  assert.ok(f.bridge.lingering.has(thread.id));
  const agent = (await list())["tu-agent"];
  assert.deepEqual([agent.status, agent.canStop], ["running", true]);
  // The agent's activity card keeps running until the agent's own notice.
  const card = [...f.bridge.lingering.get(thread.id).children.values()][0];
  assert.equal(card.projection.terminal, false);
  assert.equal(f.frames.some(frame => frame.method === "item/completed" && frame.params.item?.type === "subAgentActivity"), false);
  await f.bridge.close();
});

test("a message after an interrupt joins the same Claude process and the agent stays stoppable", async t => {
  const { f, thread, stopped, list, setTranscript } = await interruptedAgent(t);
  const process = f.bridge.lingering.get(thread.id).query;
  f.gate.current = Promise.withResolvers();
  await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Next" }] });
  await settle(() => f.inputs.length === 2);
  assert.equal(f.capturedOptions.length, 1, "no second process");
  assert.equal(f.bridge.active.get(thread.id).query, process);
  assert.equal(f.closes.length, 0);
  assert.equal(f.inputs[1].message.content[0].text, "Next");
  const during = (await list())["tu-agent"];
  assert.deepEqual([during.status, during.canStop], ["running", true]);

  // The reply finishes while the agent still runs: the process stays, and Stop works.
  f.gate.current.resolve();
  await f.bridge.active.get(thread.id)?.finished;
  assert.equal(f.sessions.get(thread.id).turns.at(-1).status, "completed");
  assert.equal(f.closes.length, 0);
  assert.ok(f.bridge.lingering.has(thread.id));
  assert.equal((await f.bridge.request("thread/backgroundTask/stop", { threadId: thread.id, taskId: "tu-agent" })).outcome, "stopped");
  assert.deepEqual(stopped, ["a0b1c2"]);
  assert.equal((await list())["tu-agent"].status, "interrupted");

  // The agent's completion notice, then the process's own result, ends the process.
  setTranscript(agentTranscript({ type: "user", uuid: "n1", message: { content:
    "<task-notification>\n<task-id>a0b1c2</task-id>\n<tool-use-id>tu-agent</tool-use-id>\n<status>completed</status>\n<summary>Agent \"Audit\" done</summary>\n</task-notification>" } }));
  assert.equal((await list())["tu-agent"].status, "completed");
  f.emits.push({ type: "result", subtype: "success" });
  await settle(() => f.closes.length);
  assert.equal(f.closes.length, 1);
  assert.ok(!f.bridge.lingering.has(thread.id));
});

// A different model needs a different process: the SDK pins the model for a
// process's lifetime, so the spared agent ends with it. Documented restart.
test("changing the model after an interrupt starts a new process", async t => {
  const { f, thread } = await interruptedAgent(t);
  f.gate.current = null;
  await f.bridge.request("turn/start", { threadId: thread.id, model: "claude:sonnet", input: [{ type: "text", text: "Switch" }] });
  await f.bridge.active.get(thread.id)?.finished;
  assert.ok(f.closes.length >= 1, "the old process ended");
  assert.equal(f.capturedOptions.length, 2);
  assert.equal(f.capturedOptions[1].model, "sonnet");
});

// Owner: the agent-task list counts what Claude on the Mac counts as running:
// agents, background commands, monitors and linked sessions it started.
test("monitors and started linked sessions are tasks; proposals are not", () => {
  const messages = [
    { type: "user", uuid: "turn-1", origin: { kind: "human" }, message: { content: "Watch the build" } },
    { type: "assistant", uuid: "a1", timestamp: "2026-10-09T00:00:01Z", message: { content: [
      { type: "tool_use", id: "mon", name: "Monitor", input: { description: "Build errors", command: "tail -f build.log" } },
      { type: "tool_use", id: "linked", name: "mcp__ccd_session__start_session", input: { title: "Review", prompt: "Review it" } },
      { type: "tool_use", id: "offer", name: "mcp__ccd_session__start_session", input: { title: "Maybe", prompt: "Later" } }] } },
    { type: "user", uuid: "r1", message: { content: [
      { type: "tool_result", tool_use_id: "mon", content: "Monitor started (task b1a2c3d4e, expires in 30m unless the source ends first)" },
      { type: "tool_result", tool_use_id: "linked", content: [{ type: "text", text: "Started session \"Review\" (session_id: local_1626a88b-15e9, name: review). It runs on its own." }] },
      { type: "tool_result", tool_use_id: "offer", content: [{ type: "text", text: "Proposed \"Maybe\" (task_id: task_ab07e02f)." }] }] } },
  ];
  const tasks = Object.fromEntries(backgroundTasks(messages, true).map(t => [t.id, t]));
  assert.deepEqual(Object.keys(tasks).sort(), ["linked", "mon"]);
  assert.deepEqual([tasks.mon.kind, tasks.mon.status, tasks.mon.taskId, tasks.mon.title], ["monitor", "running", "b1a2c3d4e", "Build errors"]);
  assert.deepEqual([tasks.linked.kind, tasks.linked.hostSessionId, tasks.linked.title], ["session", "local_1626a88b-15e9", "Review"]);
  // Without a live process a monitor's state is unknown; a linked session has its own process.
  const idle = Object.fromEntries(backgroundTasks(messages, false).map(t => [t.id, t.status]));
  assert.deepEqual(idle, { mon: "unknown", linked: "running" });
  const done = [...messages, { type: "user", uuid: "n1", origin: { kind: "task-notification" }, message: { content:
    "<task-notification>\n<task-id>b1a2c3d4e</task-id>\n<tool-use-id>mon</tool-use-id>\n<status>completed</status>\n<summary>Monitor \"Build errors\" ended</summary>\n</task-notification>" } }];
  assert.equal(backgroundTasks(done, true).find(t => t.id === "mon").status, "completed");
});

test("a main turn ends at its final reply even while background work runs", () => {
  const prompt = { type: "user", uuid: "u", message: { content: "Go" } };
  const tool = { type: "assistant", uuid: "a", message: { stop_reason: "tool_use", content: [{ type: "tool_use", id: "t", name: "Bash", input: {} }] } };
  const result = { type: "user", uuid: "r", message: { content: [{ type: "tool_result", tool_use_id: "t", content: "ok" }] } };
  const reply = { type: "assistant", uuid: "b", message: { stop_reason: "end_turn", content: [{ type: "text", text: "Started" }] } };
  const child = { type: "assistant", uuid: "c", parent_tool_use_id: "t", message: { stop_reason: null, content: [] } };
  assert.equal(mainTurnRunning([prompt]), true);
  assert.equal(mainTurnRunning([prompt, tool]), true);
  assert.equal(mainTurnRunning([prompt, tool, result]), true);
  assert.equal(mainTurnRunning([prompt, tool, result, reply]), false);
  assert.equal(mainTurnRunning([prompt, tool, result, reply, child]), false, "an agent's own messages are not the main turn");
  assert.equal(mainTurnRunning([prompt, { type: "user", uuid: "i", message: { content: [{ type: "text", text: "[Request interrupted by user]" }] } }]), false);
  assert.equal(mainTurnRunning([]), false);
});

test("a desktop session's status separates its reply from background work", async t => {
  const dir = await mkdtemp(join(tmpdir(), "wonder-claude-sessions-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const record = status => writeFile(join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: "s", status }));
  const state = async status => { await record(status); return claudeSessionState("s", dir); };
  assert.deepEqual(await state("busy"), { open: true, busy: true, background: true });
  assert.deepEqual(await state("shell"), { open: true, busy: false, background: true }, "only background commands or monitors");
  assert.deepEqual(await state("waiting"), { open: true, busy: true, background: true });
  assert.deepEqual(await state("idle"), { open: true, busy: false, background: false });
  await writeFile(join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: "s", status: "busy", entrypoint: "sdk-ts" }));
  assert.deepEqual(await claudeSessionState("s", dir), { open: false, busy: false, background: false }, "Wonder's own SDK runs are not Claude on the Mac");
});

test("a desktop session whose reply finished is idle while its tasks run, and refuses a second writer", async t => {
  const f = await fixture(t, { transcripts: {} });
  const dir = await mkdtemp(join(tmpdir(), "wonder-claude-sessions-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const sdkSessionId = "11111111-2222-3333-4444-555555555556";
  const messages = [{ type: "user", uuid: "turn-1", origin: { kind: "human" }, message: { content: "Audit it" } },
    { type: "assistant", uuid: "a1", message: { id: "m1", stop_reason: "tool_use", content: [{ type: "tool_use", id: "tu-a", name: "Agent", input: { description: "Audit", prompt: "Look" } }] } },
    { type: "user", uuid: "r1", message: { content: [{ type: "tool_result", tool_use_id: "tu-a", content: "Async agent launched successfully. agentId: x9" }] } },
    { type: "assistant", uuid: "a2", message: { id: "m2", stop_reason: "end_turn", content: [{ type: "text", text: "It is running." }] } }];
  const sdk = { getSessionMessages: async () => messages, getSessionInfo: async (id, { dir: cwd }) => ({ sessionId: id, cwd, lastModified: 1 }) };
  const bridge = new ClaudeBridge({ updates: { acquire: async () => ({ runtime: { sdk }, release: async () => {} }) },
    sessions: f.sessions, send: async () => {}, claudeSessionsDir: dir });
  const { thread } = await bridge.request("project/session/attach", { sessionId: sdkSessionId, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });
  await writeFile(join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: sdkSessionId, status: "busy" }));
  const { data } = await bridge.request("thread/turns/list", { threadId: thread.id, itemsView: "notLoaded" });
  assert.equal(data[0].status, "completed");
  assert.equal(data[0].runningElsewhere, undefined);
  const tasks = (await bridge.request("thread/backgroundTasks/list", { threadId: thread.id })).data;
  assert.deepEqual(tasks.map(t => [t.id, t.status, t.runningElsewhere]), [["tu-a", "running", true]]);
  // Claude Code 2.1.295 reports "idle" while a background command runs: an
  // open process still runs what its transcript launched and never reported.
  await writeFile(join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: sdkSessionId, status: "idle" }));
  bridge.transcripts.clear();
  const idle = (await bridge.request("thread/backgroundTasks/list", { threadId: thread.id })).data;
  assert.deepEqual(idle.map(t => [t.id, t.status, t.runningElsewhere]), [["tu-a", "running", true]]);
  // Wonder's host ends the app's process before sending; a process still (or
  // again) open here would write its own copy, so the bridge refuses a second writer.
  await assert.rejects(bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Another" }] }), /open in Claude on your Mac/);
});

test("the live roster names running tasks the transcript has not recorded", () => {
  const roster = { tasks: new Map([["b1", { task_id: "b1", task_type: "local_bash", description: "Sleep" }],
    ["m1", { task_id: "m1", task_type: "monitor_mcp", description: "Watch" }]]), toolUses: new Map([["b1", "tu-b"]]) };
  const transcript = [{ id: "tu-b", kind: "command", status: "unknown", taskId: null, title: "Sleep" },
    { id: "tu-old", kind: "command", status: "completed", taskId: "b0", title: "Old" }];
  const merged = withLiveRoster(transcript, roster);
  assert.deepEqual(merged.map(t => [t.id, t.kind, t.status, t.taskId]),
    [["task:m1", "monitor", "running", "m1"], ["tu-b", "command", "running", "b1"], ["tu-old", "command", "completed", "b0"]]);
  assert.equal(withLiveRoster(transcript, { tasks: null, toolUses: new Map() }), transcript, "no roster yet: the transcript decides");
});

test("a reply ends at its result while a background command runs; the next message joins the process", async t => {
  const f = await fixture(t);
  f.lingers.current = true;
  const { thread } = await f.bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });
  f.gate.current = Promise.withResolvers();
  await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Start a build" }] });
  await settle(() => f.bridge.active.get(thread.id)?.query);
  const run = f.bridge.active.get(thread.id);
  f.emits.push({ type: "system", subtype: "task_started", task_type: "local_bash", task_id: "bq77", tool_use_id: "tu-bg", description: "Build" });
  f.emits.push({ type: "system", subtype: "background_tasks_changed", tasks: [{ task_id: "bq77", task_type: "local_bash", description: "Build" }] });
  await settle(() => run.roster.tasks?.size);
  f.bridge.projectMessages = async () => ({ messages: [], desktop: false });
  f.gate.current.resolve();
  await run.finished;
  assert.equal(f.sessions.get(thread.id).turns.at(-1).status, "completed", "the reply is done");
  assert.ok(!f.bridge.active.has(thread.id), "the conversation is idle");
  assert.equal(f.closes.length, 0, "the process stays up for the command");
  assert.ok(f.bridge.lingering.has(thread.id));
  const listed = (await f.bridge.request("thread/backgroundTasks/list", { threadId: thread.id })).data;
  assert.deepEqual(listed.map(t => [t.id, t.kind, t.status]), [["tu-bg", "command", "running"]]);

  f.gate.current = null;
  await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Next" }] });
  await f.bridge.active.get(thread.id)?.finished;
  assert.equal(f.capturedOptions.length, 1, "no second process");
  assert.equal(f.inputs.at(-1).message.content[0].text, "Next");
  assert.equal(f.sessions.get(thread.id).turns.at(-1).status, "completed");
  assert.ok(f.bridge.lingering.has(thread.id), "still up while the command runs");

  // The command finishes; Claude reports it in its own turn, which ends the process.
  // That reply joins the last turn live, under the IDs history gives it, and
  // the turn is not reported as ending again.
  const last = f.sessions.get(thread.id).turns.at(-1).id;
  const before = f.frames.length;
  f.emits.push({ type: "system", subtype: "background_tasks_changed", tasks: [] });
  f.emits.push({ type: "user", origin: { kind: "task-notification" }, message: { role: "user", content: "<task-notification><task-id>bq77</task-id><status>completed</status></task-notification>" } });
  f.emits.push({ type: "stream_event", event: { type: "message_start", message: { id: "auto" } } });
  f.emits.push({ type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } });
  f.emits.push({ type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "The build " } } });
  f.emits.push({ type: "assistant", message: { id: "auto", content: [{ type: "text", text: "The build finished." }] } });
  f.emits.push({ type: "result", subtype: "success" });
  await settle(() => f.closes.length);
  assert.ok(!f.bridge.lingering.has(thread.id));
  const after = f.frames.slice(before);
  assert.ok(!after.some(frame => ["turn/started", "turn/completed"].includes(frame.method)), "the turn stays ended");
  const done = after.filter(frame => frame.method === "item/completed").map(frame => frame.params);
  assert.deepEqual(done.map(p => [p.turnId, p.item.id, p.item.text]), [[last, `${last}:auto:0`, "The build finished."]]);
  const history = nativeTurns([{ type: "user", uuid: last, message: { content: "Next" } },
    { type: "user", origin: { kind: "task-notification" }, message: { content: "<task-notification></task-notification>" } },
    { type: "assistant", message: { id: "auto", content: [{ type: "text", text: "The build finished." }] } }]);
  assert.equal(history.at(-1).items.at(-1).id, done[0].item.id, "history shows the same item");
});

test("a lingering process yields when Claude on the Mac opens the chat, so one process writes it", async t => {
  const dir = await mkdtemp(join(tmpdir(), "wonder-claude-sessions-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const f = await fixture(t, { claudeSessionsDir: dir });
  f.lingers.current = true;
  const { thread } = await f.bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });
  f.gate.current = Promise.withResolvers();
  await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Start a build" }] });
  await settle(() => f.bridge.active.get(thread.id)?.query);
  const run = f.bridge.active.get(thread.id);
  f.emits.push({ type: "system", subtype: "background_tasks_changed", tasks: [{ task_id: "bq77", task_type: "local_bash", description: "Build" }] });
  await settle(() => run.roster.tasks?.size);
  f.bridge.projectMessages = async () => ({ messages: [], desktop: false });
  f.gate.current.resolve();
  await run.finished;
  assert.ok(f.bridge.lingering.has(thread.id), "the process stays up for the command");
  await new Promise(resolve => setTimeout(resolve, 60));
  assert.ok(f.bridge.lingering.has(thread.id), "Wonder's own Agent SDK record is not Claude on the Mac");
  await writeFile(join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: f.sessions.get(thread.id).sdkSessionId, status: "idle", entrypoint: "claude-desktop" }));
  await settle(() => f.closes.length);
  assert.ok(!f.bridge.lingering.has(thread.id), "Wonder released its process");
});

test("a reply does not keep its process for background work when Claude on the Mac has the chat open", async t => {
  const dir = await mkdtemp(join(tmpdir(), "wonder-claude-sessions-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const f = await fixture(t, { claudeSessionsDir: dir });
  f.lingers.current = true;
  const { thread } = await f.bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku", wonderPolicy: f.policy, wonderProject: f.project });
  f.gate.current = Promise.withResolvers();
  await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Start a build" }] });
  await settle(() => f.bridge.active.get(thread.id)?.query);
  const run = f.bridge.active.get(thread.id);
  f.emits.push({ type: "system", subtype: "background_tasks_changed", tasks: [{ task_id: "bq77", task_type: "local_bash", description: "Build" }] });
  await settle(() => run.roster.tasks?.size);
  await writeFile(join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: f.sessions.get(thread.id).sdkSessionId, status: "idle", entrypoint: "claude-desktop" }));
  f.bridge.projectMessages = async () => ({ messages: [], desktop: false });
  f.gate.current.resolve();
  await run.finished;
  assert.ok(!f.bridge.lingering.has(thread.id));
  assert.equal(f.closes.length, 1);
});

test("a Project's agents may run in the background; a Bot's stay in the turn", async () => {
  const cwd = "/tmp";
  const policy = project => new ToolPolicy({ cwd, mode: "workspace", approvalMode: "auto", readRoots: ["/"], writeRoots: [cwd], deniedRoots: [], project, tools: [] });
  const hook = async p => (await p.beforeTool({ tool_name: "Agent", tool_input: { prompt: "x", run_in_background: true, model: "opus" } })).hookSpecificOutput;
  const project = await hook(policy(true)), bot = await hook(policy(false));
  assert.deepEqual(project.updatedInput, { prompt: "x", run_in_background: true }, "the parent's model, the agent's own choice of background");
  assert.deepEqual(bot.updatedInput, { prompt: "x", run_in_background: false });
});
