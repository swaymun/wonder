import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

const origin = (process.env.WONDER_PUBLIC_ORIGIN ?? "").replace(/\/$/, "");
assert.match(origin, /^https:\/\/[^\s/]+$/, "WONDER_PUBLIC_ORIGIN must be an HTTPS origin");

function curl(path, options = {}) {
  const args = ["-4", "--connect-timeout", "5", "--max-time", "15", "-sS", "-w", "\n%{http_code}"];
  if (options.method) args.push("-X", options.method);
  if (options.origin !== false) args.push("-H", `origin: ${origin}`);
  if (options.body) args.push("-H", "content-type: application/json", "--data", options.body);
  args.push(`${origin}${path}`);
  const output = execFileSync("curl", args, { encoding: "utf8", timeout: 20_000 });
  const split = output.lastIndexOf("\n");
  return { body: output.slice(0, split), status: Number(output.slice(split + 1)) };
}

const shell = curl("/pair", { origin: false });
assert.equal(shell.status, 200, "the public native-pairing page should be reachable");
assert.match(shell.body, /<html/i, "the public response should be HTML");

const unpairedRoot = curl("/", { origin: false });
assert.equal(unpairedRoot.status, 307, "an unpaired browser must be redirected to pairing");

for (const path of ["/manifest.webmanifest", "/precache-manifest.json", "/assets/index.js", "/index.html", "/bots"]) {
  assert.equal(curl(path, { origin: false }).status, 404, `${path} must no longer serve a browser app`);
}
const retirement = curl("/sw.js", { origin: false });
assert.equal(retirement.status, 200);
assert.match(retirement.body, /registration\.unregister/);
assert.doesNotMatch(retirement.body, /addEventListener\(["']fetch/);
assert.doesNotMatch(shell.body, /<script|rel=["']manifest/i);

const protectedBots = curl("/api/v1/bots");
assert.equal(protectedBots.status, 401, "unpaired public clients must not read Bot data");
assert.match(protectedBots.body, /Wonder session required/);

const protectedConnections = curl("/api/v1/runtime/capabilities");
assert.equal(protectedConnections.status, 401, "unpaired public clients must not read runtime connection data");
assert.match(protectedConnections.body, /Wonder session required/);

const wrongOriginPairing = curl("/api/v1/pairing/code", {
  method: "POST",
  body: JSON.stringify({}),
  origin: false,
});
assert.equal(wrongOriginPairing.status, 403, "pairing claims must reject requests without the public origin");

const wrongOriginProtectedApi = (() => {
  const args = ["-4", "--connect-timeout", "5", "--max-time", "15", "-sS", "-w", "\n%{http_code}", "-H", "origin: https://not-wonder.example", `${origin}/api/v1/bots`];
  const output = execFileSync("curl", args, { encoding: "utf8", timeout: 20_000 });
  const split = output.lastIndexOf("\n");
  return { body: output.slice(0, split), status: Number(output.slice(split + 1)) };
})();
assert.equal(wrongOriginProtectedApi.status, 403, "protected API requests must reject a wrong origin before session handling");

console.log(`verified native pairing page, retired browser app, and unpaired API boundary at ${origin}`);
