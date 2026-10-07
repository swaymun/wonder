import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, symlink, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ToolPolicy } from "../permissions.mjs";

// Contract: model-supplied paths cannot turn an approved folder into access to
// a denied or unrelated folder, including when creating a file through a link.
test("file grants enforce lexical and canonical scope for reads and new writes", async t => {
  const root = await mkdtemp(join(tmpdir(), "wonder-policy-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cwd = join(root, "allowed"), other = join(root, "other"), denied = join(cwd, "secrets");
  await Promise.all([mkdir(denied, { recursive: true }), mkdir(other)]);
  await writeFile(join(other, "secret"), "private");
  await symlink(other, join(cwd, "escape"));
  const policy = new ToolPolicy({ cwd, mode: "workspace", approvalMode: "ask", readRoots: [cwd], writeRoots: [cwd], deniedRoots: [denied] });
  assert.equal(await policy.permits("new/file.txt", true), true);
  assert.equal(await policy.permits("escape/secret"), false);
  assert.equal(await policy.permits("escape/new.txt", true), false);
  assert.equal(await policy.permits("../other/secret"), false);
  assert.equal(await policy.permits("secrets/new.txt", true), false);
  assert.equal(await policy.decision("Write", { file_path: "new.txt" }), "ask");
  assert.equal(await policy.decision("FuturePowerTool", {}), "deny");
  assert.equal(await policy.decision("StructuredOutput", {}), "deny");
  assert.equal(await policy.decision("mcp__claude-in-chrome__navigate", {}), "deny");
  // Existing installations keep a legacy alias to the protected data root.
  // Its canonical scope must allow the same owned workspace, but no sibling.
  const legacy = join(root, "legacy");
  await symlink(root, legacy);
  const privateWorkspace = new ToolPolicy({ cwd, workspace: cwd, mode: "workspace", approvalMode: "ask", readRoots: [root], writeRoots: [cwd], deniedRoots: [root, legacy, denied] });
  assert.equal(await privateWorkspace.permits(cwd), true);
  assert.equal(await privateWorkspace.permits("new.txt", true), true);
  assert.equal(await privateWorkspace.permits("secrets/new.txt", true), false);
  assert.equal(await privateWorkspace.permits("../other/secret"), false);
  assert.equal(await privateWorkspace.permits(join(legacy, "other/secret")), false);
  assert.equal(await privateWorkspace.permits("escape/secret"), false);
  assert.equal(await policy.decision("Bash", { dangerouslyDisableSandbox: true }), "deny");
});
test("read-only mode cannot be widened by full-access approval or internal initialization", async () => {
  const policy = new ToolPolicy({ cwd: "/tmp", mode: "read_only", approvalMode: "full_access", readRoots: ["/tmp"], writeRoots: ["/tmp"], deniedRoots: [] });
  assert.equal(await policy.permits("new.txt", true), false);
  policy.internal = true;
  assert.equal(await policy.decision("Bash", {}), "deny");
  assert.equal(await policy.decision("mcp__wonder__wonder_update_profile", {}), "deny");
});
// Contract: Projects run commands without a sandbox, as Claude Code does,
// except Read only, whose sandbox confines $HOME to the project and toolchains,
// reaches common developer hosts and keeps protected folders closed. Bots keep
// a closed network and their own scope. Live behavior is proven by
// scripts/claude-sdk-smoke/access-acceptance.mjs.
test("Projects run commands without a sandbox; Read only and Bots keep it", async t => {
  const root = await mkdtemp(join(tmpdir(), "wonder-sandbox-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = join(root, "home"), app = join(home, "app"), data = join(home, ".wonder"), bot = join(data, "bots", "b1"), ssh = join(home, ".ssh");
  await Promise.all([app, bot, ssh].map(path => mkdir(path, { recursive: true })));
  const projectPolicy = modes => new ToolPolicy({ cwd: app, readRoots: ["/"], writeRoots: modes.mode === "read_only" ? [] : [app],
    deniedRoots: [data, ssh], project: true, projectRoots: [app], home, ...modes });
  for (const modes of [{ mode: "workspace", approvalMode: "ask" }, { mode: "workspace", approvalMode: "auto" },
    { mode: "workspace", approvalMode: "auto", planMode: true }, { mode: "full_access", approvalMode: "full_access" }])
    assert.deepEqual(projectPolicy(modes).sandbox(), { enabled: false }, JSON.stringify(modes));
  // Read only is enforced by the sandbox, with the developer-friendly Project layout.
  const readOnly = projectPolicy({ mode: "read_only", approvalMode: "ask" }).sandbox();
  assert.equal(readOnly.enabled, true);
  assert.equal(readOnly.allowUnsandboxedCommands, true);
  assert.ok(readOnly.network.allowedDomains.includes("github.com"));
  assert.equal(readOnly.network.allowLocalBinding, true);
  for (const denied of [home, data, ssh]) assert.ok(readOnly.filesystem.denyRead.includes(denied));
  for (const readable of [app, join(home, ".cargo"), join(home, ".gitconfig")]) assert.ok(readOnly.filesystem.allowRead.includes(readable));
  assert.ok(!readOnly.filesystem.allowRead.some(path => path === home || path.startsWith(ssh) || path.startsWith(data)));
  assert.ok(readOnly.filesystem.allowWrite.includes("/tmp"));
  assert.ok(!readOnly.filesystem.allowWrite.includes(app));
  assert.ok(readOnly.filesystem.denyWrite.includes(app));
  assert.equal(projectPolicy({ mode: "full_access", approvalMode: "full_access", internal: true }).sandbox().enabled, true);

  // A Bot works inside Wonder's protected data folder without opening the rest of it.
  for (const mode of ["read_only", "workspace", "full_access"]) {
    const sandbox = new ToolPolicy({ cwd: bot, mode, approvalMode: mode === "full_access" ? "full_access" : "ask",
      readRoots: [bot], writeRoots: [bot], deniedRoots: [data, ssh], home }).sandbox();
    assert.equal(sandbox.enabled, true);
    assert.equal(sandbox.allowUnsandboxedCommands, false);
    assert.deepEqual(sandbox.network, { allowedDomains: [], strictAllowlist: true });
    assert.ok(sandbox.filesystem.denyRead.includes(data) && sandbox.filesystem.allowRead.includes(bot));
    assert.ok(!sandbox.filesystem.denyWrite.includes(data), "the Bot's own workspace stays writable");
    assert.ok(sandbox.filesystem.denyWrite.includes(ssh));
    // Full access Bots keep their existing whole-disk write scope inside the sandbox.
    assert.equal(sandbox.filesystem.allowWrite.includes(mode === "full_access" ? "/" : bot), mode !== "read_only");
    assert.equal(sandbox.filesystem.denyWrite.includes(bot), mode === "read_only");
  }
});
test("delegated work inherits the selected model", async () => {
  const policy = new ToolPolicy({ cwd: "/tmp", mode: "read_only", approvalMode: "ask", readRoots: [], writeRoots: [], deniedRoots: [] });
  const result = await policy.beforeTool({ tool_name: "Agent", tool_input: { prompt: "Check", model: "opus" } });
  assert.deepEqual(result.hookSpecificOutput.updatedInput, { prompt: "Check", run_in_background: false });
});

// Contract: Wonder's approval modes are decided in one table. Auto and Full
// access still send Bash through canUseTool (the hook only ever answers "ask"),
// leaving the sandbox always asks the owner, and plan mode forbids every write
// even when the owner's approval mode would allow it.
test("approval modes and plan mode decide each tool once", async t => {
  const root = await mkdtemp(join(tmpdir(), "wonder-modes-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cwd = join(root, "app"), outside = join(root, "other");
  await Promise.all([mkdir(cwd), mkdir(outside)]);
  const policy = (approvalMode, planMode = false, mode = approvalMode === "full_access" ? "full_access" : "workspace") =>
    new ToolPolicy({ cwd, mode, approvalMode, planMode, readRoots: ["/"], writeRoots: [cwd], deniedRoots: [], project: true });
  const write = { file_path: join(cwd, "a.txt") }, notebook = { notebook_path: join(cwd, "n.ipynb") };
  const decisions = async p => ({ write: await p.decision("Write", write), edit: await p.decision("Edit", write), notebook: await p.decision("NotebookEdit", notebook),
    outside: await p.decision("Write", { file_path: join(outside, "a.txt") }), bash: await p.decision("Bash", { command: "ls" }),
    unsandboxed: await p.decision("Bash", { command: "ls", dangerouslyDisableSandbox: true }),
    web: await p.decision("WebFetch", {}), mcp: await p.decision("mcp__claude_ai_Gmail__list_labels", {}), exit: await p.decision("ExitPlanMode", { plan: "x" }) });
  const asks = { write: "ask", edit: "ask", notebook: "ask", outside: "deny", bash: "ask", unsandboxed: "ask", web: "ask", mcp: "ask", exit: "ask" };
  const edits = { write: "allow", edit: "allow", notebook: "allow" };
  assert.deepEqual(await decisions(policy("ask")), asks);
  assert.deepEqual(await decisions(policy("accept_edits")), { ...asks, ...edits });
  // Auto asks only when Claude Code's classifier escalates; see the hook below.
  assert.deepEqual(await decisions(policy("auto")), { ...asks, ...edits });
  // Full access: no file scope, no sandbox and no prompts.
  assert.deepEqual(await decisions(policy("full_access")), { ...asks, ...edits, outside: "allow", bash: "allow", unsandboxed: "allow", web: "allow" });
  // Planning: no write in any approval mode, no automatic command or web access.
  const planning = { ...asks, write: "deny", edit: "deny", notebook: "deny", exit: "deny" };
  for (const approvalMode of ["ask", "accept_edits", "auto", "full_access"])
    assert.deepEqual(await decisions(policy(approvalMode, true)), planning, approvalMode);
  assert.equal(policy("auto").autoRunsCommands, false);
  assert.equal(policy("full_access").autoRunsCommands, true);
  assert.equal(policy("auto", true).autoRunsCommands, false);
  // Claude Code's own mode runs underneath: Auto uses its classifier.
  assert.deepEqual(["ask", "accept_edits", "auto", "full_access"].map(mode => policy(mode).permissionMode), ["default", "default", "auto", "default"]);
  assert.equal(policy("auto", true).permissionMode, "plan");
  // A sandboxed Bot in Auto still runs commands without asking.
  const bot = new ToolPolicy({ cwd, mode: "workspace", approvalMode: "auto", readRoots: [cwd], writeRoots: [cwd], deniedRoots: [] });
  assert.equal(bot.autoRunsCommands, true);
  assert.equal(bot.permissionMode, "default");
  assert.equal((await bot.beforeTool({ tool_name: "Bash", tool_input: { command: "ls" } })).hookSpecificOutput.permissionDecision, "ask");
  assert.equal(policy("full_access").bypassesApproval, true);
  assert.equal(policy("full_access", true).bypassesApproval, false);

  // The hook never allows Bash itself: Claude Code decides commands and web
  // access unless nothing asks, and never lets a write through in plan mode.
  for (const approvalMode of ["ask", "accept_edits", "auto", "full_access"]) {
    for (const tool of [["Bash", { command: "ls" }], ["WebFetch", { url: "https://example.com" }]]) {
      const hook = await policy(approvalMode).beforeTool({ tool_name: tool[0], tool_input: tool[1] });
      assert.deepEqual(hook, approvalMode === "full_access"
        ? { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: tool[0] === "Bash" ? "ask" : "allow" } } : {}, `${approvalMode} ${tool[0]}`);
      assert.deepEqual(await policy(approvalMode, true).beforeTool({ tool_name: tool[0], tool_input: tool[1] }), {}, approvalMode);
    }
    const planned = await policy(approvalMode, true).beforeTool({ tool_name: "Write", tool_input: write });
    assert.equal(planned.hookSpecificOutput.permissionDecision, "deny", approvalMode);
    assert.match(planned.hookSpecificOutput.permissionDecisionReason, /Plan mode: describe the change instead of editing/);
  }
  assert.equal((await policy("accept_edits").beforeTool({ tool_name: "Edit", tool_input: write })).hookSpecificOutput.permissionDecision, "allow");
  const review = await policy("ask", true).beforeTool({ tool_name: "ExitPlanMode", tool_input: { plan: "x" } });
  assert.equal(review.hookSpecificOutput.permissionDecision, "deny");
  assert.match(review.hookSpecificOutput.permissionDecisionReason, /owner reviews the plan in Wonder/);
  assert.match(policy("ask").denial("Write"), /outside this conversation’s allowed tools/);
});
test("unsupported approval modes fail closed instead of widening access", () => {
  const scope = { cwd: "/tmp", readRoots: [], writeRoots: [], deniedRoots: [] };
  assert.doesNotThrow(() => new ToolPolicy({ ...scope, mode: "workspace", approvalMode: "auto", planMode: true }));
  for (const bad of [{ mode: "workspace", approvalMode: "yolo" }, { mode: "workspace", approvalMode: "ask", planMode: "yes" },
    // Accepting edits or running commands automatically refines Workspace only.
    { mode: "read_only", approvalMode: "auto" }, { mode: "full_access", approvalMode: "accept_edits" }])
    assert.throws(() => new ToolPolicy({ ...scope, ...bad }), /unsupported/);
});

// Contract owner: the command policy. Leaving the sandbox or reaching a new
// host always asks the owner in a sandboxed Project and is impossible for Bots;
// Full access has no sandbox. Claude Code settings files cannot be edited
// silently, and Claude's file tools share the sandbox's view of $HOME.
test("Projects ask through Claude Code instead of a sandbox and settings edits still ask", async t => {
  const root = await mkdtemp(join(tmpdir(), "wonder-escape-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = join(root, "home"), app = join(home, "app");
  for (const path of [join(app, ".claude"), join(home, "Documents"), join(home, ".cargo")]) await mkdir(path, { recursive: true });
  await writeFile(join(home, "Documents", "private.txt"), "private");
  const base = { cwd: app, mode: "workspace", approvalMode: "auto", project: true, projectRoots: [app], home,
    readRoots: ["/"], writeRoots: [app], deniedRoots: [] };
  const outside = { command: "git push", dangerouslyDisableSandbox: true };
  const decide = async (change, name, input) => new ToolPolicy({ ...base, ...change }).decision(name, input);
  // What reaches canUseTool from Claude Code asks the owner; Full access never asks.
  assert.equal(await decide({}, "Bash", { command: "ls" }), "ask");
  assert.equal(await decide({}, "Bash", outside), "ask");
  assert.equal(await decide({ planMode: true }, "Bash", outside), "ask");
  assert.equal(await decide({ mode: "full_access", approvalMode: "full_access" }, "Bash", outside), "allow");
  // Read only keeps its sandbox and may leave it only with approval; Bots never leave it.
  assert.equal(await decide({ mode: "read_only", approvalMode: "ask", writeRoots: [] }, "Bash", outside), "ask");
  for (const change of [{ project: false }, { internal: true }, { mode: "read_only", approvalMode: "ask", writeRoots: [], planMode: true }])
    assert.equal(await decide(change, "Bash", outside), "deny");
  assert.equal(await decide({}, "SandboxNetworkAccess", { host: "example.com" }), "ask");
  assert.equal(await decide({ project: false }, "SandboxNetworkAccess", { host: "example.com" }), "deny");
  const settings = { file_path: join(app, ".claude", "settings.local.json"), content: "{}" };
  assert.equal(await decide({}, "Write", settings), "ask");
  assert.equal(await decide({}, "Write", { file_path: join(app, "notes.md"), content: "" }), "allow");
  assert.equal(await decide({ mode: "full_access", approvalMode: "full_access" }, "Write", settings), "allow");
  // As in Claude Code, Read covers the disk except protected folders; only
  // a sandboxed Read only Project confines $HOME.
  const documents = { file_path: join(home, "Documents", "private.txt") };
  assert.equal(await decide({}, "Read", documents), "allow");
  const readOnly = { mode: "read_only", approvalMode: "ask", writeRoots: [] };
  assert.equal(await decide(readOnly, "Read", documents), "deny");
  assert.equal(await decide(readOnly, "Read", { file_path: join(home, ".cargo") }), "allow");
  assert.equal(await decide({ mode: "full_access", approvalMode: "full_access" }, "Read", documents), "allow");
});
