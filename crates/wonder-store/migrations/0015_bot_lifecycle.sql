ALTER TABLE bots ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS bots_archived_created_idx
    ON bots(is_archived, created_at ASC);
