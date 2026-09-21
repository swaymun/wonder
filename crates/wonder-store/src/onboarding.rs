use super::*;

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BotInitialization {
    pub question_id: Option<String>,
}

impl Store {
    /// Only brand-new conversations wait for initialization. A saved question
    /// unlocks sending, whether the owner answers it, skips it, or starts a task.
    pub async fn bot_initialization(
        &self,
        conversation: &str,
        now_ms: i64,
    ) -> Result<Option<BotInitialization>, sqlx::Error> {
        let initial = self.bot_initialization_messages(conversation).await?;
        let Some(message) = initial.first() else {
            return Ok(None);
        };
        let has_work: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM messages m WHERE m.conversation_id=? AND NOT EXISTS(SELECT 1 FROM bot_initializations i WHERE i.message_id=m.id) AND NOT EXISTS(SELECT 1 FROM bot_workspace_followups f WHERE f.message_id=m.id))")
            .bind(conversation).fetch_one(&self.pool).await?;
        if has_work {
            return Ok(None);
        }

        let existing: Option<String> = sqlx::query_scalar("SELECT id FROM async_questions WHERE conversation_id=? AND item_id='wonder-purpose' ORDER BY rowid LIMIT 1")
            .bind(conversation).fetch_optional(&self.pool).await?;
        if existing.is_some() {
            return Ok(Some(BotInitialization {
                question_id: existing,
            }));
        }
        // Repair a failed/interrupted startup without another model request.
        // The purpose question has a conversation-wide identity, so a late
        // runtime notification cannot create a second one after recovery.
        if matches!(
            message.state.as_str(),
            "completed" | "failed" | "interrupted" | "safe_to_retry" | "uncertain"
        ) {
            let fallback = format!("wonder-initialization:{}", message.id);
            self.save_async_question(
                conversation,
                message.codex_thread_id.as_deref().unwrap_or(&fallback),
                message.codex_turn_id.as_deref().unwrap_or(&fallback),
                "wonder-purpose",
                &serde_json::json!([{"title":"What should I help with?","options":["Build and debug software","Research and explain topics","Plan projects and write content"]}]).to_string(),
                now_ms.saturating_add(300_000),
            ).await?;
        }
        let question_id = sqlx::query_scalar("SELECT id FROM async_questions WHERE conversation_id=? AND item_id='wonder-purpose' ORDER BY rowid LIMIT 1")
            .bind(conversation).fetch_optional(&self.pool).await?;
        Ok(Some(BotInitialization { question_id }))
    }

    /// Application-authored approval follow-ups are hidden inputs; the Bot's
    /// acknowledgement remains an ordinary, durable assistant reply.
    pub async fn bot_workspace_followup_messages(
        &self,
        conversation: &str,
    ) -> Result<Vec<StoredMessage>, sqlx::Error> {
        let rows = sqlx::query("SELECT m.* FROM messages m JOIN bot_workspace_followups f ON f.message_id=m.id WHERE m.conversation_id=?")
            .bind(conversation).fetch_all(&self.pool).await?;
        Ok(rows.iter().map(stored_message).collect())
    }

    /// The initialization and queue entry commit together, exactly once per Bot.
    pub async fn initialize_bot(
        &self,
        bot: &str,
        body: &str,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        use sha2::{Digest, Sha256};
        self.ensure_local_desktop(now).await?;
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM bot_initializations WHERE bot_id=?)")
                .bind(bot)
                .fetch_one(&mut *tx)
                .await?;
        if !exists {
            let conversation: String =
                sqlx::query_scalar("SELECT conversation_id FROM bot_workspaces WHERE bot_id=?")
                    .bind(bot)
                    .fetch_one(&mut *tx)
                    .await?;
            let has_work: bool =
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id=?)")
                    .bind(&conversation)
                    .fetch_one(&mut *tx)
                    .await?;
            if !has_work {
                let id = uuid::Uuid::new_v4().to_string();
                sqlx::query("INSERT INTO messages(id,device_id,client_message_id,body,body_sha256,conversation_id,state,created_at) VALUES (?,'wonder-desktop',?,?,?,?,'accepted_by_wonder',?)")
                    .bind(&id).bind(uuid::Uuid::new_v4().to_string()).bind(body).bind(hex::encode(Sha256::digest(body.as_bytes()))).bind(&conversation).bind(now).execute(&mut *tx).await?;
                sqlx::query("INSERT INTO bot_initializations(bot_id,message_id) VALUES (?,?)")
                    .bind(bot)
                    .bind(&id)
                    .execute(&mut *tx)
                    .await?;
                sqlx::query("INSERT INTO dispatch_work(message_id) VALUES (?)")
                    .bind(&id)
                    .execute(&mut *tx)
                    .await?;
            }
        }
        tx.commit().await?;
        Ok(())
    }
    pub async fn dismiss_initialization_question(
        &self,
        conversation: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE async_questions SET state='dismissed',response_json='{\"answers\":[],\"skip\":true}' WHERE state='pending' AND conversation_id=? AND turn_id IN (SELECT m.codex_turn_id FROM messages m JOIN bot_initializations i ON i.message_id=m.id)")
            .bind(conversation).execute(&self.pool).await?;
        Ok(())
    }
    pub async fn bot_initialization_messages(
        &self,
        conversation: &str,
    ) -> Result<Vec<StoredMessage>, sqlx::Error> {
        let rows = sqlx::query("SELECT m.* FROM messages m JOIN bot_initializations i ON i.message_id=m.id WHERE m.conversation_id=?")
            .bind(conversation).fetch_all(&self.pool).await?;
        Ok(rows.iter().map(stored_message).collect())
    }
    pub async fn enable_bot_onboarding(&self, bot: &str) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT OR IGNORE INTO bot_onboarding(bot_id) VALUES(?)")
            .bind(bot)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
    pub async fn bot_onboarding_enabled(&self, bot: &str) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM bot_onboarding WHERE bot_id=?)")
            .bind(bot)
            .fetch_one(&self.pool)
            .await
    }
    /// Profile and replay receipt commit together, so a repeated runtime call cannot overwrite a later owner edit.
    pub async fn apply_conversational_profile(
        &self,
        bot: &str,
        key: &str,
        hash: &str,
        name: &str,
        role: &str,
        instructions: &str,
    ) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        if let Some(saved) = sqlx::query_scalar::<_, String>(
            "SELECT input_hash FROM bot_profile_changes WHERE call_key=?",
        )
        .bind(key)
        .fetch_optional(&mut *tx)
        .await?
        {
            return Ok(saved == hash);
        }
        let result=sqlx::query("UPDATE bots SET name=?,role=?,system_prompt=? WHERE id=? AND is_archived=0 AND EXISTS(SELECT 1 FROM bot_onboarding WHERE bot_id=bots.id)").bind(name).bind(role).bind(instructions).bind(bot).execute(&mut *tx).await?;
        if result.rows_affected() != 1 {
            return Ok(false);
        }
        sqlx::query("UPDATE conversation_metadata SET title=? WHERE id=(SELECT conversation_id FROM bot_workspaces WHERE bot_id=?)").bind(name).bind(bot).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO bot_profile_changes(call_key,bot_id,input_hash,profile_json) VALUES(?,?,?,?)").bind(key).bind(bot).bind(hash).bind(serde_json::json!({"name":name,"role":role,"systemPrompt":instructions}).to_string()).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn initialization_and_profile_replay_are_durable_and_scoped() {
        let dir = tempfile::tempdir().unwrap();
        let url = format!("sqlite://{}?mode=rwc", dir.path().join("db").display());
        let store = Store::connect(&url).await.unwrap();
        for id in ["one", "two"] {
            store
                .upsert_bot(
                    id,
                    id,
                    "purpose",
                    "instructions",
                    "/tmp",
                    id,
                    None,
                    None,
                    "1",
                )
                .await
                .unwrap();
            store.ensure_bot_workspace(id, id, "1").await.unwrap();
            store.enable_bot_onboarding(id).await.unwrap();
        }
        store
            .initialize_bot("one", "Initialize questionnaire", "2")
            .await
            .unwrap();
        store
            .initialize_bot("one", "Initialize questionnaire", "2")
            .await
            .unwrap();
        assert_eq!(
            store
                .bot_initialization_messages("bot:one")
                .await
                .unwrap()
                .len(),
            1
        );
        assert!(store
            .bot_initialization_messages("bot:two")
            .await
            .unwrap()
            .is_empty());
        sqlx::query("UPDATE messages SET codex_thread_id='thread',codex_turn_id='turn',state='completed' WHERE id IN (SELECT message_id FROM bot_initializations WHERE bot_id='one')").execute(&store.pool).await.unwrap();
        store
            .save_async_question(
                "bot:one",
                "thread",
                "turn",
                "purpose",
                "[{\"title\":\"Purpose?\",\"options\":[\"Build\",\"Learn\"]}]",
                1000,
            )
            .await
            .unwrap();
        assert_eq!(
            store.async_questions("bot:one", 3).await.unwrap()[0].state,
            "pending"
        );
        store
            .dismiss_initialization_question("bot:one")
            .await
            .unwrap();
        assert_eq!(
            store.async_questions("bot:one", 3).await.unwrap()[0].state,
            "dismissed"
        );
        store
            .insert_message(
                "wonder-desktop",
                "real-task",
                "Do work",
                "hash",
                "bot:one",
                "3",
            )
            .await
            .unwrap();
        store
            .save_async_question(
                "bot:one",
                "thread",
                "turn",
                "late",
                "[{\"title\":\"Purpose?\"}]",
                1000,
            )
            .await
            .unwrap();
        assert!(store
            .async_questions("bot:one", 4)
            .await
            .unwrap()
            .iter()
            .all(|q| q.state == "dismissed"));
        assert!(store
            .search("Initialize questionnaire", 10)
            .await
            .unwrap()
            .is_empty());
        assert!(store
            .apply_conversational_profile(
                "one",
                "call",
                "hash",
                "iOS helper",
                "iOS development",
                "Use SwiftUI"
            )
            .await
            .unwrap());
        store
            .update_bot("one", Some("Owner edit"), None, None, None, None, None)
            .await
            .unwrap();
        assert!(store
            .apply_conversational_profile(
                "one",
                "call",
                "hash",
                "iOS helper",
                "iOS development",
                "Use SwiftUI"
            )
            .await
            .unwrap());
        assert!(!store
            .apply_conversational_profile("one", "call", "changed", "Other", "Other", "Other")
            .await
            .unwrap());
        drop(store);
        let reopened = Store::connect(&url).await.unwrap();
        assert_eq!(
            reopened.bot("one").await.unwrap().unwrap().name,
            "Owner edit"
        );
        assert_eq!(reopened.bot("two").await.unwrap().unwrap().name, "two");
        assert_eq!(
            reopened
                .bot_initialization_messages("bot:one")
                .await
                .unwrap()
                .len(),
            1
        );
    }
}
