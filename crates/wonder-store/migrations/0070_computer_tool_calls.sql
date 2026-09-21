-- Keep only the call-to-receipt binding. The existing approval journal owns the
-- result, avoiding another retained copy of screenshots or accessibility text.
CREATE TABLE computer_tool_calls (
    call_key TEXT PRIMARY KEY NOT NULL,
    input_hash TEXT NOT NULL,
    approval_id TEXT NOT NULL
);
