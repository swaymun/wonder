//! Committed sync boundary. The journal carries invalidations, not commands to
//! append text to a client cache. Clients replace projections from snapshots.
use super::*;

pub struct CommittedConversationSnapshot {
    pub last_sequence: u64,
    pub workspace_path: String,
    pub messages: Vec<StoredMessage>,
    pub assistant_messages: Vec<StoredAssistantMessage>,
    pub attachment_ids: HashMap<String, Vec<String>>,
    pub codex_thread_id: Option<String>,
    pub events: Vec<HostEventEnvelope>,
    pub next_cursor: Option<super::HistoryCursor>,
}

#[derive(Debug)]
pub enum ReplayBatch {
    Events(Vec<HostEventEnvelope>),
    Resync(wonder_api::ResyncReason),
}

impl Store {
    /// Called once at daemon startup, before accepting work. Sequence numbers
    /// stay monotonic across epochs; epoch identity still fences old clients.
    pub async fn start_event_epoch(&self, host_epoch: &str) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO sync_state(singleton, host_epoch, start_sequence, last_sequence) VALUES (1, ?, COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'sync_journal'), 0), COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'sync_journal'), 0)) ON CONFLICT(singleton) DO UPDATE SET host_epoch = excluded.host_epoch, start_sequence = excluded.start_sequence, last_sequence = excluded.last_sequence WHERE sync_state.host_epoch != excluded.host_epoch")
            .bind(host_epoch).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn committed_sequence(&self, host_epoch: &str) -> Result<u64, sqlx::Error> {
        let sequence: i64 = sqlx::query_scalar(
            "SELECT last_sequence FROM sync_state WHERE singleton = 1 AND host_epoch = ?",
        )
        .bind(host_epoch)
        .fetch_one(&self.pool)
        .await?;
        Ok(sequence as u64)
    }

    /// Clear only the conversation version the client actually displayed. The
    /// conditional write shares SQLite's ordering with projection invalidations,
    /// so a delayed acknowledgement cannot consume a newer unseen reply.
    pub async fn acknowledge_conversation_read(
        &self,
        conversation: &str,
        epoch: &str,
        through: u64,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        let Ok(through) = i64::try_from(through) else {
            return Ok(false);
        };
        let changed = sqlx::query("UPDATE conversation_metadata SET has_unread=0, updated_at=? WHERE id=? AND has_unread=1 AND EXISTS (SELECT 1 FROM sync_state WHERE singleton=1 AND host_epoch=? AND ? BETWEEN start_sequence AND last_sequence) AND ? >= COALESCE((SELECT MIN(sequence)-1 FROM sync_journal), (SELECT last_sequence FROM sync_state WHERE singleton=1)) AND NOT EXISTS (SELECT 1 FROM sync_journal WHERE conversation_id=? AND sequence>?)")
            .bind(now).bind(conversation).bind(epoch).bind(through).bind(through)
            .bind(conversation).bind(through).execute(&self.pool).await?;
        Ok(changed.rows_affected() == 1)
    }

    /// Allocation, durable presentation event, and retention are one commit.
    /// SQLite's writer lock orders this with projection-triggered invalidations.
    pub async fn commit_event(&self, event: &mut HostEventEnvelope) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let result = sqlx::query("INSERT INTO sync_journal(host_epoch, occurred_at, conversation_id) SELECT host_epoch, ?, ? FROM sync_state WHERE singleton = 1 AND host_epoch = ?")
            .bind(&event.occurred_at).bind(&event.conversation_id).bind(&event.host_epoch)
            .execute(&mut *tx).await?;
        if result.rows_affected() != 1 {
            return Err(sqlx::Error::Protocol("event epoch is not active".into()));
        }
        event.sequence = result.last_insert_rowid() as u64;
        let payload = serde_json::to_string(event).map_err(|e| sqlx::Error::Encode(Box::new(e)))?;
        sqlx::query("UPDATE sync_journal SET payload_json = ? WHERE sequence = ?")
            .bind(&payload)
            .bind(event.sequence as i64)
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT INTO events(event_id, host_epoch, sequence, occurred_at, payload_json) VALUES (?, ?, ?, ?, ?)")
            .bind(&event.event_id).bind(&event.host_epoch).bind(event.sequence as i64)
            .bind(&event.occurred_at).bind(payload).execute(&mut *tx).await?;
        self.save_history_event(&mut tx, event).await?;
        tx.commit().await?;
        self.prune_replay().await
    }

    /// Read bounds, head and all retained rows from the same database view.
    /// Validate the entire window, including empty, future and interior gaps.
    pub async fn replay_batch(
        &self,
        host_epoch: &str,
        after: u64,
    ) -> Result<ReplayBatch, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let state = sqlx::query(
            "SELECT host_epoch, start_sequence, last_sequence FROM sync_state WHERE singleton = 1",
        )
        .fetch_one(&mut *tx)
        .await?;
        if state.get::<String, _>("host_epoch") != host_epoch {
            return Ok(ReplayBatch::Resync(wonder_api::ResyncReason::EpochChanged));
        }
        let start = state.get::<i64, _>("start_sequence") as u64;
        let head = state.get::<i64, _>("last_sequence") as u64;
        if after < start || after > head {
            return Ok(ReplayBatch::Resync(
                wonder_api::ResyncReason::ReplayWindowExpired,
            ));
        }
        // Validate continuity over the indexed range before decoding a bounded
        // batch. A larger global retention window must not become one giant
        // allocation or WebSocket write loop.
        let bounds = sqlx::query("SELECT COUNT(*) AS count, MAX(sequence) AS last FROM sync_journal WHERE host_epoch=? AND sequence>?")
            .bind(host_epoch).bind(after as i64).fetch_one(&mut *tx).await?;
        if bounds.get::<i64, _>("count") as u64 != head - after
            || bounds
                .get::<Option<i64>, _>("last")
                .is_some_and(|last| last as u64 != head)
        {
            return Ok(ReplayBatch::Resync(
                wonder_api::ResyncReason::ReplayWindowExpired,
            ));
        }
        let rows = sqlx::query(
            "SELECT * FROM sync_journal WHERE host_epoch = ? AND sequence > ? ORDER BY sequence LIMIT 256",
        )
        .bind(host_epoch)
        .bind(after as i64)
        .fetch_all(&mut *tx)
        .await?;
        let mut events = Vec::with_capacity(rows.len());
        let mut expected = after;
        for row in rows {
            let sequence = row.get::<i64, _>("sequence") as u64;
            if expected.checked_add(1) != Some(sequence) {
                return Ok(ReplayBatch::Resync(
                    wonder_api::ResyncReason::ReplayWindowExpired,
                ));
            }
            let event = journal_event(&row)?;
            if event.sequence != sequence || event.host_epoch != host_epoch {
                return Ok(ReplayBatch::Resync(
                    wonder_api::ResyncReason::ReplayWindowExpired,
                ));
            }
            expected = sequence;
            events.push(event);
        }
        tx.commit().await?;
        Ok(ReplayBatch::Events(events))
    }
}

fn journal_event(row: &sqlx::sqlite::SqliteRow) -> Result<HostEventEnvelope, sqlx::Error> {
    if let Some(payload) = row.get::<Option<String>, _>("payload_json") {
        return serde_json::from_str(&payload).map_err(|e| sqlx::Error::Decode(Box::new(e)));
    }
    let sequence = row.get::<i64, _>("sequence") as u64;
    let host_epoch: String = row.get("host_epoch");
    Ok(HostEventEnvelope {
        event_id: format!("projection:{host_epoch}:{sequence}"), host_epoch, sequence,
        occurred_at: row.get("occurred_at"), conversation_id: row.get("conversation_id"),
        request_id: None, device_id: None, message_id: None, thread_id: None,
        turn_id: None, item_id: None, approval_id: None,
        event: WonderEvent::Activity { category: "projection_changed".into(), state: "updated".into(),
            detail: Some(serde_json::json!({"resource": row.get::<Option<String>,_>("resource"), "change": row.get::<Option<String>,_>("change_kind")}).to_string()) },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn device_presence_does_not_invalidate_chats_but_identity_changes_do() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::connect(&format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("presence.db").display()
        ))
        .await
        .unwrap();
        store.start_event_epoch("presence-test").await.unwrap();
        store
            .upsert_owner_device("owner", "Phone", "{}", "0")
            .await
            .unwrap();
        let original = store.committed_sequence("presence-test").await.unwrap();
        for n in 1..100 {
            assert!(store
                .touch_owner_device("owner", &n.to_string())
                .await
                .unwrap());
        }
        assert_eq!(
            store.committed_sequence("presence-test").await.unwrap(),
            original
        );
        assert_eq!(
            store.list_owner_devices().await.unwrap()[0]
                .last_seen_at
                .as_deref(),
            Some("99")
        );
        store
            .rename_owner_device("owner", "Renamed phone")
            .await
            .unwrap();
        let renamed = store.committed_sequence("presence-test").await.unwrap();
        assert!(renamed > original);
        store
            .rename_owner_device("owner", "Renamed phone")
            .await
            .unwrap();
        assert_eq!(
            store.committed_sequence("presence-test").await.unwrap(),
            renamed
        );
        store
            .upsert_owner_device_with_expiration("owner", "Renamed phone", "{}", Some(1000), "100")
            .await
            .unwrap();
        let renewed = store.committed_sequence("presence-test").await.unwrap();
        assert!(renewed > renamed);
        store.revoke_owner_device("owner", "101").await.unwrap();
        assert!(store.committed_sequence("presence-test").await.unwrap() > renewed);
    }

    async fn fixture() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::connect(&format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("sync.db").display()
        ))
        .await
        .unwrap();
        store
            .upsert_owner_device("owner", "Owner", "{}", "now")
            .await
            .unwrap();
        store
            .upsert_bot(
                "chat",
                "Bot",
                "Assistant",
                "Help",
                "/tmp",
                "test",
                None,
                None,
                "now",
            )
            .await
            .unwrap();
        sqlx::query("INSERT INTO messages(id, device_id, client_message_id, body, body_sha256, conversation_id, state, created_at) VALUES ('message', 'owner', 'client', '0', 'hash', 'chat', 'accepted_by_wonder', 'now')").execute(&store.pool).await.unwrap();
        sqlx::query("INSERT INTO assistant_messages(id, conversation_id, codex_thread_id, codex_turn_id, item_id, text, state, created_at, updated_at) VALUES ('assistant', 'chat', 'thread', 'turn', 'item', '0', 'streaming', 'now', 'now')").execute(&store.pool).await.unwrap();
        store.start_event_epoch("epoch").await.unwrap();
        (dir, store)
    }

    fn event(id: &str) -> HostEventEnvelope {
        HostEventEnvelope {
            event_id: id.into(),
            host_epoch: "epoch".into(),
            sequence: 999,
            occurred_at: "now".into(),
            request_id: None,
            device_id: None,
            conversation_id: Some("chat".into()),
            message_id: None,
            thread_id: None,
            turn_id: None,
            item_id: None,
            approval_id: None,
            event: WonderEvent::HostStatus {
                state: "ready".into(),
            },
        }
    }

    fn events(batch: ReplayBatch) -> Vec<HostEventEnvelope> {
        match batch {
            ReplayBatch::Events(events) => events,
            other => panic!("{other:?}"),
        }
    }

    #[tokio::test]
    async fn read_acknowledgement_preserves_newer_messages_and_survives_reopen() {
        let (dir, store) = fixture().await;
        store
            .ensure_conversation_metadata("chat", "chat", "Bot", "now")
            .await
            .unwrap();
        store
            .update_conversation("chat", None, None, None, Some(true), "now")
            .await
            .unwrap();
        let seen = store.committed_sequence("epoch").await.unwrap();
        // New content commits after the phone took its visible snapshot.
        sqlx::query("UPDATE assistant_messages SET text='unseen reply' WHERE id='assistant'")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(!store
            .acknowledge_conversation_read("chat", "epoch", seen, "now")
            .await
            .unwrap());
        assert!(
            store
                .conversation("chat")
                .await
                .unwrap()
                .unwrap()
                .has_unread
        );
        let latest = store.committed_sequence("epoch").await.unwrap();
        assert!(!store
            .acknowledge_conversation_read("chat", "wrong", latest, "now")
            .await
            .unwrap());
        assert!(!store
            .acknowledge_conversation_read("chat", "epoch", latest + 1, "now")
            .await
            .unwrap());
        assert!(!store
            .acknowledge_conversation_read("chat", "epoch", u64::MAX, "now")
            .await
            .unwrap());
        assert!(store
            .acknowledge_conversation_read("chat", "epoch", latest, "now")
            .await
            .unwrap());
        let after = store.committed_sequence("epoch").await.unwrap();
        assert!(!store
            .acknowledge_conversation_read("chat", "epoch", latest, "now")
            .await
            .unwrap());
        assert_eq!(store.committed_sequence("epoch").await.unwrap(), after);
        drop(store);
        let store = Store::connect(&format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("sync.db").display()
        ))
        .await
        .unwrap();
        assert!(
            !store
                .conversation("chat")
                .await
                .unwrap()
                .unwrap()
                .has_unread
        );
    }

    #[tokio::test]
    async fn read_acknowledgement_rejects_pruned_or_previous_epoch_snapshots() {
        let (_dir, store) = fixture().await;
        store
            .ensure_conversation_metadata("chat", "chat", "Bot", "now")
            .await
            .unwrap();
        store
            .update_conversation("chat", None, None, None, Some(true), "now")
            .await
            .unwrap();
        let old = store.committed_sequence("epoch").await.unwrap();
        sqlx::query("UPDATE assistant_messages SET text='unseen' WHERE id='assistant'")
            .execute(&store.pool)
            .await
            .unwrap();
        sqlx::query("DELETE FROM sync_journal")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(!store
            .acknowledge_conversation_read("chat", "epoch", old, "now")
            .await
            .unwrap());
        store.start_event_epoch("new").await.unwrap();
        assert!(!store
            .acknowledge_conversation_read("chat", "epoch", old, "now")
            .await
            .unwrap());
        assert!(
            store
                .conversation("chat")
                .await
                .unwrap()
                .unwrap()
                .has_unread
        );
    }

    #[tokio::test]
    async fn projection_and_invalidation_commit_or_rollback_together() {
        let (dir, store) = fixture().await;
        let mut tx = store.pool.begin().await.unwrap();
        sqlx::query("UPDATE messages SET body = 'lost' WHERE id = 'message'")
            .execute(&mut *tx)
            .await
            .unwrap();
        let inside: i64 = sqlx::query_scalar("SELECT last_sequence FROM sync_state")
            .fetch_one(&mut *tx)
            .await
            .unwrap();
        assert_eq!(inside, 1);
        assert_eq!(store.committed_sequence("epoch").await.unwrap(), 0);
        // Dropping the connection's transaction models cancellation/crash before COMMIT.
        drop(tx);
        store.pool.close().await;
        let reopened = Store::connect(&format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("sync.db").display()
        ))
        .await
        .unwrap();
        assert_eq!(
            reopened
                .message_by_id("message")
                .await
                .unwrap()
                .unwrap()
                .body,
            "0"
        );
        assert_eq!(reopened.committed_sequence("epoch").await.unwrap(), 0);
        sqlx::query("UPDATE messages SET body = 'saved' WHERE id = 'message'")
            .execute(&reopened.pool)
            .await
            .unwrap();
        let snapshot = reopened
            .committed_conversation_snapshot("epoch", "chat")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(snapshot.last_sequence, 1);
        assert_eq!(snapshot.messages[0].body, "saved");
        let replay = events(reopened.replay_batch("epoch", 0).await.unwrap());
        assert_eq!(replay.len(), 1);
        assert_eq!(replay[0].conversation_id.as_deref(), Some("chat"));
        assert!(
            matches!(&replay[0].event, WonderEvent::Activity { category, .. } if category == "projection_changed")
        );
    }

    #[tokio::test]
    async fn journal_write_failure_aborts_the_projection_write() {
        let (_dir, store) = fixture().await;
        sqlx::query("CREATE TRIGGER fail_journal BEFORE INSERT ON sync_journal BEGIN SELECT RAISE(ABORT, 'injected journal failure'); END").execute(&store.pool).await.unwrap();
        assert!(
            sqlx::query("UPDATE messages SET body = 'lost' WHERE id = 'message'")
                .execute(&store.pool)
                .await
                .is_err()
        );
        assert_eq!(
            store.message_by_id("message").await.unwrap().unwrap().body,
            "0"
        );
        assert_eq!(store.committed_sequence("epoch").await.unwrap(), 0);
    }

    #[tokio::test]
    async fn concurrent_publishers_allocate_only_committed_sequences() {
        let (_dir, store) = fixture().await;
        let mut workers = tokio::task::JoinSet::new();
        for i in 0..40 {
            let store = store.clone();
            workers.spawn(async move {
                let mut envelope = event(&format!("event-{i}"));
                if i % 2 == 0 {
                    tokio::task::yield_now().await;
                }
                store.commit_event(&mut envelope).await.unwrap();
                envelope
            });
        }
        while let Some(result) = workers.join_next().await {
            result.unwrap();
        }
        let replay = events(store.replay_batch("epoch", 0).await.unwrap());
        assert_eq!(replay.len(), 40);
        assert_eq!(
            replay.iter().map(|e| e.sequence).collect::<Vec<_>>(),
            (1..=40).collect::<Vec<_>>()
        );
        let mut duplicate = event("event-0");
        assert!(store.commit_event(&mut duplicate).await.is_err());
        assert_eq!(store.committed_sequence("epoch").await.unwrap(), 40);
        let mut next = event("next");
        store.commit_event(&mut next).await.unwrap();
        assert_eq!(next.sequence, 41);
    }

    #[tokio::test]
    async fn delayed_publisher_and_missing_broadcast_do_not_omit_commits() {
        let (_dir, store) = fixture().await;
        let mut tx = store.pool.begin().await.unwrap();
        // Hold the SQLite writer after N is allocated. N+1 cannot commit first.
        sqlx::query("UPDATE messages SET body = 'first' WHERE id = 'message'")
            .execute(&mut *tx)
            .await
            .unwrap();
        let other = store.clone();
        let later = tokio::spawn(async move {
            let mut e = event("later");
            other.commit_event(&mut e).await.unwrap();
            e
        });
        assert!(events(store.replay_batch("epoch", 0).await.unwrap()).is_empty());
        assert!(!later.is_finished());
        tx.commit().await.unwrap();
        assert_eq!(later.await.unwrap().sequence, 2);
        // No broadcast was sent, yet reconnect sees both committed entries.
        assert_eq!(
            events(store.replay_batch("epoch", 0).await.unwrap()).len(),
            2
        );
    }

    #[tokio::test]
    async fn snapshots_never_mix_projection_rows_or_cursor_across_commits() {
        let (_dir, store) = fixture().await;
        let writer = store.clone();
        let task = tokio::spawn(async move {
            for i in 1..=50 {
                let mut tx = writer.pool.begin().await.unwrap();
                sqlx::query("UPDATE messages SET body = ? WHERE id = 'message'")
                    .bind(i.to_string())
                    .execute(&mut *tx)
                    .await
                    .unwrap();
                tokio::task::yield_now().await;
                sqlx::query("UPDATE assistant_messages SET text = ? WHERE id = 'assistant'")
                    .bind(i.to_string())
                    .execute(&mut *tx)
                    .await
                    .unwrap();
                tx.commit().await.unwrap();
            }
        });
        for _ in 0..100 {
            let snapshot = store
                .committed_conversation_snapshot("epoch", "chat")
                .await
                .unwrap()
                .unwrap();
            assert_eq!(
                snapshot.messages[0].body,
                snapshot.assistant_messages[0].text
            );
            assert_eq!(
                snapshot.last_sequence,
                snapshot.messages[0].body.parse::<u64>().unwrap() * 2
            );
        }
        task.await.unwrap();
    }

    #[tokio::test]
    async fn replay_detects_interior_tail_empty_future_and_epoch_gaps() {
        let (_dir, store) = fixture().await;
        assert!(matches!(
            store.replay_batch("old", 0).await.unwrap(),
            ReplayBatch::Resync(wonder_api::ResyncReason::EpochChanged)
        ));
        assert!(matches!(
            store.replay_batch("epoch", 1).await.unwrap(),
            ReplayBatch::Resync(_)
        ));
        for i in 0..3 {
            store
                .commit_event(&mut event(&i.to_string()))
                .await
                .unwrap();
        }
        sqlx::query("DELETE FROM sync_journal WHERE sequence = 2")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(matches!(
            store.replay_batch("epoch", 0).await.unwrap(),
            ReplayBatch::Resync(_)
        ));
        sqlx::query("DELETE FROM sync_journal WHERE sequence = 3")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(matches!(
            store.replay_batch("epoch", 2).await.unwrap(),
            ReplayBatch::Resync(_)
        ));
        sqlx::query("DELETE FROM sync_journal")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(matches!(
            store.replay_batch("epoch", 0).await.unwrap(),
            ReplayBatch::Resync(_)
        ));
        assert!(events(store.replay_batch("epoch", 3).await.unwrap()).is_empty());
        store.start_event_epoch("new").await.unwrap();
        assert_eq!(store.committed_sequence("new").await.unwrap(), 3);
        assert!(matches!(
            store.replay_batch("new", 0).await.unwrap(),
            ReplayBatch::Resync(_)
        ));
        assert!(events(store.replay_batch("new", 3).await.unwrap()).is_empty());
    }

    #[tokio::test]
    async fn retained_window_is_bounded_and_reset_erases_journal_payloads() {
        let (_dir, store) = fixture().await;
        for _ in 0..1030 {
            sqlx::query("UPDATE messages SET body = 'changed' WHERE id = 'message'")
                .execute(&store.pool)
                .await
                .unwrap();
        }
        sqlx::query("UPDATE replay_retention SET retained_at=0 WHERE source='journal' AND CAST(source_id AS INTEGER)<=6").execute(&store.pool).await.unwrap();
        store.prune_replay().await.unwrap();
        assert!(matches!(
            store.replay_batch("epoch", 0).await.unwrap(),
            ReplayBatch::Resync(_)
        ));
        let mut cursor = 6;
        let mut replay = Vec::new();
        loop {
            let batch = events(store.replay_batch("epoch", cursor).await.unwrap());
            assert!(batch.len() <= 256);
            if batch.is_empty() {
                break;
            }
            cursor = batch.last().unwrap().sequence;
            replay.extend(batch);
        }
        assert_eq!(replay.len(), 1024);
        store.reset_workspace("owner", "now").await.unwrap();
        let rows = sqlx::query("SELECT resource, payload_json FROM sync_journal")
            .fetch_all(&store.pool)
            .await
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].get::<String, _>("resource"), "workspace");
        assert!(rows[0].get::<Option<String>, _>("payload_json").is_none());
        assert!(store
            .committed_conversation_snapshot("epoch", "chat")
            .await
            .unwrap()
            .is_none());
    }
}
