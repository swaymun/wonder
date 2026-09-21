use super::*;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ComputerSessionState {
    Preparing,
    AwaitingSource,
    Live,
    Paused,
    Stale,
    Ended,
    Failed,
    Unavailable,
}

impl ComputerSessionState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Preparing => "preparing",
            Self::AwaitingSource => "awaitingSource",
            Self::Live => "live",
            Self::Paused => "paused",
            Self::Stale => "stale",
            Self::Ended => "ended",
            Self::Failed => "failed",
            Self::Unavailable => "unavailable",
        }
    }
}

impl TryFrom<&str> for ComputerSessionState {
    type Error = ();

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Ok(match value {
            "preparing" => Self::Preparing,
            "awaitingSource" => Self::AwaitingSource,
            "live" => Self::Live,
            "paused" => Self::Paused,
            "stale" => Self::Stale,
            "ended" => Self::Ended,
            "failed" => Self::Failed,
            "unavailable" => Self::Unavailable,
            _ => return Err(()),
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComputerSessionCreate {
    pub id: String,
    pub client_request_id: String,
    pub owner_device_id: String,
    pub host_installation_id: String,
    pub conversation_id: String,
    pub generation: u64,
    pub state: ComputerSessionState,
    pub source_id: Option<String>,
    pub source_name: Option<String>,
    pub source_kind: Option<String>,
    pub source_width: Option<u32>,
    pub source_height: Option<u32>,
    pub source_scale: Option<f64>,
    pub crop_json: Option<String>,
    pub geometry_revision: u64,
    pub failure_reason: Option<String>,
    pub now: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StoredComputerSession {
    pub id: String,
    pub client_request_id: String,
    pub owner_device_id: String,
    pub host_installation_id: String,
    pub conversation_id: String,
    pub generation: u64,
    pub state: String,
    pub source_id: Option<String>,
    pub source_name: Option<String>,
    pub source_kind: Option<String>,
    pub source_width: Option<u32>,
    pub source_height: Option<u32>,
    pub source_scale: Option<f64>,
    pub crop_json: Option<String>,
    pub geometry_revision: u64,
    pub failure_reason: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub last_state_at: String,
    pub ended_at: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComputerControlLeaseCreate {
    pub id: String,
    pub client_request_id: String,
    pub session_id: String,
    pub owner_device_id: String,
    pub host_installation_id: String,
    pub conversation_id: String,
    pub session_generation: u64,
    pub source_id: Option<String>,
    pub geometry_revision: u64,
    pub now: String,
    pub expires_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredComputerControlLease {
    pub id: String,
    pub client_request_id: String,
    pub session_id: String,
    pub owner_device_id: String,
    pub host_installation_id: String,
    pub conversation_id: String,
    pub session_generation: u64,
    pub source_id: Option<String>,
    pub geometry_revision: u64,
    pub status: String,
    pub last_sequence: u64,
    pub acquired_at: String,
    pub updated_at: String,
    pub expires_at: String,
    pub released_at: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ComputerLeaseAcquireResult {
    Granted(StoredComputerControlLease),
    Existing(StoredComputerControlLease),
    Busy(StoredComputerControlLease),
    Conflict,
}

fn stored(row: &sqlx::sqlite::SqliteRow) -> StoredComputerSession {
    StoredComputerSession {
        id: row.get("id"),
        client_request_id: row.get("client_request_id"),
        owner_device_id: row.get("owner_device_id"),
        host_installation_id: row.get("host_installation_id"),
        conversation_id: row.get("conversation_id"),
        generation: row.get::<i64, _>("generation") as u64,
        state: row.get("state"),
        source_id: row.get("source_id"),
        source_name: row.get("source_name"),
        source_kind: row.get("source_kind"),
        source_width: row.get::<Option<i64>, _>("source_width").map(|v| v as u32),
        source_height: row.get::<Option<i64>, _>("source_height").map(|v| v as u32),
        source_scale: row.get("source_scale"),
        crop_json: row.get("crop_json"),
        geometry_revision: row.get::<i64, _>("geometry_revision") as u64,
        failure_reason: row.get("failure_reason"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        last_state_at: row.get("last_state_at"),
        ended_at: row.get("ended_at"),
    }
}

fn stored_lease(row: &sqlx::sqlite::SqliteRow) -> StoredComputerControlLease {
    StoredComputerControlLease {
        id: row.get("id"),
        client_request_id: row.get("client_request_id"),
        session_id: row.get("session_id"),
        owner_device_id: row.get("owner_device_id"),
        host_installation_id: row.get("host_installation_id"),
        conversation_id: row.get("conversation_id"),
        session_generation: row.get::<i64, _>("session_generation") as u64,
        source_id: row.get("source_id"),
        geometry_revision: row.get::<i64, _>("geometry_revision") as u64,
        status: row.get("status"),
        last_sequence: row.get::<i64, _>("last_sequence") as u64,
        acquired_at: row.get("acquired_at"),
        updated_at: row.get("updated_at"),
        expires_at: row.get("expires_at"),
        released_at: row.get("released_at"),
    }
}

impl Store {
    async fn computer_session_by_id_with<'a, E>(
        executor: E,
        id: &str,
    ) -> Result<Option<StoredComputerSession>, sqlx::Error>
    where
        E: sqlx::Executor<'a, Database = sqlx::Sqlite>,
    {
        let row = sqlx::query("SELECT id, client_request_id, owner_device_id, host_installation_id, conversation_id, generation, state, source_id, source_name, source_kind, source_width, source_height, source_scale, crop_json, geometry_revision, failure_reason, created_at, updated_at, last_state_at, ended_at FROM computer_sessions WHERE id=?")
            .bind(id)
            .fetch_optional(executor)
            .await?;
        Ok(row.as_ref().map(stored))
    }

    async fn lease_by_id_with<'a, E>(
        executor: E,
        id: &str,
    ) -> Result<Option<StoredComputerControlLease>, sqlx::Error>
    where
        E: sqlx::Executor<'a, Database = sqlx::Sqlite>,
    {
        let row = sqlx::query("SELECT id, client_request_id, session_id, owner_device_id, host_installation_id, conversation_id, session_generation, source_id, geometry_revision, status, last_sequence, acquired_at, updated_at, expires_at, released_at FROM computer_control_leases WHERE id=?")
            .bind(id)
            .fetch_optional(executor)
            .await?;
        Ok(row.as_ref().map(stored_lease))
    }

    pub async fn computer_control_lease(
        &self,
        id: &str,
    ) -> Result<Option<StoredComputerControlLease>, sqlx::Error> {
        Self::lease_by_id_with(&self.pool, id).await
    }

    pub async fn computer_control_lease_by_request(
        &self,
        owner_device_id: &str,
        client_request_id: &str,
    ) -> Result<Option<StoredComputerControlLease>, sqlx::Error> {
        let row = sqlx::query("SELECT id, client_request_id, session_id, owner_device_id, host_installation_id, conversation_id, session_generation, source_id, geometry_revision, status, last_sequence, acquired_at, updated_at, expires_at, released_at FROM computer_control_leases WHERE owner_device_id=? AND client_request_id=?")
            .bind(owner_device_id)
            .bind(client_request_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(stored_lease))
    }

    pub async fn acquire_computer_control_lease(
        &self,
        request: &ComputerControlLeaseCreate,
    ) -> Result<ComputerLeaseAcquireResult, sqlx::Error> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query("UPDATE computer_control_leases SET status='expired', updated_at=?, released_at=? WHERE status='active' AND expires_at<=?")
            .bind(&request.now)
            .bind(&request.now)
            .bind(&request.now)
            .execute(&mut *transaction)
            .await?;

        if let Some(row) = sqlx::query("SELECT id, client_request_id, session_id, owner_device_id, host_installation_id, conversation_id, session_generation, source_id, geometry_revision, status, last_sequence, acquired_at, updated_at, expires_at, released_at FROM computer_control_leases WHERE owner_device_id=? AND client_request_id=?")
            .bind(&request.owner_device_id)
            .bind(&request.client_request_id)
            .fetch_optional(&mut *transaction)
            .await?
        {
            let lease = stored_lease(&row);
            transaction.commit().await?;
            return Ok(if lease_matches_create(&lease, request) {
                ComputerLeaseAcquireResult::Existing(lease)
            } else {
                ComputerLeaseAcquireResult::Conflict
            });
        }

        let session_is_live: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM computer_sessions WHERE id=? AND owner_device_id=? AND host_installation_id=? AND conversation_id=? AND generation=? AND state='live' AND geometry_revision=? AND source_id IS ?)")
            .bind(&request.session_id)
            .bind(&request.owner_device_id)
            .bind(&request.host_installation_id)
            .bind(&request.conversation_id)
            .bind(request.session_generation as i64)
            .bind(request.geometry_revision as i64)
            .bind(&request.source_id)
            .fetch_one(&mut *transaction)
            .await?;
        if !session_is_live {
            return Err(sqlx::Error::Protocol("computer session is stale".into()));
        }

        if let Some(row) = sqlx::query("SELECT id, client_request_id, session_id, owner_device_id, host_installation_id, conversation_id, session_generation, source_id, geometry_revision, status, last_sequence, acquired_at, updated_at, expires_at, released_at FROM computer_control_leases WHERE host_installation_id=? AND status='active' LIMIT 1")
            .bind(&request.host_installation_id)
            .fetch_optional(&mut *transaction)
            .await?
        {
            transaction.commit().await?;
            return Ok(ComputerLeaseAcquireResult::Busy(stored_lease(&row)));
        }

        sqlx::query("INSERT INTO computer_control_leases (id, client_request_id, session_id, owner_device_id, host_installation_id, conversation_id, session_generation, source_id, geometry_revision, status, last_sequence, acquired_at, updated_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', 0, ?, ?, ?)")
            .bind(&request.id)
            .bind(&request.client_request_id)
            .bind(&request.session_id)
            .bind(&request.owner_device_id)
            .bind(&request.host_installation_id)
            .bind(&request.conversation_id)
            .bind(request.session_generation as i64)
            .bind(&request.source_id)
            .bind(request.geometry_revision as i64)
            .bind(&request.now)
            .bind(&request.now)
            .bind(&request.expires_at)
            .execute(&mut *transaction)
            .await?;
        let lease = Self::lease_by_id_with(&mut *transaction, &request.id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)?;
        transaction.commit().await?;
        Ok(ComputerLeaseAcquireResult::Granted(lease))
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn heartbeat_computer_control_lease(
        &self,
        lease_id: &str,
        owner_device_id: &str,
        host_installation_id: &str,
        session_id: &str,
        conversation_id: &str,
        session_generation: u64,
        source_id: Option<&str>,
        geometry_revision: u64,
        now: &str,
        expires_at: &str,
    ) -> Result<Option<StoredComputerControlLease>, sqlx::Error> {
        let lease = self.computer_control_lease(lease_id).await?;
        let Some(lease) = lease else { return Ok(None) };
        if !lease_binding_matches(
            &lease,
            owner_device_id,
            host_installation_id,
            session_id,
            conversation_id,
            session_generation,
            source_id,
            geometry_revision,
        ) || lease.status != "active"
            || lease.expires_at.as_str() <= now
        {
            return Ok(None);
        }
        let result = sqlx::query("UPDATE computer_control_leases SET updated_at=?, expires_at=? WHERE id=? AND status='active' AND updated_at=? AND EXISTS(SELECT 1 FROM computer_sessions WHERE id=? AND state='live' AND generation=? AND geometry_revision=? AND source_id IS ?)")
            .bind(now)
            .bind(expires_at)
            .bind(lease_id)
            .bind(&lease.updated_at)
            .bind(session_id)
            .bind(session_generation as i64)
            .bind(geometry_revision as i64)
            .bind(source_id)
            .execute(&self.pool)
            .await?;
        if result.rows_affected() != 1 {
            return Ok(None);
        }
        self.computer_control_lease(lease_id).await
    }

    #[allow(clippy::too_many_arguments)]
    async fn validate_computer_input_lease(
        &self,
        lease_id: &str,
        owner_device_id: &str,
        host_installation_id: &str,
        session_id: &str,
        conversation_id: &str,
        session_generation: u64,
        source_id: Option<&str>,
        geometry_revision: u64,
        now: &str,
    ) -> Result<StoredComputerControlLease, &'static str> {
        let lease = self
            .computer_control_lease(lease_id)
            .await
            .map_err(|_| "lease unavailable")?
            .ok_or("lease not found")?;
        if !lease_binding_matches(
            &lease,
            owner_device_id,
            host_installation_id,
            session_id,
            conversation_id,
            session_generation,
            source_id,
            geometry_revision,
        ) || lease.status != "active"
            || lease.expires_at.as_str() <= now
        {
            return Err("lease binding is stale");
        }
        let session = self
            .computer_session(session_id)
            .await
            .map_err(|_| "session unavailable")?
            .ok_or("session not found")?;
        if session.state != ComputerSessionState::Live.as_str()
            || session.generation != session_generation
            || session.geometry_revision != geometry_revision
            || session.source_id.as_deref() != source_id
        {
            return Err("computer session is stale");
        }
        Ok(lease)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn prepare_computer_input_batch(
        &self,
        lease_id: &str,
        owner_device_id: &str,
        host_installation_id: &str,
        session_id: &str,
        conversation_id: &str,
        session_generation: u64,
        source_id: Option<&str>,
        geometry_revision: u64,
        sequence: u64,
        now: &str,
    ) -> Result<StoredComputerControlLease, &'static str> {
        let lease = self
            .validate_computer_input_lease(
                lease_id,
                owner_device_id,
                host_installation_id,
                session_id,
                conversation_id,
                session_generation,
                source_id,
                geometry_revision,
                now,
            )
            .await?;
        let next_sequence = lease.last_sequence.saturating_add(1);
        if sequence != next_sequence && sequence != lease.last_sequence {
            return Err("input sequence must increase by one");
        }
        Ok(lease)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn advance_computer_input_batch(
        &self,
        lease_id: &str,
        owner_device_id: &str,
        host_installation_id: &str,
        session_id: &str,
        conversation_id: &str,
        session_generation: u64,
        source_id: Option<&str>,
        geometry_revision: u64,
        sequence: u64,
        now: &str,
    ) -> Result<StoredComputerControlLease, &'static str> {
        let lease = self
            .validate_computer_input_lease(
                lease_id,
                owner_device_id,
                host_installation_id,
                session_id,
                conversation_id,
                session_generation,
                source_id,
                geometry_revision,
                now,
            )
            .await?;
        if sequence == lease.last_sequence {
            return Ok(lease);
        }
        if sequence != lease.last_sequence.saturating_add(1) {
            return Err("input sequence must increase by one");
        }
        let result = sqlx::query("UPDATE computer_control_leases SET last_sequence=?, updated_at=? WHERE id=? AND status='active' AND last_sequence=? AND expires_at>? AND EXISTS(SELECT 1 FROM computer_sessions WHERE id=? AND state='live' AND generation=? AND geometry_revision=? AND source_id IS ?)")
            .bind(sequence as i64)
            .bind(now)
            .bind(lease_id)
            .bind(lease.last_sequence as i64)
            .bind(now)
            .bind(session_id)
            .bind(session_generation as i64)
            .bind(geometry_revision as i64)
            .bind(source_id)
            .execute(&self.pool)
            .await
            .map_err(|_| "lease unavailable")?;
        if result.rows_affected() != 1 {
            return Err("input sequence was not accepted");
        }
        self.computer_control_lease(lease_id)
            .await
            .map_err(|_| "lease unavailable")?
            .ok_or("lease ended")
    }

    /// Legacy store-level acknowledgement used by focused store tests. The
    /// daemon uses prepare + helper delivery + advance so durable state never
    /// moves ahead of native input acknowledgement.
    #[allow(clippy::too_many_arguments)]
    pub async fn accept_computer_input_batch(
        &self,
        lease_id: &str,
        owner_device_id: &str,
        host_installation_id: &str,
        session_id: &str,
        conversation_id: &str,
        session_generation: u64,
        source_id: Option<&str>,
        geometry_revision: u64,
        sequence: u64,
        now: &str,
    ) -> Result<StoredComputerControlLease, &'static str> {
        let lease = self
            .validate_computer_input_lease(
                lease_id,
                owner_device_id,
                host_installation_id,
                session_id,
                conversation_id,
                session_generation,
                source_id,
                geometry_revision,
                now,
            )
            .await?;
        if sequence != lease.last_sequence.saturating_add(1) {
            return Err("input sequence must increase by one");
        }
        self.advance_computer_input_batch(
            lease_id,
            owner_device_id,
            host_installation_id,
            session_id,
            conversation_id,
            session_generation,
            source_id,
            geometry_revision,
            sequence,
            now,
        )
        .await
    }

    pub async fn release_computer_control_lease(
        &self,
        lease_id: &str,
        owner_device_id: &str,
        now: &str,
    ) -> Result<Option<StoredComputerControlLease>, sqlx::Error> {
        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let Some(current) = Self::lease_by_id_with(&mut *transaction, lease_id).await? else {
            transaction.commit().await?;
            return Ok(None);
        };
        if current.owner_device_id != owner_device_id {
            transaction.commit().await?;
            return Ok(None);
        }
        if current.status == "active" {
            sqlx::query("UPDATE computer_control_leases SET status='released', updated_at=?, released_at=? WHERE id=? AND owner_device_id=? AND status='active'")
                .bind(now)
                .bind(now)
                .bind(lease_id)
                .bind(owner_device_id)
                .execute(&mut *transaction)
                .await?;
        }
        sqlx::query("UPDATE teaching_sessions SET state='expired',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE control_lease_id=? AND state='recording' AND expires_at IS NOT NULL AND julianday(expires_at) IS NOT NULL AND julianday(expires_at) <= julianday(?)")
            .bind(TEACHING_EXPIRED_REASON)
            .bind(now)
            .bind(now)
            .bind(lease_id)
            .bind(now)
            .execute(&mut *transaction)
            .await?;
        sqlx::query("UPDATE teaching_sessions SET state='interrupted',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE control_lease_id=? AND state='recording'")
            .bind("Teaching stopped because computer control ended.")
            .bind(now)
            .bind(now)
            .bind(lease_id)
            .execute(&mut *transaction)
            .await?;
        let released = Self::lease_by_id_with(&mut *transaction, lease_id).await?;
        transaction.commit().await?;
        Ok(released)
    }

    pub async fn release_computer_control_lease_for_session(
        &self,
        session_id: &str,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        sqlx::query("UPDATE computer_control_leases SET status='released', updated_at=?, released_at=? WHERE session_id=? AND status='active'")
            .bind(now)
            .bind(now)
            .bind(session_id)
            .execute(&mut *transaction)
            .await?;
        sqlx::query("UPDATE teaching_sessions SET state='expired',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE computer_session_id=? AND state='recording' AND expires_at IS NOT NULL AND julianday(expires_at) IS NOT NULL AND julianday(expires_at) <= julianday(?)")
            .bind(TEACHING_EXPIRED_REASON)
            .bind(now)
            .bind(now)
            .bind(session_id)
            .bind(now)
            .execute(&mut *transaction)
            .await?;
        sqlx::query("UPDATE teaching_sessions SET state='interrupted',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE computer_session_id=? AND state='recording'")
            .bind("Teaching stopped because the computer view ended.")
            .bind(now)
            .bind(now)
            .bind(session_id)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        Ok(())
    }

    pub async fn computer_conversation_allowed(
        &self,
        conversation_id: &str,
    ) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM conversation_metadata m WHERE m.id=? AND m.is_archived=0 AND ((m.bot_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM channels c WHERE c.conversation_id=m.id) AND NOT EXISTS(SELECT 1 FROM subagent_ownership s WHERE s.conversation_id=m.id)) OR EXISTS(SELECT 1 FROM channels c WHERE c.conversation_id=m.id AND c.is_archived=0)))")
            .bind(conversation_id)
            .fetch_one(&self.pool)
            .await
    }

    pub async fn computer_session_by_request(
        &self,
        owner_device_id: &str,
        client_request_id: &str,
    ) -> Result<Option<StoredComputerSession>, sqlx::Error> {
        let row = sqlx::query("SELECT id, client_request_id, owner_device_id, host_installation_id, conversation_id, generation, state, source_id, source_name, source_kind, source_width, source_height, source_scale, crop_json, geometry_revision, failure_reason, created_at, updated_at, last_state_at, ended_at FROM computer_sessions WHERE owner_device_id=? AND client_request_id=?")
        .bind(owner_device_id)
        .bind(client_request_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.as_ref().map(stored))
    }

    pub async fn computer_session(
        &self,
        id: &str,
    ) -> Result<Option<StoredComputerSession>, sqlx::Error> {
        let row = sqlx::query("SELECT id, client_request_id, owner_device_id, host_installation_id, conversation_id, generation, state, source_id, source_name, source_kind, source_width, source_height, source_scale, crop_json, geometry_revision, failure_reason, created_at, updated_at, last_state_at, ended_at FROM computer_sessions WHERE id=?")
            .bind(id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(stored))
    }

    pub async fn active_computer_session_for_host(
        &self,
        host_installation_id: &str,
    ) -> Result<Option<StoredComputerSession>, sqlx::Error> {
        let row = sqlx::query("SELECT id, client_request_id, owner_device_id, host_installation_id, conversation_id, generation, state, source_id, source_name, source_kind, source_width, source_height, source_scale, crop_json, geometry_revision, failure_reason, created_at, updated_at, last_state_at, ended_at FROM computer_sessions WHERE host_installation_id=? AND state IN ('preparing', 'awaitingSource', 'live', 'paused', 'stale') ORDER BY updated_at DESC LIMIT 1")
            .bind(host_installation_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(stored))
    }

    pub async fn active_computer_sessions_for_host(
        &self,
        host_installation_id: &str,
    ) -> Result<Vec<StoredComputerSession>, sqlx::Error> {
        let rows = sqlx::query("SELECT id, client_request_id, owner_device_id, host_installation_id, conversation_id, generation, state, source_id, source_name, source_kind, source_width, source_height, source_scale, crop_json, geometry_revision, failure_reason, created_at, updated_at, last_state_at, ended_at FROM computer_sessions WHERE host_installation_id=? AND state IN ('preparing', 'awaitingSource', 'live', 'paused', 'stale') ORDER BY updated_at DESC")
            .bind(host_installation_id)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows.iter().map(stored).collect())
    }

    pub async fn insert_computer_session(
        &self,
        request: &ComputerSessionCreate,
    ) -> Result<StoredComputerSession, sqlx::Error> {
        sqlx::query("INSERT INTO computer_sessions (id, client_request_id, owner_device_id, host_installation_id, conversation_id, generation, state, source_id, source_name, source_kind, source_width, source_height, source_scale, crop_json, geometry_revision, failure_reason, created_at, updated_at, last_state_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            .bind(&request.id)
            .bind(&request.client_request_id)
            .bind(&request.owner_device_id)
            .bind(&request.host_installation_id)
            .bind(&request.conversation_id)
            .bind(request.generation as i64)
            .bind(request.state.as_str())
            .bind(&request.source_id)
            .bind(&request.source_name)
            .bind(&request.source_kind)
            .bind(request.source_width.map(i64::from))
            .bind(request.source_height.map(i64::from))
            .bind(request.source_scale)
            .bind(&request.crop_json)
            .bind(request.geometry_revision as i64)
            .bind(&request.failure_reason)
            .bind(&request.now)
            .bind(&request.now)
            .bind(&request.now)
            .execute(&self.pool)
            .await?;
        self.computer_session(&request.id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)
    }

    /// Applies helper state only to the expected session generation. A stale
    /// helper event returns `None` and cannot resurrect an ended session.
    #[allow(clippy::too_many_arguments)]
    pub async fn transition_computer_session(
        &self,
        id: &str,
        expected_generation: u64,
        state: ComputerSessionState,
        source_id: Option<&str>,
        source_name: Option<&str>,
        source_kind: Option<&str>,
        source_width: Option<u32>,
        source_height: Option<u32>,
        source_scale: Option<f64>,
        crop_json: Option<&str>,
        geometry_revision: u64,
        failure_reason: Option<&str>,
        now: &str,
    ) -> Result<Option<StoredComputerSession>, sqlx::Error> {
        let result = sqlx::query("UPDATE computer_sessions SET state=?, source_id=COALESCE(?, source_id), source_name=COALESCE(?, source_name), source_kind=COALESCE(?, source_kind), source_width=COALESCE(?, source_width), source_height=COALESCE(?, source_height), source_scale=COALESCE(?, source_scale), crop_json=COALESCE(?, crop_json), geometry_revision=MAX(geometry_revision, ?), failure_reason=?, updated_at=?, last_state_at=CASE WHEN state != ? THEN ? ELSE last_state_at END WHERE id=? AND generation=? AND state != 'ended'")
            .bind(state.as_str())
            .bind(source_id)
            .bind(source_name)
            .bind(source_kind)
            .bind(source_width.map(i64::from))
            .bind(source_height.map(i64::from))
            .bind(source_scale)
            .bind(crop_json)
            .bind(geometry_revision as i64)
            .bind(failure_reason)
            .bind(now)
            .bind(state.as_str())
            .bind(now)
            .bind(id)
            .bind(expected_generation as i64)
            .execute(&self.pool)
            .await?;
        if result.rows_affected() == 0 {
            return Ok(None);
        }
        self.computer_session(id).await
    }

    pub async fn end_computer_session(
        &self,
        id: &str,
        owner_device_id: &str,
        expected_generation: Option<u64>,
        now: &str,
    ) -> Result<Option<StoredComputerSession>, sqlx::Error> {
        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let Some(current) = Self::computer_session_by_id_with(&mut *transaction, id).await? else {
            transaction.commit().await?;
            return Ok(None);
        };
        if current.owner_device_id != owner_device_id {
            transaction.commit().await?;
            return Ok(None);
        }
        if current.state == ComputerSessionState::Ended.as_str() {
            transaction.commit().await?;
            return Ok(Some(current));
        }
        if expected_generation.is_some_and(|generation| generation != current.generation) {
            return Err(sqlx::Error::Protocol(
                "computer session generation mismatch".into(),
            ));
        }
        sqlx::query("UPDATE computer_sessions SET state='ended', generation=generation+1, updated_at=?, last_state_at=?, ended_at=? WHERE id=? AND owner_device_id=?")
            .bind(now).bind(now).bind(now).bind(id).bind(owner_device_id)
            .execute(&mut *transaction).await?;
        sqlx::query("UPDATE teaching_sessions SET state='expired',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE computer_session_id=? AND state='recording' AND expires_at IS NOT NULL AND julianday(expires_at) IS NOT NULL AND julianday(expires_at) <= julianday(?)")
            .bind(TEACHING_EXPIRED_REASON)
            .bind(now)
            .bind(now)
            .bind(id)
            .bind(now)
            .execute(&mut *transaction)
            .await?;
        sqlx::query("UPDATE teaching_sessions SET state='interrupted',failure_reason=?,revision=revision+1,updated_at=?,ended_at=COALESCE(ended_at,?) WHERE computer_session_id=? AND state='recording'")
            .bind("Teaching stopped because the computer view ended.")
            .bind(now)
            .bind(now)
            .bind(id)
            .execute(&mut *transaction)
            .await?;
        let ended = Self::computer_session_by_id_with(&mut *transaction, id).await?;
        transaction.commit().await?;
        Ok(ended)
    }
}

#[allow(clippy::too_many_arguments)]
fn lease_binding_matches(
    lease: &StoredComputerControlLease,
    owner_device_id: &str,
    host_installation_id: &str,
    session_id: &str,
    conversation_id: &str,
    session_generation: u64,
    source_id: Option<&str>,
    geometry_revision: u64,
) -> bool {
    lease.owner_device_id == owner_device_id
        && lease.host_installation_id == host_installation_id
        && lease.session_id == session_id
        && lease.conversation_id == conversation_id
        && lease.session_generation == session_generation
        && lease.source_id.as_deref() == source_id
        && lease.geometry_revision == geometry_revision
}

fn lease_matches_create(
    lease: &StoredComputerControlLease,
    request: &ComputerControlLeaseCreate,
) -> bool {
    lease.client_request_id == request.client_request_id
        && lease_binding_matches(
            lease,
            &request.owner_device_id,
            &request.host_installation_id,
            &request.session_id,
            &request.conversation_id,
            request.session_generation,
            request.source_id.as_deref(),
            request.geometry_revision,
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn live_session_and_lease(
        store: &Store,
        session_id: &str,
        lease_id: &str,
        host_installation_id: &str,
    ) -> StoredComputerControlLease {
        store
            .upsert_bot(
                "bot-teardown",
                "Teardown Bot",
                "Test bot",
                "Test bot",
                "/tmp/wonder-teardown",
                ":workspace",
                None,
                None,
                "2026-09-12T00:00:00Z",
            )
            .await
            .unwrap();
        store
            .insert_computer_session(&ComputerSessionCreate {
                id: session_id.into(),
                client_request_id: format!("{session_id}-request"),
                owner_device_id: "phone-1".into(),
                host_installation_id: host_installation_id.into(),
                conversation_id: format!("{session_id}-conversation"),
                generation: 1,
                state: ComputerSessionState::Live,
                source_id: Some("display-1".into()),
                source_name: Some("Mac display".into()),
                source_kind: Some("display".into()),
                source_width: Some(1280),
                source_height: Some(720),
                source_scale: Some(2.0),
                crop_json: None,
                geometry_revision: 1,
                failure_reason: None,
                now: "2026-09-12T00:00:00Z".into(),
            })
            .await
            .unwrap();
        match store
            .acquire_computer_control_lease(&ComputerControlLeaseCreate {
                id: lease_id.into(),
                client_request_id: format!("{lease_id}-request"),
                session_id: session_id.into(),
                owner_device_id: "phone-1".into(),
                host_installation_id: host_installation_id.into(),
                conversation_id: format!("{session_id}-conversation"),
                session_generation: 1,
                source_id: Some("display-1".into()),
                geometry_revision: 1,
                now: "2026-09-12T00:00:01Z".into(),
                expires_at: "2026-09-12T00:10:00Z".into(),
            })
            .await
            .unwrap()
        {
            ComputerLeaseAcquireResult::Granted(lease) => lease,
            other => panic!("unexpected lease result: {other:?}"),
        }
    }

    fn bound_teaching(
        id: &str,
        session_id: &str,
        lease_id: Option<&str>,
        state: &str,
        expires_at: Option<&str>,
    ) -> TeachingSessionCreate {
        TeachingSessionCreate {
            id: id.into(),
            client_request_id: format!("{id}-request"),
            owner_device_id: "phone-1".into(),
            host_installation_id: "host-teardown".into(),
            bot_id: "bot-teardown".into(),
            conversation_id: format!("{session_id}-conversation"),
            computer_session_id: Some(session_id.into()),
            control_lease_id: lease_id.map(str::to_owned),
            state: state.into(),
            capture_scope: "authenticated-remote-control".into(),
            capture_provider: "fixture".into(),
            outcome: "Test teaching capture".into(),
            failure_reason: None,
            now: "2026-09-12T00:00:00Z".into(),
            expires_at: expires_at.map(str::to_owned),
        }
    }

    #[tokio::test]
    async fn releasing_control_interrupts_bound_teaching_and_preserves_expired_rows() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let lease =
            live_session_and_lease(&store, "session-release", "lease-release", "host-teardown")
                .await;
        let recording = store
            .insert_teaching_session(&bound_teaching(
                "teaching-release",
                "session-release",
                Some(&lease.id),
                "recording",
                Some("2026-09-12T00:10:00Z"),
            ))
            .await
            .unwrap();

        let released = store
            .release_computer_control_lease(&lease.id, "phone-1", "2026-09-12T00:02:00Z")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(released.status, "released");
        assert_eq!(
            store
                .teaching_session(&recording.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "interrupted"
        );

        let expired = store
            .insert_teaching_session(&bound_teaching(
                "teaching-release-expired",
                "session-release",
                Some(&lease.id),
                "recording",
                Some("2026-09-12T00:01:00Z"),
            ))
            .await
            .unwrap();
        let repeated = store
            .release_computer_control_lease(&lease.id, "phone-1", "2026-09-12T00:03:00Z")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(repeated.status, "released");
        let expired_after = store.teaching_session(&expired.id).await.unwrap().unwrap();
        assert_eq!(expired_after.state, "expired");
        assert_eq!(
            expired_after.failure_reason,
            Some(TEACHING_EXPIRED_REASON.into())
        );
    }

    #[tokio::test]
    async fn releasing_session_interrupts_bound_teaching_and_is_idempotent() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let lease = live_session_and_lease(
            &store,
            "session-release-all",
            "lease-release-all",
            "host-teardown",
        )
        .await;
        let teaching = store
            .insert_teaching_session(&bound_teaching(
                "teaching-release-all",
                "session-release-all",
                Some(&lease.id),
                "recording",
                Some("2026-09-12T00:10:00Z"),
            ))
            .await
            .unwrap();

        store
            .release_computer_control_lease_for_session(
                "session-release-all",
                "2026-09-12T00:02:00Z",
            )
            .await
            .unwrap();
        let interrupted = store.teaching_session(&teaching.id).await.unwrap().unwrap();
        assert_eq!(interrupted.state, "interrupted");
        let revision = interrupted.revision;

        store
            .release_computer_control_lease_for_session(
                "session-release-all",
                "2026-09-12T00:03:00Z",
            )
            .await
            .unwrap();
        assert_eq!(
            store
                .teaching_session(&teaching.id)
                .await
                .unwrap()
                .unwrap()
                .revision,
            revision
        );
    }

    #[tokio::test]
    async fn ending_session_interrupts_recording_preserves_expired_and_is_idempotent() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        live_session_and_lease(&store, "session-end", "lease-end", "host-teardown").await;
        let recording = store
            .insert_teaching_session(&bound_teaching(
                "teaching-end",
                "session-end",
                Some("lease-end"),
                "recording",
                Some("2026-09-12T00:10:00Z"),
            ))
            .await
            .unwrap();
        let expired = store
            .insert_teaching_session(&bound_teaching(
                "teaching-end-expired",
                "session-end",
                Some("lease-end"),
                "expired",
                Some("2026-09-12T00:01:00Z"),
            ))
            .await
            .unwrap();

        let ended = store
            .end_computer_session("session-end", "phone-1", Some(1), "2026-09-12T00:02:00Z")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(ended.state, "ended");
        assert_eq!(ended.generation, 2);
        assert_eq!(
            store
                .teaching_session(&recording.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "interrupted"
        );
        assert_eq!(
            store
                .teaching_session(&expired.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "expired"
        );

        let repeated = store
            .end_computer_session("session-end", "phone-1", Some(1), "2026-09-12T00:03:00Z")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(repeated.state, "ended");
        assert_eq!(repeated.generation, 2);
        assert_eq!(
            store
                .teaching_session(&recording.id)
                .await
                .unwrap()
                .unwrap()
                .revision,
            2
        );
    }

    #[tokio::test]
    async fn computer_session_is_idempotent_and_end_retires_generation() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let request = ComputerSessionCreate {
            id: "session-1".into(),
            client_request_id: "request-1".into(),
            owner_device_id: "phone-1".into(),
            host_installation_id: "host-1".into(),
            conversation_id: "bot-chat".into(),
            generation: 1,
            state: ComputerSessionState::Unavailable,
            source_id: Some("display-1".into()),
            source_name: Some("Mac display".into()),
            source_kind: Some("display".into()),
            source_width: Some(1280),
            source_height: Some(720),
            source_scale: Some(2.0),
            crop_json: None,
            geometry_revision: 0,
            failure_reason: Some("provider unavailable".into()),
            now: "2026-09-12T00:00:00Z".into(),
        };
        let inserted = store.insert_computer_session(&request).await.unwrap();
        assert_eq!(inserted.state, "unavailable");
        let same = store
            .computer_session_by_request("phone-1", "request-1")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(same.id, "session-1");
        let ended = store
            .end_computer_session("session-1", "phone-1", Some(1), "later")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(ended.state, "ended");
        assert_eq!(ended.generation, 2);
        assert!(store
            .end_computer_session("session-1", "phone-1", Some(1), "later")
            .await
            .unwrap()
            .is_some());
    }

    #[tokio::test]
    async fn helper_transition_is_compare_and_set_and_monotonic_for_geometry() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .insert_computer_session(&ComputerSessionCreate {
                id: "session-cas".into(),
                client_request_id: "request-cas".into(),
                owner_device_id: "phone-1".into(),
                host_installation_id: "host-1".into(),
                conversation_id: "bot-chat".into(),
                generation: 1,
                state: ComputerSessionState::Preparing,
                source_id: None,
                source_name: None,
                source_kind: None,
                source_width: None,
                source_height: None,
                source_scale: None,
                crop_json: None,
                geometry_revision: 0,
                failure_reason: None,
                now: "now".into(),
            })
            .await
            .unwrap();

        let awaiting = store
            .transition_computer_session(
                "session-cas",
                1,
                ComputerSessionState::AwaitingSource,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                2,
                None,
                "later",
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(awaiting.state, "awaitingSource");
        assert_eq!(awaiting.geometry_revision, 2);

        let retained = store
            .transition_computer_session(
                "session-cas",
                1,
                ComputerSessionState::Preparing,
                Some("display:1"),
                Some("Display 1"),
                Some("display"),
                Some(1280),
                Some(720),
                Some(2.0),
                Some(r#"{"x":0,"y":0,"width":1280,"height":720}"#),
                1,
                None,
                "older",
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(retained.state, "preparing");
        assert_eq!(retained.geometry_revision, 2);
        assert_eq!(retained.source_id.as_deref(), Some("display:1"));
        assert_eq!(retained.source_name.as_deref(), Some("Display 1"));
        assert_eq!(retained.source_kind.as_deref(), Some("display"));
        assert_eq!(
            retained.crop_json.as_deref(),
            Some(r#"{"x":0,"y":0,"width":1280,"height":720}"#)
        );

        assert!(store
            .transition_computer_session(
                "session-cas",
                2,
                ComputerSessionState::Failed,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                3,
                Some("stale_generation"),
                "stale",
            )
            .await
            .unwrap()
            .is_none());

        let ended = store
            .end_computer_session("session-cas", "phone-1", Some(1), "ended")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(ended.state, "ended");
        assert!(store
            .transition_computer_session(
                "session-cas",
                2,
                ComputerSessionState::Failed,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                4,
                Some("late_event"),
                "late",
            )
            .await
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn control_lease_is_host_wide_sequenced_and_release_is_idempotent() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .insert_computer_session(&ComputerSessionCreate {
                id: "session-live".into(),
                client_request_id: "session-request".into(),
                owner_device_id: "phone-1".into(),
                host_installation_id: "host-1".into(),
                conversation_id: "bot-chat".into(),
                generation: 1,
                state: ComputerSessionState::Live,
                source_id: Some("display-1".into()),
                source_name: Some("Mac display".into()),
                source_kind: Some("display".into()),
                source_width: Some(1280),
                source_height: Some(720),
                source_scale: Some(2.0),
                crop_json: None,
                geometry_revision: 4,
                failure_reason: None,
                now: "2026-09-12T00:00:00Z".into(),
            })
            .await
            .unwrap();
        store
            .insert_computer_session(&ComputerSessionCreate {
                id: "session-live-2".into(),
                client_request_id: "session-request-2".into(),
                owner_device_id: "phone-2".into(),
                host_installation_id: "host-1".into(),
                conversation_id: "other-chat".into(),
                generation: 1,
                state: ComputerSessionState::Live,
                source_id: Some("display-1".into()),
                source_name: Some("Mac display".into()),
                source_kind: Some("display".into()),
                source_width: Some(1280),
                source_height: Some(720),
                source_scale: Some(2.0),
                crop_json: None,
                geometry_revision: 4,
                failure_reason: None,
                now: "2026-09-12T00:00:00Z".into(),
            })
            .await
            .unwrap();
        let request = ComputerControlLeaseCreate {
            id: "lease-1".into(),
            client_request_id: "control-request-1".into(),
            session_id: "session-live".into(),
            owner_device_id: "phone-1".into(),
            host_installation_id: "host-1".into(),
            conversation_id: "bot-chat".into(),
            session_generation: 1,
            source_id: Some("display-1".into()),
            geometry_revision: 4,
            now: "2026-09-12T00:00:01Z".into(),
            expires_at: "2026-09-12T00:00:11Z".into(),
        };
        let granted = store
            .acquire_computer_control_lease(&request)
            .await
            .unwrap();
        let lease = match granted {
            ComputerLeaseAcquireResult::Granted(lease) => lease,
            other => panic!("unexpected lease result: {other:?}"),
        };
        assert_eq!(lease.status, "active");
        assert_eq!(lease.last_sequence, 0);
        assert!(matches!(
            store
                .acquire_computer_control_lease(&request)
                .await
                .unwrap(),
            ComputerLeaseAcquireResult::Existing(_)
        ));
        assert_eq!(
            store
                .acquire_computer_control_lease(&ComputerControlLeaseCreate {
                    geometry_revision: 5,
                    ..request.clone()
                })
                .await
                .unwrap(),
            ComputerLeaseAcquireResult::Conflict
        );
        assert!(matches!(
            store
                .acquire_computer_control_lease(&ComputerControlLeaseCreate {
                    id: "lease-2".into(),
                    client_request_id: "control-request-2".into(),
                    owner_device_id: "phone-2".into(),
                    session_id: "session-live-2".into(),
                    conversation_id: "other-chat".into(),
                    ..request.clone()
                })
                .await
                .unwrap(),
            ComputerLeaseAcquireResult::Busy(_)
        ));
        assert_eq!(
            store
                .accept_computer_input_batch(
                    &lease.id,
                    "phone-1",
                    "host-1",
                    "session-live",
                    "bot-chat",
                    1,
                    Some("display-1"),
                    4,
                    1,
                    "2026-09-12T00:00:02Z"
                )
                .await
                .unwrap()
                .last_sequence,
            1
        );
        assert_eq!(
            store
                .accept_computer_input_batch(
                    &lease.id,
                    "phone-1",
                    "host-1",
                    "session-live",
                    "bot-chat",
                    1,
                    Some("display-1"),
                    4,
                    1,
                    "2026-09-12T00:00:03Z"
                )
                .await,
            Err("input sequence must increase by one")
        );
        // A helper can have delivered sequence 1 before the durable CAS
        // response was lost. Retrying the same request must be allowed to
        // finalize the already-advanced durable sequence without reinjection.
        assert_eq!(
            store
                .prepare_computer_input_batch(
                    &lease.id,
                    "phone-1",
                    "host-1",
                    "session-live",
                    "bot-chat",
                    1,
                    Some("display-1"),
                    4,
                    1,
                    "2026-09-12T00:00:03Z"
                )
                .await
                .unwrap()
                .last_sequence,
            1
        );
        assert_eq!(
            store
                .advance_computer_input_batch(
                    &lease.id,
                    "phone-1",
                    "host-1",
                    "session-live",
                    "bot-chat",
                    1,
                    Some("display-1"),
                    4,
                    1,
                    "2026-09-12T00:00:03Z"
                )
                .await
                .unwrap()
                .last_sequence,
            1
        );
        assert_eq!(
            store
                .accept_computer_input_batch(
                    &lease.id,
                    "phone-1",
                    "host-1",
                    "session-live",
                    "bot-chat",
                    1,
                    Some("display-1"),
                    5,
                    2,
                    "2026-09-12T00:00:03Z"
                )
                .await,
            Err("lease binding is stale")
        );
        let released = store
            .release_computer_control_lease(&lease.id, "phone-1", "2026-09-12T00:00:04Z")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(released.status, "released");
        assert_eq!(
            store
                .release_computer_control_lease(&lease.id, "phone-1", "2026-09-12T00:00:05Z")
                .await
                .unwrap()
                .unwrap()
                .status,
            "released"
        );
    }
}
