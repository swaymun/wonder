CREATE TABLE group_runs (
 parent_message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
 channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
 snapshot_json TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending',
 output_message_id TEXT,
 updated_at TEXT NOT NULL
);
CREATE TABLE group_nodes (
 parent_message_id TEXT NOT NULL REFERENCES group_runs(parent_message_id) ON DELETE CASCADE,
 device_id TEXT NOT NULL,
 client_message_id TEXT NOT NULL,
 bot_id TEXT NOT NULL,
 phase TEXT NOT NULL,
 PRIMARY KEY(parent_message_id, client_message_id),
 UNIQUE(device_id, client_message_id)
);
-- Attribution and recovery intent commit together, before a receipt is sent.
CREATE TRIGGER group_parent_accepted AFTER INSERT ON channel_messages
WHEN NEW.phase = 'user' AND NEW.author_kind IN ('user','automation')
BEGIN
 INSERT INTO group_runs(parent_message_id,channel_id,snapshot_json,updated_at)
 SELECT NEW.message_id,c.id,json_object(
  'id',c.id,'conversation_id',c.conversation_id,'name',c.name,
  'description',c.description,'coordinator_bot_id',c.coordinator_bot_id,
  'is_archived',json(CASE WHEN c.is_archived THEN 'true' ELSE 'false' END),
  'created_at',c.created_at,'updated_at',c.updated_at,'messages',json('[]'),
  'members',json((SELECT json_group_array(json_object('bot_id',m.bot_id,'bot_name',b.name,'role',m.role,'position',m.position))
    FROM channel_members m JOIN bots b ON b.id=m.bot_id WHERE m.channel_id=c.id ORDER BY m.position,m.bot_id))
 ),NEW.created_at FROM channels c WHERE c.id=NEW.channel_id;
END;
