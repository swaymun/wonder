//! Global replay budgets. Canonical history and pending intent are never pruned.
use super::*;

pub const REPLAY_MAX_EVENTS: i64 = 100_000;
pub const REPLAY_MAX_BYTES: i64 = 128 * 1024 * 1024;
const REPLAY_MAX_AGE_SECONDS: i64 = 7 * 24 * 60 * 60;
const PRUNE_BATCH: i64 = 256;

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
}
