CREATE TABLE teaching_sessions (
    id TEXT PRIMARY KEY,
    client_request_id TEXT NOT NULL,
    owner_device_id TEXT NOT NULL,
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    conversation_id TEXT NOT NULL,
    state TEXT NOT NULL,
    capture_scope TEXT NOT NULL,
    capture_provider TEXT NOT NULL,
    outcome TEXT NOT NULL,
    host_installation_id TEXT NOT NULL DEFAULT 'legacy-host',
    name TEXT,
    description TEXT,
    goal TEXT,
    input_schema_json TEXT,
    prerequisites TEXT,
    steps TEXT,
    result_checks TEXT,
    failure_reason TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    event_count INTEGER NOT NULL DEFAULT 0,
    evidence_bytes INTEGER NOT NULL DEFAULT 0,
    content_hash TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    started_at TEXT,
    ended_at TEXT,
    expires_at TEXT,
    UNIQUE(owner_device_id, client_request_id)
);

CREATE INDEX teaching_sessions_bot_idx
ON teaching_sessions(bot_id, updated_at DESC);

CREATE UNIQUE INDEX teaching_sessions_active_host_idx
    ON teaching_sessions(host_installation_id)
    WHERE state IN ('starting', 'recording');

CREATE TABLE bot_skills (
    id TEXT PRIMARY KEY,
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    slug TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    state TEXT NOT NULL,
    active_version INTEGER,
    skill_path TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(bot_id, slug)
);

CREATE INDEX bot_skills_bot_idx
    ON bot_skills(bot_id, updated_at DESC);

CREATE TABLE bot_skill_versions (
    id TEXT PRIMARY KEY,
    skill_id TEXT NOT NULL REFERENCES bot_skills(id) ON DELETE CASCADE,
    bot_id TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    version INTEGER NOT NULL,
    source_session_id TEXT NOT NULL REFERENCES teaching_sessions(id),
    save_request_id TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    skill_path TEXT NOT NULL,
    input_schema_json TEXT NOT NULL,
    verification_state TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(skill_id, version),
    UNIQUE(bot_id, save_request_id)
);

CREATE INDEX bot_skill_versions_skill_idx
    ON bot_skill_versions(skill_id, version DESC);
