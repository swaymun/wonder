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
          for (const message of messages) yield message;
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
test("failed runtime results stay failed after the sidecar restarts", async t => {
  const f = await fixture(t, { messages: [{ type: "result", subtype: "error_during_execution", is_error: true, errors: ["Failed"] }] });
  await f.bridge.request("turn/start", { threadId: f.thread.id, input: [{ type: "text", text: "Hi" }] });
  await f.finish();
  const restarted = await new Sessions(join(f.root, "sessions")).initialize();
  assert.equal(restarted.get(f.thread.id).turns[0].status, "failed");
  assert.equal(f.frames.at(-1).params.turn.status, "failed");
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
