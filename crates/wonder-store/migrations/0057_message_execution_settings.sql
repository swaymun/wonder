CREATE TABLE message_execution_settings (
    message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    model TEXT, reasoning_effort TEXT, service_tier TEXT,
    permission_mode TEXT, permission_profile TEXT NOT NULL
);
-- Preserve the current choices for messages already queued during an upgrade.
INSERT INTO message_execution_settings(message_id,model,reasoning_effort,service_tier,permission_mode,permission_profile)
SELECT m.id,COALESCE(s.model,b.model),COALESCE(s.reasoning_effort,b.reasoning_effort),COALESCE(s.service_tier,b.service_tier),b.permission_mode,COALESCE(s.permission_profile,b.permission_profile)
FROM messages m JOIN dispatch_work w ON w.message_id=m.id
JOIN conversation_metadata c ON c.id=m.conversation_id JOIN bots b ON b.id=c.bot_id
LEFT JOIN conversation_settings s ON s.conversation_id=c.id
WHERE m.state='accepted_by_wonder' AND NOT EXISTS(SELECT 1 FROM channels WHERE conversation_id=c.id);
