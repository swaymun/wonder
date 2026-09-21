CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY NOT NULL,
    codex_thread_id TEXT NOT NULL,
    session_id TEXT,
    created_at TEXT NOT NULL
);
