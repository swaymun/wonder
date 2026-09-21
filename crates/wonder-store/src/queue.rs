//! Revision-checked edits share SQLite's write boundary with dispatch claims.
use super::*;

#[derive(Debug)]
pub struct QueueItem {
    pub id: String,
    pub client_message_id: String,
    pub body: String,
    pub revision: i64,
    pub attachment_ids: Vec<String>,
}
impl Store {
    pub async fn pending_queue(&self, conversation: &str) -> Result<Vec<QueueItem>, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let rows = sqlx::query("SELECT m.* FROM messages m JOIN dispatch_work w ON w.message_id=m.id WHERE m.conversation_id=? AND m.state='accepted_by_wonder' AND NOT EXISTS(SELECT 1 FROM bot_initializations i WHERE i.message_id=m.id) AND NOT EXISTS(SELECT 1 FROM bot_workspace_followups f WHERE f.message_id=m.id) ORDER BY m.queue_position,m.created_at,m.id")
            .bind(conversation).fetch_all(&mut *tx).await?;
        let mut items = Vec::new();
        for row in rows {
            let id: String = row.get("id");
            let attachment_ids = sqlx::query_scalar(
                "SELECT file_id FROM message_attachments WHERE message_id=? ORDER BY file_id",
            )
            .bind(&id)
            .fetch_all(&mut *tx)
            .await?;
            items.push(QueueItem {
                id,
                client_message_id: row.get("client_message_id"),
                body: row.get("body"),
                revision: row.get("queue_revision"),
                attachment_ids,
            });
        }
        tx.commit().await?;
        Ok(items)
    }
    pub async fn edit_pending(
        &self,
        conversation: &str,
        id: &str,
        revision: i64,
        body: Option<(&str, &str)>,
    ) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let result = if let Some((body, hash)) = body {
            sqlx::query("UPDATE messages SET body=?,body_sha256=?,queue_revision=queue_revision+1 WHERE id=? AND conversation_id=? AND queue_revision=? AND state='accepted_by_wonder' AND id IN (SELECT message_id FROM dispatch_work) AND id NOT IN (SELECT message_id FROM bot_initializations) AND id NOT IN (SELECT message_id FROM bot_workspace_followups)")
                .bind(body).bind(hash).bind(id).bind(conversation).bind(revision).execute(&mut *tx).await?
        } else {
            sqlx::query("UPDATE messages SET state='interrupted',queue_revision=queue_revision+1 WHERE id=? AND conversation_id=? AND queue_revision=? AND state='accepted_by_wonder' AND id IN (SELECT message_id FROM dispatch_work) AND id NOT IN (SELECT message_id FROM bot_initializations) AND id NOT IN (SELECT message_id FROM bot_workspace_followups)")
                .bind(id).bind(conversation).bind(revision).execute(&mut *tx).await?
        };
        if result.rows_affected() == 1 && body.is_none() {
            sqlx::query("DELETE FROM message_attachments WHERE message_id=?")
                .bind(id)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        Ok(result.rows_affected() == 1)
    }
    pub async fn reorder_pending(
        &self,
        conversation: &str,
        order: &[(String, i64)],
    ) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        // Acquire the write boundary before comparing the complete queue.
        sqlx::query("UPDATE messages SET queue_position=queue_position WHERE conversation_id=? AND state='accepted_by_wonder'").bind(conversation).execute(&mut *tx).await?;
        let rows = sqlx::query("SELECT m.id,m.queue_revision FROM messages m JOIN dispatch_work w ON w.message_id=m.id WHERE m.conversation_id=? AND m.state='accepted_by_wonder' AND NOT EXISTS(SELECT 1 FROM bot_initializations i WHERE i.message_id=m.id) AND NOT EXISTS(SELECT 1 FROM bot_workspace_followups f WHERE f.message_id=m.id)")
            .bind(conversation).fetch_all(&mut *tx).await?;
        let expected = order
            .iter()
            .cloned()
            .collect::<std::collections::HashMap<_, _>>();
        if rows.len() != order.len()
            || expected.len() != order.len()
            || rows.iter().any(|r| {
                expected.get(&r.get::<String, _>("id")) != Some(&r.get::<i64, _>("queue_revision"))
            })
        {
            return Ok(false);
        }
        for (index, (id, _)) in order.iter().enumerate() {
            sqlx::query(
                "UPDATE messages SET queue_position=?,queue_revision=queue_revision+1 WHERE id=?",
            )
            .bind(index as i64 - order.len() as i64)
            .bind(id)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(true)
    }
    pub async fn original_body_hash(&self, id: &str) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT original_body_sha256 FROM messages WHERE id=?")
            .bind(id)
            .fetch_one(&self.pool)
            .await
    }
}

impl Store {
    pub async fn pending_guides(&self) -> Result<Vec<(StoredMessage, String)>, sqlx::Error> {
        let rows = sqlx::query("SELECT m.*,g.expected_turn_id FROM messages m JOIN guide_work g ON g.message_id=m.id WHERE m.state='accepted_by_wonder' AND NOT EXISTS(SELECT 1 FROM bot_initializations i WHERE i.message_id=m.id) AND NOT EXISTS(SELECT 1 FROM bot_workspace_followups f WHERE f.message_id=m.id) ORDER BY m.created_at,m.id LIMIT 32").fetch_all(&self.pool).await?;
        Ok(rows
            .iter()
            .map(|r| (stored_message(r), r.get("expected_turn_id")))
            .collect())
    }
    pub async fn claim_guide(&self, id: &str, thread: &str) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE messages SET state='uncertain',codex_thread_id=? WHERE id=? AND state='accepted_by_wonder' AND id IN (SELECT message_id FROM guide_work)").bind(thread).bind(id).execute(&self.pool).await?.rows_affected()==1)
    }
    pub async fn queue_to_guide(
        &self,
        conversation: &str,
        id: &str,
        revision: i64,
        turn: &str,
    ) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let changed=sqlx::query("UPDATE messages SET queue_revision=queue_revision+1 WHERE id=? AND conversation_id=? AND queue_revision=? AND state='accepted_by_wonder' AND id IN (SELECT message_id FROM dispatch_work) AND id NOT IN (SELECT message_id FROM bot_initializations) AND id NOT IN (SELECT message_id FROM bot_workspace_followups) AND EXISTS(SELECT 1 FROM messages active WHERE active.conversation_id=? AND active.codex_turn_id=? AND active.state IN ('accepted_by_codex','streaming'))")
            .bind(id).bind(conversation).bind(revision).bind(conversation).bind(turn).execute(&mut *tx).await?.rows_affected()==1;
        if changed {
            sqlx::query("DELETE FROM dispatch_work WHERE message_id=?")
                .bind(id)
                .execute(&mut *tx)
                .await?;
            sqlx::query("INSERT INTO guide_work(message_id,expected_turn_id) VALUES (?,?)")
                .bind(id)
                .bind(turn)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        Ok(changed)
    }

    /// Move a queued child message to a guide without manufacturing a parent
    /// user receipt. The daemon must verify the live child turn separately;
    /// this boundary only checks the exact conversation/thread ownership and
    /// the queued message revision atomically.
    pub async fn queue_to_guide_verified_child(
        &self,
        conversation: &str,
        id: &str,
        revision: i64,
        thread: &str,
        turn: &str,
    ) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let changed = sqlx::query(
            "UPDATE messages SET queue_revision=queue_revision+1 WHERE id=? AND conversation_id=? AND queue_revision=? AND state='accepted_by_wonder' AND id IN (SELECT message_id FROM dispatch_work) AND id NOT IN (SELECT message_id FROM bot_initializations) AND id NOT IN (SELECT message_id FROM bot_workspace_followups) AND EXISTS(SELECT 1 FROM subagent_ownership child WHERE child.conversation_id=? AND child.thread_id=? AND child.is_archived=0) AND EXISTS(SELECT 1 FROM conversations target WHERE target.id=? AND target.codex_thread_id=?)",
        )
        .bind(id)
        .bind(conversation)
        .bind(revision)
        .bind(conversation)
        .bind(thread)
        .bind(conversation)
        .bind(thread)
        .execute(&mut *tx)
        .await?
        .rows_affected()
            == 1;
        if changed {
            sqlx::query("DELETE FROM dispatch_work WHERE message_id=?")
                .bind(id)
                .execute(&mut *tx)
                .await?;
            sqlx::query("INSERT INTO guide_work(message_id,expected_turn_id) VALUES (?,?)")
                .bind(id)
                .bind(turn)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn setup() -> Store {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_owner_device("phone", "Phone", "{}", "now")
            .await
            .unwrap();
        store
    }
    async fn message(store: &Store, client: &str) -> StoredMessage {
        message_at(store, client, client).await
    }
    async fn message_at(store: &Store, client: &str, created_at: &str) -> StoredMessage {
        match store
            .insert_dispatch_message(
                "phone",
                client,
                client,
                client,
                "chat",
                &[],
                created_at,
                true,
            )
            .await
            .unwrap()
        {
            MessageInsert::Inserted(m) => m,
            _ => panic!("new message"),
        }
    }
    #[tokio::test]
    async fn identical_created_at_durable_messages_preserve_insertion_and_claim_order() {
        let store = setup().await;
        let first = message_at(&store, "first", "same-time").await;
        let second = message_at(&store, "second", "same-time").await;

        let pending = store.pending_queue("chat").await.unwrap();
        assert_eq!(
            pending
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec![first.id.as_str(), second.id.as_str()]
        );
        assert!(store.claim_message_for_dispatch(&first.id).await.unwrap());
        assert!(!store.claim_message_for_dispatch(&second.id).await.unwrap());
        store
            .update_message_delivery(&first.id, "completed", None, None)
            .await
            .unwrap();
        assert!(store.claim_message_for_dispatch(&second.id).await.unwrap());
    }

    #[tokio::test]
    async fn reorder_and_edit_cannot_race_claim_or_overwrite_a_revision() {
        let store = setup().await;
        let a = message(&store, "a").await;
        let b = message(&store, "b").await;
        assert!(store
            .reorder_pending("chat", &[(b.id.clone(), 1), (a.id.clone(), 1)])
            .await
            .unwrap());
        assert!(!store.claim_message_for_dispatch(&a.id).await.unwrap());
        assert!(!store
            .edit_pending("chat", &b.id, 1, Some(("stale", "stale")))
            .await
            .unwrap());
        let (edit, claim) = tokio::join!(
            store.edit_pending("chat", &b.id, 2, Some(("edited", "edited-hash"))),
            store.claim_message_for_dispatch(&b.id)
        );
        assert!(claim.unwrap());
        let body = store.message_by_id(&b.id).await.unwrap().unwrap().body;
        assert_eq!(body, if edit.unwrap() { "edited" } else { "b" });
        assert!(!store.edit_pending("chat", &b.id, 3, None).await.unwrap());
        assert_eq!(
            store.original_body_hash(&b.id).await.unwrap().as_deref(),
            Some("b")
        );
        assert!(!store.claim_message_for_dispatch(&a.id).await.unwrap());
        store
            .update_message_delivery(&b.id, "completed", None, None)
            .await
            .unwrap();
        assert!(store.claim_message_for_dispatch(&a.id).await.unwrap());
    }
    #[tokio::test]
    async fn queued_guide_moves_atomically_and_survives_recovery_without_becoming_send() {
        let store = setup().await;
        let a = message(&store, "a").await;
        store
            .update_message_delivery(&a.id, "streaming", Some("thread"), Some("turn"))
            .await
            .unwrap();
        let b = message(&store, "b").await;
        assert!(!store
            .queue_to_guide("chat", &b.id, 1, "stale-turn")
            .await
            .unwrap());
        assert!(store
            .queue_to_guide("chat", &b.id, 1, "turn")
            .await
            .unwrap());
        assert!(!store
            .queue_to_guide("chat", &b.id, 1, "turn")
            .await
            .unwrap());
        assert!(!store.is_durable_dispatch(&b.id).await.unwrap());
        store.recover_dispatch_claims().await.unwrap();
        let guides = store.pending_guides().await.unwrap();
        assert_eq!(guides.len(), 1);
        assert_eq!(guides[0].0.id, b.id);
        assert_eq!(guides[0].1, "turn");
        assert!(store.claim_guide(&b.id, "thread").await.unwrap());
        assert!(!store.claim_guide(&b.id, "thread").await.unwrap());
        store.recover_dispatch_claims().await.unwrap();
        assert!(store.pending_guides().await.unwrap().is_empty());
        assert_eq!(
            store.ambiguous_dispatch_messages().await.unwrap()[0].id,
            b.id
        );
        assert!(store.pending_dispatch_messages().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn verified_child_guide_does_not_require_a_user_receipt_or_accept_unrelated_thread() {
        let store = setup().await;
        store
            .upsert_bot(
                "bot",
                "Bot",
                "Role",
                "Instructions",
                "/tmp/bot",
                "profile",
                None,
                None,
                "now",
            )
            .await
            .unwrap();
        let parent_conversation = store
            .ensure_bot_workspace("bot", "Bot", "now")
            .await
            .unwrap();
        store
            .set_conversation_thread(&parent_conversation, "parent-thread", None, "now")
            .await
            .unwrap();
        store
            .register_subagent_ownership(
                "child",
                &parent_conversation,
                "child-thread",
                "parent-thread",
                "bot",
                "Scout",
                Some("Scout"),
                None,
                None,
                r#"{"subAgent":{"thread_spawn":{"parent_thread_id":"parent-thread","depth":1}}}"#,
                Some("runtime"),
                Some(true),
                "active",
                None,
                "now",
            )
            .await
            .unwrap();
        let message = message(&store, "child-message").await;
        sqlx::query("UPDATE messages SET conversation_id='child' WHERE id=?")
            .bind(&message.id)
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(!store
            .queue_to_guide_verified_child("child", &message.id, 1, "wrong-thread", "turn")
            .await
            .unwrap());
        assert!(store
            .queue_to_guide_verified_child("child", &message.id, 1, "child-thread", "turn")
            .await
            .unwrap());
        assert_eq!(store.pending_guides().await.unwrap()[0].1, "turn");
    }
    #[tokio::test]
    async fn guide_acceptance_registers_target_and_pending_cancel_releases_references() {
        let store = setup().await;
        let first = store
            .insert_guide_message("phone", "guide", "body", "hash", "chat", &[], "now", "turn")
            .await
            .unwrap();
        assert!(matches!(first, MessageInsert::Inserted(_)));
        assert!(matches!(
            store
                .insert_guide_message(
                    "phone",
                    "guide",
                    "body",
                    "hash",
                    "chat",
                    &[],
                    "now",
                    "other"
                )
                .await
                .unwrap(),
            MessageInsert::Conflict
        ));
        store.recover_dispatch_claims().await.unwrap();
        assert_eq!(store.pending_guides().await.unwrap().len(), 1);
        sqlx::query("INSERT INTO conversation_files(id,conversation_id,kind,name,state,created_at,updated_at) VALUES ('file','chat','attachment','notes','available','now','now')").execute(&store.pool).await.unwrap();
        let MessageInsert::Inserted(pending) = store
            .insert_dispatch_message(
                "phone",
                "cancel",
                "body",
                "hash",
                "chat",
                &["file".into()],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!("pending")
        };
        assert_eq!(
            store.attachment_ids_for_message(&pending.id).await.unwrap(),
            vec!["file"]
        );
        assert!(store
            .edit_pending("chat", &pending.id, 1, None)
            .await
            .unwrap());
        assert!(!store.claim_message_for_dispatch(&pending.id).await.unwrap());
        assert!(store.pending_queue("chat").await.unwrap().is_empty());
        assert!(store
            .attachment_ids_for_message(&pending.id)
            .await
            .unwrap()
            .is_empty());
    }
}
