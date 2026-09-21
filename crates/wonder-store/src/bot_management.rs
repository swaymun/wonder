use super::*;

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BotFileRequest {
    pub id: String,
    pub bot_id: String,
    pub path: String,
    pub access: String,
    pub use_as_working_directory: bool,
    pub state: String,
}

impl StoredBot {
    pub fn effective_permission_profile(&self) -> &str {
        match self.permission_mode.as_deref() {
            Some("read-only") => ":read-only",
            Some("workspace") => ":workspace",
            Some("full-access") => ":danger-full-access",
            _ => &self.permission_profile,
        }
    }
    pub fn approval_policy(&self) -> &'static str {
        match self.permission_mode.as_deref() {
            Some("read-only" | "workspace") => "on-request",
            _ => "never",
        }
    }

    pub fn execution_directory(&self) -> &str {
        self.working_directory
            .as_deref()
            .unwrap_or(&self.workspace_path)
    }
}

impl Store {
    pub async fn update_pending_execution_bot(
        &self,
        conversation: &str,
        id: &str,
        revision: i64,
        bot: &StoredBot,
    ) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let changed = sqlx::query("UPDATE messages SET queue_revision=queue_revision+1 WHERE id=? AND conversation_id=? AND queue_revision=? AND state='accepted_by_wonder' AND id IN (SELECT message_id FROM dispatch_work)")
            .bind(id).bind(conversation).bind(revision).execute(&mut *tx).await?.rows_affected() == 1;
        if changed {
            sqlx::query("INSERT INTO message_execution_settings(message_id,model,reasoning_effort,service_tier,permission_mode,approval_mode,permission_profile,working_directory) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(message_id) DO UPDATE SET model=excluded.model,reasoning_effort=excluded.reasoning_effort,service_tier=excluded.service_tier,permission_mode=excluded.permission_mode,approval_mode=excluded.approval_mode,permission_profile=excluded.permission_profile,working_directory=excluded.working_directory")
                .bind(id).bind(&bot.model).bind(&bot.reasoning_effort).bind(&bot.service_tier).bind(&bot.permission_mode).bind(&bot.approval_mode).bind(&bot.permission_profile).bind(&bot.working_directory).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(changed)
    }

    /// Resolve a queued message with its acceptance-time execution choices.
    pub async fn message_execution_bot(
        &self,
        message: &str,
        mut bot: StoredBot,
    ) -> Result<(StoredBot, bool), sqlx::Error> {
        let row = sqlx::query("SELECT model,reasoning_effort,service_tier,permission_mode,approval_mode,permission_profile,working_directory FROM message_execution_settings WHERE message_id=?")
            .bind(message).fetch_optional(&self.pool).await?;
        if let Some(row) = row {
            let conservative_directory = bot.workspace_path.clone();
            bot.model = row.get("model");
            bot.reasoning_effort = row.get("reasoning_effort");
            bot.service_tier = row.get("service_tier");
            bot.permission_mode = row.get("permission_mode");
            bot.approval_mode = row.get("approval_mode");
            bot.permission_profile = row.get("permission_profile");
            bot.working_directory = row
                .get::<Option<String>, _>("working_directory")
                .or(Some(conservative_directory));
            return Ok((bot, true));
        }
        Ok((bot, false))
    }

    pub async fn reserve_group_creation(&self, id: &str, hash: &str) -> Result<bool, sqlx::Error> {
        sqlx::query("INSERT OR IGNORE INTO group_creation_requests VALUES(?,?)")
            .bind(id)
            .bind(hash)
            .execute(&self.pool)
            .await?;
        Ok(sqlx::query_scalar::<_, String>(
            "SELECT payload_hash FROM group_creation_requests WHERE request_id=?",
        )
        .bind(id)
        .fetch_one(&self.pool)
        .await?
            == hash)
    }

    /// Reservation outlives a lost HTTP response or interrupted runtime activation.
    pub async fn reserve_bot_creation(&self, id: &str, hash: &str) -> Result<bool, sqlx::Error> {
        sqlx::query("INSERT OR IGNORE INTO bot_creation_requests(request_id,bot_id,payload_hash) SELECT ?,?,? WHERE NOT EXISTS(SELECT 1 FROM bots WHERE id=?)")
            .bind(id).bind(id).bind(hash).bind(id).execute(&self.pool).await?;
        Ok(sqlx::query_scalar::<_, String>(
            "SELECT payload_hash FROM bot_creation_requests WHERE request_id=?",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?
        .is_some_and(|saved| saved == hash))
    }
    pub async fn finish_bot_creation(&self, id: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE bot_creation_requests SET completed=1 WHERE bot_id=?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
    pub async fn update_managed_bot(
        &self,
        bot: &StoredBot,
        clear_overrides: [bool; 3],
    ) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("UPDATE bots SET name=?,role=?,system_prompt=?,model=?,reasoning_effort=?,service_tier=?,avatar_color=?,avatar_shape=?,avatar_palette=?,avatar_legacy_color=?,working_directory=?,permission_mode=?,approval_mode=? WHERE id=?")
            .bind(&bot.name).bind(&bot.role).bind(&bot.system_prompt).bind(&bot.model).bind(&bot.reasoning_effort).bind(&bot.service_tier).bind(&bot.avatar_color).bind(&bot.avatar_shape).bind(&bot.avatar_palette).bind(&bot.avatar_legacy_color).bind(&bot.working_directory).bind(&bot.permission_mode).bind(&bot.approval_mode).bind(&bot.id).execute(&mut *tx).await?;
        // An explicitly chosen Bot default must also win in previously customized chats.
        sqlx::query("UPDATE conversation_settings SET model=CASE WHEN ? THEN NULL ELSE model END, reasoning_effort=CASE WHEN ? THEN NULL ELSE reasoning_effort END, service_tier=CASE WHEN ? THEN NULL ELSE service_tier END WHERE conversation_id IN (SELECT id FROM conversation_metadata WHERE bot_id=?)")
            .bind(clear_overrides[0]).bind(clear_overrides[1]).bind(clear_overrides[2]).bind(&bot.id)
            .execute(&mut *tx).await?;
        if bot.permission_mode.is_some() {
            sqlx::query("UPDATE bot_file_access SET applied_revision=revision WHERE bot_id=?")
                .bind(&bot.id)
                .execute(&mut *tx)
                .await?;
        }
        sqlx::query("UPDATE conversation_metadata SET title=? WHERE id=(SELECT conversation_id FROM bot_workspaces WHERE bot_id=?)")
            .bind(&bot.name).bind(&bot.id).execute(&mut *tx).await?;
        tx.commit().await
    }
    pub async fn save_bot_presentation(
        &self,
        id: &str,
        shape: Option<&str>,
        palette: Option<&str>,
        color: Option<&str>,
        directory: Option<&str>,
    ) -> Result<(), sqlx::Error> {
        let derived_color = palette
            .and_then(crate::avatar::palette)
            .map(|palette| palette.body);
        sqlx::query("UPDATE bots SET avatar_shape=COALESCE(?,avatar_shape), avatar_palette=COALESCE(?,avatar_palette), avatar_color=COALESCE(?,avatar_color), avatar_legacy_color=COALESCE(?,avatar_legacy_color), working_directory=COALESCE(?,working_directory) WHERE id=?")
            .bind(shape).bind(palette).bind(derived_color.or(color)).bind(color).bind(directory).bind(id).execute(&self.pool).await?;
        // The primary conversation follows a rename; separately named chats do not.
        sqlx::query("UPDATE conversation_metadata SET title=(SELECT name FROM bots WHERE id=?) WHERE id=(SELECT conversation_id FROM bot_workspaces WHERE bot_id=?)")
            .bind(id).bind(id).execute(&self.pool).await?;
        Ok(())
    }
    pub async fn bot_has_work(&self, id: &str) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM messages m JOIN conversation_metadata c ON c.id=m.conversation_id WHERE c.bot_id=? AND m.state IN ('accepted_by_wonder','dispatching_to_codex','accepted_by_codex','streaming','uncertain')) OR EXISTS(SELECT 1 FROM group_runs g WHERE g.state NOT IN ('completed','failed','cancelled') AND (json_extract(g.snapshot_json,'$.coordinator_bot_id')=? OR EXISTS(SELECT 1 FROM json_each(g.snapshot_json,'$.members') WHERE json_extract(value,'$.bot_id')=?))) OR EXISTS(SELECT 1 FROM automation_runs r JOIN automations a ON a.id=r.automation_id WHERE a.bot_id=? AND r.status='running')")
            .bind(id).bind(id).bind(id).bind(id).fetch_one(&self.pool).await
    }
    pub async fn change_group_lead(&self, group: &str, bot: &str) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let changed=sqlx::query("UPDATE channels SET coordinator_bot_id=? WHERE id=? AND EXISTS(SELECT 1 FROM channel_members m JOIN bots b ON b.id=m.bot_id WHERE m.channel_id=? AND m.bot_id=? AND b.is_archived=0) AND NOT EXISTS(SELECT 1 FROM group_runs WHERE channel_id=? AND state NOT IN ('completed','failed','cancelled'))")
            .bind(bot).bind(group).bind(group).bind(bot).bind(group).execute(&mut *tx).await?.rows_affected()==1;
        if changed {
            sqlx::query("UPDATE channel_members SET role=CASE WHEN bot_id=? THEN 'coordinator' ELSE 'worker' END WHERE channel_id=?").bind(bot).bind(group).execute(&mut *tx).await?;
            sqlx::query("UPDATE conversation_metadata SET bot_id=? WHERE id=(SELECT conversation_id FROM channels WHERE id=?)").bind(bot).bind(group).execute(&mut *tx).await?;
            sqlx::query("UPDATE automations SET bot_id=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE scope_type='group_chat' AND scope_id=?").bind(bot).bind(group).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(changed)
    }
    pub async fn bot_was_deleted(&self, id: &str) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM bot_deletions WHERE bot_id=?)")
            .bind(id)
            .fetch_one(&self.pool)
            .await
    }
    pub async fn bot_leads_group(&self, id: &str) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM channels WHERE coordinator_bot_id=?)")
            .bind(id)
            .fetch_one(&self.pool)
            .await
    }
    pub async fn archive_bot_safely(&self, id: &str, archived: bool) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("UPDATE bots SET is_archived=? WHERE id=? AND NOT EXISTS(SELECT 1 FROM bot_deletions WHERE bot_id=? AND completed=0)")
            .bind(archived).bind(id).bind(id).execute(&mut *tx).await?;
        if archived {
            sqlx::query("UPDATE automations SET status='paused',next_run_at=NULL WHERE bot_id=?")
                .bind(id)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await
    }
    pub async fn begin_bot_deletion(&self, id: &str) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT OR IGNORE INTO bot_deletions(bot_id,workspace_path) SELECT id,workspace_path FROM bots WHERE id=? AND is_archived=1")
            .bind(id).execute(&self.pool).await?;
        Ok(())
    }
    pub async fn pending_bot_deletions(&self) -> Result<Vec<(String, String)>, sqlx::Error> {
        sqlx::query_as("SELECT bot_id,workspace_path FROM bot_deletions WHERE completed=0")
            .fetch_all(&self.pool)
            .await
    }
    /// Remove direct data in one transaction while retaining shared Group messages.
    pub async fn finish_bot_deletion(&self, id: &str) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("UPDATE conversation_metadata SET bot_id=(SELECT coordinator_bot_id FROM channels WHERE conversation_id=conversation_metadata.id) WHERE bot_id=? AND id IN (SELECT conversation_id FROM channels)").bind(id).execute(&mut *tx).await?;
        let conversations: Vec<String> = sqlx::query_scalar("SELECT id FROM conversation_metadata WHERE bot_id=? AND id NOT IN (SELECT conversation_id FROM channels)")
            .bind(id).fetch_all(&mut *tx).await?;
        // Ownership points at both parent and child metadata. Remove the
        // binding before either side is deleted; the child metadata is already
        // included in `conversations` because it inherits the parent Bot.
        sqlx::query("DELETE FROM subagent_ownership WHERE conversation_id IN (SELECT id FROM conversation_metadata WHERE bot_id=?) OR parent_conversation_id IN (SELECT id FROM conversation_metadata WHERE bot_id=?)")
            .bind(id)
            .bind(id)
            .execute(&mut *tx)
            .await?;
        for conversation in conversations {
            sqlx::query("DELETE FROM approvals WHERE thread_id IN (SELECT codex_thread_id FROM conversations WHERE id=?)")
                .bind(&conversation).execute(&mut *tx).await?;
            sqlx::query("DELETE FROM pending_app_server_notifications WHERE thread_id IN (SELECT codex_thread_id FROM conversations WHERE id=?)")
                .bind(&conversation).execute(&mut *tx).await?;
            for statement in [
                "DELETE FROM async_questions WHERE conversation_id=?",
                "DELETE FROM assistant_messages WHERE conversation_id=?",
                "DELETE FROM conversation_settings WHERE conversation_id=?",
                "DELETE FROM conversation_files WHERE conversation_id=?",
                "DELETE FROM history_entries WHERE conversation_id=?",
                "DELETE FROM history_hydration WHERE conversation_id=?",
                "DELETE FROM messages WHERE conversation_id=?",
            ] {
                sqlx::query(statement)
                    .bind(&conversation)
                    .execute(&mut *tx)
                    .await?;
            }
            sqlx::query("DELETE FROM events WHERE json_extract(payload_json,'$.conversationId')=? OR json_extract(payload_json,'$.event.conversationId')=?")
                .bind(&conversation).bind(&conversation).execute(&mut *tx).await?;
            sqlx::query(
                "DELETE FROM sync_journal WHERE conversation_id=? AND payload_json IS NOT NULL",
            )
            .bind(&conversation)
            .execute(&mut *tx)
            .await?;
            sqlx::query("DELETE FROM conversations WHERE id=?")
                .bind(&conversation)
                .execute(&mut *tx)
                .await?;
            sqlx::query("DELETE FROM conversation_metadata WHERE id=?")
                .bind(&conversation)
                .execute(&mut *tx)
                .await?;
        }
        sqlx::query("UPDATE channel_messages SET historical_author_name=(SELECT name FROM bots WHERE id=?),author_bot_id=NULL WHERE author_bot_id=?")
            .bind(id).bind(id).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM channel_members WHERE bot_id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM automations WHERE bot_id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM search_documents WHERE bot_id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM bots WHERE id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE bot_deletions SET completed=1 WHERE bot_id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await
    }
    pub async fn add_bot_file_request(
        &self,
        request: &BotFileRequest,
    ) -> Result<bool, sqlx::Error> {
        sqlx::query("INSERT OR IGNORE INTO bot_file_requests(id,bot_id,path,access,use_as_working_directory) VALUES(?,?,?,?,?)")
            .bind(&request.id).bind(&request.bot_id).bind(&request.path).bind(&request.access).bind(request.use_as_working_directory).execute(&self.pool).await?;
        sqlx::query_scalar::<_,bool>("SELECT bot_id=? AND path=? AND access=? AND use_as_working_directory=? FROM bot_file_requests WHERE id=?")
            .bind(&request.bot_id).bind(&request.path).bind(&request.access).bind(request.use_as_working_directory).bind(&request.id).fetch_one(&self.pool).await
    }
    pub async fn bot_file_requests(&self, id: &str) -> Result<Vec<BotFileRequest>, sqlx::Error> {
        let rows =
            sqlx::query("SELECT * FROM bot_file_requests WHERE bot_id=? ORDER BY rowid DESC")
                .bind(id)
                .fetch_all(&self.pool)
                .await?;
        Ok(rows
            .into_iter()
            .map(|r| BotFileRequest {
                id: r.get("id"),
                bot_id: r.get("bot_id"),
                path: r.get("path"),
                access: r.get("access"),
                use_as_working_directory: r.get("use_as_working_directory"),
                state: r.get("state"),
            })
            .collect())
    }
    pub async fn approve_bot_folder(
        &self,
        request: &BotFileRequest,
        access: &BotFileAccess,
        followup: Option<&str>,
    ) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let changed = sqlx::query("UPDATE bot_file_requests SET state='approved' WHERE bot_id=? AND id=? AND state='pending'")
            .bind(&request.bot_id).bind(&request.id).execute(&mut *tx).await?.rows_affected();
        if changed != 1 {
            return Ok(false);
        }
        sqlx::query("INSERT INTO bot_file_access(bot_id,revision,applied_revision,read_roots_json,write_roots_json) VALUES(?,?,?,?,?) ON CONFLICT(bot_id) DO UPDATE SET revision=excluded.revision,applied_revision=excluded.applied_revision,read_roots_json=excluded.read_roots_json,write_roots_json=excluded.write_roots_json")
            .bind(&request.bot_id).bind(access.revision + 1).bind(access.revision + 1)
            .bind(serde_json::to_string(&access.read_roots).unwrap()).bind(serde_json::to_string(&access.write_roots).unwrap()).execute(&mut *tx).await?;
        if request.use_as_working_directory {
            sqlx::query("UPDATE bots SET working_directory=? WHERE id=?")
                .bind(&request.path)
                .bind(&request.bot_id)
                .execute(&mut *tx)
                .await?;
        }
        if let Some(body) = followup {
            use sha2::{Digest, Sha256};
            let conversation: String =
                sqlx::query_scalar("SELECT conversation_id FROM bot_workspaces WHERE bot_id=?")
                    .bind(&request.bot_id)
                    .fetch_one(&mut *tx)
                    .await?;
            let id = uuid::Uuid::new_v4().to_string();
            sqlx::query("INSERT INTO messages(id,device_id,client_message_id,body,body_sha256,conversation_id,state,created_at) VALUES (?,'wonder-desktop',?,?,?,?,'accepted_by_wonder',strftime('%Y-%m-%dT%H:%M:%fZ','now'))")
                .bind(&id).bind(&id).bind(body).bind(hex::encode(Sha256::digest(body.as_bytes()))).bind(conversation).execute(&mut *tx).await?;
            sqlx::query("INSERT INTO bot_workspace_followups(request_id,message_id) VALUES (?,?)")
                .bind(&request.id)
                .bind(&id)
                .execute(&mut *tx)
                .await?;
            sqlx::query("INSERT INTO dispatch_work(message_id) VALUES (?)")
                .bind(&id)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        Ok(true)
    }
    pub async fn resolve_bot_file_request(
        &self,
        bot: &str,
        id: &str,
        accepted: bool,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "UPDATE bot_file_requests SET state=? WHERE id=? AND bot_id=? AND state='pending'",
        )
        .bind(if accepted { "approved" } else { "declined" })
        .bind(id)
        .bind(bot)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn fixture() -> Store {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store.ensure_local_desktop("now").await.unwrap();
        for id in ["one", "two"] {
            store
                .upsert_bot(
                    id,
                    id,
                    "purpose",
                    "instructions",
                    &format!("/tmp/{id}"),
                    id,
                    None,
                    None,
                    "1",
                )
                .await
                .unwrap();
            store.ensure_bot_workspace(id, id, "1").await.unwrap();
        }
        store
    }
    #[tokio::test]
    async fn startup_question_recovers_once_and_does_not_require_an_answer() {
        let store = fixture().await;
        store
            .initialize_bot("one", "private initialization", "2")
            .await
            .unwrap();
        assert!(store
            .bot_initialization("bot:one", 1)
            .await
            .unwrap()
            .unwrap()
            .question_id
            .is_none());
        assert!(store
            .bot_initialization("bot:two", 1)
            .await
            .unwrap()
            .is_none());
        assert!(store.pending_queue("bot:one").await.unwrap().is_empty());
        let init = store
            .bot_initialization_messages("bot:one")
            .await
            .unwrap()
            .remove(0);
        assert!(!store
            .edit_pending("bot:one", &init.id, 1, Some(("edit", "hash")))
            .await
            .unwrap());
        store
            .update_message_delivery(&init.id, "failed", None, None)
            .await
            .unwrap();
        let recovered = store
            .bot_initialization("bot:one", 10)
            .await
            .unwrap()
            .unwrap();
        assert!(recovered.question_id.is_some());
        let repeated = store
            .bot_initialization("bot:one", 11)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(recovered.question_id, repeated.question_id);
        store
            .save_async_question(
                "bot:one",
                "late-thread",
                "late-turn",
                "wonder-purpose",
                "[]",
                300000,
            )
            .await
            .unwrap();
        let questions = store.async_questions("bot:one", 12).await.unwrap();
        assert_eq!(questions.len(), 1);
        assert_eq!(questions[0].state, "pending");
        assert_eq!(
            questions[0].questions[0]["title"],
            "What should I help with?"
        );
        store
            .insert_message(
                "wonder-desktop",
                "user-task",
                "Build an app",
                "hash",
                "bot:one",
                "3",
            )
            .await
            .unwrap();
        assert!(store
            .bot_initialization("bot:one", 13)
            .await
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn folder_approval_and_hidden_followup_commit_once_and_roll_back_together() {
        let store = fixture().await;
        let request = BotFileRequest {
            id: "request".into(),
            bot_id: "one".into(),
            path: "/project".into(),
            access: "write".into(),
            use_as_working_directory: true,
            state: "pending".into(),
        };
        store.add_bot_file_request(&request).await.unwrap();
        let mut access = store.bot_file_access("one").await.unwrap();
        access.write_roots.push("/project".into());
        // A failed queue insertion must not leave an approved request behind.
        sqlx::query("CREATE TRIGGER fail_followup BEFORE INSERT ON dispatch_work BEGIN SELECT RAISE(ABORT,'test failure'); END;").execute(&store.pool).await.unwrap();
        assert!(store
            .approve_bot_folder(&request, &access, Some("private followup"))
            .await
            .is_err());
        assert_eq!(
            store.bot_file_requests("one").await.unwrap()[0].state,
            "pending"
        );
        assert_ne!(
            store
                .bot("one")
                .await
                .unwrap()
                .unwrap()
                .working_directory
                .as_deref(),
            Some("/project")
        );
        sqlx::query("DROP TRIGGER fail_followup")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(store
            .approve_bot_folder(&request, &access, Some("private followup"))
            .await
            .unwrap());
        assert!(!store
            .approve_bot_folder(&request, &access, Some("duplicate"))
            .await
            .unwrap());
        let followups = store
            .bot_workspace_followup_messages("bot:one")
            .await
            .unwrap();
        assert_eq!(followups.len(), 1);
        assert_eq!(followups[0].body, "private followup");
        assert!(store.is_durable_dispatch(&followups[0].id).await.unwrap());
        assert!(store.pending_queue("bot:one").await.unwrap().is_empty());
        assert_eq!(
            store
                .bot("one")
                .await
                .unwrap()
                .unwrap()
                .working_directory
                .as_deref(),
            Some("/project")
        );
        assert!(store
            .bot_file_access("one")
            .await
            .unwrap()
            .write_roots
            .contains(&"/project".to_string()));
        assert_eq!(
            store
                .list_conversation_summaries()
                .await
                .unwrap()
                .iter()
                .find(|c| c.conversation_id == "bot:one")
                .unwrap()
                .message_count,
            0
        );
        assert!(store.search("private", 20).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn approval_upgrade_backfills_each_frozen_scope_without_broadening() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        let mut prior = sqlx::migrate!();
        prior.migrations = std::borrow::Cow::Owned(
            prior
                .migrations
                .iter()
                .filter(|m| m.version < 59)
                .cloned()
                .collect(),
        );
        prior.run(&pool).await.unwrap();
        let old = Store { pool };
        old.ensure_local_desktop("now").await.unwrap();
        for (id, scope) in [
            ("read", Some("read-only")),
            ("write", Some("workspace")),
            ("full", Some("full-access")),
            ("custom", None),
        ] {
            old.upsert_bot(
                id,
                id,
                "Helper",
                "Help",
                "/tmp",
                "custom-profile",
                None,
                None,
                "now",
            )
            .await
            .unwrap();
            sqlx::query("UPDATE bots SET permission_mode=? WHERE id=?")
                .bind(scope)
                .bind(id)
                .execute(&old.pool)
                .await
                .unwrap();
            sqlx::query("INSERT INTO messages(id,device_id,client_message_id,body_sha256,conversation_id,state,created_at) VALUES(?,'wonder-desktop',?,'hash','bot','accepted_by_wonder','now')").bind(id).bind(id).execute(&old.pool).await.unwrap();
            sqlx::query("INSERT INTO message_execution_settings(message_id,permission_mode,permission_profile) VALUES(?,?,'frozen-profile')").bind(id).bind(scope).execute(&old.pool).await.unwrap();
        }
        // Change the live Bot after the queue snapshots, before upgrading.
        sqlx::query("UPDATE bots SET permission_mode='full-access' WHERE id='read'")
            .execute(&old.pool)
            .await
            .unwrap();
        sqlx::migrate!().run(&old.pool).await.unwrap();
        for (id, scope, expected) in [
            ("read", Some("read-only"), Some("ask-for-approval")),
            ("write", Some("workspace"), Some("ask-for-approval")),
            ("full", Some("full-access"), Some("full-access")),
            ("custom", None, None),
        ] {
            let row = sqlx::query("SELECT permission_mode,permission_profile,approval_mode FROM message_execution_settings WHERE message_id=?").bind(id).fetch_one(&old.pool).await.unwrap();
            assert_eq!(
                row.get::<Option<String>, _>("permission_mode").as_deref(),
                scope
            );
            assert_eq!(
                row.get::<Option<String>, _>("approval_mode").as_deref(),
                expected
            );
            assert_eq!(row.get::<String, _>("permission_profile"), "frozen-profile");
            if id != "read" {
                let bot = old.bot(id).await.unwrap().unwrap();
                assert_eq!(bot.permission_mode.as_deref(), scope);
                assert_eq!(bot.approval_mode.as_deref(), expected);
                assert_eq!(bot.permission_profile, "custom-profile");
            }
        }
        let live = old.bot("read").await.unwrap().unwrap();
        assert_eq!(live.permission_mode.as_deref(), Some("full-access"));
        assert_eq!(live.approval_mode.as_deref(), Some("full-access"));
    }

    #[tokio::test]
    async fn working_directory_upgrade_backfill_uses_private_workspace_not_live_external_cwd() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        let mut prior = sqlx::migrate!();
        prior.migrations = std::borrow::Cow::Owned(
            prior
                .migrations
                .iter()
                .filter(|m| m.version < 61)
                .cloned()
                .collect(),
        );
        prior.run(&pool).await.unwrap();
        let old = Store { pool };
        old.ensure_local_desktop("now").await.unwrap();
        old.upsert_bot(
            "legacy",
            "Legacy",
            "Helper",
            "Help",
            "/tmp/legacy-private-home",
            "profile",
            None,
            None,
            "now",
        )
        .await
        .unwrap();
        let conversation = old
            .ensure_bot_workspace("legacy", "Legacy", "now")
            .await
            .unwrap();
        sqlx::query(
            "UPDATE bots SET working_directory='/tmp/live-external-project' WHERE id='legacy'",
        )
        .execute(&old.pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO messages(id,device_id,client_message_id,body,body_sha256,conversation_id,state,created_at) VALUES('legacy-message','wonder-desktop','legacy-client','queued','hash',?,'accepted_by_wonder','now')")
            .bind(&conversation)
            .execute(&old.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO message_execution_settings(message_id,permission_profile) VALUES('legacy-message','profile')")
            .execute(&old.pool)
            .await
            .unwrap();

        sqlx::migrate!().run(&old.pool).await.unwrap();
        let saved: String = sqlx::query_scalar(
            "SELECT working_directory FROM message_execution_settings WHERE message_id='legacy-message'",
        )
        .fetch_one(&old.pool)
        .await
        .unwrap();
        assert_eq!(saved, "/tmp/legacy-private-home");
        assert_ne!(saved, "/tmp/live-external-project");
    }

    #[tokio::test]
    async fn queued_messages_keep_their_accepted_settings_across_edits_and_retries() {
        let store = fixture().await;
        let mut bot = store.bot("one").await.unwrap().unwrap();
        bot.model = Some("first-model".into());
        bot.permission_mode = Some("read-only".into());
        bot.approval_mode = Some("ask-for-approval".into());
        store
            .update_managed_bot(&bot, [true, true, true])
            .await
            .unwrap();
        let conversation = bot.conversation_id.clone().unwrap();
        let MessageInsert::Inserted(first) = store
            .insert_dispatch_message(
                "wonder-desktop",
                "first",
                "hello",
                "hash",
                &conversation,
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        bot.model = Some("second-model".into());
        bot.permission_mode = Some("workspace".into());
        bot.approval_mode = Some("approve-for-me".into());
        store
            .update_managed_bot(&bot, [true, true, true])
            .await
            .unwrap();
        let MessageInsert::Inserted(second) = store
            .insert_dispatch_message(
                "wonder-desktop",
                "second",
                "again",
                "hash2",
                &conversation,
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        assert!(matches!(
            store
                .insert_dispatch_message(
                    "wonder-desktop",
                    "first",
                    "hello",
                    "hash",
                    &conversation,
                    &[],
                    "now",
                    true
                )
                .await
                .unwrap(),
            MessageInsert::Existing(_)
        ));
        let (original, frozen) = store
            .message_execution_bot(&first.id, bot.clone())
            .await
            .unwrap();
        assert!(frozen);
        assert_eq!(original.model.as_deref(), Some("first-model"));
        assert_eq!(original.permission_mode.as_deref(), Some("read-only"));
        assert_eq!(original.approval_mode.as_deref(), Some("ask-for-approval"));
        let (next, _) = store.message_execution_bot(&second.id, bot).await.unwrap();
        assert_eq!(next.model.as_deref(), Some("second-model"));
        assert_eq!(next.permission_mode.as_deref(), Some("workspace"));
        assert_eq!(next.approval_mode.as_deref(), Some("approve-for-me"));
        assert!(store
            .update_pending_execution_bot(&conversation, &first.id, 1, &next)
            .await
            .unwrap());
        assert!(!store
            .update_pending_execution_bot(&conversation, &first.id, 1, &original)
            .await
            .unwrap());
        let (edited, _) = store
            .message_execution_bot(&first.id, original.clone())
            .await
            .unwrap();
        assert_eq!(edited.model, next.model);
        store
            .update_message_delivery(&first.id, "streaming", Some("thread"), Some("turn"))
            .await
            .unwrap();
        assert!(!store
            .update_pending_execution_bot(&conversation, &first.id, 2, &original)
            .await
            .unwrap());
    }

    #[tokio::test]
    async fn queued_working_directories_survive_bot_switch_and_dispatch_recovery() {
        let store = fixture().await;
        let mut bot = store.bot("one").await.unwrap().unwrap();
        let conversation = bot.conversation_id.clone().unwrap();
        bot.working_directory = Some("/projects/alpha".into());
        store
            .update_managed_bot(&bot, [false, false, false])
            .await
            .unwrap();
        let MessageInsert::Inserted(first) = store
            .insert_dispatch_message(
                "wonder-desktop",
                "alpha",
                "Use alpha",
                "alpha-hash",
                &conversation,
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!()
        };

        bot.working_directory = Some("/projects/beta".into());
        store
            .update_managed_bot(&bot, [false, false, false])
            .await
            .unwrap();
        let MessageInsert::Inserted(second) = store
            .insert_dispatch_message(
                "wonder-desktop",
                "beta",
                "Use beta",
                "beta-hash",
                &conversation,
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!()
        };

        let current = store.bot("one").await.unwrap().unwrap();
        let (first_snapshot, first_frozen) = store
            .message_execution_bot(&first.id, current.clone())
            .await
            .unwrap();
        let (second_snapshot, second_frozen) = store
            .message_execution_bot(&second.id, current)
            .await
            .unwrap();
        assert!(first_frozen && second_frozen);
        assert_eq!(first_snapshot.execution_directory(), "/projects/alpha");
        assert_eq!(second_snapshot.execution_directory(), "/projects/beta");

        // Startup/retry recovery must not replace either accepted snapshot
        // with the Bot's current setting.
        store.recover_dispatch_claims().await.unwrap();
        let restarted_bot = store.bot("one").await.unwrap().unwrap();
        assert_eq!(
            store
                .message_execution_bot(&first.id, restarted_bot.clone())
                .await
                .unwrap()
                .0
                .execution_directory(),
            "/projects/alpha"
        );
        assert_eq!(
            store
                .message_execution_bot(&second.id, restarted_bot)
                .await
                .unwrap()
                .0
                .execution_directory(),
            "/projects/beta"
        );
    }

    #[tokio::test]
    async fn creation_reservation_detects_changed_payload_and_preserves_identity() {
        let store = fixture().await;
        assert!(store.reserve_bot_creation("request", "hash").await.unwrap());
        assert!(store.reserve_bot_creation("request", "hash").await.unwrap());
        assert!(!store
            .reserve_bot_creation("request", "different")
            .await
            .unwrap());
    }
    #[tokio::test]
    async fn archive_pauses_routines_and_restore_does_not_restart_them() {
        let store = fixture().await;
        sqlx::query("INSERT INTO automations(id,name,kind,bot_id,prompt,rrule,timezone,status,notification_policy,created_at,updated_at,next_run_at) VALUES('routine','Check','standalone','one','hello','FREQ=DAILY','UTC','active','all_runs','1','1','future')").execute(&store.pool).await.unwrap();
        store.archive_bot_safely("one", true).await.unwrap();
        let routine = store.automation_by_id("routine").await.unwrap().unwrap();
        assert_eq!(routine.status, "paused");
        assert!(routine.next_run_at.is_none());
        store.archive_bot_safely("one", false).await.unwrap();
        assert_eq!(
            store
                .automation_by_id("routine")
                .await
                .unwrap()
                .unwrap()
                .status,
            "paused"
        );
    }
    #[tokio::test]
    async fn deletion_removes_direct_data_preserves_group_history_and_other_bot() {
        let store = fixture().await;
        let direct = store
            .bot("one")
            .await
            .unwrap()
            .unwrap()
            .conversation_id
            .unwrap();
        store
            .create_channel(
                "group",
                "group-chat",
                "Group",
                None,
                "two",
                &[("two", "coordinator"), ("one", "worker")],
                "1",
            )
            .await
            .unwrap();
        let MessageInsert::Inserted(message) = store
            .insert_message(
                "wonder-desktop",
                "group-result",
                "Shared result",
                "hash",
                "group-chat",
                "2",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        store
            .add_channel_message(NewChannelMessage {
                channel_id: "group",
                message_id: &message.id,
                author_kind: "member",
                author_bot_id: Some("one"),
                phase: "worker",
                created_at: "2",
                presentation_kind: "message",
                outcome: None,
                retryable: false,
            })
            .await
            .unwrap();
        store
            .insert_message(
                "wonder-desktop",
                "direct",
                "Private result",
                "hash",
                &direct,
                "2",
            )
            .await
            .unwrap();
        assert!(store.bot_has_work("one").await.unwrap());
        sqlx::query("UPDATE messages SET state='completed'")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(!store.bot_has_work("one").await.unwrap());
        store.archive_bot_safely("one", true).await.unwrap();
        store.begin_bot_deletion("one").await.unwrap();
        store.finish_bot_deletion("one").await.unwrap();
        store.finish_bot_deletion("one").await.unwrap();
        assert!(store.bot("one").await.unwrap().is_none());
        assert!(store.bot("two").await.unwrap().is_some());
        let group = store.channel("group").await.unwrap().unwrap();
        assert_eq!(group.messages[0].body, "Shared result");
        assert_eq!(group.messages[0].author_bot_name.as_deref(), Some("one"));
        assert!(group.messages[0].author_bot_id.is_none());
        assert!(!group.members.iter().any(|m| m.bot_id == "one"));
        assert!(store.pending_bot_deletions().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn subagent_registration_is_atomic_and_deletion_removes_hidden_child() {
        let store = fixture().await;
        let parent = store.bot("one").await.unwrap().unwrap();
        let parent_conversation = parent.conversation_id.clone().unwrap();
        store
            .set_conversation_thread(&parent_conversation, "parent-thread", None, "now")
            .await
            .unwrap();
        let source = r#"{"subAgent":{"thread_spawn":{"parent_thread_id":"parent-thread","depth":1,"agent_nickname":"Scout"}}}"#;
        let registered = store
            .register_subagent_ownership(
                "child-conversation",
                &parent_conversation,
                "child-thread",
                "parent-thread",
                "one",
                "Scout",
                Some("Scout"),
                Some("research"),
                None,
                source,
                Some("runtime-a"),
                Some(true),
                "idle",
                None,
                "now",
            )
            .await
            .unwrap();
        assert_eq!(registered.runtime_id.as_deref(), Some("runtime-a"));
        assert_eq!(registered.can_accept_direct_input, Some(true));
        assert!(!store
            .list_conversation_summaries()
            .await
            .unwrap()
            .iter()
            .any(|summary| summary.conversation_id == "child-conversation"));
        assert!(!store
            .search("Scout", 20)
            .await
            .unwrap()
            .iter()
            .any(|result| result.conversation_id.as_deref() == Some("child-conversation")));

        let refreshed = store
            .register_subagent_ownership(
                "child-conversation",
                &parent_conversation,
                "child-thread",
                "parent-thread",
                "one",
                "Scout",
                Some("Scout"),
                Some("research"),
                None,
                source,
                Some("runtime-b"),
                Some(false),
                "completed",
                Some(true),
                "later",
            )
            .await
            .unwrap();
        assert_eq!(refreshed.runtime_id.as_deref(), Some("runtime-b"));
        assert_eq!(refreshed.can_accept_direct_input, Some(false));
        assert!(refreshed.is_archived);
        let immutable_error = store
            .register_subagent_ownership(
                "child-conversation",
                &parent_conversation,
                "child-thread",
                "different-parent-thread",
                "one",
                "Scout",
                None,
                None,
                None,
                source,
                Some("runtime-c"),
                Some(true),
                "idle",
                None,
                "later-2",
            )
            .await;
        assert!(immutable_error.is_err());

        // The ownership insert fails on the unique child thread after the
        // synthetic metadata/conversation attempt. The transaction must roll
        // both rows back, leaving no discoverable ghost child.
        assert!(store
            .register_subagent_ownership(
                "child-collision",
                &parent_conversation,
                "child-thread",
                "parent-thread",
                "one",
                "Collision",
                None,
                None,
                None,
                source,
                Some("runtime-a"),
                None,
                "idle",
                None,
                "later-3",
            )
            .await
            .is_err());
        assert!(
            sqlx::query("SELECT 1 FROM conversation_metadata WHERE id='child-collision'")
                .fetch_optional(&store.pool)
                .await
                .unwrap()
                .is_none()
        );

        store.archive_bot_safely("one", true).await.unwrap();
        store.begin_bot_deletion("one").await.unwrap();
        store.finish_bot_deletion("one").await.unwrap();
        assert!(store
            .subagent_ownership_for_thread("child-thread")
            .await
            .unwrap()
            .is_none());
        assert!(
            sqlx::query("SELECT 1 FROM conversation_metadata WHERE id='child-conversation'")
                .fetch_optional(&store.pool)
                .await
                .unwrap()
                .is_none()
        );
    }
    #[tokio::test]
    async fn settings_clear_overrides_and_update_primary_title_atomically() {
        let store = fixture().await;
        let mut bot = store.bot("one").await.unwrap().unwrap();
        bot.name = "Renamed".into();
        bot.avatar_color = Some("#167a7a".into());
        bot.model = Some("model".into());
        let conversation = bot.conversation_id.as_ref().unwrap();
        store
            .upsert_conversation_settings(
                conversation,
                Some("old"),
                Some("high"),
                Some("fast"),
                None,
                "2026-09-08T00:00:00Z",
            )
            .await
            .unwrap();

        store
            .update_managed_bot(&bot, [true, true, false])
            .await
            .unwrap();
        bot.model = None;
        store
            .update_managed_bot(&bot, [true, true, false])
            .await
            .unwrap();
        let settings = store
            .conversation_settings(bot.conversation_id.as_ref().unwrap())
            .await
            .unwrap()
            .unwrap();
        assert!(settings.model.is_none());
        assert!(settings.reasoning_effort.is_none());
        assert_eq!(settings.service_tier.as_deref(), Some("fast"));
        let actual = store.bot("one").await.unwrap().unwrap();
        assert_eq!(actual.name, "Renamed");
        assert!(actual.model.is_none());
        assert_eq!(actual.avatar_color, bot.avatar_color);
        let title: String =
            sqlx::query_scalar("SELECT title FROM conversation_metadata WHERE id=?")
                .bind(actual.conversation_id)
                .fetch_one(&store.pool)
                .await
                .unwrap();
        assert_eq!(title, "Renamed");
    }
}
