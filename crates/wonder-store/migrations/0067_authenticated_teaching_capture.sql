ALTER TABLE teaching_sessions ADD COLUMN computer_session_id TEXT;
ALTER TABLE teaching_sessions ADD COLUMN control_lease_id TEXT;

CREATE INDEX teaching_sessions_control_binding_idx
    ON teaching_sessions(computer_session_id, control_lease_id, state);

CREATE TABLE teaching_events (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES teaching_sessions(id) ON DELETE CASCADE,
    control_sequence INTEGER NOT NULL,
    action_index INTEGER NOT NULL,
    event_json TEXT NOT NULL,
    payload_bytes INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(session_id, control_sequence, action_index)
);

CREATE INDEX teaching_events_session_idx
    ON teaching_events(session_id, control_sequence, action_index);
