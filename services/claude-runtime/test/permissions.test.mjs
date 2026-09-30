import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, symlink, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ToolPolicy, closeCommandSandbox } from "../permissions.mjs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

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
// Contract: commands and their children obey the same scope as individual file
// tools. Real OS execution catches SDK precedence and shell-escaping regressions.
test("Mac command sandbox protects siblings and symlink targets while allowing its own workspace", { skip: process.platform !== "darwin" }, async t => {
  t.after(closeCommandSandbox);
  const root = await mkdtemp(join(tmpdir(), "wonder-command-'-$-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cwd = join(root, "workspace"), secret = join(cwd, "secret"), other = join(root, "other");
  await Promise.all([mkdir(secret, { recursive: true }), mkdir(other)]);
  await Promise.all([writeFile(join(cwd, "allowed"), "fixture"), writeFile(join(root, "denied"), "fixture"), writeFile(join(secret, "denied"), "fixture")]);
  await symlink(other, join(cwd, "escape"));
  for (const mode of ["read_only", "workspace", "full_access"]) {
    const policy = new ToolPolicy({ cwd, mode, approvalMode: "full_access", readRoots: ["/"], writeRoots: [cwd], deniedRoots: [root, secret] });
    const program = `import pathlib,json,subprocess; w=pathlib.Path(${JSON.stringify(cwd)}); r=pathlib.Path(${JSON.stringify(root)}); result={}\nfor key,action in [("read",lambda:(w/"allowed").read_text()),("sibling",lambda:(r/"denied").read_text()),("nested",lambda:(w/"secret/denied").read_text()),("write",lambda:(w/"output").write_text("fixture")),("outsideWrite",lambda:(r/"outside").write_text("fixture")),("symlinkWrite",lambda:(w/"escape/output").write_text("fixture")),("rename",lambda:r.rename(str(r)+"-moved"))]:\n try: action(); result[key]=True\n except PermissionError: result[key]=False\nprint(json.dumps(result))`;
    const command = "/usr/bin/python3 -c '" + program.replaceAll("'", "'\\''") + "'";
    const input = await policy.commandInput({ command });
    const { stdout } = await promisify(execFile)("/bin/bash", ["--noprofile", "--norc", "-c", input.command], { cwd });
    assert.deepEqual(JSON.parse(stdout), { read: true, sibling: false, nested: false, write: mode !== "read_only", outsideWrite: false, symlinkWrite: false, rename: false });
  }
});
test("delegated work inherits the selected model", async () => {
  const policy = new ToolPolicy({ cwd: "/tmp", mode: "read_only", approvalMode: "ask", readRoots: [], writeRoots: [], deniedRoots: [] });
  const result = await policy.beforeTool({ tool_name: "Agent", tool_input: { prompt: "Check", model: "opus" } });
  assert.deepEqual(result.hookSpecificOutput.updatedInput, { prompt: "Check", run_in_background: false });
});

// Contract: Wonder's approval modes are decided in one table. Auto and Bypass
// still send Bash through canUseTool (the hook only ever answers "ask") so the
// host command sandbox always applies, and plan mode forbids every write even
// when the owner's approval mode would allow it.
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
  const asks = { write: "ask", edit: "ask", notebook: "ask", outside: "deny", bash: "ask", unsandboxed: "deny", web: "ask", mcp: "ask", exit: "ask" };
  const edits = { write: "allow", edit: "allow", notebook: "allow" };
  assert.deepEqual(await decisions(policy("ask")), asks);
  assert.deepEqual(await decisions(policy("accept_edits")), { ...asks, ...edits });
  assert.deepEqual(await decisions(policy("auto")), { ...asks, ...edits, bash: "allow" });
  // Bypass permissions keeps its existing meaning: no file scope and no prompts.
  assert.deepEqual(await decisions(policy("full_access")), { ...asks, ...edits, outside: "allow", bash: "allow", web: "allow" });
  // Planning: no write in any approval mode, no automatic command or web access.
  const planning = { ...asks, write: "deny", edit: "deny", notebook: "deny", exit: "deny" };
  for (const approvalMode of ["ask", "accept_edits", "auto", "full_access"])
    assert.deepEqual(await decisions(policy(approvalMode, true)), planning, approvalMode);
  assert.equal(policy("auto").autoRunsCommands, true);
  assert.equal(policy("auto", true).autoRunsCommands, false);
  assert.equal(policy("full_access").bypassesApproval, true);
  assert.equal(policy("full_access", true).bypassesApproval, false);

  // The hook never allows Bash itself, and never lets a write through in plan mode.
  for (const approvalMode of ["ask", "accept_edits", "auto", "full_access"]) {
    const bash = await policy(approvalMode).beforeTool({ tool_name: "Bash", tool_input: { command: "ls" } });
    assert.equal(bash.hookSpecificOutput.permissionDecision, "ask", approvalMode);
    const planBash = await policy(approvalMode, true).beforeTool({ tool_name: "Bash", tool_input: { command: "ls" } });
    assert.equal(planBash.hookSpecificOutput.permissionDecision, "ask", approvalMode);
    const planned = await policy(approvalMode, true).beforeTool({ tool_name: "Write", tool_input: write });
    assert.equal(planned.hookSpecificOutput.permissionDecision, "deny", approvalMode);
    assert.match(planned.hookSpecificOutput.permissionDecisionReason, /Plan mode: describe the change instead of editing/);
  }
  assert.equal((await policy("accept_edits").beforeTool({ tool_name: "Edit", tool_input: write })).hookSpecificOutput.permissionDecision, "allow");
  const review = await policy("ask", true).beforeTool({ tool_name: "ExitPlanMode", tool_input: { plan: "x" } });
  assert.equal(review.hookSpecificOutput.permissionDecision, "deny");
  assert.match(review.hookSpecificOutput.permissionDecisionReason, /owner reviews the plan in Wonder/);
  assert.match(policy("ask").denial("Write"), /outside this Bot's allowed tools/);
});
test("unsupported approval modes fail closed instead of widening access", () => {
  const scope = { cwd: "/tmp", readRoots: [], writeRoots: [], deniedRoots: [] };
  assert.doesNotThrow(() => new ToolPolicy({ ...scope, mode: "workspace", approvalMode: "auto", planMode: true }));
  for (const bad of [{ mode: "workspace", approvalMode: "yolo" }, { mode: "workspace", approvalMode: "ask", planMode: "yes" },
    // Accepting edits or running commands automatically refines Workspace only.
    { mode: "read_only", approvalMode: "auto" }, { mode: "full_access", approvalMode: "accept_edits" }])
    assert.throws(() => new ToolPolicy({ ...scope, ...bad }), /unsupported/);
});
