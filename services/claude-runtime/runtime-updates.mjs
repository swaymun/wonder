import { mkdir, readFile, rename, open, readdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { loadSdk, inspectSdk, subscriptionEnvironment } from "./sdk-runtime.mjs";

const execute = promisify(execFile);
const DAY = 24 * 60 * 60 * 1000;
const REGISTRY = "https://registry.npmjs.org";

export function compatibleVersion(candidate, baseline) {
  const parse = value => /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(value)?.slice(1).map(Number);
  const c = parse(candidate), b = parse(baseline);
  // Pre-1.0 SDK minor releases may break the host contract. They need an adapter
  // review; compatible patch updates need no Wonder app release.
  return !!(c && b && c[0] === b[0] && (b[0] !== 0 || c[1] === b[1])
    && (c[1] > b[1] || (c[1] === b[1] && c[2] >= b[2])));
}

export async function writeJson(path, value) {
  const temporary = `${path}.${process.pid}.tmp`;
  const file = await open(temporary, "w", 0o600);
  try { await file.writeFile(JSON.stringify(value)); await file.sync(); } finally { await file.close(); }
  await rename(temporary, path);
  const directory = await open(dirname(path), "r");
  try { await directory.sync(); } finally { await directory.close(); }
}

// One owner in the daemon sidecar. Staging never changes an in-flight Query or
// its executable. The bundled SDK remains the recovery path on every launch.
export class RuntimeUpdates {
  constructor({ root, npm, bundled, load = loadSdk, check = inspectSdk, install, latest, clock = Date.now }) {
    Object.assign(this, { root, npm, bundled, load, check, clock });
    this.abort = new AbortController();
    this.install = install ?? (version => this.installPackage(version));
    this.latest = latest ?? (async () => {
      const response = await fetch(`${REGISTRY}/@anthropic-ai%2Fclaude-agent-sdk/latest`, { signal: AbortSignal.any([this.abort.signal, AbortSignal.timeout(10_000)]) });
      if (!response.ok) throw new Error("registry_unavailable");
      return (await response.json()).version;
    });
    this.users = 0; this.pending = null; this.state = {};
    this.current = bundled; this.refreshing = null; this.activating = null;
  }
  async initialize() {
    await mkdir(join(this.root, "versions"), { recursive: true, mode: 0o700 });
    try { this.state = JSON.parse(await readFile(join(this.root, "state.json"), "utf8")); } catch { this.state = {}; }
    for (const version of [this.state.active, this.state.lastGood]) {
      if (!compatibleVersion(version, this.bundled.version) || version === this.bundled.version) continue;
      try {
        const runtime = await this.load(join(this.root, "versions", version));
        if (runtime.version !== version) throw new Error("version_mismatch");
        await this.check(runtime);
        this.current = runtime; break;
      } catch { this.state.lastFailure = "saved_runtime_incompatible"; }
    }
    this.state.active = this.current.version;
    if (compatibleVersion(this.state.staged, this.bundled.version) && this.state.staged !== this.current.version) {
      try {
        const candidate = await this.load(join(this.root, "versions", this.state.staged));
        if (candidate.version !== this.state.staged) throw new Error("version_mismatch");
        await this.check(candidate); this.pending = candidate;
      } catch { this.state.staged = null; this.state.lastFailure = "saved_candidate_incompatible"; }
    }
    await this.save();
    await this.activate();
    await this.prune();
    return this;
  }
  async save() { await writeJson(join(this.root, "state.json"), this.state); }
  async acquire() {
    if (this.activating) await this.activating;
    this.users += 1;
    let released = false;
    return { runtime: this.current, release: async () => {
      if (released) return;
      released = true; this.users -= 1;
      await this.activate();
    } };
  }
  async activate() {
    if (this.activating) return this.activating;
    if (this.abort.signal.aborted || this.users || this.staging || !this.pending) return;
    this.activating = this.activateIdle().finally(() => { this.activating = null; });
    return this.activating;
  }
  async activateIdle() {
    const candidate = this.pending;
    // Persist first: if storage fails, the known-good runtime stays active.
    const previous = { ...this.state };
    this.state = { ...this.state, active: candidate.version, lastGood: this.current.version, staged: null };
    try { await this.save(); } catch (error) { this.state = previous; throw error; }
    this.pending = null; this.current = candidate;
    await this.prune();
  }
  async refresh({ force = false } = {}) {
    if (this.abort.signal.aborted) return;
    if (this.refreshing) return this.refreshing;
    if (!force && this.clock() - (this.state.checkedAt ?? 0) < DAY) return;
    this.refreshing = this.stage().finally(() => { this.refreshing = null; });
    return this.refreshing;
  }
  async stage() {
    if (this.pending) { await this.activate(); return; }
    this.staging = true;
    this.state.checkedAt = this.clock();
    try {
      const version = await this.latest();
      if (!compatibleVersion(version, this.bundled.version)) {
        this.state.lastFailure = "adapter_update_required";
      } else if (version !== this.current.version && compatibleVersion(version, this.current.version)) {
        const root = await this.install(version);
        const candidate = await this.load(root);
        if (candidate.version !== version) throw new Error("version_mismatch");
        await this.check(candidate);
        this.pending = candidate; this.state.staged = version; this.state.lastFailure = null;
      }
    } catch { this.state.lastFailure = "candidate_unavailable_or_incompatible"; }
    try { await this.save(); } finally { this.staging = false; }
    await this.activate();
    await this.prune();
  }
  async prune() {
    if (this.users) return;
    const keep = new Set([this.current.version, this.state.lastGood, this.pending?.version]);
    // Only manager-owned version directories. Never follow links or remove
    // bundled files, credential state, SDK transcripts or an in-flight runtime.
    for (const entry of await readdir(join(this.root, "versions"), { withFileTypes: true })) {
      if (entry.isDirectory() && /^\d+\.\d+\.\d+$/.test(entry.name) && !keep.has(entry.name))
        await rm(join(this.root, "versions", entry.name), { recursive: true, force: true });
    }
  }
  async installPackage(version) {
    if (!this.npm || !compatibleVersion(version, this.bundled.version)) throw new Error("installer_unavailable");
    const root = join(this.root, "versions", version);
    await mkdir(root, { recursive: true, mode: 0o700 });
    await writeJson(join(root, "package.json"), { private: true, dependencies: {
      "@anthropic-ai/claude-agent-sdk": version, zod: "4.6.5" } });
    // npm verifies registry integrity hashes. No lifecycle scripts, user npm
    // credentials, custom registries, or inherited NODE_OPTIONS are accepted.
    await execute(process.execPath, [this.npm, "install", "--ignore-scripts", "--no-audit", "--no-fund", "--no-bin-links",
      `--registry=${REGISTRY}`, "--userconfig=/dev/null"], { cwd: root, timeout: 180_000, maxBuffer: 128 * 1024,
      signal: this.abort.signal,
      env: { ...subscriptionEnvironment(), NPM_CONFIG_IGNORE_SCRIPTS: "true", NPM_CONFIG_REGISTRY: REGISTRY } });
    return root;
  }
  status() {
    return { activeVersion: this.current.version, bundledVersion: this.bundled.version,
      pendingVersion: this.pending?.version ?? null, checkedAtMs: this.state.checkedAt ?? null,
      lastFailure: this.state.lastFailure ?? null };
  }
  async close() {
    this.abort.abort();
    await Promise.allSettled([this.refreshing, this.activating].filter(Boolean));
  }
}
