CREATE TABLE IF NOT EXISTS automations (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('continuation', 'standalone')),
    bot_id TEXT NOT NULL REFERENCES bots(id),
    conversation_id TEXT,
    prompt TEXT NOT NULL,
    rrule TEXT NOT NULL,
    timezone TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'paused')),
    notification_policy TEXT NOT NULL CHECK (notification_policy IN ('all_runs', 'failed_runs_only')),
    model_id TEXT,
    reasoning_effort TEXT,
    next_run_at TEXT,
    last_run_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS automations_status_next_run_idx ON automations(status, next_run_at);
