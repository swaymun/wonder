import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, readFile, mkdir, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { compatibleVersion, RuntimeUpdates } from "../runtime-updates.mjs";
import { isSubscription, subscriptionEnvironment, projectUsage } from "../sdk-runtime.mjs";

// Contract: new SDK bytes never replace a running turn; a bad candidate and a
// restart must preserve a usable runtime. Exercise the manager's persisted state.
async function fixture(t, overrides = {}) {
  const root = await mkdtemp(join(tmpdir(), "wonder-sdk-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const options = { root, bundled: { version: "0.3.283" }, load: async root => ({ version: root.split("/").at(-1) }),
    check: async () => {}, install: async version => join(root, "versions", version), latest: async () => "0.3.284", ...overrides };
  return { options, manager: await new RuntimeUpdates(options).initialize() };
}
test("activates a checked update only after all active turns finish", async t => {
  const { manager, options } = await fixture(t);
  const first = await manager.acquire(), second = await manager.acquire();
  await manager.refresh();
  assert.equal(manager.status().pendingVersion, "0.3.284");
  assert.equal(manager.current.version, "0.3.283");
  await first.release(); await first.release();
  assert.equal(manager.current.version, "0.3.283");
  await second.release();
  assert.equal(manager.current.version, "0.3.284");
  assert.equal(first.runtime.version, "0.3.283");
  const restarted = await new RuntimeUpdates(options).initialize();
  assert.equal(restarted.current.version, "0.3.284");
});
test("a broken candidate cannot displace the bundled version", async t => {
  const { manager } = await fixture(t, { check: async () => { throw new Error("control protocol changed"); } });
  await manager.refresh();
  assert.equal(manager.current.version, "0.3.283");
  assert.equal(manager.status().pendingVersion, null);
  assert.equal(manager.status().lastFailure, "candidate_unavailable_or_incompatible");
});
test("restart falls back when an installed candidate no longer loads", async t => {
  const { manager, options } = await fixture(t);
  await manager.refresh();
  const restarted = await new RuntimeUpdates({ ...options, load: async () => { throw new Error("missing executable"); } }).initialize();
  assert.equal(restarted.current.version, "0.3.283");
  assert.equal(JSON.parse(await readFile(join(options.root, "state.json"))).active, "0.3.283");
});
test("updates are coalesced and breaking/prerelease/path values never install", async t => {
  let checks = 0;
  const { manager } = await fixture(t, { latest: async () => { checks++; return "0.4.0"; }, install: async () => assert.fail("must not install") });
  await Promise.all([manager.refresh(), manager.refresh()]);
  await manager.refresh();
  assert.equal(checks, 1);
  assert.equal(manager.status().lastFailure, "adapter_update_required");
  for (const version of ["../0.3.284", "0.3.284-beta", "0.3.282", "1.0.0", undefined]) assert.equal(compatibleVersion(version, "0.3.283"), false);
});
test("subscription guard cannot silently select API billing", () => {
  const pro = { apiProvider: "firstParty", subscriptionType: "Claude Pro", apiKeySource: "none" };
  assert.equal(isSubscription(pro), true);
  assert.equal(isSubscription({ ...pro, apiKeySource: "ANTHROPIC_API_KEY" }), false);
  assert.equal(isSubscription({ ...pro, apiProvider: "bedrock" }), false);
  assert.deepEqual(subscriptionEnvironment({ HOME: "/home/test", ANTHROPIC_API_KEY: "secret", NODE_OPTIONS: "--require evil", CODEX_HOME: "private" }),
    { HOME: "/home/test", DISABLE_TELEMETRY: "1", DISABLE_ERROR_REPORTING: "1", DISABLE_AUTOUPDATER: "1", CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION: "false", CLAUDE_AGENT_SDK_CLIENT_APP: "wonder/1.0" });
});
test("experimental usage is optional and percentages are never fractions", () => {
  assert.equal(projectUsage({ rate_limits_available: false }), null);
  assert.equal(projectUsage({ rate_limits_available: true, rate_limits: { future: { utilization: 10 } } }), null);
  const result = projectUsage({ rate_limits_available: true, rate_limits: { five_hour: { utilization: 10 }, seven_day: { utilization: 20 } } });
  assert.deepEqual(result.map(w => [w.id, w.remainingPercent]), [["five_hour", 90], ["seven_day", 80]]);
});

test("a staged update survives restart and old versions are bounded", async t => {
  let latest = "0.3.284";
  const { manager, options } = await fixture(t, { latest: async () => latest });
  for (const version of ["0.3.281", "0.3.284", "notes"]) await mkdir(join(options.root, "versions", version));
  const running = await manager.acquire();
  await manager.refresh();
  assert.equal(manager.current.version, "0.3.283");
  const restarted = await new RuntimeUpdates(options).initialize();
  assert.equal(restarted.current.version, "0.3.284");
  assert.deepEqual((await readdir(join(options.root, "versions"))).sort(), ["0.3.284", "notes"]);
  latest = "0.3.285";
  await mkdir(join(options.root, "versions", latest));
  await restarted.refresh({ force: true });
  assert.equal(restarted.current.version, "0.3.285");
  assert.equal(restarted.state.lastGood, "0.3.284");
  assert.deepEqual((await readdir(join(options.root, "versions"))).sort(), ["0.3.284", "0.3.285", "notes"]);
  // This lease represents the process that died; do not activate it again.
  assert.equal(running.runtime.version, "0.3.283");
});

test("finishing a turn during the staged-state commit cannot race activation", async t => {
  const { manager, options } = await fixture(t);
  const running = await manager.acquire();
  const entered = Promise.withResolvers(), proceed = Promise.withResolvers();
  const save = manager.save.bind(manager);
  let first = true;
  manager.save = async () => { if (first) { first = false; entered.resolve(); await proceed.promise; } await save(); };
  const refreshing = manager.refresh();
  await entered.promise;
  await running.release();
  assert.equal(manager.current.version, "0.3.283");
  proceed.resolve(); await refreshing;
  assert.equal(manager.current.version, "0.3.284");
  assert.equal(JSON.parse(await readFile(join(options.root, "state.json"))).active, "0.3.284");
});

test("shutdown aborts discovery and drains the owner without activating an update", async t => {
  const { manager, options } = await fixture(t);
  const entered = Promise.withResolvers();
  manager.latest = () => new Promise((_, reject) => {
    manager.abort.signal.addEventListener("abort", () => reject(new Error("closed")), { once: true });
    entered.resolve();
  });
  const refreshing = manager.refresh();
  await entered.promise;
  await manager.close();
  await refreshing;
  assert.equal(manager.current.version, "0.3.283");
  assert.equal(manager.refreshing, null);
  assert.equal(JSON.parse(await readFile(join(options.root, "state.json"))).active, "0.3.283");
  manager.latest = () => assert.fail("closed managers cannot restart discovery");
  await manager.refresh({ force: true });
});
