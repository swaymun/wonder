import { realpath } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { SandboxManager } from "@anthropic-ai/sandbox-runtime";
import shellQuote from "shell-quote";

let sandboxReady;
const commandSandbox = { filesystem: { denyRead: [], allowRead: [], allowWrite: ["/"], denyWrite: [] },
  network: { allowedDomains: [], deniedDomains: [], allowLocalBinding: false, allowAllUnixSockets: false }, allowAppleEvents: false };
export async function closeCommandSandbox() {
  if (sandboxReady) { await sandboxReady; await SandboxManager.reset(); sandboxReady = null; }
}

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
  constructor({ cwd, workspace = cwd, mode, approvalMode, readRoots, writeRoots, deniedRoots, internal = false, structuredOutput = false, tools = [] }) {
    if (!isAbsolute(cwd ?? "") || !["read_only", "workspace", "full_access"].includes(mode)
      || !["ask", "full_access"].includes(approvalMode)) throw new Error("Claude permission scope is missing or unsupported");
    for (const roots of [readRoots, writeRoots, deniedRoots]) {
      if (!Array.isArray(roots) || roots.some(root => typeof root !== "string" || !isAbsolute(root))) throw new Error("Invalid Claude file scope");
    }
    if (!isAbsolute(workspace)) throw new Error("Invalid Claude workspace");
    Object.assign(this, { cwd, workspace, mode, approvalMode, readRoots, writeRoots, deniedRoots, internal, structuredOutput });
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
    if (["AskUserQuestion", "ExitPlanMode"].includes(name)) return "ask";
    if (name === "Agent") return input.isolation === "remote" ? "deny" : "allow";
    if (["TodoWrite", "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop", "EnterPlanMode"].includes(name)) return "allow";
    // Recursive built-ins execute outside the Bash sandbox and can traverse a
    // protected descendant of an otherwise readable folder. Use scoped Bash
    // for searches; Read checks each concrete file, including symlink targets.
    if (["Glob", "Grep"].includes(name)) return "deny";
    if (name === "Read")
      return await this.permits(input.file_path ?? input.path ?? this.cwd) ? "allow" : "deny";
    if (["Edit", "Write", "NotebookEdit"].includes(name)) {
      if (!await this.permits(input.file_path ?? input.notebook_path, true)) return "deny";
      return this.approvalMode === "full_access" ? "allow" : "ask";
    }
    // Bash is always sandboxed. Never honor dangerousDisableSandbox or a model
    // request for a broader scope; the owner changes scope through Wonder.
    if (name === "Bash") return input.dangerouslyDisableSandbox ? "deny" : (this.approvalMode === "full_access" ? "allow" : "ask");
    if (["WebFetch", "WebSearch"].includes(name)) return this.approvalMode === "full_access" ? "allow" : "ask";
    return "deny";
  }
  async beforeTool(event) {
    const decision = await this.decision(event.tool_name, event.tool_input ?? {});
    // Always pass Bash through canUseTool, including automatic approval, so
    // every execution receives the host-owned filesystem sandbox.
    const result = { hookEventName: "PreToolUse", permissionDecision: event.tool_name === "Bash" && decision !== "deny" ? "ask" : decision };
    if (decision === "deny") result.permissionDecisionReason = "This action is outside this Bot's allowed tools or file access. Ask the owner to change access in Wonder.";
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
