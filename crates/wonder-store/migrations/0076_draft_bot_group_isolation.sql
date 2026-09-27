-- Group and helper sessions do not choose the lead Bot's direct-chat family.
DROP TRIGGER bot_agent_family_is_fixed;
CREATE TRIGGER bot_agent_family_is_fixed BEFORE UPDATE OF agent_family ON bots
WHEN NEW.agent_family != OLD.agent_family
AND NOT (OLD.agent_family='codex' AND NEW.agent_family='claude' AND COALESCE(OLD.model LIKE 'claude:%',0))
AND NOT EXISTS (
 SELECT 1 FROM bot_model_drafts d WHERE d.bot_id=OLD.id AND d.first_message_id IS NULL
 AND NOT EXISTS (
  SELECT 1 FROM conversation_metadata c JOIN runtime_bindings r ON r.conversation_id=c.id
  WHERE c.bot_id=OLD.id
  AND NOT EXISTS(SELECT 1 FROM channels WHERE conversation_id=c.id)
  AND NOT EXISTS(SELECT 1 FROM subagent_ownership WHERE conversation_id=c.id)
 )
)
BEGIN
 SELECT RAISE(ABORT,'The Bot agent family is fixed after its first message');
END;
