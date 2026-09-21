//! Async prompts are messages, not pending App Server RPCs.
use super::*;

#[derive(Debug)]
pub struct AsyncQuestion {
    pub id: String,
    pub conversation_id: String,
    pub runtime_conversation_id: String,
    pub turn_id: String,
    pub item_id: String,
    pub questions: serde_json::Value,
    pub response: Option<serde_json::Value>,
    pub state: String,
    pub expires_at_ms: i64,
}
// Scope is derived from persisted execution ownership, never question content.
// Private worker questions must belong to an exact accepted Group node turn.
// Reusing a worker conversation across Groups/Bots fails closed.
macro_rules! scoped_questions {
    ($query:literal) => { concat!(r#"
WITH node_owners AS (
 SELECT child.conversation_id AS runtime_conversation, channel.conversation_id AS visible_conversation,
        node.bot_id, node.phase
 FROM group_nodes node
 JOIN messages child ON child.device_id=node.device_id AND child.client_message_id=node.client_message_id
 JOIN group_runs run ON run.parent_message_id=node.parent_message_id
 JOIN channels channel ON channel.id=run.channel_id
 JOIN messages parent ON parent.id=run.parent_message_id AND parent.conversation_id=channel.conversation_id
), owned_conversations AS (
 SELECT runtime_conversation, MIN(visible_conversation) AS visible_conversation
 FROM node_owners
 WHERE NOT EXISTS(SELECT 1 FROM bot_workspaces WHERE conversation_id=runtime_conversation)
   AND NOT EXISTS(SELECT 1 FROM channels WHERE conversation_id=runtime_conversation)
 GROUP BY runtime_conversation
 HAVING COUNT(DISTINCT visible_conversation)=1 AND COUNT(DISTINCT bot_id)=1
    AND MIN(phase)='worker' AND MAX(phase)='worker'
    AND MIN(bot_id)=(SELECT bot_id FROM conversation_metadata WHERE id=runtime_conversation)
), scoped_questions AS (
 SELECT q.*, q.rowid AS position,
 CASE
 WHEN EXISTS(SELECT 1 FROM channels WHERE conversation_id=q.conversation_id) THEN
   CASE WHEN EXISTS(SELECT 1 FROM messages m WHERE m.conversation_id=q.conversation_id
     AND m.codex_thread_id=q.thread_id AND m.codex_turn_id=q.turn_id)
     AND NOT EXISTS(SELECT 1 FROM messages other WHERE other.codex_thread_id=q.thread_id
       AND other.codex_turn_id=q.turn_id AND other.conversation_id!=q.conversation_id)
   THEN q.conversation_id END
 WHEN EXISTS(SELECT 1 FROM group_nodes n JOIN messages m
     ON m.device_id=n.device_id AND m.client_message_id=n.client_message_id
     WHERE m.conversation_id=q.conversation_id) THEN
   (SELECT owned.visible_conversation FROM owned_conversations owned
    WHERE owned.runtime_conversation=q.conversation_id
      AND NOT EXISTS(SELECT 1 FROM messages other WHERE other.codex_thread_id=q.thread_id
        AND other.codex_turn_id=q.turn_id AND other.conversation_id!=q.conversation_id)
      AND EXISTS(SELECT 1 FROM messages m WHERE m.conversation_id=q.conversation_id
        AND m.codex_thread_id=q.thread_id AND m.codex_turn_id=q.turn_id
        AND EXISTS(SELECT 1 FROM group_nodes n WHERE n.device_id=m.device_id AND n.client_message_id=m.client_message_id)))
 ELSE q.conversation_id
 END AS visible_conversation
 FROM async_questions q
)
"#, $query) };
}

pub(crate) use scoped_questions;

pub(crate) const VERIFIED_SUBAGENT_ROOT_SQL: &str = "WITH RECURSIVE parents(id,depth) AS (SELECT ?,0 UNION ALL SELECT s.parent_conversation_id,p.depth+1 FROM parents p JOIN subagent_ownership s ON s.conversation_id=p.id WHERE p.depth<32) SELECT id FROM parents WHERE NOT EXISTS(SELECT 1 FROM subagent_ownership s WHERE s.conversation_id=parents.id) ORDER BY depth DESC LIMIT 1";
pub(crate) const VERIFIED_WORKER_GROUP_SQL: &str = "SELECT MIN(c.conversation_id) FROM group_nodes n JOIN messages m ON m.device_id=n.device_id AND m.client_message_id=n.client_message_id JOIN group_runs r ON r.parent_message_id=n.parent_message_id JOIN channels c ON c.id=r.channel_id JOIN messages parent ON parent.id=r.parent_message_id AND parent.conversation_id=c.conversation_id WHERE m.conversation_id=? AND NOT EXISTS(SELECT 1 FROM bot_workspaces WHERE conversation_id=m.conversation_id) AND NOT EXISTS(SELECT 1 FROM channels WHERE conversation_id=m.conversation_id) HAVING COUNT(DISTINCT c.conversation_id)=1 AND COUNT(DISTINCT n.bot_id)=1 AND MIN(n.phase)='worker' AND MAX(n.phase)='worker' AND MIN(n.bot_id)=(SELECT bot_id FROM conversation_metadata WHERE id=?)";

impl Store {
    pub const GROUP_QUESTION_TURN_FINISHED: &str = "This Group reply has finished. Your answer is still saved as a draft; send it as a new Group message.";
    pub const QUESTION_PARENT_UNAVAILABLE: &str =
        "The parent conversation is unavailable. Your answer is still saved as a draft.";
    pub const QUESTION_PARENT_GROUP_UNAVAILABLE: &str =
        "The parent Group is unavailable. Your answer is still saved as a draft.";
    pub async fn save_async_question(
        &self,
        conversation: &str,
        thread: &str,
        turn: &str,
        item: &str,
        questions: &str,
        deadline: i64,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO async_questions(id,conversation_id,thread_id,turn_id,item_id,questions_json,expires_at_ms) SELECT ?,?,?,?,?,?,? WHERE ?!='wonder-purpose' OR NOT EXISTS(SELECT 1 FROM async_questions WHERE conversation_id=? AND item_id='wonder-purpose') ON CONFLICT(thread_id,turn_id,item_id) DO NOTHING")
            .bind(uuid::Uuid::new_v4().to_string()).bind(conversation).bind(thread).bind(turn).bind(item).bind(questions).bind(deadline).bind(item).bind(conversation).execute(&self.pool).await?;
        // A task can win the race before the startup question reaches us.
        sqlx::query("UPDATE async_questions SET state='dismissed',response_json='{\"answers\":[],\"skip\":true}' WHERE conversation_id=? AND turn_id=? AND state='pending' AND EXISTS(SELECT 1 FROM messages init JOIN bot_initializations i ON i.message_id=init.id WHERE init.conversation_id=? AND init.codex_turn_id=? AND EXISTS(SELECT 1 FROM messages user WHERE user.conversation_id=init.conversation_id AND user.id!=init.id AND NOT EXISTS(SELECT 1 FROM bot_workspace_followups f WHERE f.message_id=user.id)))")
            .bind(conversation).bind(turn).bind(conversation).bind(turn).execute(&self.pool).await?;
        sqlx::query("UPDATE async_questions SET state='dismissed' WHERE conversation_id=? AND state='pending' AND EXISTS(SELECT 1 FROM messages child JOIN group_nodes n ON n.device_id=child.device_id AND n.client_message_id=child.client_message_id JOIN channel_messages init ON init.message_id=n.parent_message_id WHERE child.conversation_id=async_questions.conversation_id AND init.presentation_kind='status' AND init.author_kind='user' AND EXISTS(SELECT 1 FROM channel_messages user WHERE user.channel_id=init.channel_id AND user.author_kind='user' AND user.presentation_kind='message'))")
            .bind(conversation).execute(&self.pool).await?;
        Ok(())
    }
    pub async fn async_questions(
        &self,
        conversation: &str,
        now: i64,
    ) -> Result<Vec<AsyncQuestion>, sqlx::Error> {
        let rows = sqlx::query(scoped_questions!(
            " SELECT * FROM scoped_questions WHERE visible_conversation=? ORDER BY position DESC LIMIT 100"
        ))
        .bind(conversation)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|r| {
                let deadline = r.get("expires_at_ms");
                let state: String = r.get("state");
                Ok(AsyncQuestion {
                    id: r.get("id"),
                    conversation_id: r.get("visible_conversation"),
                    runtime_conversation_id: r.get("conversation_id"),
                    turn_id: r.get("turn_id"),
                    item_id: r.get("item_id"),
                    questions: serde_json::from_str(r.get("questions_json"))
                        .map_err(|e| sqlx::Error::Decode(Box::new(e)))?,
                    state: if state == "pending" && now >= deadline {
                        "expired".into()
                    } else {
                        state
                    },
                    response: r
                        .get::<Option<String>, _>("response_json")
                        .and_then(|v| serde_json::from_str(&v).ok()),
                    expires_at_ms: deadline,
                })
            })
            .collect()
    }
    pub async fn question_answer_messages(
        &self,
        conversation: &str,
    ) -> Result<Vec<StoredMessage>, sqlx::Error> {
        let rows = sqlx::query("SELECT m.* FROM messages m JOIN async_questions q ON q.message_id=m.id WHERE m.conversation_id=?")
            .bind(conversation).fetch_all(&self.pool).await?;
        Ok(rows.iter().map(stored_message).collect())
    }
    /// One SQLite commit owns both the reply and its execution intent. A second
    /// device cannot answer or skip a question that already has a winner.
    pub async fn answer_async_question(
        &self,
        conversation: &str,
        id: &str,
        device: &str,
        response: &str,
        body: Option<&str>,
        now: i64,
    ) -> Result<bool, sqlx::Error> {
        use sha2::{Digest, Sha256};
        let mut tx = self.pool.begin().await?;
        let state = if body.is_some() {
            "answered"
        } else {
            "dismissed"
        };
        // Group replies can steer their original live turn. A fresh
        // hidden continuation has no public result projection, so do not queue
        // one if completion won the race with this atomic answer acceptance.
        let changed = sqlx::query(scoped_questions!(" UPDATE async_questions SET state=?,response_json=? WHERE id=? AND id IN (SELECT id FROM scoped_questions WHERE visible_conversation=?) AND state='pending' AND expires_at_ms>? AND (?=0 OR NOT EXISTS(SELECT 1 FROM channels WHERE conversation_id=?) OR EXISTS(SELECT 1 FROM group_collaboration gc JOIN channels c ON c.id=gc.group_id WHERE c.conversation_id=?) OR EXISTS(SELECT 1 FROM messages active WHERE active.conversation_id=async_questions.conversation_id AND active.codex_thread_id=async_questions.thread_id AND active.codex_turn_id=async_questions.turn_id AND active.state IN ('accepted_by_codex','streaming')))"))
            .bind(state).bind(response).bind(id).bind(conversation).bind(now).bind(body.is_some()).bind(conversation).bind(conversation).execute(&mut *tx).await?.rows_affected();
        if changed != 1 {
            let saved: Option<String> = sqlx::query_scalar(scoped_questions!(
                " SELECT response_json FROM scoped_questions WHERE id=? AND visible_conversation=?"
            ))
            .bind(id)
            .bind(conversation)
            .fetch_optional(&mut *tx)
            .await?
            .flatten();
            if saved.as_deref() == Some(response) {
                return Ok(true);
            }
            let finished: bool = sqlx::query_scalar(scoped_questions!(
                " SELECT EXISTS(SELECT 1 FROM scoped_questions WHERE id=? AND visible_conversation=? AND EXISTS(SELECT 1 FROM channels WHERE conversation_id=visible_conversation) AND state='pending' AND expires_at_ms>?)"
            ))
            .bind(id).bind(conversation).bind(now).fetch_one(&mut *tx).await?;
            if body.is_some() && finished {
                return Err(sqlx::Error::Protocol(
                    Self::GROUP_QUESTION_TURN_FINISHED.into(),
                ));
            }
            return Ok(false);
        }
        if let Some(body) = body {
            let row = sqlx::query(
                "SELECT conversation_id,thread_id,turn_id FROM async_questions WHERE id=?",
            )
            .bind(id)
            .fetch_one(&mut *tx)
            .await?;
            let runtime_conversation: String = row.get("conversation_id");
            let thread: String = row.get("thread_id");
            let turn: String = row.get("turn_id");
            // Keep the answer on its exact child question, but continue work in
            // the verified parent. Direct child sends/Guide are intentionally
            // forbidden, including durable work left by older clients.
            let child: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM subagent_ownership WHERE conversation_id=?)",
            )
            .bind(&runtime_conversation)
            .fetch_one(&mut *tx)
            .await?;
            let parent: Option<String> = if child {
                let root: Option<String> = sqlx::query_scalar(VERIFIED_SUBAGENT_ROOT_SQL)
                    .bind(&runtime_conversation)
                    .fetch_optional(&mut *tx)
                    .await?;
                let root = root.ok_or_else(|| {
                    sqlx::Error::Protocol(Self::QUESTION_PARENT_UNAVAILABLE.into())
                })?;
                let worker: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM group_nodes n JOIN messages m ON m.device_id=n.device_id AND m.client_message_id=n.client_message_id WHERE m.conversation_id=? AND n.phase='worker')").bind(&root).fetch_one(&mut *tx).await?;
                if worker {
                    let group: Option<String> = sqlx::query_scalar(VERIFIED_WORKER_GROUP_SQL)
                        .bind(&root)
                        .bind(&root)
                        .fetch_optional(&mut *tx)
                        .await?
                        .flatten();
                    Some(group.ok_or_else(|| {
                        sqlx::Error::Protocol(Self::QUESTION_PARENT_GROUP_UNAVAILABLE.into())
                    })?)
                } else {
                    Some(root)
                }
            } else {
                None
            };
            let active: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id=? AND codex_thread_id=? AND codex_turn_id=? AND state IN ('accepted_by_codex','streaming'))")
                .bind(&runtime_conversation).bind(thread).bind(&turn).fetch_one(&mut *tx).await?;
            let active = active && parent.is_none();
            let visible = parent.as_deref().unwrap_or(conversation);
            let group:Option<String>=sqlx::query_scalar("SELECT c.id FROM channels c WHERE c.conversation_id=? AND (? OR EXISTS(SELECT 1 FROM group_collaboration gc WHERE gc.group_id=c.id))").bind(visible).bind(parent.is_some()).fetch_optional(&mut *tx).await?;
            let destination = if let Some(parent) = &parent {
                parent.as_str()
            } else if group.is_some() && !active {
                conversation
            } else {
                &runtime_conversation
            };
            let created: String = if group.is_some() {
                sqlx::query_scalar("SELECT strftime('%Y-%m-%dT%H:%M:%fZ', ? / 1000.0, 'unixepoch')")
                    .bind(now)
                    .fetch_one(&mut *tx)
                    .await?
            } else {
                now.to_string()
            };
            let message = uuid::Uuid::new_v4().to_string();
            sqlx::query("INSERT INTO messages(id,device_id,client_message_id,body,body_sha256,conversation_id,state,created_at) VALUES (?,?,?,?,?,?,'accepted_by_wonder',?)")
                .bind(&message).bind(device).bind(format!("question-{id}")).bind(body).bind(hex::encode(Sha256::digest(body.as_bytes()))).bind(destination).bind(&created).execute(&mut *tx).await?;
            if group.is_some() && !active {
                sqlx::query("INSERT INTO channel_messages(channel_id,message_id,author_kind,phase,created_at,presentation_kind) VALUES (?,?,'user','user',?,'message')").bind(group).bind(&message).bind(&created).execute(&mut *tx).await?;
            } else if active {
                sqlx::query("INSERT INTO guide_work(message_id,expected_turn_id) VALUES (?,?)")
                    .bind(&message)
                    .bind(turn)
                    .execute(&mut *tx)
                    .await?;
            } else {
                sqlx::query("INSERT INTO dispatch_work(message_id) VALUES (?)")
                    .bind(&message)
                    .execute(&mut *tx)
                    .await?;
            }
            sqlx::query("UPDATE async_questions SET message_id=? WHERE id=?")
                .bind(message)
                .bind(id)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn setup() -> Store {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_owner_device("phone", "Phone", "{}", "0")
            .await
            .unwrap();
        store
    }
    async fn question(store: &Store, item: &str) -> String {
        store
            .save_async_question(
                "chat",
                "thread",
                "turn",
                item,
                "[{\"title\":\"Which day?\"}]",
                1000,
            )
            .await
            .unwrap();
        store
            .async_questions("chat", 0)
            .await
            .unwrap()
            .into_iter()
            .find(|q| q.item_id == item)
            .unwrap()
            .id
    }
    #[tokio::test]
    async fn reply_is_atomic_idempotent_and_preserves_guide_on_restart() {
        let store = setup().await;
        let MessageInsert::Inserted(active) = store
            .insert_message("phone", "active", "work", "hash", "chat", "0")
            .await
            .unwrap()
        else {
            panic!()
        };
        store
            .update_message_delivery(&active.id, "streaming", Some("thread"), Some("turn"))
            .await
            .unwrap();
        let id = question(&store, "a").await;
        let (first, other) = tokio::join!(
            store.answer_async_question("chat", &id, "phone", "Friday", Some("Friday"), 1),
            store.answer_async_question("chat", &id, "phone", "Saturday", Some("Saturday"), 1)
        );
        assert_ne!(first.unwrap(), other.unwrap());
        store.recover_dispatch_claims().await.unwrap();
        let guides = store.pending_guides().await.unwrap();
        assert_eq!(guides.len(), 1);
        let hidden = store.question_answer_messages("chat").await.unwrap();
        assert_eq!(hidden.len(), 1);
        assert_ne!(hidden[0].id, active.id);
        assert_eq!(guides[0].1, "turn");
        let body = &guides[0].0.body;
        assert!(store
            .answer_async_question("chat", &id, "phone", body, Some(body), 2000)
            .await
            .unwrap());
        assert!(!store
            .answer_async_question("chat", &id, "phone", "skip", None, 2)
            .await
            .unwrap());
        assert_eq!(store.pending_guides().await.unwrap().len(), 1);
        assert!(store.pending_dispatch_messages().await.unwrap().is_empty());
    }
    #[tokio::test]
    async fn skip_expiry_and_replay_never_generate_work() {
        let store = setup().await;
        let id = question(&store, "a").await;
        assert!(store
            .answer_async_question("chat", &id, "phone", "skip", None, 1)
            .await
            .unwrap());
        store
            .save_async_question("chat", "thread", "turn", "a", "[]", 9000)
            .await
            .unwrap();
        assert_eq!(
            store.async_questions("chat", 0).await.unwrap()[0].state,
            "dismissed"
        );
        let id = question(&store, "b").await;
        assert!(!store
            .answer_async_question("chat", &id, "phone", "late", Some("late"), 1000)
            .await
            .unwrap());
        assert_eq!(
            store.async_questions("chat", 1000).await.unwrap()[0].state,
            "expired"
        );
        assert!(store.pending_dispatch_messages().await.unwrap().is_empty());
        assert!(store.pending_guides().await.unwrap().is_empty());
        assert!(!store
            .answer_async_question("other", &id, "phone", "reply", Some("reply"), 1)
            .await
            .unwrap());
    }
    #[tokio::test]
    async fn child_answer_preserves_question_ownership_and_only_queues_parent_work() {
        let store = setup().await;
        store
            .upsert_bot(
                "bot",
                "Bot",
                "Assistant",
                "Help",
                "/tmp/child-question-test",
                "test",
                None,
                None,
                "0",
            )
            .await
            .unwrap();
        store
            .create_conversation("parent", "bot", "Parent", "0")
            .await
            .unwrap();
        store
            .register_subagent_ownership(
                "chat",
                "parent",
                "thread",
                "parent-thread",
                "bot",
                "Child",
                None,
                None,
                None,
                "{}",
                Some("runtime"),
                Some(false),
                "completed",
                Some(false),
                "0",
            )
            .await
            .unwrap();
        let id = question(&store, "child-question").await;
        assert!(store
            .answer_async_question("chat", &id, "phone", "Friday", Some("Friday"), 1)
            .await
            .unwrap());
        let queued = store.pending_dispatch_messages().await.unwrap();
        assert_eq!(queued.len(), 1);
        assert_eq!(queued[0].conversation_id, "parent");
        assert!(store.pending_guides().await.unwrap().is_empty());
        let owner: String =
            sqlx::query_scalar("SELECT conversation_id FROM async_questions WHERE id=?")
                .bind(id)
                .fetch_one(&store.pool)
                .await
                .unwrap();
        assert_eq!(owner, "chat");
        assert!(store
            .messages_for_conversation("chat")
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn completed_turn_answer_uses_normal_durable_send() {
        let store = setup().await;
        let id = question(&store, "a").await;
        assert!(store
            .answer_async_question("chat", &id, "phone", "Friday", Some("Friday"), 1)
            .await
            .unwrap());
        assert_eq!(store.pending_dispatch_messages().await.unwrap().len(), 1);
        assert!(store.pending_guides().await.unwrap().is_empty());
    }
}

#[cfg(test)]
mod group_tests {
    use super::*;
    async fn parent(store: &Store, group: &str) -> StoredMessage {
        let chat = format!("{group}-chat");
        store
            .create_channel(
                group,
                &chat,
                group,
                None,
                "bot",
                &[("bot", "coordinator")],
                "0",
            )
            .await
            .unwrap();
        let MessageInsert::Inserted(parent) = store
            .insert_message("phone", group, "Group task", "hash", &chat, "0")
            .await
            .unwrap()
        else {
            panic!()
        };
        store
            .add_channel_message(NewChannelMessage {
                channel_id: group,
                message_id: &parent.id,
                author_kind: "user",
                author_bot_id: None,
                phase: "user",
                created_at: "0",
                presentation_kind: "message",
                outcome: Some("completed"),
                retryable: false,
            })
            .await
            .unwrap();
        parent
    }
    async fn setup() -> (Store, StoredMessage) {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_owner_device("phone", "Phone", "{}", "0")
            .await
            .unwrap();
        store
            .upsert_bot(
                "bot",
                "Bot",
                "Assistant",
                "Help",
                "/tmp/questions-test",
                "test",
                None,
                None,
                "0",
            )
            .await
            .unwrap();
        let parent = parent(&store, "group").await;
        store
            .create_conversation("private-worker", "bot", "Worker", "0")
            .await
            .unwrap();
        store
            .plan_group_node(&parent, "worker", "bot", "worker")
            .await
            .unwrap();
        let MessageInsert::Inserted(worker) = store
            .insert_message("phone", "worker", "Do work", "hash", "private-worker", "0")
            .await
            .unwrap()
        else {
            panic!()
        };
        store
            .update_message_delivery(&worker.id, "streaming", Some("thread"), Some("turn-one"))
            .await
            .unwrap();
        (store, worker)
    }
    async fn question(store: &Store, turn: &str, item: &str) -> String {
        store
            .save_async_question(
                "private-worker",
                "thread",
                turn,
                item,
                r#"[{"title":"Which day?","conversationId":"wrong-chat"}]"#,
                1000,
            )
            .await
            .unwrap();
        store
            .async_questions("group-chat", 0)
            .await
            .unwrap()
            .into_iter()
            .find(|q| q.item_id == item)
            .unwrap()
            .id
    }
    #[tokio::test]
    async fn push_routes_worker_attention_to_its_group_and_suppresses_ambiguous_ownership() {
        let (store, _) = setup().await;
        store
            .register_push("phone", "push", "https://push.test", "secret")
            .await
            .unwrap();
        for (source, conversation, kind) in [
            ("group-done", "group-chat", "completed"),
            ("worker-done", "private-worker", "completed"),
            ("worker-help", "private-worker", "attention"),
        ] {
            sqlx::query("INSERT INTO push_intents(source_key,conversation_id,kind) VALUES(?,?,?)")
                .bind(source)
                .bind(conversation)
                .bind(kind)
                .execute(&store.pool)
                .await
                .unwrap();
        }
        store.distribute_push().await.unwrap();
        let targets: Vec<(String, String)> =
            sqlx::query_as("SELECT conversation_id,kind FROM push_outbox ORDER BY kind")
                .fetch_all(&store.pool)
                .await
                .unwrap();
        assert_eq!(
            targets,
            vec![
                ("group-chat".into(), "attention".into()),
                ("group-chat".into(), "completed".into())
            ]
        );
        let other = parent(&store, "other-group").await;
        store
            .plan_group_node(&other, "other-worker", "bot", "worker")
            .await
            .unwrap();
        store
            .insert_message(
                "phone",
                "other-worker",
                "Other work",
                "hash",
                "private-worker",
                "0",
            )
            .await
            .unwrap();
        sqlx::query("INSERT INTO push_intents(source_key,conversation_id,kind) VALUES('ambiguous','private-worker','attention')").execute(&store.pool).await.unwrap();
        store.distribute_push().await.unwrap();
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM push_outbox")
            .fetch_one(&store.pool)
            .await
            .unwrap();
        assert_eq!(
            count, 2,
            "A worker reused across Groups must not pick an arbitrary parent"
        );
    }

    #[tokio::test]
    async fn nested_child_answer_reaches_only_its_verified_group() {
        let (store, _) = setup().await;
        store
            .register_subagent_ownership(
                "child",
                "private-worker",
                "child-thread",
                "thread",
                "bot",
                "Child",
                None,
                None,
                None,
                "{}",
                Some("runtime"),
                Some(false),
                "completed",
                Some(false),
                "0",
            )
            .await
            .unwrap();
        store
            .save_async_question(
                "child",
                "child-thread",
                "child-turn",
                "question",
                "[]",
                1000,
            )
            .await
            .unwrap();
        let id = store.async_questions("child", 0).await.unwrap()[0]
            .id
            .clone();
        assert!(store
            .answer_async_question("child", &id, "phone", "Friday", Some("Friday"), 1)
            .await
            .unwrap());
        let messages = store.messages_for_conversation("group-chat").await.unwrap();
        let answer = messages.iter().find(|m| m.body == "Friday").unwrap();
        let projected: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM channel_messages WHERE channel_id='group' AND message_id=?)").bind(&answer.id).fetch_one(&store.pool).await.unwrap();
        assert!(projected);
        assert!(store
            .messages_for_conversation("child")
            .await
            .unwrap()
            .is_empty());
        assert!(store.pending_guides().await.unwrap().is_empty());
        assert!(store.pending_dispatch_messages().await.unwrap().is_empty());

        let other = parent(&store, "other-group").await;
        store
            .plan_group_node(&other, "other-worker", "bot", "worker")
            .await
            .unwrap();
        store
            .insert_message(
                "phone",
                "other-worker",
                "Other work",
                "hash",
                "private-worker",
                "0",
            )
            .await
            .unwrap();
        store
            .save_async_question(
                "child",
                "child-thread",
                "child-turn",
                "ambiguous",
                "[]",
                1000,
            )
            .await
            .unwrap();
        let id = store
            .async_questions("child", 0)
            .await
            .unwrap()
            .into_iter()
            .find(|q| q.item_id == "ambiguous")
            .unwrap()
            .id;
        let error = store
            .answer_async_question("child", &id, "phone", "Saturday", Some("Saturday"), 1)
            .await
            .unwrap_err();
        assert!(
            matches!(error, sqlx::Error::Protocol(ref message) if message == Store::QUESTION_PARENT_GROUP_UNAVAILABLE)
        );
        let state: String = sqlx::query_scalar("SELECT state FROM async_questions WHERE id=?")
            .bind(&id)
            .fetch_one(&store.pool)
            .await
            .unwrap();
        assert_eq!(
            state, "pending",
            "Failed routing must roll back answer acceptance"
        );
        assert!(!store
            .messages_for_conversation("group-chat")
            .await
            .unwrap()
            .iter()
            .any(|m| m.body == "Saturday"));
    }

    #[tokio::test]
    async fn completed_collaboration_question_starts_one_visible_round() {
        let (store, worker) = setup().await;
        store
            .save_collaboration_config("group", r#"{"routing":{"model":"luna"}}"#)
            .await
            .unwrap();
        let id = question(&store, "turn-one", "purpose").await;
        store
            .update_message_delivery(&worker.id, "completed", Some("thread"), Some("turn-one"))
            .await
            .unwrap();
        assert!(store
            .answer_async_question("group-chat", &id, "phone", "answer", Some("UX reviews"), 1)
            .await
            .unwrap());
        assert!(store
            .answer_async_question("group-chat", &id, "phone", "answer", Some("UX reviews"), 1)
            .await
            .unwrap());
        let messages = store.messages_for_conversation("group-chat").await.unwrap();
        assert_eq!(
            messages.iter().filter(|m| m.body == "UX reviews").count(),
            1
        );
        let answer = messages.iter().find(|m| m.body == "UX reviews").unwrap();
        assert!(store
            .collaboration_context(&answer.id)
            .await
            .unwrap()
            .is_some());
        assert!(!store
            .messages_for_conversation("private-worker")
            .await
            .unwrap()
            .iter()
            .any(|m| m.body == "UX reviews"));
    }
    #[tokio::test]
    async fn group_question_uses_trusted_scope_and_exact_private_guide_once() {
        let (store, worker) = setup().await;
        parent(&store, "wrong").await;
        let id = question(&store, "turn-one", "first").await;
        let listed = store.async_questions("group-chat", 0).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].conversation_id, "group-chat");
        assert_eq!(listed[0].runtime_conversation_id, "private-worker");
        assert!(store
            .async_questions("private-worker", 0)
            .await
            .unwrap()
            .is_empty());
        assert!(store
            .async_questions("wrong-chat", 0)
            .await
            .unwrap()
            .is_empty());
        assert!(!store
            .answer_async_question("wrong-chat", &id, "phone", "Friday", Some("Friday"), 1)
            .await
            .unwrap());
        assert!(store
            .answer_async_question("group-chat", &id, "phone", "Friday", Some("Friday"), 1)
            .await
            .unwrap());
        store
            .update_message_delivery(&worker.id, "completed", Some("thread"), Some("turn-one"))
            .await
            .unwrap();
        assert!(store
            .answer_async_question("group-chat", &id, "phone", "Friday", Some("Friday"), 2000)
            .await
            .unwrap());
        assert!(!store
            .answer_async_question("group-chat", &id, "phone", "skip", None, 2)
            .await
            .unwrap());
        let guides = store.pending_guides().await.unwrap();
        assert_eq!(guides.len(), 1);
        assert_eq!(guides[0].0.conversation_id, "private-worker");
        assert_eq!(guides[0].1, "turn-one");
        assert_eq!(
            store
                .messages_for_conversation("group-chat")
                .await
                .unwrap()
                .len(),
            1
        );
    }
    #[tokio::test]
    async fn completed_worker_answers_refuse_work_but_skip_and_expiry_are_preserved() {
        let (store, worker) = setup().await;
        let id = question(&store, "turn-one", "first").await;
        // The list was read while active; completion before the answer is checked
        // atomically again by the store, so an HTTP preflight cannot authorize it.
        assert_eq!(
            store.async_questions("group-chat", 0).await.unwrap()[0].state,
            "pending"
        );
        store
            .update_message_delivery(&worker.id, "completed", Some("thread"), Some("turn-one"))
            .await
            .unwrap();
        let error = store
            .answer_async_question("group-chat", &id, "phone", "Friday", Some("Friday"), 1)
            .await
            .unwrap_err();
        assert!(
            matches!(error, sqlx::Error::Protocol(ref message) if message == Store::GROUP_QUESTION_TURN_FINISHED)
        );
        assert_eq!(
            store.async_questions("group-chat", 0).await.unwrap()[0].state,
            "pending"
        );
        assert!(store
            .answer_async_question("group-chat", &id, "phone", "skip", None, 1)
            .await
            .unwrap());
        assert!(store
            .answer_async_question("group-chat", &id, "phone", "skip", None, 2000)
            .await
            .unwrap());
        let expired = question(&store, "turn-one", "expired").await;
        assert!(!store
            .answer_async_question("group-chat", &expired, "phone", "late", Some("late"), 1000)
            .await
            .unwrap());
        assert_eq!(
            store
                .messages_for_conversation("private-worker")
                .await
                .unwrap()
                .len(),
            1
        );
        assert!(store.pending_guides().await.unwrap().is_empty());
    }
    #[tokio::test]
    async fn group_deletion_removes_owned_question_guides_without_orphaning_private_chat() {
        let (store, worker) = setup().await;
        let id = question(&store, "turn-one", "first").await;
        store
            .answer_async_question("group-chat", &id, "phone", "Friday", Some("Friday"), 1)
            .await
            .unwrap();
        for message in store
            .messages_for_conversation("private-worker")
            .await
            .unwrap()
        {
            store
                .update_message_delivery(&message.id, "completed", Some("thread"), Some("turn-one"))
                .await
                .unwrap();
        }
        let parent = store
            .messages_for_conversation("group-chat")
            .await
            .unwrap()
            .remove(0);
        store
            .update_message_delivery(&parent.id, "completed", None, None)
            .await
            .unwrap();
        store
            .finish_group_run(&parent.id, Some(&worker.id), "2")
            .await
            .unwrap();
        assert!(store.delete_channel("group").await.unwrap());
        assert!(store
            .conversation("private-worker")
            .await
            .unwrap()
            .is_none());
        assert!(store
            .messages_for_conversation("private-worker")
            .await
            .unwrap()
            .is_empty());
        assert!(store
            .async_questions("private-worker", 0)
            .await
            .unwrap()
            .is_empty());
    }
    #[tokio::test]
    async fn conflicting_runtime_identity_hides_question_and_public_lead_stays_public() {
        let (store, _) = setup().await;
        let id = question(&store, "turn-one", "first").await;
        store
            .create_conversation("other-direct", "bot", "Other", "0")
            .await
            .unwrap();
        let MessageInsert::Inserted(other) = store
            .insert_message(
                "phone",
                "other-direct",
                "Other work",
                "hash",
                "other-direct",
                "0",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        store
            .update_message_delivery(&other.id, "streaming", Some("thread"), Some("turn-one"))
            .await
            .unwrap();
        assert!(store
            .async_questions("group-chat", 0)
            .await
            .unwrap()
            .is_empty());
        assert!(!store
            .answer_async_question("group-chat", &id, "phone", "reply", Some("reply"), 1)
            .await
            .unwrap());
        let lead = store
            .messages_for_conversation("group-chat")
            .await
            .unwrap()
            .remove(0);
        store
            .update_message_delivery(
                &lead.id,
                "streaming",
                Some("lead-thread"),
                Some("lead-turn"),
            )
            .await
            .unwrap();
        store
            .save_async_question(
                "group-chat",
                "lead-thread",
                "lead-turn",
                "lead-question",
                "[]",
                1000,
            )
            .await
            .unwrap();
        let listed = store.async_questions("group-chat", 0).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].conversation_id, "group-chat");
        assert_eq!(listed[0].runtime_conversation_id, "group-chat");
        assert!(store
            .answer_async_question("group-chat", &listed[0].id, "phone", "skip", None, 1)
            .await
            .unwrap());
        assert_eq!(
            store
                .messages_for_conversation("group-chat")
                .await
                .unwrap()
                .len(),
            1
        );
    }
    #[tokio::test]
    async fn coordinator_answers_steer_only_the_original_live_group_turn() {
        let (store, _) = setup().await;
        let lead = store
            .messages_for_conversation("group-chat")
            .await
            .unwrap()
            .remove(0);
        store
            .update_message_delivery(
                &lead.id,
                "streaming",
                Some("lead-thread"),
                Some("lead-turn"),
            )
            .await
            .unwrap();
        for item in ["active", "late"] {
            store
                .save_async_question("group-chat", "lead-thread", "lead-turn", item, "[]", 1000)
                .await
                .unwrap();
        }
        let questions = store.async_questions("group-chat", 0).await.unwrap();
        let active = &questions.iter().find(|q| q.item_id == "active").unwrap().id;
        let late = &questions.iter().find(|q| q.item_id == "late").unwrap().id;
        assert!(store
            .answer_async_question("group-chat", active, "phone", "Friday", Some("Friday"), 1)
            .await
            .unwrap());
        let guides = store.pending_guides().await.unwrap();
        assert_eq!(guides.len(), 1);
        assert_eq!(guides[0].0.conversation_id, "group-chat");
        assert_eq!(guides[0].1, "lead-turn");
        store
            .update_message_delivery(
                &lead.id,
                "completed",
                Some("lead-thread"),
                Some("lead-turn"),
            )
            .await
            .unwrap();
        let error = store
            .answer_async_question("group-chat", late, "phone", "Friday", Some("Friday"), 1)
            .await
            .unwrap_err();
        assert!(
            matches!(error,sqlx::Error::Protocol(ref message) if message==Store::GROUP_QUESTION_TURN_FINISHED)
        );
        assert!(store
            .answer_async_question("group-chat", active, "phone", "Friday", Some("Friday"), 1)
            .await
            .unwrap());
        assert_eq!(
            store
                .messages_for_conversation("group-chat")
                .await
                .unwrap()
                .len(),
            2
        );
        assert_eq!(store.pending_guides().await.unwrap().len(), 1);
    }
    #[tokio::test]
    async fn forged_turn_unowned_continuation_and_ambiguous_group_ownership_fail_closed() {
        let (store, _) = setup().await;
        let id = question(&store, "turn-one", "first").await;
        store
            .save_async_question(
                "private-worker",
                "other-thread",
                "turn-one",
                "forged",
                "[]",
                1000,
            )
            .await
            .unwrap();
        let MessageInsert::Inserted(unowned) = store
            .insert_message(
                "phone",
                "unowned",
                "Unrelated",
                "hash",
                "private-worker",
                "0",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        store
            .update_message_delivery(
                &unowned.id,
                "streaming",
                Some("thread"),
                Some("unowned-turn"),
            )
            .await
            .unwrap();
        store
            .save_async_question(
                "private-worker",
                "thread",
                "unowned-turn",
                "unowned",
                "[]",
                1000,
            )
            .await
            .unwrap();
        assert_eq!(
            store.async_questions("group-chat", 0).await.unwrap().len(),
            1
        );
        let other = parent(&store, "other").await;
        store
            .plan_group_node(&other, "other-worker", "bot", "worker")
            .await
            .unwrap();
        store
            .insert_message(
                "phone",
                "other-worker",
                "Other Group",
                "hash",
                "private-worker",
                "0",
            )
            .await
            .unwrap();
        assert!(store
            .async_questions("group-chat", 0)
            .await
            .unwrap()
            .is_empty());
        assert!(store
            .async_questions("other-chat", 0)
            .await
            .unwrap()
            .is_empty());
        assert!(!store
            .answer_async_question("group-chat", &id, "phone", "reply", Some("reply"), 1)
            .await
            .unwrap());
        assert_eq!(
            store
                .messages_for_conversation("private-worker")
                .await
                .unwrap()
                .len(),
            3
        );
    }
}
