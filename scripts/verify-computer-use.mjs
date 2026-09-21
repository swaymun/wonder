import assert from "node:assert/strict";
import { spawn } from "node:child_process";

const binary = process.argv[2] ?? process.env.WONDER_COMPUTER_USE_BIN;
if (!binary) throw new Error("usage: verify-computer-use.mjs /path/to/WonderComputerUse");

const requests = [
  { id: 1, method: "status", params: {} },
  { id: 2, method: "status", params: { handshake: "verify-token" } },
  { id: 3, method: "capture.status", params: { handshake: "verify-token" } },
  { id: 4, method: "type", params: { handshake: "verify-token", text: "dry-run text" } },
  { id: 5, method: "key", params: { handshake: "verify-token", keyCode: 36, modifiers: 0 } },
  { id: 6, method: "focusApp", params: { handshake: "verify-token", bundleId: "com.apple.Safari" } },
  { id: 7, method: "type", params: { handshake: "verify-token", text: "" } },
];

const child = spawn(binary, ["--dry-run"], {
  env: { ...process.env, WONDER_COMPUTER_USE_HANDSHAKE: "verify-token" },
  stdio: ["pipe", "pipe", "inherit"],
});
const output = [];
let buffer = "";
let responsesReadyResolve;
const responsesReady = new Promise((resolve) => { responsesReadyResolve = resolve; });
function append(message) {
  output.push(message);
  if (output.filter((candidate) => Object.hasOwn(candidate, "id")).length >= requests.length) {
    responsesReadyResolve();
  }
}
child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  for (const line of buffer.split("\n").slice(0, -1)) append(JSON.parse(line));
  buffer = buffer.split("\n").at(-1) ?? "";
});
child.stdin.write(requests.map((request) => JSON.stringify(request)).join("\n") + "\n");

let responseTimeout;
await Promise.race([
  responsesReady,
  new Promise((_, reject) => {
    responseTimeout = setTimeout(() => reject(new Error("computer-use persistent stdin timed out")), 10_000);
  }),
]);
clearTimeout(responseTimeout);
child.stdin.write(JSON.stringify({ id: 8, method: "stop", params: { handshake: "verify-token" } }) + "\n");

const exitCode = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => {
    child.kill("SIGTERM");
    reject(new Error("computer-use dry-run timed out"));
  }, 10_000);
  child.once("error", reject);
  child.once("close", (code) => {
    clearTimeout(timer);
    resolve(code);
  });
});
if (buffer.trim()) append(JSON.parse(buffer));

assert.equal(exitCode, 0);
const responses = output.filter((message) => Object.hasOwn(message, "id"));
const events = output.filter((message) => Object.hasOwn(message, "event"));
assert.equal(responses.length, requests.length + 1);
assert.equal(responses[0].error.code, "handshake_required");
assert.equal(responses[1].result.dryRun, true);
assert.equal(responses[1].result.lockedUse, false);
assert.equal(responses[1].result.action, "status");
assert.equal(typeof responses[1].result.observation?.available, "boolean");
assert.equal(responses[2].result.action, "capture.status");
assert.equal(responses[2].result.configuration.width, 1280);
assert.equal(responses[2].result.configuration.height, 720);
assert.equal(responses[2].result.configuration.framesPerSecond, 15);
assert.equal(responses[2].result.configuration.audioEnabled, false);
assert.equal("imageBase64" in responses[2].result, false);
for (const response of responses.slice(3, 6)) {
  assert.equal(response.result.accepted, true);
  assert.equal(response.result.dryRun, true);
  assert.equal(typeof response.result.action, "string");
  assert.equal(typeof response.result.observation?.available, "boolean");
}
assert.equal(responses[6].error.code, "invalid_input");
assert.equal(responses[7].result.stopped, true);
assert.equal(events.length, 1);
assert.equal(events[0].event, "capture.stopped");
assert.equal(events[0].status.state, "stopped");
assert.equal(events[0].status.reason, "helper_stopped");
assert.equal("imageBase64" in events[0].status, false);
console.log("verified persistent JSONL input, locked-use guard, dry-run actions, validation, and terminal lifecycle event");
