// Explicit Mac setup actions; never starts a model turn or manages a second updater.
import { spawn } from "node:child_process";
import { loadSdk, inspectSdk, subscriptionEnvironment } from "./sdk-runtime.mjs";

const action = process.argv[2];
const runtime = await loadSdk();
if (action === "login") {
  const child = spawn(runtime.executable, ["auth", "login", "--claudeai"], {
    env: subscriptionEnvironment(), stdio: "inherit" });
  for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => child.kill(signal));
  child.once("error", () => { process.stderr.write("Claude sign-in could not open. Reinstall Wonder and try again.\n"); process.exitCode = 1; });
  child.once("exit", code => { process.exitCode = code ?? 1; });
} else if (action === "check") {
  const status = await inspectSdk(runtime);
  if (!status.connected) throw new Error("Sign in to your Claude subscription on this Mac.");
  console.log("Claude subscription connected. Compatible SDK updates install automatically between requests.");
} else throw new Error("Choose login or check.");
