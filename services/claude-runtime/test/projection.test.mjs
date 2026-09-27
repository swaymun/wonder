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
  const { projection: p, events } = fixture();
  p.accept({ type: "assistant", message: { content: [{ type: "tool_use", id: "tool", name: "mcp__wonder__wonder_update_profile", input: { name: "Helper" } }] } });
  p.accept({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: "tool", is_error: true, content: "Save rejected" }] } });
  p.accept({ type: "result", subtype: "success" });
  const item = events.find(e => e.method === "item/completed").params.item;
  assert.equal(item.type, "dynamicToolCall"); assert.equal(item.tool, "wonder_update_profile");
  assert.equal(item.status, "failed"); assert.equal(item.success, false); assert.equal(item.error.message, "Save rejected");
  assert.equal(events.at(-1).params.turn.status, "completed");
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
