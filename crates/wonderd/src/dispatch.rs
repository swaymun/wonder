//! Durable direct Bot sends. The database is the queue; HTTP does not own a task.
use crate::{AppState, DeliveryState};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

type ReceiptScans = Arc<Mutex<HashMap<String, BotReceiptScan>>>;
const RECEIPT_PAGES_PER_CYCLE: usize = 20;
const RECEIPT_HISTORY_PAGE_LIMIT: usize = 10_000;
const RECEIPT_RESCAN_DELAY: Duration = Duration::from_secs(60);

struct BotReceiptScan {
    thread_id: String,
    client_message_id: String,
    cursor: Option<String>,
    seen: HashSet<String>,
    pages_scanned: usize,
    resume_after: Instant,
}

impl BotReceiptScan {
    fn new(message: &wonder_store::StoredMessage) -> Self {
        Self {
            thread_id: message.codex_thread_id.clone().unwrap_or_default(),
            client_message_id: message.client_message_id.clone(),
            cursor: None,
            seen: HashSet::new(),
            pages_scanned: 0,
            resume_after: Instant::now(),
        }
    }

    fn reset_after(&mut self, delay: Duration) {
        self.cursor = None;
        self.seen.clear();
        self.pages_scanned = 0;
        self.resume_after = Instant::now() + delay;
    }
}

pub async fn spawn(state: AppState) -> Result<tokio::task::JoinHandle<()>, sqlx::Error> {
    state.store.recover_dispatch_claims().await?;
    state.store.recover_group_runs().await?;
    Ok(tokio::spawn(async move {
        let mut groups = tokio::task::JoinSet::new();
        let mut goal_checks = tokio::task::JoinSet::new();
        let mut project_recovery = tokio::task::JoinSet::new();
        let mut bot_recovery = tokio::task::JoinSet::new();
        let mut next_goal_check = tokio::time::Instant::now();
        let mut next_project_recovery = tokio::time::Instant::now();
        let mut next_bot_recovery = tokio::time::Instant::now();
        let bot_receipt_scans: ReceiptScans = Arc::default();
        let mut next_update_recovery = tokio::time::Instant::now();
        loop {
            while groups.try_join_next().is_some() {}
            while goal_checks.try_join_next().is_some() {}
            while project_recovery.try_join_next().is_some() {}
            while bot_recovery.try_join_next().is_some() {}
            if goal_checks.is_empty() && tokio::time::Instant::now() >= next_goal_check {
                let goal_state = state.clone();
                goal_checks
                    .spawn(async move { crate::goals::enforce_time_limits(&goal_state).await });
                next_goal_check = tokio::time::Instant::now() + Duration::from_secs(5);
            }
            let Some(_admission) = state.update_admission.claim_guard().await else {
                tokio::time::sleep(Duration::from_millis(250)).await;
                continue;
            };
            if tokio::time::Instant::now() >= next_update_recovery {
                if let Err(error) = crate::update_handoff::recover(&state).await {
                    let _ = state.logger.record(
                        "error",
                        "update_handoff_recovery_failed",
                        json!({"error":error}),
                    );
                }
                next_update_recovery = tokio::time::Instant::now() + Duration::from_secs(5);
            }
            let _ = crate::questions::expire_optional(&state).await;
            let bots_ready = state.ingestion.readiness(&state.store).await.ready;
            if bots_ready {
                let _ = crate::groups::tick(&state, &mut groups).await;
            }
            // Project sends need durable ingestion, not a healthy Bot runtime.
            if bots_ready || crate::projects::ready(&state).await {
                if let Err(error) = tick(&state).await {
                    let _ = state.logger.record(
                        "error",
                        "dispatch_recovery_failed",
                        json!({"error":error}),
                    );
                }
            }
            drop(_admission);
            // Native history can span many pages. Keep these reads outside
            // update admission and dispatch; recheck each receipt under both
            // locks before applying an observation.
            if bot_recovery.is_empty() && tokio::time::Instant::now() >= next_bot_recovery {
                let recovery_state = state.clone();
                let scans = bot_receipt_scans.clone();
                bot_recovery.spawn(async move {
                    if let Err(error) = recover_bot_receipts(&recovery_state, &scans).await {
                        let _ = recovery_state.logger.record(
                            "error",
                            "bot_receipt_recovery_failed",
                            json!({"error":error}),
                        );
                    }
                });
                next_bot_recovery = tokio::time::Instant::now() + Duration::from_secs(5);
            }
            if project_recovery.is_empty() && tokio::time::Instant::now() >= next_project_recovery {
                let recovery_state = state.clone();
                project_recovery
                    .spawn(async move { crate::projects::recover(&recovery_state).await });
                next_project_recovery = tokio::time::Instant::now() + Duration::from_secs(5);
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }))
}

async fn message_ready(state: &AppState, message: &wonder_store::StoredMessage) -> bool {
    if crate::projects::is_project(state, &message.conversation_id).await {
        return crate::projects::ready(state).await;
    }
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
        if crate::projects::is_project(state, &message.conversation_id).await {
            if crate::projects::held_on_mac(state, &message.conversation_id).await {
                continue; // Stays queued until the Mac app finishes or closes the chat.
            }
            crate::projects::clear_deliver_now(state, &message.conversation_id);
            crate::projects::dispatch(state.clone(), message).await;
        } else {
            crate::dispatch_to_codex(state.clone(), message).await;
        }
    }
    Ok(())
}

async fn recover_bot_receipts(state: &AppState, scans: &ReceiptScans) -> Result<(), String> {
    let messages = state
        .store
        .ambiguous_dispatch_messages()
        .await
        .map_err(|e| e.to_string())?;
    let ids = messages
        .iter()
        .map(|message| message.id.as_str())
        .collect::<HashSet<_>>();
    scans
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .retain(|id, _| ids.contains(id.as_str()));
    for message in messages {
        if state.update_admission.work_paused() {
            return Ok(());
        }
        if crate::projects::is_project(state, &message.conversation_id).await
            || !message_ready(state, &message).await
        {
            continue;
        }
        let mut scan = scans
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&message.id)
            .filter(|scan| {
                scan.thread_id == message.codex_thread_id.as_deref().unwrap_or_default()
                    && scan.client_message_id == message.client_message_id
            })
            .unwrap_or_else(|| BotReceiptScan::new(&message));
        if scan.resume_after > Instant::now() {
            scans
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(message.id.clone(), scan);
            continue;
        }
        // Resume/setup can change native runtime state, so it stays behind
        // update admission. Only the potentially long history read runs free.
        let runtime = {
            let Some(_admission) = state.update_admission.claim_guard().await else {
                scans
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(message.id.clone(), scan);
                return Ok(());
            };
            prepare_bot_receipt_runtime(state, &message).await
        };
        let runtime = match runtime {
            Ok(runtime) => runtime,
            Err(error) => {
                scan.reset_after(RECEIPT_RESCAN_DELAY);
                scans
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(message.id.clone(), scan);
                let _ = state.logger.record(
                    "error",
                    "bot_receipt_runtime_failed",
                    json!({"error":error,"message_id":message.id}),
                );
                continue;
            }
        };
        let Some(runtime) = runtime else {
            scans
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(message.id.clone(), scan);
            continue;
        };
        let found = scan_bot_receipt_pages(
            state,
            &message,
            &runtime,
            &mut scan,
            RECEIPT_PAGES_PER_CYCLE,
        )
        .await;
        let Some(turn_id) = (match found {
            Ok(turn) => turn,
            Err(error) => {
                scan.reset_after(RECEIPT_RESCAN_DELAY);
                let _ = state.logger.record(
                    "error",
                    "bot_receipt_history_failed",
                    json!({"error":error,"message_id":message.id}),
                );
                None
            }
        }) else {
            scans
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(message.id.clone(), scan);
            continue;
        };
        let Some(_admission) = state.update_admission.claim_guard().await else {
            scans
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(message.id.clone(), scan);
            return Ok(());
        };
        let _dispatch = state.dispatch_lock.lock().await;
        let current = state
            .store
            .ambiguous_dispatch_messages()
            .await
            .map_err(|e| e.to_string())?;
        if !current.iter().any(|current| {
            current.id == message.id
                && current.conversation_id == message.conversation_id
                && current.client_message_id == message.client_message_id
                && current.codex_thread_id == message.codex_thread_id
        }) {
            continue;
        }
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
        scans
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&message.id);
    }
    Ok(())
}

pub(crate) async fn find_accepted_turn(
    state: &AppState,
    message: &wonder_store::StoredMessage,
) -> Result<Option<String>, String> {
    if crate::projects::is_project(state, &message.conversation_id).await {
        return crate::projects::find_accepted_turn(state, message).await;
    }
    let runtime = {
        let Some(_admission) = state.update_admission.claim_guard().await else {
            return Ok(None);
        };
        prepare_bot_receipt_runtime(state, message).await?
    };
    let Some(runtime) = runtime else {
        return Ok(None);
    };
    scan_bot_receipt(state, message, &runtime).await
}

async fn prepare_bot_receipt_runtime(
    state: &AppState,
    message: &wonder_store::StoredMessage,
) -> Result<Option<wonder_app_server::RpcClient>, String> {
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
    Ok(Some(runtime))
}

async fn scan_bot_receipt(
    state: &AppState,
    message: &wonder_store::StoredMessage,
    runtime: &wonder_app_server::RpcClient,
) -> Result<Option<String>, String> {
    let mut scan = BotReceiptScan::new(message);
    scan_bot_receipt_pages(
        state,
        message,
        runtime,
        &mut scan,
        RECEIPT_HISTORY_PAGE_LIMIT,
    )
    .await
}

async fn scan_bot_receipt_pages(
    state: &AppState,
    message: &wonder_store::StoredMessage,
    runtime: &wonder_app_server::RpcClient,
    scan: &mut BotReceiptScan,
    budget: usize,
) -> Result<Option<String>, String> {
    let Some(thread_id) = message.codex_thread_id.as_deref() else {
        return Ok(None);
    };
    for _ in 0..budget.min(RECEIPT_HISTORY_PAGE_LIMIT.saturating_sub(scan.pages_scanned)) {
        if state.update_admission.work_paused() {
            return Ok(None);
        }
        let mut params = json!({"threadId":thread_id,"limit":100,"sortDirection":"desc"});
        if let Some(value) = scan.cursor.as_deref() {
            params["cursor"] = json!(value);
        }
        let response = runtime
            .request("thread/items/list", params)
            .await
            .map_err(|e| e.to_string())?;
        if response.error.is_some() {
            scan.reset_after(RECEIPT_RESCAN_DELAY);
            return Ok(None);
        }
        let Some(result) = response.result else {
            scan.reset_after(RECEIPT_RESCAN_DELAY);
            return Ok(None);
        };
        if let Some(turn_id) = crate::find_client_message(&result, &message.client_message_id) {
            return Ok(Some(turn_id));
        }
        scan.pages_scanned += 1;
        scan.cursor = result
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(str::to_owned);
        if scan
            .cursor
            .as_ref()
            .is_some_and(|value| !scan.seen.insert(value.clone()))
        {
            return Err("History repeated a continuation cursor".into());
        }
        if scan.cursor.is_none() {
            scan.reset_after(RECEIPT_RESCAN_DELAY);
            return Ok(None);
        }
    }
    if scan.pages_scanned >= RECEIPT_HISTORY_PAGE_LIMIT {
        scan.reset_after(RECEIPT_RESCAN_DELAY);
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

    #[tokio::test]
    async fn held_bot_receipt_read_allows_update_without_publishing_stale_state() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let message = enqueue(&state, "held-receipt", true).await;
        assert!(state
            .store
            .claim_message_for_dispatch(&message.id)
            .await
            .unwrap());
        state
            .store
            .begin_dispatch_submission(&message.id, "thread")
            .await
            .unwrap();
        state
            .store
            .bind_runtime(
                &message.conversation_id,
                wonder_store::AgentFamily::Codex,
                "thread",
                None,
                "now",
            )
            .await
            .unwrap();
        state.store.recover_dispatch_claims().await.unwrap();
        std::fs::write(
            dir.path().join("accepted-client"),
            &message.client_message_id,
        )
        .unwrap();
        std::fs::write(dir.path().join("delay-history"), "").unwrap();
        let _ingestion = crate::ingestion::spawn(state.clone()).await;
        tokio::time::timeout(Duration::from_secs(10), async {
            while !state.ingestion.readiness(&state.store).await.ready {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let dispatcher = spawn(state.clone()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            while !dir.path().join("history-waiting").exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap_or_else(|error| {
            let requests = std::fs::read_to_string(dir.path().join("requests-jsonl"));
            let logs = std::fs::read_to_string(dir.path().join("logs/test.jsonl"));
            panic!("{error}: requests {requests:?}; logs {logs:?}");
        });
        let update_state = state.clone();
        let preparing = tokio::spawn(async move {
            update_state
                .update_admission
                .prepare_update("held-bot-receipt", &update_state)
                .await
        });
        let admitted = tokio::time::timeout(Duration::from_secs(1), async {
            while !state.update_admission.work_paused() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await;
        std::fs::remove_file(dir.path().join("delay-history")).unwrap();
        if admitted.is_err() {
            preparing.abort();
            dispatcher.abort();
            panic!("Bot history blocked update admission");
        }
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(3), preparing)
                .await
                .unwrap()
                .unwrap(),
            Ok(())
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
        let saved = state
            .store
            .message_by_id(&message.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(saved.state, "uncertain");
        assert!(
            state
                .update_admission
                .cancel_lease("held-bot-receipt")
                .await
        );
        dispatcher.abort();
        let _ = dispatcher.await;
        recover_bot_receipts(&state, &Arc::default()).await.unwrap();
        let saved = state
            .store
            .message_by_id(&message.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(saved.state, "accepted_by_codex");
        assert_eq!(saved.codex_turn_id.as_deref(), Some("turn"));
        let requests = std::fs::read_to_string(dir.path().join("requests")).unwrap();
        assert!(!requests.lines().any(|method| method == "turn/start"));
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn absent_bot_receipt_backs_off_without_resending() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let message = enqueue(&state, "absent-receipt", true).await;
        assert!(state
            .store
            .claim_message_for_dispatch(&message.id)
            .await
            .unwrap());
        state
            .store
            .begin_dispatch_submission(&message.id, "thread")
            .await
            .unwrap();
        state
            .store
            .bind_runtime(
                &message.conversation_id,
                wonder_store::AgentFamily::Codex,
                "thread",
                None,
                "now",
            )
            .await
            .unwrap();
        state.store.recover_dispatch_claims().await.unwrap();
        let _ingestion = crate::ingestion::spawn(state.clone()).await;
        tokio::time::timeout(Duration::from_secs(3), async {
            while !state.ingestion.readiness(&state.store).await.ready {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let scans: ReceiptScans = Arc::default();
        recover_bot_receipts(&state, &scans).await.unwrap();
        recover_bot_receipts(&state, &scans).await.unwrap();
        let requests = std::fs::read_to_string(dir.path().join("requests-jsonl")).unwrap();
        assert_eq!(
            requests
                .lines()
                .filter(
                    |line| serde_json::from_str::<Value>(line).unwrap()["method"]
                        == "thread/items/list"
                )
                .count(),
            1
        );
        assert!(requests.lines().any(|line| {
            let request = serde_json::from_str::<Value>(line).unwrap();
            request["method"] == "thread/items/list" && request["params"]["sortDirection"] == "desc"
        }));
        assert!(requests.lines().all(|line| {
            serde_json::from_str::<Value>(line).unwrap()["method"] != "turn/start"
        }));
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
        std::fs::write(
            dir.path().join("accepted-client"),
            &message.client_message_id,
        )
        .unwrap();
        scans
            .lock()
            .unwrap()
            .get_mut(&message.id)
            .unwrap()
            .resume_after = Instant::now();
        recover_bot_receipts(&state, &scans).await.unwrap();
        let saved = state
            .store
            .message_by_id(&message.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(saved.state, "accepted_by_codex");
        assert_eq!(saved.codex_turn_id.as_deref(), Some("turn"));
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn long_bot_receipt_yields_to_later_receipt_and_resumes_its_cursor() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let old = enqueue(&state, "old-receipt", true).await;
        let MessageInsert::Inserted(newer) = state
            .store
            .insert_dispatch_message(
                "owner",
                "new-receipt",
                "hello",
                "hash",
                "automation:bot",
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!("insert")
        };
        for (message, thread) in [(&old, "thread"), (&newer, "new-thread")] {
            assert!(state
                .store
                .claim_message_for_dispatch(&message.id)
                .await
                .unwrap());
            state
                .store
                .begin_dispatch_submission(&message.id, thread)
                .await
                .unwrap();
            state
                .store
                .bind_runtime(
                    &message.conversation_id,
                    wonder_store::AgentFamily::Codex,
                    thread,
                    None,
                    "now",
                )
                .await
                .unwrap();
        }
        state.store.recover_dispatch_claims().await.unwrap();
        let pool = sqlx::SqlitePool::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        for (message, when) in [(&old, "2000-01-01"), (&newer, "2000-01-02")] {
            sqlx::query("UPDATE messages SET created_at=? WHERE id=?")
                .bind(when)
                .bind(&message.id)
                .execute(&pool)
                .await
                .unwrap();
        }
        std::fs::write(dir.path().join("long-history"), "").unwrap();
        std::fs::write(dir.path().join("accepted-client"), &newer.client_message_id).unwrap();
        let script_path = dir.path().join("runtime.py");
        let script = std::fs::read_to_string(&script_path).unwrap();
        let marker = "elif method == 'thread/items/list':\n        if os.path.exists(root + '/long-history'):";
        let position = script.rfind(marker).unwrap();
        let mut script = script;
        script.replace_range(
            position..position + marker.len(),
            "elif method == 'thread/items/list':\n        if os.path.exists(root + '/long-history') and r.get('params',{}).get('threadId') == 'thread':",
        );
        std::fs::write(&script_path, script).unwrap();
        state
            .app_server
            .lock()
            .await
            .restart(state.launch_config.lock().await.clone())
            .await
            .unwrap();
        let _ingestion = crate::ingestion::spawn(state.clone()).await;
        tokio::time::timeout(Duration::from_secs(3), async {
            while !state.ingestion.readiness(&state.store).await.ready {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let scans: ReceiptScans = Arc::default();
        recover_bot_receipts(&state, &scans).await.unwrap();
        assert_eq!(scans.lock().unwrap()[&old.id].pages_scanned, 20);
        assert_eq!(scans.lock().unwrap()[&old.id].cursor.as_deref(), Some("20"));
        assert_eq!(
            state
                .store
                .message_by_id(&old.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "uncertain"
        );
        assert_eq!(
            state
                .store
                .message_by_id(&newer.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "accepted_by_codex"
        );
        tokio::time::timeout(Duration::from_secs(3), async {
            while !message_ready(&state, &old).await {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        recover_bot_receipts(&state, &scans).await.unwrap();
        assert_eq!(scans.lock().unwrap()[&old.id].pages_scanned, 40);
        assert_eq!(scans.lock().unwrap()[&old.id].cursor.as_deref(), Some("40"));
        let requests = std::fs::read_to_string(dir.path().join("requests-jsonl")).unwrap();
        assert!(requests.lines().any(|line| {
            let request: Value = serde_json::from_str(line).unwrap();
            request["method"] == "thread/items/list"
                && request["params"]["threadId"] == "thread"
                && request["params"]["cursor"] == "20"
        }));
        assert!(!requests.lines().any(|line| {
            serde_json::from_str::<Value>(line).unwrap()["method"] == "turn/start"
        }));
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
