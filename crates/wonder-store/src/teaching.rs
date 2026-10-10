use super::*;

pub const TEACHING_EXPIRED_REASON: &str =
    "Teaching stopped because its maximum capture duration was reached.";

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

    /// Saved teaching files only; ordinary workspace and installed skills are unrelated.
    pub async fn teaching_skill_paths(&self) -> Result<Vec<(String, String)>, sqlx::Error> {
        sqlx::query_as("SELECT b.workspace_path,s.skill_path FROM bot_skills s JOIN bots b ON b.id=s.bot_id WHERE s.state!='archived' UNION SELECT b.workspace_path,v.skill_path FROM bot_skill_versions v JOIN bots b ON b.id=v.bot_id")
            .fetch_all(&self.pool)
            .await
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
}
