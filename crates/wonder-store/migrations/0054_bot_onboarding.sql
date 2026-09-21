CREATE TABLE bot_onboarding (
    bot_id TEXT PRIMARY KEY REFERENCES bots(id) ON DELETE CASCADE,
    dismissed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE bot_profile_changes (
    call_key TEXT PRIMARY KEY,
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    input_hash TEXT NOT NULL,
    profile_json TEXT NOT NULL
);
