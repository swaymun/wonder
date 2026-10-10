import { realpathSync } from "node:fs";
import { realpath } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

// SDK schema parsing can reorder object properties. Correlation follows JSON
// values while preserving array order and every argument's value.
export function toolCallKey(name, input) {
  return JSON.stringify([name, input], (_key, value) => value && typeof value === "object" && !Array.isArray(value)
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, value[key]])) : value);
}

// Hosts sandboxed Project commands reach without asking. Any other host asks
// the owner, who can save it to the project's Claude Code settings.
export const ALLOWED_DOMAINS = ["github.com", "*.github.com", "*.githubusercontent.com",
  "registry.npmjs.org", "registry.yarnpkg.com", "repo.yarnpkg.com", "crates.io", "*.crates.io", "static.rust-lang.org",
  "pypi.org", "files.pythonhosted.org", "proxy.golang.org", "sum.golang.org", "formulae.brew.sh", "ghcr.io",
  "api.cloudflare.com", "api.anthropic.com", "api.openai.com"];
// Toolchains and their caches in $HOME. The rest of $HOME stays unreadable to
// sandboxed Project commands. Executable folders on PATH stay read-only so a
// command cannot plant a program that later runs outside the sandbox.
const HOME_READ = [".cargo", ".rustup", ".npm", ".nvm", ".yarn", ".bun", ".deno", ".volta", ".pyenv", ".rbenv", ".asdf",
  ".gradle", ".m2", "go", ".swiftpm", ".cache", ".local/bin", ".local/lib", ".gitconfig", ".gitignore_global", ".config/git",
  "Library/Caches", "Library/Developer", "Library/pnpm", ".pnpm-store",
  // git's osxkeychain credential helper reads this file; other keychains stay closed.
  "Library/Keychains/login.keychain-db"];
const HOME_WRITE = [".cargo/registry", ".cargo/git", ".npm", ".yarn/berry/cache", ".bun/install/cache", ".cache",
  "Library/Caches", "Library/pnpm/store", ".pnpm-store", ".gradle/caches", ".m2/repository", "go/pkg/mod",
  "Library/Developer/Xcode/DerivedData"];
// Claude Code reads these; an agent that edits them could widen its own sandbox.
const SETTINGS_FILES = ["settings.json", "settings.local.json"];
const real = path => { try { return realpathSync(path); } catch { return path; } };
const both = paths => [...new Set(paths.flatMap(path => [path, real(path)]))];

const APPROVAL_MODES = ["ask", "accept_edits", "auto", "full_access"];
const EDIT_TOOLS = ["Edit", "Write", "NotebookEdit"];
const DENIED = "This action is outside this conversation’s allowed tools or file access. Ask the owner to change access in Wonder.";
// Appended to Claude Code's own sandbox guidance, which names CLI-only controls.
export const SANDBOX_GUIDANCE = "Commands run in Wonder's sandbox. The owner steers this conversation from Wonder, not a terminal: they cannot use `/sandbox`, `!` commands or settings files. When the sandbox blocks a host or a command, retrying the command reaches the owner as an approval on their phone. To lift the sandbox for the whole conversation, the owner chooses Full access in the shield menu.";
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
  // `projectRoots` lists a Project's folders; it is empty for Bots and chats.
  constructor({ cwd, workspace = cwd, mode, approvalMode, planMode = false, readRoots, writeRoots, deniedRoots, projectRoots = [], internal = false, structuredOutput = false, tools = [], project = false, home = homedir() }) {
    if (!isAbsolute(cwd ?? "") || !["read_only", "workspace", "full_access"].includes(mode)
      || !APPROVAL_MODES.includes(approvalMode) || typeof planMode !== "boolean"
      // Accepting edits or running commands automatically refines Workspace only.
      || (["accept_edits", "auto"].includes(approvalMode) && mode !== "workspace")) throw new Error("Claude permission scope is missing or unsupported");
    for (const roots of [readRoots, writeRoots, deniedRoots, projectRoots]) {
      if (!Array.isArray(roots) || roots.some(root => typeof root !== "string" || !isAbsolute(root))) throw new Error("Invalid Claude file scope");
    }
    if (!isAbsolute(workspace) || !isAbsolute(home)) throw new Error("Invalid Claude workspace");
    Object.assign(this, { cwd, workspace, mode, approvalMode, planMode, readRoots, writeRoots, deniedRoots, projectRoots, internal, structuredOutput, project, home });
    this.tools = new Set(tools);
  }
  // Projects follow Claude Code: no sandbox, and its permission mode decides
  // what asks. Read only, no longer offered, keeps the sandbox that enforces it.
  get unsandboxed() { return this.project && !this.internal && this.mode !== "read_only"; }
  // Claude Code's own rules decide commands and web access, including its
  // read-only command checks and Auto's classifier. Whatever it would ask
  // reaches the owner through canUseTool.
  get defersToClaudeCode() { return this.unsandboxed && !this.bypassesApproval; }
  get permissionMode() { return this.planMode ? "plan" : this.unsandboxed && this.approvalMode === "auto" ? "auto" : "default"; }
  // Sandboxed Projects confine $HOME to the project and toolchains, for
  // commands and for Claude's own file tools alike.
  get confinesHome() { return this.project && !this.internal && !this.unsandboxed; }
  homeReadable() { return [...this.projectRoots, ...HOME_READ.map(path => join(this.home, path))]; }
  async permits(path, write = false) {
    if (typeof path !== "string" || !path.trim() || path.includes("\0")) return false;
    const lexical = resolve(this.cwd, path);
    let canonical;
    try { canonical = await canonicalTarget(lexical); } catch { return false; }
    if (this.confinesHome && within(canonical, real(this.home))
      && !this.homeReadable().some(root => within(lexical, root) || within(canonical, real(root)))) return false;
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
      const target = input.file_path ?? input.notebook_path;
      if (this.planMode || !await this.permits(target, true)) return "deny";
      // These settings can add permission rules, so changing them asks unless nothing asks.
      if ((!this.unsandboxed || !this.bypassesApproval) && typeof target === "string" && SETTINGS_FILES.includes(basename(target)) && basename(dirname(target)) === ".claude") return "ask";
      return this.approvalMode === "ask" ? "ask" : "allow";
    }
    if (name === "Bash") {
      // Leaving the sandbox is never automatic. Projects ask the owner; Bots and
      // chats, which act on other people's messages, cannot leave it.
      if (input.dangerouslyDisableSandbox && !this.unsandboxed) return this.project && !this.internal && !this.planMode ? "ask" : "deny";
      return this.autoRunsCommands ? "allow" : "ask";
    }
    // A sandboxed command reached a host outside the allowlist.
    if (name === "SandboxNetworkAccess") return this.project && !this.internal ? "ask" : "deny";
    if (["WebFetch", "WebSearch"].includes(name)) return this.bypassesApproval ? "allow" : "ask";
    return "deny";
  }
  // Bypass permissions: nothing asks, except while planning.
  get bypassesApproval() { return this.approvalMode === "full_access" && !this.planMode; }
  // Commands run without asking in Bypass, and in Auto only inside the sandbox;
  // never while planning.
  get autoRunsCommands() { return !this.planMode && (this.approvalMode === "full_access" || (this.approvalMode === "auto" && !this.unsandboxed)); }
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
    if (decision === "ask" && this.defersToClaudeCode && ["Bash", "WebFetch", "WebSearch"].includes(event.tool_name)) return {};
    // Always pass Bash through canUseTool, including automatic approval, so
    // every execution applies the host-owned command policy.
    const result = { hookEventName: "PreToolUse", permissionDecision: event.tool_name === "Bash" && decision !== "deny" ? "ask" : decision };
    if (decision === "deny") result.permissionDecisionReason = this.denial(event.tool_name);
    if (event.tool_name === "Agent" && decision === "allow") {
      // Child work inherits the parent's selected model. In particular, Haiku
      // validation must not silently start a more expensive helper model.
      const { model, ...input } = event.tool_input;
      // A Bot's child stays within the parent turn's owned lifetime: a
      // background agent could leave the Bot saying it is waiting after its
      // result frame. A Project follows Claude Code, whose agents may run in
      // the background while the conversation takes new messages; the bridge
      // keeps the process up for them (see ClaudeBridge.linger).
      result.updatedInput = this.project && !this.internal ? input : { ...input, run_in_background: false };
    }
    return { hookSpecificOutput: result };
  }
  // Claude Code's own command sandbox, configured from the host-owned policy.
  // Project and user Claude Code settings merge into it, as in the CLI.
  sandbox() {
    if (this.unsandboxed) return { enabled: false };
    const owned = real(this.workspace);
    const project = this.project && !this.internal;
    const writes = this.mode === "read_only" ? [] : this.mode === "full_access" && !project ? ["/"] : this.writeRoots;
    const tmp = [tmpdir(), "/tmp", "/private/tmp"];
    // A Bot's own workspace may sit inside Wonder's protected data folder.
    const reopened = both([this.workspace]).filter(path => this.deniedRoots.some(root => within(path, root) || within(path, real(root))));
    const denyRead = both(project ? [this.home, ...this.deniedRoots]
      : this.readRoots.includes("/") ? this.deniedRoots : ["/Users", "/Volumes", "/private/var", "/private/tmp", ...this.deniedRoots]);
    const allowRead = both(project ? this.homeReadable() : this.readRoots.includes("/") ? [] : [...this.readRoots, ...this.writeRoots])
      .filter(path => !this.deniedRoots.some(root => within(path, root) || within(path, real(root))) || reopened.includes(path))
      .concat(reopened);
    return {
      enabled: true, failIfUnavailable: true, autoAllowBashIfSandboxed: false,
      // Projects may retry a command outside the sandbox; decision() asks the
      // owner. As in the CLI, this also honors the repository's committed
      // `sandbox.excludedCommands`, which canUseTool cannot tell apart; the
      // agent cannot add exclusions (settings edits ask, and commands cannot
      // write them). Bots never leave the sandbox and ignore exclusions.
      allowUnsandboxedCommands: project,
      network: project
        // Tests bind local ports; git's fsmonitor uses a socket and FSEvents.
        ? { allowedDomains: ALLOWED_DOMAINS, allowLocalBinding: true, allowAllUnixSockets: true, allowMachLookup: ["com.apple.FSEvents"] }
        : { allowedDomains: [], strictAllowlist: true },
      filesystem: {
        allowWrite: both([...writes, ...(project ? [...tmp, ...HOME_WRITE.map(path => join(this.home, path))] : [])]),
        // Protected folders stay closed inside writable roots, except the one
        // holding the owned workspace. Claude Code always lets commands write
        // the working folder, so Read only denies it explicitly.
        denyWrite: both([...this.deniedRoots.filter(root => !within(owned, root) && !within(owned, real(root))),
          ...(this.mode === "read_only" ? [this.cwd, ...this.projectRoots] : [])]),
        denyRead: [...new Set(denyRead)], allowRead: [...new Set(allowRead)],
      },
    };
  }
}
