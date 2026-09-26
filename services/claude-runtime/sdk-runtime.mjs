import { createRequire } from "node:module";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { HAIKU_MODEL, usageWindow } from "./projection.mjs";

export async function loadSdk(packageRoot) {
  const require = createRequire(packageRoot ? join(packageRoot, "package.json") : import.meta.url);
  const entry = require.resolve("@anthropic-ai/claude-agent-sdk");
  const metadata = JSON.parse(await readFile(join(dirname(entry), "package.json"), "utf8"));
  const sdk = await import(pathToFileURL(entry).href);
  for (const name of ["query", "tool", "createSdkMcpServer"]) {
    if (typeof sdk[name] !== "function") throw new Error(`Claude SDK is missing ${name}`);
  }
  const executable = require.resolve(`@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}/claude`);
  return { sdk, executable, version: metadata.version };
}

// Never inherit API billing, custom endpoints, prompt overrides, or host credentials.
// Normal HOME preserves the official CLI's Keychain subscription login.
export function subscriptionEnvironment(source = process.env) {
  const env = {};
  for (const name of ["HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL"])
    if (source[name] !== undefined) env[name] = source[name];
  // The aggregate NONESSENTIAL flag also disables account usage discovery.
  // Disable telemetry and the CLI's own updater separately; Wonder owns SDK updates.
  return { ...env, DISABLE_TELEMETRY: "1", DISABLE_ERROR_REPORTING: "1", DISABLE_AUTOUPDATER: "1",
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION: "false", CLAUDE_AGENT_SDK_CLIENT_APP: "wonder/1.0" };
}

export function isSubscription(account) {
  return account?.apiProvider === "firstParty"
    && /^(Claude )?(Pro|Max|Team|Enterprise)$/i.test(account.subscriptionType ?? "")
    && (account.apiKeySource == null || account.apiKeySource === "none")
    && (account.tokenSource == null || account.tokenSource === "claude.ai");
}

export function baseOptions(runtime) {
  return { pathToClaudeCodeExecutable: runtime.executable, env: subscriptionEnvironment(),
    extraArgs: { "no-chrome": null },
    model: HAIKU_MODEL, settingSources: [], plugins: [], strictMcpConfig: true,
    settings: { autoMemoryEnabled: false, switchModelsOnFlag: false, autoContinueAtUsageLimit: false },
    promptSuggestions: false, agentProgressSummaries: false, stderr: () => {} };
}

export function projectUsage(result) {
  if (result?.rate_limits_available !== true || !result.rate_limits || typeof result.rate_limits !== "object") return null;
  const windows = Object.entries(result.rate_limits).flatMap(([type, value]) => {
    const window = usageWindow(type, value ? { ...value, format: "percent" } : null);
    return window ? [window] : [];
  });
  return windows.length ? windows : null;
}

// These control requests initialize the runtime but never submit a user prompt.
// Keep experimental account data behind this adapter, not in the native protocol.
export async function inspectSdk(runtime, { cwd, includeUsage = false, connectors = false } = {}) {
  const abortController = new AbortController();
  const done = Promise.withResolvers();
  const timer = setTimeout(() => abortController.abort(), 30_000);
  const query = runtime.sdk.query({ prompt: (async function* () { await done.promise; })(),
    options: { ...baseOptions(runtime), cwd, abortController, tools: [], mcpServers: {},
      permissionMode: "dontAsk", permissionPrompts: "none", persistSession: false,
      settings: { ...baseOptions(runtime).settings, disableAllHooks: true, disableClaudeAiConnectors: !connectors } } });
  try {
    for (const method of ["initializationResult", "accountInfo", "supportedModels", "mcpServerStatus", "interrupt", "close"])
      if (typeof query[method] !== "function") throw new Error(`Claude runtime is missing ${method}`);
    await query.initializationResult();
    const account = await query.accountInfo();
    const models = await query.supportedModels();
    if (!Array.isArray(models) || !models.some(m => typeof m.value === "string" && m.value.includes("haiku")))
      throw new Error("Claude runtime returned an incompatible model catalog");
    const connected = isSubscription(account);
    const usageMethod = query.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET;
    let windows = null;
    if (includeUsage && connected && typeof usageMethod === "function") {
      try { windows = projectUsage(await usageMethod.call(query, { skipBehaviors: true })); } catch { /* Usage is optional; never fake a zero. */ }
    }
    const servers = connectors && connected ? await query.mcpServerStatus() : [];
    return { version: runtime.version, connected, subscription: connected ? account.subscriptionType : null,
      models: models.map(m => ({ id: m.value, name: m.displayName, description: m.description,
        efforts: m.supportsEffort ? (m.supportedEffortLevels ?? []).filter(e => ["low", "medium", "high", "xhigh", "max"].includes(e)) : [] })),
      usageSupported: typeof usageMethod === "function", windows,
      servers: servers.map(s => ({ name: s.name, status: s.status, source: s.source })) };
  } finally {
    clearTimeout(timer); done.resolve(); query.close(); abortController.abort();
  }
}
