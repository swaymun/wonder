// Native Claude Code transcripts are authoritative for project conversations.
// Project SDK session messages into the same turn/item shapes as the live
// stream so Wonder reconciles both by stable IDs instead of duplicating them.
import { toolContent } from "./projection.mjs";

const textOf = content => typeof content === "string" ? content
  : Array.isArray(content) ? content.filter(b => b?.type === "text").map(b => b.text ?? "").join("\n") : "";

// Wonder-originated turns reuse the owner's receipt from the bridge journal.
export function nativeTurns(messages, journal = [], active = false) {
  const turns = [], known = new Map(journal.map(turn => [turn.id, turn]));
  const blockIndex = new Map(), tools = new Map();
  let turn = null;
  for (const entry of messages) {
    const content = entry?.message?.content;
    if (entry?.parent_tool_use_id) continue; // Child-agent detail stays in its own activity.
    if (entry?.type === "user") {
      const results = Array.isArray(content) ? content.filter(b => b?.type === "tool_result") : [];
      for (const block of results) {
        const item = tools.get(block.tool_use_id);
        if (!item) continue;
        item.success = block.is_error !== true;
        item.status = item.success ? "completed" : "failed";
        item.contentItems = toolContent(block.content);
        if (!item.success) item.error = { message: item.contentItems.filter(c => c.type === "inputText").map(c => c.text).join("\n") || "Tool failed" };
      }
      const text = textOf(content);
      if (results.length || !text.trim()) continue;
      const receipt = known.get(entry.uuid);
      const user = receipt?.items?.find(i => i.type === "userMessage");
      turn = { id: entry.uuid, status: "completed", error: null, items: [user
        ? { ...user }
        : { type: "userMessage", id: entry.uuid, content: [{ type: "text", text }] }] };
      turns.push(turn);
      continue;
    }
    if (entry?.type !== "assistant" || !turn || !Array.isArray(content)) continue;
    const messageId = entry.message?.id ?? entry.uuid;
    for (const block of content) {
      const index = blockIndex.get(messageId) ?? 0;
      blockIndex.set(messageId, index + 1);
      if (block?.type === "text" && block.text) {
        turn.items.push({ type: "agentMessage", id: `${turn.id}:${messageId}:${index}`, text: block.text, status: "completed" });
      } else if (block?.type === "tool_use" && !["Agent", "Task"].includes(block.name)) {
        const item = { type: "mcpToolCall", id: block.id, server: "Claude", tool: block.name, arguments: block.input ?? {}, status: "completed" };
        tools.set(block.id, item);
        turn.items.push(item);
      }
    }
  }
  const last = turns.at(-1);
  if (last && active) last.status = "inProgress";
  // Preserve the durable outcome of Wonder's own turns (failed, interrupted).
  for (const t of turns) {
    const receipt = known.get(t.id);
    if (receipt && receipt.status !== "inProgress" && !(t === last && active)) { t.status = receipt.status; t.error = receipt.error ?? null; }
  }
  return turns;
}

export function sessionSummary(info) {
  const title = (info.customTitle || info.summary || info.firstPrompt || "Claude session").replace(/\s+/g, " ").trim().slice(0, 200);
  return { sessionId: info.sessionId, title, cwd: info.cwd ?? null,
    createdAt: Math.floor((info.createdAt ?? info.lastModified) / 1000), updatedAt: Math.floor(info.lastModified / 1000) };
}
