CREATE TABLE bot_file_access (
 bot_id TEXT PRIMARY KEY REFERENCES bots(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL,
 applied_revision INTEGER NOT NULL DEFAULT 0,
 read_roots_json TEXT NOT NULL,
 write_roots_json TEXT NOT NULL
);
