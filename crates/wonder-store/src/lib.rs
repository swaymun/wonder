//! SQLite persistence for Wonder-owned metadata and the durable event ledger.

mod asr;
mod automations;
pub mod avatar;
mod onboarding;
pub use asr::{AsrJob, NewAsrJob};
pub use onboarding::BotInitialization;
mod push;
pub use push::{PushDelivery, PushPreview, PushRevocation};
mod questions;
pub use questions::AsyncQuestion;

use std::{cmp::Ordering, collections::HashMap, time::Duration};

use sqlx::{sqlite::SqlitePoolOptions, Row, SqlitePool};
use wonder_api::{HostEventEnvelope, WonderEvent};

pub const MIGRATION_NAMES: [&str; 72] = [
    "0001_initial.sql",
    "0002_message_body.sql",
    "0003_conversations.sql",
    "0004_approvals.sql",
    "0005_approval_action_nonce.sql",
    "0006_approval_correlation.sql",
    "0007_bots.sql",
    "0008_transcriptions.sql",
    "0009_bot_profiles.sql",
    "0010_automations.sql",
    "0011_automation_runs.sql",
    "0012_conversation_controls.sql",
    "0013_conversation_metadata.sql",
    "0014_assistant_messages.sql",
    "0015_bot_lifecycle.sql",
    "0016_conversation_file_metadata.sql",
    "0017_app_server_notifications.sql",
    "0018_search_index.sql",
    "0019_channels.sql",
    "0020_pending_app_server_notifications.sql",
    "0021_channel_messages.sql",
    "0022_pending_notification_envelope.sql",
    "0023_message_attachments.sql",
    "0024_approval_resolution_intent.sql",
    "0025_action_nonces.sql",
    "0026_device_session_expiration.sql",
    "0027_bot_workspaces_and_automation_scopes.sql",
    "0028_channel_orchestration_claim.sql",
    "0029_channel_automation_author.sql",
    "0030_channel_direct_phase.sql",
    "0031_conversation_dynamic_tools.sql",
    "0032_channel_message_presentation.sql",
    "0033_notification_inbox.sql",
    "0034_dispatch_attempts.sql",
    "0035_committed_sync.sql",
    "0036_history_retention.sql",
    "0037_editable_queue.sql",
    "0038_async_questions.sql",
    "0039_local_client_identity.sql",
    "0040_user_echo_projection.sql",
    "0041_group_runs.sql",
    "0042_group_context.sql",
    "0043_bot_file_access.sql",
    "0044_dispatch_context.sql",
    "0045_preserve_message_lifecycle.sql",
    "0046_bot_management.sql",
    "0047_automation_management.sql",
    "0048_bot_permission_modes.sql",
    "0049_project_assignments.sql",
    "0050_asr_jobs.sql",
    "0051_pm_tool_calls.sql",
    "0052_asr_request_cancellation.sql",
    "0053_forgotten_devices.sql",
    "0054_bot_onboarding.sql",
    "0055_bot_initialization.sql",
    "0056_group_collaboration.sql",
    "0057_message_execution_settings.sql",
    "0058_device_presence_sync.sql",
    "0059_approval_modes.sql",
    "0060_subagent_ownership.sql",
    "0061_message_execution_working_directory.sql",
    "0062_science_avatar_identity.sql",
    "0063_computer_sessions.sql",
    "0064_computer_control_leases.sql",
    "0065_teaching_and_skills.sql",
    "0066_skill_fixture_runs.sql",
    "0067_authenticated_teaching_capture.sql",
    "0068_bot_workspace_followups.sql",
    "0069_file_change_history_repair.sql",
    "0070_computer_tool_calls.sql",
    "0071_push.sql",
    "0072_push_previews_presence.sql",
];

mod bot_management;
pub use bot_management::BotFileRequest;
mod computer_sessions;
pub use computer_sessions::{
    ComputerControlLeaseCreate, ComputerLeaseAcquireResult, StoredComputerControlLease,
};
pub use computer_sessions::{ComputerSessionCreate, ComputerSessionState, StoredComputerSession};
mod teaching;
pub use teaching::{
    NewSkillFixtureRun, SkillFixtureRunReservation, SkillVersionReservation, StoredBotSkill,
    StoredBotSkillVersion, StoredSkillFixtureRun, StoredTeachingEvent, StoredTeachingSession,
    TeachingCaptureAppendResult, TeachingEventCreate, TeachingReview, TeachingSessionCreate,
    TEACHING_EXPIRED_REASON, TEACHING_MAX_EVENTS, TEACHING_MAX_EVIDENCE_BYTES,
    TEACHING_UNAVAILABLE,
};
mod file_access;
pub use file_access::BotFileAccess;
mod pm_tools;
mod project_assignments;
pub use project_assignments::ProjectAssignment;
mod group_collaboration;
mod groups;
pub use groups::GroupRun;
mod queue;
pub use queue::QueueItem;
mod history;
mod search;
pub use search::{SearchCursor, SearchPage};
mod retention;
pub use history::HistoryCursor;
pub use retention::ReplayStorageUsage;
mod sync;
pub use sync::{CommittedConversationSnapshot, ReplayBatch};

pub const INITIAL_MIGRATION: &str = include_str!("../migrations/0001_initial.sql");

#[derive(Clone)]
pub struct Store {
    pool: SqlitePool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceResetResult {
    pub workspace_paths: Vec<String>,
    pub revoked_device_ids: Vec<String>,
}

#[derive(Debug, Eq, PartialEq)]
pub enum MessageInsert {
    Inserted(StoredMessage),
    Existing(StoredMessage),
    Conflict,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredMessage {
    pub id: String,
    pub device_id: String,
    pub client_message_id: String,
    pub body: String,
    pub body_sha256: String,
    pub conversation_id: String,
    pub state: String,
    pub created_at: String,
    pub codex_thread_id: Option<String>,
    pub codex_turn_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredAssistantMessage {
    pub id: String,
    pub conversation_id: String,
    pub codex_thread_id: String,
    pub codex_turn_id: String,
    pub item_id: String,
    pub text: String,
    pub state: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredPendingAppServerNotification {
    pub id: String,
    pub identity_key: Option<String>,
    pub method: String,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub item_id: Option<String>,
    pub notification_json: String,
    pub params_json: String,
    pub received_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredSearchResult {
    pub kind: String,
    pub id: String,
    pub title: String,
    pub snippet: Option<String>,
    pub conversation_id: Option<String>,
    pub bot_id: Option<String>,
    pub updated_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredConversationSummary {
    pub conversation_id: String,
    pub bot_id: Option<String>,
    pub title: String,
    pub last_message_preview: Option<String>,
    pub last_message_at: Option<String>,
    pub message_count: u64,
    pub delivery_state: Option<String>,
    pub is_archived: bool,
    pub is_pinned: bool,
    pub has_unread: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredConversation {
    pub id: String,
    pub bot_id: String,
    pub title: String,
    pub is_archived: bool,
    pub is_pinned: bool,
    pub has_unread: bool,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredSubagentOwnership {
    pub conversation_id: String,
    pub parent_conversation_id: String,
    pub thread_id: String,
    pub parent_thread_id: String,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    pub agent_path: Option<String>,
    pub source_json: String,
    pub runtime_id: Option<String>,
    pub can_accept_direct_input: Option<bool>,
    pub status: String,
    pub is_archived: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct StoredChannelMember {
    pub bot_id: String,
    pub bot_name: String,
    pub role: String,
    pub position: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct StoredChannel {
    pub id: String,
    pub conversation_id: String,
    pub name: String,
    pub description: Option<String>,
    pub coordinator_bot_id: String,
    pub is_archived: bool,
    pub created_at: String,
    pub updated_at: String,
    pub members: Vec<StoredChannelMember>,
    pub messages: Vec<StoredChannelMessage>,
    #[serde(default)]
    pub has_unread: bool,
    #[serde(default)]
    pub host_epoch: Option<String>,
    #[serde(default)]
    pub last_sequence: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct StoredChannelMessage {
    #[serde(default)]
    pub attachment_ids: Vec<String>,
    pub message_id: String,
    pub client_message_id: String,
    pub body: String,
    pub state: String,
    pub created_at: String,
    pub body_sha256: String,
    pub codex_thread_id: Option<String>,
    pub codex_turn_id: Option<String>,
    pub author_kind: String,
    pub author_bot_id: Option<String>,
    pub author_bot_name: Option<String>,
    pub phase: String,
    pub presentation_kind: String,
    pub outcome: Option<String>,
    pub retryable: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NewChannelMessage<'a> {
    pub channel_id: &'a str,
    pub message_id: &'a str,
    pub author_kind: &'a str,
    pub author_bot_id: Option<&'a str>,
    pub phase: &'a str,
    pub created_at: &'a str,
    pub presentation_kind: &'a str,
    pub outcome: Option<&'a str>,
    pub retryable: bool,
}

struct AssistantPreview {
    text: String,
    occurred_at: String,
    sequence: u64,
}

fn search_match_query(query: &str) -> String {
    query
        .split(|character: char| !character.is_alphanumeric())
        .filter(|term| !term.is_empty())
        .take(8)
        .map(|term| format!("\"{term}\"*"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn parsed_timestamp(value: &str) -> Option<i128> {
    let value = value.trim();
    if let Ok(milliseconds) = value.parse::<i128>() {
        return milliseconds.checked_mul(1_000_000);
    }
    time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339)
        .ok()
        .map(|timestamp| timestamp.unix_timestamp_nanos())
}

fn compare_timestamps(left: &str, right: &str) -> Ordering {
    match (parsed_timestamp(left), parsed_timestamp(right)) {
        (Some(left), Some(right)) => left.cmp(&right),
        (Some(_), None) => Ordering::Greater,
        (None, Some(_)) => Ordering::Less,
        _ => left.cmp(right),
    }
}

fn timestamp_is_at_or_after(left: &str, right: &str) -> bool {
    compare_timestamps(left, right) != Ordering::Less
}

fn assistant_preview_is_newer(candidate: &AssistantPreview, current: &AssistantPreview) -> bool {
    match compare_timestamps(&candidate.occurred_at, &current.occurred_at) {
        Ordering::Greater => true,
        Ordering::Equal => candidate.sequence > current.sequence,
        Ordering::Less => false,
    }
}

fn compare_timestamps_desc(left: Option<&str>, right: Option<&str>) -> Ordering {
    match (left, right) {
        (Some(left), Some(right)) => compare_timestamps(right, left),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredDevice {
    pub id: String,
    pub created_at: String,
    pub label: String,
    pub public_key_jwk: String,
    pub last_seen_at: Option<String>,
    pub revoked_at: Option<String>,
    pub session_expires_at_ms: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredSession {
    pub token_hash: String,
    pub device_id: String,
    pub csrf_hash: String,
    pub expires_at_ms: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredBot {
    pub id: String,
    pub name: String,
    pub role: String,
    pub system_prompt: String,
    pub workspace_path: String,
    pub working_directory: Option<String>,
    pub avatar_color: Option<String>,
    pub avatar_shape: Option<String>,
    pub avatar_palette: Option<String>,
    pub avatar_legacy_color: Option<String>,
    pub permission_profile: String,
    pub permission_mode: Option<String>,
    pub approval_mode: Option<String>,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub service_tier: Option<String>,
    pub is_archived: bool,
    pub conversation_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredConversationSettings {
    pub conversation_id: String,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub service_tier: Option<String>,
    pub permission_profile: Option<String>,
    pub updated_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredConversationFile {
    pub id: String,
    pub conversation_id: String,
    pub kind: String,
    pub name: String,
    pub mime_type: Option<String>,
    pub byte_size: Option<i64>,
    pub sha256: Option<String>,
    pub relative_path: Option<String>,
    pub state: String,
    pub additions: Option<i64>,
    pub deletions: Option<i64>,
    pub source_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct StoredAutomation {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub bot_id: String,
    pub conversation_id: Option<String>,
    pub prompt: String,
    pub rrule: String,
    pub timezone: String,
    pub status: String,
    pub notification_policy: String,
    pub model_id: Option<String>,
    pub reasoning_effort: Option<String>,
    pub scope_type: String,
    pub scope_id: String,
    pub next_run_at: Option<String>,
    pub last_run_at: Option<String>,
    #[serde(default)]
    pub last_attempt_at: Option<String>,
    #[serde(default)]
    pub last_success_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredAutomationRun {
    pub id: String,
    pub automation_id: String,
    pub scheduled_for: String,
    pub status: String,
    pub started_at: String,
    pub finished_at: Option<String>,
    pub error: Option<String>,
    pub message_id: Option<String>,
    pub conversation_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StoredTranscription {
    pub id: String,
    pub state: String,
    pub source_device_id: String,
    pub duration_ms: u64,
    pub transcript_text: Option<String>,
    pub word_timestamps_json: Option<String>,
    pub confidence: Option<f32>,
    pub retry_expires_at_ms: Option<u64>,
    pub error_category: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredApproval {
    pub approval_id: String,
    pub server_request_id: String,
    pub method: String,
    pub params_json: String,
    pub action_nonce: String,
    pub state: String,
    pub decision: Option<String>,
    pub thread_id: String,
    pub turn_id: String,
    pub item_id: String,
    pub resolution_idempotency_key: Option<String>,
    pub resolution_body_sha256: Option<String>,
    pub resolution_json: Option<String>,
}

impl Store {
    pub async fn connect(database_url: &str) -> Result<Self, sqlx::Error> {
        let pool = SqlitePoolOptions::new()
            .max_connections(5)
            .after_connect(|connection, _| {
                Box::pin(async move {
                    sqlx::query("PRAGMA busy_timeout = 5000")
                        .execute(connection)
                        .await?;
                    Ok(())
                })
            })
            .acquire_timeout(Duration::from_secs(5))
            .connect(database_url)
            .await?;
        sqlx::query("PRAGMA journal_mode = WAL")
            .execute(&pool)
            .await?;
        sqlx::migrate!().run(&pool).await?;
        cleanup_taught_task_sections(&pool).await?;
        let store = Self { pool };
        backfill_avatar_identity(&store.pool).await?;
        store.prune_replay().await?;
        Ok(store)
    }

    pub async fn upsert_owner_device(
        &self,
        id: &str,
        label: &str,
        public_key_jwk: &str,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        self.upsert_owner_device_with_expiration(id, label, public_key_jwk, None, now)
            .await
    }

    pub async fn upsert_owner_device_with_expiration(
        &self,
        id: &str,
        label: &str,
        public_key_jwk: &str,
        session_expires_at_ms: Option<u64>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO devices (id, label, role, public_key_jwk, created_at, last_seen_at, session_expires_at_ms) VALUES (?, ?, 'owner', ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET label = excluded.label, public_key_jwk = excluded.public_key_jwk, last_seen_at = excluded.last_seen_at, session_expires_at_ms = excluded.session_expires_at_ms")
            .bind(id)
            .bind(label)
            .bind(public_key_jwk)
            .bind(now)
            .bind(now)
            .bind(session_expires_at_ms.map(|value| value as i64))
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Only the daemon's authenticated local route may create this attribution.
    /// It has no pairing key and is excluded from restored remote identities.
    pub async fn ensure_local_desktop(&self, now: &str) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO devices (id, label, role, public_key_jwk, created_at, is_local) VALUES ('wonder-desktop', 'This Mac', 'owner', '{}', ?, 1) ON CONFLICT(id) DO NOTHING")
            .bind(now).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn list_owner_devices(&self) -> Result<Vec<StoredDevice>, sqlx::Error> {
        let rows = sqlx::query("SELECT id, label, public_key_jwk, created_at, last_seen_at, revoked_at, session_expires_at_ms FROM devices WHERE role = 'owner' AND is_local = 0 AND forgotten = 0 ORDER BY created_at ASC")
            .fetch_all(&self.pool)
            .await?;
        Ok(rows
            .into_iter()
            .map(|row| StoredDevice {
                created_at: row.get("created_at"),
                id: row.get("id"),
                label: row.get("label"),
                public_key_jwk: row.get("public_key_jwk"),
                last_seen_at: row.get("last_seen_at"),
                revoked_at: row.get("revoked_at"),
                session_expires_at_ms: row
                    .get::<Option<i64>, _>("session_expires_at_ms")
                    .map(|value| value as u64),
            })
            .collect())
    }

    /// Automation messages are still owner-visible messages, so associate
    /// them with the most recently active authorized owner device. The
    /// device id is required by the messages foreign key; automations do not
    /// create a second device identity of their own.
    pub async fn automation_message_device_id(&self) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar(
            "SELECT id FROM devices WHERE role = 'owner' AND revoked_at IS NULL ORDER BY last_seen_at DESC, created_at ASC, id ASC LIMIT 1",
        )
        .fetch_optional(&self.pool)
        .await
    }

    pub async fn touch_owner_device(
        &self,
        device_id: &str,
        last_seen_at: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE devices SET last_seen_at = ? WHERE id = ? AND role = 'owner' AND revoked_at IS NULL",
        )
        .bind(last_seen_at)
        .bind(device_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn rename_owner_device(
        &self,
        device_id: &str,
        label: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE devices SET label = ? WHERE id = ? AND role = 'owner' AND revoked_at IS NULL",
        )
        .bind(label)
        .bind(device_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn forget_revoked_device(&self, device_id: &str) -> Result<bool, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        let result = sqlx::query("UPDATE devices SET forgotten = 1, label = 'Removed device', public_key_jwk = '{}', last_seen_at = NULL, session_expires_at_ms = NULL WHERE id = ? AND is_local = 0 AND revoked_at IS NOT NULL AND forgotten = 0")
            .bind(device_id).execute(&mut *transaction).await?;
        if result.rows_affected() == 1 {
            sqlx::query("DELETE FROM sessions WHERE device_id = ?")
                .bind(device_id)
                .execute(&mut *transaction)
                .await?;
        }
        transaction.commit().await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn revoke_owner_device(
        &self,
        device_id: &str,
        revoked_at: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query("UPDATE devices SET revoked_at = ? WHERE id = ? AND role = 'owner' AND revoked_at IS NULL")
            .bind(revoked_at)
            .bind(device_id)
            .execute(&self.pool)
            .await?;
        sqlx::query("DELETE FROM sessions WHERE device_id = ?")
            .bind(device_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() == 1)
    }

    /// Permanently remove user-owned Wonder data while preserving one active
    /// owner device. This is intentionally an application-level transaction so
    /// reset callers cannot accidentally leave orphaned conversation or bot
    /// records behind by deleting rows in an unsafe order.
    pub async fn reset_workspace(
        &self,
        keep_device_id: &str,
        revoked_at: &str,
    ) -> Result<WorkspaceResetResult, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        let keep_exists = sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM devices WHERE id = ? AND role = 'owner' AND revoked_at IS NULL",
        )
        .bind(keep_device_id)
        .fetch_one(&mut *transaction)
        .await?
            == 1;
        if !keep_exists {
            return Err(sqlx::Error::RowNotFound);
        }

        let workspace_paths =
            sqlx::query_scalar::<_, String>("SELECT workspace_path FROM bots ORDER BY id ASC")
                .fetch_all(&mut *transaction)
                .await?;
        let revoked_device_ids = sqlx::query_scalar::<_, String>(
            "SELECT id FROM devices WHERE role = 'owner' AND revoked_at IS NULL AND id != ? ORDER BY id ASC",
        )
        .bind(keep_device_id)
        .fetch_all(&mut *transaction)
        .await?;

        sqlx::query("DELETE FROM sessions WHERE device_id != ?")
            .bind(keep_device_id)
            .execute(&mut *transaction)
            .await?;
        sqlx::query("UPDATE devices SET revoked_at = ? WHERE role = 'owner' AND revoked_at IS NULL AND id != ?")
            .bind(revoked_at)
            .bind(keep_device_id)
            .execute(&mut *transaction)
            .await?;

        // Delete children before their referenced rows. Some legacy tables do
        // not declare cascading foreign keys, so being explicit keeps this
        // safe across every supported migration state.
        for statement in [
            "DELETE FROM push_routes",
            "DELETE FROM push_outbox",
            "DELETE FROM push_intents",
            "DELETE FROM project_assignments",
            "DELETE FROM message_attachments",
            "DELETE FROM channel_messages",
            "DELETE FROM channel_members",
            "DELETE FROM automation_runs",
            "DELETE FROM assistant_message_deltas",
            "DELETE FROM assistant_messages",
            "DELETE FROM conversation_settings",
            "DELETE FROM conversation_files",
            "DELETE FROM pending_app_server_notifications",
            "DELETE FROM notification_inbox",
            "DELETE FROM app_server_notification_receipts",
            "DELETE FROM approvals",
            "DELETE FROM asr_cancelled_requests",
            "DELETE FROM transcriptions",
            "DELETE FROM subagent_ownership",
            "DELETE FROM conversations",
            "DELETE FROM conversation_metadata",
            "DELETE FROM messages",
            "DELETE FROM automations",
            "DELETE FROM channels",
            "DELETE FROM bot_workspaces",
            "DELETE FROM bots",
            "DELETE FROM search_documents",
            "DELETE FROM action_nonces",
            "DELETE FROM events",
            "DELETE FROM sync_journal",
            "DELETE FROM history_entries",
            "DELETE FROM history_hydration",
        ] {
            // The statements are fixed literals; assert that audit for SQLx's
            // dynamic-query safety check without changing reset behavior.
            sqlx::query(sqlx::AssertSqlSafe(statement))
                .execute(&mut *transaction)
                .await?;
        }

        sqlx::query("INSERT INTO sync_journal(host_epoch, occurred_at, resource, change_kind) SELECT host_epoch, ?, 'workspace', 'reset' FROM sync_state WHERE singleton = 1")
            .bind(revoked_at).execute(&mut *transaction).await?;

        transaction.commit().await?;
        Ok(WorkspaceResetResult {
            workspace_paths,
            revoked_device_ids,
        })
    }

    pub async fn insert_session(
        &self,
        token_hash: &str,
        device_id: &str,
        csrf_hash: &str,
        expires_at_ms: u64,
        created_at: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO sessions (token_hash, device_id, csrf_hash, expires_at_ms, created_at) VALUES (?, ?, ?, ?, ?)")
            .bind(token_hash)
            .bind(device_id)
            .bind(csrf_hash)
            .bind(expires_at_ms as i64)
            .bind(created_at)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn claim_action_nonce(
        &self,
        nonce: &str,
        used_at: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "INSERT INTO action_nonces (nonce, used_at) VALUES (?, ?) ON CONFLICT(nonce) DO NOTHING",
        )
        .bind(nonce)
        .bind(used_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn upsert_bot(
        &self,
        id: &str,
        name: &str,
        role: &str,
        system_prompt: &str,
        workspace_path: &str,
        permission_profile: &str,
        model: Option<&str>,
        reasoning_effort: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        self.upsert_bot_with_service_tier(
            id,
            name,
            role,
            system_prompt,
            workspace_path,
            permission_profile,
            model,
            reasoning_effort,
            None,
            now,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn upsert_bot_with_service_tier(
        &self,
        id: &str,
        name: &str,
        role: &str,
        system_prompt: &str,
        workspace_path: &str,
        permission_profile: &str,
        model: Option<&str>,
        reasoning_effort: Option<&str>,
        service_tier: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        let has_avatar_identity: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM pragma_table_info('bots') WHERE name IN ('avatar_color', 'avatar_shape', 'avatar_palette')",
        )
        .fetch_one(&self.pool)
        .await?;
        if has_avatar_identity == 3 {
            let default_palette = avatar::palette(avatar::DEFAULT_PALETTE)
                .expect("the default avatar palette must be in the catalog");
            sqlx::query(
                "INSERT INTO bots (id, name, role, system_prompt, workspace_path, permission_profile, model, reasoning_effort, service_tier, avatar_color, avatar_shape, avatar_palette, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, role = excluded.role, system_prompt = excluded.system_prompt, workspace_path = excluded.workspace_path, permission_profile = excluded.permission_profile, model = excluded.model, reasoning_effort = excluded.reasoning_effort, service_tier = COALESCE(excluded.service_tier, bots.service_tier)",
            )
            .bind(id)
            .bind(name)
            .bind(role)
            .bind(system_prompt)
            .bind(workspace_path)
            .bind(permission_profile)
            .bind(model)
            .bind(reasoning_effort)
            .bind(service_tier)
            .bind(default_palette.body)
            .bind(avatar::DEFAULT_SHAPE)
            .bind(avatar::DEFAULT_PALETTE)
            .bind(now)
            .execute(&self.pool)
            .await?;
        } else {
            sqlx::query(
                "INSERT INTO bots (id, name, role, system_prompt, workspace_path, permission_profile, model, reasoning_effort, service_tier, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, role = excluded.role, system_prompt = excluded.system_prompt, workspace_path = excluded.workspace_path, permission_profile = excluded.permission_profile, model = excluded.model, reasoning_effort = excluded.reasoning_effort, service_tier = COALESCE(excluded.service_tier, bots.service_tier)",
            )
            .bind(id)
            .bind(name)
            .bind(role)
            .bind(system_prompt)
            .bind(workspace_path)
            .bind(permission_profile)
            .bind(model)
            .bind(reasoning_effort)
            .bind(service_tier)
            .bind(now)
            .execute(&self.pool)
            .await?;
        }
        Ok(())
    }

    pub async fn list_bots(&self) -> Result<Vec<StoredBot>, sqlx::Error> {
        let rows = sqlx::query("SELECT bots.id, bots.name, bots.role, bots.system_prompt, bots.workspace_path, bots.working_directory, bots.avatar_color, bots.avatar_shape, bots.avatar_palette, bots.avatar_legacy_color, bots.permission_profile, bots.permission_mode, bots.approval_mode, bots.model, bots.reasoning_effort, bots.service_tier, bots.is_archived, bot_workspaces.conversation_id FROM bots LEFT JOIN bot_workspaces ON bot_workspaces.bot_id = bots.id WHERE NOT EXISTS(SELECT 1 FROM bot_creation_requests r WHERE r.bot_id=bots.id AND r.completed=0) ORDER BY bots.is_archived ASC, bots.created_at ASC")
            .fetch_all(&self.pool)
            .await?;
        Ok(rows
            .into_iter()
            .map(|row| StoredBot {
                id: row.get("id"),
                name: row.get("name"),
                role: row.get("role"),
                system_prompt: row.get("system_prompt"),
                workspace_path: row.get("workspace_path"),
                working_directory: row.get("working_directory"),
                avatar_color: row.get("avatar_color"),
                avatar_shape: row.get("avatar_shape"),
                avatar_palette: row.get("avatar_palette"),
                avatar_legacy_color: row.get("avatar_legacy_color"),
                permission_profile: row.get("permission_profile"),
                permission_mode: row.get("permission_mode"),
                approval_mode: row.get("approval_mode"),
                model: row.get("model"),
                reasoning_effort: row.get("reasoning_effort"),
                service_tier: row.get("service_tier"),
                is_archived: row.get::<i64, _>("is_archived") != 0,
                conversation_id: row.get("conversation_id"),
            })
            .collect())
    }

    pub async fn bot(&self, id: &str) -> Result<Option<StoredBot>, sqlx::Error> {
        sqlx::query("SELECT bots.id, bots.name, bots.role, bots.system_prompt, bots.workspace_path, bots.working_directory, bots.avatar_color, bots.avatar_shape, bots.avatar_palette, bots.avatar_legacy_color, bots.permission_profile, bots.permission_mode, bots.approval_mode, bots.model, bots.reasoning_effort, bots.service_tier, bots.is_archived, bot_workspaces.conversation_id FROM bots LEFT JOIN bot_workspaces ON bot_workspaces.bot_id = bots.id WHERE bots.id = ?")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.map(|row| stored_bot(&row)))
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn update_bot(
        &self,
        id: &str,
        name: Option<&str>,
        role: Option<&str>,
        system_prompt: Option<&str>,
        model: Option<&str>,
        reasoning_effort: Option<&str>,
        service_tier: Option<&str>,
    ) -> Result<Option<StoredBot>, sqlx::Error> {
        let result = sqlx::query("UPDATE bots SET name = COALESCE(?, name), role = COALESCE(?, role), system_prompt = COALESCE(?, system_prompt), model = COALESCE(?, model), reasoning_effort = COALESCE(?, reasoning_effort), service_tier = COALESCE(?, service_tier) WHERE id = ?")
            .bind(name)
            .bind(role)
            .bind(system_prompt)
            .bind(model)
            .bind(reasoning_effort)
            .bind(service_tier)
            .bind(id)
            .execute(&self.pool)
            .await?;
        if result.rows_affected() == 0 {
            return Ok(None);
        }
        self.bot(id).await
    }

    pub async fn set_bot_archived(
        &self,
        id: &str,
        is_archived: bool,
    ) -> Result<Option<StoredBot>, sqlx::Error> {
        let result = sqlx::query("UPDATE bots SET is_archived = ? WHERE id = ?")
            .bind(i64::from(is_archived))
            .bind(id)
            .execute(&self.pool)
            .await?;
        if result.rows_affected() == 0 {
            return Ok(None);
        }
        self.bot(id).await
    }

    pub async fn delete_bot(&self, id: &str) -> Result<bool, sqlx::Error> {
        let result = sqlx::query("DELETE FROM bots WHERE id = ? AND NOT EXISTS (SELECT 1 FROM conversation_metadata WHERE bot_id = ?) AND NOT EXISTS (SELECT 1 FROM automations WHERE bot_id = ?) AND NOT EXISTS (SELECT 1 FROM channels WHERE coordinator_bot_id = ?) AND NOT EXISTS (SELECT 1 FROM channel_members WHERE bot_id = ?)")
            .bind(id)
            .bind(id)
            .bind(id)
            .bind(id)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn create_conversation(
        &self,
        id: &str,
        bot_id: &str,
        title: &str,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO conversation_metadata (id, bot_id, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?)")
            .bind(id)
            .bind(bot_id)
            .bind(title)
            .bind(now)
            .bind(now)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn ensure_bot_workspace(
        &self,
        bot_id: &str,
        title: &str,
        now: &str,
    ) -> Result<String, sqlx::Error> {
        if let Some(row) =
            sqlx::query("SELECT conversation_id FROM bot_workspaces WHERE bot_id = ?")
                .bind(bot_id)
                .fetch_optional(&self.pool)
                .await?
        {
            let conversation_id: String = row.get("conversation_id");
            sqlx::query("UPDATE conversation_metadata SET title = ?, updated_at = ? WHERE id = ?")
                .bind(title)
                .bind(now)
                .bind(&conversation_id)
                .execute(&self.pool)
                .await?;
            return Ok(conversation_id);
        }
        let conversation_id = format!("bot:{bot_id}");
        self.ensure_conversation_metadata(&conversation_id, bot_id, title, now)
            .await?;
        sqlx::query("INSERT INTO bot_workspaces (bot_id, conversation_id, created_at, updated_at) VALUES (?, ?, ?, ?)")
            .bind(bot_id)
            .bind(&conversation_id)
            .bind(now)
            .bind(now)
            .execute(&self.pool)
            .await?;
        Ok(conversation_id)
    }

    pub async fn bot_workspace(&self, bot_id: &str) -> Result<Option<String>, sqlx::Error> {
        sqlx::query("SELECT conversation_id FROM bot_workspaces WHERE bot_id = ?")
            .bind(bot_id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.map(|row| row.get("conversation_id")))
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn create_channel(
        &self,
        id: &str,
        conversation_id: &str,
        name: &str,
        description: Option<&str>,
        coordinator_bot_id: &str,
        member_bot_ids: &[(&str, &str)],
        now: &str,
    ) -> Result<StoredChannel, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query(
            "INSERT INTO channels (id, conversation_id, name, description, coordinator_bot_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(conversation_id)
        .bind(name)
        .bind(description)
        .bind(coordinator_bot_id)
        .bind(now)
        .bind(now)
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            "INSERT INTO conversation_metadata (id, bot_id, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        )
        .bind(conversation_id)
        .bind(coordinator_bot_id)
        .bind(name)
        .bind(now)
        .bind(now)
        .execute(&mut *transaction)
        .await?;
        for (position, (bot_id, role)) in member_bot_ids.iter().enumerate() {
            sqlx::query(
                "INSERT INTO channel_members (channel_id, bot_id, role, position, created_at) VALUES (?, ?, ?, ?, ?)",
            )
            .bind(id)
            .bind(*bot_id)
            .bind(*role)
            .bind(position as i64)
            .bind(now)
            .execute(&mut *transaction)
            .await?;
        }
        transaction.commit().await?;
        self.channel(id).await?.ok_or(sqlx::Error::RowNotFound)
    }

    pub async fn channel(&self, id: &str) -> Result<Option<StoredChannel>, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        // Pin the WAL snapshot before reading any visible Group projection.
        let fence =
            sqlx::query("SELECT host_epoch, last_sequence FROM sync_state WHERE singleton=1")
                .fetch_optional(&mut *tx)
                .await?;
        let row = sqlx::query(
            "SELECT channels.*, COALESCE(metadata.has_unread,0) AS has_unread FROM channels LEFT JOIN conversation_metadata metadata ON metadata.id=channels.conversation_id WHERE channels.id = ?",
        )
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(row) = row else {
            return Ok(None);
        };
        let members = Self::channel_members_on(&mut tx, id).await?;
        let messages = Self::channel_messages_on(&mut tx, id).await?;
        Ok(Some(StoredChannel {
            has_unread: row.get::<i64, _>("has_unread") != 0,
            host_epoch: fence.as_ref().map(|r| r.get("host_epoch")),
            last_sequence: fence
                .as_ref()
                .map(|r| r.get::<i64, _>("last_sequence") as u64),
            id: row.get("id"),
            conversation_id: row.get("conversation_id"),
            name: row.get("name"),
            description: row.get("description"),
            coordinator_bot_id: row.get("coordinator_bot_id"),
            is_archived: row.get::<i64, _>("is_archived") != 0,
            created_at: row.get("created_at"),
            updated_at: row.get("updated_at"),
            members,
            messages,
        }))
    }

    pub async fn list_channels(&self) -> Result<Vec<StoredChannel>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT id FROM channels ORDER BY is_archived ASC, updated_at DESC, id ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut channels = Vec::with_capacity(rows.len());
        for row in rows {
            if let Some(channel) = self.channel(row.get("id")).await? {
                channels.push(channel);
            }
        }
        Ok(channels)
    }

    pub async fn update_channel(
        &self,
        id: &str,
        name: Option<&str>,
        description: Option<Option<&str>>,
        is_archived: Option<bool>,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE channels SET name = COALESCE(?, name), description = CASE WHEN ? THEN ? ELSE description END, is_archived = COALESCE(?, is_archived), updated_at = ? WHERE id = ?",
        )
        .bind(name)
        .bind(description.is_some())
        .bind(description.flatten())
        .bind(is_archived.map(i64::from))
        .bind(now)
        .bind(id)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 1 && name.is_some() {
            sqlx::query("UPDATE conversation_metadata SET title = ?, updated_at = ? WHERE id = (SELECT conversation_id FROM channels WHERE id = ?)")
                .bind(name)
                .bind(now)
                .bind(id)
                .execute(&self.pool)
                .await?;
        }
        Ok(result.rows_affected() == 1)
    }

    pub async fn channel_members(
        &self,
        channel_id: &str,
    ) -> Result<Vec<StoredChannelMember>, sqlx::Error> {
        Self::channel_members_on(&mut *self.pool.acquire().await?, channel_id).await
    }

    async fn channel_members_on(
        connection: &mut sqlx::SqliteConnection,
        channel_id: &str,
    ) -> Result<Vec<StoredChannelMember>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT members.bot_id, bots.name AS bot_name, members.role, members.position FROM channel_members AS members JOIN bots ON bots.id = members.bot_id WHERE members.channel_id = ? ORDER BY members.position ASC, members.bot_id ASC",
        )
        .bind(channel_id)
        .fetch_all(&mut *connection)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| StoredChannelMember {
                bot_id: row.get("bot_id"),
                bot_name: row.get("bot_name"),
                role: row.get("role"),
                position: row.get("position"),
            })
            .collect())
    }

    pub async fn add_channel_message(
        &self,
        message: NewChannelMessage<'_>,
    ) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "INSERT INTO channel_messages (channel_id, message_id, author_kind, author_bot_id, phase, created_at, presentation_kind, outcome, retryable) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(channel_id, message_id) DO UPDATE SET author_kind = excluded.author_kind, author_bot_id = excluded.author_bot_id, phase = excluded.phase, presentation_kind = excluded.presentation_kind, outcome = excluded.outcome, retryable = excluded.retryable",
        )
        .bind(message.channel_id)
        .bind(message.message_id)
        .bind(message.author_kind)
        .bind(message.author_bot_id)
        .bind(message.phase)
        .bind(message.created_at)
        .bind(message.presentation_kind)
        .bind(message.outcome)
        .bind(message.retryable)
        .execute(&mut *tx)
        .await?;
        if matches!(message.author_kind, "member" | "coordinator") {
            // These are finished presentation copies, never executable work.
            sqlx::query(
                "UPDATE messages SET state='completed' WHERE id=? AND state='accepted_by_wonder'",
            )
            .bind(message.message_id)
            .execute(&mut *tx)
            .await?;
        }
        if matches!(message.author_kind, "member" | "coordinator")
            && (message.presentation_kind == "message"
                || matches!(
                    message.outcome,
                    Some("failed" | "interrupted" | "timed_out")
                ))
        {
            sqlx::query("UPDATE conversation_metadata SET has_unread=1, updated_at=? WHERE id=(SELECT conversation_id FROM channels WHERE id=?)")
                .bind(message.created_at).bind(message.channel_id).execute(&mut *tx).await?;
        }
        tx.commit().await
    }

    pub async fn claim_channel_orchestration(
        &self,
        channel_id: &str,
        message_id: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE channel_messages SET orchestration_claimed = 1 WHERE channel_id = ? AND message_id = ? AND orchestration_claimed = 0",
        )
        .bind(channel_id)
        .bind(message_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn channel_messages(
        &self,
        channel_id: &str,
    ) -> Result<Vec<StoredChannelMessage>, sqlx::Error> {
        Self::channel_messages_on(&mut *self.pool.acquire().await?, channel_id).await
    }

    async fn channel_messages_on(
        connection: &mut sqlx::SqliteConnection,
        channel_id: &str,
    ) -> Result<Vec<StoredChannelMessage>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT COALESCE((SELECT json_group_array(file_id) FROM (SELECT file_id FROM message_attachments WHERE message_id=messages.id ORDER BY file_id)), '[]') AS attachment_ids, messages.id AS message_id, messages.client_message_id, messages.body, messages.state, messages.created_at, messages.body_sha256, messages.codex_thread_id, messages.codex_turn_id, channel_messages.author_kind, channel_messages.author_bot_id, COALESCE(bots.name, channel_messages.historical_author_name) AS author_bot_name, channel_messages.phase, channel_messages.presentation_kind, channel_messages.outcome, channel_messages.retryable FROM channel_messages JOIN messages ON messages.id = channel_messages.message_id LEFT JOIN bots ON bots.id = channel_messages.author_bot_id WHERE channel_messages.channel_id = ? ORDER BY messages.created_at ASC, messages.rowid ASC",
        )
        .bind(channel_id)
        .fetch_all(&mut *connection)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| StoredChannelMessage {
                attachment_ids: serde_json::from_str(row.get("attachment_ids")).unwrap_or_default(),
                message_id: row.get("message_id"),
                client_message_id: row.get("client_message_id"),
                body: row.get("body"),
                state: row.get("state"),
                created_at: row.get("created_at"),
                body_sha256: row.get("body_sha256"),
                codex_thread_id: row.get("codex_thread_id"),
                codex_turn_id: row.get("codex_turn_id"),
                author_kind: row.get("author_kind"),
                author_bot_id: row.get("author_bot_id"),
                author_bot_name: row.get("author_bot_name"),
                phase: row.get("phase"),
                presentation_kind: row.get("presentation_kind"),
                outcome: row.get("outcome"),
                retryable: row.get("retryable"),
            })
            .collect())
    }

    pub async fn add_channel_member(
        &self,
        channel_id: &str,
        bot_id: &str,
        role: &str,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        let position = sqlx::query("SELECT COALESCE(MAX(position), -1) + 1 AS next_position FROM channel_members WHERE channel_id = ?")
            .bind(channel_id)
            .fetch_one(&self.pool)
            .await?
            .get::<i64, _>("next_position");
        let result = sqlx::query("INSERT INTO channel_members (channel_id, bot_id, role, position, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(channel_id, bot_id) DO NOTHING")
            .bind(channel_id)
            .bind(bot_id)
            .bind(role)
            .bind(position)
            .bind(now)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn remove_channel_member(
        &self,
        channel_id: &str,
        bot_id: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query("DELETE FROM channel_members WHERE channel_id = ? AND bot_id = ? AND role != 'coordinator'")
            .bind(channel_id)
            .bind(bot_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn conversation(&self, id: &str) -> Result<Option<StoredConversation>, sqlx::Error> {
        sqlx::query("SELECT id, bot_id, title, is_archived, is_pinned, has_unread, created_at, updated_at FROM conversation_metadata WHERE id = ?")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.map(|row| StoredConversation {
                id: row.get("id"),
                bot_id: row.get("bot_id"),
                title: row.get("title"),
                is_archived: row.get::<i64, _>("is_archived") != 0,
                is_pinned: row.get::<i64, _>("is_pinned") != 0,
                has_unread: row.get::<i64, _>("has_unread") != 0,
                created_at: row.get("created_at"),
                updated_at: row.get("updated_at"),
            }))
    }

    pub async fn update_conversation(
        &self,
        id: &str,
        title: Option<&str>,
        is_archived: Option<bool>,
        is_pinned: Option<bool>,
        has_unread: Option<bool>,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query("UPDATE conversation_metadata SET title = COALESCE(?, title), is_archived = COALESCE(?, is_archived), is_pinned = COALESCE(?, is_pinned), has_unread = COALESCE(?, has_unread), updated_at = ? WHERE id = ?")
            .bind(title)
            .bind(is_archived.map(i64::from))
            .bind(is_pinned.map(i64::from))
            .bind(has_unread.map(i64::from))
            .bind(now)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn ensure_conversation_metadata(
        &self,
        id: &str,
        bot_id: &str,
        title: &str,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO conversation_metadata (id, bot_id, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING")
            .bind(id)
            .bind(bot_id)
            .bind(title)
            .bind(now)
            .bind(now)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Persist the runtime's verified child/thread binding. The parent and
    /// thread fields are immutable once exposed so a reconnect cannot retarget
    /// an existing child conversation.
    #[allow(clippy::too_many_arguments)]
    pub async fn register_subagent_ownership(
        &self,
        conversation_id: &str,
        parent_conversation_id: &str,
        thread_id: &str,
        parent_thread_id: &str,
        bot_id: &str,
        title: &str,
        agent_nickname: Option<&str>,
        agent_role: Option<&str>,
        agent_path: Option<&str>,
        source_json: &str,
        runtime_id: Option<&str>,
        can_accept_direct_input: Option<bool>,
        status: &str,
        is_archived: Option<bool>,
        verified_at: &str,
    ) -> Result<StoredSubagentOwnership, sqlx::Error> {
        if conversation_id.is_empty()
            || parent_conversation_id.is_empty()
            || thread_id.is_empty()
            || parent_thread_id.is_empty()
            || conversation_id == parent_conversation_id
            || thread_id == parent_thread_id
        {
            return Err(sqlx::Error::Protocol(
                "invalid subagent ownership identity".into(),
            ));
        }
        let mut tx = self.pool.begin().await?;
        let Some(parent) = sqlx::query("SELECT bot_id FROM conversation_metadata WHERE id = ?")
            .bind(parent_conversation_id)
            .fetch_optional(&mut *tx)
            .await?
        else {
            return Err(sqlx::Error::RowNotFound);
        };
        let parent_bot_id: String = parent.get("bot_id");
        if parent_bot_id != bot_id {
            return Err(sqlx::Error::Protocol(
                "subagent parent Bot does not match ownership".into(),
            ));
        }
        let existing = sqlx::query(
            "SELECT conversation_id, parent_conversation_id, thread_id, parent_thread_id, agent_nickname, agent_role, agent_path, source_json, runtime_id, can_accept_direct_input, status, is_archived FROM subagent_ownership WHERE conversation_id = ?",
        )
        .bind(conversation_id)
        .fetch_optional(&mut *tx)
        .await?;
        if let Some(row) = existing {
            let current = stored_subagent_ownership(&row);
            if current.parent_conversation_id != parent_conversation_id
                || current.thread_id != thread_id
                || current.parent_thread_id != parent_thread_id
            {
                return Err(sqlx::Error::Protocol(
                    "subagent ownership is immutable".into(),
                ));
            }
            sqlx::query(
                "UPDATE subagent_ownership SET agent_nickname = COALESCE(?, agent_nickname), agent_role = COALESCE(?, agent_role), agent_path = COALESCE(?, agent_path), source_json = ?, runtime_id = COALESCE(?, runtime_id), can_accept_direct_input = ?, status = ?, is_archived = COALESCE(?, is_archived), verified_at = ? WHERE conversation_id = ?",
            )
            .bind(agent_nickname)
            .bind(agent_role)
            .bind(agent_path)
            .bind(source_json)
            .bind(runtime_id)
            .bind(can_accept_direct_input.map(i64::from))
            .bind(status)
            .bind(is_archived.map(i64::from))
            .bind(verified_at)
            .bind(conversation_id)
            .execute(&mut *tx)
            .await?;
        } else {
            if sqlx::query("SELECT 1 FROM conversation_metadata WHERE id = ?")
                .bind(conversation_id)
                .fetch_optional(&mut *tx)
                .await?
                .is_some()
            {
                return Err(sqlx::Error::Protocol(
                    "subagent conversation identity is already in use".into(),
                ));
            }
            sqlx::query(
                "INSERT INTO conversation_metadata (id, bot_id, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            )
            .bind(conversation_id)
            .bind(bot_id)
            .bind(title)
            .bind(verified_at)
            .bind(verified_at)
            .execute(&mut *tx)
            .await?;
            sqlx::query(
                "INSERT INTO conversations (id, codex_thread_id, session_id, created_at) VALUES (?, ?, NULL, ?)",
            )
            .bind(conversation_id)
            .bind(thread_id)
            .bind(verified_at)
            .execute(&mut *tx)
            .await?;
            sqlx::query(
                "INSERT INTO subagent_ownership (conversation_id, parent_conversation_id, thread_id, parent_thread_id, agent_nickname, agent_role, agent_path, source_json, runtime_id, can_accept_direct_input, status, is_archived, verified_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(conversation_id)
            .bind(parent_conversation_id)
            .bind(thread_id)
            .bind(parent_thread_id)
            .bind(agent_nickname)
            .bind(agent_role)
            .bind(agent_path)
            .bind(source_json)
            .bind(runtime_id)
            .bind(can_accept_direct_input.map(i64::from))
            .bind(status)
            .bind(i64::from(is_archived.unwrap_or(false)))
            .bind(verified_at)
            .execute(&mut *tx)
            .await?;
        }
        let result = sqlx::query(
            "SELECT conversation_id, parent_conversation_id, thread_id, parent_thread_id, agent_nickname, agent_role, agent_path, source_json, runtime_id, can_accept_direct_input, status, is_archived FROM subagent_ownership WHERE conversation_id = ?",
        )
        .bind(conversation_id)
        .fetch_optional(&mut *tx)
        .await?
        .map(|row| stored_subagent_ownership(&row))
        .ok_or(sqlx::Error::RowNotFound)?;
        tx.commit().await?;
        Ok(result)
    }

    pub async fn subagent_ownership_for_thread(
        &self,
        thread_id: &str,
    ) -> Result<Option<StoredSubagentOwnership>, sqlx::Error> {
        sqlx::query(
            "SELECT conversation_id, parent_conversation_id, thread_id, parent_thread_id, agent_nickname, agent_role, agent_path, source_json, runtime_id, can_accept_direct_input, status, is_archived FROM subagent_ownership WHERE thread_id = ?",
        )
        .bind(thread_id)
        .fetch_optional(&self.pool)
        .await
        .map(|row| row.map(|row| stored_subagent_ownership(&row)))
    }

    pub async fn subagent_ownership_for_conversation(
        &self,
        conversation_id: &str,
    ) -> Result<Option<StoredSubagentOwnership>, sqlx::Error> {
        sqlx::query(
            "SELECT conversation_id, parent_conversation_id, thread_id, parent_thread_id, agent_nickname, agent_role, agent_path, source_json, runtime_id, can_accept_direct_input, status, is_archived FROM subagent_ownership WHERE conversation_id = ?",
        )
        .bind(conversation_id)
        .fetch_optional(&self.pool)
        .await
        .map(|row| row.map(|row| stored_subagent_ownership(&row)))
    }

    pub async fn list_subagent_ownership(
        &self,
        parent_conversation_id: &str,
    ) -> Result<Vec<StoredSubagentOwnership>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT conversation_id, parent_conversation_id, thread_id, parent_thread_id, agent_nickname, agent_role, agent_path, source_json, runtime_id, can_accept_direct_input, status, is_archived FROM subagent_ownership WHERE parent_conversation_id = ? ORDER BY conversation_id ASC LIMIT 100",
        )
        .bind(parent_conversation_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(stored_subagent_ownership).collect())
    }

    pub async fn conversation_settings(
        &self,
        conversation_id: &str,
    ) -> Result<Option<StoredConversationSettings>, sqlx::Error> {
        sqlx::query("SELECT conversation_id, model, reasoning_effort, service_tier, permission_profile, updated_at FROM conversation_settings WHERE conversation_id = ?")
            .bind(conversation_id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.map(|row| StoredConversationSettings {
                conversation_id: row.get("conversation_id"),
                model: row.get("model"),
                reasoning_effort: row.get("reasoning_effort"),
                service_tier: row.get("service_tier"),
                permission_profile: row.get("permission_profile"),
                updated_at: row.get("updated_at"),
            }))
    }

    pub async fn upsert_conversation_settings(
        &self,
        conversation_id: &str,
        model: Option<&str>,
        reasoning_effort: Option<&str>,
        service_tier: Option<&str>,
        permission_profile: Option<&str>,
        updated_at: &str,
    ) -> Result<StoredConversationSettings, sqlx::Error> {
        sqlx::query("INSERT INTO conversation_settings (conversation_id, model, reasoning_effort, service_tier, permission_profile, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(conversation_id) DO UPDATE SET model = excluded.model, reasoning_effort = excluded.reasoning_effort, service_tier = excluded.service_tier, permission_profile = excluded.permission_profile, updated_at = excluded.updated_at")
            .bind(conversation_id)
            .bind(model)
            .bind(reasoning_effort)
            .bind(service_tier)
            .bind(permission_profile)
            .bind(updated_at)
            .execute(&self.pool)
            .await?;
        self.conversation_settings(conversation_id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)
    }

    pub async fn list_conversation_files(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<StoredConversationFile>, sqlx::Error> {
        let rows = sqlx::query("SELECT id, conversation_id, kind, name, mime_type, byte_size, sha256, relative_path, state, additions, deletions, source_id, created_at, updated_at FROM conversation_files WHERE conversation_id = ? ORDER BY updated_at DESC")
            .bind(conversation_id)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows
            .into_iter()
            .map(|row| StoredConversationFile {
                id: row.get("id"),
                conversation_id: row.get("conversation_id"),
                kind: row.get("kind"),
                name: row.get("name"),
                mime_type: row.get("mime_type"),
                byte_size: row.get("byte_size"),
                sha256: row.get("sha256"),
                relative_path: row.get("relative_path"),
                state: row.get("state"),
                additions: row.get("additions"),
                deletions: row.get("deletions"),
                source_id: row.get("source_id"),
                created_at: row.get("created_at"),
                updated_at: row.get("updated_at"),
            })
            .collect())
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn upsert_conversation_file(
        &self,
        id: &str,
        conversation_id: &str,
        kind: &str,
        name: &str,
        mime_type: Option<&str>,
        byte_size: Option<i64>,
        sha256: Option<&str>,
        relative_path: Option<&str>,
        state: &str,
        additions: Option<i64>,
        deletions: Option<i64>,
        source_id: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO conversation_files (id, conversation_id, kind, name, mime_type, byte_size, sha256, relative_path, state, additions, deletions, source_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, mime_type = excluded.mime_type, byte_size = excluded.byte_size, sha256 = excluded.sha256, relative_path = excluded.relative_path, state = excluded.state, additions = excluded.additions, deletions = excluded.deletions, updated_at = excluded.updated_at")
            .bind(id).bind(conversation_id).bind(kind).bind(name).bind(mime_type).bind(byte_size).bind(sha256).bind(relative_path)
            .bind(state).bind(additions).bind(deletions).bind(source_id).bind(now).bind(now)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn insert_automation(
        &self,
        id: &str,
        name: &str,
        kind: &str,
        bot_id: &str,
        conversation_id: Option<&str>,
        prompt: &str,
        rrule: &str,
        timezone: &str,
        status: &str,
        notification_policy: &str,
        model_id: Option<&str>,
        reasoning_effort: Option<&str>,
        next_run_at: Option<&str>,
        now: &str,
    ) -> Result<StoredAutomation, sqlx::Error> {
        self.insert_scoped_automation(
            id,
            name,
            kind,
            "bot",
            bot_id,
            bot_id,
            conversation_id,
            prompt,
            rrule,
            timezone,
            status,
            notification_policy,
            model_id,
            reasoning_effort,
            next_run_at,
            now,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn insert_scoped_automation(
        &self,
        id: &str,
        name: &str,
        kind: &str,
        scope_type: &str,
        scope_id: &str,
        bot_id: &str,
        conversation_id: Option<&str>,
        prompt: &str,
        rrule: &str,
        timezone: &str,
        status: &str,
        notification_policy: &str,
        model_id: Option<&str>,
        reasoning_effort: Option<&str>,
        next_run_at: Option<&str>,
        now: &str,
    ) -> Result<StoredAutomation, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query("INSERT INTO automations (id, name, kind, bot_id, conversation_id, prompt, rrule, timezone, status, notification_policy, model_id, reasoning_effort, scope_type, scope_id, next_run_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING")
            .bind(id).bind(name).bind(kind).bind(bot_id).bind(conversation_id).bind(prompt)
            .bind(rrule).bind(timezone).bind(status).bind(notification_policy).bind(model_id)
            .bind(reasoning_effort).bind(scope_type).bind(scope_id).bind(next_run_at).bind(now).bind(now)
            .execute(&mut *transaction).await?;
        if let Some(conversation_id) = conversation_id {
            sqlx::query("INSERT INTO conversation_metadata (id, bot_id, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING")
                .bind(conversation_id)
                .bind(bot_id)
                .bind(name)
                .bind(now)
                .bind(now)
                .execute(&mut *transaction)
                .await?;
        }
        transaction.commit().await?;
        self.automation_by_id(id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)
    }

    pub async fn list_automations(&self) -> Result<Vec<StoredAutomation>, sqlx::Error> {
        let rows = sqlx::query("SELECT id, name, kind, bot_id, conversation_id, prompt, rrule, timezone, status, notification_policy, model_id, reasoning_effort, scope_type, scope_id, next_run_at, last_run_at, (SELECT MAX(started_at) FROM automation_runs WHERE automation_id = automations.id) AS last_attempt_at, (SELECT MAX(finished_at) FROM automation_runs WHERE automation_id = automations.id AND status = 'completed') AS last_success_at, created_at, updated_at FROM automations ORDER BY created_at ASC")
            .fetch_all(&self.pool).await?;
        Ok(rows.iter().map(stored_automation).collect())
    }

    pub async fn automation_by_id(
        &self,
        id: &str,
    ) -> Result<Option<StoredAutomation>, sqlx::Error> {
        sqlx::query("SELECT id, name, kind, bot_id, conversation_id, prompt, rrule, timezone, status, notification_policy, model_id, reasoning_effort, scope_type, scope_id, next_run_at, last_run_at, (SELECT MAX(started_at) FROM automation_runs WHERE automation_id = automations.id) AS last_attempt_at, (SELECT MAX(finished_at) FROM automation_runs WHERE automation_id = automations.id AND status = 'completed') AS last_success_at, created_at, updated_at FROM automations WHERE id = ?")
            .bind(id).fetch_optional(&self.pool).await.map(|row| row.map(|row| stored_automation(&row)))
    }

    pub async fn set_automation_status(
        &self,
        id: &str,
        status: &str,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query("UPDATE automations SET status = ?, updated_at = ? WHERE id = ?")
            .bind(status)
            .bind(now)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn delete_automation(&self, id: &str) -> Result<bool, sqlx::Error> {
        let result = sqlx::query("DELETE FROM automations WHERE id = ? AND NOT EXISTS (SELECT 1 FROM automation_runs WHERE automation_id=automations.id AND status='running')")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn list_due_automations(
        &self,
        now: &str,
    ) -> Result<Vec<StoredAutomation>, sqlx::Error> {
        let rows = sqlx::query("SELECT id, name, kind, bot_id, conversation_id, prompt, rrule, timezone, status, notification_policy, model_id, reasoning_effort, scope_type, scope_id, next_run_at, last_run_at, (SELECT MAX(started_at) FROM automation_runs WHERE automation_id = automations.id) AS last_attempt_at, (SELECT MAX(finished_at) FROM automation_runs WHERE automation_id = automations.id AND status = 'completed') AS last_success_at, created_at, updated_at FROM automations WHERE status = 'active' AND next_run_at IS NOT NULL AND next_run_at <= ? ORDER BY next_run_at ASC")
            .bind(now)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows.iter().map(stored_automation).collect())
    }

    pub async fn claim_automation_run(
        &self,
        id: &str,
        automation_id: &str,
        scheduled_for: &str,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query("INSERT OR IGNORE INTO automation_runs (id, automation_id, scheduled_for, status, started_at) SELECT ?, ?, ?, 'running', ? WHERE NOT EXISTS (SELECT 1 FROM automation_runs WHERE automation_id = ? AND status = 'running')")
            .bind(id)
            .bind(automation_id)
            .bind(scheduled_for)
            .bind(now)
            .bind(automation_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn finish_automation_run(
        &self,
        run_id: &str,
        status: &str,
        finished_at: &str,
        error: Option<&str>,
        message_id: Option<&str>,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE automation_runs SET status = ?, finished_at = ?, error = ?, message_id = COALESCE(?, message_id) WHERE id = ?")
            .bind(status)
            .bind(finished_at)
            .bind(error)
            .bind(message_id)
            .bind(run_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn set_automation_run_message_id(
        &self,
        run_id: &str,
        message_id: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE automation_runs SET message_id = ?, conversation_id = (SELECT conversation_id FROM messages WHERE id = ?) WHERE id = ?")
            .bind(message_id)
            .bind(message_id)
            .bind(run_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn automation_run_for_message(
        &self,
        message_id: &str,
    ) -> Result<Option<StoredAutomationRun>, sqlx::Error> {
        sqlx::query("SELECT id, automation_id, scheduled_for, status, started_at, finished_at, error, message_id, conversation_id FROM automation_runs WHERE message_id = ?")
            .bind(message_id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.map(|row| stored_automation_run(&row)))
    }

    pub async fn set_automation_schedule(
        &self,
        automation_id: &str,
        next_run_at: Option<&str>,
        last_run_at: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE automations SET next_run_at = ?, last_run_at = COALESCE(?, last_run_at), updated_at = ? WHERE id = ?")
            .bind(next_run_at)
            .bind(last_run_at)
            .bind(now)
            .bind(automation_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn list_automation_runs(
        &self,
        automation_id: &str,
    ) -> Result<Vec<StoredAutomationRun>, sqlx::Error> {
        let rows = sqlx::query("SELECT id, automation_id, scheduled_for, status, started_at, finished_at, error, message_id, conversation_id FROM automation_runs WHERE automation_id = ? ORDER BY started_at DESC LIMIT 50")
            .bind(automation_id)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows.iter().map(stored_automation_run).collect())
    }

    pub async fn insert_transcription(
        &self,
        id: &str,
        source_device_id: &str,
        duration_ms: u64,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "INSERT INTO transcriptions (id, state, source_device_id, duration_ms, created_at, updated_at) VALUES (?, 'queued', ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(source_device_id)
        .bind(duration_ms as i64)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn update_transcription(
        &self,
        id: &str,
        state: &str,
        transcript_text: Option<&str>,
        word_timestamps_json: Option<&str>,
        confidence: Option<f32>,
        retry_expires_at_ms: Option<u64>,
        error_category: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "UPDATE transcriptions SET state = ?, transcript_text = ?, word_timestamps_json = ?, confidence = ?, retry_expires_at_ms = ?, error_category = ?, updated_at = ? WHERE id = ?",
        )
        .bind(state)
        .bind(transcript_text)
        .bind(word_timestamps_json)
        .bind(confidence)
        .bind(retry_expires_at_ms.map(|value| value as i64))
        .bind(error_category)
        .bind(now)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn transcription_by_id(
        &self,
        id: &str,
    ) -> Result<Option<StoredTranscription>, sqlx::Error> {
        sqlx::query("SELECT id, state, source_device_id, duration_ms, transcript_text, word_timestamps_json, confidence, retry_expires_at_ms, error_category FROM transcriptions WHERE id = ?")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.map(|row| StoredTranscription {
                id: row.get("id"),
                state: row.get("state"),
                source_device_id: row.get("source_device_id"),
                duration_ms: row.get::<i64, _>("duration_ms") as u64,
                transcript_text: row.get("transcript_text"),
                word_timestamps_json: row.get("word_timestamps_json"),
                confidence: row.get("confidence"),
                retry_expires_at_ms: row.get::<Option<i64>, _>("retry_expires_at_ms").map(|value| value as u64),
                error_category: row.get("error_category"),
            }))
    }

    pub async fn transcription_by_id_for_device(
        &self,
        id: &str,
        source_device_id: &str,
    ) -> Result<Option<StoredTranscription>, sqlx::Error> {
        sqlx::query("SELECT id, state, source_device_id, duration_ms, transcript_text, word_timestamps_json, confidence, retry_expires_at_ms, error_category FROM transcriptions WHERE id = ? AND source_device_id = ?")
            .bind(id)
            .bind(source_device_id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.map(|row| StoredTranscription {
                id: row.get("id"),
                state: row.get("state"),
                source_device_id: row.get("source_device_id"),
                duration_ms: row.get::<i64, _>("duration_ms") as u64,
                transcript_text: row.get("transcript_text"),
                word_timestamps_json: row.get("word_timestamps_json"),
                confidence: row.get("confidence"),
                retry_expires_at_ms: row.get::<Option<i64>, _>("retry_expires_at_ms").map(|value| value as u64),
                error_category: row.get("error_category"),
            }))
    }

    pub async fn list_active_sessions(
        &self,
        now_ms: u64,
    ) -> Result<Vec<StoredSession>, sqlx::Error> {
        let rows = sqlx::query("SELECT s.token_hash, s.device_id, s.csrf_hash, s.expires_at_ms FROM sessions s JOIN devices d ON d.id = s.device_id WHERE s.expires_at_ms > ? AND d.revoked_at IS NULL")
            .bind(now_ms as i64)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows
            .into_iter()
            .map(|row| StoredSession {
                token_hash: row.get("token_hash"),
                device_id: row.get("device_id"),
                csrf_hash: row.get("csrf_hash"),
                expires_at_ms: row.get::<i64, _>("expires_at_ms") as u64,
            })
            .collect())
    }

    pub async fn insert_message(
        &self,
        device_id: &str,
        client_message_id: &str,
        body: &str,
        body_sha256: &str,
        conversation_id: &str,
        now: &str,
    ) -> Result<MessageInsert, sqlx::Error> {
        self.insert_message_with_attachments(
            device_id,
            client_message_id,
            body,
            body_sha256,
            conversation_id,
            &[],
            now,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn insert_message_with_attachments(
        &self,
        device_id: &str,
        client_message_id: &str,
        body: &str,
        body_sha256: &str,
        conversation_id: &str,
        attachment_ids: &[String],
        now: &str,
    ) -> Result<MessageInsert, sqlx::Error> {
        self.insert_dispatch_message(
            device_id,
            client_message_id,
            body,
            body_sha256,
            conversation_id,
            attachment_ids,
            now,
            false,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn insert_dispatch_message(
        &self,
        device_id: &str,
        client_message_id: &str,
        body: &str,
        body_sha256: &str,
        conversation_id: &str,
        attachment_ids: &[String],
        now: &str,
        durable_dispatch: bool,
    ) -> Result<MessageInsert, sqlx::Error> {
        self.insert_work_message(
            device_id,
            client_message_id,
            body,
            body_sha256,
            conversation_id,
            attachment_ids,
            now,
            durable_dispatch,
            None,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn insert_guide_message(
        &self,
        device_id: &str,
        client_message_id: &str,
        body: &str,
        body_sha256: &str,
        conversation_id: &str,
        attachment_ids: &[String],
        now: &str,
        turn: &str,
    ) -> Result<MessageInsert, sqlx::Error> {
        self.insert_work_message(
            device_id,
            client_message_id,
            body,
            body_sha256,
            conversation_id,
            attachment_ids,
            now,
            false,
            Some(turn),
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn insert_work_message(
        &self,
        device_id: &str,
        client_message_id: &str,
        body: &str,
        body_sha256: &str,
        conversation_id: &str,
        attachment_ids: &[String],
        now: &str,
        durable_dispatch: bool,
        guide_turn: Option<&str>,
    ) -> Result<MessageInsert, sqlx::Error> {
        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if let Some(row) = sqlx::query(
            "SELECT id, device_id, client_message_id, body, body_sha256, conversation_id, state, created_at, codex_thread_id, codex_turn_id FROM messages WHERE device_id = ? AND client_message_id = ?",
        )
        .bind(device_id)
        .bind(client_message_id)
        .fetch_optional(&mut *transaction)
        .await?
        {
            let existing = stored_message(&row);
            let queued: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM dispatch_work WHERE message_id = ?")
                .bind(&existing.id).fetch_one(&mut *transaction).await?;
            let saved_guide: Option<String> = sqlx::query_scalar("SELECT expected_turn_id FROM guide_work WHERE message_id=?").bind(&existing.id).fetch_optional(&mut *transaction).await?;
            if saved_guide.as_deref() != guide_turn { return Ok(MessageInsert::Conflict); }
            if durable_dispatch != (queued != 0) {
                return Ok(MessageInsert::Conflict);
            }

            if existing.conversation_id != conversation_id || existing.body_sha256 != body_sha256 {
                transaction.commit().await?;
                return Ok(MessageInsert::Conflict);
            }
            let existing_attachments = sqlx::query(
                "SELECT file_id FROM message_attachments WHERE message_id = ? ORDER BY file_id ASC",
            )
            .bind(&existing.id)
            .fetch_all(&mut *transaction)
            .await?
            .into_iter()
            .map(|row| row.get::<String, _>("file_id"))
            .collect::<Vec<_>>();
            let mut requested_attachments = attachment_ids.to_vec();
            requested_attachments.sort();
            if existing_attachments != requested_attachments {
                transaction.commit().await?;
                return Ok(MessageInsert::Conflict);
            }
            transaction.commit().await?;
            return Ok(MessageInsert::Existing(existing));
        }

        let mut requested_attachments = attachment_ids.to_vec();
        requested_attachments.sort();
        requested_attachments.dedup();
        if !requested_attachments.is_empty() {
            let mut query = sqlx::QueryBuilder::<sqlx::Sqlite>::new(
                "SELECT COUNT(*) AS count FROM conversation_files WHERE conversation_id = ",
            );
            query.push_bind(conversation_id);
            query.push(" AND kind = 'attachment' AND state = 'available' AND id IN (");
            let mut separated = query.separated(", ");
            for file_id in &requested_attachments {
                separated.push_bind(file_id);
            }
            separated.push_unseparated(")");
            let count = query
                .build()
                .fetch_one(&mut *transaction)
                .await?
                .get::<i64, _>("count") as usize;
            if count != requested_attachments.len() {
                transaction.commit().await?;
                return Ok(MessageInsert::Conflict);
            }
        }

        let id = uuid::Uuid::new_v4().to_string();
        let queue_position = if durable_dispatch {
            Some(
                sqlx::query_scalar::<_, i64>(
                    "SELECT COALESCE(MAX(m.queue_position), -1) + 1 FROM messages m JOIN dispatch_work w ON w.message_id=m.id WHERE m.conversation_id=? AND m.state='accepted_by_wonder'",
                )
                .bind(conversation_id)
                .fetch_one(&mut *transaction)
                .await?,
            )
        } else {
            None
        };
        if let Some(queue_position) = queue_position {
            sqlx::query(
                "INSERT INTO messages (id, device_id, client_message_id, body, body_sha256, conversation_id, state, created_at, queue_position) VALUES (?, ?, ?, ?, ?, ?, 'accepted_by_wonder', ?, ?)",
            )
            .bind(&id)
            .bind(device_id)
            .bind(client_message_id)
            .bind(body)
            .bind(body_sha256)
            .bind(conversation_id)
            .bind(now)
            .bind(queue_position)
            .execute(&mut *transaction)
            .await?;
        } else {
            sqlx::query(
                "INSERT INTO messages (id, device_id, client_message_id, body, body_sha256, conversation_id, state, created_at) VALUES (?, ?, ?, ?, ?, ?, 'accepted_by_wonder', ?)",
            )
            .bind(&id)
            .bind(device_id)
            .bind(client_message_id)
            .bind(body)
            .bind(body_sha256)
            .bind(conversation_id)
            .bind(now)
            .execute(&mut *transaction)
            .await?;
        }
        for file_id in requested_attachments {
            sqlx::query(
                "INSERT INTO message_attachments (message_id, file_id, created_at) VALUES (?, ?, ?)",
            )
            .bind(&id)
            .bind(file_id)
            .bind(now)
            .execute(&mut *transaction)
            .await?;
        }
        if durable_dispatch {
            // Freeze the owner's selected settings when accepting a direct message.
            // Later composer edits must not rewrite previously queued work.
            sqlx::query("INSERT INTO message_execution_settings(message_id,model,reasoning_effort,service_tier,permission_mode,approval_mode,permission_profile,working_directory) SELECT ?,COALESCE(s.model,b.model),COALESCE(s.reasoning_effort,b.reasoning_effort),COALESCE(s.service_tier,b.service_tier),b.permission_mode,b.approval_mode,COALESCE(s.permission_profile,b.permission_profile),COALESCE(b.working_directory,b.workspace_path) FROM conversation_metadata m JOIN bots b ON b.id=m.bot_id LEFT JOIN conversation_settings s ON s.conversation_id=m.id WHERE m.id=? AND NOT EXISTS(SELECT 1 FROM channels WHERE conversation_id=m.id) AND NOT EXISTS(SELECT 1 FROM subagent_ownership WHERE conversation_id=m.id)")
                .bind(&id).bind(conversation_id).execute(&mut *transaction).await?;
        }
        if durable_dispatch {
            sqlx::query("INSERT INTO dispatch_work (message_id) VALUES (?)")
                .bind(&id)
                .execute(&mut *transaction)
                .await?;
        }
        if let Some(turn) = guide_turn {
            sqlx::query("INSERT INTO guide_work(message_id,expected_turn_id) VALUES (?,?)")
                .bind(&id)
                .bind(turn)
                .execute(&mut *transaction)
                .await?;
        }
        transaction.commit().await?;
        Ok(MessageInsert::Inserted(StoredMessage {
            id,
            device_id: device_id.into(),
            client_message_id: client_message_id.into(),
            body: body.into(),
            body_sha256: body_sha256.into(),
            conversation_id: conversation_id.into(),
            state: "accepted_by_wonder".into(),
            created_at: now.into(),
            codex_thread_id: None,
            codex_turn_id: None,
        }))
    }

    pub async fn attachment_ids_for_message(
        &self,
        message_id: &str,
    ) -> Result<Vec<String>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT file_id FROM message_attachments WHERE message_id = ? ORDER BY file_id ASC",
        )
        .bind(message_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| row.get::<String, _>("file_id"))
            .collect())
    }

    pub async fn attachments_for_message(
        &self,
        message_id: &str,
    ) -> Result<Vec<StoredConversationFile>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT files.id, files.conversation_id, files.kind, files.name, files.mime_type, files.byte_size, files.sha256, files.relative_path, files.state, files.additions, files.deletions, files.source_id, files.created_at, files.updated_at
             FROM conversation_files AS files
             JOIN message_attachments ON message_attachments.file_id = files.id
             WHERE message_attachments.message_id = ?
             ORDER BY message_attachments.file_id ASC",
        )
        .bind(message_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| StoredConversationFile {
                id: row.get("id"),
                conversation_id: row.get("conversation_id"),
                kind: row.get("kind"),
                name: row.get("name"),
                mime_type: row.get("mime_type"),
                byte_size: row.get("byte_size"),
                sha256: row.get("sha256"),
                relative_path: row.get("relative_path"),
                state: row.get("state"),
                additions: row.get("additions"),
                deletions: row.get("deletions"),
                source_id: row.get("source_id"),
                created_at: row.get("created_at"),
                updated_at: row.get("updated_at"),
            })
            .collect())
    }

    pub async fn complete_message_if_active(&self, message_id: &str) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE messages SET state = 'completed' WHERE id = ? AND state IN ('accepted_by_codex', 'streaming', 'uncertain')",
        )
        .bind(message_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn complete_messages_for_codex_turn(
        &self,
        codex_turn_id: &str,
    ) -> Result<u64, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE messages SET state = 'completed' WHERE codex_turn_id = ? AND state IN ('accepted_by_codex', 'streaming', 'uncertain')",
        )
        .bind(codex_turn_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }

    pub async fn interrupt_message_if_active(&self, message_id: &str) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE messages SET state = 'interrupted' WHERE id = ? AND state IN ('accepted_by_codex', 'streaming')",
        )
        .bind(message_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn update_message_delivery(
        &self,
        message_id: &str,
        state: &str,
        codex_thread_id: Option<&str>,
        codex_turn_id: Option<&str>,
    ) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "UPDATE messages SET state = ?, codex_thread_id = COALESCE(?, codex_thread_id), codex_turn_id = COALESCE(?, codex_turn_id) WHERE id = ?",
        )
        .bind(state)
        .bind(codex_thread_id)
        .bind(codex_turn_id)
        .bind(message_id)
        .execute(&mut *tx)
        .await?;
        sqlx::query("UPDATE dispatch_attempts SET phase = ?, thread_id = COALESCE(?, thread_id), turn_id = COALESCE(?, turn_id) WHERE id = (SELECT MAX(id) FROM dispatch_attempts WHERE message_id = ?)")
            .bind(state).bind(codex_thread_id).bind(codex_turn_id).bind(message_id)
            .execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn enqueue_notification(
        &self,
        notification: &serde_json::Value,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO notification_inbox (notification_json) VALUES (?)")
            .bind(notification.to_string())
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn notification_backlog(&self) -> Result<i64, sqlx::Error> {
        sqlx::query_scalar("SELECT COUNT(*) FROM (SELECT id FROM notification_inbox LIMIT 257)")
            .fetch_one(&self.pool)
            .await
    }

    pub async fn next_notification(&self) -> Result<Option<(i64, serde_json::Value)>, sqlx::Error> {
        let row =
            sqlx::query("SELECT id, notification_json FROM notification_inbox ORDER BY id LIMIT 1")
                .fetch_optional(&self.pool)
                .await?;
        row.map(|row| {
            let value = serde_json::from_str(row.get::<&str, _>("notification_json"))
                .map_err(|error| sqlx::Error::Protocol(error.to_string()))?;
            Ok((row.get("id"), value))
        })
        .transpose()
    }

    pub async fn notification_was_started(&self, id: i64) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar("SELECT started != 0 FROM notification_inbox WHERE id = ?")
            .bind(id)
            .fetch_one(&self.pool)
            .await
    }

    pub async fn start_notification(&self, id: i64) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE notification_inbox SET started = 1 WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn acknowledge_notification(&self, id: i64) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM notification_inbox WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn mark_runtime_turn_uncertain(
        &self,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<(), sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query("UPDATE messages SET state = 'uncertain' WHERE codex_thread_id = ? AND codex_turn_id = ? AND state IN ('accepted_by_codex', 'streaming', 'uncertain')")
            .bind(thread_id).bind(turn_id).execute(&mut *transaction).await?;
        sqlx::query("UPDATE assistant_messages SET state = 'failed' WHERE codex_thread_id = ? AND codex_turn_id = ? AND state IN ('accepted_by_codex', 'streaming')")
            .bind(thread_id).bind(turn_id).execute(&mut *transaction).await?;
        transaction.commit().await?;
        Ok(())
    }

    pub async fn active_runtime_messages(&self) -> Result<Vec<StoredMessage>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM messages WHERE codex_turn_id IS NOT NULL AND state IN ('accepted_by_codex', 'streaming', 'uncertain')")
            .fetch_all(&self.pool).await?;
        Ok(rows.iter().map(stored_message).collect())
    }

    pub async fn has_active_app_server_turns(&self) -> Result<bool, sqlx::Error> {
        let row = sqlx::query(
            "SELECT EXISTS(SELECT 1 FROM messages WHERE codex_turn_id IS NOT NULL AND state IN ('accepted_by_codex', 'streaming')) AS active",
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(row.get::<i64, _>("active") != 0)
    }

    /// A daemon restart terminates the App Server child, so persisted turns
    /// that were active before startup can no longer receive terminal events.
    /// Keep their user messages uncertain and stop presenting their partial
    /// assistant projections as live work.
    pub async fn recover_orphaned_app_server_turns(&self) -> Result<u64, sqlx::Error> {
        let updated_at = time::OffsetDateTime::now_utc()
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_else(|_| "now".to_owned());
        let mut transaction = self.pool.begin().await?;
        let result = sqlx::query(
            "UPDATE messages SET state = 'uncertain' WHERE codex_turn_id IS NOT NULL AND state IN ('accepted_by_codex', 'streaming')",
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            "UPDATE assistant_messages SET state = 'failed', updated_at = ? WHERE state IN ('accepted_by_codex', 'streaming') AND codex_turn_id IN (SELECT codex_turn_id FROM messages WHERE state = 'uncertain')",
        )
        .bind(updated_at)
        .execute(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(result.rows_affected())
    }

    pub async fn message_for_codex_turn(
        &self,
        codex_turn_id: &str,
    ) -> Result<Option<StoredMessage>, sqlx::Error> {
        sqlx::query(
            // A steer can legitimately reuse the active Codex turn id. The
            // newest Wonder message owns subsequent turn/item events while
            // the original row retains its own lifecycle state.
            "SELECT id, device_id, client_message_id, body, body_sha256, conversation_id, state, created_at, codex_thread_id, codex_turn_id FROM messages WHERE codex_turn_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        )
        .bind(codex_turn_id)
        .fetch_optional(&self.pool)
        .await
            .map(|row| row.map(|row| stored_message(&row)))
    }

    pub async fn message_for_codex_thread_and_turn(
        &self,
        codex_thread_id: &str,
        codex_turn_id: &str,
    ) -> Result<Option<StoredMessage>, sqlx::Error> {
        sqlx::query(
            "SELECT id, device_id, client_message_id, body, body_sha256, conversation_id, state, created_at, codex_thread_id, codex_turn_id FROM messages WHERE codex_thread_id = ? AND codex_turn_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        )
        .bind(codex_thread_id)
        .bind(codex_turn_id)
        .fetch_optional(&self.pool)
        .await
        .map(|row| row.map(|row| stored_message(&row)))
    }

    pub async fn complete_messages_for_codex_thread_and_turn(
        &self,
        codex_thread_id: &str,
        codex_turn_id: &str,
    ) -> Result<u64, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE messages SET state = 'completed' WHERE codex_thread_id = ? AND codex_turn_id = ? AND state IN ('accepted_by_codex', 'streaming', 'uncertain')",
        )
        .bind(codex_thread_id)
        .bind(codex_turn_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }

    pub async fn message_by_device_and_client_message_id(
        &self,
        device_id: &str,
        client_message_id: &str,
    ) -> Result<Option<StoredMessage>, sqlx::Error> {
        sqlx::query(
            "SELECT id, device_id, client_message_id, body, body_sha256, conversation_id, state, created_at, codex_thread_id, codex_turn_id FROM messages WHERE device_id = ? AND client_message_id = ?",
        )
        .bind(device_id)
        .bind(client_message_id)
        .fetch_optional(&self.pool)
        .await
        .map(|row| row.map(|row| stored_message(&row)))
    }

    pub async fn message_by_id(
        &self,
        message_id: &str,
    ) -> Result<Option<StoredMessage>, sqlx::Error> {
        sqlx::query(
            "SELECT id, device_id, client_message_id, body, body_sha256, conversation_id, state, created_at, codex_thread_id, codex_turn_id FROM messages WHERE id = ?",
        )
        .bind(message_id)
        .fetch_optional(&self.pool)
        .await
            .map(|row| row.map(|row| stored_message(&row)))
    }

    pub async fn messages_for_conversation(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<StoredMessage>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT id, device_id, client_message_id, body, body_sha256, conversation_id, state, created_at, codex_thread_id, codex_turn_id FROM messages WHERE conversation_id = ?",
        )
        .bind(conversation_id)
        .fetch_all(&self.pool)
        .await?;
        let mut messages = rows
            .into_iter()
            .map(|row| stored_message(&row))
            .collect::<Vec<_>>();
        messages.sort_by(|left, right| {
            compare_timestamps(&left.created_at, &right.created_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(messages)
    }

    /// Upsert a streamed chunk idempotently using the durable notification key.
    /// The key is per notification, not per text, so two live chunks with the
    /// same text remain distinct while a replay is ignored.
    #[allow(clippy::too_many_arguments)]
    pub async fn upsert_assistant_delta(
        &self,
        conversation_id: &str,
        codex_thread_id: &str,
        codex_turn_id: &str,
        item_id: &str,
        delta: &str,
        notification_key: &str,
        now: &str,
    ) -> Result<StoredAssistantMessage, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        let id = format!("assistant:{codex_turn_id}:{item_id}");
        sqlx::query(
            "INSERT INTO assistant_messages (id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, '', 'streaming', ?, ?) ON CONFLICT(conversation_id, codex_turn_id, item_id) DO NOTHING",
        )
        .bind(&id)
        .bind(conversation_id)
        .bind(codex_thread_id)
        .bind(codex_turn_id)
        .bind(item_id)
        .bind(now)
        .bind(now)
        .execute(&mut *transaction)
        .await?;
        let row = sqlx::query(
            "SELECT id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at FROM assistant_messages WHERE conversation_id = ? AND codex_turn_id = ? AND item_id = ?",
        )
        .bind(conversation_id)
        .bind(codex_turn_id)
        .bind(item_id)
        .fetch_one(&mut *transaction)
        .await?;
        let existing = stored_assistant_message(&row);
        if existing.state != "completed" && !delta.is_empty() {
            let inserted = sqlx::query("INSERT INTO assistant_message_deltas (assistant_message_id, delta_sha256) VALUES (?, ?) ON CONFLICT(assistant_message_id, delta_sha256) DO NOTHING")
                .bind(&existing.id)
                .bind(notification_key)
                .execute(&mut *transaction)
                .await?;
            if inserted.rows_affected() == 1 {
                sqlx::query(
                    "UPDATE assistant_messages SET text = text || ?, updated_at = ? WHERE id = ? AND state != 'completed'",
                )
                .bind(delta)
                .bind(now)
                .bind(&existing.id)
                .execute(&mut *transaction)
                .await?;
            }
        }
        let row = sqlx::query(
            "SELECT id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at FROM assistant_messages WHERE id = ?",
        )
        .bind(&existing.id)
        .fetch_one(&mut *transaction)
        .await?;
        let result = stored_assistant_message(&row);
        transaction.commit().await?;
        Ok(result)
    }

    pub async fn claim_app_server_notification(
        &self,
        notification_key: &str,
        received_at: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "INSERT INTO app_server_notification_receipts (notification_key, received_at) VALUES (?, ?) ON CONFLICT(notification_key) DO NOTHING",
        )
        .bind(notification_key)
        .bind(received_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn enqueue_pending_app_server_notification(
        &self,
        id: &str,
        identity_key: Option<&str>,
        method: &str,
        thread_id: Option<&str>,
        turn_id: Option<&str>,
        item_id: Option<&str>,
        notification_json: &str,
        params_json: &str,
        received_at: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "INSERT INTO pending_app_server_notifications (id, identity_key, method, thread_id, turn_id, item_id, notification_json, params_json, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING",
        )
        .bind(id)
        .bind(identity_key)
        .bind(method)
        .bind(thread_id)
        .bind(turn_id)
        .bind(item_id)
        .bind(notification_json)
        .bind(params_json)
        .bind(received_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn pending_app_server_notifications_for_turn(
        &self,
        turn_id: &str,
    ) -> Result<Vec<StoredPendingAppServerNotification>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT id, identity_key, method, thread_id, turn_id, item_id, notification_json, params_json, received_at FROM pending_app_server_notifications WHERE turn_id = ? ORDER BY received_at ASC, rowid ASC",
        )
        .bind(turn_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| StoredPendingAppServerNotification {
                id: row.get("id"),
                identity_key: row.get("identity_key"),
                method: row.get("method"),
                thread_id: row.get("thread_id"),
                turn_id: row.get("turn_id"),
                item_id: row.get("item_id"),
                notification_json: row.get("notification_json"),
                params_json: row.get("params_json"),
                received_at: row.get("received_at"),
            })
            .collect())
    }

    pub async fn pending_app_server_notifications_for_thread_and_turn(
        &self,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<Vec<StoredPendingAppServerNotification>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT id, identity_key, method, thread_id, turn_id, item_id, notification_json, params_json, received_at FROM pending_app_server_notifications WHERE thread_id = ? AND turn_id = ? ORDER BY received_at ASC, rowid ASC",
        )
        .bind(thread_id)
        .bind(turn_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| StoredPendingAppServerNotification {
                id: row.get("id"),
                identity_key: row.get("identity_key"),
                method: row.get("method"),
                thread_id: row.get("thread_id"),
                turn_id: row.get("turn_id"),
                item_id: row.get("item_id"),
                notification_json: row.get("notification_json"),
                params_json: row.get("params_json"),
                received_at: row.get("received_at"),
            })
            .collect())
    }

    pub async fn delete_pending_app_server_notification(
        &self,
        id: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM pending_app_server_notifications WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn release_app_server_notification(
        &self,
        notification_key: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM app_server_notification_receipts WHERE notification_key = ?")
            .bind(notification_key)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Append a live streamed chunk verbatim. Repeated adjacent chunks are
    /// valid output, so this path intentionally does not deduplicate.
    pub async fn append_assistant_delta(
        &self,
        conversation_id: &str,
        codex_thread_id: &str,
        codex_turn_id: &str,
        item_id: &str,
        delta: &str,
        now: &str,
    ) -> Result<StoredAssistantMessage, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        let id = format!("assistant:{codex_turn_id}:{item_id}");
        sqlx::query(
            "INSERT INTO assistant_messages (id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, '', 'streaming', ?, ?) ON CONFLICT(conversation_id, codex_turn_id, item_id) DO NOTHING",
        )
        .bind(&id)
        .bind(conversation_id)
        .bind(codex_thread_id)
        .bind(codex_turn_id)
        .bind(item_id)
        .bind(now)
        .bind(now)
        .execute(&mut *transaction)
        .await?;
        let row = sqlx::query(
            "SELECT id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at FROM assistant_messages WHERE conversation_id = ? AND codex_turn_id = ? AND item_id = ?",
        )
        .bind(conversation_id)
        .bind(codex_turn_id)
        .bind(item_id)
        .fetch_one(&mut *transaction)
        .await?;
        let existing = stored_assistant_message(&row);
        if existing.state != "completed" && !delta.is_empty() {
            sqlx::query(
                "UPDATE assistant_messages SET text = text || ?, updated_at = ? WHERE id = ? AND state != 'completed'",
            )
            .bind(delta)
            .bind(now)
            .bind(&existing.id)
            .execute(&mut *transaction)
            .await?;
        }
        let row = sqlx::query(
            "SELECT id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at FROM assistant_messages WHERE id = ?",
        )
        .bind(&existing.id)
        .fetch_one(&mut *transaction)
        .await?;
        let result = stored_assistant_message(&row);
        transaction.commit().await?;
        Ok(result)
    }

    pub async fn complete_assistant_message(
        &self,
        conversation_id: &str,
        codex_thread_id: &str,
        codex_turn_id: &str,
        item_id: &str,
        text: &str,
        now: &str,
    ) -> Result<Option<StoredAssistantMessage>, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        let id = format!("assistant:{codex_turn_id}:{item_id}");
        let existing = sqlx::query(
            "SELECT id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at FROM assistant_messages WHERE conversation_id = ? AND codex_turn_id = ? AND item_id = ?",
        )
        .bind(conversation_id)
        .bind(codex_turn_id)
        .bind(item_id)
        .fetch_optional(&mut *transaction)
        .await?;
        let Some(existing) = existing else {
            sqlx::query(
                "INSERT INTO assistant_messages (id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, 'completed', ?, ?)",
            )
            .bind(&id)
            .bind(conversation_id)
            .bind(codex_thread_id)
            .bind(codex_turn_id)
            .bind(item_id)
            .bind(text)
            .bind(now)
            .bind(now)
            .execute(&mut *transaction)
            .await?;
            let row = sqlx::query(
                "SELECT id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at FROM assistant_messages WHERE id = ?",
            )
            .bind(&id)
            .fetch_one(&mut *transaction)
            .await?;
            let completed = stored_assistant_message(&row);
            transaction.commit().await?;
            return Ok(Some(completed));
        };
        let existing = stored_assistant_message(&existing);
        if !matches!(existing.state.as_str(), "accepted_by_codex" | "streaming") {
            transaction.commit().await?;
            return Ok(None);
        }
        sqlx::query(
            "UPDATE assistant_messages SET text = CASE WHEN ? != '' THEN ? ELSE text END, state = 'completed', updated_at = ? WHERE id = ? AND state IN ('accepted_by_codex', 'streaming')",
        )
        .bind(text)
        .bind(text)
        .bind(now)
        .bind(&existing.id)
        .execute(&mut *transaction)
        .await?;
        let row = sqlx::query(
            "SELECT id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at FROM assistant_messages WHERE id = ?",
        )
        .bind(&existing.id)
        .fetch_one(&mut *transaction)
        .await?;
        let completed = stored_assistant_message(&row);
        transaction.commit().await?;
        Ok(Some(completed))
    }

    pub async fn complete_assistant_messages_for_codex_thread_and_turn(
        &self,
        codex_thread_id: &str,
        codex_turn_id: &str,
        now: &str,
    ) -> Result<Vec<StoredAssistantMessage>, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        let rows = sqlx::query(
            "SELECT id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at FROM assistant_messages WHERE codex_thread_id = ? AND codex_turn_id = ? AND state IN ('accepted_by_codex', 'streaming') ORDER BY created_at ASC, id ASC",
        )
        .bind(codex_thread_id)
        .bind(codex_turn_id)
        .fetch_all(&mut *transaction)
        .await?;
        sqlx::query(
            "UPDATE assistant_messages SET state = 'completed', updated_at = ? WHERE codex_thread_id = ? AND codex_turn_id = ? AND state IN ('accepted_by_codex', 'streaming')",
        )
        .bind(now)
        .bind(codex_thread_id)
        .bind(codex_turn_id)
        .execute(&mut *transaction)
        .await?;
        let completed = rows
            .into_iter()
            .map(|row| {
                let mut message = stored_assistant_message(&row);
                message.state = "completed".into();
                message.updated_at = now.into();
                message
            })
            .collect();
        transaction.commit().await?;
        Ok(completed)
    }

    pub async fn complete_assistant_messages_for_codex_turn(
        &self,
        codex_turn_id: &str,
        now: &str,
    ) -> Result<Vec<StoredAssistantMessage>, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        let rows = sqlx::query(
            "SELECT id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at FROM assistant_messages WHERE codex_turn_id = ? AND state IN ('accepted_by_codex', 'streaming') ORDER BY created_at ASC, id ASC",
        )
        .bind(codex_turn_id)
        .fetch_all(&mut *transaction)
        .await?;
        sqlx::query(
            "UPDATE assistant_messages SET state = 'completed', updated_at = ? WHERE codex_turn_id = ? AND state IN ('accepted_by_codex', 'streaming')",
        )
        .bind(now)
        .bind(codex_turn_id)
        .execute(&mut *transaction)
        .await?;
        let completed = rows
            .into_iter()
            .map(|row| {
                let mut message = stored_assistant_message(&row);
                message.state = "completed".into();
                message.updated_at = now.into();
                message
            })
            .collect();
        transaction.commit().await?;
        Ok(completed)
    }

    pub async fn assistant_messages_for_conversation(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<StoredAssistantMessage>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at FROM assistant_messages WHERE conversation_id = ? ORDER BY created_at ASC, id ASC",
        )
        .bind(conversation_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(stored_assistant_message).collect())
    }

    pub async fn list_conversation_summaries(
        &self,
    ) -> Result<Vec<StoredConversationSummary>, sqlx::Error> {
        let rows = sqlx::query(
            "WITH conversation_sources AS (
                 SELECT COALESCE(bot_workspaces.conversation_id, bots.id) AS conversation_id, bots.created_at AS sort_at FROM bots LEFT JOIN bot_workspaces ON bot_workspaces.bot_id = bots.id
                 UNION ALL
                 SELECT id AS conversation_id, created_at AS sort_at FROM conversations
                 UNION ALL
                 SELECT id AS conversation_id, created_at AS sort_at FROM conversation_metadata
                 UNION ALL
                 SELECT conversation_id, MIN(created_at) AS sort_at
                 FROM messages
                 GROUP BY conversation_id
             ), conversation_ids AS (
                 SELECT conversation_id, MIN(sort_at) AS sort_at
                 FROM conversation_sources
                 GROUP BY conversation_id
             ), message_counts AS (
                 SELECT conversation_id, COUNT(*) AS message_count
                 FROM messages
                 WHERE NOT EXISTS (SELECT 1 FROM bot_initializations WHERE message_id=messages.id)
                   AND NOT EXISTS (SELECT 1 FROM bot_workspace_followups WHERE message_id=messages.id)
                 GROUP BY conversation_id
             )
             SELECT conversation_ids.conversation_id,
                    COALESCE(metadata.bot_id, bots.id) AS bot_id,
                    COALESCE(metadata.title, bots.name, conversation_ids.conversation_id) AS title,
                    last_message.body AS last_message_body,
                    last_message.created_at AS last_message_at,
                    COALESCE(message_counts.message_count, 0) AS message_count,
                    last_message.state AS delivery_state,
                    COALESCE(metadata.is_archived, 0) AS is_archived,
                    COALESCE(metadata.is_pinned, 0) AS is_pinned,
                    COALESCE(metadata.has_unread, 0) AS has_unread
             FROM conversation_ids
             LEFT JOIN conversation_metadata AS metadata ON metadata.id = conversation_ids.conversation_id
             LEFT JOIN bots ON bots.id = COALESCE(metadata.bot_id, conversation_ids.conversation_id)
             LEFT JOIN message_counts ON message_counts.conversation_id = conversation_ids.conversation_id
             LEFT JOIN messages AS last_message
                 ON last_message.id = (
                     SELECT message.id
                     FROM messages AS message
                     WHERE message.conversation_id = conversation_ids.conversation_id
                       AND NOT EXISTS (SELECT 1 FROM bot_initializations WHERE message_id=message.id)
                       AND NOT EXISTS (SELECT 1 FROM bot_workspace_followups WHERE message_id=message.id)
                     ORDER BY message.created_at DESC, message.rowid DESC
                     LIMIT 1
                 )
             WHERE NOT EXISTS (
                 SELECT 1 FROM group_nodes node JOIN messages child
                 ON child.device_id=node.device_id AND child.client_message_id=node.client_message_id
                 WHERE node.phase='worker' AND child.conversation_id=conversation_ids.conversation_id
             )
             AND NOT EXISTS (
                 SELECT 1 FROM subagent_ownership child
                 WHERE child.conversation_id=conversation_ids.conversation_id
             )
             ORDER BY conversation_ids.conversation_id ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        let assistant_rows = sqlx::query(
            "SELECT conversation_id, text, updated_at, rowid FROM assistant_messages WHERE text != '' AND NOT EXISTS (SELECT 1 FROM bot_initializations i JOIN messages m ON m.id=i.message_id WHERE m.codex_turn_id=assistant_messages.codex_turn_id AND m.conversation_id=assistant_messages.conversation_id)",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut latest_assistant = HashMap::<String, AssistantPreview>::new();
        for row in assistant_rows {
            let conversation_id: String = row.get("conversation_id");
            let candidate = AssistantPreview {
                text: row.get("text"),
                occurred_at: row.get("updated_at"),
                sequence: row.get::<i64, _>("rowid") as u64,
            };
            let replace = latest_assistant
                .get(&conversation_id)
                .is_none_or(|current| assistant_preview_is_newer(&candidate, current));
            if replace {
                latest_assistant.insert(conversation_id, candidate);
            }
        }
        let event_rows = sqlx::query("SELECT payload_json FROM events")
            .fetch_all(&self.pool)
            .await?;
        for row in event_rows {
            let payload: String = row.get("payload_json");
            let Ok(event) = serde_json::from_str::<HostEventEnvelope>(&payload) else {
                continue;
            };
            let Some(conversation_id) = event.conversation_id else {
                continue;
            };
            let WonderEvent::AssistantCompleted { text } = event.event else {
                continue;
            };
            if text.trim().is_empty() {
                continue;
            }
            let candidate = AssistantPreview {
                text,
                occurred_at: event.occurred_at,
                sequence: event.sequence,
            };
            let replace = latest_assistant
                .get(&conversation_id)
                .is_none_or(|current| assistant_preview_is_newer(&candidate, current));
            if replace {
                latest_assistant.insert(conversation_id, candidate);
            }
        }

        let mut summaries = rows
            .into_iter()
            .map(|row| {
                let conversation_id: String = row.get("conversation_id");
                let user_preview = row
                    .get::<Option<String>, _>("last_message_body")
                    .map(|body| body.chars().take(240).collect());
                let user_at = row.get::<Option<String>, _>("last_message_at");
                let (last_message_preview, last_message_at) =
                    match (latest_assistant.get(&conversation_id), user_at.as_deref()) {
                        (Some(assistant), Some(user_at))
                            if timestamp_is_at_or_after(&assistant.occurred_at, user_at) =>
                        {
                            (
                                Some(assistant.text.chars().take(240).collect()),
                                Some(assistant.occurred_at.clone()),
                            )
                        }
                        (Some(assistant), None) => (
                            Some(assistant.text.chars().take(240).collect()),
                            Some(assistant.occurred_at.clone()),
                        ),
                        _ => (user_preview, user_at),
                    };
                StoredConversationSummary {
                    conversation_id,
                    bot_id: row.get("bot_id"),
                    title: row.get("title"),
                    last_message_preview,
                    last_message_at,
                    message_count: row.get::<i64, _>("message_count") as u64,
                    delivery_state: row.get("delivery_state"),
                    is_archived: row.get::<i64, _>("is_archived") != 0,
                    is_pinned: row.get::<i64, _>("is_pinned") != 0,
                    has_unread: row.get::<i64, _>("has_unread") != 0,
                }
            })
            .collect::<Vec<_>>();
        summaries.sort_by(|left, right| {
            right
                .is_pinned
                .cmp(&left.is_pinned)
                .then_with(|| {
                    compare_timestamps_desc(
                        left.last_message_at.as_deref(),
                        right.last_message_at.as_deref(),
                    )
                })
                .then_with(|| left.conversation_id.cmp(&right.conversation_id))
        });
        Ok(summaries)
    }

    pub async fn claim_message_for_dispatch(&self, message_id: &str) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let result = sqlx::query("UPDATE messages SET state = 'dispatching_to_codex' WHERE id = ? AND state = 'accepted_by_wonder' AND (id NOT IN (SELECT message_id FROM dispatch_work) OR (NOT EXISTS (SELECT 1 FROM messages active WHERE active.conversation_id=messages.conversation_id AND active.id<>messages.id AND active.state IN ('dispatching_to_codex','accepted_by_codex','streaming')) AND id=(SELECT pending.id FROM messages pending JOIN dispatch_work w ON w.message_id=pending.id WHERE pending.conversation_id=messages.conversation_id AND pending.state='accepted_by_wonder' ORDER BY pending.queue_position,pending.created_at,pending.id LIMIT 1)))")
            .bind(message_id).execute(&mut *tx).await?;
        if result.rows_affected() == 1 {
            sqlx::query("INSERT INTO dispatch_attempts (message_id, phase) VALUES (?, 'claimed')")
                .bind(message_id)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        Ok(result.rows_affected() == 1)
    }

    /// Commit before any turn/start bytes can reach the runtime.
    pub async fn begin_dispatch_submission(
        &self,
        message_id: &str,
        thread_id: &str,
    ) -> Result<(), sqlx::Error> {
        self.begin_dispatch_submission_with_context(message_id, thread_id, None)
            .await
    }

    pub async fn begin_dispatch_submission_with_context(
        &self,
        message_id: &str,
        thread_id: &str,
        context_json: Option<&str>,
    ) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let result = sqlx::query("UPDATE dispatch_attempts SET phase = 'submitting', thread_id = ?, context_json = ? WHERE id = (SELECT MAX(id) FROM dispatch_attempts WHERE message_id = ?) AND phase = 'claimed'")
            .bind(thread_id).bind(context_json).bind(message_id).execute(&mut *tx).await?;
        if result.rows_affected() != 1 {
            return Err(sqlx::Error::RowNotFound);
        }
        sqlx::query("UPDATE messages SET codex_thread_id = ? WHERE id = ?")
            .bind(thread_id)
            .bind(message_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await
    }

    pub async fn is_durable_dispatch(&self, message_id: &str) -> Result<bool, sqlx::Error> {
        let row = sqlx::query(
            "SELECT EXISTS(SELECT 1 FROM dispatch_work WHERE message_id = ?) AS present",
        )
        .bind(message_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(row.get::<i64, _>("present") != 0)
    }

    pub async fn pending_dispatch_messages(&self) -> Result<Vec<StoredMessage>, sqlx::Error> {
        let rows = sqlx::query("SELECT m.* FROM messages m JOIN dispatch_work w ON w.message_id=m.id WHERE m.state='accepted_by_wonder' AND NOT EXISTS(SELECT 1 FROM messages active WHERE active.conversation_id=m.conversation_id AND active.id<>m.id AND active.state IN ('dispatching_to_codex','accepted_by_codex','streaming')) AND m.id=(SELECT pending.id FROM messages pending JOIN dispatch_work pw ON pw.message_id=pending.id WHERE pending.conversation_id=m.conversation_id AND pending.state='accepted_by_wonder' ORDER BY pending.queue_position,pending.created_at,pending.id LIMIT 1) ORDER BY m.queue_position,m.created_at,m.id LIMIT 32")
            .fetch_all(&self.pool).await?;
        Ok(rows.iter().map(stored_message).collect())
    }

    pub async fn ambiguous_dispatch_messages(&self) -> Result<Vec<StoredMessage>, sqlx::Error> {
        let rows = sqlx::query("SELECT m.* FROM messages m WHERE (m.id IN (SELECT message_id FROM dispatch_work) OR m.id IN (SELECT message_id FROM guide_work) OR EXISTS (SELECT 1 FROM group_nodes g WHERE g.device_id=m.device_id AND g.client_message_id=m.client_message_id)) AND m.state = 'uncertain' AND m.codex_turn_id IS NULL ORDER BY m.created_at, m.id")
            .fetch_all(&self.pool).await?;
        Ok(rows.iter().map(stored_message).collect())
    }

    /// Fail closed for every durable source of work that could be interrupted
    /// when the host application exits for an update. Includes queued and
    /// uncertain work, not only turns currently running in Codex.
    pub async fn has_update_blocking_work(
        &self,
        host_installation_id: &str,
    ) -> Result<bool, sqlx::Error> {
        // An uncertain message needs user review, but is no longer executing.
        // Blocking on it indefinitely would strand signed updates after a crash.
        let blocking: i64 = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE state IN ('accepted_by_wonder','dispatching_to_codex','accepted_by_codex','streaming')) OR EXISTS(SELECT 1 FROM group_runs WHERE state NOT IN ('completed','failed','cancelled')) OR EXISTS(SELECT 1 FROM automation_runs WHERE status='running') OR EXISTS(SELECT 1 FROM project_assignments WHERE state IN ('queued','working','uncertain','awaiting_input','integrating')) OR EXISTS(SELECT 1 FROM computer_sessions WHERE host_installation_id=? AND state IN ('preparing','awaitingSource','live','paused','stale')) OR EXISTS(SELECT 1 FROM computer_control_leases WHERE host_installation_id=? AND status='active')")
            .bind(host_installation_id)
            .bind(host_installation_id)
            .fetch_one(&self.pool)
            .await?;
        Ok(blocking != 0)
    }

    /// Run only at service startup, before any dispatcher is allowed to claim.
    pub async fn recover_dispatch_claims(&self) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("UPDATE messages SET state = CASE WHEN (EXISTS (SELECT 1 FROM dispatch_work WHERE message_id = messages.id) OR EXISTS (SELECT 1 FROM group_nodes WHERE device_id=messages.device_id AND client_message_id=messages.client_message_id)) AND (SELECT phase FROM dispatch_attempts WHERE message_id = messages.id ORDER BY id DESC LIMIT 1) = 'claimed' THEN 'accepted_by_wonder' ELSE 'uncertain' END WHERE state = 'dispatching_to_codex'")
            .execute(&mut *tx).await?;
        sqlx::query("UPDATE dispatch_attempts SET phase = CASE WHEN phase = 'claimed' THEN 'released' ELSE 'uncertain' END WHERE phase IN ('claimed', 'submitting')")
            .execute(&mut *tx).await?;
        sqlx::query("UPDATE messages SET state = 'uncertain' WHERE state = 'accepted_by_wonder' AND id NOT IN (SELECT message_id FROM dispatch_work) AND id NOT IN (SELECT message_id FROM guide_work) AND id NOT IN (SELECT parent_message_id FROM group_runs) AND NOT EXISTS (SELECT 1 FROM group_nodes WHERE device_id=messages.device_id AND client_message_id=messages.client_message_id)")
            .execute(&mut *tx).await?;
        tx.commit().await
    }

    /// Run only at service startup, before any dispatcher is allowed to claim.
    pub async fn recover_direct_dispatch_claims(&self) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("UPDATE messages SET state = CASE WHEN EXISTS (SELECT 1 FROM dispatch_work WHERE message_id = messages.id) AND (SELECT phase FROM dispatch_attempts WHERE message_id = messages.id ORDER BY id DESC LIMIT 1) = 'claimed' THEN 'accepted_by_wonder' ELSE 'uncertain' END WHERE state = 'dispatching_to_codex' AND id IN (SELECT message_id FROM dispatch_work)")
            .execute(&mut *tx).await?;
        sqlx::query("UPDATE dispatch_attempts SET phase = CASE WHEN phase = 'claimed' THEN 'released' ELSE 'uncertain' END WHERE phase IN ('claimed', 'submitting') AND message_id IN (SELECT message_id FROM dispatch_work)")
            .execute(&mut *tx).await?;
        tx.commit().await
    }

    pub async fn requeue_safe_to_retry(&self, message_id: &str) -> Result<bool, sqlx::Error> {
        self.requeue_message_for_retry(message_id).await
    }

    pub async fn requeue_message_for_retry(&self, message_id: &str) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE messages SET state = 'accepted_by_wonder' WHERE id = ? AND state IN ('safe_to_retry', 'failed')",
        )
        .bind(message_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn conversation_thread(
        &self,
        conversation_id: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        sqlx::query("SELECT codex_thread_id FROM conversations WHERE id = ?")
            .bind(conversation_id)
            .fetch_optional(&self.pool)
            .await?
            .map(|row| row.try_get("codex_thread_id"))
            .transpose()
    }

    pub async fn conversation_for_thread(
        &self,
        thread_id: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT id FROM conversations WHERE codex_thread_id = ? LIMIT 1")
            .bind(thread_id)
            .fetch_optional(&self.pool)
            .await
    }

    pub async fn set_conversation_thread(
        &self,
        conversation_id: &str,
        codex_thread_id: &str,
        session_id: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "INSERT INTO conversations (id, codex_thread_id, session_id, created_at) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET codex_thread_id = excluded.codex_thread_id, session_id = COALESCE(excluded.session_id, conversations.session_id)",
        )
        .bind(conversation_id)
        .bind(codex_thread_id)
        .bind(session_id)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn conversation_dynamic_tools_version(
        &self,
        conversation_id: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        sqlx::query("SELECT dynamic_tools_version FROM conversations WHERE id = ?")
            .bind(conversation_id)
            .fetch_optional(&self.pool)
            .await?
            .map(|row| row.try_get("dynamic_tools_version"))
            .transpose()
    }

    pub async fn mark_conversation_dynamic_tools(
        &self,
        conversation_id: &str,
        version: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE conversations SET dynamic_tools_version = ? WHERE id = ?")
            .bind(version)
            .bind(conversation_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn insert_pending_approval(
        &self,
        server_request_id: &str,
        method: &str,
        params_json: &str,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        let action_nonce = uuid::Uuid::new_v4().to_string();
        let params = serde_json::from_str::<serde_json::Value>(params_json).unwrap_or_default();
        let thread_id = params
            .get("threadId")
            .and_then(|value| value.as_str())
            .unwrap_or_default();
        let turn_id = params
            .get("turnId")
            .and_then(|value| value.as_str())
            .unwrap_or_default();
        let item_id = params
            .get("itemId")
            .and_then(|value| value.as_str())
            .unwrap_or_default();
        sqlx::query(
            "INSERT INTO approvals (approval_id, server_request_id, method, params_json, thread_id, turn_id, item_id, action_nonce, state, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?) ON CONFLICT(server_request_id) DO NOTHING",
        )
        .bind(server_request_id)
        .bind(server_request_id)
        .bind(method)
        .bind(params_json)
        .bind(thread_id)
        .bind(turn_id)
        .bind(item_id)
        .bind(action_nonce)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_pending_approvals(&self) -> Result<Vec<StoredApproval>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT approval_id, server_request_id, method, params_json, thread_id, turn_id, item_id, action_nonce, state, decision, resolution_idempotency_key, resolution_body_sha256, resolution_json FROM approvals WHERE state IN ('pending', 'resolving') ORDER BY created_at ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|row| stored_approval(&row)).collect())
    }

    pub async fn approval(&self, id: &str) -> Result<Option<StoredApproval>, sqlx::Error> {
        let row = sqlx::query("SELECT approval_id, server_request_id, method, params_json, thread_id, turn_id, item_id, action_nonce, state, decision, resolution_idempotency_key, resolution_body_sha256, resolution_json FROM approvals WHERE approval_id = ?")
            .bind(id).fetch_optional(&self.pool).await?;
        Ok(row.map(|row| stored_approval(&row)))
    }

    /// Atomically bind a tool call to its first execution receipt, even when a
    /// transport retry gives that call a different RPC request id.
    pub async fn reserve_computer_tool_call(
        &self,
        key: &str,
        hash: &str,
        approval: &str,
    ) -> Result<(bool, String, String), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let inserted = sqlx::query("INSERT INTO computer_tool_calls(call_key,input_hash,approval_id) VALUES(?,?,?) ON CONFLICT DO NOTHING")
            .bind(key).bind(hash).bind(approval).execute(&mut *tx).await?.rows_affected() == 1;
        let row =
            sqlx::query("SELECT input_hash,approval_id FROM computer_tool_calls WHERE call_key=?")
                .bind(key)
                .fetch_one(&mut *tx)
                .await?;
        tx.commit().await?;
        Ok((inserted, row.get("input_hash"), row.get("approval_id")))
    }

    /// Guide can become the newest receipt for a turn without changing the
    /// permissions accepted by its original dispatch.
    pub async fn dispatched_message_for_turn(
        &self,
        thread: &str,
        turn: &str,
    ) -> Result<Option<StoredMessage>, sqlx::Error> {
        let row = sqlx::query("SELECT m.* FROM messages m JOIN dispatch_attempts d ON d.message_id=m.id WHERE m.codex_thread_id=? AND m.codex_turn_id=? AND d.context_json IS NOT NULL ORDER BY d.id ASC LIMIT 1")
            .bind(thread).bind(turn).fetch_optional(&self.pool).await?;
        Ok(row.map(|row| stored_message(&row)))
    }

    /// Terminal turns cannot consume an outstanding tool reply. Include legacy
    /// requests, but never expire another turn just because it shares a thread.
    pub async fn retire_completed_tool_approvals(
        &self,
        now: &str,
    ) -> Result<Vec<String>, sqlx::Error> {
        sqlx::query_scalar("UPDATE approvals SET state = 'resolved', decision = 'turn_ended', resolved_at = ? WHERE method = 'item/tool/call' AND state IN ('pending', 'resolving') AND (SELECT m.state FROM messages m WHERE m.codex_thread_id = approvals.thread_id AND m.codex_turn_id = approvals.turn_id ORDER BY m.created_at DESC, m.rowid DESC LIMIT 1) IN ('completed', 'failed', 'cancelled', 'interrupted') RETURNING approval_id")
            .bind(now).fetch_all(&self.pool).await
    }

    pub async fn begin_approval_resolution(
        &self,
        approval_id: &str,
    ) -> Result<Option<StoredApproval>, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        let result = sqlx::query(
            "UPDATE approvals SET state = 'resolving' WHERE approval_id = ? AND state = 'pending'",
        )
        .bind(approval_id)
        .execute(&mut *transaction)
        .await?;
        if result.rows_affected() != 1 {
            transaction.commit().await?;
            return Ok(None);
        }
        let row = sqlx::query(
            "SELECT approval_id, server_request_id, method, params_json, thread_id, turn_id, item_id, action_nonce, state, decision, resolution_idempotency_key, resolution_body_sha256, resolution_json FROM approvals WHERE approval_id = ?",
        )
        .bind(approval_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(Some(stored_approval(&row)))
    }

    pub async fn resume_approval_resolution(
        &self,
        approval_id: &str,
    ) -> Result<Option<StoredApproval>, sqlx::Error> {
        let row = sqlx::query(
            "SELECT approval_id, server_request_id, method, params_json, thread_id, turn_id, item_id, action_nonce, state, decision, resolution_idempotency_key, resolution_body_sha256, resolution_json FROM approvals WHERE approval_id = ? AND state = 'resolving'",
        )
        .bind(approval_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|row| stored_approval(&row)))
    }

    pub async fn finish_approval_resolution(
        &self,
        approval_id: &str,
        decision: &str,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "UPDATE approvals SET state = 'resolved', decision = ?, resolved_at = ? WHERE approval_id = ? AND state = 'resolving'",
        )
        .bind(decision)
        .bind(now)
        .bind(approval_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn persist_approval_resolution_intent(
        &self,
        approval_id: &str,
        idempotency_key: &str,
        body_sha256: &str,
        response_json: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE approvals SET resolution_idempotency_key = ?, resolution_body_sha256 = ?, resolution_json = ? WHERE approval_id = ? AND state = 'resolving' AND (resolution_idempotency_key IS NULL OR resolution_idempotency_key = ?)",
        )
        .bind(idempotency_key)
        .bind(body_sha256)
        .bind(response_json)
        .bind(approval_id)
        .bind(idempotency_key)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn reset_approval_resolution(&self, approval_id: &str) -> Result<(), sqlx::Error> {
        sqlx::query(
            "UPDATE approvals SET state = 'pending' WHERE approval_id = ? AND state = 'resolving'",
        )
        .bind(approval_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn invalidate_pending_approvals(&self, now: &str) -> Result<(), sqlx::Error> {
        sqlx::query(
            "UPDATE approvals SET state = 'resolved', decision = 'app_server_lost', resolved_at = ? WHERE state IN ('pending', 'resolving')",
        )
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn resolve_approval_by_server_request_id(
        &self,
        server_request_id: &str,
        decision: &str,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE approvals SET state = 'resolved', decision = ?, resolved_at = ? WHERE server_request_id = ? AND state IN ('pending', 'resolving')",
        )
        .bind(decision)
        .bind(now)
        .bind(server_request_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    /// Legacy history insertion (including old fixtures). Daemon publishers use
    /// `commit_event` so the committed sync journal receives the event too.
    pub async fn append_event(&self, event: &HostEventEnvelope) -> Result<(), sqlx::Error> {
        let payload_json =
            serde_json::to_string(event).map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
        sqlx::query("INSERT INTO events (event_id, host_epoch, sequence, occurred_at, payload_json) VALUES (?, ?, ?, ?, ?) ON CONFLICT(event_id) DO NOTHING")
            .bind(&event.event_id)
            .bind(&event.host_epoch)
            .bind(event.sequence as i64)
            .bind(&event.occurred_at)
            .bind(payload_json)
            .execute(&self.pool)
            .await?;
        self.prune_replay().await?;
        Ok(())
    }

    /// Legacy presentation history. Client synchronization uses `replay_batch`.
    pub async fn events_after(
        &self,
        host_epoch: &str,
        sequence: u64,
    ) -> Result<Vec<HostEventEnvelope>, sqlx::Error> {
        let rows = sqlx::query("SELECT payload_json FROM events WHERE host_epoch = ? AND sequence > ? ORDER BY sequence ASC")
            .bind(host_epoch)
            .bind(sequence as i64)
            .fetch_all(&self.pool)
            .await?;
        rows.into_iter()
            .map(|row| {
                let payload: String = row.get("payload_json");
                serde_json::from_str(&payload).map_err(|error| sqlx::Error::Decode(Box::new(error)))
            })
            .collect()
    }

    pub async fn events_for_conversation(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<HostEventEnvelope>, sqlx::Error> {
        let rows = sqlx::query("SELECT payload_json FROM events WHERE json_extract(payload_json, '$.conversationId') = ? ORDER BY sequence ASC")
            .bind(conversation_id)
            .fetch_all(&self.pool)
            .await?;
        let mut events = Vec::new();
        for row in rows {
            let payload: String = row.get("payload_json");
            let event = serde_json::from_str::<HostEventEnvelope>(&payload)
                .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
            if event.conversation_id.as_deref() == Some(conversation_id) {
                events.push(event);
            }
        }
        Ok(events)
    }

    pub async fn event_bounds(&self, host_epoch: &str) -> Result<Option<(u64, u64)>, sqlx::Error> {
        let row = sqlx::query(
            "SELECT MIN(sequence) AS first_sequence, MAX(sequence) AS last_sequence FROM events WHERE host_epoch = ?",
        )
        .bind(host_epoch)
        .fetch_one(&self.pool)
        .await?;
        let first: Option<i64> = row.try_get("first_sequence")?;
        let last: Option<i64> = row.try_get("last_sequence")?;
        Ok(first
            .zip(last)
            .map(|(first, last)| (first as u64, last as u64)))
    }
}

fn stored_message(row: &sqlx::sqlite::SqliteRow) -> StoredMessage {
    StoredMessage {
        id: row.get("id"),
        device_id: row.get("device_id"),
        client_message_id: row.get("client_message_id"),
        body: row.get("body"),
        body_sha256: row.get("body_sha256"),
        conversation_id: row.get("conversation_id"),
        state: row.get("state"),
        created_at: row.get("created_at"),
        codex_thread_id: row.get("codex_thread_id"),
        codex_turn_id: row.get("codex_turn_id"),
    }
}

fn is_taught_task_heading(line: &str) -> bool {
    line.trim_start().starts_with("## Taught task:")
}

fn is_top_level_heading(line: &str) -> bool {
    line.trim_start().starts_with("## ")
}

fn strip_taught_task_sections(prompt: &str) -> String {
    let mut kept = Vec::<String>::new();
    let mut skipping = false;

    for line in prompt.lines() {
        if skipping {
            if is_taught_task_heading(line) {
                continue;
            }
            if is_top_level_heading(line) {
                skipping = false;
                if !kept.is_empty()
                    && kept
                        .last()
                        .is_some_and(|kept_line| !kept_line.trim().is_empty())
                {
                    kept.push(String::new());
                }
            } else {
                continue;
            }
        }

        if is_taught_task_heading(line) {
            while kept
                .last()
                .is_some_and(|kept_line| kept_line.trim().is_empty())
            {
                kept.pop();
            }
            skipping = true;
            continue;
        }
        kept.push(line.to_owned());
    }

    while kept
        .last()
        .is_some_and(|kept_line| kept_line.trim().is_empty())
    {
        kept.pop();
    }
    kept.join("\n")
}

async fn cleanup_taught_task_sections(pool: &SqlitePool) -> Result<(), sqlx::Error> {
    let mut transaction = pool.begin().await?;
    let rows = sqlx::query("SELECT id, role, system_prompt FROM bots")
        .fetch_all(&mut *transaction)
        .await?;

    for row in rows {
        let id: String = row.get("id");
        let role: String = row.get("role");
        let prompt: String = row.get("system_prompt");
        if !prompt.lines().any(is_taught_task_heading) {
            continue;
        }
        let cleaned = strip_taught_task_sections(&prompt);
        let replacement = if cleaned.trim().is_empty() {
            role.trim().to_owned()
        } else {
            cleaned
        };
        if replacement != prompt {
            sqlx::query("UPDATE bots SET system_prompt = ? WHERE id = ?")
                .bind(replacement)
                .bind(id)
                .execute(&mut *transaction)
                .await?;
        }
    }

    transaction.commit().await
}

fn stored_bot(row: &sqlx::sqlite::SqliteRow) -> StoredBot {
    StoredBot {
        id: row.get("id"),
        name: row.get("name"),
        role: row.get("role"),
        system_prompt: row.get("system_prompt"),
        workspace_path: row.get("workspace_path"),
        working_directory: row.get("working_directory"),
        avatar_color: row.get("avatar_color"),
        avatar_shape: row.get("avatar_shape"),
        avatar_palette: row.get("avatar_palette"),
        avatar_legacy_color: row.get("avatar_legacy_color"),
        permission_profile: row.get("permission_profile"),
        permission_mode: row.get("permission_mode"),
        approval_mode: row.get("approval_mode"),
        model: row.get("model"),
        reasoning_effort: row.get("reasoning_effort"),
        service_tier: row.get("service_tier"),
        is_archived: row.get::<i64, _>("is_archived") != 0,
        conversation_id: row.get("conversation_id"),
    }
}

async fn backfill_avatar_identity(pool: &SqlitePool) -> Result<(), sqlx::Error> {
    let rows = sqlx::query(
        "SELECT id, avatar_shape, avatar_palette, avatar_color, avatar_legacy_color FROM bots",
    )
    .fetch_all(pool)
    .await?;
    for row in rows {
        let id: String = row.get("id");
        let shape: Option<String> = row.get("avatar_shape");
        let palette: Option<String> = row.get("avatar_palette");
        let color: Option<String> = row.get("avatar_color");
        let legacy_color: Option<String> = row.get("avatar_legacy_color");
        let resolved_shape = shape
            .clone()
            .or_else(|| Some(avatar::default_shape_for_identity(&id).to_owned()));
        let resolved_palette = palette.clone().or_else(|| {
            color
                .as_deref()
                .and_then(avatar::palette_for_legacy_color)
                .or_else(|| {
                    resolved_shape
                        .as_deref()
                        .map(avatar::default_palette_for_shape)
                })
                .map(str::to_owned)
        });
        let derived_color = resolved_palette
            .as_deref()
            .and_then(avatar::palette)
            .map(|palette| palette.body.to_owned())
            .or(color.clone());
        // Only pre-contract rows need a rollback copy. Do not mutate a row
        // that already has both identity fields, including future catalog
        // values that this binary must preserve verbatim.
        let preserved_legacy = legacy_color.or_else(|| {
            (shape.is_none() || palette.is_none())
                .then(|| color.clone())
                .flatten()
        });
        if shape != resolved_shape
            || palette != resolved_palette
            || color != derived_color
            || row.get::<Option<String>, _>("avatar_legacy_color") != preserved_legacy
        {
            sqlx::query(
                "UPDATE bots SET avatar_shape=?, avatar_palette=?, avatar_color=?, avatar_legacy_color=? WHERE id=?",
            )
            .bind(resolved_shape)
            .bind(resolved_palette)
            .bind(derived_color)
            .bind(preserved_legacy)
            .bind(id)
            .execute(pool)
            .await?;
        }
    }
    Ok(())
}

fn stored_assistant_message(row: &sqlx::sqlite::SqliteRow) -> StoredAssistantMessage {
    StoredAssistantMessage {
        id: row.get("id"),
        conversation_id: row.get("conversation_id"),
        codex_thread_id: row.get("codex_thread_id"),
        codex_turn_id: row.get("codex_turn_id"),
        item_id: row.get("item_id"),
        text: row.get("text"),
        state: row.get("state"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}

fn stored_subagent_ownership(row: &sqlx::sqlite::SqliteRow) -> StoredSubagentOwnership {
    StoredSubagentOwnership {
        conversation_id: row.get("conversation_id"),
        parent_conversation_id: row.get("parent_conversation_id"),
        thread_id: row.get("thread_id"),
        parent_thread_id: row.get("parent_thread_id"),
        agent_nickname: row.get("agent_nickname"),
        agent_role: row.get("agent_role"),
        agent_path: row.get("agent_path"),
        source_json: row.get("source_json"),
        runtime_id: row.get("runtime_id"),
        can_accept_direct_input: row
            .get::<Option<i64>, _>("can_accept_direct_input")
            .map(|value| value != 0),
        status: row.get("status"),
        is_archived: row.get::<i64, _>("is_archived") != 0,
    }
}

fn stored_approval(row: &sqlx::sqlite::SqliteRow) -> StoredApproval {
    StoredApproval {
        approval_id: row.get("approval_id"),
        server_request_id: row.get("server_request_id"),
        method: row.get("method"),
        params_json: row.get("params_json"),
        action_nonce: row.get("action_nonce"),
        state: row.get("state"),
        decision: row.get("decision"),
        thread_id: row.get("thread_id"),
        turn_id: row.get("turn_id"),
        item_id: row.get("item_id"),
        resolution_idempotency_key: row.get("resolution_idempotency_key"),
        resolution_body_sha256: row.get("resolution_body_sha256"),
        resolution_json: row.get("resolution_json"),
    }
}

fn stored_automation(row: &sqlx::sqlite::SqliteRow) -> StoredAutomation {
    StoredAutomation {
        id: row.get("id"),
        name: row.get("name"),
        kind: row.get("kind"),
        bot_id: row.get("bot_id"),
        conversation_id: row.get("conversation_id"),
        prompt: row.get("prompt"),
        rrule: row.get("rrule"),
        timezone: row.get("timezone"),
        status: row.get("status"),
        notification_policy: row.get("notification_policy"),
        model_id: row.get("model_id"),
        reasoning_effort: row.get("reasoning_effort"),
        scope_type: row.get("scope_type"),
        scope_id: row.get("scope_id"),
        next_run_at: row.get("next_run_at"),
        last_run_at: row.get("last_run_at"),
        last_attempt_at: row.get("last_attempt_at"),
        last_success_at: row.get("last_success_at"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}

fn stored_automation_run(row: &sqlx::sqlite::SqliteRow) -> StoredAutomationRun {
    StoredAutomationRun {
        id: row.get("id"),
        automation_id: row.get("automation_id"),
        scheduled_for: row.get("scheduled_for"),
        status: row.get("status"),
        started_at: row.get("started_at"),
        finished_at: row.get("finished_at"),
        error: row.get("error"),
        message_id: row.get("message_id"),
        conversation_id: row.get("conversation_id"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wonder_api::WonderEvent;

    #[tokio::test]
    async fn user_echo_repair_preserves_real_assistant_with_identical_text() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        for item in ["user-item", "assistant-item"] {
            store
                .complete_assistant_message("chat", "thread", "turn", item, "hello", "now")
                .await
                .unwrap();
        }
        let payload = serde_json::json!({"conversationId":"chat", "threadId":"thread", "turnId":"turn", "itemId":"user-item", "event":{"data":{"category":"thread_item_upsert", "detail":serde_json::json!({"item":{"type":"userMessage"}}).to_string()}}});
        sqlx::query("INSERT INTO events VALUES ('event','epoch',1,'now',?)")
            .bind(payload.to_string())
            .execute(&store.pool)
            .await
            .unwrap();
        sqlx::raw_sql(include_str!("../migrations/0040_user_echo_projection.sql"))
            .execute(&store.pool)
            .await
            .unwrap();
        let rows = store
            .assistant_messages_for_conversation("chat")
            .await
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].item_id, "assistant-item");
        assert_eq!(rows[0].text, "hello");
    }

    #[tokio::test]
    async fn local_desktop_is_not_a_remote_pairing_identity() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store.ensure_local_desktop("now").await.unwrap();
        store.ensure_local_desktop("later").await.unwrap();
        assert!(store.list_owner_devices().await.unwrap().is_empty());
        assert!(store
            .insert_dispatch_message(
                "wonder-desktop",
                "request",
                "hello",
                "hash",
                "chat",
                &[],
                "now",
                true
            )
            .await
            .is_ok());
    }

    #[tokio::test]
    async fn update_readiness_rejects_active_work_but_allows_uncertain_messages() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        assert!(!store.has_update_blocking_work("host").await.unwrap());
        store
            .upsert_owner_device("device", "Owner", "{}", "now")
            .await
            .unwrap();
        let MessageInsert::Inserted(message) = store
            .insert_dispatch_message("device", "client", "body", "hash", "bot", &[], "now", true)
            .await
            .unwrap()
        else {
            panic!("message insertion");
        };
        assert!(store.has_update_blocking_work("host").await.unwrap());
        store
            .update_message_delivery(&message.id, "uncertain", None, None)
            .await
            .unwrap();
        assert!(!store.has_update_blocking_work("host").await.unwrap());
        store
            .update_message_delivery(&message.id, "completed", None, None)
            .await
            .unwrap();
        assert!(!store.has_update_blocking_work("host").await.unwrap());
        sqlx::query("INSERT INTO computer_sessions(id,client_request_id,owner_device_id,host_installation_id,conversation_id,generation,state,geometry_revision,created_at,updated_at,last_state_at) VALUES ('session','request','device','host','bot',1,'paused',0,'now','now','now')")
            .execute(&store.pool).await.unwrap();
        assert!(store.has_update_blocking_work("host").await.unwrap());
        assert!(!store.has_update_blocking_work("other-host").await.unwrap());
        sqlx::query("UPDATE computer_sessions SET state='ended' WHERE id='session'")
            .execute(&store.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO computer_control_leases(id,client_request_id,session_id,owner_device_id,host_installation_id,conversation_id,session_generation,geometry_revision,status,acquired_at,updated_at,expires_at) VALUES ('control','control-request','session','device','host','bot',1,0,'active','now','now','later')")
            .execute(&store.pool).await.unwrap();
        assert!(store.has_update_blocking_work("host").await.unwrap());
        sqlx::query("UPDATE computer_control_leases SET status='released' WHERE id='control'")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(!store.has_update_blocking_work("host").await.unwrap());
    }

    #[tokio::test]
    async fn durable_acceptance_claim_and_submission_boundaries_are_atomic() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_owner_device("device", "Owner", "{}", "now")
            .await
            .unwrap();
        let MessageInsert::Inserted(message) = store
            .insert_dispatch_message("device", "client", "body", "hash", "bot", &[], "now", true)
            .await
            .unwrap()
        else {
            panic!("insert");
        };
        assert_eq!(
            store.pending_dispatch_messages().await.unwrap(),
            vec![message.clone()]
        );
        assert!(matches!(
            store
                .insert_dispatch_message(
                    "device",
                    "client",
                    "body",
                    "hash",
                    "bot",
                    &[],
                    "now",
                    true
                )
                .await
                .unwrap(),
            MessageInsert::Existing(_)
        ));
        assert_eq!(
            store
                .insert_message("device", "client", "body", "hash", "bot", "now")
                .await
                .unwrap(),
            MessageInsert::Conflict
        );
        let (first, second) = tokio::join!(
            store.claim_message_for_dispatch(&message.id),
            store.claim_message_for_dispatch(&message.id)
        );
        assert_eq!(u8::from(first.unwrap()) + u8::from(second.unwrap()), 1);
        store.recover_dispatch_claims().await.unwrap();
        assert_eq!(store.pending_dispatch_messages().await.unwrap().len(), 1);
        assert!(store.claim_message_for_dispatch(&message.id).await.unwrap());
        store
            .begin_dispatch_submission_with_context(
                &message.id,
                "thread",
                Some(r#"{"instructions":"original"}"#),
            )
            .await
            .unwrap();
        assert!(store
            .begin_dispatch_submission_with_context(
                &message.id,
                "thread",
                Some(r#"{"instructions":"changed"}"#)
            )
            .await
            .is_err());
        let saved: String = sqlx::query_scalar(
            "SELECT context_json FROM dispatch_attempts ORDER BY id DESC LIMIT 1",
        )
        .fetch_one(&store.pool)
        .await
        .unwrap();
        assert_eq!(saved, r#"{"instructions":"original"}"#);
        store.recover_dispatch_claims().await.unwrap();
        assert!(store.pending_dispatch_messages().await.unwrap().is_empty());
        assert!(!store.requeue_message_for_retry(&message.id).await.unwrap());
        let phases: Vec<String> =
            sqlx::query_scalar("SELECT phase FROM dispatch_attempts ORDER BY id")
                .fetch_all(&store.pool)
                .await
                .unwrap();
        assert_eq!(phases, vec!["released", "uncertain"]);
    }

    #[tokio::test]
    async fn failed_queue_insert_rolls_back_message_acceptance() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_owner_device("device", "Owner", "{}", "now")
            .await
            .unwrap();
        sqlx::query("CREATE TRIGGER refuse_queue BEFORE INSERT ON dispatch_work BEGIN SELECT RAISE(ABORT, 'disk fault'); END").execute(&store.pool).await.unwrap();
        assert!(store
            .insert_dispatch_message("device", "client", "body", "hash", "bot", &[], "now", true)
            .await
            .is_err());
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM messages")
            .fetch_one(&store.pool)
            .await
            .unwrap();
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn duplicate_message_is_idempotent_and_conflicting_body_is_rejected() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device(
                "device-1",
                "Recorded",
                "{\"kty\":\"EC\"}",
                "2026-08-31T00:00:00Z",
            )
            .await
            .expect("device");
        let first = store
            .insert_message(
                "device-1",
                "client-1",
                "message body",
                "hash-a",
                "conversation-1",
                "2026-08-31T00:00:00Z",
            )
            .await
            .expect("insert");
        let second = store
            .insert_message(
                "device-1",
                "client-1",
                "message body",
                "hash-a",
                "conversation-1",
                "2026-08-31T00:00:01Z",
            )
            .await
            .expect("duplicate");
        let conflict = store
            .insert_message(
                "device-1",
                "client-1",
                "different body",
                "hash-b",
                "conversation-1",
                "2026-08-31T00:00:02Z",
            )
            .await
            .expect("conflict");
        assert!(matches!(first, MessageInsert::Inserted(_)));
        assert!(matches!(second, MessageInsert::Existing(_)));
        assert_eq!(conflict, MessageInsert::Conflict);
    }

    #[tokio::test]
    async fn bot_lifecycle_updates_archives_and_allows_legacy_default_recovery() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_bot(
                "default",
                "Default Bot",
                "General assistant",
                "Keep work focused.",
                "/tmp/default",
                "wonder_bot_default",
                None,
                None,
                "2026-09-01T10:00:00Z",
            )
            .await
            .expect("default bot");
        store
            .upsert_bot(
                "custom",
                "Custom Bot",
                "Research",
                "Research carefully.",
                "/tmp/custom",
                "wonder_bot_custom",
                Some("model-a"),
                Some("low"),
                "2026-09-01T10:01:00Z",
            )
            .await
            .expect("custom bot");

        let updated = store
            .update_bot(
                "custom",
                Some("Updated Bot"),
                Some("Writer"),
                Some("Write clearly."),
                None,
                None,
                None,
            )
            .await
            .expect("update")
            .expect("updated bot");
        assert_eq!(updated.name, "Updated Bot");
        assert_eq!(updated.role, "Writer");
        assert!(!updated.is_archived);
        let legacy = store
            .set_bot_archived("default", true)
            .await
            .expect("archive legacy default")
            .expect("legacy default");
        assert!(legacy.is_archived);
        assert!(store.delete_bot("default").await.expect("delete default"));

        let archived = store
            .set_bot_archived("custom", true)
            .await
            .expect("archive")
            .expect("archived bot");
        assert!(archived.is_archived);
        assert!(
            store
                .bot("custom")
                .await
                .expect("get")
                .expect("bot")
                .is_archived
        );
        assert!(store.delete_bot("custom").await.expect("delete custom"));
        assert!(store.bot("custom").await.expect("get deleted").is_none());
    }

    #[tokio::test]
    async fn bot_workspace_is_stable_and_reuses_existing_metadata() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_bot(
                "writer",
                "Writer",
                "Writing partner",
                "Write clearly.",
                "/tmp/writer",
                "wonder_bot_writer",
                None,
                None,
                "2026-09-01T10:00:00Z",
            )
            .await
            .expect("bot");
        let first = store
            .ensure_bot_workspace("writer", "Writer", "2026-09-01T10:01:00Z")
            .await
            .expect("workspace");
        let second = store
            .ensure_bot_workspace("writer", "Renamed Writer", "2026-09-01T10:02:00Z")
            .await
            .expect("workspace reuse");
        assert_eq!(first, second);
        assert_eq!(
            store.bot_workspace("writer").await.expect("lookup"),
            Some(first)
        );
        assert_eq!(
            store
                .conversation(&second)
                .await
                .expect("conversation")
                .expect("metadata")
                .title,
            "Renamed Writer"
        );
    }

    #[tokio::test]
    async fn canonical_workspace_does_not_add_an_empty_legacy_chat() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_bot(
                "bot",
                "Bot",
                "Assistant",
                "Help",
                "/tmp/bot",
                "test",
                None,
                None,
                "now",
            )
            .await
            .unwrap();
        let canonical = store
            .ensure_bot_workspace("bot", "Bot", "now")
            .await
            .unwrap();
        let summaries = store.list_conversation_summaries().await.unwrap();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].conversation_id, canonical);
    }

    #[tokio::test]
    async fn conversation_summaries_join_bot_and_latest_message_data() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Recorded", "{\"kty\":\"EC\"}", "now")
            .await
            .expect("device");
        store
            .upsert_bot(
                "default",
                "Default Bot",
                "General assistant",
                "Keep work focused.",
                "/tmp/wonder-default",
                "wonder_bot_default",
                None,
                None,
                "2026-09-01T09:00:00Z",
            )
            .await
            .expect("bot");
        store
            .upsert_bot(
                "empty",
                "Empty Bot",
                "General assistant",
                "Keep work focused.",
                "/tmp/wonder-empty",
                "wonder_bot_empty",
                None,
                None,
                "2026-09-01T08:00:00Z",
            )
            .await
            .expect("empty bot");
        store
            .insert_message(
                "device-1",
                "client-1",
                "first message",
                "hash-a",
                "default",
                "2026-09-01T10:00:00Z",
            )
            .await
            .expect("first message");
        let second = store
            .insert_message(
                "device-1",
                "client-2",
                &("latest ".to_owned() + &"x".repeat(300)),
                "hash-b",
                "default",
                "2026-09-01T10:01:00Z",
            )
            .await
            .expect("second message");
        let second_id = match second {
            MessageInsert::Inserted(message) => message.id,
            _ => panic!("expected inserted message"),
        };
        store
            .update_message_delivery(&second_id, "safe_to_retry", None, None)
            .await
            .expect("delivery state");
        store
            .append_event(&HostEventEnvelope {
                event_id: "assistant-event-1".into(),
                host_epoch: "epoch-1".into(),
                sequence: 1,
                occurred_at: "2026-09-01T10:02:00.000Z".into(),
                request_id: None,
                device_id: None,
                conversation_id: Some("default".into()),
                message_id: Some(second_id),
                thread_id: None,
                turn_id: None,
                item_id: None,
                approval_id: None,
                event: WonderEvent::AssistantCompleted {
                    text: "assistant reply".into(),
                },
            })
            .await
            .expect("assistant event");

        let summaries = store
            .list_conversation_summaries()
            .await
            .expect("summaries");
        assert_eq!(summaries.len(), 2);
        let summary = summaries
            .iter()
            .find(|summary| summary.conversation_id == "default")
            .expect("default summary");
        assert_eq!(summary.conversation_id, "default");
        assert_eq!(summary.bot_id.as_deref(), Some("default"));
        assert_eq!(summary.title, "Default Bot");
        assert_eq!(summary.message_count, 2);
        assert_eq!(
            summary.last_message_at.as_deref(),
            Some("2026-09-01T10:02:00.000Z")
        );
        assert_eq!(summary.delivery_state.as_deref(), Some("safe_to_retry"));
        assert_eq!(
            summary.last_message_preview.as_deref(),
            Some("assistant reply")
        );
        let empty = summaries
            .iter()
            .find(|summary| summary.conversation_id == "empty")
            .expect("empty summary");
        assert_eq!(empty.bot_id.as_deref(), Some("empty"));
        assert_eq!(empty.title, "Empty Bot");
        assert_eq!(empty.message_count, 0);
        assert_eq!(empty.last_message_preview, None);
        assert_eq!(empty.last_message_at, None);
        assert_eq!(empty.delivery_state, None);
    }

    #[tokio::test]
    async fn conversation_summaries_order_tied_timestamps_by_id() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Recorded", "{\"kty\":\"EC\"}", "now")
            .await
            .expect("device");
        for (conversation_id, client_id) in [("zeta", "client-zeta"), ("alpha", "client-alpha")] {
            store
                .insert_message(
                    "device-1",
                    client_id,
                    "message",
                    client_id,
                    conversation_id,
                    "2026-09-01T10:00:00.000Z",
                )
                .await
                .expect("message");
        }

        let summaries = store
            .list_conversation_summaries()
            .await
            .expect("summaries");
        assert_eq!(
            summaries
                .iter()
                .map(|summary| summary.conversation_id.as_str())
                .collect::<Vec<_>>(),
            ["alpha", "zeta"]
        );
    }

    #[tokio::test]
    async fn conversation_summaries_order_legacy_epoch_milliseconds_with_rfc3339() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Recorded", "{\"kty\":\"EC\"}", "now")
            .await
            .expect("device");
        store
            .insert_message(
                "device-1",
                "client-legacy",
                "legacy message",
                "hash-legacy",
                "legacy",
                "1788256800000",
            )
            .await
            .expect("legacy message");
        store
            .insert_message(
                "device-1",
                "client-modern",
                "modern message",
                "hash-modern",
                "modern",
                "2026-09-01T09:00:00.000Z",
            )
            .await
            .expect("modern message");

        let summaries = store
            .list_conversation_summaries()
            .await
            .expect("summaries");
        assert_eq!(summaries[0].conversation_id, "legacy");
        assert_eq!(
            summaries[0].last_message_at.as_deref(),
            Some("1788256800000")
        );
        assert_eq!(
            summaries[0].last_message_preview.as_deref(),
            Some("legacy message")
        );
    }

    #[tokio::test]
    async fn event_is_replayed_from_durable_store() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        let event = HostEventEnvelope {
            event_id: "event-1".into(),
            host_epoch: "epoch-1".into(),
            sequence: 1,
            occurred_at: "2026-08-31T00:00:00Z".into(),
            request_id: None,
            device_id: None,
            conversation_id: None,
            message_id: None,
            thread_id: None,
            turn_id: None,
            item_id: None,
            approval_id: None,
            event: WonderEvent::HostStatus {
                state: "ready".into(),
            },
        };
        store.append_event(&event).await.expect("append event");
        assert_eq!(
            store.events_after("epoch-1", 0).await.expect("replay"),
            vec![event]
        );
    }

    #[tokio::test]
    async fn owner_devices_and_active_sessions_survive_store_reopen() {
        let directory = tempfile::tempdir().expect("temporary store directory");
        let database_url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("wonder.sqlite3").display()
        );
        let store = Store::connect(&database_url).await.expect("store");
        store
            .upsert_owner_device("device-1", "Chrome", "{\"kty\":\"EC\"}", "now")
            .await
            .expect("device");
        store
            .insert_session("token-hash", "device-1", "csrf-hash", 2_000, "now")
            .await
            .expect("session");
        drop(store);
        let reopened = Store::connect(&database_url).await.expect("reopen");
        let devices = reopened.list_owner_devices().await.expect("devices");
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].last_seen_at.as_deref(), Some("now"));
        assert_eq!(
            reopened
                .list_active_sessions(1_000)
                .await
                .expect("sessions")[0]
                .token_hash,
            "token-hash"
        );
        assert!(reopened
            .list_active_sessions(2_000)
            .await
            .expect("expired sessions")
            .is_empty());
    }

    #[tokio::test]
    async fn automation_messages_use_the_most_recent_active_owner_device() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("older", "Older", "{}", "2026-09-01T00:00:00Z")
            .await
            .expect("older device");
        store
            .upsert_owner_device("newer", "Newer", "{}", "2026-09-02T00:00:00Z")
            .await
            .expect("newer device");
        assert_eq!(
            store
                .automation_message_device_id()
                .await
                .expect("automation device"),
            Some("newer".into())
        );
        store
            .revoke_owner_device("newer", "2026-09-02T01:00:00Z")
            .await
            .expect("revoke newer");
        assert_eq!(
            store
                .automation_message_device_id()
                .await
                .expect("fallback automation device"),
            Some("older".into())
        );
    }

    #[tokio::test]
    async fn owner_device_rename_persists_without_invalidating_session() {
        let directory = tempfile::tempdir().expect("temporary store directory");
        let database_url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("wonder.sqlite3").display()
        );
        let store = Store::connect(&database_url).await.expect("store");
        store
            .upsert_owner_device("device-1", "Chrome", "{}", "now")
            .await
            .expect("device");
        store
            .insert_session("token-hash", "device-1", "csrf-hash", 2_000, "now")
            .await
            .expect("session");

        assert!(store
            .rename_owner_device("device-1", "Phone")
            .await
            .expect("rename"));
        assert!(!store
            .rename_owner_device("missing", "Other")
            .await
            .expect("missing rename"));
        assert_eq!(
            store.list_owner_devices().await.expect("devices")[0].label,
            "Phone"
        );
        assert_eq!(
            store
                .list_active_sessions(1_000)
                .await
                .expect("sessions")
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn forgotten_devices_are_hidden_but_keep_history_references() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .unwrap();
        store
            .upsert_owner_device("old-phone", "Phone", "{}", "now")
            .await
            .unwrap();
        assert!(
            sqlx::query("UPDATE devices SET forgotten = 1 WHERE id = 'old-phone'")
                .execute(&store.pool)
                .await
                .is_err()
        );
        assert!(!store.forget_revoked_device("old-phone").await.unwrap());
        store
            .revoke_owner_device("old-phone", "later")
            .await
            .unwrap();
        assert!(store.forget_revoked_device("old-phone").await.unwrap());
        assert!(!store.forget_revoked_device("old-phone").await.unwrap());
        assert!(!store.forget_revoked_device("missing").await.unwrap());
        assert!(store.list_owner_devices().await.unwrap().is_empty());
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE id = 'old-phone'")
            .fetch_one(&store.pool)
            .await
            .unwrap();
        assert_eq!(count, 1);
    }

    #[tokio::test]
    async fn owner_device_revoke_invalidates_all_sessions() {
        let directory = tempfile::tempdir().expect("temporary store directory");
        let database_url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("wonder.sqlite3").display()
        );
        let store = Store::connect(&database_url).await.expect("store");
        store
            .upsert_owner_device("device-1", "Chrome", "{}", "now")
            .await
            .expect("device");
        store
            .insert_session("token-one", "device-1", "csrf-one", 2_000, "now")
            .await
            .expect("session one");
        store
            .insert_session("token-two", "device-1", "csrf-two", 2_000, "now")
            .await
            .expect("session two");

        assert!(store
            .revoke_owner_device("device-1", "revoked")
            .await
            .expect("revoke"));
        assert!(store
            .list_active_sessions(1_000)
            .await
            .expect("sessions")
            .is_empty());
        assert!(!store
            .rename_owner_device("device-1", "Renamed revoked device")
            .await
            .expect("rename revoked device"));
    }

    #[tokio::test]
    async fn conversation_thread_survives_store_reopen() {
        let directory = tempfile::tempdir().expect("temporary store directory");
        let database_url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("wonder.sqlite3").display()
        );
        let store = Store::connect(&database_url).await.expect("store");
        store
            .set_conversation_thread("conversation-1", "thread-1", Some("session-1"), "now")
            .await
            .expect("thread");
        drop(store);
        let reopened = Store::connect(&database_url).await.expect("reopen");
        assert_eq!(
            reopened
                .conversation_thread("conversation-1")
                .await
                .expect("lookup"),
            Some("thread-1".into())
        );
    }

    #[tokio::test]
    async fn transcription_reads_are_device_scoped() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .insert_transcription("transcription-1", "device-1", 1_000, "now")
            .await
            .expect("transcription");
        assert!(store
            .transcription_by_id_for_device("transcription-1", "device-1")
            .await
            .expect("owner lookup")
            .is_some());
        assert!(store
            .transcription_by_id_for_device("transcription-1", "device-2")
            .await
            .expect("other device lookup")
            .is_none());
    }

    #[tokio::test]
    async fn dispatch_claim_is_atomic() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Chrome", "{}", "now")
            .await
            .expect("device");
        let inserted = store
            .insert_message(
                "device-1",
                "client-1",
                "body",
                "hash",
                "conversation-1",
                "now",
            )
            .await
            .expect("message");
        let message_id = match inserted {
            MessageInsert::Inserted(message) => message.id,
            _ => panic!("expected inserted message"),
        };
        let (first, second) = tokio::join!(
            store.claim_message_for_dispatch(&message_id),
            store.claim_message_for_dispatch(&message_id)
        );
        assert_eq!(
            first.expect("first claim") as u8 + second.expect("second claim") as u8,
            1
        );
    }

    #[tokio::test]
    async fn turn_owner_is_deterministic_when_a_steer_reuses_the_turn_id() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Chrome", "{}", "now")
            .await
            .expect("device");
        let first = store
            .insert_message(
                "device-1",
                "client-1",
                "original",
                "hash-1",
                "conversation-1",
                "2026-09-01T10:00:00.000Z",
            )
            .await
            .expect("original message");
        let first_id = match first {
            MessageInsert::Inserted(message) => message.id,
            _ => panic!("expected original message"),
        };
        let second = store
            .insert_message(
                "device-1",
                "client-2",
                "steered",
                "hash-2",
                "conversation-1",
                "2026-09-01T10:01:00.000Z",
            )
            .await
            .expect("steered message");
        let second_id = match second {
            MessageInsert::Inserted(message) => message.id,
            _ => panic!("expected steered message"),
        };
        store
            .update_message_delivery(&first_id, "streaming", Some("thread-1"), Some("turn-1"))
            .await
            .expect("original delivery");
        store
            .update_message_delivery(
                &second_id,
                "accepted_by_codex",
                Some("thread-1"),
                Some("turn-1"),
            )
            .await
            .expect("steered delivery");

        let owner = store
            .message_for_codex_turn("turn-1")
            .await
            .expect("turn owner lookup")
            .expect("turn owner");
        assert_eq!(owner.id, second_id);
        assert_eq!(
            store
                .message_by_id(&first_id)
                .await
                .expect("original lookup")
                .expect("original")
                .state,
            "streaming"
        );
        assert_eq!(
            store
                .complete_messages_for_codex_turn("turn-1")
                .await
                .expect("complete turn"),
            2
        );
        assert_eq!(
            store
                .message_by_id(&first_id)
                .await
                .expect("completed original lookup")
                .expect("completed original")
                .state,
            "completed"
        );
    }

    #[tokio::test]
    async fn client_message_lookup_preserves_completed_steer_for_replay() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Chrome", "{}", "now")
            .await
            .expect("device");
        let inserted = store
            .insert_message(
                "device-1",
                "client-steer",
                "steer body",
                "hash-steer",
                "conversation-1",
                "2026-09-01T10:00:00.000Z",
            )
            .await
            .expect("message");
        let message_id = match inserted {
            MessageInsert::Inserted(message) => message.id,
            _ => panic!("expected inserted message"),
        };
        store
            .update_message_delivery(&message_id, "completed", Some("thread-1"), Some("turn-1"))
            .await
            .expect("completed delivery");

        let replay = store
            .message_by_device_and_client_message_id("device-1", "client-steer")
            .await
            .expect("lookup")
            .expect("stored replay");
        assert_eq!(replay.id, message_id);
        assert_eq!(replay.state, "completed");
        assert_eq!(replay.codex_turn_id.as_deref(), Some("turn-1"));
    }

    #[tokio::test]
    async fn safe_to_retry_is_requeued_once() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Chrome", "{}", "now")
            .await
            .expect("device");
        let inserted = store
            .insert_message(
                "device-1",
                "client-1",
                "body",
                "hash",
                "conversation-1",
                "now",
            )
            .await
            .expect("message");
        let message_id = match inserted {
            MessageInsert::Inserted(message) => message.id,
            _ => panic!("expected inserted message"),
        };
        store
            .update_message_delivery(&message_id, "safe_to_retry", None, None)
            .await
            .expect("mark safe to retry");
        assert!(store
            .requeue_safe_to_retry(&message_id)
            .await
            .expect("requeue"));
        assert!(!store
            .requeue_safe_to_retry(&message_id)
            .await
            .expect("duplicate requeue"));
        assert_eq!(
            store
                .message_by_id(&message_id)
                .await
                .expect("lookup")
                .expect("message")
                .state,
            "accepted_by_wonder"
        );
        store
            .update_message_delivery(&message_id, "streaming", Some("thread-1"), Some("turn-1"))
            .await
            .expect("start turn");
        assert!(store
            .interrupt_message_if_active(&message_id)
            .await
            .expect("interrupt"));
        assert!(!store
            .complete_message_if_active(&message_id)
            .await
            .expect("ignore late completion"));
        assert_eq!(
            store
                .message_by_id(&message_id)
                .await
                .expect("lookup")
                .expect("message")
                .state,
            "interrupted"
        );
    }

    #[tokio::test]
    async fn message_attachment_refs_are_atomic_and_idempotent() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Browser", "{}", "now")
            .await
            .expect("device");
        store
            .upsert_conversation_file(
                "550e8400-e29b-41d4-a716-446655440000",
                "conversation-1",
                "attachment",
                "brief.txt",
                Some("text/plain"),
                Some(5),
                Some(&"a".repeat(64)),
                Some(".wonder/attachments/550e8400-e29b-41d4-a716-446655440000"),
                "available",
                None,
                None,
                None,
                "now",
            )
            .await
            .expect("file");
        let file_id = "550e8400-e29b-41d4-a716-446655440000".to_owned();
        let inserted = store
            .insert_message_with_attachments(
                "device-1",
                "client-attachment",
                "Review this file",
                "hash",
                "conversation-1",
                std::slice::from_ref(&file_id),
                "now",
            )
            .await
            .expect("message");
        let message_id = match inserted {
            MessageInsert::Inserted(message) => message.id,
            _ => panic!("expected inserted message"),
        };
        assert_eq!(
            store
                .attachment_ids_for_message(&message_id)
                .await
                .expect("refs"),
            vec![file_id.clone()]
        );
        assert_eq!(
            store
                .attachments_for_message(&message_id)
                .await
                .expect("files")[0]
                .name,
            "brief.txt"
        );
        assert!(matches!(
            store
                .insert_message_with_attachments(
                    "device-1",
                    "client-attachment",
                    "Review this file",
                    "hash",
                    "conversation-1",
                    std::slice::from_ref(&file_id),
                    "later",
                )
                .await
                .expect("replay"),
            MessageInsert::Existing(_)
        ));
        assert_eq!(
            store
                .insert_message_with_attachments(
                    "device-1",
                    "client-attachment",
                    "Review this file",
                    "hash",
                    "conversation-1",
                    &[],
                    "later",
                )
                .await
                .expect("conflict"),
            MessageInsert::Conflict
        );
        assert!(matches!(
            store
                .insert_message_with_attachments(
                    "device-1",
                    "client-missing-attachment",
                    "Review missing",
                    "hash-2",
                    "conversation-1",
                    &["550e8400-e29b-41d4-a716-446655440001".to_owned()],
                    "now",
                )
                .await
                .expect("missing attachment"),
            MessageInsert::Conflict
        ));
    }

    #[tokio::test]
    async fn search_indexes_bots_messages_assistant_text_and_files() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_bot(
                "researcher",
                "Research Bot",
                "Source checker",
                "Find reliable sources.",
                "/tmp/wonder-researcher",
                "wonder_bot_researcher",
                None,
                None,
                "now",
            )
            .await
            .expect("bot");
        store
            .upsert_bot(
                "archived-researcher",
                "Archived Sources Bot",
                "Old source checker",
                "Archived launch sources.",
                "/tmp/wonder-archived",
                "wonder_bot_archived",
                None,
                None,
                "now",
            )
            .await
            .expect("archived bot");
        store
            .set_bot_archived("archived-researcher", true)
            .await
            .expect("archive")
            .expect("archived bot");
        store
            .create_conversation("conversation-search", "researcher", "Launch notes", "now")
            .await
            .expect("conversation");
        store
            .create_channel(
                "channel-search",
                "conversation-channel-search",
                "Launch team",
                Some("Coordinate launch sources."),
                "researcher",
                &[("researcher", "coordinator")],
                "2026-09-01T09:59:00Z",
            )
            .await
            .expect("channel");
        store
            .upsert_owner_device("device-1", "Search test", "{}", "now")
            .await
            .expect("device");
        store
            .insert_message(
                "device-1",
                "client-search",
                "Compare the launch sources",
                "hash-search",
                "conversation-search",
                "2026-09-01T10:00:00Z",
            )
            .await
            .expect("message");
        store
            .upsert_conversation_file(
                "file-search",
                "conversation-search",
                "attachment",
                "launch-sources.pdf",
                Some("application/pdf"),
                Some(12),
                Some(&"a".repeat(64)),
                Some(".wonder/attachments/file-search"),
                "available",
                None,
                None,
                None,
                "2026-09-01T10:01:00Z",
            )
            .await
            .expect("file");
        store
            .append_assistant_delta(
                "conversation-search",
                "thread-search",
                "turn-search",
                "item-search",
                "The launch sources are ready.",
                "2026-09-01T10:02:00Z",
            )
            .await
            .expect("assistant");

        let source_results = store.search("sources", 20).await.expect("search");
        assert!(source_results.iter().any(|result| result.kind == "message"));
        assert!(source_results
            .iter()
            .any(|result| result.kind == "assistant_message"));
        assert!(source_results.iter().any(|result| result.kind == "file"));
        assert_eq!(
            store
                .search("Launch team", 20)
                .await
                .expect("channel search")
                .iter()
                .find(|result| result.kind == "channel")
                .map(|result| result.id.as_str()),
            Some("channel-search")
        );
        assert_eq!(
            store.search("Research Bot", 20).await.expect("bot search")[0].kind,
            "bot"
        );
        assert!(store
            .search("Archived Sources Bot", 20)
            .await
            .expect("archived search")
            .is_empty());
        assert!(store.search("", 20).await.expect("empty search").is_empty());
    }

    #[tokio::test]
    async fn channels_persist_topology_and_protect_the_coordinator() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        for (id, name) in [("coordinator", "Coordinator"), ("worker", "Worker")] {
            store
                .upsert_bot(
                    id,
                    name,
                    "Channel Bot",
                    "Coordinate bounded work.",
                    "/tmp/wonder-channel",
                    "wonder_bot_channel",
                    None,
                    None,
                    "2026-09-01T10:00:00Z",
                )
                .await
                .expect("Bot");
        }
        let channel = store
            .create_channel(
                "channel-1",
                "conversation-channel-1",
                "Launch team",
                Some("Coordinate the launch."),
                "coordinator",
                &[("coordinator", "coordinator"), ("worker", "worker")],
                "2026-09-01T10:01:00Z",
            )
            .await
            .expect("channel");
        assert_eq!(channel.name, "Launch team");
        assert_eq!(channel.members.len(), 2);
        assert_eq!(channel.members[0].role, "coordinator");
        assert_eq!(channel.members[1].bot_id, "worker");
        assert!(!store
            .remove_channel_member("channel-1", "coordinator")
            .await
            .expect("coordinator removal"));
        assert!(store
            .update_channel(
                "channel-1",
                Some("Launch crew"),
                Some(Some("Updated objective")),
                Some(true),
                "2026-09-01T10:02:00Z",
            )
            .await
            .expect("update"));
        let updated = store
            .channel("channel-1")
            .await
            .expect("load")
            .expect("channel");
        assert_eq!(updated.name, "Launch crew");
        assert_eq!(updated.description.as_deref(), Some("Updated objective"));
        assert!(updated.is_archived);
        assert_eq!(store.list_channels().await.expect("list").len(), 1);
    }

    #[tokio::test]
    async fn group_snapshot_read_fence_preserves_later_replies() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .unwrap();
        store.start_event_epoch("group-epoch").await.unwrap();
        store
            .upsert_owner_device("owner", "Owner", "{}", "now")
            .await
            .unwrap();
        store
            .upsert_bot(
                "coordinator",
                "Coordinator",
                "Bot",
                "Work",
                "/tmp/group",
                "role",
                None,
                None,
                "now",
            )
            .await
            .unwrap();
        store
            .create_channel(
                "group",
                "group-chat",
                "Group",
                None,
                "coordinator",
                &[("coordinator", "coordinator")],
                "now",
            )
            .await
            .unwrap();
        async fn reply(store: &Store, id: &str, kind: &str) {
            let MessageInsert::Inserted(message) = store
                .insert_message("owner", id, id, &"a".repeat(64), "group-chat", "now")
                .await
                .unwrap()
            else {
                panic!("new message");
            };
            store
                .add_channel_message(NewChannelMessage {
                    channel_id: "group",
                    message_id: &message.id,
                    author_kind: kind,
                    author_bot_id: Some("coordinator"),
                    phase: "direct",
                    created_at: "now",
                    presentation_kind: "message",
                    outcome: None,
                    retryable: false,
                })
                .await
                .unwrap();
        }
        reply(&store, "user-message", "user").await;
        assert!(!store.channel("group").await.unwrap().unwrap().has_unread);
        reply(&store, "first-reply", "coordinator").await;
        let visible = store.channel("group").await.unwrap().unwrap();
        assert!(visible.has_unread);
        assert_eq!(visible.host_epoch.as_deref(), Some("group-epoch"));
        assert_eq!(visible.messages.len(), 2);
        reply(&store, "later-reply", "member").await;
        assert!(!store
            .acknowledge_conversation_read(
                "group-chat",
                "group-epoch",
                visible.last_sequence.unwrap(),
                "now"
            )
            .await
            .unwrap());
        let latest = store.channel("group").await.unwrap().unwrap();
        assert!(latest.has_unread);
        assert_eq!(latest.messages.len(), 3);
        assert!(store
            .acknowledge_conversation_read(
                "group-chat",
                "group-epoch",
                latest.last_sequence.unwrap(),
                "now"
            )
            .await
            .unwrap());
        assert!(!store.channel("group").await.unwrap().unwrap().has_unread);
        reply(&store, "after-read", "coordinator").await;
        assert!(store.channel("group").await.unwrap().unwrap().has_unread);
    }

    #[tokio::test]
    async fn channel_orchestration_claim_is_single_use() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Test browser", "{}", "now")
            .await
            .expect("device");
        store
            .upsert_bot(
                "coordinator",
                "Coordinator",
                "Channel Bot",
                "Coordinate bounded work.",
                "/tmp/wonder-channel",
                "wonder_bot_channel",
                None,
                None,
                "now",
            )
            .await
            .expect("Bot");
        store
            .create_channel(
                "channel-claim",
                "conversation-channel-claim",
                "Launch team",
                None,
                "coordinator",
                &[("coordinator", "coordinator")],
                "now",
            )
            .await
            .expect("channel");
        let message = match store
            .insert_message(
                "device-1",
                "client-1",
                "Launch update",
                &"a".repeat(64),
                "conversation-channel-claim",
                "now",
            )
            .await
            .expect("message")
        {
            MessageInsert::Inserted(message) => message,
            _ => panic!("message should be inserted"),
        };
        store
            .add_channel_message(NewChannelMessage {
                channel_id: "channel-claim",
                message_id: &message.id,
                author_kind: "user",
                author_bot_id: None,
                phase: "user",
                created_at: "now",
                presentation_kind: "message",
                outcome: Some("completed"),
                retryable: false,
            })
            .await
            .expect("channel message");
        assert!(store
            .claim_channel_orchestration("channel-claim", &message.id)
            .await
            .expect("first claim"));
        assert!(!store
            .claim_channel_orchestration("channel-claim", &message.id)
            .await
            .expect("second claim"));
    }

    #[tokio::test]
    async fn approval_resolution_is_single_use_and_retryable_after_response_failure() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .insert_pending_approval(
                "42",
                "item/commandExecution/requestApproval",
                r#"{"availableDecisions":["accept","decline"]}"#,
                "now",
            )
            .await
            .expect("approval");
        let first = store
            .begin_approval_resolution("42")
            .await
            .expect("begin")
            .expect("pending approval");
        assert_eq!(first.state, "resolving");
        assert!(store
            .begin_approval_resolution("42")
            .await
            .expect("second begin")
            .is_none());
        store.reset_approval_resolution("42").await.expect("reset");
        assert!(store
            .begin_approval_resolution("42")
            .await
            .expect("retry begin")
            .is_some());
        store
            .finish_approval_resolution("42", "accept", "later")
            .await
            .expect("finish");
        store
            .insert_pending_approval(
                "42",
                "item/commandExecution/requestApproval",
                "{}",
                "replayed",
            )
            .await
            .expect("replay");
        assert!(
            store
                .list_pending_approvals()
                .await
                .expect("approvals")
                .is_empty(),
            "a replay must not reopen an owner-resolved request"
        );

        store
            .insert_pending_approval(
                "runtime-2:42",
                "item/tool/call",
                r#"{"threadId":"thread-new","turnId":"turn-new","itemId":"item-new","tool":"wonder_computer_use"}"#,
                "newer",
            )
            .await
            .expect("reopened approval");
        let reopened = store
            .list_pending_approvals()
            .await
            .expect("pending approvals")
            .into_iter()
            .find(|approval| approval.approval_id == "runtime-2:42")
            .expect("reopened approval is pending");
        assert_eq!(reopened.method, "item/tool/call");
        assert_eq!(reopened.thread_id, "thread-new");
        assert_eq!(reopened.turn_id, "turn-new");
        assert_eq!(reopened.item_id, "item-new");
        assert_eq!(reopened.state, "pending");
        assert_ne!(reopened.action_nonce, first.action_nonce);
        store
            .begin_approval_resolution("runtime-2:42")
            .await
            .expect("begin reopened approval")
            .expect("reopened approval is resolvable");
        store
            .finish_approval_resolution("runtime-2:42", "respond", "newer-later")
            .await
            .expect("finish reopened approval");
        store
            .insert_pending_approval(
                "43",
                "item/fileChange/requestApproval",
                r#"{"availableDecisions":["accept","decline"]}"#,
                "now",
            )
            .await
            .expect("second approval");
        assert!(store
            .resolve_approval_by_server_request_id("43", "app_server_resolved", "later")
            .await
            .expect("server resolution"));
        assert!(store
            .begin_approval_resolution("42")
            .await
            .expect("resolved begin")
            .is_none());
    }

    #[tokio::test]
    async fn automation_records_are_durable_and_pauseable() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_bot(
                "default",
                "Default Bot",
                "General assistant",
                "Keep work focused.",
                "/tmp/wonder-default",
                "wonder_bot_default",
                None,
                None,
                "now",
            )
            .await
            .expect("bot");
        let automation = store
            .insert_automation(
                "automation-1",
                "Daily brief",
                "standalone",
                "default",
                None,
                "Prepare a short brief.",
                "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
                "America/New_York",
                "active",
                "all_runs",
                None,
                None,
                None,
                "now",
            )
            .await
            .expect("automation");
        assert_eq!(automation.status, "active");
        assert!(store
            .set_automation_status("automation-1", "paused", "later")
            .await
            .expect("pause"));
        assert_eq!(
            store.list_automations().await.expect("list")[0].status,
            "paused"
        );
        assert!(store
            .delete_automation("automation-1")
            .await
            .expect("delete"));
    }

    #[tokio::test]
    async fn automation_run_claim_is_idempotent_and_linkable() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_bot(
                "default",
                "Default Bot",
                "General assistant",
                "Keep work focused.",
                "/tmp/wonder-default",
                "wonder_bot_default",
                None,
                None,
                "now",
            )
            .await
            .expect("bot");
        store
            .insert_automation(
                "automation-1",
                "Daily brief",
                "standalone",
                "default",
                None,
                "Prepare a short brief.",
                "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
                "UTC",
                "active",
                "all_runs",
                None,
                None,
                None,
                "now",
            )
            .await
            .expect("automation");
        assert!(store
            .claim_automation_run("run-1", "automation-1", "2026-09-01T09:00:00Z", "now")
            .await
            .expect("claim"));
        assert!(!store
            .claim_automation_run("run-2", "automation-1", "2026-09-01T09:00:00Z", "later")
            .await
            .expect("duplicate claim"));
        store
            .set_automation_run_message_id("run-1", "message-1")
            .await
            .expect("message link");
        store
            .finish_automation_run("run-1", "completed", "finished", None, Some("message-1"))
            .await
            .expect("finish");
        assert_eq!(
            store
                .automation_run_for_message("message-1")
                .await
                .expect("lookup")
                .expect("run")
                .status,
            "completed"
        );
    }

    #[tokio::test]
    async fn conversation_controls_and_files_are_durable() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_conversation_settings(
                "default",
                Some("model-a"),
                Some("high"),
                Some("fast"),
                Some("wonder_bot_default"),
                "now",
            )
            .await
            .expect("settings");
        store
            .upsert_conversation_file(
                "file-1",
                "default",
                "file_change",
                "main.rs",
                None,
                None,
                None,
                Some("src/main.rs"),
                "update",
                Some(4),
                Some(2),
                Some("item-1"),
                "now",
            )
            .await
            .expect("file");
        assert_eq!(
            store
                .conversation_settings("default")
                .await
                .expect("settings lookup")
                .expect("settings")
                .service_tier
                .as_deref(),
            Some("fast")
        );
        let file = store
            .list_conversation_files("default")
            .await
            .expect("files")
            .pop()
            .expect("file row");
        assert_eq!(file.relative_path.as_deref(), Some("src/main.rs"));
        assert_eq!(file.additions, Some(4));
    }

    #[tokio::test]
    async fn workspace_artifact_metadata_round_trips_without_a_new_schema() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        let sha256 = "a".repeat(64);
        store
            .upsert_conversation_file(
                "artifact-1",
                "conversation-1",
                "artifact",
                "report.pdf",
                Some("application/pdf"),
                Some(12),
                Some(&sha256),
                Some("reports/report.pdf"),
                "available",
                None,
                None,
                Some("item-1"),
                "now",
            )
            .await
            .expect("artifact metadata");
        let artifact = store
            .list_conversation_files("conversation-1")
            .await
            .expect("artifact list")
            .pop()
            .expect("artifact row");
        assert_eq!(artifact.kind, "artifact");
        assert_eq!(artifact.mime_type.as_deref(), Some("application/pdf"));
        assert_eq!(artifact.byte_size, Some(12));
        assert_eq!(artifact.sha256.as_deref(), Some(sha256.as_str()));
        assert_eq!(
            artifact.relative_path.as_deref(),
            Some("reports/report.pdf")
        );
        assert_eq!(artifact.source_id.as_deref(), Some("item-1"));
    }

    #[tokio::test]
    async fn conversation_metadata_supports_lifecycle_and_inbox_ordering() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_bot(
                "default",
                "Default Bot",
                "General assistant",
                "Help the owner.",
                "/tmp/wonder-default",
                "wonder_bot_default",
                None,
                None,
                "2026-09-01T09:00:00Z",
            )
            .await
            .expect("bot");
        store
            .create_conversation(
                "conversation-1",
                "default",
                "Launch notes",
                "2026-09-01T10:00:00Z",
            )
            .await
            .expect("conversation");
        assert_eq!(
            store
                .conversation("conversation-1")
                .await
                .expect("lookup")
                .expect("conversation")
                .title,
            "Launch notes"
        );
        assert!(store
            .update_conversation(
                "conversation-1",
                Some("Pinned launch notes"),
                Some(false),
                Some(true),
                Some(true),
                "2026-09-01T10:01:00Z",
            )
            .await
            .expect("update"));
        let summary = store
            .list_conversation_summaries()
            .await
            .expect("summaries")
            .into_iter()
            .find(|summary| summary.conversation_id == "conversation-1")
            .expect("summary");
        assert_eq!(summary.title, "Pinned launch notes");
        assert!(summary.is_pinned);
        assert!(summary.has_unread);
        assert!(!summary.is_archived);
    }

    #[tokio::test]
    async fn assistant_projection_is_idempotent_and_survives_reopen() {
        let directory = tempfile::tempdir().expect("temporary store directory");
        let database_url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("wonder.sqlite3").display()
        );
        let store = Store::connect(&database_url).await.expect("store");
        let first = store
            .upsert_assistant_delta(
                "conversation-1",
                "thread-1",
                "turn-1",
                "item-1",
                "hello",
                "notification-1",
                "2026-09-01T10:00:00Z",
            )
            .await
            .expect("first delta");
        let replay = store
            .upsert_assistant_delta(
                "conversation-1",
                "thread-1",
                "turn-1",
                "item-1",
                "hello",
                "notification-1",
                "2026-09-01T10:00:01Z",
            )
            .await
            .expect("replayed delta");
        let distinct = store
            .upsert_assistant_delta(
                "conversation-1",
                "thread-1",
                "turn-1",
                "item-1",
                "hello",
                "notification-2",
                "2026-09-01T10:00:01.500Z",
            )
            .await
            .expect("distinct delta");
        assert_eq!(first.text, "hello");
        assert_eq!(replay.text, "hello");
        assert_eq!(distinct.text, "hellohello");
        store
            .complete_assistant_message(
                "conversation-1",
                "thread-1",
                "turn-1",
                "item-1",
                "hello world",
                "2026-09-01T10:00:02Z",
            )
            .await
            .expect("completion")
            .expect("active completion");
        assert!(store
            .complete_assistant_message(
                "conversation-1",
                "thread-1",
                "turn-1",
                "item-1",
                "late completion must not overwrite fallback text",
                "2026-09-01T10:00:02.500Z",
            )
            .await
            .expect("late completion")
            .is_none());
        let late_replay = store
            .upsert_assistant_delta(
                "conversation-1",
                "thread-1",
                "turn-1",
                "item-1",
                "corrupting replay",
                "notification-after-completion",
                "2026-09-01T10:00:03Z",
            )
            .await
            .expect("late replay");
        // App Server completion text is authoritative. A repeated or late
        // chunk must never mutate the completed message, even when no
        // sequence identity was available for the chunk.
        assert_eq!(late_replay.text, "hello world");
        drop(store);

        let reopened = Store::connect(&database_url).await.expect("reopen");
        let messages = reopened
            .assistant_messages_for_conversation("conversation-1")
            .await
            .expect("assistant messages");
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].text, "hello world");
        assert_eq!(messages[0].state, "completed");
    }

    #[tokio::test]
    async fn completing_codex_turn_completes_active_assistant_rows_with_context() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_assistant_delta(
                "conversation-1",
                "thread-1",
                "turn-1",
                "item-1",
                "hello",
                "notification-1",
                "2026-09-01T10:00:00Z",
            )
            .await
            .expect("first delta");
        store
            .upsert_assistant_delta(
                "conversation-1",
                "thread-1",
                "turn-1",
                "item-2",
                "world",
                "notification-2",
                "2026-09-01T10:00:01Z",
            )
            .await
            .expect("second delta");
        store
            .upsert_assistant_delta(
                "conversation-2",
                "thread-2",
                "turn-1",
                "item-3",
                "other",
                "notification-3",
                "2026-09-01T10:00:02Z",
            )
            .await
            .expect("other turn delta");

        let completed = store
            .complete_assistant_messages_for_codex_thread_and_turn(
                "thread-1",
                "turn-1",
                "2026-09-01T10:00:03Z",
            )
            .await
            .expect("complete assistant turn");
        assert_eq!(completed.len(), 2);
        assert_eq!(completed[0].conversation_id, "conversation-1");
        assert_eq!(completed[0].codex_thread_id, "thread-1");
        assert_eq!(completed[0].codex_turn_id, "turn-1");
        assert_eq!(completed[0].item_id, "item-1");
        assert_eq!(completed[0].text, "hello");
        assert_eq!(completed[0].state, "completed");
        assert_eq!(completed[0].updated_at, "2026-09-01T10:00:03Z");
        assert!(store
            .complete_assistant_messages_for_codex_thread_and_turn(
                "thread-1",
                "turn-1",
                "2026-09-01T10:00:04Z",
            )
            .await
            .expect("ignore completed assistant turn")
            .is_empty());
        assert!(store
            .assistant_messages_for_conversation("conversation-2")
            .await
            .expect("other turn lookup")
            .iter()
            .all(|message| message.state == "streaming"));
        assert!(store
            .complete_assistant_messages_for_codex_thread_and_turn(
                "thread-1",
                "turn-1",
                "2026-09-01T10:00:04Z",
            )
            .await
            .expect("ignore completed assistant thread")
            .is_empty());
    }

    #[tokio::test]
    async fn app_server_notification_receipt_is_durable_and_single_use() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        assert!(store
            .claim_app_server_notification("notification-1", "now")
            .await
            .expect("first receipt"));
        assert!(!store
            .claim_app_server_notification("notification-1", "later")
            .await
            .expect("replayed receipt"));
    }

    #[tokio::test]
    async fn app_server_notification_receipt_can_be_released_for_retry() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        assert!(store
            .claim_app_server_notification("notification-1", "now")
            .await
            .expect("first receipt"));
        store
            .release_app_server_notification("notification-1")
            .await
            .expect("release receipt");
        assert!(store
            .claim_app_server_notification("notification-1", "retry")
            .await
            .expect("retry receipt"));
    }

    #[tokio::test]
    async fn mapped_assistant_projection_failure_preserves_full_notification_for_retry() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        let notification = serde_json::json!({
            "method": "item/agentMessage/delta",
            "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "item": {"id": "item-1"},
                "delta": {"text": "retry me"}
            }
        });
        let params = notification.get("params").expect("params");
        assert!(store
            .enqueue_pending_app_server_notification(
                "pending-1",
                None,
                "item/agentMessage/delta",
                Some("thread-1"),
                Some("turn-1"),
                Some("item-1"),
                &notification.to_string(),
                &params.to_string(),
                "now",
            )
            .await
            .expect("queue projection failure"));

        let pending = store
            .pending_app_server_notifications_for_turn("turn-1")
            .await
            .expect("pending notification");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].notification_json, notification.to_string());
        assert_eq!(pending[0].identity_key, None);
    }

    #[tokio::test]
    async fn failed_retry_enqueue_leaves_claimed_notification_receipt_intact() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        assert!(store
            .claim_app_server_notification("notification-1", "now")
            .await
            .expect("claim receipt"));
        sqlx::query("DROP TABLE pending_app_server_notifications")
            .execute(&store.pool)
            .await
            .expect("simulate retry enqueue failure");
        assert!(store
            .enqueue_pending_app_server_notification(
                "pending-1",
                Some("notification-1"),
                "item/agentMessage/delta",
                Some("thread-1"),
                Some("turn-1"),
                Some("item-1"),
                r#"{"method":"item/agentMessage/delta"}"#,
                r#"{"turnId":"turn-1"}"#,
                "later",
            )
            .await
            .is_err());
        assert!(!store
            .claim_app_server_notification("notification-1", "retry")
            .await
            .expect("receipt remains claimed"));
    }

    #[tokio::test]
    async fn message_idempotency_is_bound_to_its_conversation() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Chrome", "{}", "now")
            .await
            .expect("device");
        let first = store
            .insert_message(
                "device-1",
                "client-1",
                "body",
                "hash",
                "conversation-1",
                "now",
            )
            .await
            .expect("first message");
        assert!(matches!(first, MessageInsert::Inserted(_)));
        let other_route = store
            .insert_message(
                "device-1",
                "client-1",
                "body",
                "hash",
                "conversation-2",
                "later",
            )
            .await
            .expect("other route replay");
        assert_eq!(other_route, MessageInsert::Conflict);
    }

    #[tokio::test]
    async fn active_app_server_turns_are_detected_until_completed() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Chrome", "{}", "now")
            .await
            .expect("device");
        let message = match store
            .insert_message(
                "device-1",
                "client-1",
                "body",
                "hash",
                "conversation-1",
                "now",
            )
            .await
            .expect("message")
        {
            MessageInsert::Inserted(message) => message,
            _ => panic!("expected inserted message"),
        };
        assert!(!store
            .has_active_app_server_turns()
            .await
            .expect("no active turns"));
        store
            .update_message_delivery(
                &message.id,
                "accepted_by_codex",
                Some("thread-1"),
                Some("turn-1"),
            )
            .await
            .expect("active delivery");
        assert!(store
            .has_active_app_server_turns()
            .await
            .expect("active turn"));
        store
            .update_message_delivery(&message.id, "completed", None, None)
            .await
            .expect("completed delivery");
        assert!(!store
            .has_active_app_server_turns()
            .await
            .expect("completed turn"));
    }

    #[tokio::test]
    async fn orphaned_app_server_turns_remain_uncertain() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("device-1", "Chrome", "{}", "now")
            .await
            .expect("device");
        let message = match store
            .insert_message(
                "device-1",
                "client-1",
                "body",
                "hash",
                "conversation-1",
                "now",
            )
            .await
            .expect("message")
        {
            MessageInsert::Inserted(message) => message,
            _ => panic!("expected inserted message"),
        };
        store
            .update_message_delivery(&message.id, "streaming", Some("thread-1"), Some("turn-1"))
            .await
            .expect("active delivery");
        store
            .upsert_assistant_delta(
                "conversation-1",
                "thread-1",
                "turn-1",
                "item-1",
                "partial",
                "delta-1",
                "now",
            )
            .await
            .expect("assistant projection");

        assert_eq!(
            store
                .recover_orphaned_app_server_turns()
                .await
                .expect("recovery"),
            1
        );
        assert!(!store
            .has_active_app_server_turns()
            .await
            .expect("no orphaned turns"));
        assert_eq!(
            store
                .message_for_codex_turn("turn-1")
                .await
                .expect("message lookup")
                .expect("message")
                .state,
            "uncertain"
        );
        assert_eq!(
            store
                .assistant_messages_for_conversation("conversation-1")
                .await
                .expect("assistant lookup")
                .pop()
                .expect("assistant")
                .state,
            "failed"
        );
    }

    #[tokio::test]
    async fn workspace_reset_preserves_one_device_and_removes_user_data() {
        let store = Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("in-memory store");
        store
            .upsert_owner_device("keep", "Current", "{}", "now")
            .await
            .expect("keep device");
        store
            .upsert_owner_device("revoke", "Old", "{}", "now")
            .await
            .expect("old device");
        store
            .upsert_bot(
                "bot-1",
                "Bot One",
                "Research",
                "Research.",
                "/tmp/wonder-bot-1",
                "wonder_bot_default",
                None,
                None,
                "now",
            )
            .await
            .expect("bot");
        store
            .ensure_bot_workspace("bot-1", "Bot One", "now")
            .await
            .expect("workspace");
        let parent = store.bot("bot-1").await.unwrap().unwrap();
        let parent_conversation = parent.conversation_id.unwrap();
        store
            .set_conversation_thread(&parent_conversation, "reset-parent-thread", None, "now")
            .await
            .unwrap();
        store
            .register_subagent_ownership(
                "reset-child-conversation",
                &parent_conversation,
                "reset-child-thread",
                "reset-parent-thread",
                "bot-1",
                "Reset child",
                Some("Reset child"),
                None,
                None,
                r#"{"subAgent":{"thread_spawn":{"parent_thread_id":"reset-parent-thread","depth":1}}}"#,
                Some("reset-runtime"),
                Some(true),
                "idle",
                None,
                "now",
            )
            .await
            .unwrap();
        let reset = store.reset_workspace("keep", "reset").await.expect("reset");
        assert_eq!(reset.workspace_paths, vec!["/tmp/wonder-bot-1"]);
        assert_eq!(reset.revoked_device_ids, vec!["revoke"]);
        assert_eq!(store.list_bots().await.expect("bots").len(), 0);
        assert!(store
            .subagent_ownership_for_thread("reset-child-thread")
            .await
            .expect("ownership lookup")
            .is_none());
        assert!(sqlx::query(
            "SELECT 1 FROM conversation_metadata WHERE id='reset-child-conversation'"
        )
        .fetch_optional(&store.pool)
        .await
        .expect("child metadata lookup")
        .is_none());
        assert_eq!(store.list_owner_devices().await.expect("devices").len(), 2);
        let devices = store.list_owner_devices().await.expect("devices");
        assert!(devices
            .iter()
            .any(|device| device.id == "keep" && device.revoked_at.is_none()));
        assert!(devices
            .iter()
            .any(|device| device.id == "revoke" && device.revoked_at.as_deref() == Some("reset")));
    }

    #[test]
    fn strip_taught_task_sections_preserves_other_prompt_sections() {
        let prompt = "Base instructions.\n\n## Taught task: First\nWhen asked to do first, follow these instructions:\nFirst task.\n\n## Keep this\nKeep this instruction.\n\n## Taught task: Second\nWhen asked to do second, follow these instructions:\nSecond task.\n\n## Final instruction\nKeep this final instruction.";
        assert_eq!(
            strip_taught_task_sections(prompt),
            "Base instructions.\n\n## Keep this\nKeep this instruction.\n\n## Final instruction\nKeep this final instruction."
        );
        assert_eq!(
            strip_taught_task_sections("No taught tasks here."),
            "No taught tasks here."
        );
    }

    #[tokio::test]
    async fn store_initialization_cleans_taught_tasks_and_uses_role_fallback() {
        let directory = tempfile::tempdir().expect("temporary store directory");
        let database_url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("wonder.sqlite3").display()
        );
        let store = Store::connect(&database_url).await.expect("store");
        store
            .upsert_bot(
                "bot-clean",
                "Clean Bot",
                "Research partner",
                "Base instructions.\n\n## Taught task: Research\nWhen asked to research, follow these instructions:\nSearch carefully.",
                "/tmp/bot-clean",
                "wonder_bot_clean",
                None,
                None,
                "now",
            )
            .await
            .expect("clean bot");
        store
            .upsert_bot(
                "bot-fallback",
                "Fallback Bot",
                "Planning partner",
                "## Taught task: Plan\nWhen asked to plan, follow these instructions:\nMake a plan.",
                "/tmp/bot-fallback",
                "wonder_bot_fallback",
                None,
                None,
                "now",
            )
            .await
            .expect("fallback bot");

        let reopened = Store::connect(&database_url).await.expect("reopened store");
        let bots = reopened.list_bots().await.expect("bots");
        assert_eq!(
            bots.iter()
                .find(|bot| bot.id == "bot-clean")
                .map(|bot| bot.system_prompt.as_str()),
            Some("Base instructions.")
        );
        assert_eq!(
            bots.iter()
                .find(|bot| bot.id == "bot-fallback")
                .map(|bot| bot.system_prompt.as_str()),
            Some("Planning partner")
        );

        let reopened_again = Store::connect(&database_url)
            .await
            .expect("reopened store again");
        let unchanged = reopened_again
            .bot("bot-clean")
            .await
            .expect("clean bot lookup")
            .expect("clean bot");
        assert_eq!(unchanged.system_prompt, "Base instructions.");
    }

    #[tokio::test]
    async fn science_avatar_migration_is_persistent_and_forward_compatible() {
        let directory = tempfile::tempdir().expect("temporary store directory");
        let database_url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("wonder.sqlite3").display()
        );
        let store = Store::connect(&database_url).await.expect("store");
        for column in ["avatar_shape", "avatar_palette", "avatar_legacy_color"] {
            let exists: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM pragma_table_info('bots') WHERE name=?")
                    .bind(column)
                    .fetch_one(&store.pool)
                    .await
                    .expect("migration column");
            assert_eq!(exists, 1, "missing migration column {column}");
        }
        store
            .upsert_bot(
                "new-avatar",
                "New Avatar",
                "Helper",
                "Help",
                "/tmp/new-avatar",
                "profile",
                None,
                None,
                "now",
            )
            .await
            .expect("new avatar bot");
        let new_avatar = store.bot("new-avatar").await.unwrap().unwrap();
        assert_eq!(new_avatar.avatar_shape.as_deref(), Some("sun"));
        assert_eq!(new_avatar.avatar_palette.as_deref(), Some("amber"));
        assert_eq!(new_avatar.avatar_color.as_deref(), Some("#ffb51c"));

        store
            .upsert_bot(
                "legacy-avatar",
                "Legacy",
                "Helper",
                "Help",
                "/tmp/legacy-avatar",
                "profile",
                None,
                None,
                "now",
            )
            .await
            .expect("legacy bot");
        sqlx::query(
            "UPDATE bots SET avatar_color='#167a7a', avatar_shape=NULL, avatar_palette=NULL WHERE id='legacy-avatar'",
        )
        .execute(&store.pool)
        .await
        .expect("legacy values");
        backfill_avatar_identity(&store.pool)
            .await
            .expect("backfill");
        let migrated = store.bot("legacy-avatar").await.unwrap().unwrap();
        assert_eq!(
            migrated.avatar_shape.as_deref(),
            Some(avatar::default_shape_for_identity("legacy-avatar"))
        );
        assert_eq!(migrated.avatar_palette.as_deref(), Some("teal"));
        assert_eq!(migrated.avatar_color.as_deref(), Some("#57b8b3"));
        assert_eq!(migrated.avatar_legacy_color.as_deref(), Some("#167a7a"));
        let shape = migrated.avatar_shape.clone();
        store
            .update_bot(
                "legacy-avatar",
                Some("Renamed"),
                None,
                None,
                None,
                None,
                None,
            )
            .await
            .expect("rename");
        backfill_avatar_identity(&store.pool)
            .await
            .expect("backfill again");
        assert_eq!(
            store
                .bot("legacy-avatar")
                .await
                .unwrap()
                .unwrap()
                .avatar_shape,
            shape
        );
        drop(store);

        let reopened = Store::connect(&database_url).await.expect("reopened store");
        let renamed = reopened.bot("legacy-avatar").await.unwrap().unwrap();
        assert_eq!(renamed.name, "Renamed");
        assert_eq!(renamed.avatar_shape, shape);
        sqlx::query(
            "UPDATE bots SET avatar_shape='future-character', avatar_palette='future-palette', avatar_color='#123456', avatar_legacy_color=NULL WHERE id='legacy-avatar'",
        )
        .execute(&reopened.pool)
        .await
        .expect("future values");
        backfill_avatar_identity(&reopened.pool)
            .await
            .expect("future backfill");
        reopened
            .update_bot(
                "legacy-avatar",
                Some("Future Renamed"),
                None,
                None,
                None,
                None,
                None,
            )
            .await
            .expect("future rename");
        let future = reopened.bot("legacy-avatar").await.unwrap().unwrap();
        assert_eq!(future.name, "Future Renamed");
        assert_eq!(future.avatar_shape.as_deref(), Some("future-character"));
        assert_eq!(future.avatar_palette.as_deref(), Some("future-palette"));
        assert_eq!(future.avatar_color.as_deref(), Some("#123456"));
        assert!(future.avatar_legacy_color.is_none());
    }
}
