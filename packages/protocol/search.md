# Native persisted search

`GET /api/v1/search?q=needle&limit=30&conversationId=chat-id&cursor=opaque`

The existing owner-authenticated API boundary applies. `q` is required (1–256
bytes after trimming). `limit` is 1–100, default 30. `conversationId` optionally
narrows results; it never grants access. Omit `cursor` for the first page.

```json
{
  "results": [{
    "kind": "message",
    "id": "matching-message-id",
    "title": "Conversation title",
    "snippet": "Text with a <mark>needle</mark> match",
    "conversationId": "chat-id",
    "botId": "bot-id",
    "updatedAt": "1788932400000",
    "deepLink": "#/chats/chat-id?focus=matching-message-id&kind=message"
  }],
  "nextCursor": null
}
```

Use `(kind, id)` as result identity. Open `conversationId` and focus `id` using
`kind`; native clients need not parse the legacy web `deepLink`. Snippets use
`<mark>` delimiters around matches, not trusted HTML. Retain existing matching
semantics: up to eight alphanumeric prefix terms, all terms required.

Order is normalized persisted timestamp descending, then kind and ID descending.
Tied timestamps and index rebuilds cannot reorder an unchanged result set.
Continue with the same query and conversation scope; cursor is opaque and bound
to both plus the current host epoch. Invalid/mismatched cursors return 400;
restart from the first page. A null next cursor marks the final page.

Each page reads current persisted content in one transaction. This is a live
view, not a frozen multi-page snapshot: edits/deletions and changed visibility
apply to the next request. Refresh from page one after relevant sync changes to
see newly matching or reordered records. Offline rendering is the native
client's saved result projection, not a daemon network operation.

Archived Bots, conversations and Groups, and the same dedicated Group worker
conversations excluded from Chats, are filtered before pagination. Bot names
and roles are searchable; system prompts and runtime events/tool payloads are
not indexed. Group message results are only the public `channel_messages`
presentation: `kind` is `message` and `id` is the canonical rendered `messageId`.
Internal coordinator prompts and raw Group assistant outputs are excluded, so a
final reply appears once and its result opens a visible Group message. Explicit
conversation scope cannot bypass those filters.

The existing small FTS projection is still rebuilt per query. Pagination bounds
response size, not total index rebuild cost; incremental indexing is deferred
until mutation lifecycle hooks are designed and measured.
