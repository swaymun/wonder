// Transport only: all computer actions and app permission checks belong to native cua_repl.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { ElicitRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import { toolCallKey } from './permissions.mjs';

async function connectNativeCua({ server, environment, sessionId, threadId, turnId,
  signal, requestElicitation }) {
  if (server?.enabled !== true || !server.command || !sessionId || !threadId || !turnId)
    throw new Error('Native computer use is unavailable for this turn.');
  signal.throwIfAborted();
  const client = new Client({ name: 'wonder-claude', version: '1.0.0' },
    { capabilities: { elicitation: { form: {} } } });
  const transport = new StdioClientTransport({ command: server.command, args: server.args,
    env: { ...environment, ...server.env }, stderr: 'pipe' });
  let closePromise;
  const meta = callId => ({ 'x-codex-turn-metadata': {
    session_id: sessionId, thread_id: threadId, turn_id: turnId,
    thread_source: 'sdk', ...(callId ? { call_id: callId } : {})
  } });
  client.setRequestHandler(ElicitRequestSchema, async (request, extra) => {
    const requestSignal = AbortSignal.any([signal, extra.signal]);
    if (requestSignal.aborted) return { action: 'cancel' };
    // Forward provider fields unchanged, including native risk/subtitle/persist metadata.
    try {
      const response = await requestElicitation({ ...request.params,
        threadId, turnId, serverName: 'cua_repl', agentFamily: 'claude' }, requestSignal);
      requestSignal.throwIfAborted();
      if (!['accept', 'decline', 'cancel'].includes(response?.action))
        throw new Error('Native computer approval returned an invalid response.');
      return response;
    } catch (error) {
      if (requestSignal.aborted) return { action: 'cancel' };
      throw error;
    }
  });
  const close = () => closePromise ??= (async () => {
    try {
      // Cleanup must not inherit the canceled model-turn signal.
      const result = await client.callTool({ name: 'turn_ended',
        arguments: { hook_event_name: 'Stop', session_id: sessionId, turn_id: turnId },
        _meta: meta() }, undefined, { timeout: 15_000 });
      if (result.isError) throw new Error('Native computer-use cleanup did not complete.');
    } finally {
      await client.close(); await transport.close();
    }
  })();
  try {
    await client.connect(transport, { signal, timeout: 30_000 });
    transport.stderr?.resume();
    signal.throwIfAborted();
    const { tools } = await client.listTools({}, { signal, timeout: 30_000 });
    // Match the provider plugin's advertised model surface. Cleanup is host-owned.
    const exposed = tools.filter(t => ['js', 'js_reset'].includes(t.name)
      && server.enabled_tools?.includes(t.name));
    if (!exposed.some(t => t.name === 'js')) throw new Error('Native computer tools are unavailable.');
    const nativeNames = new Set(exposed.map(t => t.name));
    return { tools: exposed, close,
      call(name, input, callId, callSignal = signal) {
        if (!nativeNames.has(name) || !callId) throw new Error('Invalid native computer call.');
        const combined = AbortSignal.any([signal, callSignal]);
        combined.throwIfAborted();
        return client.callTool({ name, arguments: input, _meta: meta(callId) }, undefined,
          { signal: combined, timeout: 10 * 60_000 });
      }
    };
  } catch (error) {
    await client.close(); await transport.close();
    throw error;
  }
}

export async function createNativeCua({ sdk, ...options }) {
  const native = await connectNativeCua(options);
  const { signal } = options, authorized = new Map();
  const nativeNames = new Set(native.tools.map(t => t.name));
  try {
    const proxy = sdk.createSdkMcpServer({ name: 'cua_repl', version: '1.0.0', tools:
      native.tools.map(t => sdk.tool(t.name, t.description, z.fromJSONSchema(t.inputSchema).shape,
        async (input, extra) => {
          const key = toolCallKey(t.name, input), calls = authorized.get(key);
          const callId = calls?.shift();
          if (!calls?.length) authorized.delete(key);
          if (!callId) throw new Error('The native computer call has no verified SDK authorization.');
          const callSignal = AbortSignal.any([signal, extra.signal]);
          callSignal.throwIfAborted();
          return native.call(t.name, input, callId, callSignal);
        }, { annotations: t.annotations })) });
    return {
      server: proxy,
      authorize(name, input, context) {
        const nativeName = name.startsWith('mcp__cua_repl__') ? name.slice('mcp__cua_repl__'.length) : '';
        if (!nativeNames.has(nativeName) || context.mcpServer?.source !== 'sdk'
          || context.mcpServer?.name !== 'cua_repl' || !context.toolUseID || signal.aborted) return false;
        const key = toolCallKey(nativeName, input), calls = authorized.get(key) ?? [];
        if (!calls.includes(context.toolUseID)) calls.push(context.toolUseID);
        authorized.set(key, calls);
        return true;
      },
      close: native.close
    };
  } catch (error) {
    await native.close();
    throw error;
  }
}
