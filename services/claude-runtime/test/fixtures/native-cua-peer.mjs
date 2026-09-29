// Isolated protocol fixture. No computer access or model calls.
import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const journal = process.argv[2];
const pending = new Map();
let nextRequest = 0;
const record = (direction, frame) => appendFileSync(journal, JSON.stringify({ direction, frame }) + '\n');
const send = frame => { record('out', frame); process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n'); };
const result = (id, value) => send({ id, result: value });
const tools = [
  { name: 'js', description: 'Fixture native JS', inputSchema: { type: 'object', properties: { code: { type: 'string' } }, required: ['code'] }, annotations: { readOnlyHint: true } },
  { name: 'js_reset', description: 'Fixture reset', inputSchema: { type: 'object', properties: {} } },
  { name: 'turn_ended', description: 'Host cleanup', inputSchema: { type: 'object' } },
  { name: 'js_add_node_module_dir', description: 'Not enabled for model', inputSchema: { type: 'object' } },
];
for await (const line of createInterface({ input: process.stdin })) {
  const frame = JSON.parse(line); record('in', frame);
  if (!frame.method) {
    const call = pending.get(frame.id);
    if (call) {
      pending.delete(frame.id);
      result(call.id, { content: [{ type: 'text', text: 'Native denied' }], isError: true,
        structuredContent: { native: true, approval: frame.result }, _meta: { nativeResult: 'preserve' } });
    }
    continue;
  }
  if (frame.method === 'initialize') result(frame.id, { protocolVersion: frame.params.protocolVersion,
    capabilities: { tools: {} }, serverInfo: { name: 'fake-native-peer', version: '1.0.0' } });
  else if (frame.method === 'tools/list') result(frame.id, { tools });
  else if (frame.method === 'tools/call') {
    if (frame.params.name === 'turn_ended') result(frame.id, { content: [{ type: 'text', text: '{}' }], isError: false });
    else {
      const id = `native-approval-${++nextRequest}`; pending.set(id, frame);
      send({ id, method: 'elicitation/create', params: {
        mode: 'form', message: 'Allow native fixture app?',
        requestedSchema: { type: 'object', properties: {} },
        _meta: { riskLevel: 'high', subtitle: 'Fixture explanation', persist: ['session', 'always'],
          codex_approval_kind: 'mcp_tool_call', connector_id: 'computer-use', connector_name: 'Computer Use',
          tool_call_id: frame.params._meta['x-codex-turn-metadata'].call_id,
          tool_name: 'get_app_state', tool_params: { app: 'test.fixture' },
          tool_params_display: [{ display_name: 'App', name: 'app', value: 'Fixture' }],
          'x-codex-turn-metadata': frame.params._meta['x-codex-turn-metadata'],
          futureProviderField: { nested: ['preserve', 42] } },
      } });
    }
  }
}
