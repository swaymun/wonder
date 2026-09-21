-- A folder decision and its conversational acknowledgement are one commit.
CREATE TABLE bot_workspace_followups (
    request_id TEXT PRIMARY KEY REFERENCES bot_file_requests(id) ON DELETE CASCADE,
    message_id TEXT NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE
);
