CREATE TABLE IF NOT EXISTS conversation_metadata (
    id TEXT PRIMARY KEY NOT NULL,
    bot_id TEXT NOT NULL REFERENCES bots(id),
    title TEXT NOT NULL,
    is_archived INTEGER NOT NULL DEFAULT 0,
    is_pinned INTEGER NOT NULL DEFAULT 0,
    has_unread INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS conversation_metadata_bot_idx
    ON conversation_metadata(bot_id);

CREATE INDEX IF NOT EXISTS conversation_metadata_inbox_idx
    ON conversation_metadata(is_archived, is_pinned DESC, updated_at DESC);

-- A conversation now exists before its first dispatch. Preserve the legacy
-- rows while allowing the Codex thread to be attached lazily on first send.
ALTER TABLE conversations RENAME TO conversations_before_nullable_thread;
CREATE TABLE conversations (
    id TEXT PRIMARY KEY NOT NULL,
    codex_thread_id TEXT,
    session_id TEXT,
    created_at TEXT NOT NULL
);
INSERT INTO conversations (id, codex_thread_id, session_id, created_at)
SELECT id, codex_thread_id, session_id, created_at
FROM conversations_before_nullable_thread;
DROP TABLE conversations_before_nullable_thread;
