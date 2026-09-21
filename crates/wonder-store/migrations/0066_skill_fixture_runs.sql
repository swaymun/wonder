CREATE TABLE bot_skill_fixture_runs (
    id TEXT PRIMARY KEY,
    client_request_id TEXT NOT NULL UNIQUE,
    owner_device_id TEXT NOT NULL,
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    skill_id TEXT NOT NULL REFERENCES bot_skills(id) ON DELETE CASCADE,
    version INTEGER NOT NULL,
    content_hash TEXT NOT NULL,
    input_schema_hash TEXT NOT NULL,
    input_schema_json TEXT NOT NULL,
    inputs_json TEXT NOT NULL,
    working_directory TEXT NOT NULL,
    provider TEXT NOT NULL,
    execution_kind TEXT NOT NULL,
    status TEXT NOT NULL,
    verification_state TEXT NOT NULL,
    artifact_path TEXT,
    artifact_hash TEXT,
    artifact_bytes INTEGER NOT NULL DEFAULT 0,
    evidence_json TEXT NOT NULL,
    failure_reason TEXT,
    created_at TEXT NOT NULL,
    completed_at TEXT NOT NULL
);

CREATE INDEX bot_skill_fixture_runs_scope_idx
    ON bot_skill_fixture_runs(owner_device_id, bot_id, skill_id, version, completed_at DESC);
