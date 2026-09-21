ALTER TABLE message_execution_settings ADD COLUMN working_directory TEXT;

-- Pre-0061 rows never retained an acceptance-time working directory. Use the
-- private Bot workspace as a conservative compatibility value instead of
-- copying the Bot's current external directory and silently broadening an old
-- queued turn. New rows snapshot the selected directory at acceptance.
UPDATE message_execution_settings
SET working_directory = (
    SELECT b.workspace_path FROM messages m
    JOIN conversation_metadata c ON c.id = m.conversation_id
    JOIN bots b ON b.id = c.bot_id
    WHERE m.id = message_execution_settings.message_id
)
WHERE working_directory IS NULL;
