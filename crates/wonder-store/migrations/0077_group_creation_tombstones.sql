-- A delayed creation retry must not resurrect a deleted Group Chat.
CREATE TABLE group_deletions (group_id TEXT PRIMARY KEY);
-- Completed conversational receipts also identify previously deleted groups.
INSERT INTO group_deletions
SELECT id FROM group_creation_receipts
WHERE result IS NOT NULL AND NOT EXISTS (SELECT 1 FROM channels WHERE channels.id=group_creation_receipts.id);
