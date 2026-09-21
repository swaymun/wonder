-- Opt-in configuration keeps existing coordinator groups compatible.
CREATE TABLE group_collaboration (
 group_id TEXT PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
 configuration TEXT NOT NULL
);
CREATE TABLE group_collaboration_plans (
 parent_message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
 group_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
 plan TEXT NOT NULL
);
CREATE TABLE group_creation_receipts (
 id TEXT PRIMARY KEY,
 request TEXT NOT NULL,
 result TEXT
);

CREATE TABLE group_collaboration_context (
 parent_message_id TEXT PRIMARY KEY REFERENCES group_runs(parent_message_id) ON DELETE CASCADE,
 configuration TEXT NOT NULL
);
CREATE TRIGGER group_collaboration_accepted AFTER INSERT ON group_runs
BEGIN
 INSERT INTO group_collaboration_context SELECT NEW.parent_message_id,configuration FROM group_collaboration WHERE group_id=NEW.channel_id;
END;

-- Freeze bounded visible history with the accepted request, so recovery uses identical input.
DROP TRIGGER group_parent_accepted;
CREATE TRIGGER group_parent_accepted AFTER INSERT ON channel_messages
WHEN NEW.phase = 'user' AND NEW.author_kind IN ('user','automation')
BEGIN
 INSERT INTO group_runs(parent_message_id,channel_id,snapshot_json,updated_at)
 SELECT NEW.message_id,c.id,json_object(
  'id',c.id,'conversation_id',c.conversation_id,'name',c.name,
  'description',c.description,'coordinator_bot_id',c.coordinator_bot_id,
  'is_archived',json(CASE WHEN c.is_archived THEN 'true' ELSE 'false' END),
  'created_at',c.created_at,'updated_at',c.updated_at,'messages',json((SELECT json_group_array(json_object(
    'message_id',h.message_id,'client_message_id',h.client_message_id,
    'body',substr(h.body,1,4000),'state',h.state,'created_at',h.created_at,
    'body_sha256',h.body_sha256,'codex_thread_id',h.codex_thread_id,'codex_turn_id',h.codex_turn_id,
    'author_kind',h.author_kind,'author_bot_id',h.author_bot_id,'author_bot_name',h.bot_name,
    'phase',h.phase,'presentation_kind',h.presentation_kind,'outcome',h.outcome,
    'retryable',json(CASE WHEN h.retryable THEN 'true' ELSE 'false' END)))
   FROM (SELECT recent.* FROM (
    SELECT cm.message_id,m.client_message_id,m.body,m.state,cm.created_at,m.body_sha256,
     m.codex_thread_id,m.codex_turn_id,cm.author_kind,cm.author_bot_id,b.name AS bot_name,
     cm.phase,cm.presentation_kind,cm.outcome,cm.retryable
    FROM channel_messages cm JOIN messages m ON m.id=cm.message_id LEFT JOIN bots b ON b.id=cm.author_bot_id
    WHERE cm.channel_id=c.id AND cm.message_id<>NEW.message_id AND cm.presentation_kind='message'
    ORDER BY cm.created_at DESC,cm.message_id DESC LIMIT 20
   ) recent ORDER BY recent.created_at,recent.message_id) h)),
  'members',json((SELECT json_group_array(json_object('bot_id',m.bot_id,'bot_name',b.name,'role',m.role,'position',m.position))
    FROM channel_members m JOIN bots b ON b.id=m.bot_id WHERE m.channel_id=c.id ORDER BY m.position,m.bot_id))
 ),NEW.created_at FROM channels c WHERE c.id=NEW.channel_id;
END;
CREATE TABLE group_collaboration_handoffs (
 parent_message_id TEXT PRIMARY KEY REFERENCES group_runs(parent_message_id) ON DELETE CASCADE,
 assignment TEXT NOT NULL
);
