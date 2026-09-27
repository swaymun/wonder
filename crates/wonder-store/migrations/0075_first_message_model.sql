-- Only newly created conversational Bots can choose a family before first Send.
-- Absence of this row deliberately leaves legacy Bots locked.
CREATE TABLE bot_model_drafts (
 bot_id TEXT PRIMARY KEY REFERENCES bots(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL DEFAULT 0,
 first_message_id TEXT
);

DROP TRIGGER bot_agent_family_is_fixed;
CREATE TRIGGER bot_agent_family_is_fixed BEFORE UPDATE OF agent_family ON bots
WHEN NEW.agent_family != OLD.agent_family
AND NOT (OLD.agent_family='codex' AND NEW.agent_family='claude' AND COALESCE(OLD.model LIKE 'claude:%',0))
AND NOT EXISTS (
 SELECT 1 FROM bot_model_drafts d WHERE d.bot_id=OLD.id AND d.first_message_id IS NULL
 AND NOT EXISTS(SELECT 1 FROM conversation_metadata c JOIN runtime_bindings r ON r.conversation_id=c.id WHERE c.bot_id=OLD.id)
)
BEGIN
 SELECT RAISE(ABORT,'The Bot agent family is fixed after its first message');
END;

-- Retire unanswered setup questions without touching ordinary runtime questions.
UPDATE async_questions SET state='dismissed',response_json='{"answers":[],"skip":true}'
 WHERE item_id='wonder-purpose' AND state='pending';
-- An initialization still waiting in the durable queue must not start on upgrade.
UPDATE messages SET state='interrupted' WHERE id IN (SELECT message_id FROM bot_initializations)
 AND state='accepted_by_wonder' AND codex_turn_id IS NULL;
