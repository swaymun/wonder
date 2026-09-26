-- The initial model chooses a Bot's harness. Existing Bots remain Codex Bots.
ALTER TABLE bots ADD COLUMN agent_family TEXT NOT NULL DEFAULT 'codex'
 CHECK(agent_family IN ('codex','claude'));
UPDATE bots SET agent_family='claude' WHERE model LIKE 'claude:%';

CREATE TRIGGER bot_initial_agent_family AFTER INSERT ON bots
WHEN NEW.model LIKE 'claude:%'
BEGIN
 UPDATE bots SET agent_family='claude' WHERE id=NEW.id;
END;
CREATE TRIGGER bot_model_stays_in_family BEFORE UPDATE OF model ON bots
WHEN NEW.model IS NOT NULL AND NEW.agent_family !=
 CASE WHEN NEW.model LIKE 'claude:%' THEN 'claude' ELSE 'codex' END
BEGIN
 SELECT RAISE(ABORT,'Choose a model from this Bot agent family');
END;
CREATE TRIGGER bot_agent_family_is_fixed BEFORE UPDATE OF agent_family ON bots
WHEN NEW.agent_family != OLD.agent_family AND NOT
 (OLD.agent_family='codex' AND NEW.agent_family='claude' AND OLD.model LIKE 'claude:%')
BEGIN
 SELECT RAISE(ABORT,'The Bot agent family is fixed by its initial model');
END;

-- Group routing selects the group's family independently from direct Bots.
CREATE TRIGGER group_model_stays_in_family BEFORE UPDATE OF configuration ON group_collaboration
WHEN (CASE WHEN json_extract(OLD.configuration,'$.routing.model') LIKE 'claude:%' THEN 'claude' ELSE 'codex' END)
 != (CASE WHEN json_extract(NEW.configuration,'$.routing.model') LIKE 'claude:%' THEN 'claude' ELSE 'codex' END)
BEGIN
 SELECT RAISE(ABORT,'Choose a model from this Group Chat agent family');
END;

-- Provider-neutral authority for routing. Historical codex_* storage columns
-- remain compatible with existing transcript/search/receipt migrations.
CREATE TABLE runtime_bindings (
 conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
 agent_family TEXT NOT NULL CHECK(agent_family IN ('codex','claude')),
 runtime_thread_id TEXT NOT NULL,
 session_id TEXT,
 updated_at TEXT NOT NULL
);
-- Preserve historical Codex aliases. New Claude sessions are exclusive to
-- their direct/group conversation and may never reuse another Bot's session.
CREATE UNIQUE INDEX claude_runtime_thread_owner ON runtime_bindings(runtime_thread_id) WHERE agent_family='claude';
CREATE INDEX runtime_binding_thread ON runtime_bindings(runtime_thread_id);
INSERT INTO runtime_bindings
 SELECT id,'codex',codex_thread_id,session_id,created_at FROM conversations WHERE codex_thread_id IS NOT NULL;
CREATE TRIGGER runtime_binding_family_is_fixed BEFORE UPDATE OF agent_family ON runtime_bindings
WHEN NEW.agent_family != OLD.agent_family
BEGIN
 SELECT RAISE(ABORT,'A runtime session cannot move between agent families');
END;
