//! Moving a Project thread to the other provider. A thread's provider is
//! otherwise fixed (see `runtime_bindings.rs` and the migration 0095
//! triggers); `switch_project_runtime` is the only write that may change it,
//! and the host calls it only while releasing a message that carries a model
//! from the other provider.

use super::*;

/// What a switch asks for. Access mode, title, folder, history and queue stay.
/// Approval and plan mode follow the new provider's registry facts.
#[derive(Clone, Debug)]
pub struct ProjectRuntimeSwitch<'a> {
    pub conversation_id: &'a str,
    pub family: AgentFamily,
    pub provider_store: &'a str,
    pub model: &'a str,
    pub effort: Option<&'a str>,
    pub service_tier: Option<&'a str>,
    /// Readable history entries the thread has now, when the caller counted them.
    pub last_position: Option<i64>,
    pub now: &'a str,
    /// The message being released: it is the work that asked for the switch.
    pub except_message: Option<&'a str>,
    /// Continue this earlier session of the target provider (a history entry
    /// of that provider) instead of starting a fresh one. With the thread's
    /// own provider as target and no entry, the current session is replaced.
    pub resume: Option<i64>,
}

/// A native session a thread left behind.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeHistoryEntry {
    pub id: i64,
    pub family: AgentFamily,
    pub provider_store: String,
    pub native_session_id: Option<String>,
    pub runtime_thread_id: Option<String>,
    pub model: Option<String>,
    pub switched_at: String,
    pub last_position: Option<i64>,
}

/// The context still owed to the thread's next turn.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PendingHandoff {
    /// The session that was left when the switch happened.
    pub history_id: i64,
    /// A resumed session needs only what happened after this entry.
    pub delta_after_history_id: Option<i64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HandoffDelivery {
    Pending,
    Injected,
}

/// The model one message carries.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MessageTarget {
    /// `None` for messages accepted before the host recorded it.
    pub family: Option<AgentFamily>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub service_tier: Option<String>,
}

fn busy() -> sqlx::Error {
    sqlx::Error::Protocol("provider_switch_busy".into())
}

fn history_entry(row: &sqlx::sqlite::SqliteRow) -> Result<RuntimeHistoryEntry, sqlx::Error> {
    Ok(RuntimeHistoryEntry {
        id: row.get("id"),
        family: AgentFamily::from_storage(row.get("agent_family"))?,
        provider_store: row.get("provider_store"),
        native_session_id: row.get("native_session_id"),
        runtime_thread_id: row.get("runtime_thread_id"),
        model: row.get("model"),
        switched_at: row.get("switched_at"),
        last_position: row.get("last_position"),
    })
}

impl Store {
    /// Changes the provider in one transaction: records the session being left,
    /// then either binds the target provider's earlier session again or clears
    /// the binding so the next turn starts a fresh one; sets the family, model
    /// and settings; and marks a handoff pending when a session was left.
    /// Returns `None` for an unknown thread.
    ///
    /// Work already delivered or uncertain, other than `except_message`, makes
    /// this fail with `provider_switch_busy`: that turn belongs to the old
    /// session. Queued messages do not: they wait their turn behind this one.
    pub async fn switch_project_runtime(
        &self,
        switch: ProjectRuntimeSwitch<'_>,
    ) -> Result<Option<StoredProjectConversation>, sqlx::Error> {
        let id = switch.conversation_id;
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let Some(row) = sqlx::query("SELECT * FROM project_conversations WHERE conversation_id=?")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?
        else {
            return Ok(None);
        };
        let current = projects::project_conversation(&row)?;
        if !switch.family.model_in_own_namespace(switch.model)
            || switch.family.model_in_foreign_namespace(switch.model)
        {
            return Err(sqlx::Error::Protocol(
                "Choose a model from the new agent family".into(),
            ));
        }
        let working: i64 = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id=? AND id<>? AND state IN ('dispatching_to_codex','accepted_by_codex','streaming','uncertain'))")
            .bind(id)
            .bind(switch.except_message.unwrap_or_default())
            .fetch_one(&mut *tx)
            .await?;
        if working != 0 {
            return Err(busy());
        }
        let resumed = match switch.resume {
            None => None,
            Some(entry) => {
                let found = sqlx::query(
                    "SELECT * FROM project_runtime_history WHERE id=? AND conversation_id=?",
                )
                .bind(entry)
                .bind(id)
                .fetch_optional(&mut *tx)
                .await?
                .map(|row| history_entry(&row))
                .transpose()?;
                match found {
                    Some(found)
                        if found.family == switch.family
                            && found.native_session_id.is_some()
                            && found.runtime_thread_id.is_some() =>
                    {
                        Some(found)
                    }
                    _ => return Err(sqlx::Error::Protocol("resume_unavailable".into())),
                }
            }
        };
        let binding = sqlx::query(
            "SELECT runtime_thread_id,session_id FROM runtime_bindings WHERE conversation_id=?",
        )
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?;
        let runtime_thread: Option<String> = binding.as_ref().map(|b| b.get("runtime_thread_id"));
        let left = if current.native_session_id.is_some() || runtime_thread.is_some() {
            let history_id = sqlx::query("INSERT INTO project_runtime_history(conversation_id,agent_family,provider_store,native_session_id,runtime_thread_id,model,switched_at,last_position) VALUES(?,?,?,?,?,?,?,?)")
                .bind(id)
                .bind(current.family.as_str())
                .bind(&current.provider_store)
                .bind(&current.native_session_id)
                .bind(&runtime_thread)
                .bind(&current.model)
                .bind(switch.now)
                .bind(switch.last_position)
                .execute(&mut *tx)
                .await?
                .last_insert_rowid();
            sqlx::query("INSERT INTO project_pending_handoff(conversation_id,history_id,delta_after_history_id,created_at) VALUES(?,?,?,?) ON CONFLICT(conversation_id) DO UPDATE SET history_id=excluded.history_id,delta_after_history_id=excluded.delta_after_history_id,created_at=excluded.created_at")
                .bind(id)
                .bind(history_id)
                .bind(resumed.as_ref().map(|entry| entry.id))
                .bind(switch.now)
                .execute(&mut *tx)
                .await?;
            Some(history_id)
        } else {
            None
        };
        sqlx::query("INSERT INTO project_runtime_switch_guard(conversation_id) VALUES(?)")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM runtime_bindings WHERE conversation_id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE conversations SET codex_thread_id=NULL,session_id=NULL WHERE id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        let provider = switch.family.provider();
        sqlx::query("UPDATE project_conversations SET agent_family=?,provider_store=?,native_session_id=NULL,native_settings_turn=NULL,model=?,effort=?,service_tier=?,claude_approval=?,plan_mode=?,updated_at=? WHERE conversation_id=?")
            .bind(switch.family.as_str())
            .bind(switch.provider_store)
            .bind(switch.model)
            .bind(switch.effort)
            .bind(switch.service_tier)
            .bind(provider.default_approval)
            .bind(i64::from(current.plan_mode && provider.capabilities.plan_mode))
            .bind(switch.now)
            .bind(id)
            .execute(&mut *tx)
            .await?;
        if let Some(entry) = &resumed {
            let (thread, session) = (
                entry.runtime_thread_id.as_deref().unwrap_or_default(),
                entry.native_session_id.as_deref().unwrap_or_default(),
            );
            let bound = async {
                sqlx::query("UPDATE conversations SET codex_thread_id=?,session_id=? WHERE id=?")
                    .bind(thread)
                    .bind(session)
                    .bind(id)
                    .execute(&mut *tx)
                    .await?;
                sqlx::query("INSERT INTO runtime_bindings(conversation_id,agent_family,runtime_thread_id,session_id,updated_at,execution_scope,provider_store) VALUES(?,?,?,?,?,'projects',?)")
                    .bind(id)
                    .bind(switch.family.as_str())
                    .bind(thread)
                    .bind(session)
                    .bind(switch.now)
                    .bind(switch.provider_store)
                    .execute(&mut *tx)
                    .await?;
                sqlx::query("UPDATE project_conversations SET native_session_id=? WHERE conversation_id=?")
                    .bind(session)
                    .bind(id)
                    .execute(&mut *tx)
                    .await?;
                sqlx::query("DELETE FROM project_runtime_history WHERE id=?")
                    .bind(entry.id)
                    .execute(&mut *tx)
                    .await?;
                Ok::<(), sqlx::Error>(())
            }
            .await;
            // Another thread may own the session now; the caller starts fresh.
            if bound.is_err() {
                return Err(sqlx::Error::Protocol("resume_unavailable".into()));
            }
        }
        sqlx::query("DELETE FROM project_runtime_switch_guard WHERE conversation_id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        let _ = left;
        tx.commit().await?;
        self.project_conversation(id).await
    }

    /// Sessions the thread left, oldest first.
    pub async fn project_runtime_history(
        &self,
        conversation: &str,
    ) -> Result<Vec<RuntimeHistoryEntry>, sqlx::Error> {
        sqlx::query("SELECT * FROM project_runtime_history WHERE conversation_id=? ORDER BY id")
            .bind(conversation)
            .fetch_all(&self.pool)
            .await?
            .iter()
            .map(history_entry)
            .collect()
    }

    /// The context the thread's next turn must carry, if a switch left one.
    pub async fn pending_handoff(
        &self,
        conversation: &str,
    ) -> Result<Option<PendingHandoff>, sqlx::Error> {
        let row = sqlx::query("SELECT history_id,delta_after_history_id FROM project_pending_handoff WHERE conversation_id=?")
            .bind(conversation)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|row| PendingHandoff {
            history_id: row.get("history_id"),
            delta_after_history_id: row.get("delta_after_history_id"),
        }))
    }

    /// Idempotent: clearing a handoff that is already gone changes nothing.
    pub async fn clear_pending_handoff(&self, conversation: &str) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM project_pending_handoff WHERE conversation_id=?")
            .bind(conversation)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn handoff_delivery(
        &self,
        conversation: &str,
        thread: &str,
    ) -> Result<Option<HandoffDelivery>, sqlx::Error> {
        let status: Option<String> = sqlx::query_scalar("SELECT status FROM project_handoff_delivery WHERE conversation_id=? AND native_thread_id=?")
            .bind(conversation)
            .bind(thread)
            .fetch_optional(&self.pool)
            .await?;
        Ok(status.map(|status| {
            if status == "injected" {
                HandoffDelivery::Injected
            } else {
                HandoffDelivery::Pending
            }
        }))
    }

    /// Written `Pending` before the turn is submitted and `Injected` after the
    /// provider accepted it; `None` forgets a delivery known not to have happened.
    pub async fn set_handoff_delivery(
        &self,
        conversation: &str,
        thread: &str,
        status: Option<HandoffDelivery>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        match status {
            None => {
                sqlx::query("DELETE FROM project_handoff_delivery WHERE conversation_id=? AND native_thread_id=?")
                    .bind(conversation)
                    .bind(thread)
                    .execute(&self.pool)
                    .await?;
            }
            Some(status) => {
                let text = match status {
                    HandoffDelivery::Pending => "pending",
                    HandoffDelivery::Injected => "injected",
                };
                sqlx::query("INSERT INTO project_handoff_delivery(conversation_id,native_thread_id,status,updated_at) VALUES(?,?,?,?) ON CONFLICT(conversation_id,native_thread_id) DO UPDATE SET status=excluded.status,updated_at=excluded.updated_at")
                    .bind(conversation)
                    .bind(thread)
                    .bind(text)
                    .bind(now)
                    .execute(&self.pool)
                    .await?;
            }
        }
        Ok(())
    }

    /// Records the model the next accepted message from this device carries.
    /// Consumed by that message's acceptance; a retry stages it again.
    #[allow(clippy::too_many_arguments)]
    pub async fn stage_project_message_target(
        &self,
        device: &str,
        client_message: &str,
        family: AgentFamily,
        model: &str,
        effort: Option<&str>,
        service_tier: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        // Rows left by a send that never completed are not kept.
        sqlx::query("DELETE FROM project_message_targets WHERE created_at < datetime(?, '-1 day')")
            .bind(now)
            .execute(&self.pool)
            .await?;
        sqlx::query("INSERT INTO project_message_targets(device_id,client_message_id,agent_family,model,effort,service_tier,created_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(device_id,client_message_id) DO UPDATE SET agent_family=excluded.agent_family,model=excluded.model,effort=excluded.effort,service_tier=excluded.service_tier,created_at=excluded.created_at")
            .bind(device)
            .bind(client_message)
            .bind(family.as_str())
            .bind(model)
            .bind(effort)
            .bind(service_tier)
            .bind(now)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn discard_project_message_target(
        &self,
        device: &str,
        client_message: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "DELETE FROM project_message_targets WHERE device_id=? AND client_message_id=?",
        )
        .bind(device)
        .bind(client_message)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// The model, effort, speed and provider frozen with a message.
    pub async fn project_message_target(
        &self,
        message: &str,
    ) -> Result<Option<MessageTarget>, sqlx::Error> {
        let row = sqlx::query("SELECT model,reasoning_effort,service_tier,agent_family FROM message_execution_settings WHERE message_id=?")
            .bind(message)
            .fetch_optional(&self.pool)
            .await?;
        row.map(|row| {
            let family: Option<String> = row.get("agent_family");
            Ok(MessageTarget {
                family: family
                    .as_deref()
                    .map(AgentFamily::from_storage)
                    .transpose()?,
                model: row.get("model"),
                effort: row.get("reasoning_effort"),
                service_tier: row.get("service_tier"),
            })
        })
        .transpose()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn thread(store: &Store, family: AgentFamily, native: Option<&str>) {
        store
            .create_project(
                "p1",
                "request-p1",
                "hash",
                "App",
                &[ProjectRootInput {
                    path: "/work/app".into(),
                    canonical_path: "/work/app".into(),
                }],
                0,
                "now",
            )
            .await
            .unwrap();
        store
            .create_project_conversation(ProjectConversationInsert {
                conversation_id: "c1",
                project_id: "p1",
                family,
                provider_store: if family == AgentFamily::Codex {
                    "codex:home"
                } else {
                    "claude:home"
                },
                native_session_id: native,
                cwd: "/work/app",
                roots_revision: 1,
                title: "Fix",
                model: Some(if family == AgentFamily::Codex {
                    "gpt-5"
                } else {
                    "claude:sonnet"
                }),
                effort: Some("high"),
                service_tier: None,
                access_mode: "full_access",
                claude_approval: family.provider().default_approval,
                plan_mode: true,
                creation_request_id: None,
                now: "now",
            })
            .await
            .unwrap();
    }

    async fn bind_codex(store: &Store) {
        store
            .bind_project_runtime(
                "c1",
                AgentFamily::Codex,
                "codex:home",
                "codex-thread",
                None,
                "now",
            )
            .await
            .unwrap();
    }

    fn to_claude<'a>() -> ProjectRuntimeSwitch<'a> {
        ProjectRuntimeSwitch {
            conversation_id: "c1",
            family: AgentFamily::Claude,
            provider_store: "claude:home",
            model: "claude:sonnet",
            effort: Some("medium"),
            service_tier: None,
            last_position: Some(12),
            now: "later",
            except_message: None,
            resume: None,
        }
    }

    fn to_codex<'a>(now: &'a str, resume: Option<i64>) -> ProjectRuntimeSwitch<'a> {
        ProjectRuntimeSwitch {
            family: AgentFamily::Codex,
            provider_store: "codex:home",
            model: "gpt-5",
            now,
            resume,
            ..to_claude()
        }
    }

    // Contract: ordinary writes still cannot change a thread's provider or
    // native session; only the explicit switch can.
    #[tokio::test]
    async fn only_the_switch_operation_may_cross_families() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        thread(&store, AgentFamily::Codex, Some("codex-thread")).await;
        bind_codex(&store).await;
        for sql in [
            "UPDATE project_conversations SET agent_family='claude' WHERE conversation_id='c1'",
            "UPDATE project_conversations SET provider_store='claude:home' WHERE conversation_id='c1'",
            "UPDATE project_conversations SET native_session_id='other' WHERE conversation_id='c1'",
            "UPDATE project_conversations SET model='claude:sonnet' WHERE conversation_id='c1'",
            "UPDATE runtime_bindings SET agent_family='claude' WHERE conversation_id='c1'",
        ] {
            assert!(sqlx::query(sql).execute(&store.pool).await.is_err(), "{sql}");
        }
        let edit = ProjectConversationPatch {
            model: Some("claude:sonnet"),
            ..Default::default()
        };
        assert!(store
            .update_project_conversation("c1", edit, "later")
            .await
            .is_err());
        let moved = store
            .switch_project_runtime(to_claude())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(moved.family, AgentFamily::Claude);
        // The guard row does not outlive the operation.
        let guards: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM project_runtime_switch_guard")
            .fetch_one(&store.pool)
            .await
            .unwrap();
        assert_eq!(guards, 0);
        assert!(sqlx::query(
            "UPDATE project_conversations SET agent_family='codex' WHERE conversation_id='c1'"
        )
        .execute(&store.pool)
        .await
        .is_err());
    }

    #[tokio::test]
    async fn a_switch_keeps_the_thread_and_starts_a_fresh_session() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        thread(&store, AgentFamily::Codex, Some("codex-thread")).await;
        bind_codex(&store).await;
        let moved = store
            .switch_project_runtime(to_claude())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            (
                moved.family,
                moved.model.as_deref(),
                moved.effort.as_deref()
            ),
            (AgentFamily::Claude, Some("claude:sonnet"), Some("medium"))
        );
        // Identity, folder, access and plan mode carry over; approval follows
        // the new provider's default.
        assert_eq!(
            (
                moved.title.as_str(),
                moved.cwd.as_str(),
                moved.project_id.as_str(),
                moved.access_mode.as_str(),
                moved.plan_mode,
                moved.claude_approval.as_str(),
                moved.provider_store.as_str(),
            ),
            (
                "Fix",
                "/work/app",
                "p1",
                "full_access",
                true,
                "auto",
                "claude:home"
            )
        );
        assert_eq!(moved.native_session_id, None);
        assert!(store.runtime_binding("c1").await.unwrap().is_none());
        assert!(store
            .conversation_thread("c1")
            .await
            .unwrap()
            .unwrap_or_default()
            .is_empty());
        let history = store.project_runtime_history("c1").await.unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(
            (
                history[0].family,
                history[0].native_session_id.as_deref(),
                history[0].runtime_thread_id.as_deref(),
                history[0].model.as_deref(),
                history[0].last_position,
                history[0].switched_at.as_str()
            ),
            (
                AgentFamily::Codex,
                Some("codex-thread"),
                Some("codex-thread"),
                Some("gpt-5"),
                Some(12),
                "later"
            )
        );
        assert_eq!(
            store.pending_handoff("c1").await.unwrap(),
            Some(PendingHandoff {
                history_id: history[0].id,
                delta_after_history_id: None
            })
        );
        store
            .bind_project_runtime(
                "c1",
                AgentFamily::Claude,
                "claude:home",
                "claude-session",
                Some("session"),
                "later",
            )
            .await
            .unwrap();
        store.clear_pending_handoff("c1").await.unwrap();
        store.clear_pending_handoff("c1").await.unwrap();
        assert!(store.pending_handoff("c1").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn switching_back_resumes_the_old_session_and_asks_for_a_delta_only() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        thread(&store, AgentFamily::Codex, Some("codex-thread")).await;
        bind_codex(&store).await;
        store
            .switch_project_runtime(to_claude())
            .await
            .unwrap()
            .unwrap();
        store
            .bind_project_runtime(
                "c1",
                AgentFamily::Claude,
                "claude:home",
                "claude-one",
                Some("one"),
                "t1",
            )
            .await
            .unwrap();
        store
            .set_project_native_session("c1", "one", "t1")
            .await
            .unwrap();
        store.clear_pending_handoff("c1").await.unwrap();
        let codex_entry = store.project_runtime_history("c1").await.unwrap()[0].id;
        let back = store
            .switch_project_runtime(to_codex("t2", Some(codex_entry)))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(back.family, AgentFamily::Codex);
        assert_eq!(back.native_session_id.as_deref(), Some("codex-thread"));
        let binding = store.runtime_binding("c1").await.unwrap().unwrap();
        assert_eq!(binding.thread_id, "codex-thread");
        assert_eq!(binding.family, AgentFamily::Codex);
        // The resumed session is no longer "left"; the Claude one now is.
        let history = store.project_runtime_history("c1").await.unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].family, AgentFamily::Claude);
        assert_eq!(history[0].native_session_id.as_deref(), Some("one"));
        assert_eq!(
            store.pending_handoff("c1").await.unwrap(),
            Some(PendingHandoff {
                history_id: history[0].id,
                delta_after_history_id: Some(codex_entry)
            })
        );
    }

    #[tokio::test]
    async fn a_resume_that_cannot_happen_changes_nothing() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        thread(&store, AgentFamily::Codex, Some("codex-thread")).await;
        bind_codex(&store).await;
        // Unknown entry, and an entry of the wrong provider.
        for resume in [99, 1] {
            let mut request = to_claude();
            request.resume = Some(resume);
            assert!(matches!(
                store.switch_project_runtime(request).await,
                Err(sqlx::Error::Protocol(message)) if message == "resume_unavailable"
            ));
        }
        let unchanged = store.project_conversation("c1").await.unwrap().unwrap();
        assert_eq!(unchanged.family, AgentFamily::Codex);
        assert!(store.runtime_binding("c1").await.unwrap().is_some());
        assert!(store
            .project_runtime_history("c1")
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn a_fresh_thread_needs_no_handoff_and_the_same_provider_replaces_its_session() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        thread(&store, AgentFamily::Codex, None).await;
        // Nothing ran yet, so there is nothing to hand over or remember.
        store
            .switch_project_runtime(to_claude())
            .await
            .unwrap()
            .unwrap();
        assert!(store
            .project_runtime_history("c1")
            .await
            .unwrap()
            .is_empty());
        assert!(store.pending_handoff("c1").await.unwrap().is_none());
        store
            .bind_project_runtime(
                "c1",
                AgentFamily::Claude,
                "claude:home",
                "claude-one",
                Some("one"),
                "t1",
            )
            .await
            .unwrap();
        store
            .set_project_native_session("c1", "one", "t1")
            .await
            .unwrap();
        // Replacing a session whose context delivery is uncertain.
        let replace = ProjectRuntimeSwitch {
            now: "t2",
            ..to_claude()
        };
        let replaced = store
            .switch_project_runtime(replace)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(replaced.family, AgentFamily::Claude);
        assert_eq!(replaced.native_session_id, None);
        let history = store.project_runtime_history("c1").await.unwrap();
        assert_eq!(history.len(), 1);
        assert!(store.pending_handoff("c1").await.unwrap().is_some());
    }

    #[tokio::test]
    async fn delivery_state_is_pending_then_injected_and_can_be_forgotten() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        thread(&store, AgentFamily::Codex, Some("codex-thread")).await;
        assert_eq!(store.handoff_delivery("c1", "t").await.unwrap(), None);
        store
            .set_handoff_delivery("c1", "t", Some(HandoffDelivery::Pending), "n")
            .await
            .unwrap();
        assert_eq!(
            store.handoff_delivery("c1", "t").await.unwrap(),
            Some(HandoffDelivery::Pending)
        );
        store
            .set_handoff_delivery("c1", "t", Some(HandoffDelivery::Injected), "n")
            .await
            .unwrap();
        assert_eq!(
            store.handoff_delivery("c1", "t").await.unwrap(),
            Some(HandoffDelivery::Injected)
        );
        store
            .set_handoff_delivery("c1", "t", None, "n")
            .await
            .unwrap();
        assert_eq!(store.handoff_delivery("c1", "t").await.unwrap(), None);
    }

    #[tokio::test]
    async fn a_message_carries_its_own_model_and_provider() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        thread(&store, AgentFamily::Codex, Some("codex-thread")).await;
        bind_codex(&store).await;
        store
            .upsert_owner_device("owner", "Phone", "{}", "now")
            .await
            .unwrap();
        // Without a staged target the message takes the thread's settings.
        let MessageInsert::Inserted(plain) = store
            .insert_dispatch_message("owner", "m1", "hi", "h1", "c1", &[], "now", true)
            .await
            .unwrap()
        else {
            panic!("inserted")
        };
        let target = store
            .project_message_target(&plain.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(target.family, Some(AgentFamily::Codex));
        assert_eq!(target.model.as_deref(), Some("gpt-5"));
        // A staged target is consumed by exactly the message that follows.
        store
            .stage_project_message_target(
                "owner",
                "m2",
                AgentFamily::Claude,
                "claude:sonnet",
                Some("low"),
                None,
                "2026-01-01T00:00:00Z",
            )
            .await
            .unwrap();
        let MessageInsert::Inserted(next) = store
            .insert_dispatch_message("owner", "m2", "again", "h2", "c1", &[], "now", true)
            .await
            .unwrap()
        else {
            panic!("inserted")
        };
        let target = store
            .project_message_target(&next.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(target.family, Some(AgentFamily::Claude));
        assert_eq!(
            (target.model.as_deref(), target.effort.as_deref()),
            (Some("claude:sonnet"), Some("low"))
        );
        let left: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM project_message_targets")
            .fetch_one(&store.pool)
            .await
            .unwrap();
        assert_eq!(left, 0);
        // The thread itself did not change: only the switch operation does that.
        let thread = store.project_conversation("c1").await.unwrap().unwrap();
        assert_eq!(thread.family, AgentFamily::Codex);
    }

    #[tokio::test]
    async fn a_switch_is_refused_for_delivered_work_and_wrong_models_but_not_queued_work() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        thread(&store, AgentFamily::Codex, Some("codex-thread")).await;
        bind_codex(&store).await;
        let wrong_model = ProjectRuntimeSwitch {
            model: "gpt-5",
            ..to_claude()
        };
        assert!(store.switch_project_runtime(wrong_model).await.is_err());
        store
            .upsert_owner_device("owner", "Phone", "{}", "now")
            .await
            .unwrap();
        let MessageInsert::Inserted(queued) = store
            .insert_dispatch_message("owner", "client", "work", "hash", "c1", &[], "now", true)
            .await
            .unwrap()
        else {
            panic!("inserted")
        };
        // Queued work waits behind the switch; it does not block it.
        store
            .update_message_delivery(&queued.id, "streaming", Some("codex-thread"), Some("t"))
            .await
            .unwrap();
        assert!(matches!(
            store.switch_project_runtime(to_claude()).await,
            Err(sqlx::Error::Protocol(message)) if message == "provider_switch_busy"
        ));
        // The message that asked for the switch is not "other work".
        let mut allowed = to_claude();
        allowed.except_message = Some(&queued.id);
        assert!(store
            .switch_project_runtime(allowed)
            .await
            .unwrap()
            .is_some());
        assert!(store
            .switch_project_runtime(ProjectRuntimeSwitch {
                conversation_id: "missing",
                ..to_codex("later", None)
            })
            .await
            .unwrap()
            .is_none());
    }
}
