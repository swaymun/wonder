CREATE TABLE IF NOT EXISTS channels (
    id TEXT PRIMARY KEY NOT NULL,
    conversation_id TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    description TEXT,
    coordinator_bot_id TEXT NOT NULL REFERENCES bots(id),
    is_archived INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS channels_updated_idx
    ON channels(is_archived, updated_at DESC);

CREATE TABLE IF NOT EXISTS channel_members (
    channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    bot_id TEXT NOT NULL REFERENCES bots(id),
    role TEXT NOT NULL CHECK (role IN ('coordinator', 'worker')),
    position INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    PRIMARY KEY (channel_id, bot_id)
);

CREATE INDEX IF NOT EXISTS channel_members_bot_idx
    ON channel_members(bot_id);
