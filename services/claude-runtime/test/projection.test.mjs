import test from "node:test";
import assert from "node:assert/strict";
import { TurnProjection, questionRequest, questionAnswer, usageWindow, toolContent } from "../projection.mjs";

// Contract owner: provider event normalization. A duplicated final reply or lost
// failed-tool state must be caught before these events reach durable ingestion.
function fixture(options = {}) {
  const events = [], children = [], usage = [];
  const projection = new TurnProjection({ threadId: "claude:thread", turnId: "turn", emit: e => events.push(e), onChild: m => children.push(m), onUsage: w => usage.push(w), ...options });
  projection.start();
  return { projection, events, children, usage };
}
test("stream deltas and repeated final reconcile one stable item", () => {
  const { projection: p, events } = fixture();
  const stream = event => p.accept({ type: "stream_event", event });
  stream({ type: "message_start", message: { id: "message" } });
  stream({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
  for (const text of ["Hello", " world"]) stream({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text } });
  const final = { type: "assistant", message: { id: "message", content: [{ type: "text", text: "Hello world" }] } };
  p.accept(final); p.accept(final);
  p.accept({ type: "future_observability_event", arbitrary: true });
  p.accept({ type: "result", subtype: "success" });
  p.accept(final); p.finish("failed");
  const completed = events.filter(e => e.method === "item/completed");
  assert.equal(completed.length, 1); assert.equal(completed[0].params.item.text, "Hello world");
  assert.ok(events.filter(e => e.method === "item/agentMessage/delta").every(e => e.params.itemId === completed[0].params.item.id));
  assert.equal(events.filter(e => e.method === "turn/completed").length, 1);
});
test("tool failure remains failed within a successful conversation turn", () => {
  for (const [name, expectedType, expectedTool, expectedServer] of [
    ["mcp__wonder__wonder_update_profile", "dynamicToolCall", "wonder_update_profile", undefined],
    ["mcp__cua_repl__js", "mcpToolCall", "js", "cua_repl"],
  ]) {
  const { projection: p, events } = fixture();
  p.accept({ type: "assistant", message: { content: [{ type: "tool_use", id: "tool", name, input: { name: "Helper" } }] } });
  p.accept({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: "tool", is_error: true, content: "Save rejected" }] } });
  p.accept({ type: "result", subtype: "success" });
  const item = events.find(e => e.method === "item/completed").params.item;
  assert.equal(item.type, expectedType); assert.equal(item.tool, expectedTool); assert.equal(item.server, expectedServer);
  assert.equal(item.status, "failed"); assert.equal(item.success, false); assert.equal(item.error.message, "Save rejected");
  assert.equal(events.at(-1).params.turn.status, "completed");
  }
});
// The proposed plan is shaped like a Codex plan item so the conversation renders
// both alike; the refused tool call itself never becomes a failed row.
test("a proposed plan becomes one completed plan item, not a failed tool call", () => {
  const { projection: p, events } = fixture();
  const plan = "# Plan\n1. Add the migration\n2. Wire the route";
  p.accept({ type: "assistant", message: { id: "m", content: [{ type: "tool_use", id: "plan-call", name: "ExitPlanMode", input: { plan } },
    { type: "tool_use", id: "empty-call", name: "ExitPlanMode", input: { plan: "  " } }] } });
  p.accept({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: "plan-call", is_error: true, content: "The owner reviews the plan in Wonder." },
    { type: "tool_result", tool_use_id: "empty-call", is_error: true, content: "The owner reviews the plan in Wonder." }] } });
  p.accept({ type: "result", subtype: "success" });
  assert.deepEqual(events.filter(e => e.method.startsWith("item/")).map(e => [e.method, e.params.item.type, e.params.item.status]),
    [["item/started", "plan", "inProgress"], ["item/completed", "plan", "completed"]]);
  const item = events.find(e => e.method === "item/completed").params.item;
  assert.deepEqual([item.id, item.text], ["plan-call", plan]);
  const turn = events.at(-1).params.turn;
  assert.equal(turn.status, "completed");
  assert.deepEqual(turn.items.map(i => i.type), ["plan"]);
});
test("internal initialization and synthetic user output never create chat text", () => {
  const { projection: p, events, children } = fixture({ internal: true });
  p.accept({ type: "user", message: { content: [{ type: "text", text: "Produce visible output" }] } });
  p.accept({ type: "assistant", message: { id: "greeting", content: [{ type: "text", text: "Hello" }] } });
  p.accept({ type: "system", subtype: "task_started", task_type: "local_agent", tool_use_id: "internal" });
  p.accept({ type: "assistant", parent_tool_use_id: "internal", message: { content: [{ type: "text", text: "Private planning" }] } });
  p.finish("completed");
  assert.equal(children.length, 0);
  assert.deepEqual(events.map(e => e.method), ["turn/started", "turn/completed"]);
});
test("child messages never leak into the parent reply", () => {
  const { projection: p, events, children } = fixture();
  p.accept({ type: "assistant", parent_tool_use_id: "agent-call", message: { id: "child", content: [{ type: "text", text: "Child work" }] } });
  assert.equal(children.length, 1); assert.equal(events.length, 1);
});
test("image bytes remain media for daemon attachment validation", () => {
  assert.deepEqual(toolContent([{ type: "image", source: { type: "base64", media_type: "image/png", data: "synthetic" } }]),
    [{ type: "inputImage", imageUrl: "data:image/png;base64,synthetic" }]);
});
test("question IDs preserve selection arrays and labels containing commas", () => {
  const input = { questions: [{ question: "Which?", header: "Pick", multiSelect: true, options: [{ label: "A, B" }, { label: "C" }] }] };
  const normalized = questionRequest(input, "request");
  const result = questionAnswer(input, normalized, { answers: { "request:0": { answers: ["A, B", "C"] } } });
  assert.deepEqual(result.answers, { "Which?": ["A, B", "C"] });
  assert.throws(() => questionAnswer(input, normalized, { answers: { "different:0": { answers: ["C"] } } }));
  assert.throws(() => questionRequest({ questions: [input.questions[0], input.questions[0]] }, "request"));
});
test("single questions reject multiple selections and accept custom text", () => {
  const input = { questions: [{ question: "Tone?", options: [{ label: "Short" }, { label: "Detailed" }] }] };
  const normalized = questionRequest(input, "request");
  assert.equal(questionAnswer(input, normalized, { answers: { "request:0": { answers: ["Friendly"] } } }).answers["Tone?"], "Friendly");
  assert.throws(() => questionAnswer(input, normalized, { answers: { "request:0": { answers: ["Short", "Detailed"] } } }));
});
test("usage distinguishes SDK fractions from endpoint percentages and unknown", () => {
  assert.equal(usageWindow("five_hour", { utilization: 0.32, resetsAt: 1900000000 }).remainingPercent, 68);
  assert.equal(usageWindow("seven_day", { utilization: 32, format: "percent" }).usedPercent, 32);
  assert.equal(usageWindow("five_hour", { utilization: NaN }), null);
  assert.equal(usageWindow("seven_day", {}), null);
  assert.equal(usageWindow("future_window", { utilization: 0 }), null);
});

// SDK connection/quota failures can use the success variant with is_error and
// a result string. Preserve the actual error instead of a generic failure.
test("error results preserve their reason and never become successful replies", () => {
  for (const message of [
    { type: "result", subtype: "success", is_error: true, result: "API Error: Cannot reach server" },
    { type: "result", subtype: "error_max_turns", errors: ["Reached maximum number of turns (64)"] },
  ]) {
    const { projection, events } = fixture();
    projection.accept(message);
    assert.equal(events.at(-1).params.turn.status, "failed");
    assert.equal(events.at(-1).params.turn.error.message, message.result ?? message.errors[0]);
    assert.equal(events.at(-1).params.turn.items.length, 0);
  }
});

test("a result for earlier queued work does not end the prompt's turn", () => {
  const events = [];
  const projection = new TurnProjection({ threadId: "t", turnId: "turn-1", promptUuid: "turn-1", emit: e => events.push(e) });
  // A resumed session first finishes a queued background-task notice.
  projection.accept({ type: "result", subtype: "success", is_error: false, user_message_uuid: "notice-1" });
  assert.equal(projection.terminal, false);
  projection.accept({ type: "result", subtype: "success", is_error: false, user_message_uuids: ["turn-1"] });
  assert.equal(projection.terminal, true);
  assert.equal(projection.result.status, "completed");
  // A notice turn Claude started itself names no prompt; it ends the turn
  // only after the reply to this prompt began.
  const plain = new TurnProjection({ threadId: "t", turnId: "turn-2", promptUuid: "turn-2", emit: () => {} });
  plain.accept({ type: "result", subtype: "success", is_error: false });
  assert.equal(plain.terminal, false);
  plain.accept({ type: "assistant", user_message_uuid: "turn-2", message: { id: "m", content: [{ type: "text", text: "Done." }] }, parent_tool_use_id: null });
  plain.accept({ type: "result", subtype: "success", is_error: false });
  assert.equal(plain.terminal, true);
});

// The projection owns terminal errors: startup failures have no prompt UUID.
test("a session-level error fails an unanswered Project prompt", () => {
  const projection = new TurnProjection({ threadId: "t", turnId: "turn", promptUuid: "turn", emit: () => {} });
  projection.accept({ type: "result", subtype: "error_during_execution", is_error: true, errors: ["Worker failed"] });
  assert.equal(projection.terminal, true);
  assert.equal(projection.result.status, "failed");
  assert.equal(projection.result.error.message, "Worker failed");
});
