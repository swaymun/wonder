ALTER TABLE bots ADD COLUMN approval_mode TEXT CHECK (approval_mode IN ('ask-for-approval','approve-for-me','full-access'));
ALTER TABLE message_execution_settings ADD COLUMN approval_mode TEXT CHECK (approval_mode IN ('ask-for-approval','approve-for-me','full-access'));

-- Scope and approval are separate axes. Preserve the legacy scope, while
-- giving managed modes a stable approval choice for the new clients.
UPDATE bots
SET approval_mode = CASE permission_mode
    WHEN 'read-only' THEN 'ask-for-approval'
    WHEN 'workspace' THEN 'ask-for-approval'
    WHEN 'full-access' THEN 'full-access'
    ELSE NULL
END
WHERE approval_mode IS NULL;

UPDATE message_execution_settings
SET approval_mode = CASE permission_mode
    WHEN 'read-only' THEN 'ask-for-approval'
    WHEN 'workspace' THEN 'ask-for-approval'
    WHEN 'full-access' THEN 'full-access'
    ELSE NULL
END
WHERE approval_mode IS NULL;
