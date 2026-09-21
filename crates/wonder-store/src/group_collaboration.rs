use super::*;
impl Store {
    pub async fn collaboration_config(&self, group: &str) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT configuration FROM group_collaboration WHERE group_id=?")
            .bind(group)
            .fetch_optional(&self.pool)
            .await
    }
    pub async fn save_collaboration_config(
        &self,
        group: &str,
        value: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO group_collaboration VALUES (?,?) ON CONFLICT(group_id) DO UPDATE SET configuration=excluded.configuration").bind(group).bind(value).execute(&self.pool).await?;
        Ok(())
    }
    pub async fn collaboration_plan(&self, parent: &str) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT plan FROM group_collaboration_plans WHERE parent_message_id=?")
            .bind(parent)
            .fetch_optional(&self.pool)
            .await
    }
    pub async fn save_collaboration_plan(
        &self,
        parent: &str,
        group: &str,
        value: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO group_collaboration_plans VALUES (?,?,?) ON CONFLICT(parent_message_id) DO UPDATE SET plan=CASE WHEN json_extract(group_collaboration_plans.plan,'$.cancelled')=1 THEN json_set(excluded.plan,'$.cancelled',json('true')) ELSE excluded.plan END").bind(parent).bind(group).bind(value).execute(&self.pool).await?;
        Ok(())
    }
    pub async fn collaboration_plans(
        &self,
        group: &str,
    ) -> Result<Vec<(String, String)>, sqlx::Error> {
        let rows=sqlx::query("SELECT parent_message_id,plan FROM group_collaboration_plans WHERE group_id=? ORDER BY rowid DESC LIMIT 50").bind(group).fetch_all(&self.pool).await?;
        Ok(rows.iter().map(|r| (r.get(0), r.get(1))).collect())
    }
    pub async fn reserve_team_creation(
        &self,
        id: &str,
        request: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        sqlx::query("INSERT INTO group_creation_receipts(id,request) VALUES (?,?) ON CONFLICT(id) DO NOTHING").bind(id).bind(request).execute(&self.pool).await?;
        let row = sqlx::query("SELECT request,result FROM group_creation_receipts WHERE id=?")
            .bind(id)
            .fetch_one(&self.pool)
            .await?;
        if row.get::<String, _>(0) != request {
            return Err(sqlx::Error::Protocol(
                "This creation request already has different choices. Start a new draft.".into(),
            ));
        }
        Ok(row.get(1))
    }
    pub async fn finish_team_creation(&self, id: &str, result: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE group_creation_receipts SET result=? WHERE id=?")
            .bind(result)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

impl Store {
    pub async fn settle_collaboration(&self, parent: &str, state: &str) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("UPDATE group_runs SET state=? WHERE parent_message_id=?")
            .bind(state)
            .bind(parent)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE messages SET state=? WHERE id=?")
            .bind(if state == "cancelled" {
                "interrupted"
            } else if state == "failed" {
                "failed"
            } else {
                "completed"
            })
            .bind(parent)
            .execute(&mut *tx)
            .await?;
        tx.commit().await
    }
    pub async fn retry_collaboration(&self, parent: &str, plan: &str) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("UPDATE group_collaboration_plans SET plan=? WHERE parent_message_id=?")
            .bind(plan)
            .bind(parent)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE group_runs SET state='pending' WHERE parent_message_id=? AND state IN ('failed','completed','cancelled','blocked')").bind(parent).execute(&mut *tx).await?;
        sqlx::query("UPDATE messages SET state='accepted_by_wonder' WHERE id=?")
            .bind(parent)
            .execute(&mut *tx)
            .await?;
        tx.commit().await
    }
}

impl Store {
    pub async fn collaboration_context(&self, parent: &str) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar(
            "SELECT configuration FROM group_collaboration_context WHERE parent_message_id=?",
        )
        .bind(parent)
        .fetch_optional(&self.pool)
        .await
    }
}
impl Store {
    pub async fn collaboration_owner(
        &self,
        conversation: &str,
    ) -> Result<Option<(String, String)>, sqlx::Error> {
        let rows=sqlx::query("SELECT DISTINCT n.parent_message_id,g.channel_id FROM messages m JOIN group_nodes n ON n.device_id=m.device_id AND n.client_message_id=m.client_message_id JOIN group_runs g ON g.parent_message_id=n.parent_message_id JOIN group_collaboration c ON c.group_id=g.channel_id WHERE m.conversation_id=? LIMIT 2").bind(conversation).fetch_all(&self.pool).await?;
        Ok(if rows.len() == 1 {
            Some((rows[0].get(0), rows[0].get(1)))
        } else {
            None
        })
    }
    pub async fn collaboration_handoff(&self, parent: &str) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar(
            "SELECT assignment FROM group_collaboration_handoffs WHERE parent_message_id=?",
        )
        .bind(parent)
        .fetch_optional(&self.pool)
        .await
    }
    pub async fn add_collaboration_handoff(
        &self,
        parent: &str,
        value: &str,
    ) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("INSERT INTO group_collaboration_handoffs VALUES (?,?) ON CONFLICT(parent_message_id) DO NOTHING").bind(parent).bind(value).execute(&self.pool).await?.rows_affected()==1)
    }
}

impl Store {
    pub async fn retry_collaboration_planning(&self, parent: &str) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("DELETE FROM group_collaboration_plans WHERE parent_message_id=?")
            .bind(parent)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE group_runs SET state='pending' WHERE parent_message_id=? AND state IN ('failed','blocked')").bind(parent).execute(&mut *tx).await?;
        sqlx::query("UPDATE messages SET state='accepted_by_wonder' WHERE id=?")
            .bind(parent)
            .execute(&mut *tx)
            .await?;
        tx.commit().await
    }
    pub async fn remove_collaboration_member(
        &self,
        group: &str,
        bot: &str,
    ) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let replacement: Option<String> = sqlx::query_scalar("SELECT bot_id FROM channel_members WHERE channel_id=? AND bot_id<>? ORDER BY position,bot_id LIMIT 1").bind(group).bind(bot).fetch_optional(&mut *tx).await?;
        let Some(replacement) = replacement else {
            return Ok(false);
        };
        sqlx::query("UPDATE channels SET coordinator_bot_id=? WHERE id=? AND coordinator_bot_id=?")
            .bind(&replacement)
            .bind(group)
            .bind(bot)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM channel_members WHERE channel_id=? AND bot_id=?")
            .bind(group)
            .bind(bot)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE channel_members SET role=CASE WHEN bot_id=(SELECT coordinator_bot_id FROM channels WHERE id=?) THEN 'coordinator' ELSE 'worker' END WHERE channel_id=?").bind(group).bind(group).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(true)
    }
}

impl Store {
    pub async fn dismiss_group_initialization_questions(
        &self,
        group: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE async_questions SET state='dismissed' WHERE state='pending' AND EXISTS(SELECT 1 FROM messages child JOIN group_nodes n ON n.device_id=child.device_id AND n.client_message_id=child.client_message_id JOIN channel_messages init ON init.message_id=n.parent_message_id WHERE child.conversation_id=async_questions.conversation_id AND init.channel_id=? AND init.presentation_kind='status' AND init.author_kind='user')").bind(group).execute(&self.pool).await?;
        Ok(())
    }
}
