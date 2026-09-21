CREATE TABLE IF NOT EXISTS channel_messages (
    channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    message_id TEXT NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
    author_kind TEXT NOT NULL CHECK (author_kind IN ('user', 'coordinator', 'member')),
    author_bot_id TEXT REFERENCES bots(id),
    phase TEXT NOT NULL CHECK (phase IN ('user', 'routing', 'worker', 'synthesis')),
    created_at TEXT NOT NULL,
    PRIMARY KEY (channel_id, message_id)
);

CREATE INDEX IF NOT EXISTS channel_messages_channel_idx
    ON channel_messages(channel_id, created_at ASC);
