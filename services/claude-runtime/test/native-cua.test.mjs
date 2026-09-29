// Contract: the production transport preserves provider approvals/results and
// host ownership, and cancellation still performs exactly one hidden cleanup.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createNativeCua } from '../native-cua.mjs';

const sdk = { tool: (name, description, schema, handler) => ({ name, handler }),
  createSdkMcpServer: ({ tools }) => ({ tools }) };
const context = { toolUseID: 'owned-tool-call', mcpServer: { name: 'cua_repl', source: 'sdk' } };
const ids = { sessionId: 'owned-sdk-session', threadId: 'owned-wonder-thread', turnId: 'owned-turn' };
const metadata = { session_id: ids.sessionId, thread_id: ids.threadId, turn_id: ids.turnId, thread_source: 'sdk' };

async function fixture(t, requestElicitation) {
  const directory = await mkdtemp(join(tmpdir(), 'wonder-native-cua-'));
  const journal = `${directory}/peer.jsonl`, abort = new AbortController();
  const adapter = await createNativeCua({ sdk, ...ids, signal: abort.signal, requestElicitation,
    environment: process.env, server: { enabled: true, command: process.execPath,
      args: [fileURLToPath(new URL('fixtures/native-cua-peer.mjs', import.meta.url)), journal],
      enabled_tools: ['js', 'js_reset', 'turn_ended', 'js_add_node_module_dir'] } });
  t.after(async () => { await adapter.close(); await rm(directory, { recursive: true, force: true }); });
  const js = adapter.server.tools.find(tool => tool.name === 'js');
  const frames = async () => (await readFile(journal, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  return { adapter, js, abort, frames };
}

test('forwards full provider metadata and result; native calls have host-owned IDs; cleanup is hidden and once', { timeout: 10000 }, async t => {
  let approval;
  const response = { action: 'decline' };
  const f = await fixture(t, async params => { approval = params; return response; });
  assert.deepEqual(f.adapter.server.tools.map(t => t.name), ['js', 'js_reset']);
  const input = { code: 'request' };
  assert.equal(f.adapter.authorize('mcp__cua_repl__js', input, context), true);
  const result = await f.js.handler(input, { signal: new AbortController().signal });
  await f.adapter.close(); await f.adapter.close();
  const frames = await f.frames();
  const sentApproval = frames.find(e => e.direction === 'out' && e.frame.method === 'elicitation/create').frame.params;
  assert.deepEqual(approval, { ...sentApproval, threadId: ids.threadId, turnId: ids.turnId, serverName: 'cua_repl', agentFamily: 'claude' });
  const reply = frames.find(e => e.direction === 'in' && e.frame.id === 'native-approval-1').frame;
  assert.deepEqual(reply.result, response);
  assert.deepEqual(result, { content: [{ type: 'text', text: 'Native denied' }], isError: true,
    structuredContent: { native: true, approval: response }, _meta: { nativeResult: 'preserve' } });
  const calls = frames.filter(e => e.direction === 'in' && e.frame.method === 'tools/call').map(e => e.frame.params);
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0], { name: 'js', arguments: input, _meta: { 'x-codex-turn-metadata': { ...metadata, call_id: context.toolUseID } } });
  assert.deepEqual(calls[1], { name: 'turn_ended', arguments: { hook_event_name: 'Stop', session_id: ids.sessionId, turn_id: ids.turnId }, _meta: { 'x-codex-turn-metadata': metadata } });
});

test('unverified origins and calls without matching SDK authorization cannot reach native runtime', { timeout: 10000 }, async t => {
  const f = await fixture(t, async () => { throw new Error('Must not request approval'); });
  const input = { code: 'request' };
  for (const [name, ctx] of [
    ['mcp__other__js', context],
    ['mcp__cua_repl__turn_ended', context],
    ['mcp__cua_repl__js', { ...context, mcpServer: { name: 'cua_repl', source: 'user' } }],
    ['mcp__cua_repl__js', { ...context, mcpServer: { name: 'other', source: 'sdk' } }],
    ['mcp__cua_repl__js', { ...context, toolUseID: '' }],
  ]) assert.equal(f.adapter.authorize(name, input, ctx), false);
  await assert.rejects(f.js.handler(input, { signal: f.abort.signal }), /no verified SDK authorization/);
  await f.adapter.close();
  const calls = (await f.frames()).filter(e => e.direction === 'in' && e.frame.method === 'tools/call');
  assert.deepEqual(calls.map(e => e.frame.params.name), ['turn_ended']);
});

test('abort cancels pending approval and native request but cleanup uses a fresh signal', { timeout: 10000 }, async t => {
  const requested = Promise.withResolvers(), cancelled = Promise.withResolvers();
  const f = await fixture(t, async (_params, signal) => {
    requested.resolve();
    await new Promise(resolve => signal.addEventListener('abort', resolve, { once: true }));
    cancelled.resolve(); return { action: 'cancel' };
  });
  const input = { code: 'hold' };
  assert.equal(f.adapter.authorize('mcp__cua_repl__js', input, context), true);
  const call = f.js.handler(input, { signal: new AbortController().signal });
  const rejection = assert.rejects(call, /abort/i);
  await requested.promise; f.abort.abort(); await cancelled.promise; await rejection;
  assert.equal(f.adapter.authorize('mcp__cua_repl__js', input, context), false);
  await f.adapter.close(); await f.adapter.close();
  const frames = await f.frames();
  const calls = frames.filter(e => e.direction === 'in' && e.frame.method === 'tools/call');
  const active = calls.find(e => e.frame.params.name === 'js').frame;
  assert.ok(frames.some(e => e.direction === 'in' && e.frame.method === 'notifications/cancelled' && e.frame.params.requestId === active.id));
  assert.equal(calls.filter(e => e.frame.params.name === 'turn_ended').length, 1);
  const approvalResponse = frames.find(e => e.direction === 'in' && e.frame.id === 'native-approval-1');
  assert.deepEqual(approvalResponse.frame.result, { action: 'cancel' });
});
