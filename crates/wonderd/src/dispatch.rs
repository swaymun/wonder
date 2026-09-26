//! Durable direct Bot sends. The database is the queue; HTTP does not own a task.
use crate::{AppState, DeliveryState};
use serde_json::{json, Value};
use std::time::Duration;

pub async fn spawn(state: AppState) -> Result<tokio::task::JoinHandle<()>, sqlx::Error> {
    state.store.recover_dispatch_claims().await?;
    state.store.recover_group_runs().await?;
    Ok(tokio::spawn(async move {
        let mut groups = tokio::task::JoinSet::new();
        loop {
            while groups.try_join_next().is_some() {}
            let _ = crate::questions::expire_optional(&state).await;
            crate::goals::enforce_time_limits(&state).await;
            if state.ingestion.readiness(&state.store).await.ready {
                let _ = crate::groups::tick(&state, &mut groups).await;
                if let Err(error) = tick(&state).await {
                    let _ = state.logger.record(
                        "error",
                        "dispatch_recovery_failed",
                        json!({"error":error}),
                    );
                }
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }))
}

async fn message_ready(state: &AppState, message: &wonder_store::StoredMessage) -> bool {
    let Ok(family) = crate::claude::conversation_family(state, &message.conversation_id).await
    else {
        return false;
    };
    state
        .ingestion
        .readiness_for(&state.store, family)
        .await
        .ready
}

async fn tick(state: &AppState) -> Result<(), String> {
    {
        let _guard = state.dispatch_lock.lock().await;
        // A cancelled task or failed response commit can leave a claim even
        // without a process restart. No direct dispatch can run under this lock.
        state
            .store
            .recover_direct_dispatch_claims()
            .await
            .map_err(|e| e.to_string())?;
        drop(_guard);
        for message in state
            .store
            .ambiguous_dispatch_messages()
            .await
            .map_err(|e| e.to_string())?
        {
            if !message_ready(state, &message).await {
                continue;
            }
            if let Some(turn_id) = find_accepted_turn(state, &message).await? {
                state
                    .store
                    .update_message_delivery(
                        &message.id,
                        "accepted_by_codex",
                        message.codex_thread_id.as_deref(),
                        Some(&turn_id),
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                state.ingestion.request_reconciliation();
                crate::publish_message_state(
                    state,
                    &message,
                    DeliveryState::AcceptedByCodex,
                    message.codex_thread_id.as_deref(),
                    Some(&turn_id),
                )
                .await;
            }
        }
    }
    for (message, turn) in state
        .store
        .pending_guides()
        .await
        .map_err(|e| e.to_string())?
    {
        if message_ready(state, &message).await {
            let _ = crate::dispatch_guide(state.clone(), message, turn).await;
        }
    }
    for message in state
        .store
        .pending_dispatch_messages()
        .await
        .map_err(|e| e.to_string())?
    {
        if !message_ready(state, &message).await {
            continue;
        }
        crate::dispatch_to_codex(state.clone(), message).await;
    }
    Ok(())
}

pub(crate) async fn find_accepted_turn(
    state: &AppState,
    message: &wonder_store::StoredMessage,
) -> Result<Option<String>, String> {
    let Some(thread_id) = message.codex_thread_id.as_deref() else {
        return Ok(None);
    };
    let runtime = if let Some(child) =
        crate::subagents::runtime_for_conversation(state, &message.conversation_id).await?
    {
        if child.ownership.thread_id != thread_id {
            return Err("The receipt does not belong to this subagent".into());
        }
        crate::resume_child(state, &child).await?;
        child.rpc
    } else {
        let Some(bot) = crate::bot_for_conversation(state, &message.conversation_id)
            .await
            .map_err(|e| e.to_string())?
        else {
            return Ok(None);
        };
        let (bot, has_message_settings) = state
            .store
            .message_execution_bot(&message.id, bot)
            .await
            .map_err(|e| e.to_string())?;
        if has_message_settings {
            crate::file_access::dispatch_check(state, &bot, bot.effective_permission_profile())
                .await?;
        }
        let bot =
            crate::project_assignments::execution_bot(state, &message.conversation_id, bot).await?;
        let bot = crate::group_collaboration::execution_bot(state, message, bot).await?;
        crate::ensure_execution_permission_cache(state, &bot).await?;
        let resolved = crate::permission_modes::resolve(&bot);
        let roots = crate::permission_modes::runtime_roots(state, &bot).await?;
        let runtime = crate::claude::for_thread(state, thread_id).await?;
        let mut resume_params = json!({
            "threadId":thread_id,"excludeTurns":true,"cwd":bot.execution_directory(),
            "permissions":resolved.permission_profile,"runtimeWorkspaceRoots":roots,
            "approvalPolicy":resolved.approval_policy,"approvalsReviewer":resolved.approvals_reviewer,
            "developerInstructions":wonder_harness::instructions(&format!("{}\n\n{}", crate::teaching::BETA_POLICY, bot.system_prompt)),
            "config":if bot.agent_family == wonder_store::AgentFamily::Codex { crate::teaching::runtime_config(state, &runtime, bot.execution_directory()).await? } else { json!({}) }
        });
        crate::claude::configure_thread(state, &bot, &mut resume_params).await?;
        let response = runtime
            .request("thread/resume", resume_params)
            .await
            .map_err(|e| e.to_string())?;
        if response.error.is_some() {
            return Ok(None);
        }
        runtime
    };

    let mut cursor = None;
    let mut seen = std::collections::HashSet::new();
    for _ in 0..10_000 {
        let mut params = json!({"threadId":thread_id,"limit":100});
        if let Some(value) = cursor.take() {
            params["cursor"] = value;
        }
        let response = runtime
            .request("thread/items/list", params)
            .await
            .map_err(|e| e.to_string())?;
        if response.error.is_some() {
            return Ok(None);
        }
        let Some(result) = response.result else {
            return Ok(None);
        };
        if let Some(turn_id) = crate::find_client_message(&result, &message.client_message_id) {
            return Ok(Some(turn_id));
        }
        cursor = result
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(|s| json!(s));
        if cursor
            .as_ref()
            .is_some_and(|value| !seen.insert(value.to_string()))
        {
            return Err("History repeated a continuation cursor".into());
        }
        if cursor.is_none() {
            return Ok(None);
        }
    }
    // Absence, incomplete history, or an unsupported identity field proves
    // nothing about execution. Never redispatch an unknown outcome.
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use wonder_store::{MessageInsert, Store};

    async fn enqueue(state: &AppState, client: &str, direct: bool) -> wonder_store::StoredMessage {
        {
            let mut catalog = state.runtime_catalog.write().await;
            catalog.apply_models_page(&json!({"data":[{"id":"test-model","isDefault":true}]}));
            catalog.apply_permission_profiles(
                &state.bot_home,
                &json!({"data":[{"name":"test","allowed":true}]}),
            );
        }
        let MessageInsert::Inserted(message) = state
            .store
            .insert_dispatch_message("owner", client, "hello", "hash", "bot", &[], "now", direct)
            .await
            .unwrap()
        else {
            panic!("insert");
        };
        message
    }

    async fn settle(state: &AppState, message: &wonder_store::StoredMessage, expected: &str) {
        tokio::time::timeout(Duration::from_secs(15), async {
            loop {
                if state
                    .store
                    .message_by_id(&message.id)
                    .await
                    .unwrap()
                    .unwrap()
                    .state
                    == expected
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .unwrap_or_else(|error| {
            let logs = std::fs::read_to_string(
                std::path::Path::new(&state.bots_root).join("logs/test.jsonl"),
            );
            panic!("{error}: expected {expected}; {logs:?}");
        });
    }

    #[tokio::test]
    async fn restart_recovers_accepted_and_claimed_work_without_another_request() {
        for claimed in [false, true] {
            let (dir, mut state) = crate::ingestion::tests::fixture().await;
            let message = enqueue(&state, "direct", true).await;
            let guide = enqueue(&state, "guide", false).await;
            if claimed {
                assert!(state
                    .store
                    .claim_message_for_dispatch(&message.id)
                    .await
                    .unwrap());
            }
            state.store = Store::connect(&format!(
                "sqlite://{}",
                dir.path().join("state.db").display()
            ))
            .await
            .unwrap();
            let _ingestion = crate::ingestion::spawn(state.clone()).await;
            let dispatcher = spawn(state.clone()).await.unwrap();
            settle(&state, &message, "accepted_by_codex").await;
            assert_eq!(
                state
                    .store
                    .message_by_id(&guide.id)
                    .await
                    .unwrap()
                    .unwrap()
                    .state,
                "uncertain"
            );
            assert_eq!(
                std::fs::read_to_string(dir.path().join("requests"))
                    .unwrap()
                    .lines()
                    .filter(|l| *l == "turn/start")
                    .count(),
                1
            );
            dispatcher.abort();
            let _ = dispatcher.await;
            state.app_server.lock().await.shutdown().await.unwrap();
        }
    }

    #[tokio::test]
    async fn dispatch_uses_each_accepted_working_directory_after_a_bot_switch() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let alpha = dir.path().join("alpha");
        let beta = dir.path().join("beta");
        std::fs::create_dir(&alpha).unwrap();
        std::fs::create_dir(&beta).unwrap();
        let alpha = std::fs::canonicalize(alpha).unwrap();
        let beta = std::fs::canonicalize(beta).unwrap();
        let mut bot = state.store.bot("bot").await.unwrap().unwrap();
        let conversation = state
            .store
            .ensure_bot_workspace("bot", "Bot", "now")
            .await
            .unwrap();
        {
            let mut catalog = state.runtime_catalog.write().await;
            catalog.apply_models_page(&json!({"data":[{"id":"test-model","isDefault":true}]}));
            catalog.apply_permission_profiles(
                &state.bot_home,
                &json!({"data":[{"name":"test","allowed":true}]}),
            );
        }
        bot.permission_mode = Some("full-access".into());
        bot.approval_mode = Some("full-access".into());
        bot.working_directory = Some(alpha.to_str().unwrap().into());
        state
            .store
            .update_managed_bot(&bot, [false, false, false])
            .await
            .unwrap();
        let MessageInsert::Inserted(first) = state
            .store
            .insert_dispatch_message(
                "owner",
                "alpha",
                "hello alpha",
                "alpha-hash",
                &conversation,
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!("first insert");
        };

        bot.working_directory = Some(beta.to_str().unwrap().into());
        state
            .store
            .update_managed_bot(&bot, [false, false, false])
            .await
            .unwrap();
        let MessageInsert::Inserted(second) = state
            .store
            .insert_dispatch_message(
                "owner",
                "beta",
                "hello beta",
                "beta-hash",
                &conversation,
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!("second insert");
        };

        let pending = state.store.pending_queue(&conversation).await.unwrap();
        assert_eq!(
            pending
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec![first.id.as_str(), second.id.as_str()]
        );
        crate::dispatch_to_codex(state.clone(), first.clone()).await;
        settle(&state, &first, "accepted_by_codex").await;
        state
            .store
            .update_message_delivery(&first.id, "completed", Some("thread"), Some("turn"))
            .await
            .unwrap();
        crate::dispatch_to_codex(state.clone(), second.clone()).await;
        settle(&state, &second, "accepted_by_codex").await;

        let requests: Vec<Value> = std::fs::read_to_string(dir.path().join("requests-jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let starts: Vec<&Value> = requests
            .iter()
            .filter(|request| request["method"] == "thread/start")
            .collect();
        let resumes: Vec<&Value> = requests
            .iter()
            .filter(|request| request["method"] == "thread/resume")
            .collect();
        assert_eq!(starts.len(), 1);
        assert_eq!(resumes.len(), 1);
        assert_eq!(starts[0]["params"]["cwd"], alpha.to_str().unwrap());
        assert_eq!(resumes[0]["params"]["cwd"], beta.to_str().unwrap());
        assert_eq!(
            state
                .store
                .bot("bot")
                .await
                .unwrap()
                .unwrap()
                .workspace_path,
            bot.workspace_path,
            "Switching the working folder must not move the private Bot home"
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn execution_before_lost_receipt_reconciles_without_repeating_action() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let message = enqueue(&state, "direct", true).await;
        std::fs::write(dir.path().join("crash-after-execution"), "").unwrap();
        let _ingestion = crate::ingestion::spawn(state.clone()).await;
        let dispatcher = spawn(state.clone()).await.unwrap();
        settle(&state, &message, "completed").await;
        assert_eq!(
            std::fs::read_to_string(dir.path().join("requests"))
                .unwrap()
                .lines()
                .filter(|l| *l == "turn/start")
                .count(),
            1
        );
        dispatcher.abort();
        let _ = dispatcher.await;
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn response_commit_failure_recovers_from_disk_without_duplicate_submission() {
        let (dir, mut state) = crate::ingestion::tests::fixture().await;
        let message = enqueue(&state, "direct", true).await;
        let url = format!("sqlite://{}", dir.path().join("state.db").display());
        let pool = sqlx::SqlitePool::connect(&url).await.unwrap();
        sqlx::query("CREATE TRIGGER fail_receipt BEFORE UPDATE OF state ON messages WHEN NEW.state = 'accepted_by_codex' BEGIN SELECT RAISE(ABORT, 'receipt write fault'); END")
            .execute(&pool).await.unwrap();
        crate::dispatch_to_codex(state.clone(), message.clone()).await;
        assert_eq!(
            state
                .store
                .message_by_id(&message.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "dispatching_to_codex"
        );
        sqlx::query("DROP TRIGGER fail_receipt")
            .execute(&pool)
            .await
            .unwrap();
        state.app_server.lock().await.shutdown().await.unwrap();
        state.store = Store::connect(&url).await.unwrap();
        std::fs::write(dir.path().join("bad-history"), "").unwrap();
        let _ingestion = crate::ingestion::spawn(state.clone()).await;
        let dispatcher = spawn(state.clone()).await.unwrap();
        settle(&state, &message, "accepted_by_codex").await;
        tokio::time::sleep(Duration::from_millis(1200)).await;
        assert!(!state.ingestion.readiness(&state.store).await.ready);
        std::fs::remove_file(dir.path().join("bad-history")).unwrap();
        settle(&state, &message, "completed").await;
        assert_eq!(
            std::fs::read_to_string(dir.path().join("requests"))
                .unwrap()
                .lines()
                .filter(|l| *l == "turn/start")
                .count(),
            1
        );
        dispatcher.abort();
        let _ = dispatcher.await;
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn absent_history_never_releases_a_possibly_submitted_action() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let message = enqueue(&state, "direct", true).await;
        state
            .store
            .claim_message_for_dispatch(&message.id)
            .await
            .unwrap();
        state
            .store
            .begin_dispatch_submission(&message.id, "thread")
            .await
            .unwrap();
        state.store.recover_dispatch_claims().await.unwrap();
        tick(&state).await.unwrap();
        assert_eq!(
            state
                .store
                .message_by_id(&message.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "uncertain"
        );
        assert!(!state
            .store
            .requeue_message_for_retry(&message.id)
            .await
            .unwrap());
        assert!(!std::fs::read_to_string(dir.path().join("requests"))
            .unwrap()
            .lines()
            .any(|l| l == "turn/start"));
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
