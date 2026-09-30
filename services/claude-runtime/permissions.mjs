import { realpath } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { SandboxManager } from "@anthropic-ai/sandbox-runtime";
import shellQuote from "shell-quote";

let sandboxReady;
// SDK schema parsing can reorder object properties. Correlation follows JSON
// values while preserving array order and every argument's value.
export function toolCallKey(name, input) {
  return JSON.stringify([name, input], (_key, value) => value && typeof value === "object" && !Array.isArray(value)
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, value[key]])) : value);
}
const commandSandbox = { filesystem: { denyRead: [], allowRead: [], allowWrite: ["/"], denyWrite: [] },
  network: { allowedDomains: [], deniedDomains: [], allowLocalBinding: false, allowAllUnixSockets: false }, allowAppleEvents: false };
export async function closeCommandSandbox() {
  if (sandboxReady) { await sandboxReady; await SandboxManager.reset(); sandboxReady = null; }
}

const APPROVAL_MODES = ["ask", "accept_edits", "auto", "full_access"];
const EDIT_TOOLS = ["Edit", "Write", "NotebookEdit"];
const DENIED = "This action is outside this Bot's allowed tools or file access. Ask the owner to change access in Wonder.";
const PLAN_EDIT_DENIED = "Plan mode: describe the change instead of editing.";
const PLAN_REVIEW_DENIED = "The owner reviews the plan in Wonder. Stop here and wait for their reply; do not edit or run anything for this plan yet.";

const within = (path, root) => path === root || path.startsWith(root.endsWith(sep) ? root : `${root}${sep}`);

async function canonicalTarget(path) {
  try { return await realpath(path); }
  catch (error) {
    // Resolve existing ancestors for a new file, including symlinks. Other
    // errors fail closed; permission errors are not evidence of a missing file.
    if (error.code !== "ENOENT" || dirname(path) === path) throw error;
    return join(await canonicalTarget(dirname(path)), relative(dirname(path), path));
  }
}

export class ToolPolicy {
  constructor({ cwd, workspace = cwd, mode, approvalMode, planMode = false, readRoots, writeRoots, deniedRoots, internal = false, structuredOutput = false, tools = [], project = false }) {
    if (!isAbsolute(cwd ?? "") || !["read_only", "workspace", "full_access"].includes(mode)
      || !APPROVAL_MODES.includes(approvalMode) || typeof planMode !== "boolean"
      // Accepting edits or running commands automatically refines Workspace only.
      || (["accept_edits", "auto"].includes(approvalMode) && mode !== "workspace")) throw new Error("Claude permission scope is missing or unsupported");
    for (const roots of [readRoots, writeRoots, deniedRoots]) {
      if (!Array.isArray(roots) || roots.some(root => typeof root !== "string" || !isAbsolute(root))) throw new Error("Invalid Claude file scope");
    }
    if (!isAbsolute(workspace)) throw new Error("Invalid Claude workspace");
    Object.assign(this, { cwd, workspace, mode, approvalMode, planMode, readRoots, writeRoots, deniedRoots, internal, structuredOutput, project });
    this.tools = new Set(tools);
  }
  async permits(path, write = false) {
    if (typeof path !== "string" || !path.trim() || path.includes("\0")) return false;
    const lexical = resolve(this.cwd, path);
    let canonical;
    try { canonical = await canonicalTarget(lexical); } catch { return false; }
    for (const root of this.deniedRoots) {
      let resolvedRoot;
      try { resolvedRoot = await canonicalTarget(root); } catch { return false; }
      if (within(lexical, resolve(root)) || within(canonical, resolvedRoot)) {
        const owned = await canonicalTarget(this.workspace);
        const ownWorkspace = within(lexical, this.workspace) && within(canonical, owned)
          && within(owned, resolvedRoot) && owned !== resolvedRoot;
        if (!ownWorkspace) return false;
      }
    }
    if (write && this.mode === "read_only") return false;
    if (this.mode === "full_access") return true;
    for (const root of write ? this.writeRoots : [...this.readRoots, ...this.writeRoots]) {
      try {
        if (within(lexical, resolve(root)) && within(canonical, await canonicalTarget(root))) return true;
      } catch { /* A missing or inaccessible grant cannot widen access. */ }
    }
    return false;
  }
  async decision(name, input) {
    // The SDK emits schema-constrained answers through this intrinsic tool.
    // It returns data only, and is enabled only by the host's output schema.
    if (name === "StructuredOutput" && this.structuredOutput) return "allow";
    if (this.internal) return name === "mcp__wonder__wonder_ask_question" && this.tools.has("wonder_ask_question") ? "ask" : "deny";
    if (/^mcp__claude[-_]in[-_]chrome__/i.test(name)) return "deny";
    if (name.startsWith("mcp__")) return "ask";
    // In plan mode the owner reviews the plan in Wonder; Claude does not proceed on its own.
    if (name === "ExitPlanMode" && this.planMode) return "deny";
    if (["AskUserQuestion", "ExitPlanMode"].includes(name)) return "ask";
    // Loads tool definitions only. Invoking a discovered connector still asks
    // through this policy; large catalogs need not fill every model prompt.
    if (name === "ToolSearch") return "allow";
    if (name === "Agent") return input.isolation === "remote" ? "deny" : "allow";
    if (["TodoWrite", "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop", "EnterPlanMode"].includes(name)) return "allow";
    // Recursive built-ins execute outside the Bash sandbox and can traverse a
    // protected descendant of an otherwise readable folder. Use scoped Bash
    // for searches; Read checks each concrete file, including symlink targets.
    if (["Glob", "Grep"].includes(name)) return this.project && await this.searchable(input.path ?? this.cwd) ? "allow" : "deny";
    if (name === "Read")
      return await this.permits(input.file_path ?? input.path ?? this.cwd) ? "allow" : "deny";
    if (EDIT_TOOLS.includes(name)) {
      // A PreToolUse allow skips the SDK's own plan-mode check, so plan mode is enforced here.
      if (this.planMode || !await this.permits(input.file_path ?? input.notebook_path, true)) return "deny";
      return this.approvalMode === "ask" ? "ask" : "allow";
    }
    // Bash is always sandboxed. Never honor dangerousDisableSandbox or a model
    // request for a broader scope; the owner changes scope through Wonder. An
    // "allow" here still runs through canUseTool, which adds the sandbox.
    if (name === "Bash") return input.dangerouslyDisableSandbox ? "deny" : (this.autoRunsCommands ? "allow" : "ask");
    if (["WebFetch", "WebSearch"].includes(name)) return this.bypassesApproval ? "allow" : "ask";
    return "deny";
  }
  // Bypass permissions: nothing asks, except while planning.
  get bypassesApproval() { return this.approvalMode === "full_access" && !this.planMode; }
  // Commands run without asking (always inside the sandbox) in Auto and Bypass modes, never while planning.
  get autoRunsCommands() { return ["auto", "full_access"].includes(this.approvalMode) && !this.planMode; }
  // Text returned to Claude when a tool call is refused.
  denial(name) {
    if (this.planMode && EDIT_TOOLS.includes(name)) return PLAN_EDIT_DENIED;
    if (this.planMode && name === "ExitPlanMode") return PLAN_REVIEW_DENIED;
    return DENIED;
  }
  // Project code search is allowed only where no protected folder can be
  // traversed below the search root, because Glob/Grep run outside the sandbox.
  async searchable(path) {
    if (!await this.permits(path)) return false;
    let base;
    try { base = await canonicalTarget(resolve(this.cwd, path)); } catch { return false; }
    for (const root of this.deniedRoots) {
      let target;
      try { target = await canonicalTarget(root); } catch { return false; }
      if (within(target, base) || within(base, target)) return false;
    }
    return true;
  }
  async beforeTool(event) {
    const decision = await this.decision(event.tool_name, event.tool_input ?? {});
    // Always pass Bash through canUseTool, including automatic approval, so
    // every execution receives the host-owned filesystem sandbox.
    const result = { hookEventName: "PreToolUse", permissionDecision: event.tool_name === "Bash" && decision !== "deny" ? "ask" : decision };
    if (decision === "deny") result.permissionDecisionReason = this.denial(event.tool_name);
    if (event.tool_name === "Agent" && decision === "allow") {
      // Child work inherits the parent's selected model. In particular, Haiku
      // validation must not silently start a more expensive helper model.
      const { model, ...input } = event.tool_input;
      // A child stays within the parent turn's owned lifetime. The SDK now
      // defaults to background agents; that can leave the parent saying it is
      // waiting after its result frame. Foreground agents still stream their
      // own rows and can run alongside sibling tool calls.
      result.updatedInput = { ...input, run_in_background: false };
    }
    return { hookSpecificOutput: result };
  }
  async commandInput(input) {
    if (process.platform !== "darwin") throw new Error("Claude commands require the Mac file sandbox.");
    const paths = async roots => [...new Set((await Promise.all(roots.map(async root => [resolve(root), await canonicalTarget(root)]))).flat())];
    const owned = await canonicalTarget(this.workspace);
    const filter = root => `(subpath ${JSON.stringify(root)})`;
    const outside = roots => `(require-all ${roots.map(root => `(require-not ${filter(root)})`).join(" ")})`;
    const rules = [];
    if (this.mode !== "full_access" && !this.readRoots.includes("/")) {
      const reads = await paths([...this.readRoots, ...this.writeRoots,
        "/bin", "/sbin", "/usr", "/System", "/Library/Apple", "/Library/Developer", "/private/etc", "/dev"]);
      rules.push(`(deny file-read* ${outside(reads)})`);
      rules.push("(allow file-read-metadata (vnode-type DIRECTORY))");
    }
    if (this.mode !== "full_access") {
      const writes = this.mode === "read_only" ? [] : await paths(this.writeRoots);
      rules.push(`(deny file-write* file-write-create file-write-unlink ${outside([...writes, "/dev/null", "/dev/tty"])})`);
    }
    for (const root of await paths(this.deniedRoots)) {
      const exception = owned !== root && within(owned, root) ? ` (require-not ${filter(owned)})` : "";
      rules.push(`(deny file-read* file-write* file-write-create file-write-unlink (require-all ${filter(root)}${exception}))`);
      // Prevent moving an enclosing folder to escape path-based restrictions.
      for (let parent = root; parent !== "/"; parent = dirname(parent))
        rules.push(`(deny file-write-unlink (literal ${JSON.stringify(parent)}))`);
    }
    // The pinned Anthropic runtime supplies process/network isolation. Append
    // our exact file restrictions to its Seatbelt profile: macOS does not
    // reliably allow nested restrictive sandboxes. Reject a changed wrapper
    // shape instead of ever running an unguarded command.
    sandboxReady ??= SandboxManager.initialize(commandSandbox, undefined, false);
    await sandboxReady;
    const isolated = await SandboxManager.wrapWithSandbox(input.command, "/bin/bash");
    const argv = shellQuote.parse(isolated, {});
    const index = argv.indexOf("/usr/bin/sandbox-exec");
    if (argv.some(a => typeof a !== "string") || index < 0 || argv[index + 1] !== "-p"
      || !argv[index + 2]?.startsWith("(version 1)\n(deny default") || argv[index + 3] !== "/bin/bash")
      throw new Error("The Mac command sandbox returned an incompatible execution format.");
    argv[index + 2] += "\n" + rules.join("\n");
    return { ...input, command: shellQuote.quote(argv) };
  }
  sandbox() {
    // Wonder wraps every approved Bash call with the pinned sandbox above.
    // Do not put the SDK's changing sandbox outside that host-owned boundary.
    return { enabled: false };
  }
}
