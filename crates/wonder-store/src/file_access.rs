use super::*;

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BotFileAccess {
    pub revision: i64,
    pub applied_revision: i64,
    pub read_roots: Vec<String>,
    pub write_roots: Vec<String>,
}
impl Store {
    pub async fn bot_file_access(&self, bot: &str) -> Result<BotFileAccess, sqlx::Error> {
        let row = sqlx::query("SELECT * FROM bot_file_access WHERE bot_id=?")
            .bind(bot)
            .fetch_optional(&self.pool)
            .await?;
        let Some(row) = row else {
            return Ok(BotFileAccess::default());
        };
        Ok(BotFileAccess {
            revision: row.get("revision"),
            applied_revision: row.get("applied_revision"),
            read_roots: serde_json::from_str(row.get("read_roots_json"))
                .map_err(|e| sqlx::Error::Decode(Box::new(e)))?,
            write_roots: serde_json::from_str(row.get("write_roots_json"))
                .map_err(|e| sqlx::Error::Decode(Box::new(e)))?,
        })
    }
    pub async fn save_bot_file_access(
        &self,
        bot: &str,
        expected: i64,
        reads: &[String],
        writes: &[String],
    ) -> Result<bool, sqlx::Error> {
        let reads = serde_json::to_string(reads).unwrap();
        let writes = serde_json::to_string(writes).unwrap();
        let result = if expected == 0 {
            sqlx::query("INSERT INTO bot_file_access(bot_id,revision,applied_revision,read_roots_json,write_roots_json) VALUES (?,1,0,?,?) ON CONFLICT(bot_id) DO NOTHING")
                .bind(bot).bind(reads).bind(writes).execute(&self.pool).await?
        } else {
            sqlx::query("UPDATE bot_file_access SET revision=revision+1,read_roots_json=?,write_roots_json=? WHERE bot_id=? AND revision=?")
                .bind(reads).bind(writes).bind(bot).bind(expected).execute(&self.pool).await?
        };
        Ok(result.rows_affected() == 1)
    }

    pub async fn apply_bot_file_access(&self, bot: &str, revision: i64) -> Result<(), sqlx::Error> {
        sqlx::query(
            "UPDATE bot_file_access SET applied_revision=revision WHERE bot_id=? AND revision=?",
        )
        .bind(bot)
        .bind(revision)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
    pub async fn has_unsettled_execution(&self) -> Result<bool, sqlx::Error> {
        let count:i64=sqlx::query_scalar("SELECT COUNT(*) FROM messages m WHERE (m.codex_turn_id IS NOT NULL AND m.state IN ('accepted_by_codex','streaming','uncertain')) OR EXISTS (SELECT 1 FROM dispatch_attempts a WHERE a.message_id=m.id AND a.phase IN ('submitting','uncertain') AND m.state NOT IN ('completed','failed','safe_to_retry','interrupted'))").fetch_one(&self.pool).await?;
        Ok(count > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn saved_policy_requires_activation_and_rejects_stale_edits() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_bot(
                "bot",
                "Bot",
                "Assistant",
                "Help",
                "/tmp/bot",
                "profile",
                None,
                None,
                "1",
            )
            .await
            .unwrap();
        assert!(store
            .save_bot_file_access("bot", 0, &["/tmp/read".into()], &[])
            .await
            .unwrap());
        let policy = store.bot_file_access("bot").await.unwrap();
        assert_eq!((policy.revision, policy.applied_revision), (1, 0));
        store.apply_bot_file_access("bot", 1).await.unwrap();
        assert!(store
            .save_bot_file_access("bot", 1, &[], &[])
            .await
            .unwrap());
        assert!(!store
            .save_bot_file_access("bot", 1, &["/tmp/stale".into()], &[])
            .await
            .unwrap());
        let policy = store.bot_file_access("bot").await.unwrap();
        assert_eq!((policy.revision, policy.applied_revision), (2, 1));
        assert!(policy.read_roots.is_empty());
    }
}
