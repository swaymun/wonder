ALTER TABLE bots ADD COLUMN avatar_color TEXT;
ALTER TABLE bots ADD COLUMN working_directory TEXT;
CREATE TABLE bot_creation_requests (
 request_id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, payload_hash TEXT NOT NULL,
 completed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE bot_deletions (
 bot_id TEXT PRIMARY KEY, workspace_path TEXT NOT NULL, completed INTEGER NOT NULL DEFAULT 0
);
ALTER TABLE channel_messages ADD COLUMN historical_author_name TEXT;
CREATE TABLE bot_file_requests (
 id TEXT PRIMARY KEY, bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
 path TEXT NOT NULL, access TEXT NOT NULL CHECK(access IN ('read','write')),
 use_as_working_directory INTEGER NOT NULL DEFAULT 0,
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','approved','declined'))
);
CREATE TRIGGER sync_bot_file_requests_insert AFTER INSERT ON bot_file_requests BEGIN
 INSERT INTO sync_journal(host_epoch,occurred_at,conversation_id,resource,change_kind)
 SELECT host_epoch,strftime('%Y-%m-%dT%H:%M:%fZ','now'),NULL,'bots','update' FROM sync_state WHERE singleton=1;
END;
CREATE TRIGGER sync_bot_file_requests_update AFTER UPDATE ON bot_file_requests BEGIN
 INSERT INTO sync_journal(host_epoch,occurred_at,conversation_id,resource,change_kind)
 SELECT host_epoch,strftime('%Y-%m-%dT%H:%M:%fZ','now'),NULL,'bots','update' FROM sync_state WHERE singleton=1;
END;
-- Enforce the archive boundary at message acceptance as well as dispatch.
CREATE TRIGGER reject_archived_bot_message BEFORE INSERT ON messages
WHEN EXISTS(SELECT 1 FROM conversation_metadata c JOIN bots b ON b.id=c.bot_id WHERE c.id=NEW.conversation_id AND b.is_archived=1)
BEGIN SELECT RAISE(ABORT,'Bot is archived'); END;
CREATE TABLE group_creation_requests(request_id TEXT PRIMARY KEY,payload_hash TEXT NOT NULL);
