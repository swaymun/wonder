use super::*;

impl Store {
    pub async fn coordinator_group_for_message(
        &self,
        message_id: &str,
    ) -> Result<Option<GroupRun>, sqlx::Error> {
        let row=sqlx::query("SELECT parent.*,g.snapshot_json FROM messages child JOIN group_nodes n ON n.device_id=child.device_id AND n.client_message_id=child.client_message_id JOIN group_runs g ON g.parent_message_id=n.parent_message_id JOIN messages parent ON parent.id=g.parent_message_id JOIN devices owner ON owner.id=parent.device_id WHERE child.id=? AND n.phase IN ('direct','synthesis') AND n.bot_id=json_extract(g.snapshot_json,'$.coordinator_bot_id') AND child.conversation_id=json_extract(g.snapshot_json,'$.conversation_id') AND owner.revoked_at IS NULL")
            .bind(message_id).fetch_optional(&self.pool).await?;
        row.map(|row| {
            Ok(GroupRun {
                parent: stored_message(&row),
                channel: serde_json::from_str(row.get("snapshot_json"))
                    .map_err(|e| sqlx::Error::Decode(Box::new(e)))?,
            })
        })
        .transpose()
    }
    pub async fn coordinator_group_for_conversation(
        &self,
        conversation: &str,
    ) -> Result<Option<StoredChannel>, sqlx::Error> {
        let id: Option<String> =
            sqlx::query_scalar("SELECT id FROM channels WHERE conversation_id=? AND is_archived=0")
                .bind(conversation)
                .fetch_optional(&self.pool)
                .await?;
        match id {
            Some(id) => self.channel(&id).await,
            None => Ok(None),
        }
    }
    /// The caller compares an existing input hash before reusing its durable response.
    pub async fn pm_tool_call(
        &self,
        key: &str,
    ) -> Result<Option<(String, Option<String>)>, sqlx::Error> {
        Ok(
            sqlx::query("SELECT input_hash,response_json FROM pm_tool_calls WHERE call_key=?")
                .bind(key)
                .fetch_optional(&self.pool)
                .await?
                .map(|r| (r.get("input_hash"), r.get("response_json"))),
        )
    }
    pub async fn reserve_pm_tool_call(
        &self,
        key: &str,
        hash: &str,
        message: &str,
        runtime: &str,
        tool: &str,
        now: &str,
    ) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        if let Some(existing) =
            sqlx::query_scalar::<_, String>("SELECT input_hash FROM pm_tool_calls WHERE call_key=?")
                .bind(key)
                .fetch_optional(&mut *tx)
                .await?
        {
            return Ok(existing == hash);
        }
        let count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM pm_tool_calls WHERE message_id=?")
                .bind(message)
                .fetch_one(&mut *tx)
                .await?;
        if count >= 16 {
            return Ok(false);
        }
        sqlx::query("INSERT INTO pm_tool_calls(call_key,input_hash,message_id,runtime_id,tool_name,created_at) VALUES(?,?,?,?,?,?)").bind(key).bind(hash).bind(message).bind(runtime).bind(tool).bind(now).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(true)
    }
    pub async fn complete_pm_tool_call(
        &self,
        key: &str,
        hash: &str,
        response: &str,
    ) -> Result<(), sqlx::Error> {
        let result=sqlx::query("UPDATE pm_tool_calls SET response_json=? WHERE call_key=? AND input_hash=? AND response_json IS NULL").bind(response).bind(key).bind(hash).execute(&self.pool).await?;
        if result.rows_affected() != 1 {
            return Err(sqlx::Error::RowNotFound);
        }
        Ok(())
    }
    pub async fn dispatch_context(&self, message: &str) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT context_json FROM dispatch_attempts WHERE message_id=? ORDER BY id DESC LIMIT 1").bind(message).fetch_optional(&self.pool).await.map(Option::flatten)
    }
}
