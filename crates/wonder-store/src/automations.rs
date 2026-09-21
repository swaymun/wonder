use super::*;

impl Store {
    /// All editable fields and the next occurrence become visible together.
    pub async fn update_automation(&self, value: &StoredAutomation) -> Result<bool, sqlx::Error> {
        let result = sqlx::query("UPDATE automations SET name=?, kind=?, conversation_id=?, prompt=?, rrule=?, timezone=?, status=?, notification_policy=?, model_id=?, reasoning_effort=?, next_run_at=?, updated_at=? WHERE id=? AND (?='paused' OR EXISTS (SELECT 1 FROM bots WHERE id=automations.bot_id AND is_archived=0))")
            .bind(&value.name).bind(&value.kind).bind(&value.conversation_id).bind(&value.prompt)
            .bind(&value.rrule).bind(&value.timezone).bind(&value.status).bind(&value.notification_policy)
            .bind(&value.model_id).bind(&value.reasoning_effort).bind(&value.next_run_at).bind(&value.updated_at).bind(&value.id).bind(&value.status)
            .execute(&self.pool).await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn automation_run_by_id(
        &self,
        id: &str,
    ) -> Result<Option<StoredAutomationRun>, sqlx::Error> {
        sqlx::query("SELECT id, automation_id, scheduled_for, status, started_at, finished_at, error, message_id, conversation_id FROM automation_runs WHERE id=?")
            .bind(id).fetch_optional(&self.pool).await.map(|row|row.map(|row|stored_automation_run(&row)))
    }

    /// Atomic admission prevents overlap. The snapshot is the accepted work;
    /// schedule edits cannot rewrite it. Advancing from wall time coalesces misses.
    pub async fn claim_scheduled_automation(
        &self,
        id: &str,
        automation: &StoredAutomation,
        scheduled_for: &str,
        now: &str,
        next_run: Option<&str>,
        scheduled: bool,
    ) -> Result<bool, sqlx::Error> {
        let snapshot =
            serde_json::to_string(automation).map_err(|e| sqlx::Error::Encode(Box::new(e)))?;
        let mut tx = self.pool.begin().await?;
        let result = sqlx::query("INSERT OR IGNORE INTO automation_runs(id, automation_id, scheduled_for, status, started_at, automation_snapshot, conversation_id) SELECT ?, ?, ?, 'running', ?, ?, ? WHERE EXISTS (SELECT 1 FROM automations a JOIN bots b ON b.id=a.bot_id WHERE a.id=? AND a.updated_at=? AND b.is_archived=0 AND (a.scope_type != 'group_chat' OR EXISTS (SELECT 1 FROM channels c WHERE c.id=a.scope_id AND c.coordinator_bot_id=a.bot_id AND c.is_archived=0)) AND (?=0 OR (a.status='active' AND a.next_run_at=?))) AND NOT EXISTS (SELECT 1 FROM automation_runs WHERE automation_id=? AND status='running')")
            .bind(id).bind(&automation.id).bind(scheduled_for).bind(now).bind(snapshot).bind(&automation.conversation_id)
            .bind(&automation.id).bind(&automation.updated_at).bind(scheduled).bind(scheduled_for).bind(&automation.id)
            .execute(&mut *tx).await?;
        if result.rows_affected() != 1 {
            return Ok(false);
        }
        if scheduled {
            sqlx::query(
                "UPDATE automations SET next_run_at=?, last_run_at=?, updated_at=? WHERE id=?",
            )
            .bind(next_run)
            .bind(now)
            .bind(now)
            .bind(&automation.id)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(true)
    }

    /// Called once at startup. Re-materializing the same deterministic message
    /// is safe; dispatch admission preserves submitted/unknown attempts.
    pub async fn recoverable_automation_runs(
        &self,
    ) -> Result<Vec<(StoredAutomationRun, StoredAutomation)>, sqlx::Error> {
        let rows = sqlx::query("SELECT id, automation_id, scheduled_for, status, started_at, finished_at, error, message_id, conversation_id, automation_snapshot FROM automation_runs WHERE status='running' AND automation_snapshot IS NOT NULL")
            .fetch_all(&self.pool).await?;
        rows.iter()
            .map(|row| {
                let snapshot: String = row.get("automation_snapshot");
                serde_json::from_str(&snapshot)
                    .map(|value| (stored_automation_run(row), value))
                    .map_err(|e| sqlx::Error::Decode(Box::new(e)))
            })
            .collect()
    }
}

impl Store {
    pub async fn materialize_automation_message(
        &self,
        run_id: &str,
        device_id: &str,
        automation: &StoredAutomation,
        conversation_id: &str,
        now: &str,
    ) -> Result<StoredMessage, sqlx::Error> {
        use sha2::{Digest, Sha256};
        let mut tx = self.pool.begin().await?;
        let id: String = sqlx::query_scalar(
            "SELECT COALESCE(message_id, ?) FROM automation_runs WHERE id=? AND status='running'",
        )
        .bind(format!("automation-message:{run_id}"))
        .bind(run_id)
        .fetch_one(&mut *tx)
        .await?;
        sqlx::query("INSERT INTO conversation_metadata(id,bot_id,title,created_at,updated_at) VALUES (?,?,?,?,?) ON CONFLICT(id) DO NOTHING")
            .bind(conversation_id).bind(&automation.bot_id).bind(&automation.name).bind(now).bind(now).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO messages(id,device_id,client_message_id,body,body_sha256,conversation_id,state,created_at) VALUES (?,?,?,?,?,?,'accepted_by_wonder',?) ON CONFLICT(id) DO NOTHING")
            .bind(&id).bind(device_id).bind(format!("automation:{run_id}")).bind(&automation.prompt).bind(hex::encode(Sha256::digest(automation.prompt.as_bytes()))).bind(conversation_id).bind(now).execute(&mut *tx).await?;
        sqlx::query("UPDATE automation_runs SET message_id=?, conversation_id=? WHERE id=?")
            .bind(&id)
            .bind(conversation_id)
            .bind(run_id)
            .execute(&mut *tx)
            .await?;
        if automation.scope_type != "group_chat" {
            sqlx::query("INSERT INTO dispatch_work(message_id) VALUES (?) ON CONFLICT(message_id) DO NOTHING").bind(&id).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        self.message_by_id(&id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)
    }

    pub async fn automation_snapshot_for_run(
        &self,
        run_id: &str,
    ) -> Result<Option<StoredAutomation>, sqlx::Error> {
        let value: Option<String> =
            sqlx::query_scalar("SELECT automation_snapshot FROM automation_runs WHERE id=?")
                .bind(run_id)
                .fetch_optional(&self.pool)
                .await?
                .flatten();
        value
            .map(|value| serde_json::from_str(&value).map_err(|e| sqlx::Error::Decode(Box::new(e))))
            .transpose()
    }

    /// Reconcile terminal durable message states, including Group runs and
    /// completions whose original notification arrived during an outage.
    pub async fn reconcile_automation_runs(&self, now: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE automation_runs SET error='Wonder is checking whether this run was received. Open its conversation for recovery; do not submit it again.' WHERE status='running' AND message_id IN (SELECT id FROM messages WHERE state='uncertain')")
            .execute(&self.pool).await?;
        sqlx::query("UPDATE automation_runs SET error=NULL WHERE status='running' AND message_id IN (SELECT id FROM messages WHERE state IN ('accepted_by_codex','streaming'))")
            .execute(&self.pool).await?;
        sqlx::query("UPDATE automation_runs SET status=CASE WHEN (SELECT state FROM messages WHERE id=automation_runs.message_id)='completed' THEN 'completed' ELSE 'failed' END, finished_at=?, error=CASE WHEN (SELECT state FROM messages WHERE id=automation_runs.message_id)='completed' THEN NULL ELSE 'The run stopped before completing. Open its conversation for details.' END WHERE status='running' AND message_id IN (SELECT id FROM messages WHERE state IN ('completed','failed','interrupted'))")
            .bind(now).execute(&self.pool).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn fixture(store: &Store) -> StoredAutomation {
        store
            .upsert_owner_device("owner", "Owner", "{}", "2026-09-01T00:00:00.000Z")
            .await
            .unwrap();
        store
            .upsert_bot(
                "bot",
                "Bot",
                "Helper",
                "Help",
                "/tmp/automation-test",
                "default",
                None,
                None,
                "2026-09-01T00:00:00.000Z",
            )
            .await
            .unwrap();
        store
            .insert_automation(
                "auto",
                "Daily",
                "standalone",
                "bot",
                Some("automation:auto"),
                "Original task",
                "FREQ=DAILY;BYHOUR=9",
                "UTC",
                "active",
                "all_runs",
                None,
                None,
                Some("2026-09-01T09:00:00.000Z"),
                "2026-09-01T00:00:00.000Z",
            )
            .await
            .unwrap()
    }
    #[tokio::test]
    async fn claims_are_atomic_and_coalesce_missed_occurrences() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let automation = fixture(&store).await;
        let now = "2026-09-08T12:00:00.000Z";
        let next = "2026-09-09T09:00:00.000Z";
        assert!(store
            .claim_scheduled_automation(
                "run1",
                &automation,
                automation.next_run_at.as_deref().unwrap(),
                now,
                Some(next),
                true
            )
            .await
            .unwrap());
        let current = store.automation_by_id("auto").await.unwrap().unwrap();
        assert_eq!(current.next_run_at.as_deref(), Some(next));
        assert!(store.list_due_automations(now).await.unwrap().is_empty());
        assert!(!store
            .claim_scheduled_automation("run2", &current, "manual", now, None, false)
            .await
            .unwrap());
        assert!(!store
            .claim_scheduled_automation("run1", &current, "manual", now, None, false)
            .await
            .unwrap());
        store
            .finish_automation_run("run1", "completed", now, None, None)
            .await
            .unwrap();
        assert!(store
            .claim_scheduled_automation("run2", &current, "manual", now, None, false)
            .await
            .unwrap());
        let current = store.automation_by_id("auto").await.unwrap().unwrap();
        assert_eq!(current.last_attempt_at.as_deref(), Some(now));
        assert_eq!(current.last_success_at.as_deref(), Some(now));
    }
    #[tokio::test]
    async fn edits_preserve_accepted_snapshot_and_reject_stale_schedule_claims() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let original = fixture(&store).await;
        assert!(store
            .claim_scheduled_automation(
                "run1",
                &original,
                "manual",
                "2026-09-01T01:00:00.000Z",
                None,
                false
            )
            .await
            .unwrap());
        let mut edited = original.clone();
        edited.prompt = "New task".into();
        edited.rrule = "FREQ=HOURLY".into();
        edited.timezone = "America/New_York".into();
        edited.status = "paused".into();
        edited.next_run_at = None;
        edited.updated_at = "2026-09-01T02:00:00.000Z".into();
        assert!(store.update_automation(&edited).await.unwrap());
        assert_eq!(
            store
                .automation_snapshot_for_run("run1")
                .await
                .unwrap()
                .unwrap()
                .prompt,
            "Original task"
        );
        let actual = store.automation_by_id("auto").await.unwrap().unwrap();
        assert_eq!(actual.prompt, "New task");
        assert_eq!(actual.next_run_at, None);
        assert_eq!(actual.status, "paused");
        store
            .finish_automation_run("run1", "completed", "later", None, None)
            .await
            .unwrap();
        assert!(!store
            .claim_scheduled_automation(
                "run2",
                &original,
                original.next_run_at.as_deref().unwrap(),
                "now",
                Some("next"),
                true
            )
            .await
            .unwrap());
        store.set_bot_archived("bot", true).await.unwrap();
        assert!(!store
            .claim_scheduled_automation("run3", &actual, "manual", "now", None, false)
            .await
            .unwrap());
    }
    #[tokio::test]
    async fn restart_materializes_once_and_does_not_replay_unknown_dispatch() {
        let directory = tempfile::tempdir().unwrap();
        let url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("store.sqlite").display()
        );
        let store = Store::connect(&url).await.unwrap();
        let automation = fixture(&store).await;
        assert!(store
            .claim_scheduled_automation(
                "run1",
                &automation,
                "manual",
                "2026-09-01T01:00:00.000Z",
                None,
                false
            )
            .await
            .unwrap());
        store.pool.close().await;
        let store = Store::connect(&url).await.unwrap();
        let runs = store.recoverable_automation_runs().await.unwrap();
        assert_eq!(runs.len(), 1);
        let message = store
            .materialize_automation_message(
                "run1",
                "owner",
                &runs[0].1,
                "automation:auto",
                "2026-09-01T01:00:00.000Z",
            )
            .await
            .unwrap();
        assert!(store.claim_message_for_dispatch(&message.id).await.unwrap());
        store
            .begin_dispatch_submission_with_context(&message.id, "thread", None)
            .await
            .unwrap();
        store.pool.close().await;
        let store = Store::connect(&url).await.unwrap();
        store.recover_dispatch_claims().await.unwrap();
        store
            .upsert_owner_device("new-owner", "Owner", "{}", "2026-09-02T00:00:00.000Z")
            .await
            .unwrap();
        let recovered = store
            .materialize_automation_message(
                "run1",
                "new-owner",
                &automation,
                "automation:auto",
                "2026-09-01T01:00:00.000Z",
            )
            .await
            .unwrap();
        assert_eq!(recovered.id, message.id);
        assert!(!store.claim_message_for_dispatch(&message.id).await.unwrap());
        assert!(store.pending_dispatch_messages().await.unwrap().is_empty());
        let run = store.automation_run_by_id("run1").await.unwrap().unwrap();
        assert_eq!(run.conversation_id.as_deref(), Some("automation:auto"));
        assert_eq!(run.status, "running");
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM messages")
            .fetch_one(&store.pool)
            .await
            .unwrap();
        assert_eq!(count, 1);
    }
    #[tokio::test]
    async fn run_terminal_state_reconciles_from_durable_message() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let automation = fixture(&store).await;
        store
            .claim_scheduled_automation("run1", &automation, "manual", "now", None, false)
            .await
            .unwrap();
        let message = store
            .materialize_automation_message("run1", "owner", &automation, "automation:auto", "now")
            .await
            .unwrap();
        store
            .update_message_delivery(
                &message.id,
                "accepted_by_codex",
                Some("thread"),
                Some("turn"),
            )
            .await
            .unwrap();
        store.complete_message_if_active(&message.id).await.unwrap();
        store
            .reconcile_automation_runs("2026-09-01T02:00:00.000Z")
            .await
            .unwrap();
        assert_eq!(
            store
                .automation_run_by_id("run1")
                .await
                .unwrap()
                .unwrap()
                .status,
            "completed"
        );
        assert_eq!(
            store
                .automation_by_id("auto")
                .await
                .unwrap()
                .unwrap()
                .last_success_at
                .as_deref(),
            Some("2026-09-01T02:00:00.000Z")
        );
    }
}
