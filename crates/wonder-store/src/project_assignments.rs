//! Assignment metadata extends the existing Group message and dispatch identities.
use super::*;

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectAssignment {
    pub id: String,
    pub creation_hash: String,
    pub owner_device_id: String,
    pub group_id: String,
    pub bot_id: String,
    pub parent_message_id: String,
    pub child_client_id: String,
    pub title: String,
    pub instruction: String,
    pub repository_path: String,
    pub target_ref: String,
    pub worktree_path: String,
    pub branch: String,
    pub base_revision: String,
    pub dependency_ids: Vec<String>,
    pub state: String,
    pub result_revision: Option<String>,
    pub summary: Option<String>,
    pub validation: Option<String>,
    pub integration_head: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}
fn assignment(row: &sqlx::sqlite::SqliteRow) -> ProjectAssignment {
    ProjectAssignment {
        id: row.get("id"),
        creation_hash: row.get("creation_hash"),
        owner_device_id: row.get("owner_device_id"),
        group_id: row.get("group_id"),
        bot_id: row.get("bot_id"),
        parent_message_id: row.get("parent_message_id"),
        child_client_id: row.get("child_client_id"),
        title: row.get("title"),
        instruction: row.get("instruction"),
        repository_path: row.get("repository_path"),
        target_ref: row.get("target_ref"),
        worktree_path: row.get("worktree_path"),
        branch: row.get("branch"),
        base_revision: row.get("base_revision"),
        dependency_ids: serde_json::from_str(row.get("dependency_ids")).unwrap_or_default(),
        state: row.get("state"),
        result_revision: row.get("result_revision"),
        summary: row.get("summary"),
        validation: row.get("validation"),
        integration_head: row.get("integration_head"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}
impl Store {
    /// Activity belongs to the assignment's durable child conversation. Approvals
    /// and typed questions must match an actual message's exact thread and turn;
    /// request payload paths, conversation hints and free-form replies are not evidence.
    pub async fn assignment_execution_activity(
        &self,
        id: &str,
        now: i64,
    ) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar(r#"
            WITH child AS (
                SELECT m.conversation_id FROM project_assignments a JOIN messages m
                ON m.device_id=a.owner_device_id AND m.client_message_id=a.child_client_id
                WHERE a.id=?
            ), execution AS (
                SELECT m.* FROM messages m JOIN child c ON m.conversation_id=c.conversation_id
            )
            SELECT CASE
                WHEN EXISTS (
                    SELECT 1 FROM execution m JOIN approvals p
                    ON p.thread_id=m.codex_thread_id AND p.turn_id=m.codex_turn_id
                    WHERE p.thread_id<>'' AND p.turn_id<>'' AND p.state IN ('pending','resolving')
                ) OR EXISTS (
                    SELECT 1 FROM execution m JOIN async_questions q
                    ON q.conversation_id=m.conversation_id AND q.thread_id=m.codex_thread_id
                    AND q.turn_id=m.codex_turn_id
                    WHERE q.thread_id<>'' AND q.turn_id<>'' AND q.state='pending' AND q.expires_at_ms>?
                ) THEN 'awaiting_input'
                WHEN EXISTS (SELECT 1 FROM execution WHERE state IN
                    ('accepted_by_wonder','dispatching_to_codex','accepted_by_codex','streaming'))
                THEN 'working' ELSE NULL END
        "#).bind(id).bind(now).fetch_one(&self.pool).await
    }

    /// Refresh projection even while all Group wait slots are occupied. This never
    /// claims a message or resubmits execution; terminal Git states stay immutable.
    pub async fn refresh_assignment_execution_states(&self, now: i64) -> Result<(), sqlx::Error> {
        let rows = sqlx::query("SELECT id,state FROM project_assignments WHERE state IN ('working','uncertain','awaiting_input')")
            .fetch_all(&self.pool).await?;
        for row in rows {
            let id: String = row.get("id");
            let previous: String = row.get("state");
            let activity = self.assignment_execution_activity(&id, now).await?;
            let next = activity
                .as_deref()
                .unwrap_or(if previous == "awaiting_input" {
                    "uncertain"
                } else {
                    &previous
                });
            if next != previous {
                self.transition_assignment(&id, &previous, next, None, &now.to_string())
                    .await?;
            }
        }
        Ok(())
    }
    /// Repair a crash between assignment completion and the Group parent update.
    /// Terminal assignments must never occupy the dispatcher's bounded pending window.
    pub async fn reconcile_assignment_group_runs(&self) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("UPDATE group_runs SET state=CASE (SELECT state FROM project_assignments a WHERE a.parent_message_id=group_runs.parent_message_id) WHEN 'failed' THEN 'failed' WHEN 'cancelled' THEN 'cancelled' ELSE 'completed' END WHERE state IN ('pending','running','blocked') AND parent_message_id IN (SELECT parent_message_id FROM project_assignments WHERE state IN ('submitted','reviewed','integrating','integrated','failed','cancelled'))")
            .execute(&mut *tx).await?;
        sqlx::query("UPDATE messages SET state=CASE (SELECT state FROM project_assignments a WHERE a.parent_message_id=messages.id) WHEN 'failed' THEN 'failed' WHEN 'cancelled' THEN 'interrupted' ELSE 'completed' END WHERE state IN ('accepted_by_wonder','dispatching_to_codex','accepted_by_codex','streaming','uncertain') AND id IN (SELECT parent_message_id FROM project_assignments WHERE state IN ('submitted','reviewed','integrating','integrated','failed','cancelled'))")
            .execute(&mut *tx).await?;
        tx.commit().await
    }
    pub async fn project_assignment(
        &self,
        id: &str,
    ) -> Result<Option<ProjectAssignment>, sqlx::Error> {
        Ok(sqlx::query("SELECT * FROM project_assignments WHERE id=?")
            .bind(id)
            .fetch_optional(&self.pool)
            .await?
            .as_ref()
            .map(assignment))
    }
    pub async fn assignment_for_parent(
        &self,
        parent: &str,
    ) -> Result<Option<ProjectAssignment>, sqlx::Error> {
        Ok(
            sqlx::query("SELECT * FROM project_assignments WHERE parent_message_id=?")
                .bind(parent)
                .fetch_optional(&self.pool)
                .await?
                .as_ref()
                .map(assignment),
        )
    }
    pub async fn assignment_for_conversation(
        &self,
        conversation: &str,
    ) -> Result<Option<ProjectAssignment>, sqlx::Error> {
        Ok(sqlx::query("SELECT a.* FROM project_assignments a JOIN messages m ON m.device_id=a.owner_device_id AND m.client_message_id=a.child_client_id WHERE m.conversation_id=? LIMIT 1").bind(conversation).fetch_optional(&self.pool).await?.as_ref().map(assignment))
    }
    pub async fn project_assignments(
        &self,
        group: &str,
    ) -> Result<Vec<ProjectAssignment>, sqlx::Error> {
        Ok(sqlx::query("SELECT * FROM project_assignments WHERE group_id=? ORDER BY created_at DESC,id LIMIT 100").bind(group).fetch_all(&self.pool).await?.iter().map(assignment).collect())
    }
    /// Acceptance, immutable Group intent and assignment all commit together.
    pub async fn create_project_assignment(
        &self,
        a: &ProjectAssignment,
        conversation: &str,
    ) -> Result<bool, sqlx::Error> {
        self.create_project_assignment_with_attachments(a, conversation, &[])
            .await
    }
    pub async fn create_project_assignment_with_attachments(
        &self,
        a: &ProjectAssignment,
        conversation: &str,
        attachment_ids: &[String],
    ) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        if let Some(hash) = sqlx::query_scalar::<_, String>(
            "SELECT creation_hash FROM project_assignments WHERE id=?",
        )
        .bind(&a.id)
        .fetch_optional(&mut *tx)
        .await?
        {
            return Ok(hash == a.creation_hash);
        }
        for id in attachment_ids {
            let valid: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM conversation_files WHERE id=? AND conversation_id=? AND kind='attachment' AND state='available')")
                .bind(id).bind(conversation).fetch_one(&mut *tx).await?;
            if !valid {
                return Ok(false);
            }
        }
        for dependency in &a.dependency_ids {
            let valid: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM project_assignments WHERE id=? AND group_id=? AND repository_path=?)").bind(dependency).bind(&a.group_id).bind(&a.repository_path).fetch_one(&mut *tx).await?;
            if !valid {
                return Ok(false);
            }
        }
        sqlx::query("INSERT INTO messages(id,device_id,client_message_id,body,body_sha256,conversation_id,state,created_at) VALUES(?,?,?,?,?,?,'accepted_by_wonder',?)")
            .bind(&a.parent_message_id).bind(&a.owner_device_id).bind(&a.id).bind(&a.instruction).bind(&a.creation_hash).bind(conversation).bind(&a.created_at).execute(&mut *tx).await?;
        for id in attachment_ids {
            sqlx::query(
                "INSERT INTO message_attachments(message_id,file_id,created_at) VALUES(?,?,?)",
            )
            .bind(&a.parent_message_id)
            .bind(id)
            .bind(&a.created_at)
            .execute(&mut *tx)
            .await?;
        }
        sqlx::query("INSERT INTO channel_messages(channel_id,message_id,author_kind,phase,created_at,presentation_kind,outcome,retryable) VALUES(?,?,'user','user',?,'message','completed',0)")
            .bind(&a.group_id).bind(&a.parent_message_id).bind(&a.created_at).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO group_nodes(parent_message_id,device_id,client_message_id,bot_id,phase) VALUES(?,?,?,?,'worker')")
            .bind(&a.parent_message_id).bind(&a.owner_device_id).bind(&a.child_client_id).bind(&a.bot_id).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO project_assignments(id,creation_hash,owner_device_id,group_id,bot_id,parent_message_id,child_client_id,title,instruction,repository_path,target_ref,worktree_path,branch,base_revision,dependency_ids,state,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'queued',?,?)")
            .bind(&a.id).bind(&a.creation_hash).bind(&a.owner_device_id).bind(&a.group_id).bind(&a.bot_id).bind(&a.parent_message_id).bind(&a.child_client_id).bind(&a.title).bind(&a.instruction).bind(&a.repository_path).bind(&a.target_ref).bind(&a.worktree_path).bind(&a.branch).bind(&a.base_revision).bind(serde_json::to_string(&a.dependency_ids).unwrap()).bind(&a.created_at).bind(&a.updated_at).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(true)
    }
    pub async fn transition_assignment(
        &self,
        id: &str,
        expected: &str,
        next: &str,
        summary: Option<&str>,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE project_assignments SET state=?,summary=COALESCE(?,summary),updated_at=? WHERE id=? AND state=?")
            .bind(next).bind(summary).bind(now).bind(id).bind(expected).execute(&self.pool).await?.rows_affected()==1)
    }
    pub async fn set_assignment_base(&self, id: &str, revision: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE project_assignments SET base_revision=? WHERE id=? AND state='queued'")
            .bind(revision)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
    pub async fn submit_assignment(
        &self,
        id: &str,
        revision: &str,
        summary: &str,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE project_assignments SET state='submitted',result_revision=?,summary=?,updated_at=? WHERE id=? AND state IN ('working','uncertain','awaiting_input')")
            .bind(revision).bind(summary).bind(now).bind(id).execute(&self.pool).await?.rows_affected()==1)
    }
    pub async fn review_assignment(
        &self,
        id: &str,
        revision: &str,
        validation: &str,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE project_assignments SET state='reviewed',validation=?,updated_at=? WHERE id=? AND state='submitted' AND result_revision=?")
            .bind(validation).bind(now).bind(id).bind(revision).execute(&self.pool).await?.rows_affected()==1)
    }
    pub async fn begin_assignment_integration(
        &self,
        id: &str,
        result: &str,
        head: &str,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE project_assignments SET state='integrating',integration_head=?,updated_at=? WHERE id=? AND state='reviewed' AND result_revision=?")
            .bind(head).bind(now).bind(id).bind(result).execute(&self.pool).await?.rows_affected()==1)
    }
    pub async fn cancel_queued_assignment(&self, id: &str, now: &str) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let changed=sqlx::query("UPDATE project_assignments SET state='cancelled',updated_at=? WHERE id=? AND state='queued'").bind(now).bind(id).execute(&mut *tx).await?.rows_affected()==1;
        if changed {
            sqlx::query("UPDATE group_runs SET state='cancelled' WHERE parent_message_id=(SELECT parent_message_id FROM project_assignments WHERE id=?)").bind(id).execute(&mut *tx).await?;
            sqlx::query("UPDATE messages SET state='interrupted' WHERE id=(SELECT parent_message_id FROM project_assignments WHERE id=?)").bind(id).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(changed)
    }
}
