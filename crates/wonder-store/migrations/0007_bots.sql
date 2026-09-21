CREATE TABLE IF NOT EXISTS bots (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    workspace_path TEXT NOT NULL,
    permission_profile TEXT NOT NULL,
    model TEXT,
    reasoning_effort TEXT,
    created_at TEXT NOT NULL
);
