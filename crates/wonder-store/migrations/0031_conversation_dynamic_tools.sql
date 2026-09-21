-- Dynamic tools are registered when a Codex thread is started. Keep a small
-- Wonder-side capability marker so an older persisted conversation can be
-- upgraded once without replacing its thread on every message.
ALTER TABLE conversations ADD COLUMN dynamic_tools_version TEXT;
