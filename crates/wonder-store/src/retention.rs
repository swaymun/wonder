//! Global replay budgets. Canonical history and pending intent are never pruned.
use super::*;

pub const REPLAY_MAX_EVENTS: i64 = 100_000;
pub const REPLAY_MAX_BYTES: i64 = 128 * 1024 * 1024;
const REPLAY_MAX_AGE_SECONDS: i64 = 7 * 24 * 60 * 60;
const PRUNE_BATCH: i64 = 256;
/// A notification waits here only until dispatch maps its turn (seconds) or a
/// Group plan reads its completion (at most minutes). One a week old whose
/// thread no conversation, message or goal knows will never be delivered.
pub const ORPHANED_NOTIFICATION_MAX_AGE_MS: i64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Debug)]
pub struct ReplayStorageUsage {
    pub event_count: i64,
    pub payload_bytes: i64,
    pub database_bytes: i64,
    pub freelist_bytes: i64,
}

impl Store {
    /// Each writer lock deletes at most 256 rows; release it between batches so
    /// controls can commit even after a long offline interval or an upgrade.
    pub async fn prune_replay(&self) -> Result<(), sqlx::Error> {
        while self.prune_replay_batch().await? {
            tokio::task::yield_now().await;
        }
        Ok(())
    }

    async fn prune_replay_batch(&self) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        // A single statement avoids upgrading a stale read transaction to write.
        let result = sqlx::query("DELETE FROM replay_retention WHERE id IN (SELECT id FROM replay_retention WHERE retained_at < unixepoch() - ? ORDER BY retained_at, id LIMIT ?)")
            .bind(REPLAY_MAX_AGE_SECONDS).bind(PRUNE_BATCH).execute(&mut *tx).await?;
        let age_removed = result.rows_affected();
        let usage =
            sqlx::query("SELECT event_count, payload_bytes FROM replay_usage WHERE singleton=1")
                .fetch_one(&mut *tx)
                .await?;
        let count: i64 = usage.get("event_count");
        let bytes: i64 = usage.get("payload_bytes");
        let overflow = count > REPLAY_MAX_EVENTS || bytes > REPLAY_MAX_BYTES;
        if overflow {
            // Count-only overflow removes only the excess; byte overflow retires
            // one bounded prefix, which may intentionally leave spare capacity.
            let batch = if bytes > REPLAY_MAX_BYTES {
                PRUNE_BATCH
            } else {
                (count - REPLAY_MAX_EVENTS).min(PRUNE_BATCH)
            }
            .min(PRUNE_BATCH - age_removed as i64);
            sqlx::query("DELETE FROM replay_retention WHERE id IN (SELECT id FROM replay_retention ORDER BY id LIMIT ?)")
                .bind(batch).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(age_removed == PRUNE_BATCH as u64 || overflow)
    }

    /// Drops held App Server notifications older than the bound whose thread
    /// was never bound to, or no longer belongs to, a conversation. Rows with a
    /// non-numeric receipt time (not written by wonderd) are left alone.
    pub async fn prune_orphaned_pending_notifications(
        &self,
        now_ms: i64,
    ) -> Result<u64, sqlx::Error> {
        let cutoff = now_ms - ORPHANED_NOTIFICATION_MAX_AGE_MS;
        let mut removed = 0;
        loop {
            let result = sqlx::query(
                "DELETE FROM pending_app_server_notifications WHERE id IN (
                   SELECT p.id FROM pending_app_server_notifications p
                   WHERE p.received_at NOT GLOB '*[^0-9]*' AND p.received_at != ''
                     AND CAST(p.received_at AS INTEGER) < ?
                     AND (p.thread_id IS NULL OR p.thread_id NOT IN (
                       SELECT codex_thread_id FROM conversations WHERE codex_thread_id IS NOT NULL
                       UNION SELECT runtime_thread_id FROM runtime_bindings
                       UNION SELECT codex_thread_id FROM messages WHERE codex_thread_id IS NOT NULL
                       UNION SELECT thread_id FROM goal_threads
                       UNION SELECT thread_id FROM subagent_ownership))
                   LIMIT ?)",
            )
            .bind(cutoff)
            .bind(PRUNE_BATCH)
            .execute(&self.pool)
            .await?;
            removed += result.rows_affected();
            if result.rows_affected() < PRUNE_BATCH as u64 {
                return Ok(removed);
            }
            tokio::task::yield_now().await;
        }
    }

    pub async fn replay_storage_usage(&self) -> Result<ReplayStorageUsage, sqlx::Error> {
        let row =
            sqlx::query("SELECT event_count, payload_bytes FROM replay_usage WHERE singleton=1")
                .fetch_one(&self.pool)
                .await?;
        let pages: i64 = sqlx::query_scalar("PRAGMA page_count")
            .fetch_one(&self.pool)
            .await?;
        let page_size: i64 = sqlx::query_scalar("PRAGMA page_size")
            .fetch_one(&self.pool)
            .await?;
        let free: i64 = sqlx::query_scalar("PRAGMA freelist_count")
            .fetch_one(&self.pool)
            .await?;
        Ok(ReplayStorageUsage {
            event_count: row.get("event_count"),
            payload_bytes: row.get("payload_bytes"),
            database_bytes: pages * page_size,
            freelist_bytes: free * page_size,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn global_count_bytes_age_and_expiry_preserve_canonical_history() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::connect(&format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("retention.db").display()
        ))
        .await
        .unwrap();
        store
            .upsert_owner_device("owner", "Owner", "{}", "now")
            .await
            .unwrap();
        store
            .insert_message("owner", "pending", "unsent text", "hash", "chat", "now")
            .await
            .unwrap();
        store.start_event_epoch("epoch").await.unwrap();
        sqlx::query("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100100) INSERT INTO sync_journal(host_epoch,occurred_at,resource,change_kind) SELECT 'epoch','now','messages','update' FROM n").execute(&store.pool).await.unwrap();
        store.prune_replay().await.unwrap();
        assert_eq!(
            store.replay_storage_usage().await.unwrap().event_count,
            REPLAY_MAX_EVENTS
        );
        assert!(matches!(
            store.replay_batch("epoch", 0).await.unwrap(),
            ReplayBatch::Resync(_)
        ));
        let usage = store.replay_storage_usage().await.unwrap();
        let huge = "x".repeat(REPLAY_MAX_BYTES as usize + 1);
        // A single oversized record must also be evictable, without special cleanup.
        sqlx::query("INSERT INTO events(event_id,host_epoch,sequence,occurred_at,payload_json) VALUES ('large','older',1,'now',?)").bind(serde_json::json!({"padding":huge}).to_string()).execute(&store.pool).await.unwrap();
        drop(huge);
        store.prune_replay().await.unwrap();
        let bounded = store.replay_storage_usage().await.unwrap();
        assert!(bounded.payload_bytes <= REPLAY_MAX_BYTES, "{bounded:?}");
        assert!(bounded.event_count <= REPLAY_MAX_EVENTS);
        store.start_event_epoch("new").await.unwrap();
        sqlx::query("INSERT INTO sync_journal(host_epoch,occurred_at,resource,change_kind) VALUES ('new','now','messages','update')").execute(&store.pool).await.unwrap();
        sqlx::query("UPDATE replay_retention SET retained_at=unixepoch()-604801")
            .execute(&store.pool)
            .await
            .unwrap();
        store.prune_replay().await.unwrap();
        let final_usage = store.replay_storage_usage().await.unwrap();
        assert_eq!(final_usage.event_count, 0);
        assert_eq!(final_usage.payload_bytes, 0);
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM messages WHERE body='unsent text'")
                .fetch_one(&store.pool)
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM history_entries")
                .fetch_one(&store.pool)
                .await
                .unwrap(),
            1
        );
        eprintln!("RETENTION_COUNT_CAP={usage:?}; RETENTION_AFTER_BYTES={bounded:?}; RETENTION_AFTER_AGE={final_usage:?}; WAL_BYTES={}",std::fs::metadata(dir.path().join("retention.db-wal")).map(|m|m.len()).unwrap_or(0));
    }

    #[tokio::test]
    async fn orphaned_pending_notifications_are_dropped_once_stale() {
        let dir = tempfile::tempdir().unwrap();
        let url = format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("pending.db").display()
        );
        let store = Store::connect(&url).await.unwrap();
        let now: i64 = 1_800_000_000_000;
        let old = (now - ORPHANED_NOTIFICATION_MAX_AGE_MS - 1).to_string();
        let fresh = (now - 60_000).to_string();
        sqlx::query("INSERT INTO conversations (id, codex_thread_id, created_at) VALUES ('chat', 'bound-thread', 'now')")
            .execute(&store.pool).await.unwrap();
        let mut rows = vec![
            ("bound".to_owned(), Some("bound-thread"), old.clone()),
            ("fresh".to_owned(), Some("gone-thread"), fresh),
            ("not-ms".to_owned(), Some("gone-thread"), "now".to_owned()),
            ("no-thread".to_owned(), None, old.clone()),
        ];
        // More than one delete batch of orphans from a removed Bot conversation.
        rows.extend((0..300).map(|i| (format!("orphan-{i}"), Some("gone-thread"), old.clone())));
        for (id, thread, received) in &rows {
            store
                .enqueue_pending_app_server_notification(
                    id,
                    None,
                    "item/completed",
                    *thread,
                    Some("turn"),
                    None,
                    "{}",
                    "{}",
                    received,
                )
                .await
                .unwrap();
        }
        assert_eq!(
            store
                .prune_orphaned_pending_notifications(now)
                .await
                .unwrap(),
            301
        );
        let mut left: Vec<String> =
            sqlx::query_scalar("SELECT id FROM pending_app_server_notifications")
                .fetch_all(&store.pool)
                .await
                .unwrap();
        left.sort();
        assert_eq!(left, ["bound", "fresh", "not-ms"]);
        assert_eq!(
            store
                .prune_orphaned_pending_notifications(now)
                .await
                .unwrap(),
            0
        );
    }
}
