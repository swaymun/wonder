import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile, symlink } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Sessions } from "../sessions.mjs";
import { ClaudeBridge } from "../bridge.mjs";
import { ToolPolicy } from "../permissions.mjs";
import { nativeTurns } from "../project-history.mjs";

// Contract owner: project conversations continue the owner's native Claude Code
// session by exact UUID, read history from that transcript, and never receive
// Bot instructions or tools.
async function fixture(t, { transcripts = {} } = {}) {
  const root = await mkdtemp(join(tmpdir(), "wonder-project-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const primary = join(root, "app"), secondary = join(root, "docs");
  await mkdir(primary); await mkdir(secondary);
  const sessions = await new Sessions(join(root, "sessions")).initialize();
  const frames = [], inputs = [], capturedOptions = [];
  const sdk = {
    tool: () => ({}), createSdkMcpServer: () => ({}),
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
          yield { type: "result", subtype: "success" };
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
  return { root, primary, secondary, sessions, bridge, frames, inputs, capturedOptions, policy, project };
}

test("project turns use the native coding preset and name the transcript entry after the Wonder turn", async t => {
  const f = await fixture(t);
  const { thread } = await f.bridge.request("thread/start", { cwd: f.primary, model: "claude:haiku",
    wonderPolicy: f.policy, wonderProject: f.project, developerInstructions: "You are a Bot", dynamicTools: [{ name: "wonder_ask_question" }] });
  const { turn } = await f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "Fix the build" }] });
  await new Promise(resolve => setImmediate(resolve));
  await f.bridge.active.get(thread.id)?.finished;
  const options = f.capturedOptions[0];
  assert.deepEqual(options.systemPrompt, { type: "preset", preset: "claude_code" });
  assert.deepEqual(options.settingSources, ["user", "project", "local"]);
  assert.deepEqual(options.additionalDirectories, [f.secondary]);
  assert.deepEqual(options.mcpServers, {});
  assert.equal(options.sessionId, thread.sessionId);
  assert.equal(f.inputs[0].uuid, turn.id);
  // A project cannot be moved to another folder by a later turn.
  await assert.rejects(f.bridge.request("turn/start", { threadId: thread.id, input: [{ type: "text", text: "x" }],
    wonderProject: { cwd: f.secondary } }), /keeps its working folder/);
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
  ], [{ id: "turn-1", status: "completed", items: [{ type: "userMessage", id: "u-1", clientId: "client-1", content: [] }] }]);
  assert.deepEqual(turns.map(t => t.id), ["turn-1", "cli-1"]);
  assert.equal(turns[0].items[0].clientId, "client-1");
  // Same ID shape as the live stream: turn:message:content-block-index.
  assert.equal(turns[0].items[1].id, "turn-1:msg-1:1");
  assert.equal(turns[1].items[1].status, "completed");
  assert.equal(turns[1].items[1].contentItems[0].text, "ok");
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
