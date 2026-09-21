ALTER TABLE bots ADD COLUMN service_tier TEXT;

CREATE TABLE IF NOT EXISTS conversation_settings (
    conversation_id TEXT PRIMARY KEY NOT NULL,
    model TEXT,
    reasoning_effort TEXT,
    service_tier TEXT,
    permission_profile TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS conversation_files (
    id TEXT PRIMARY KEY NOT NULL,
    conversation_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    name TEXT NOT NULL,
    relative_path TEXT,
    state TEXT NOT NULL,
    additions INTEGER,
    deletions INTEGER,
    source_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS conversation_files_conversation_idx
    ON conversation_files(conversation_id, updated_at DESC);
