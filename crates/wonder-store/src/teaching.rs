use super::*;

pub const TEACHING_UNAVAILABLE: &str = "Live Mac teaching capture is unavailable on this host. Update Wonder when a supervised capture provider is available.";
pub const TEACHING_MAX_EVENTS: u64 = 20_000;
pub const TEACHING_MAX_EVIDENCE_BYTES: u64 = 50 * 1024 * 1024;
pub const TEACHING_EXPIRED_REASON: &str =
    "Teaching stopped because its maximum capture duration was reached.";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TeachingEventCreate {
    pub control_sequence: u64,
    pub action_index: u64,
    pub event_json: String,
    pub payload_bytes: u64,
    pub created_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredTeachingEvent {
    pub id: String,
    pub session_id: String,
    pub control_sequence: u64,
    pub action_index: u64,
    pub event_json: String,
    pub payload_bytes: u64,
    pub created_at: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TeachingCaptureAppendResult {
    NotRecording,
    Appended(u64),
    Duplicate,
    Interrupted,
    Expired,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TeachingSessionCreate {
    pub id: String,
    pub client_request_id: String,
    pub owner_device_id: String,
    pub host_installation_id: String,
    pub bot_id: String,
    pub conversation_id: String,
    pub computer_session_id: Option<String>,
    pub control_lease_id: Option<String>,
    pub state: String,
    pub capture_scope: String,
    pub capture_provider: String,
    pub outcome: String,
    pub failure_reason: Option<String>,
    pub now: String,
    pub expires_at: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredTeachingSession {
    pub id: String,
    pub client_request_id: String,
    pub owner_device_id: String,
    pub host_installation_id: String,
    pub bot_id: String,
    pub conversation_id: String,
    pub computer_session_id: Option<String>,
    pub control_lease_id: Option<String>,
    pub state: String,
    pub capture_scope: String,
    pub capture_provider: String,
    pub outcome: String,
    pub name: Option<String>,
    pub description: Option<String>,
    pub goal: Option<String>,
    pub input_schema_json: Option<String>,
    pub prerequisites: Option<String>,
    pub steps: Option<String>,
    pub result_checks: Option<String>,
    pub failure_reason: Option<String>,
    pub revision: u64,
    pub event_count: u64,
    pub evidence_bytes: u64,
    pub content_hash: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub expires_at: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TeachingReview {
    pub expected_revision: u64,
    pub name: String,
    pub description: String,
    pub goal: String,
    pub input_schema_json: String,
    pub prerequisites: String,
    pub steps: String,
    pub result_checks: String,
    pub content_hash: String,
    pub now: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredBotSkill {
    pub id: String,
    pub bot_id: String,
    pub slug: String,
    pub name: String,
    pub description: String,
    pub state: String,
    pub active_version: Option<u64>,
    pub skill_path: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredBotSkillVersion {
    pub id: String,
    pub skill_id: String,
    pub bot_id: String,
    pub version: u64,
    pub source_session_id: String,
    pub save_request_id: String,
    pub content_hash: String,
    pub skill_path: String,
    pub input_schema_json: String,
    pub verification_state: String,
    pub created_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NewSkillFixtureRun {
    pub id: String,
    pub client_request_id: String,
    pub owner_device_id: String,
    pub bot_id: String,
    pub skill_id: String,
    pub version: u64,
    pub content_hash: String,
    pub input_schema_hash: String,
    pub input_schema_json: String,
    pub inputs_json: String,
    pub working_directory: String,
    pub provider: String,
    pub execution_kind: String,
    pub status: String,
    pub verification_state: String,
    pub artifact_path: Option<String>,
    pub artifact_hash: Option<String>,
    pub artifact_bytes: u64,
    pub evidence_json: String,
    pub failure_reason: Option<String>,
    pub created_at: String,
    pub completed_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredSkillFixtureRun {
    pub id: String,
    pub client_request_id: String,
    pub owner_device_id: String,
    pub bot_id: String,
    pub skill_id: String,
    pub version: u64,
    pub content_hash: String,
    pub input_schema_hash: String,
    pub input_schema_json: String,
    pub inputs_json: String,
    pub working_directory: String,
    pub provider: String,
    pub execution_kind: String,
    pub status: String,
    pub verification_state: String,
    pub artifact_path: Option<String>,
    pub artifact_hash: Option<String>,
    pub artifact_bytes: u64,
    pub evidence_json: String,
    pub failure_reason: Option<String>,
    pub created_at: String,
    pub completed_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SkillFixtureRunReservation {
    pub run: StoredSkillFixtureRun,
    pub created: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SkillVersionReservation {
    pub version: StoredBotSkillVersion,
    pub created: bool,
}

fn teaching(row: &sqlx::sqlite::SqliteRow) -> StoredTeachingSession {
    StoredTeachingSession {
        id: row.get("id"),
        client_request_id: row.get("client_request_id"),
        owner_device_id: row.get("owner_device_id"),
        host_installation_id: row.get("host_installation_id"),
        bot_id: row.get("bot_id"),
        conversation_id: row.get("conversation_id"),
        computer_session_id: row.get("computer_session_id"),
        control_lease_id: row.get("control_lease_id"),
        state: row.get("state"),
        capture_scope: row.get("capture_scope"),
        capture_provider: row.get("capture_provider"),
        outcome: row.get("outcome"),
        name: row.get("name"),
        description: row.get("description"),
        goal: row.get("goal"),
        input_schema_json: row.get("input_schema_json"),
        prerequisites: row.get("prerequisites"),
        steps: row.get("steps"),
        result_checks: row.get("result_checks"),
        failure_reason: row.get("failure_reason"),
        revision: row.get::<i64, _>("revision") as u64,
        event_count: row.get::<i64, _>("event_count") as u64,
        evidence_bytes: row.get::<i64, _>("evidence_bytes") as u64,
        content_hash: row.get("content_hash"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        started_at: row.get("started_at"),
        ended_at: row.get("ended_at"),
        expires_at: row.get("expires_at"),
    }
}

fn teaching_event(row: &sqlx::sqlite::SqliteRow) -> StoredTeachingEvent {
    StoredTeachingEvent {
        id: row.get("id"),
        session_id: row.get("session_id"),
        control_sequence: row.get::<i64, _>("control_sequence") as u64,
        action_index: row.get::<i64, _>("action_index") as u64,
        event_json: row.get("event_json"),
        payload_bytes: row.get::<i64, _>("payload_bytes") as u64,
        created_at: row.get("created_at"),
    }
}

fn skill(row: &sqlx::sqlite::SqliteRow) -> StoredBotSkill {
    StoredBotSkill {
        id: row.get("id"),
        bot_id: row.get("bot_id"),
        slug: row.get("slug"),
        name: row.get("name"),
        description: row.get("description"),
        state: row.get("state"),
        active_version: row
            .get::<Option<i64>, _>("active_version")
            .map(|value| value as u64),
        skill_path: row.get("skill_path"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}

fn version(row: &sqlx::sqlite::SqliteRow) -> StoredBotSkillVersion {
    StoredBotSkillVersion {
        id: row.get("id"),
        skill_id: row.get("skill_id"),
        bot_id: row.get("bot_id"),
        version: row.get::<i64, _>("version") as u64,
        source_session_id: row.get("source_session_id"),
        save_request_id: row.get("save_request_id"),
        content_hash: row.get("content_hash"),
        skill_path: row.get("skill_path"),
        input_schema_json: row.get("input_schema_json"),
        verification_state: row.get("verification_state"),
        created_at: row.get("created_at"),
    }
}

fn fixture_run(row: &sqlx::sqlite::SqliteRow) -> StoredSkillFixtureRun {
    StoredSkillFixtureRun {
        id: row.get("id"),
        client_request_id: row.get("client_request_id"),
        owner_device_id: row.get("owner_device_id"),
        bot_id: row.get("bot_id"),
        skill_id: row.get("skill_id"),
        version: row.get::<i64, _>("version") as u64,
        content_hash: row.get("content_hash"),
        input_schema_hash: row.get("input_schema_hash"),
        input_schema_json: row.get("input_schema_json"),
        inputs_json: row.get("inputs_json"),
        working_directory: row.get("working_directory"),
        provider: row.get("provider"),
        execution_kind: row.get("execution_kind"),
        status: row.get("status"),
        verification_state: row.get("verification_state"),
        artifact_path: row.get("artifact_path"),
        artifact_hash: row.get("artifact_hash"),
        artifact_bytes: row.get::<i64, _>("artifact_bytes") as u64,
        evidence_json: row.get("evidence_json"),
        failure_reason: row.get("failure_reason"),
        created_at: row.get("created_at"),
        completed_at: row.get("completed_at"),
    }
}

impl Store {
    fn current_timestamp() -> String {
        time::OffsetDateTime::now_utc()
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_else(|_| "now".to_owned())
    }

    async fn reconcile_expired_teaching_sessions_at(&self, now: &str) -> Result<u64, sqlx::Error> {
        let result = sqlx::query(
            "UPDATE teaching_sessions SET state='expired',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE state='recording' AND expires_at IS NOT NULL AND julianday(expires_at) IS NOT NULL AND julianday(expires_at) <= julianday(?)",
        )
        .bind(TEACHING_EXPIRED_REASON)
        .bind(now)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }

    async fn teaching_session_at(
        &self,
        id: &str,
        now: &str,
    ) -> Result<Option<StoredTeachingSession>, sqlx::Error> {
        self.reconcile_expired_teaching_sessions_at(now).await?;
        let row = sqlx::query("SELECT id,client_request_id,owner_device_id,host_installation_id,bot_id,conversation_id,computer_session_id,control_lease_id,state,capture_scope,capture_provider,outcome,name,description,goal,input_schema_json,prerequisites,steps,result_checks,failure_reason,revision,event_count,evidence_bytes,content_hash,created_at,updated_at,started_at,ended_at,expires_at FROM teaching_sessions WHERE id=?")
            .bind(id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(teaching))
    }

    pub async fn teaching_session_by_request(
        &self,
        owner_device_id: &str,
        client_request_id: &str,
    ) -> Result<Option<StoredTeachingSession>, sqlx::Error> {
        let now = Self::current_timestamp();
        self.reconcile_expired_teaching_sessions_at(&now).await?;
        let row = sqlx::query("SELECT id,client_request_id,owner_device_id,host_installation_id,bot_id,conversation_id,computer_session_id,control_lease_id,state,capture_scope,capture_provider,outcome,name,description,goal,input_schema_json,prerequisites,steps,result_checks,failure_reason,revision,event_count,evidence_bytes,content_hash,created_at,updated_at,started_at,ended_at,expires_at FROM teaching_sessions WHERE owner_device_id=? AND client_request_id=?")
            .bind(owner_device_id)
            .bind(client_request_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(teaching))
    }

    pub async fn teaching_session(
        &self,
        id: &str,
    ) -> Result<Option<StoredTeachingSession>, sqlx::Error> {
        self.teaching_session_at(id, &Self::current_timestamp())
            .await
    }

    pub async fn insert_teaching_session(
        &self,
        request: &TeachingSessionCreate,
    ) -> Result<StoredTeachingSession, sqlx::Error> {
        self.reconcile_expired_teaching_sessions_at(&request.now)
            .await?;
        sqlx::query("INSERT INTO teaching_sessions(id,client_request_id,owner_device_id,host_installation_id,bot_id,conversation_id,computer_session_id,control_lease_id,state,capture_scope,capture_provider,outcome,failure_reason,created_at,updated_at,started_at,ended_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            .bind(&request.id)
            .bind(&request.client_request_id)
            .bind(&request.owner_device_id)
            .bind(&request.host_installation_id)
            .bind(&request.bot_id)
            .bind(&request.conversation_id)
            .bind(&request.computer_session_id)
            .bind(&request.control_lease_id)
            .bind(&request.state)
            .bind(&request.capture_scope)
            .bind(&request.capture_provider)
            .bind(&request.outcome)
            .bind(&request.failure_reason)
            .bind(&request.now)
            .bind(&request.now)
            .bind(if request.state == "recording" { Some(&request.now) } else { None })
            .bind(if matches!(request.state.as_str(), "unavailable" | "cancelled" | "interrupted" | "expired") { Some(&request.now) } else { None })
            .bind(&request.expires_at)
            .execute(&self.pool)
            .await?;
        self.teaching_session_at(&request.id, &request.now)
            .await?
            .ok_or(sqlx::Error::RowNotFound)
    }

    pub async fn teaching_events(
        &self,
        session_id: &str,
        limit: u64,
    ) -> Result<Vec<StoredTeachingEvent>, sqlx::Error> {
        let rows = sqlx::query("SELECT id,session_id,control_sequence,action_index,event_json,payload_bytes,created_at FROM teaching_events WHERE session_id=? ORDER BY control_sequence ASC, action_index ASC LIMIT ?")
            .bind(session_id)
            .bind(limit.min(2_000) as i64)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows.iter().map(teaching_event).collect())
    }

    pub async fn active_teaching_session_for_binding(
        &self,
        owner_device_id: &str,
        host_installation_id: &str,
        computer_session_id: &str,
        control_lease_id: &str,
    ) -> Result<Option<StoredTeachingSession>, sqlx::Error> {
        let row = sqlx::query("SELECT id,client_request_id,owner_device_id,host_installation_id,bot_id,conversation_id,computer_session_id,control_lease_id,state,capture_scope,capture_provider,outcome,name,description,goal,input_schema_json,prerequisites,steps,result_checks,failure_reason,revision,event_count,evidence_bytes,content_hash,created_at,updated_at,started_at,ended_at,expires_at FROM teaching_sessions WHERE owner_device_id=? AND host_installation_id=? AND computer_session_id=? AND control_lease_id=? AND state='recording' LIMIT 1")
            .bind(owner_device_id)
            .bind(host_installation_id)
            .bind(computer_session_id)
            .bind(control_lease_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(teaching))
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn append_teaching_events(
        &self,
        session_id: &str,
        owner_device_id: &str,
        host_installation_id: &str,
        computer_session_id: &str,
        control_lease_id: &str,
        events: &[TeachingEventCreate],
        now: &str,
    ) -> Result<TeachingCaptureAppendResult, sqlx::Error> {
        if events.is_empty() {
            return Ok(TeachingCaptureAppendResult::Duplicate);
        }
        let mut transaction = self.pool.begin().await?;
        let row = sqlx::query("SELECT id,client_request_id,owner_device_id,host_installation_id,bot_id,conversation_id,computer_session_id,control_lease_id,state,capture_scope,capture_provider,outcome,name,description,goal,input_schema_json,prerequisites,steps,result_checks,failure_reason,revision,event_count,evidence_bytes,content_hash,created_at,updated_at,started_at,ended_at,expires_at FROM teaching_sessions WHERE id=?")
            .bind(session_id)
            .fetch_optional(&mut *transaction)
            .await?;
        let Some(row) = row else {
            transaction.commit().await?;
            return Ok(TeachingCaptureAppendResult::NotRecording);
        };
        let current = teaching(&row);
        if current.owner_device_id != owner_device_id
            || current.host_installation_id != host_installation_id
            || current.computer_session_id.as_deref() != Some(computer_session_id)
            || current.control_lease_id.as_deref() != Some(control_lease_id)
        {
            transaction.commit().await?;
            return Ok(TeachingCaptureAppendResult::NotRecording);
        }
        if current.state == "expired" {
            transaction.commit().await?;
            return Ok(TeachingCaptureAppendResult::Expired);
        }
        if current.state != "recording" {
            transaction.commit().await?;
            return Ok(TeachingCaptureAppendResult::NotRecording);
        }
        if current
            .expires_at
            .as_deref()
            .is_some_and(|expires| compare_timestamps(expires, now) != Ordering::Greater)
        {
            sqlx::query("UPDATE teaching_sessions SET state='expired',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE id=? AND state='recording'")
                .bind(TEACHING_EXPIRED_REASON)
                .bind(now)
                .bind(now)
                .bind(session_id)
                .execute(&mut *transaction)
                .await?;
            transaction.commit().await?;
            return Ok(TeachingCaptureAppendResult::Expired);
        }

        let mut pending = Vec::new();
        for event in events {
            let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM teaching_events WHERE session_id=? AND control_sequence=? AND action_index=? )")
                .bind(session_id)
                .bind(event.control_sequence as i64)
                .bind(event.action_index as i64)
                .fetch_one(&mut *transaction)
                .await?;
            if !exists {
                pending.push(event);
            }
        }
        if pending.is_empty() {
            transaction.commit().await?;
            return Ok(TeachingCaptureAppendResult::Duplicate);
        }
        let pending_bytes: u64 = pending.iter().map(|event| event.payload_bytes).sum();
        if current.event_count.saturating_add(pending.len() as u64) > TEACHING_MAX_EVENTS
            || current.evidence_bytes.saturating_add(pending_bytes) > TEACHING_MAX_EVIDENCE_BYTES
        {
            sqlx::query("UPDATE teaching_sessions SET state='interrupted',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE id=? AND state='recording'")
                .bind("Teaching stopped because its bounded capture limit was reached.")
                .bind(now)
                .bind(now)
                .bind(session_id)
                .execute(&mut *transaction)
                .await?;
            transaction.commit().await?;
            return Ok(TeachingCaptureAppendResult::Interrupted);
        }
        for event in pending.iter() {
            sqlx::query("INSERT INTO teaching_events(id,session_id,control_sequence,action_index,event_json,payload_bytes,created_at) VALUES(?,?,?,?,?,?,?)")
                .bind(uuid::Uuid::new_v4().to_string())
                .bind(session_id)
                .bind(event.control_sequence as i64)
                .bind(event.action_index as i64)
                .bind(&event.event_json)
                .bind(event.payload_bytes as i64)
                .bind(&event.created_at)
                .execute(&mut *transaction)
                .await?;
        }
        sqlx::query("UPDATE teaching_sessions SET event_count=event_count+?,evidence_bytes=evidence_bytes+?,updated_at=? WHERE id=? AND state='recording'")
            .bind(pending.len() as i64)
            .bind(pending_bytes as i64)
            .bind(now)
            .bind(session_id)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        Ok(TeachingCaptureAppendResult::Appended(pending.len() as u64))
    }

    pub async fn interrupt_teaching_for_lease(
        &self,
        control_lease_id: &str,
        reason: &str,
        now: &str,
    ) -> Result<u64, sqlx::Error> {
        self.reconcile_expired_teaching_sessions_at(now).await?;
        let result = sqlx::query("UPDATE teaching_sessions SET state='interrupted',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE control_lease_id=? AND state='recording'")
            .bind(reason)
            .bind(now)
            .bind(now)
            .bind(control_lease_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected())
    }

    pub async fn interrupt_teaching_for_session(
        &self,
        computer_session_id: &str,
        reason: &str,
        now: &str,
    ) -> Result<u64, sqlx::Error> {
        self.reconcile_expired_teaching_sessions_at(now).await?;
        let result = sqlx::query("UPDATE teaching_sessions SET state='interrupted',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE computer_session_id=? AND state='recording'")
            .bind(reason)
            .bind(now)
            .bind(now)
            .bind(computer_session_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected())
    }

    pub async fn cancel_teaching_session(
        &self,
        id: &str,
        owner_device_id: &str,
        expected_revision: Option<u64>,
        now: &str,
    ) -> Result<Option<StoredTeachingSession>, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query("UPDATE teaching_sessions SET state='expired',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE id=? AND state='recording' AND expires_at IS NOT NULL AND julianday(expires_at) IS NOT NULL AND julianday(expires_at) <= julianday(?)")
            .bind(TEACHING_EXPIRED_REASON)
            .bind(now)
            .bind(now)
            .bind(id)
            .bind(now)
            .execute(&mut *transaction)
            .await?;
        let row = sqlx::query("SELECT id,client_request_id,owner_device_id,host_installation_id,bot_id,conversation_id,computer_session_id,control_lease_id,state,capture_scope,capture_provider,outcome,name,description,goal,input_schema_json,prerequisites,steps,result_checks,failure_reason,revision,event_count,evidence_bytes,content_hash,created_at,updated_at,started_at,ended_at,expires_at FROM teaching_sessions WHERE id=?")
            .bind(id)
            .fetch_optional(&mut *transaction)
            .await?;
        let Some(row) = row else {
            transaction.commit().await?;
            return Ok(None);
        };
        let current = teaching(&row);
        if current.owner_device_id != owner_device_id {
            transaction.commit().await?;
            return Ok(None);
        }
        if current.state == "cancelled" {
            transaction.commit().await?;
            return Ok(Some(current));
        }
        if current.state == "expired" {
            transaction.commit().await?;
            return Ok(Some(current));
        }
        if matches!(current.state.as_str(), "approvedVersion" | "replayVerified") {
            return Err(sqlx::Error::Protocol(
                "approved skills cannot be cancelled".into(),
            ));
        }
        if expected_revision.is_some_and(|revision| revision != current.revision) {
            return Err(sqlx::Error::Protocol(
                "teaching session revision mismatch".into(),
            ));
        }
        let result = sqlx::query("UPDATE teaching_sessions SET state='cancelled',event_count=0,evidence_bytes=0,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE id=? AND owner_device_id=? AND revision=? AND state=?")
            .bind(now)
            .bind(now)
            .bind(id)
            .bind(owner_device_id)
            .bind(current.revision as i64)
            .bind(&current.state)
            .execute(&mut *transaction)
            .await?;
        if result.rows_affected() != 1 {
            return Err(sqlx::Error::Protocol("teaching session changed".into()));
        }
        sqlx::query("DELETE FROM teaching_events WHERE session_id=?")
            .bind(id)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        self.teaching_session_at(id, now).await
    }

    pub async fn stop_teaching_session(
        &self,
        id: &str,
        owner_device_id: &str,
        expected_revision: u64,
        now: &str,
    ) -> Result<Option<StoredTeachingSession>, sqlx::Error> {
        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        sqlx::query("UPDATE teaching_sessions SET state='expired',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE id=? AND state='recording' AND expires_at IS NOT NULL AND julianday(expires_at) IS NOT NULL AND julianday(expires_at) <= julianday(?)")
            .bind(TEACHING_EXPIRED_REASON)
            .bind(now)
            .bind(now)
            .bind(id)
            .bind(now)
            .execute(&mut *transaction)
            .await?;
        let row = sqlx::query("SELECT id,client_request_id,owner_device_id,host_installation_id,bot_id,conversation_id,computer_session_id,control_lease_id,state,capture_scope,capture_provider,outcome,name,description,goal,input_schema_json,prerequisites,steps,result_checks,failure_reason,revision,event_count,evidence_bytes,content_hash,created_at,updated_at,started_at,ended_at,expires_at FROM teaching_sessions WHERE id=?")
            .bind(id)
            .fetch_optional(&mut *transaction)
            .await?;
        let Some(row) = row else {
            transaction.commit().await?;
            return Ok(None);
        };
        let current = teaching(&row);
        if current.owner_device_id != owner_device_id {
            transaction.commit().await?;
            return Ok(None);
        }
        if current.state != "recording" {
            transaction.commit().await?;
            return Ok(Some(current));
        }
        if current.revision != expected_revision {
            return Err(sqlx::Error::Protocol(
                "teaching session revision mismatch".into(),
            ));
        }
        let (state, reason) = if current.event_count == 0 {
            (
                "interrupted",
                Some("Teaching stopped without any accepted computer actions."),
            )
        } else {
            ("reviewing", None)
        };
        let result = sqlx::query("UPDATE teaching_sessions SET state=?,failure_reason=?,revision=revision+1,updated_at=?,ended_at=? WHERE id=? AND owner_device_id=? AND state='recording' AND revision=?")
            .bind(state).bind(reason).bind(now).bind(now).bind(id).bind(owner_device_id).bind(expected_revision as i64).execute(&mut *transaction).await?;
        if result.rows_affected() != 1 {
            return Err(sqlx::Error::Protocol("teaching session changed".into()));
        }
        let row = sqlx::query("SELECT id,client_request_id,owner_device_id,host_installation_id,bot_id,conversation_id,computer_session_id,control_lease_id,state,capture_scope,capture_provider,outcome,name,description,goal,input_schema_json,prerequisites,steps,result_checks,failure_reason,revision,event_count,evidence_bytes,content_hash,created_at,updated_at,started_at,ended_at,expires_at FROM teaching_sessions WHERE id=?")
            .bind(id)
            .fetch_one(&mut *transaction)
            .await?;
        transaction.commit().await?;
        Ok(Some(teaching(&row)))
    }

    pub async fn review_teaching_session(
        &self,
        id: &str,
        owner_device_id: &str,
        review: &TeachingReview,
    ) -> Result<Option<StoredTeachingSession>, sqlx::Error> {
        let Some(current) = self.teaching_session_at(id, &review.now).await? else {
            return Ok(None);
        };
        if current.owner_device_id != owner_device_id {
            return Ok(None);
        }
        // A lost response can cause the client to retry the same review with
        // its original expected revision. Once the exact review is already
        // stored, return the committed row instead of treating that retry as
        // a stale write. Different review content still follows CAS below.
        let same_review = current.state == "skillDraft"
            && current.name.as_deref() == Some(review.name.as_str())
            && current.description.as_deref() == Some(review.description.as_str())
            && current.goal.as_deref() == Some(review.goal.as_str())
            && current.input_schema_json.as_deref() == Some(review.input_schema_json.as_str())
            && current.prerequisites.as_deref() == Some(review.prerequisites.as_str())
            && current.steps.as_deref() == Some(review.steps.as_str())
            && current.result_checks.as_deref() == Some(review.result_checks.as_str())
            && current.content_hash.as_deref() == Some(review.content_hash.as_str());
        if same_review {
            return Ok(Some(current));
        }
        if current.revision != review.expected_revision {
            return Err(sqlx::Error::Protocol(
                "teaching session revision mismatch".into(),
            ));
        }
        if !matches!(current.state.as_str(), "reviewing" | "skillDraft") {
            return Err(sqlx::Error::Protocol(
                "teaching session is not ready for review".into(),
            ));
        }
        let result = sqlx::query("UPDATE teaching_sessions SET state='skillDraft',name=?,description=?,goal=?,input_schema_json=?,prerequisites=?,steps=?,result_checks=?,content_hash=?,revision=revision+1,updated_at=? WHERE id=? AND owner_device_id=? AND revision=?")
            .bind(&review.name).bind(&review.description).bind(&review.goal).bind(&review.input_schema_json)
            .bind(&review.prerequisites).bind(&review.steps).bind(&review.result_checks).bind(&review.content_hash)
            .bind(&review.now).bind(id).bind(owner_device_id).bind(review.expected_revision as i64)
            .execute(&self.pool).await?;
        if result.rows_affected() != 1 {
            return Err(sqlx::Error::Protocol("teaching session changed".into()));
        }
        self.teaching_session_at(id, &review.now).await
    }

    pub async fn list_bot_skills(&self, bot_id: &str) -> Result<Vec<StoredBotSkill>, sqlx::Error> {
        let rows = sqlx::query("SELECT id,bot_id,slug,name,description,state,active_version,skill_path,created_at,updated_at FROM bot_skills WHERE bot_id=? AND state!='archived' ORDER BY updated_at DESC")
            .bind(bot_id).fetch_all(&self.pool).await?;
        Ok(rows.iter().map(skill).collect())
    }

    /// Saved teaching files only; ordinary workspace and installed skills are unrelated.
    pub async fn teaching_skill_paths(&self) -> Result<Vec<(String, String)>, sqlx::Error> {
        sqlx::query_as("SELECT b.workspace_path,s.skill_path FROM bot_skills s JOIN bots b ON b.id=s.bot_id WHERE s.state!='archived' UNION SELECT b.workspace_path,v.skill_path FROM bot_skill_versions v JOIN bots b ON b.id=v.bot_id")
            .fetch_all(&self.pool)
            .await
    }

    pub async fn bot_skill(
        &self,
        bot_id: &str,
        skill_id: &str,
    ) -> Result<Option<StoredBotSkill>, sqlx::Error> {
        let row = sqlx::query("SELECT id,bot_id,slug,name,description,state,active_version,skill_path,created_at,updated_at FROM bot_skills WHERE bot_id=? AND id=?")
        .bind(bot_id)
        .bind(skill_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.as_ref().map(skill))
    }

    pub async fn bot_skill_versions(
        &self,
        bot_id: &str,
        skill_id: &str,
    ) -> Result<Vec<StoredBotSkillVersion>, sqlx::Error> {
        let rows = sqlx::query("SELECT id,skill_id,bot_id,version,source_session_id,save_request_id,content_hash,skill_path,input_schema_json,verification_state,created_at FROM bot_skill_versions WHERE bot_id=? AND skill_id=? ORDER BY version DESC")
            .bind(bot_id).bind(skill_id).fetch_all(&self.pool).await?;
        Ok(rows.iter().map(version).collect())
    }

    pub async fn bot_skill_version_by_request(
        &self,
        bot_id: &str,
        save_request_id: &str,
    ) -> Result<Option<StoredBotSkillVersion>, sqlx::Error> {
        let row = sqlx::query("SELECT id,skill_id,bot_id,version,source_session_id,save_request_id,content_hash,skill_path,input_schema_json,verification_state,created_at FROM bot_skill_versions WHERE bot_id=? AND save_request_id=?")
            .bind(bot_id)
            .bind(save_request_id)
            .fetch_optional(&self.pool)
        .await?;
        Ok(row.as_ref().map(version))
    }

    pub async fn bot_skill_version(
        &self,
        bot_id: &str,
        skill_id: &str,
        version_number: u64,
    ) -> Result<Option<StoredBotSkillVersion>, sqlx::Error> {
        let row = sqlx::query("SELECT id,skill_id,bot_id,version,source_session_id,save_request_id,content_hash,skill_path,input_schema_json,verification_state,created_at FROM bot_skill_versions WHERE bot_id=? AND skill_id=? AND version=?")
        .bind(bot_id)
        .bind(skill_id)
        .bind(version_number as i64)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.as_ref().map(version))
    }

    pub async fn skill_fixture_run_by_request(
        &self,
        client_request_id: &str,
    ) -> Result<Option<StoredSkillFixtureRun>, sqlx::Error> {
        let row = sqlx::query("SELECT id,client_request_id,owner_device_id,bot_id,skill_id,version,content_hash,input_schema_hash,input_schema_json,inputs_json,working_directory,provider,execution_kind,status,verification_state,artifact_path,artifact_hash,artifact_bytes,evidence_json,failure_reason,created_at,completed_at FROM bot_skill_fixture_runs WHERE client_request_id=?")
        .bind(client_request_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.as_ref().map(fixture_run))
    }

    pub async fn insert_skill_fixture_run(
        &self,
        request: &NewSkillFixtureRun,
    ) -> Result<SkillFixtureRunReservation, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        if let Some(row) = sqlx::query("SELECT id,client_request_id,owner_device_id,bot_id,skill_id,version,content_hash,input_schema_hash,input_schema_json,inputs_json,working_directory,provider,execution_kind,status,verification_state,artifact_path,artifact_hash,artifact_bytes,evidence_json,failure_reason,created_at,completed_at FROM bot_skill_fixture_runs WHERE client_request_id=?")
        .bind(&request.client_request_id)
        .fetch_optional(&mut *transaction)
        .await?
        {
            let existing = fixture_run(&row);
            let same_payload = existing.owner_device_id == request.owner_device_id
                && existing.bot_id == request.bot_id
                && existing.skill_id == request.skill_id
                && existing.version == request.version
                && existing.content_hash == request.content_hash
                && existing.input_schema_hash == request.input_schema_hash
                && existing.input_schema_json == request.input_schema_json
                && existing.inputs_json == request.inputs_json
                && existing.working_directory == request.working_directory
                && existing.provider == request.provider
                && existing.execution_kind == request.execution_kind;
            if !same_payload {
                return Err(sqlx::Error::Protocol(
                    "fixture request payload mismatch".into(),
                ));
            }
            transaction.commit().await?;
            return Ok(SkillFixtureRunReservation {
                run: existing,
                created: false,
            });
        }

        if request.status == "succeeded" {
            let version_row = sqlx::query("SELECT content_hash,input_schema_json FROM bot_skill_versions WHERE bot_id=? AND skill_id=? AND version=?")
                .bind(&request.bot_id)
                .bind(&request.skill_id)
                .bind(request.version as i64)
                .fetch_optional(&mut *transaction)
                .await?;
            let Some(version_row) = version_row else {
                return Err(sqlx::Error::Protocol("skill version is missing".into()));
            };
            let stored_hash: String = version_row.get("content_hash");
            let stored_schema: String = version_row.get("input_schema_json");
            let schema_matches = serde_json::from_str::<serde_json::Value>(&stored_schema)
                .ok()
                .zip(serde_json::from_str::<serde_json::Value>(&request.input_schema_json).ok())
                .is_some_and(|(stored, requested)| stored == requested);
            if stored_hash != request.content_hash || !schema_matches {
                return Err(sqlx::Error::Protocol(
                    "skill version binding changed before fixture verification".into(),
                ));
            }
            let changed = sqlx::query("UPDATE bot_skill_versions SET verification_state='fixtureVerified' WHERE bot_id=? AND skill_id=? AND version=? AND content_hash=? AND input_schema_json=?")
                .bind(&request.bot_id)
                .bind(&request.skill_id)
                .bind(request.version as i64)
                .bind(&request.content_hash)
                .bind(&request.input_schema_json)
                .execute(&mut *transaction)
                .await?;
            if changed.rows_affected() != 1 {
                return Err(sqlx::Error::Protocol(
                    "skill version changed before fixture verification".into(),
                ));
            }
        }

        sqlx::query("INSERT INTO bot_skill_fixture_runs(id,client_request_id,owner_device_id,bot_id,skill_id,version,content_hash,input_schema_hash,input_schema_json,inputs_json,working_directory,provider,execution_kind,status,verification_state,artifact_path,artifact_hash,artifact_bytes,evidence_json,failure_reason,created_at,completed_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            .bind(&request.id)
            .bind(&request.client_request_id)
            .bind(&request.owner_device_id)
            .bind(&request.bot_id)
            .bind(&request.skill_id)
            .bind(request.version as i64)
            .bind(&request.content_hash)
            .bind(&request.input_schema_hash)
            .bind(&request.input_schema_json)
            .bind(&request.inputs_json)
            .bind(&request.working_directory)
            .bind(&request.provider)
            .bind(&request.execution_kind)
            .bind(&request.status)
            .bind(&request.verification_state)
            .bind(&request.artifact_path)
            .bind(&request.artifact_hash)
            .bind(request.artifact_bytes as i64)
            .bind(&request.evidence_json)
            .bind(&request.failure_reason)
            .bind(&request.created_at)
            .bind(&request.completed_at)
            .execute(&mut *transaction)
            .await?;
        let row = sqlx::query("SELECT id,client_request_id,owner_device_id,bot_id,skill_id,version,content_hash,input_schema_hash,input_schema_json,inputs_json,working_directory,provider,execution_kind,status,verification_state,artifact_path,artifact_hash,artifact_bytes,evidence_json,failure_reason,created_at,completed_at FROM bot_skill_fixture_runs WHERE id=?")
        .bind(&request.id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(SkillFixtureRunReservation {
            run: fixture_run(&row),
            created: true,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn reserve_bot_skill_version(
        &self,
        bot_id: &str,
        source_session: &StoredTeachingSession,
        skill_id: &str,
        slug: &str,
        active_skill_path: &str,
        version_skill_path: &str,
        save_request_id: &str,
        now: &str,
    ) -> Result<SkillVersionReservation, sqlx::Error> {
        if source_session.bot_id != bot_id {
            return Err(sqlx::Error::Protocol(
                "teaching session is not ready to save".into(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        if let Some(row) = sqlx::query("SELECT id,skill_id,bot_id,version,source_session_id,save_request_id,content_hash,skill_path,input_schema_json,verification_state,created_at FROM bot_skill_versions WHERE bot_id=? AND save_request_id=?")
        .bind(bot_id)
        .bind(save_request_id)
        .fetch_optional(&mut *transaction)
        .await?
        {
            let existing = version(&row);
            if existing.skill_id != skill_id
                || existing.source_session_id != source_session.id
                || existing.content_hash
                    != source_session.content_hash.as_deref().unwrap_or_default()
                || existing.skill_path != version_skill_path
                || existing.input_schema_json
                    != source_session.input_schema_json.as_deref().unwrap_or("{}")
            {
                return Err(sqlx::Error::Protocol(
                    "save request payload mismatch".into(),
                ));
            }
            transaction.commit().await?;
            return Ok(SkillVersionReservation {
                version: existing,
                created: false,
            });
        }
        if source_session.state != "skillDraft" {
            return Err(sqlx::Error::Protocol(
                "teaching session is not ready to save".into(),
            ));
        }
        if let Some(row) = sqlx::query("SELECT id,bot_id,slug,name,description,state,active_version,skill_path,created_at,updated_at FROM bot_skills WHERE bot_id=? AND id=?")
        .bind(bot_id)
        .bind(skill_id)
        .fetch_optional(&mut *transaction)
        .await?
        {
            let existing = skill(&row);
            if existing.slug != slug || existing.skill_path != active_skill_path {
                return Err(sqlx::Error::Protocol("skill identity mismatch".into()));
            }
        } else {
            sqlx::query("INSERT INTO bot_skills(id,bot_id,slug,name,description,state,active_version,skill_path,created_at,updated_at) VALUES(?,?,?,?,?,'draft',NULL,?,?,?)")
                .bind(skill_id).bind(bot_id).bind(slug)
                .bind(source_session.name.as_deref().unwrap_or("Taught skill"))
                .bind(source_session.description.as_deref().unwrap_or("A private taught workflow."))
                .bind(active_skill_path).bind(now).bind(now)
                .execute(&mut *transaction).await?;
        }
        let next: i64 = sqlx::query_scalar(
            "SELECT COALESCE(MAX(version),0)+1 FROM bot_skill_versions WHERE skill_id=?",
        )
        .bind(skill_id)
        .fetch_one(&mut *transaction)
        .await?;
        let id = uuid::Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO bot_skill_versions(id,skill_id,bot_id,version,source_session_id,save_request_id,content_hash,skill_path,input_schema_json,verification_state,created_at) VALUES(?,?,?,?,?,?,?,?,?,'structurallyVerified',?)")
            .bind(&id).bind(skill_id).bind(bot_id).bind(next).bind(&source_session.id).bind(save_request_id)
            .bind(source_session.content_hash.as_deref().unwrap_or_default()).bind(version_skill_path)
            .bind(source_session.input_schema_json.as_deref().unwrap_or("{}"))
            .bind(now).execute(&mut *transaction).await?;
        let row = sqlx::query("SELECT id,skill_id,bot_id,version,source_session_id,save_request_id,content_hash,skill_path,input_schema_json,verification_state,created_at FROM bot_skill_versions WHERE id=?")
        .bind(&id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(SkillVersionReservation {
            version: version(&row),
            created: true,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn activate_bot_skill_version(
        &self,
        bot_id: &str,
        skill_id: &str,
        version_number: u64,
        source_session_id: &str,
        owner_device_id: &str,
        expected_revision: u64,
        now: &str,
    ) -> Result<StoredBotSkill, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        let session_row = sqlx::query("SELECT id,client_request_id,owner_device_id,host_installation_id,bot_id,conversation_id,computer_session_id,control_lease_id,state,capture_scope,capture_provider,outcome,name,description,goal,input_schema_json,prerequisites,steps,result_checks,failure_reason,revision,event_count,evidence_bytes,content_hash,created_at,updated_at,started_at,ended_at,expires_at FROM teaching_sessions WHERE id=? AND bot_id=? AND owner_device_id=?")
            .bind(source_session_id).bind(bot_id).bind(owner_device_id).fetch_optional(&mut *transaction).await?
            .ok_or(sqlx::Error::RowNotFound)?;
        let session = teaching(&session_row);
        if session.state == "approvedVersion" {
            let row = sqlx::query("SELECT id,bot_id,slug,name,description,state,active_version,skill_path,created_at,updated_at FROM bot_skills WHERE id=? AND bot_id=? AND active_version=?")
                .bind(skill_id).bind(bot_id).bind(version_number as i64).fetch_optional(&mut *transaction).await?;
            if let Some(row) = row {
                transaction.commit().await?;
                return Ok(skill(&row));
            }
        }
        if session.state != "skillDraft" || session.revision != expected_revision {
            return Err(sqlx::Error::Protocol(
                "teaching session revision mismatch".into(),
            ));
        }
        let stored_hash: Option<String> = sqlx::query_scalar("SELECT content_hash FROM bot_skill_versions WHERE skill_id=? AND bot_id=? AND version=? AND source_session_id=?")
            .bind(skill_id).bind(bot_id).bind(version_number as i64).bind(source_session_id)
            .fetch_optional(&mut *transaction).await?;
        if stored_hash.as_deref() != session.content_hash.as_deref() {
            return Err(sqlx::Error::Protocol(
                "skill version content mismatch".into(),
            ));
        }
        let result = sqlx::query("UPDATE bot_skills SET state='active',active_version=?,updated_at=? WHERE id=? AND bot_id=?")
            .bind(version_number as i64).bind(now).bind(skill_id).bind(bot_id).execute(&mut *transaction).await?;
        if result.rows_affected() != 1 {
            return Err(sqlx::Error::RowNotFound);
        }
        sqlx::query("UPDATE teaching_sessions SET state='approvedVersion',revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE id=? AND bot_id=? AND owner_device_id=? AND state='skillDraft' AND revision=?")
            .bind(now).bind(now).bind(source_session_id).bind(bot_id).bind(owner_device_id).bind(expected_revision as i64)
            .execute(&mut *transaction).await?;
        let row = sqlx::query("SELECT id,bot_id,slug,name,description,state,active_version,skill_path,created_at,updated_at FROM bot_skills WHERE id=? AND bot_id=?")
        .bind(skill_id)
        .bind(bot_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(skill(&row))
    }

    pub async fn set_active_bot_skill_version(
        &self,
        bot_id: &str,
        skill_id: &str,
        version_number: u64,
        now: &str,
    ) -> Result<Option<StoredBotSkill>, sqlx::Error> {
        let result = sqlx::query("UPDATE bot_skills SET state='active',active_version=?,updated_at=? WHERE id=? AND bot_id=? AND EXISTS(SELECT 1 FROM bot_skill_versions v WHERE v.skill_id=bot_skills.id AND v.bot_id=bot_skills.bot_id AND v.version=?)")
            .bind(version_number as i64).bind(now).bind(skill_id).bind(bot_id).bind(version_number as i64)
            .execute(&self.pool).await?;
        if result.rows_affected() == 0 {
            return Ok(None);
        }
        self.bot_skill(bot_id, skill_id).await
    }

    pub async fn archive_bot_skill(
        &self,
        bot_id: &str,
        skill_id: &str,
        now: &str,
    ) -> Result<Option<StoredBotSkill>, sqlx::Error> {
        sqlx::query("UPDATE bot_skills SET state='archived',updated_at=? WHERE bot_id=? AND id=?")
            .bind(now)
            .bind(bot_id)
            .bind(skill_id)
            .execute(&self.pool)
            .await?;
        self.bot_skill(bot_id, skill_id).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn store() -> Store {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        for (id, path) in [
            ("bot-1", "/tmp/wonder-bot-1"),
            ("bot-2", "/tmp/wonder-bot-2"),
        ] {
            store
                .upsert_bot(
                    id,
                    id,
                    "Helper",
                    "Help.",
                    path,
                    "wonder_bot_default",
                    None,
                    None,
                    "now",
                )
                .await
                .unwrap();
        }
        store
    }

    fn create(state: &str) -> TeachingSessionCreate {
        TeachingSessionCreate {
            id: "session-1".into(),
            client_request_id: "request-1".into(),
            owner_device_id: "phone-1".into(),
            host_installation_id: "host-1".into(),
            bot_id: "bot-1".into(),
            conversation_id: "conversation-1".into(),
            computer_session_id: Some("computer-1".into()),
            control_lease_id: Some("lease-1".into()),
            state: state.into(),
            capture_scope: "foreground-window".into(),
            capture_provider: "fixture".into(),
            outcome: "Save a preview file".into(),
            failure_reason: None,
            now: "2026-09-12T00:00:00Z".into(),
            expires_at: Some("2026-12-12T00:10:00Z".into()),
        }
    }

    fn review(revision: u64, hash: &str) -> TeachingReview {
        TeachingReview {
            expected_revision: revision,
            name: "Preview file".into(),
            description: "Create a preview file".into(),
            goal: "Save the preview".into(),
            input_schema_json: r#"{"title":{"type":"string"}}"#.into(),
            prerequisites: "Preview app".into(),
            steps: "Open the preview app.".into(),
            result_checks: "The file exists.".into(),
            content_hash: hash.into(),
            now: "later".into(),
        }
    }

    #[tokio::test]
    async fn cancel_and_stop_are_idempotent_and_cross_owner_reads_fail() {
        let store = store().await;
        let unavailable = store
            .insert_teaching_session(&create("unavailable"))
            .await
            .unwrap();
        assert_eq!(
            store
                .stop_teaching_session(&unavailable.id, "phone-1", 1, "stop")
                .await
                .unwrap()
                .unwrap()
                .state,
            "unavailable"
        );
        let cancelled = store
            .cancel_teaching_session(&unavailable.id, "phone-1", Some(1), "cancel")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(cancelled.state, "cancelled");
        assert_eq!(
            store
                .cancel_teaching_session(&unavailable.id, "phone-1", None, "again")
                .await
                .unwrap()
                .unwrap(),
            cancelled
        );
        assert!(store
            .cancel_teaching_session(&unavailable.id, "phone-2", None, "wrong")
            .await
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn stop_preserves_reviewing_state_when_capture_evidence_was_accepted() {
        let store = store().await;
        let inserted = store
            .insert_teaching_session(&create("recording"))
            .await
            .unwrap();
        let event = TeachingEventCreate {
            control_sequence: 1,
            action_index: 0,
            event_json: r#"{"kind":"pointer","x":0.5,"y":0.5}"#.into(),
            payload_bytes: 32,
            created_at: "2026-09-12T00:01:00Z".into(),
        };
        assert_eq!(
            store
                .append_teaching_events(
                    &inserted.id,
                    "phone-1",
                    "host-1",
                    "computer-1",
                    "lease-1",
                    std::slice::from_ref(&event),
                    "2026-09-12T00:01:00Z",
                )
                .await
                .unwrap(),
            TeachingCaptureAppendResult::Appended(1)
        );
        let before_stop = store.teaching_session(&inserted.id).await.unwrap().unwrap();

        let stopped = store
            .stop_teaching_session(
                &inserted.id,
                "phone-1",
                before_stop.revision,
                "2026-09-12T00:02:00Z",
            )
            .await
            .unwrap()
            .unwrap();

        assert_eq!(stopped.state, "reviewing");
        assert_eq!(stopped.event_count, 1);
        assert_eq!(stopped.revision, before_stop.revision + 1);
        assert!(stopped.failure_reason.is_none());
        assert_eq!(
            store.teaching_events(&inserted.id, 10).await.unwrap().len(),
            1
        );
    }

    #[tokio::test]
    async fn stop_empty_capture_remains_interrupted() {
        let store = store().await;
        let inserted = store
            .insert_teaching_session(&create("recording"))
            .await
            .unwrap();

        let stopped = store
            .stop_teaching_session(&inserted.id, "phone-1", inserted.revision, "stop")
            .await
            .unwrap()
            .unwrap();

        assert_eq!(stopped.state, "interrupted");
        assert_eq!(
            stopped.failure_reason.as_deref(),
            Some("Teaching stopped without any accepted computer actions.")
        );
        assert_eq!(stopped.event_count, 0);

        let repeated = store
            .stop_teaching_session(&inserted.id, "phone-1", 1, "stop-again")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(repeated, stopped);
    }

    #[tokio::test]
    async fn authenticated_capture_binds_events_deduplicates_and_interrupts_at_bounds() {
        let store = store().await;
        let inserted = store
            .insert_teaching_session(&create("recording"))
            .await
            .unwrap();
        assert_eq!(
            store
                .active_teaching_session_for_binding("phone-1", "host-1", "computer-1", "lease-1",)
                .await
                .unwrap()
                .unwrap()
                .id,
            inserted.id
        );
        assert!(store
            .active_teaching_session_for_binding("phone-1", "other-host", "computer-1", "lease-1",)
            .await
            .unwrap()
            .is_none());

        let event = TeachingEventCreate {
            control_sequence: 7,
            action_index: 0,
            event_json: r#"{"kind":"text","characterCount":4,"redacted":true}"#.into(),
            payload_bytes: 52,
            created_at: "2026-09-12T00:01:00Z".into(),
        };
        assert_eq!(
            store
                .append_teaching_events(
                    &inserted.id,
                    "phone-1",
                    "host-1",
                    "computer-1",
                    "lease-1",
                    std::slice::from_ref(&event),
                    "2026-09-12T00:01:00Z",
                )
                .await
                .unwrap(),
            TeachingCaptureAppendResult::Appended(1)
        );
        assert_eq!(
            store
                .append_teaching_events(
                    &inserted.id,
                    "phone-1",
                    "host-1",
                    "computer-1",
                    "lease-1",
                    std::slice::from_ref(&event),
                    "2026-09-12T00:01:01Z",
                )
                .await
                .unwrap(),
            TeachingCaptureAppendResult::Duplicate
        );
        assert_eq!(
            store.teaching_events(&inserted.id, 10).await.unwrap().len(),
            1
        );

        sqlx::query("UPDATE teaching_sessions SET event_count=? WHERE id=?")
            .bind(TEACHING_MAX_EVENTS as i64)
            .bind(&inserted.id)
            .execute(&store.pool)
            .await
            .unwrap();
        assert_eq!(
            store
                .append_teaching_events(
                    &inserted.id,
                    "phone-1",
                    "host-1",
                    "computer-1",
                    "lease-1",
                    &[TeachingEventCreate {
                        control_sequence: 8,
                        ..event
                    }],
                    "2026-09-12T00:01:02Z",
                )
                .await
                .unwrap(),
            TeachingCaptureAppendResult::Interrupted
        );
        assert_eq!(
            store
                .teaching_session(&inserted.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "interrupted"
        );
    }

    #[tokio::test]
    async fn append_late_event_expires_only_the_exact_session() {
        let store = store().await;
        let mut target_request = create("recording");
        target_request.id = "late-target".into();
        target_request.client_request_id = "late-target-request".into();
        target_request.expires_at = Some("2026-09-12T00:10:00Z".into());
        target_request.now = "2026-09-12T00:00:00Z".into();
        let target = store
            .insert_teaching_session(&target_request)
            .await
            .unwrap();

        let mut idle_request = create("recording");
        idle_request.id = "late-idle".into();
        idle_request.client_request_id = "late-idle-request".into();
        idle_request.host_installation_id = "host-2".into();
        idle_request.expires_at = Some("2026-09-12T00:10:00Z".into());
        idle_request.now = "2026-09-12T00:00:00Z".into();
        let idle = store.insert_teaching_session(&idle_request).await.unwrap();

        assert_eq!(
            store
                .append_teaching_events(
                    &target.id,
                    "phone-1",
                    "host-1",
                    "computer-1",
                    "lease-1",
                    &[TeachingEventCreate {
                        control_sequence: 1,
                        action_index: 0,
                        event_json: r#"{"kind":"pointer","x":0.5,"y":0.5}"#.into(),
                        payload_bytes: 32,
                        created_at: "2026-09-12T00:11:00Z".into(),
                    }],
                    "2026-09-12T00:11:00Z",
                )
                .await
                .unwrap(),
            TeachingCaptureAppendResult::Expired
        );

        let target_state: String =
            sqlx::query_scalar("SELECT state FROM teaching_sessions WHERE id=?")
                .bind(&target.id)
                .fetch_one(&store.pool)
                .await
                .unwrap();
        let idle_state: String =
            sqlx::query_scalar("SELECT state FROM teaching_sessions WHERE id=?")
                .bind(&idle.id)
                .fetch_one(&store.pool)
                .await
                .unwrap();
        assert_eq!(target_state, "expired");
        assert_eq!(idle_state, "recording");
        assert!(store
            .teaching_events(&target.id, 10)
            .await
            .unwrap()
            .is_empty());
        assert_eq!(
            store
                .teaching_session(&idle.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "expired"
        );
    }

    #[tokio::test]
    async fn expired_capture_reconciles_once_unblocks_host_and_rejects_late_input() {
        let store = store().await;
        let mut expired_request = create("recording");
        expired_request.id = "expired-session".into();
        expired_request.client_request_id = "expired-request".into();
        expired_request.expires_at = Some("2026-09-12T00:10:00Z".into());
        expired_request.now = "2026-09-12T00:00:00Z".into();
        let expired = store
            .insert_teaching_session(&expired_request)
            .await
            .unwrap();

        let reconciled = store
            .teaching_session_at(&expired.id, "2026-09-12T00:11:00Z")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(reconciled.state, "expired");
        assert_eq!(reconciled.revision, expired.revision + 1);
        assert_eq!(
            reconciled.failure_reason.as_deref(),
            Some(TEACHING_EXPIRED_REASON)
        );
        assert_eq!(reconciled.ended_at.as_deref(), Some("2026-09-12T00:11:00Z"));

        let repeated = store
            .teaching_session_at(&expired.id, "2026-09-12T00:12:00Z")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(repeated.state, "expired");
        assert_eq!(repeated.revision, reconciled.revision);

        assert_eq!(
            store
                .active_teaching_session_for_binding("phone-1", "host-1", "computer-1", "lease-1",)
                .await
                .unwrap(),
            None
        );

        let late_event = TeachingEventCreate {
            control_sequence: 1,
            action_index: 0,
            event_json: r#"{"kind":"pointer","x":0.5,"y":0.5}"#.into(),
            payload_bytes: 32,
            created_at: "2026-09-12T00:12:00Z".into(),
        };
        assert_eq!(
            store
                .append_teaching_events(
                    &expired.id,
                    "phone-1",
                    "host-1",
                    "computer-1",
                    "lease-1",
                    &[late_event],
                    "2026-09-12T00:12:00Z",
                )
                .await
                .unwrap(),
            TeachingCaptureAppendResult::Expired
        );
        assert!(store
            .teaching_events(&expired.id, 10)
            .await
            .unwrap()
            .is_empty());

        let mut replacement_request = create("recording");
        replacement_request.id = "replacement-session".into();
        replacement_request.client_request_id = "replacement-request".into();
        replacement_request.now = "2026-09-12T00:11:00Z".into();
        replacement_request.expires_at = Some("2026-09-12T00:20:00Z".into());
        let replacement = store
            .insert_teaching_session(&replacement_request)
            .await
            .unwrap();
        assert_eq!(replacement.state, "recording");
        assert_eq!(
            store
                .active_teaching_session_for_binding("phone-1", "host-1", "computer-1", "lease-1",)
                .await
                .unwrap()
                .unwrap()
                .id,
            replacement.id
        );
    }

    #[tokio::test]
    async fn cancellation_deletes_capture_rows_and_lease_interruption_is_truthful() {
        let store = store().await;
        let inserted = store
            .insert_teaching_session(&create("recording"))
            .await
            .unwrap();
        store
            .append_teaching_events(
                &inserted.id,
                "phone-1",
                "host-1",
                "computer-1",
                "lease-1",
                &[TeachingEventCreate {
                    control_sequence: 1,
                    action_index: 0,
                    event_json: r#"{"kind":"pointer","x":0.5,"y":0.5}"#.into(),
                    payload_bytes: 32,
                    created_at: "2026-09-12T00:01:00Z".into(),
                }],
                "2026-09-12T00:01:00Z",
            )
            .await
            .unwrap();
        let before_cancel = store.teaching_session(&inserted.id).await.unwrap().unwrap();
        assert_eq!(before_cancel.event_count, 1);
        let cancelled = store
            .cancel_teaching_session(
                &inserted.id,
                "phone-1",
                Some(before_cancel.revision),
                "cancelled",
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(cancelled.state, "cancelled");
        assert_eq!(cancelled.event_count, 0);
        assert_eq!(cancelled.evidence_bytes, 0);
        assert!(store
            .teaching_events(&inserted.id, 10)
            .await
            .unwrap()
            .is_empty());

        let second = store
            .insert_teaching_session(&TeachingSessionCreate {
                id: "session-2".into(),
                client_request_id: "request-2".into(),
                ..create("recording")
            })
            .await
            .unwrap();
        assert_eq!(
            store
                .interrupt_teaching_for_lease("lease-1", "lease ended", "ended")
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            store
                .teaching_session(&second.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "interrupted"
        );
        assert_eq!(
            store
                .teaching_session(&inserted.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "cancelled"
        );
    }

    #[tokio::test]
    async fn stale_cancellation_preserves_events_and_current_cas_clears_them() {
        let store = store().await;
        let inserted = store
            .insert_teaching_session(&create("recording"))
            .await
            .unwrap();
        store
            .append_teaching_events(
                &inserted.id,
                "phone-1",
                "host-1",
                "computer-1",
                "lease-1",
                &[TeachingEventCreate {
                    control_sequence: 1,
                    action_index: 0,
                    event_json: r#"{"kind":"pointer","x":0.5,"y":0.5}"#.into(),
                    payload_bytes: 32,
                    created_at: "2026-09-12T00:01:00Z".into(),
                }],
                "2026-09-12T00:01:00Z",
            )
            .await
            .unwrap();
        let stale_revision = store
            .teaching_session(&inserted.id)
            .await
            .unwrap()
            .unwrap()
            .revision;
        sqlx::query("UPDATE teaching_sessions SET state='reviewing',revision=revision+1,updated_at=? WHERE id=?")
            .bind("2026-09-12T00:02:00Z")
            .bind(&inserted.id)
            .execute(&store.pool)
            .await
            .unwrap();

        let error = store
            .cancel_teaching_session(
                &inserted.id,
                "phone-1",
                Some(stale_revision),
                "2026-09-12T00:03:00Z",
            )
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            sqlx::Error::Protocol(ref message) if message == "teaching session revision mismatch"
        ));
        assert_eq!(
            store.teaching_events(&inserted.id, 10).await.unwrap().len(),
            1
        );

        let current = store.teaching_session(&inserted.id).await.unwrap().unwrap();
        let cancelled = store
            .cancel_teaching_session(
                &inserted.id,
                "phone-1",
                Some(current.revision),
                "2026-09-12T00:04:00Z",
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(cancelled.state, "cancelled");
        assert_eq!(cancelled.revision, current.revision + 1);
        assert!(store
            .teaching_events(&inserted.id, 10)
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn review_is_idempotent_after_response_loss_for_exact_payload() {
        let store = store().await;
        let inserted = store
            .insert_teaching_session(&create("reviewing"))
            .await
            .unwrap();
        let first = store
            .review_teaching_session(&inserted.id, "phone-1", &review(1, "hash-1"))
            .await
            .unwrap()
            .unwrap();
        let retried = store
            .review_teaching_session(&inserted.id, "phone-1", &review(1, "hash-1"))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(retried, first);

        assert!(store
            .review_teaching_session(&inserted.id, "phone-1", &review(1, "hash-2"))
            .await
            .is_err());
    }

    #[tokio::test]
    async fn reservations_bind_payload_and_versions_activate_through_migrated_session_rows() {
        let store = store().await;
        let inserted = store
            .insert_teaching_session(&create("reviewing"))
            .await
            .unwrap();
        let drafted = store
            .review_teaching_session(&inserted.id, "phone-1", &review(1, "hash-1"))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(drafted.computer_session_id.as_deref(), Some("computer-1"));
        assert_eq!(drafted.control_lease_id.as_deref(), Some("lease-1"));
        let one = store
            .reserve_bot_skill_version(
                "bot-1",
                &drafted,
                "skill-1",
                "preview-file",
                ".agents/skills/preview-file/SKILL.md",
                ".agents/skills/.wonder-versions/skill-1/1/SKILL.md",
                "save-1",
                "saved",
            )
            .await
            .unwrap();
        let same = store
            .reserve_bot_skill_version(
                "bot-1",
                &drafted,
                "skill-1",
                "preview-file",
                ".agents/skills/preview-file/SKILL.md",
                ".agents/skills/.wonder-versions/skill-1/1/SKILL.md",
                "save-1",
                "saved-again",
            )
            .await
            .unwrap();
        assert_eq!(one.version, same.version);
        assert!(!same.created);
        assert!(store
            .reserve_bot_skill_version(
                "bot-1",
                &drafted,
                "skill-2",
                "other",
                ".agents/skills/other/SKILL.md",
                ".agents/skills/.wonder-versions/skill-2/1/SKILL.md",
                "save-1",
                "later"
            )
            .await
            .is_err());
        assert!(store.bot_skill("bot-2", "skill-1").await.unwrap().is_none());
        let active = store
            .activate_bot_skill_version(
                "bot-1",
                "skill-1",
                1,
                &drafted.id,
                "phone-1",
                drafted.revision,
                "active",
            )
            .await
            .unwrap();
        assert_eq!(active.active_version, Some(1));
        assert!(store
            .set_active_bot_skill_version("bot-1", "skill-1", 99, "bad")
            .await
            .unwrap()
            .is_none());
        assert_eq!(
            store
                .set_active_bot_skill_version("bot-1", "skill-1", 1, "rollback")
                .await
                .unwrap()
                .unwrap()
                .active_version,
            Some(1)
        );
    }

    #[tokio::test]
    async fn fixture_receipts_are_immutable_idempotent_and_preserve_active_version_on_failure() {
        let store = store().await;
        let inserted = store
            .insert_teaching_session(&create("reviewing"))
            .await
            .unwrap();
        let schema = r#"{"date":{"format":"date","type":"string"},"title":{"type":"string"}}"#;
        let drafted = store
            .review_teaching_session(
                &inserted.id,
                "phone-1",
                &TeachingReview {
                    input_schema_json: schema.into(),
                    ..review(1, "hash-1")
                },
            )
            .await
            .unwrap()
            .unwrap();
        let reservation = store
            .reserve_bot_skill_version(
                "bot-1",
                &drafted,
                "skill-fixture",
                "preview-file",
                ".agents/skills/preview-file/SKILL.md",
                ".agents/skills/.wonder-versions/skill-fixture/save-1/SKILL.md",
                "save-1",
                "saved",
            )
            .await
            .unwrap();
        let active = store
            .activate_bot_skill_version(
                "bot-1",
                "skill-fixture",
                reservation.version.version,
                &drafted.id,
                "phone-1",
                drafted.revision,
                "active",
            )
            .await
            .unwrap();
        assert_eq!(active.active_version, Some(1));
        let request = NewSkillFixtureRun {
            id: "fixture-run-1".into(),
            client_request_id: "11111111-1111-4111-8111-111111111111".into(),
            owner_device_id: "phone-1".into(),
            bot_id: "bot-1".into(),
            skill_id: "skill-fixture".into(),
            version: 1,
            content_hash: "hash-1".into(),
            input_schema_hash: "schema-hash".into(),
            input_schema_json: schema.into(),
            inputs_json: r#"{"date":"2026-09-12","title":"One"}"#.into(),
            working_directory: ".".into(),
            provider: "deterministic-local".into(),
            execution_kind: "deterministicFixture".into(),
            status: "succeeded".into(),
            verification_state: "fixtureVerified".into(),
            artifact_path: Some(".wonder/fixture-runs/bot-1/fixture-run-1/preview.json".into()),
            artifact_hash: Some("artifact-hash".into()),
            artifact_bytes: 128,
            evidence_json: r#"{"verified":true}"#.into(),
            failure_reason: None,
            created_at: "created".into(),
            completed_at: "completed".into(),
        };
        let first = store.insert_skill_fixture_run(&request).await.unwrap();
        assert!(first.created);
        assert_eq!(
            store
                .bot_skill_version("bot-1", "skill-fixture", 1)
                .await
                .unwrap()
                .unwrap()
                .verification_state,
            "fixtureVerified"
        );
        let second = store
            .insert_skill_fixture_run(&NewSkillFixtureRun {
                id: "different-id-is-ignored".into(),
                completed_at: "later".into(),
                ..request.clone()
            })
            .await
            .unwrap();
        assert!(!second.created);
        assert_eq!(second.run, first.run);
        assert!(store
            .insert_skill_fixture_run(&NewSkillFixtureRun {
                inputs_json: r#"{"date":"2026-09-13","title":"Two"}"#.into(),
                ..request.clone()
            })
            .await
            .is_err());
        let failed = store
            .insert_skill_fixture_run(&NewSkillFixtureRun {
                id: "fixture-run-2".into(),
                client_request_id: "22222222-2222-4222-8222-222222222222".into(),
                status: "failed".into(),
                verification_state: "testFailed".into(),
                artifact_path: None,
                artifact_hash: None,
                artifact_bytes: 0,
                evidence_json: r#"{"verified":false}"#.into(),
                failure_reason: Some("invalid date".into()),
                ..request
            })
            .await
            .unwrap();
        assert_eq!(failed.run.verification_state, "testFailed");
        assert_eq!(
            store
                .bot_skill("bot-1", "skill-fixture")
                .await
                .unwrap()
                .unwrap()
                .active_version,
            Some(1)
        );
        assert_eq!(
            store
                .bot_skill_version("bot-1", "skill-fixture", 1)
                .await
                .unwrap()
                .unwrap()
                .verification_state,
            "fixtureVerified"
        );
    }
}
