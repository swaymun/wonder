ALTER TABLE channel_messages ADD COLUMN presentation_kind TEXT NOT NULL DEFAULT 'message' CHECK (presentation_kind IN ('message', 'status'));
ALTER TABLE channel_messages ADD COLUMN outcome TEXT CHECK (outcome IN ('completed', 'failed', 'timed_out', 'interrupted'));
ALTER TABLE channel_messages ADD COLUMN retryable INTEGER NOT NULL DEFAULT 0;
