use super::*;

#[derive(Debug)]
pub struct GroupRun {
    pub parent: StoredMessage,
    pub channel: StoredChannel,
}
impl Store {
    pub async fn group_id_for_conversation(
        &self,
        conversation: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT id FROM channels WHERE conversation_id=?")
            .bind(conversation)
            .fetch_optional(&self.pool)
            .await
    }
    /// Only the persisted dispatch node and its immutable Group membership can
    /// grant a child turn access to its parent's attached files.
    pub async fn group_attachment_parent(
        &self,
        message: &str,
        bot: &str,
    ) -> Result<Option<StoredMessage>, sqlx::Error> {
        let row = sqlx::query("SELECT n.bot_id,n.phase,g.snapshot_json,n.parent_message_id FROM messages m JOIN group_nodes n ON n.device_id=m.device_id AND n.client_message_id=m.client_message_id JOIN group_runs g ON g.parent_message_id=n.parent_message_id WHERE m.id=?")
            .bind(message).fetch_optional(&self.pool).await?;
        let Some(row) = row else { return Ok(None) };
        let assigned: String = row.get("bot_id");
        let phase: String = row.get("phase");
        let snapshot: StoredChannel = serde_json::from_str(row.get("snapshot_json"))
            .map_err(|e| sqlx::Error::Decode(Box::new(e)))?;
        let collaborative = self.collaboration_config(&snapshot.id).await?.is_some();
        let authorized = assigned == bot
            && snapshot.members.iter().any(|member| {
                member.bot_id == bot
                    && match phase.as_str() {
                        "worker" => member.role == "worker" || collaborative,
                        "direct" | "synthesis" => member.role == "coordinator",
                        _ => false,
                    }
            });
        if !authorized {
            return Err(sqlx::Error::Protocol(
                "Group attachment recipient does not match the accepted dispatch.".into(),
            ));
        }
        self.message_by_id(row.get("parent_message_id")).await
    }
    /// Route an approval from its exact persisted runtime turn to the visible chat.
    /// A guided message may be the newest row for a worker turn, so find its
    /// durable Group node among messages in that same conversation/thread/turn.
    pub async fn approval_conversation_id(
        &self,
        thread: &str,
        turn: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        if thread.is_empty() || turn.is_empty() {
            return Ok(None);
        }
        let message = self.message_for_codex_thread_and_turn(thread, turn).await?;
        if message.is_none() {
            if let Some(conversation) = self.goal_conversation_for_turn(thread, turn).await? {
                return Ok(Some(conversation));
            }
            return Ok(self
                .subagent_ownership_for_thread(thread)
                .await?
                .map(|ownership| ownership.conversation_id));
        }
        let Some(message) = message else {
            return Ok(None);
        };
        let groups: Vec<String> = sqlx::query_scalar("SELECT DISTINCT parent.conversation_id FROM messages child JOIN group_nodes node ON node.device_id=child.device_id AND node.client_message_id=child.client_message_id JOIN group_runs run ON run.parent_message_id=node.parent_message_id JOIN messages parent ON parent.id=run.parent_message_id WHERE child.conversation_id=? AND child.codex_thread_id=? AND child.codex_turn_id=? LIMIT 2")
            .bind(&message.conversation_id).bind(thread).bind(turn).fetch_all(&self.pool).await?;
        Ok(match groups.as_slice() {
            [] => Some(message.conversation_id),
            [group] => Some(group.clone()),
            _ => None,
        })
    }
    /// Delete the Group and its owned transcript together. Remaining message
    /// rows are also chat-list sources, so deleting only metadata leaves ghosts.
    pub async fn delete_channel(&self, id: &str) -> Result<bool, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let conversation: Option<String> =
            sqlx::query_scalar("SELECT conversation_id FROM channels WHERE id=?")
                .bind(id)
                .fetch_optional(&mut *tx)
                .await?;
        let Some(conversation) = conversation else {
            return Ok(false);
        };
        let active: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM group_runs WHERE channel_id=? AND state NOT IN ('completed','failed','cancelled')) OR EXISTS(SELECT 1 FROM automation_runs r JOIN automations a ON a.id=r.automation_id WHERE a.scope_type='group_chat' AND a.scope_id=? AND r.status='running') OR EXISTS(SELECT 1 FROM project_assignments WHERE group_id=? AND state='integrating')")
            .bind(id).bind(id).bind(id).fetch_one(&mut *tx).await?;
        if active {
            return Ok(false);
        }
        // Only dedicated worker conversations are owned by the Group. Never
        // delete a Bot's primary chat or a conversation with unrelated sends.
        let mut conversations: Vec<String> = sqlx::query_scalar("SELECT DISTINCT m.conversation_id FROM group_nodes n JOIN group_runs g ON g.parent_message_id=n.parent_message_id JOIN messages m ON m.device_id=n.device_id AND m.client_message_id=n.client_message_id WHERE g.channel_id=? AND n.phase='worker' AND NOT EXISTS(SELECT 1 FROM bot_workspaces WHERE conversation_id=m.conversation_id) AND NOT EXISTS(SELECT 1 FROM channels WHERE conversation_id=m.conversation_id) AND NOT EXISTS(SELECT 1 FROM messages other WHERE other.conversation_id=m.conversation_id AND NOT EXISTS(SELECT 1 FROM group_nodes owned JOIN group_runs own_run ON own_run.parent_message_id=owned.parent_message_id WHERE own_run.channel_id=g.channel_id AND owned.device_id=other.device_id AND owned.client_message_id=other.client_message_id) AND NOT EXISTS(SELECT 1 FROM async_questions answer JOIN messages original ON original.conversation_id=answer.conversation_id AND original.codex_thread_id=answer.thread_id AND original.codex_turn_id=answer.turn_id JOIN group_nodes owned ON owned.device_id=original.device_id AND owned.client_message_id=original.client_message_id JOIN group_runs own_run ON own_run.parent_message_id=owned.parent_message_id WHERE answer.message_id=other.id AND answer.conversation_id=other.conversation_id AND answer.state='answered' AND own_run.channel_id=g.channel_id))")
            .bind(id).fetch_all(&mut *tx).await?;
        conversations.push(conversation);
        for conversation in &conversations {
            let active: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id=? AND state IN ('accepted_by_wonder','dispatching_to_codex','accepted_by_codex','streaming','uncertain'))")
                .bind(conversation).fetch_one(&mut *tx).await?;
            if active {
                return Ok(false);
            }
        }
        sqlx::query("DELETE FROM automations WHERE scope_type='group_chat' AND scope_id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        // Repository worktrees are retained; deleting a chat only removes its metadata.
        sqlx::query("DELETE FROM project_assignments WHERE group_id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM channels WHERE id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        for conversation in conversations {
            sqlx::query("DELETE FROM approvals WHERE thread_id IN (SELECT codex_thread_id FROM conversations WHERE id=?)").bind(&conversation).execute(&mut *tx).await?;
            sqlx::query("DELETE FROM pending_app_server_notifications WHERE thread_id IN (SELECT codex_thread_id FROM conversations WHERE id=?)").bind(&conversation).execute(&mut *tx).await?;
            for statement in [
                "DELETE FROM async_questions WHERE conversation_id=?",
                "DELETE FROM assistant_messages WHERE conversation_id=?",
                "DELETE FROM conversation_settings WHERE conversation_id=?",
                "DELETE FROM conversation_files WHERE conversation_id=?",
                "DELETE FROM history_entries WHERE conversation_id=?",
                "DELETE FROM history_hydration WHERE conversation_id=?",
                "DELETE FROM search_documents WHERE conversation_id=?",
                "DELETE FROM messages WHERE conversation_id=?",
            ] {
                sqlx::query(statement)
                    .bind(&conversation)
                    .execute(&mut *tx)
                    .await?;
            }
            sqlx::query("DELETE FROM events WHERE json_extract(payload_json,'$.conversationId')=? OR json_extract(payload_json,'$.event.conversationId')=?").bind(&conversation).bind(&conversation).execute(&mut *tx).await?;
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
        tx.commit().await?;
        Ok(true)
    }

    pub async fn recover_group_runs(&self) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE group_runs SET state='pending' WHERE state='running'")
            .execute(&self.pool)
            .await?;
        Ok(())
    }
    pub async fn pending_group_runs(&self) -> Result<Vec<GroupRun>, sqlx::Error> {
        let rows = sqlx::query("SELECT m.*,g.snapshot_json FROM group_runs g JOIN messages m ON m.id=g.parent_message_id WHERE (g.state='pending' OR (g.state='blocked' AND CAST(g.updated_at AS INTEGER) < CAST(strftime('%s','now') AS INTEGER)*1000-10000)) AND (NOT EXISTS(SELECT 1 FROM project_assignments a WHERE a.parent_message_id=g.parent_message_id) OR EXISTS(SELECT 1 FROM project_assignments a WHERE a.parent_message_id=g.parent_message_id AND a.state IN ('queued','working','uncertain','awaiting_input') AND NOT EXISTS(SELECT 1 FROM json_each(a.dependency_ids) needed LEFT JOIN project_assignments dependency ON dependency.id=needed.value WHERE dependency.id IS NULL OR dependency.state!='integrated'))) ORDER BY m.created_at,m.id LIMIT 16").fetch_all(&self.pool).await?;
        rows.iter()
            .map(|row| {
                Ok(GroupRun {
                    parent: stored_message(row),
                    channel: serde_json::from_str(row.get("snapshot_json"))
                        .map_err(|e| sqlx::Error::Decode(Box::new(e)))?,
                })
            })
            .collect()
    }
    pub async fn claim_group_run(&self, parent: &str) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE group_runs SET state='running' WHERE parent_message_id=? AND state IN ('pending','blocked') AND NOT EXISTS (SELECT 1 FROM group_runs active WHERE active.channel_id=group_runs.channel_id AND active.state='running')").bind(parent).execute(&self.pool).await?.rows_affected() == 1)
    }
    pub async fn finish_group_run(
        &self,
        parent: &str,
        output: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("UPDATE group_runs SET state=?,output_message_id=?,updated_at=? WHERE parent_message_id=?")
            .bind(if output.is_some(){"completed"}else{"blocked"}).bind(output).bind(now).bind(parent).execute(&mut *tx).await?;
        sqlx::query("UPDATE messages SET state=? WHERE id=?")
            .bind(if output.is_some() {
                "completed"
            } else {
                "uncertain"
            })
            .bind(parent)
            .execute(&mut *tx)
            .await?;
        if output.is_some() {
            sqlx::query("UPDATE automation_runs SET status='completed',finished_at=?,error=NULL WHERE message_id=?").bind(now).bind(parent).execute(&mut *tx).await?;
        }
        tx.commit().await
    }
    /// Plan the immutable child identity before inserting or dispatching it.
    pub async fn plan_group_node(
        &self,
        parent: &StoredMessage,
        client: &str,
        bot: &str,
        phase: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO group_nodes(parent_message_id,device_id,client_message_id,bot_id,phase) VALUES (?,?,?,?,?) ON CONFLICT(parent_message_id,client_message_id) DO NOTHING")
            .bind(&parent.id).bind(&parent.device_id).bind(client).bind(bot).bind(phase).execute(&self.pool).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn fixture(url: &str) -> (Store, StoredMessage) {
        let store = Store::connect(url).await.unwrap();
        store
            .upsert_owner_device("owner", "Owner", "{}", "1")
            .await
            .unwrap();
        store
            .upsert_bot(
                "bot",
                "Original name",
                "Assistant",
                "Help",
                "/tmp/group-test",
                "test",
                None,
                None,
                "1",
            )
            .await
            .unwrap();
        store
            .create_channel(
                "group",
                "group-chat",
                "Team",
                None,
                "bot",
                &[("bot", "coordinator")],
                "1",
            )
            .await
            .unwrap();
        let MessageInsert::Inserted(parent) = store
            .insert_message("owner", "parent", "hello", "hash", "group-chat", "1")
            .await
            .unwrap()
        else {
            panic!()
        };
        store
            .add_channel_message(NewChannelMessage {
                channel_id: "group",
                message_id: &parent.id,
                author_kind: "user",
                author_bot_id: None,
                phase: "user",
                created_at: "1",
                presentation_kind: "message",
                outcome: Some("completed"),
                retryable: false,
            })
            .await
            .unwrap();
        (store, parent)
    }
    #[tokio::test]
    async fn collaboration_freezes_defaults_and_preserves_stop_across_progress() {
        let (store, _) = fixture("sqlite::memory:").await;
        let original = r#"{"routing":{"model":"luna","reasoningEffort":"xhigh"}}"#;
        store
            .save_collaboration_config("group", original)
            .await
            .unwrap();
        let MessageInsert::Inserted(parent) = store
            .insert_message("owner", "collab", "work", "hash", "group-chat", "2")
            .await
            .unwrap()
        else {
            panic!()
        };
        store
            .add_channel_message(NewChannelMessage {
                channel_id: "group",
                message_id: &parent.id,
                author_kind: "user",
                author_bot_id: None,
                phase: "user",
                created_at: "2",
                presentation_kind: "message",
                outcome: None,
                retryable: false,
            })
            .await
            .unwrap();
        store
            .save_collaboration_config("group", r#"{"routing":{"model":"changed"}}"#)
            .await
            .unwrap();
        assert_eq!(
            store
                .collaboration_context(&parent.id)
                .await
                .unwrap()
                .as_deref(),
            Some(original)
        );
        store
            .save_collaboration_plan(
                &parent.id,
                "group",
                r#"{"cancelled":true,"assignments":[]}"#,
            )
            .await
            .unwrap();
        store
            .save_collaboration_plan(
                &parent.id,
                "group",
                r#"{"cancelled":false,"assignments":[]}"#,
            )
            .await
            .unwrap();
        let plan: serde_json::Value =
            serde_json::from_str(&store.collaboration_plan(&parent.id).await.unwrap().unwrap())
                .unwrap();
        assert_eq!(plan["cancelled"], true);
        store
            .settle_collaboration(&parent.id, "failed")
            .await
            .unwrap();
        store
            .retry_collaboration_planning(&parent.id)
            .await
            .unwrap();
        assert!(store
            .collaboration_plan(&parent.id)
            .await
            .unwrap()
            .is_none());
        assert_eq!(
            store
                .collaboration_context(&parent.id)
                .await
                .unwrap()
                .as_deref(),
            Some(original)
        );
        assert!(store
            .reserve_team_creation("receipt", "same")
            .await
            .unwrap()
            .is_none());
        assert!(store
            .reserve_team_creation("receipt", "different")
            .await
            .is_err());
        store
            .finish_team_creation("receipt", "result")
            .await
            .unwrap();
        assert_eq!(
            store
                .reserve_team_creation("receipt", "same")
                .await
                .unwrap()
                .as_deref(),
            Some("result")
        );
    }
    #[tokio::test]
    async fn deleting_group_removes_owned_transcripts_without_orphans_or_active_work_loss() {
        let (store, parent) = fixture("sqlite::memory:").await;
        // Pending or uncertain Group work must survive a rejected deletion.
        assert!(!store.delete_channel("group").await.unwrap());
        assert!(store.channel("group").await.unwrap().is_some());
        store.ensure_bot_workspace("bot", "Bot", "2").await.unwrap();
        let direct = store
            .bot("bot")
            .await
            .unwrap()
            .unwrap()
            .conversation_id
            .unwrap();
        store
            .insert_message(
                "owner",
                "unrelated",
                "Keep this Bot chat",
                "hash",
                &direct,
                "2",
            )
            .await
            .unwrap();
        store
            .create_conversation("worker-chat", "bot", "Worker", "2")
            .await
            .unwrap();
        store
            .plan_group_node(&parent, "worker", "bot", "worker")
            .await
            .unwrap();
        let MessageInsert::Inserted(worker) = store
            .insert_message("owner", "worker", "Worker task", "hash", "worker-chat", "2")
            .await
            .unwrap()
        else {
            panic!()
        };
        store
            .set_conversation_thread("group-chat", "group-thread", None, "2")
            .await
            .unwrap();
        store
            .set_conversation_thread("worker-chat", "worker-thread", None, "2")
            .await
            .unwrap();
        store
            .complete_assistant_message(
                "worker-chat",
                "worker-thread",
                "worker-turn",
                "item",
                "Worker result",
                "2",
            )
            .await
            .unwrap();
        store
            .update_message_delivery(&worker.id, "safe_to_retry", None, None)
            .await
            .unwrap();
        store
            .finish_group_run(&parent.id, Some("output"), "3")
            .await
            .unwrap();
        let automation = store
            .insert_scoped_automation(
                "auto",
                "Group task",
                "continuation",
                "group_chat",
                "group",
                "bot",
                Some("group-chat"),
                "Task",
                "FREQ=DAILY",
                "UTC",
                "active",
                "all_runs",
                None,
                None,
                None,
                "3",
            )
            .await
            .unwrap();
        store
            .claim_scheduled_automation("run", &automation, "now", "now", None, false)
            .await
            .unwrap();
        assert!(
            !store.delete_channel("group").await.unwrap(),
            "Accepted automation fences deletion before a message exists"
        );
        store
            .finish_automation_run("run", "completed", "4", None, None)
            .await
            .unwrap();
        assert!(store.delete_channel("group").await.unwrap());
        assert!(!store.delete_channel("group").await.unwrap());
        assert!(store.channel("group").await.unwrap().is_none());
        assert!(store.bot("bot").await.unwrap().is_some());
        assert!(store.automation_by_id("auto").await.unwrap().is_none());
        for id in ["group-chat", "worker-chat"] {
            assert!(store.conversation(id).await.unwrap().is_none());
            assert!(store.conversation_thread(id).await.unwrap().is_none());
            assert!(store
                .messages_for_conversation(id)
                .await
                .unwrap()
                .is_empty());
            assert!(store
                .assistant_messages_for_conversation(id)
                .await
                .unwrap()
                .is_empty());
        }
        let summaries = store.list_conversation_summaries().await.unwrap();
        assert!(!summaries
            .iter()
            .any(|chat| matches!(chat.conversation_id.as_str(), "group-chat" | "worker-chat")));
        assert!(summaries.iter().any(|chat| chat.conversation_id == direct));
        assert_eq!(
            store.messages_for_conversation(&direct).await.unwrap()[0].body,
            "Keep this Bot chat"
        );
    }

    #[tokio::test]
    async fn accepted_parent_and_frozen_roster_survive_reopen_without_another_request() {
        let directory = tempfile::tempdir().unwrap();
        let url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("store.db").display()
        );
        let (store, parent) = fixture(&url).await;
        assert!(store.claim_group_run(&parent.id).await.unwrap());
        assert!(!store.claim_group_run(&parent.id).await.unwrap());
        sqlx::query("UPDATE bots SET name='Changed' WHERE id='bot'")
            .execute(&store.pool)
            .await
            .unwrap();
        store.pool.close().await;
        let store = Store::connect(&url).await.unwrap();
        store.recover_dispatch_claims().await.unwrap();
        store.recover_group_runs().await.unwrap();
        let runs = store.pending_group_runs().await.unwrap();
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].parent.id, parent.id);
        assert_eq!(runs[0].parent.state, "accepted_by_wonder");
        assert_eq!(runs[0].channel.members[0].bot_name, "Original name");
    }
    #[tokio::test]
    async fn followup_freezes_visible_history_before_later_edits() {
        let (store, parent) = fixture("sqlite::memory:").await;
        let MessageInsert::Inserted(followup) = store
            .insert_message(
                "owner",
                "followup",
                "another idea?",
                "hash2",
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
                message_id: &followup.id,
                author_kind: "user",
                author_bot_id: None,
                phase: "user",
                created_at: "2",
                presentation_kind: "message",
                outcome: None,
                retryable: false,
            })
            .await
            .unwrap();
        sqlx::query("UPDATE messages SET body='later edit' WHERE id=?")
            .bind(&parent.id)
            .execute(&store.pool)
            .await
            .unwrap();
        let runs = store.pending_group_runs().await.unwrap();
        let run = runs.iter().find(|r| r.parent.id == followup.id).unwrap();
        assert_eq!(run.channel.messages.len(), 1);
        assert_eq!(run.channel.messages[0].message_id, parent.id);
        assert_eq!(run.channel.messages[0].body, "hello");
    }
    #[tokio::test]
    async fn recover_each_child_boundary_without_repeating_possibly_executed_work() {
        let (store, parent) = fixture("sqlite::memory:").await;
        for client in ["queued", "claimed", "submitted", "completed"] {
            store
                .plan_group_node(
                    &parent,
                    client,
                    "bot",
                    if client == "submitted" {
                        "synthesis"
                    } else {
                        "worker"
                    },
                )
                .await
                .unwrap();
            let MessageInsert::Inserted(child) = store
                .insert_message("owner", client, "work", "hash", client, "2")
                .await
                .unwrap()
            else {
                panic!()
            };
            if client != "queued" {
                assert!(store.claim_message_for_dispatch(&child.id).await.unwrap());
            }
            if matches!(client, "submitted" | "completed") {
                store
                    .begin_dispatch_submission(&child.id, "thread")
                    .await
                    .unwrap();
            }
            if client == "completed" {
                store
                    .update_message_delivery(&child.id, "completed", Some("thread"), Some("turn"))
                    .await
                    .unwrap();
            }
        }
        store.recover_dispatch_claims().await.unwrap();
        for (client, expected, claimable) in [
            ("queued", "accepted_by_wonder", true),
            ("claimed", "accepted_by_wonder", true),
            ("submitted", "uncertain", false),
            ("completed", "completed", false),
        ] {
            let child = store
                .message_by_device_and_client_message_id("owner", client)
                .await
                .unwrap()
                .unwrap();
            assert_eq!(child.state, expected);
            assert_eq!(
                store.claim_message_for_dispatch(&child.id).await.unwrap(),
                claimable
            );
        }
        let ambiguous = store.ambiguous_dispatch_messages().await.unwrap();
        assert_eq!(ambiguous.len(), 1);
        assert_eq!(ambiguous[0].client_message_id, "submitted");
        store.finish_group_run(&parent.id, None, "0").await.unwrap();
        assert_eq!(store.pending_group_runs().await.unwrap().len(), 1);
        store
            .finish_group_run(&parent.id, Some("result"), "3")
            .await
            .unwrap();
        assert!(store.pending_group_runs().await.unwrap().is_empty());
    }
}
