-- Project threads have their own provider identity. Keep the historical Bot
-- and Group rows, including accepted runs, while allowing a typed Project
-- target with no fabricated Bot owner.
CREATE TABLE automation_runs_migration_backup AS SELECT * FROM automation_runs;
DROP TABLE automation_runs;

CREATE TABLE automations_migration_backup AS SELECT * FROM automations;
DROP TABLE automations;

CREATE TABLE automations (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('continuation', 'standalone')),
    bot_id TEXT REFERENCES bots(id),
    conversation_id TEXT,
    prompt TEXT NOT NULL,
    rrule TEXT NOT NULL,
    timezone TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'paused')),
    notification_policy TEXT NOT NULL CHECK (notification_policy IN ('all_runs', 'failed_runs_only')),
    model_id TEXT,
    reasoning_effort TEXT,
    scope_type TEXT NOT NULL DEFAULT 'bot',
    scope_id TEXT,
    next_run_at TEXT,
    last_run_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    CHECK (
        (scope_type = 'project_thread' AND bot_id IS NULL AND kind = 'continuation'
            AND scope_id IS NOT NULL AND conversation_id = scope_id)
        OR (scope_type IN ('bot', 'group_chat') AND bot_id IS NOT NULL)
    )
);
INSERT INTO automations (
    id, name, kind, bot_id, conversation_id, prompt, rrule, timezone, status,
    notification_policy, model_id, reasoning_effort, scope_type, scope_id,
    next_run_at, last_run_at, created_at, updated_at
)
SELECT id, name, kind, bot_id, conversation_id, prompt, rrule, timezone, status,
       notification_policy, model_id, reasoning_effort, scope_type,
       COALESCE(scope_id, bot_id), next_run_at, last_run_at, created_at, updated_at
FROM automations_migration_backup;
DROP TABLE automations_migration_backup;
CREATE INDEX automations_status_next_run_idx ON automations(status, next_run_at);
CREATE INDEX automations_scope_idx ON automations(scope_type, scope_id);

CREATE TABLE automation_runs (
    id TEXT PRIMARY KEY NOT NULL,
    automation_id TEXT NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
    scheduled_for TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed')),
    started_at TEXT NOT NULL,
    finished_at TEXT,
    error TEXT,
    message_id TEXT,
    automation_snapshot TEXT,
    conversation_id TEXT,
    UNIQUE (automation_id, scheduled_for)
);
INSERT INTO automation_runs (
    id, automation_id, scheduled_for, status, started_at, finished_at, error,
    message_id, automation_snapshot, conversation_id
)
SELECT id, automation_id, scheduled_for, status, started_at, finished_at, error,
       message_id, automation_snapshot, conversation_id
FROM automation_runs_migration_backup;
DROP TABLE automation_runs_migration_backup;
CREATE INDEX automation_runs_automation_idx ON automation_runs(automation_id, started_at DESC);
CREATE INDEX automation_runs_active_idx ON automation_runs(automation_id, status);

-- Table replacement removes its triggers. Keep committed-sync coverage.
CREATE TRIGGER sync_automations_insert AFTER INSERT ON automations BEGIN
    INSERT INTO sync_journal(host_epoch, occurred_at, conversation_id, resource, change_kind)
    SELECT host_epoch, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), NEW.conversation_id, 'automations', 'insert'
    FROM sync_state WHERE singleton = 1;
END;
CREATE TRIGGER sync_automations_update AFTER UPDATE ON automations BEGIN
    INSERT INTO sync_journal(host_epoch, occurred_at, conversation_id, resource, change_kind)
    SELECT host_epoch, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), NEW.conversation_id, 'automations', 'update'
    FROM sync_state WHERE singleton = 1;
END;
CREATE TRIGGER sync_automations_delete AFTER DELETE ON automations BEGIN
    INSERT INTO sync_journal(host_epoch, occurred_at, conversation_id, resource, change_kind)
    SELECT host_epoch, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), OLD.conversation_id, 'automations', 'delete'
    FROM sync_state WHERE singleton = 1;
END;
CREATE TRIGGER sync_automation_runs_insert AFTER INSERT ON automation_runs BEGIN
    INSERT INTO sync_journal(host_epoch, occurred_at, conversation_id, resource, change_kind)
    SELECT host_epoch, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), NULL, 'automation_runs', 'insert'
    FROM sync_state WHERE singleton = 1;
END;
CREATE TRIGGER sync_automation_runs_update AFTER UPDATE ON automation_runs BEGIN
    INSERT INTO sync_journal(host_epoch, occurred_at, conversation_id, resource, change_kind)
    SELECT host_epoch, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), NULL, 'automation_runs', 'update'
    FROM sync_state WHERE singleton = 1;
END;
CREATE TRIGGER sync_automation_runs_delete AFTER DELETE ON automation_runs BEGIN
    INSERT INTO sync_journal(host_epoch, occurred_at, conversation_id, resource, change_kind)
    SELECT host_epoch, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), NULL, 'automation_runs', 'delete'
    FROM sync_state WHERE singleton = 1;
END;
