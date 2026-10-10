// Explicit Mac setup actions; never starts a model turn or manages a second updater.
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { loadSdk, inspectSdk, subscriptionEnvironment, classifyAuthStatus } from "./sdk-runtime.mjs";
import { activeRuntime } from "./runtime-updates.mjs";

const action = process.argv[2];
let runtime;
try {
  // Act on the SDK the sidecar runs: an activated update replaces the bundled
  // one, and its CLI is the version Settings → Providers reports.
  const root = join(process.env.WONDER_DATA_DIR || join(homedir(), ".wonder"), "claude-runtime", "sdk");
  runtime = await activeRuntime({ root, bundled: await loadSdk() });
} catch {
  process.stderr.write("Wonder's Claude runtime is missing or damaged. Reinstall Wonder.\n");
  // Status distinguishes a missing runtime; other actions keep their generic failure.
  process.exit(action === "status" ? 44 : 1);
}

function run(args, { capture = false } = {}) {
  return new Promise(resolve => {
    const child = spawn(runtime.executable, args, {
      env: subscriptionEnvironment(), stdio: capture ? ["ignore", "pipe", "inherit"] : "inherit" });
    let output = "";
    child.stdout?.setEncoding("utf8").on("data", chunk => { if (output.length < 65_536) output += chunk; });
    // Cancelling from Settings terminates this process; pass that on to the CLI.
    const forward = signal => child.kill(signal);
    const finish = code => {
      for (const signal of ["SIGINT", "SIGTERM"]) process.off(signal, forward);
      resolve({ code, output });
    };
    for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, forward);
    child.once("error", () => finish(null));
    child.once("exit", code => finish(code));
  });
}

if (action === "login" || action === "logout") {
  const { code } = await run(action === "login" ? ["auth", "login", "--claudeai"] : ["auth", "logout"]);
  if (code === null) process.stderr.write(`Claude ${action === "login" ? "sign-in" : "sign-out"} could not open. Reinstall Wonder and try again.\n`);
  process.exitCode = code ?? 1;
} else if (action === "status") {
  const version = await run(["--version"], { capture: true });
  const label = version.code === 0 ? version.output.trim().split("\n")[0].replace(/\s*\(Claude Code\)$/, "") : runtime.version;
  const auth = await run(["auth", "status", "--json"], { capture: true });
  let parsed = null;
  try { parsed = JSON.parse(auth.output); } catch { /* Classified as unreadable below. */ }
  const { exitCode, account } = auth.code === 0 || auth.code === 1 ? classifyAuthStatus(parsed) : { exitCode: 1, account: "" };
  if (exitCode === 1) process.stderr.write("Claude sign-in status could not be read.\n");
  process.stdout.write(`${label}\t${account}\n`);
  process.exitCode = exitCode;
} else if (action === "check") {
  const status = await inspectSdk(runtime);
  if (!status.connected) {
    process.stderr.write("Sign in to your Claude subscription on this Mac.\n");
    process.exitCode = 42; // Distinct from runtime/transport failures.
  } else {
    console.log("Claude subscription connected. Compatible SDK updates install automatically between requests.");
  }
} else throw new Error("Choose login, logout, status or check.");
