-- Runtime requests are scoped to an existing coordinator Group turn, never owner credentials.
CREATE TABLE pm_tool_calls (
 call_key TEXT PRIMARY KEY,
 input_hash TEXT NOT NULL,
 message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
 runtime_id TEXT NOT NULL,
 tool_name TEXT NOT NULL,
 response_json TEXT,
 created_at TEXT NOT NULL
);
CREATE INDEX pm_tool_call_message ON pm_tool_calls(message_id);
