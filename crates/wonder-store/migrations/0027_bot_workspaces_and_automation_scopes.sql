-- Product-facing Bot workspaces are stable identities, not disposable chats.
-- Existing conversation metadata remains intact for historical recovery.
CREATE TABLE IF NOT EXISTS bot_workspaces (
    bot_id TEXT PRIMARY KEY NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    conversation_id TEXT NOT NULL UNIQUE REFERENCES conversation_metadata(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- Give legacy Bots without metadata a deterministic canonical workspace.
INSERT OR IGNORE INTO conversation_metadata (id, bot_id, title, created_at, updated_at)
SELECT 'bot:' || id, id, name, created_at, created_at
FROM bots
WHERE NOT EXISTS (
    SELECT 1 FROM conversation_metadata AS metadata WHERE metadata.bot_id = bots.id
);

-- Prefer active metadata, then the most recently updated row, then the stable id.
INSERT OR IGNORE INTO bot_workspaces (bot_id, conversation_id, created_at, updated_at)
SELECT bots.id,
       (
           SELECT metadata.id
           FROM conversation_metadata AS metadata
           WHERE metadata.bot_id = bots.id
           ORDER BY metadata.is_archived ASC, metadata.updated_at DESC, metadata.id ASC
           LIMIT 1
       ),
       bots.created_at,
       bots.created_at
FROM bots;

ALTER TABLE automations ADD COLUMN scope_type TEXT NOT NULL DEFAULT 'bot';
ALTER TABLE automations ADD COLUMN scope_id TEXT;
UPDATE automations SET scope_id = bot_id WHERE scope_id IS NULL;
CREATE INDEX IF NOT EXISTS automations_scope_idx ON automations(scope_type, scope_id);
