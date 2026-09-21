CREATE TABLE channel_messages_v3 (
    channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    message_id TEXT NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
    author_kind TEXT NOT NULL CHECK (author_kind IN ('user', 'coordinator', 'member', 'automation')),
    author_bot_id TEXT REFERENCES bots(id),
    phase TEXT NOT NULL CHECK (phase IN ('user', 'routing', 'worker', 'synthesis', 'direct')),
    created_at TEXT NOT NULL,
    orchestration_claimed INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (channel_id, message_id)
);

INSERT INTO channel_messages_v3 (channel_id, message_id, author_kind, author_bot_id, phase, created_at, orchestration_claimed)
SELECT channel_id, message_id, author_kind, author_bot_id, phase, created_at, orchestration_claimed
FROM channel_messages;

DROP TABLE channel_messages;
ALTER TABLE channel_messages_v3 RENAME TO channel_messages;

CREATE INDEX channel_messages_channel_idx
    ON channel_messages(channel_id, created_at ASC);
