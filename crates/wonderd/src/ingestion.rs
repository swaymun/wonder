//! Durable notification projection and runtime recovery. Broadcast is only a
//! optional observer: SQLite owns every envelope before it can leave the reader.
use crate::AppState;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};
use wonder_app_server::{NotificationSink, RuntimeHealth};
use wonder_store::Store;

#[derive(Clone, Default)]
pub struct Ingestion {
    inner: Arc<Mutex<Status>>,
}

#[derive(Default)]
struct Status {
    health: Option<RuntimeHealth>,
    heartbeat: Option<Instant>,
    consumer: Option<tokio::task::AbortHandle>,
    recovering: bool,
    needs_validation: bool,
    reconcile_requested: bool,
    error: Option<String>,
    runtimes: HashMap<String, RuntimeRegistration>,
}

struct RuntimeRegistration {
    health: RuntimeHealth,
    client: Weak<tokio::sync::Mutex<wonder_app_server::AppServerClient>>,
    message_id: Option<String>,
}

/// A snapshot of an existing runtime registration, not authority for an
/// arbitrary thread. Child discovery verifies the parent binding separately.
#[derive(Clone)]
pub(crate) struct RuntimeRoute {
    pub runtime_id: String,
    pub message_id: Option<String>,
    client: Arc<tokio::sync::Mutex<wonder_app_server::AppServerClient>>,
}

impl RuntimeRoute {
    pub(crate) async fn rpc(&self) -> Result<wonder_app_server::RpcClient, String> {
        let rpc = self.client.lock().await.rpc();
        if rpc.health().id() != self.runtime_id || !rpc.health().is_alive() {
            return Err("The Bot runtime changed. Reopen the conversation and try again.".into());
        }
        Ok(rpc)
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Readiness {
    pub ready: bool,
    pub detail: &'static str,
}

impl Ingestion {
    pub(crate) fn request_reconciliation(&self) {
        let mut status = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        status.reconcile_requested = true;
        status.recovering = true;
    }

    pub fn register(
        &self,
        client: &Arc<tokio::sync::Mutex<wonder_app_server::AppServerClient>>,
        health: RuntimeHealth,
        message_id: Option<String>,
    ) {
        let mut status = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if message_id.is_none() {
            status.health = Some(health.clone());
        }
        status.runtimes.insert(
            health.id().to_owned(),
            RuntimeRegistration {
                health,
                client: Arc::downgrade(client),
                message_id,
            },
        );
    }

    fn runtime_alive(&self, id: &str) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .runtimes
            .get(id)
            .is_some_and(|r| r.health.is_alive())
    }

    pub(crate) fn runtime_accepts_message(&self, runtime_id: &str, message_id: &str) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .runtimes
            .get(runtime_id)
            .is_some_and(|r| {
                r.health.is_alive() && r.message_id.as_deref().is_none_or(|id| id == message_id)
            })
    }

    pub(crate) fn runtime_routes(&self) -> Vec<RuntimeRoute> {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .runtimes
            .iter()
            .filter(|(_, registration)| registration.health.is_alive())
            .filter_map(|(id, registration)| {
                Some(RuntimeRoute {
                    runtime_id: id.clone(),
                    message_id: registration.message_id.clone(),
                    client: registration.client.upgrade()?,
                })
            })
            .collect()
    }

    pub(crate) fn runtime_route(&self, id: &str) -> Option<RuntimeRoute> {
        self.runtime_routes()
            .into_iter()
            .find(|route| route.runtime_id == id)
    }

    pub fn approval_client(
        &self,
        params: &Value,
    ) -> Option<Arc<tokio::sync::Mutex<wonder_app_server::AppServerClient>>> {
        let id = params.get("_wonderRuntimeId")?.as_str()?;
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .runtimes
            .get(id)
            .filter(|r| r.health.is_alive())?
            .client
            .upgrade()
    }

    fn live_worker(&self, message_id: &str) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .runtimes
            .values()
            .any(|r| r.message_id.as_deref() == Some(message_id) && r.health.is_alive())
    }

    pub async fn readiness(&self, store: &Store) -> Readiness {
        let detail = {
            let status = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            if status
                .health
                .as_ref()
                .is_none_or(|health| !health.is_alive())
            {
                Some("Bots are restarting. Wonder will check existing work before you can send again. If this continues, reopen Wonder on your Mac.")
            } else if status
                .health
                .as_ref()
                .is_some_and(RuntimeHealth::storage_blocked)
                || status.error.is_some()
            {
                Some("Chat updates could not be saved. Wonder is retrying; check available disk space if this continues.")
            } else if status.runtimes.values().any(|r| {
                r.message_id.is_some() && (!r.health.is_alive() || r.health.storage_blocked())
            }) {
                Some("A Bot stopped responding. Wonder is checking its existing work.")
            } else if status
                .consumer
                .as_ref()
                .is_none_or(tokio::task::AbortHandle::is_finished)
                || status.recovering
                || status
                    .heartbeat
                    .is_none_or(|time| time.elapsed() > Duration::from_secs(5))
            {
                Some("Wonder is recovering chat updates. Please wait before sending again.")
            } else {
                None
            }
        };
        if let Some(detail) = detail {
            return Readiness {
                ready: false,
                detail,
            };
        }
        match store.notification_backlog().await {
            Ok(0..=256) => Readiness {
                ready: true,
                detail: "Ready",
            },
            Ok(_) => Readiness {
                ready: false,
                detail: "Wonder is catching up on chat updates. Please wait.",
            },
            Err(_) => Readiness {
                ready: false,
                detail:
                    "Chat storage is unavailable. Wonder is retrying; check available disk space.",
            },
        }
    }

    fn error(&self, error: Option<String>) {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).error = error;
    }
}

pub fn notification_sink(store: Store) -> NotificationSink {
    Arc::new(move |notification| {
        let store = store.clone();
        Box::pin(async move {
            store
                .enqueue_notification(&notification)
                .await
                .map_err(|e| e.to_string())
        })
    })
}

struct AbortChild(tokio::task::AbortHandle);
impl Drop for AbortChild {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub struct NotificationService {
    ingestion: Ingestion,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}
impl Drop for NotificationService {
    fn drop(&mut self) {
        self.ingestion
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .recovering = true;
        for task in &self.tasks {
            task.abort();
        }
    }
}

pub async fn spawn(state: AppState) -> NotificationService {
    let health = state.app_server.lock().await.health();
    state
        .ingestion
        .register(&state.app_server, health.clone(), None);
    {
        let mut status = state
            .ingestion
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        status.health = Some(health);
        status.recovering = true;
    }
    let projection_state = state.clone();
    let projection = tokio::spawn(async move {
        loop {
            // A separate child makes panic/cancellation observable. The durable
            // row remains until the entire projection reports success.
            let child_state = projection_state.clone();
            let mut child = tokio::spawn(async move { project_loop(child_state).await });
            {
                projection_state.ingestion.inner.lock().unwrap().consumer =
                    Some(child.abort_handle());
            }
            let _abort = AbortChild(child.abort_handle());
            let outcome = (&mut child).await;
            projection_state
                .ingestion
                .error(Some(format!("notification consumer stopped: {outcome:?}")));
            let _ = projection_state.logger.record(
                "error",
                "notification_consumer_restarting",
                json!({"outcome": format!("{outcome:?}")}),
            );
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    });
    let ingestion = state.ingestion.clone();
    let maintenance_state = state.clone();
    let recovery = tokio::spawn(async move {
        let mut needs_recovery = true;
        let mut recover_all = true;
        let mut delay = Duration::from_secs(1);
        loop {
            if std::mem::take(
                &mut state
                    .ingestion
                    .inner
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .reconcile_requested,
            ) {
                needs_recovery = true;
                recover_all = true;
            }
            let healthy = {
                let status = state
                    .ingestion
                    .inner
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                status.health.as_ref().is_some_and(RuntimeHealth::is_alive)
            };
            if !healthy {
                needs_recovery = true;
                recover_all = true;
            }
            if state
                .ingestion
                .inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .runtimes
                .values()
                .any(|r| r.message_id.is_some() && !r.health.is_alive())
            {
                needs_recovery = true;
            }
            if needs_recovery {
                state
                    .ingestion
                    .inner
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .recovering = true;
                match recover(&state, recover_all).await {
                    Ok(()) => {
                        needs_recovery = false;
                        recover_all = false;
                        state
                            .ingestion
                            .inner
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .runtimes
                            .retain(|_, runtime| runtime.health.is_alive());
                        delay = Duration::from_secs(1);
                        state
                            .ingestion
                            .inner
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .recovering = false;
                        let _ = state.logger.record(
                            "info",
                            "notification_runtime_recovered",
                            json!({}),
                        );
                    }
                    Err(error) => {
                        let _ = state.logger.record(
                            "error",
                            "notification_runtime_recovery_failed",
                            json!({"error": error}),
                        );
                        delay = (delay * 2).min(Duration::from_secs(30));
                    }
                }
            }
            tokio::time::sleep(delay).await;
        }
    });
    let maintenance = tokio::spawn(async move {
        loop {
            if let Err(error) = maintenance_state.store.prune_replay().await {
                let _ = maintenance_state.logger.record(
                    "error",
                    "replay_retention_failed",
                    json!({"error":error.to_string()}),
                );
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    });
    NotificationService {
        ingestion,
        tasks: vec![projection, recovery, maintenance],
    }
}

async fn project_loop(state: AppState) {
    loop {
        match project_next(&state).await {
            Ok(true) => {
                state
                    .ingestion
                    .inner
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .heartbeat = Some(Instant::now());
                continue;
            }
            Ok(false) => {
                let mut status = state
                    .ingestion
                    .inner
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                status.heartbeat = Some(Instant::now());
                status.error = None;
            }
            Err(error) => state.ingestion.error(Some(error)),
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

async fn project_next(state: &AppState) -> Result<bool, String> {
    let _guard = state.dispatch_lock.lock().await;
    let Some((id, mut notification)) = state
        .store
        .next_notification()
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(false);
    };
    // Unsequenced deltas still need a stable identity when replayed.
    notification["_wonderInboxId"] = json!(id);
    let params = notification.get("params").cloned().unwrap_or_default();
    let method = notification
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if state
        .store
        .notification_was_started(id)
        .await
        .map_err(|e| e.to_string())?
    {
        if let Some(key) = crate::app_server_notification_key(method, &notification, &params) {
            state
                .store
                .release_app_server_notification(&key)
                .await
                .map_err(|e| e.to_string())?;
        }
    }
    state
        .store
        .start_notification(id)
        .await
        .map_err(|e| e.to_string())?;
    if notification.get("id").is_some()
        && notification
            .get("_wonderRuntimeId")
            .and_then(Value::as_str)
            .is_some_and(|id| !state.ingestion.runtime_alive(id))
    {
        // History can recover messages, but an RPC request from a dead
        // transport is no longer actionable.
        state
            .store
            .acknowledge_notification(id)
            .await
            .map_err(|e| e.to_string())?;
        return Ok(true);
    }
    if !crate::process_app_server_notification(state, notification, false).await {
        return Err(format!("notification {id} could not be projected"));
    }
    state
        .store
        .acknowledge_notification(id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(true)
}

async fn recover(state: &AppState, recover_all: bool) -> Result<(), String> {
    // Let committed completion envelopes settle before inspecting runtime
    // history or invalidating requests belonging to a dead connection.
    while project_next(state).await? {}
    let _guard = state.dispatch_lock.lock().await;
    {
        let mut runtime = state.app_server.lock().await;
        if !runtime.health().is_alive() {
            state
                .ingestion
                .inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .needs_validation = true;
            runtime
                .restart(state.launch_config.lock().await.clone())
                .await
                .map_err(|e| e.to_string())?;
        }
        state
            .ingestion
            .register(&state.app_server, runtime.health(), None);
        let needs_validation = state
            .ingestion
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .needs_validation;
        if needs_validation {
            crate::rediscover_runtime(state, &mut runtime).await?;
            state
                .ingestion
                .inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .needs_validation = false;
        }
    }
    drop(_guard);
    // No request from a previous transport can be answered on the replacement.
    for approval in state
        .store
        .list_pending_approvals()
        .await
        .map_err(|e| e.to_string())?
    {
        let params: Value =
            serde_json::from_str(&approval.params_json).map_err(|e| e.to_string())?;
        if params
            .get("_wonderRuntimeId")
            .and_then(Value::as_str)
            .is_none_or(|id| !state.ingestion.runtime_alive(id))
        {
            state
                .store
                .resolve_approval_by_server_request_id(
                    &approval.server_request_id,
                    "app_server_lost",
                    &crate::now_ms().to_string(),
                )
                .await
                .map_err(|e| e.to_string())?;
            crate::publish_event(
                state,
                wonder_api::WonderEvent::ApprovalResolved {
                    request_id: approval.server_request_id,
                    decision: "app_server_lost".into(),
                },
            )
            .await
            .map_err(|e| e.to_string())?;
        }
    }
    let messages = state
        .store
        .active_runtime_messages()
        .await
        .map_err(|e| e.to_string())?;
    for message in messages {
        if state.ingestion.live_worker(&message.id) {
            continue;
        }
        if !recover_all
            && !state
                .ingestion
                .inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .runtimes
                .values()
                .any(|r| r.message_id.as_deref() == Some(&message.id) && !r.health.is_alive())
        {
            continue;
        }
        let Some(thread_id) = message.codex_thread_id.as_deref() else {
            continue;
        };
        let Some(turn_id) = message.codex_turn_id.as_deref() else {
            continue;
        };
        let (runtime, resumed) = if let Some(child) =
            crate::subagents::runtime_for_conversation(state, &message.conversation_id).await?
        {
            if child.ownership.thread_id != thread_id {
                return Err("The receipt does not belong to this subagent".into());
            }
            let resumed = crate::resume_child(state, &child).await?;
            (child.rpc, resumed)
        } else {
            let bot = crate::bot_for_conversation(state, &message.conversation_id)
                .await
                .map_err(|e| e.to_string())?
                .ok_or("The Bot for existing work could not be found")?;
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
                crate::project_assignments::execution_bot(state, &message.conversation_id, bot)
                    .await?;
            let bot = crate::group_collaboration::execution_bot(state, &message, bot).await?;
            crate::ensure_execution_permission_cache(state, &bot).await?;
            let resolved = crate::permission_modes::resolve(&bot);
            let runtime = state.app_server.lock().await.rpc();
            let response = runtime
            .request(
                "thread/resume",
                json!({
                    "threadId": thread_id,
                    "excludeTurns": true,
                    "cwd": bot.execution_directory(),
                    "permissions": resolved.permission_profile,
                    "runtimeWorkspaceRoots": crate::permission_modes::runtime_roots(state, &bot).await?,
                    "approvalPolicy": resolved.approval_policy,
                    "approvalsReviewer": resolved.approvals_reviewer,
                    "developerInstructions": wonder_harness::instructions(&format!("{}\n\n{}", crate::teaching::BETA_POLICY, bot.system_prompt)),
                    "config":crate::teaching::runtime_config(state, &runtime, bot.execution_directory()).await?,
                }),
            )
            .await
            .map_err(|e| e.to_string())?;
            if response.error.is_some() {
                return Err("Existing Bot work could not be reopened".into());
            }
            (
                runtime,
                response
                    .result
                    .ok_or("Existing Bot work returned no conversation")?,
            )
        };
        let thread_status = resumed
            .get("thread")
            .and_then(|t| t.get("status"))
            .and_then(|s| s.get("type"))
            .and_then(Value::as_str);
        let thread_active = match thread_status {
            Some("active") => true,
            Some("idle") => false,
            _ => return Err("The Bot could not restore its existing conversation".into()),
        };
        let mut cursor = None;
        let mut seen = std::collections::HashSet::new();
        let mut terminal = false;
        let mut in_progress = false;
        let mut complete = false;
        for _ in 0..10_000 {
            let mut params = json!({"threadId":thread_id,"limit":100,"itemsView":"notLoaded"});
            if let Some(value) = cursor.take() {
                params["cursor"] = value;
            }
            let response = runtime
                .request("thread/turns/list", params)
                .await
                .map_err(|e| e.to_string())?;
            if response.error.is_some() {
                return Err("Could not check existing Bot work".into());
            }
            let result = response.result.ok_or("Missing Bot history")?;
            let turns = result
                .get("data")
                .and_then(Value::as_array)
                .ok_or("Invalid Bot history")?;
            if turns.iter().any(|turn| {
                turn.get("id").and_then(Value::as_str).is_none()
                    || turn.get("status").and_then(Value::as_str).is_none()
            }) {
                return Err("Bot history contains an incomplete turn".into());
            }
            if result
                .get("nextCursor")
                .is_some_and(|cursor| !cursor.is_null() && !cursor.is_string())
            {
                return Err("Bot history has an invalid continuation cursor".into());
            }
            terminal |= turns.iter().any(|turn| {
                turn.get("id").and_then(Value::as_str) == Some(turn_id)
                    && turn.get("status").and_then(Value::as_str) == Some("completed")
            });
            in_progress |= turns.iter().any(|turn| {
                turn.get("id").and_then(Value::as_str) == Some(turn_id)
                    && turn.get("status").and_then(Value::as_str) == Some("inProgress")
            });
            cursor = result
                .get("nextCursor")
                .filter(|value| !value.is_null())
                .cloned();
            if cursor
                .as_ref()
                .is_some_and(|value| !seen.insert(value.to_string()))
            {
                return Err(
                    "Bot history repeated a continuation cursor; recovery will retry".into(),
                );
            }
            if cursor.is_none() {
                complete = true;
                break;
            }
        }
        if !complete {
            return Err("Bot history is incomplete; recovery will retry".into());
        }
        if in_progress && thread_active {
            continue;
        }
        let items = crate::hydrate_app_server_turn_items(state, thread_id, turn_id)
            .await
            .ok_or("Could not read existing Bot work")?;
        if !runtime.health().is_alive() {
            return Err("Bot restarted while reading history; recovery will retry".into());
        }
        for entry in items.into_iter().filter(|item| item.turn_id == turn_id) {
            if entry.item.get("type").and_then(Value::as_str) == Some("agentMessage") &&
                !crate::process_app_server_notification(state, json!({"method":"item/completed", "params":{"threadId":thread_id,"turnId":turn_id,"item":entry.item}}), false).await {
                return Err("Could not save recovered Bot messages".into());
            }
        }
        if terminal {
            if !crate::process_app_server_notification(
                state,
                json!({"method":"turn/completed","params":{"threadId":thread_id,"turnId":turn_id}}),
                false,
            )
            .await
            {
                return Err("Could not save recovered completion".into());
            }
        } else {
            state
                .store
                .mark_runtime_turn_uncertain(thread_id, turn_id)
                .await
                .map_err(|e| e.to_string())?;
            crate::publish_message_state_checked(
                state,
                &message,
                wonder_api::DeliveryState::Uncertain,
                Some(thread_id),
                Some(turn_id),
            )
            .await
            .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt};
    use wonder_app_server::{AppServerClient, LaunchConfig};

    pub(crate) async fn fixture() -> (tempfile::TempDir, AppState) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::connect(&format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        let workspace = dir.path().join("bot");
        fs::create_dir(&workspace).unwrap();
        store
            .upsert_bot(
                "bot",
                "Bot",
                "Assistant",
                "Help",
                workspace.to_str().unwrap(),
                "test",
                None,
                None,
                "now",
            )
            .await
            .unwrap();
        store
            .upsert_owner_device("owner", "Owner", "{}", "now")
            .await
            .unwrap();
        let source = r#"import json, sys, os, threading, time
root = os.path.dirname(__file__)
def child_thread():
    status = 'idle'
    if os.path.exists(root + '/child-active'): status = 'active'
    if os.path.exists(root + '/child-interrupted'): status = 'idle'
    return {'id':'child-thread','parentThreadId':'thread','source':{'subAgent':{'thread_spawn':{'parent_thread_id':'thread','depth':1,'agent_nickname':'Scout','agent_role':'research'}}},'status':{'type':status},'canAcceptDirectInput':True,'cwd':'/child/work','model':'child-model'}
for line in sys.stdin:
    r = json.loads(line)
    method = r.get('method')
    if method is None:
        with open(root + '/responses', 'a') as log: log.write(json.dumps(r) + '\n')
        continue
    if method == 'initialized': continue
    with open(root + '/requests', 'a') as log: log.write(method + '\n')
    with open(root + '/requests-jsonl', 'a') as log: log.write(json.dumps(r) + '\n')
    result = {}
    if method == 'initialize': result = {'capabilities': {'experimentalApi': True}}
    elif method == 'permissionProfile/list': result = {'data': [{'name': 'test', 'allowed': True}, {'name': ':read-only', 'allowed': True}, {'name': ':workspace', 'allowed': True}, {'name': ':danger-full-access', 'allowed': True}]}
    elif method == 'thread/start': result = {'thread':{'id':'thread'}}
    elif method == 'turn/start':
        with open(root + '/accepted-client', 'w') as saved: saved.write(r['params']['clientUserMessageId'])
        open(root + '/completed', 'w').close()
        if os.path.exists(root + '/crash-after-execution'): sys.exit(0)
        result = {'turn':{'id':'turn'}}
    elif method == 'thread/resume': result = {'thread':child_thread()} if r.get('params',{}).get('threadId') == 'child-thread' else {'thread':{'status':{'type':'idle'}}}
    elif method == 'thread/list': result = {'data':[child_thread(), {'id':'ordinary-task','parentThreadId':None,'source':'appServer','status':{'type':'idle'},'canAcceptDirectInput':True}] if os.path.exists(root + '/child-fixture') and not r.get('params',{}).get('archived',False) else [], 'nextCursor':None}
    elif method == 'turn/steer': result = {'turnId':'turn'}
    elif method == 'thread/items/list':
        if os.path.exists(root + '/long-history'):
            page = int(r.get('params',{}).get('cursor') or '0')
            result = {'data':[{'turnId':'turn' if page == 99 else 'other','item':{'id':'item-'+str(page)+'-'+str(i),'type':'agentMessage','text':'history'}} for i in range(100)],'nextCursor':str(page+1) if page < 99 else None}
            print(json.dumps({'id':r['id'],'result':result}),flush=True)
            continue
        if os.path.exists(root + '/delay-history'):
            open(root + '/history-waiting','w').close()
            def delayed(request_id):
                while os.path.exists(root + '/delay-history'): time.sleep(0.01)
                print(json.dumps({'id':request_id,'result':{'data':[], 'nextCursor':None}}),flush=True)
            threading.Thread(target=delayed,args=(r['id'],),daemon=True).start()
            continue
        result = {'data': [{'turnId':'turn','item':{'id':'item','type':'agentMessage','content':[{'text':'recovered'}]}}] if os.path.exists(root + '/completed') else [], 'nextCursor':None}
        if os.path.exists(root + '/accepted-client'):
            with open(root + '/accepted-client') as saved: client = saved.read()
            result['data'].append({'turnId':'turn','item':{'type':'userMessage','clientId':client}})
    elif method == 'thread/turns/list':
        if r.get('params',{}).get('threadId') == 'child-thread':
            child_status = 'interrupted' if os.path.exists(root + '/child-interrupted') else ('inProgress' if os.path.exists(root + '/child-active') else 'completed')
            result = {'data':[{'id':'turn','status':child_status}], 'nextCursor':None}
        else: result = {} if os.path.exists(root + '/bad-history') else {'data':[{'id':'turn','status':'completed'}] if os.path.exists(root + '/completed') else [], 'nextCursor':None}
    elif method == 'thread/read' and r.get('params',{}).get('threadId') == 'child-thread': result = {'thread':child_thread()}
    elif method == 'turn/interrupt':
        open(root + '/child-interrupted','w').close()
        result = {}
    elif method == 'thread/unarchive': result = {'thread':child_thread()}
    elif method == 'thread/read':
        mode = r.get('params', {}).get('mode')
        if mode == 'die':
            open(root + '/completed', 'w').close()
            print(json.dumps({'id':r['id'],'result':{}}), flush=True)
            sys.exit(0)
        count = r.get('params', {}).get('count', 600)
        print(json.dumps({'id':r.get('params', {}).get('approvalId', r['id']),'method':'item/commandExecution/requestApproval','params':{'threadId':'thread','turnId':'turn','itemId':'command','availableDecisions':['accept','decline']}}), flush=True)
        for i in range(count):
            print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':'thread','turnId':'turn','itemId':'item','sequence':i,'delta':{'text':'x'}}}), flush=True)
    print(json.dumps({'id':r['id'],'result':result}), flush=True)
"#;
        fs::write(dir.path().join("runtime.py"), source).unwrap();
        let schemas = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../research/codex-app-server/0.155.0-alpha.9");
        let script = format!("#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'codex-cli 0.155.0-alpha.9'; exit 0; fi\nif [ \"$2\" = generate-json-schema ]; then last=''; for arg in \"$@\"; do last=\"$arg\"; done; flavor=stable; if [ \"$3\" = --experimental ]; then flavor=experimental; fi; cp '{}/'\"$flavor\"'/codex_app_server_protocol.v2.schemas.json' \"$last/codex_app_server_protocol.v2.schemas.json\"; exit 0; fi\nexec python3 '{}'\n", schemas.display(), dir.path().join("runtime.py").display());
        // This fake server does not invoke code mode, but models its launch check.
        let helper = dir.path().join("codex-code-mode-host");
        fs::write(
            &helper,
            include_str!("../../../tests/fixtures/code-mode-host.py"),
        )
        .unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();
        let bin = dir.path().join("codex");
        fs::write(&bin, script).unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        let config = LaunchConfig {
            runtime_home: None,
            codex_bin: bin,
            wonder_version: "test".into(),
            permission_overrides: vec![],
        };
        let runtime = AppServerClient::spawn_with_notification_sink(
            config.clone(),
            notification_sink(store.clone()),
        )
        .await
        .unwrap();
        store.start_event_epoch("epoch").await.expect("sync epoch");
        let state = AppState {
            ingestion: Ingestion::default(),
            store,
            logger: Arc::new(
                crate::logging::JsonlLogger::new(dir.path().join("logs"), "test.jsonl").unwrap(),
            ),
            loopback_capability: "test".into(),
            host_epoch: "epoch".into(),
            started_at: "now".into(),
            events: tokio::sync::broadcast::channel(256).0,
            revocations: tokio::sync::broadcast::channel(64).0,
            pairing: Arc::new(tokio::sync::Mutex::new(Default::default())),
            public_origin: "https://wonder.test".into(),
            public_origin_file: None,
            host_installation_id: "test".into(),
            app_server: Arc::new(tokio::sync::Mutex::new(runtime)),
            launch_config: Arc::new(tokio::sync::Mutex::new(config)),
            denied_roots: vec![],
            linked_file_roots: vec![],
            dispatch_lock: Arc::new(tokio::sync::Mutex::new(())),
            update_admission: Arc::new(Default::default()),
            channel_worker_slots: Arc::new(tokio::sync::Semaphore::new(2)),
            approval_lock: Arc::new(tokio::sync::Mutex::new(())),
            bots_root: dir.path().to_string_lossy().into(),
            bot_home: workspace.to_string_lossy().into(),
            permission_profile: "test".into(),
            model: None,
            reasoning_effort: None,
            runtime_catalog: Arc::new(tokio::sync::RwLock::new(Default::default())),
            asr_service: Arc::new(crate::asr::AsrService::default()),
            asr_slots: Arc::new(tokio::sync::Semaphore::new(1)),
            asr_rate_limits: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            computer_use_enabled: false,
            computer_use_bin: None,
            computer_supervisor: Arc::new(
                crate::computer_sessions::ComputerSessionSupervisor::default(),
            ),
        };
        (dir, state)
    }

    async fn ready(state: &AppState) {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if state.ingestion.readiness(&state.store).await.ready
                    && state.store.next_notification().await.unwrap().is_none()
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("execution should recover");
    }

    async fn active_message(state: &AppState, turn: &str) -> wonder_store::StoredMessage {
        let inserted = state
            .store
            .insert_message("owner", turn, "hello", "hash", "bot", "now")
            .await
            .unwrap();
        let wonder_store::MessageInsert::Inserted(message) = inserted else {
            panic!("new message")
        };
        state
            .store
            .ensure_conversation_metadata("bot", "bot", "Bot", "now")
            .await
            .unwrap();
        state
            .store
            .set_conversation_thread("bot", "thread", None, "now")
            .await
            .unwrap();
        state
            .store
            .update_message_delivery(&message.id, "accepted_by_codex", Some("thread"), Some(turn))
            .await
            .unwrap();
        message
    }

    #[tokio::test]
    async fn overflow_while_projection_is_blocked_preserves_messages_and_approval() {
        let (_dir, state) = fixture().await;
        let _service = spawn(state.clone()).await;
        ready(&state).await;
        active_message(&state, "turn").await;
        let guard = state.dispatch_lock.lock().await;
        let mut observer = state.app_server.lock().await.subscribe_notifications();
        state
            .app_server
            .lock()
            .await
            .request("thread/read", json!({"mode":"burst"}))
            .await
            .unwrap();
        assert!(matches!(
            observer.recv().await,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_))
        ));
        assert!(!state.ingestion.readiness(&state.store).await.ready);
        use tower::ServiceExt;
        for (path, expected) in [("/healthz", 200), ("/readyz", 503)] {
            let response = crate::router(state.clone())
                .oneshot(
                    axum::http::Request::builder()
                        .uri(path)
                        .body(axum::body::Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status().as_u16(), expected);
        }
        let host = crate::router(state.clone())
            .oneshot(
                axum::http::Request::builder()
                    .uri("/api/v1/host/status")
                    .header("x-wonder-loopback-capability", "test")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let host: Value =
            serde_json::from_slice(&axum::body::to_bytes(host.into_body(), 65536).await.unwrap())
                .unwrap();
        crate::tests::validate_http_contract("hostStatus", &host);
        crate::tests::validate_http_contract("executionReadiness", &host["execution"]);
        assert_eq!(host["execution"]["ready"], false);
        assert_eq!(host["state"], "degraded");
        let rejected = crate::router(state.clone())
            .oneshot(
                axum::http::Request::builder()
                    .method("POST")
                    .uri("/api/v1/conversations/bot/messages")
                    .header("x-wonder-loopback-capability", "test")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(rejected.status().as_u16(), 503);
        drop(guard);
        ready(&state).await;
        let messages = state
            .store
            .assistant_messages_for_conversation("bot")
            .await
            .unwrap();
        assert_eq!(messages[0].text, "x".repeat(600));
        let approvals = state.store.list_pending_approvals().await.unwrap();
        assert_eq!(approvals.len(), 1);
        assert!(
            approvals[0].server_request_id.ends_with(":2"),
            "server request IDs may equal an outstanding client request ID"
        );
        assert!(state.store.next_notification().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn stopped_consumer_restarts_and_replays_an_interrupted_receipt() {
        let (_dir, state) = fixture().await;
        let _service = spawn(state.clone()).await;
        ready(&state).await;
        active_message(&state, "turn").await;
        let guard = state.dispatch_lock.lock().await;
        let notification = json!({"method":"item/agentMessage/delta","params":{"threadId":"thread","turnId":"turn","itemId":"item","delta":{"text":"once"}}});
        state
            .store
            .enqueue_notification(&notification)
            .await
            .unwrap();
        let (id, mut notification) = state.store.next_notification().await.unwrap().unwrap();
        notification["_wonderInboxId"] = json!(id);
        let key = crate::app_server_notification_key(
            "item/agentMessage/delta",
            &notification,
            &notification["params"],
        )
        .unwrap();
        state.store.start_notification(id).await.unwrap();
        state
            .store
            .claim_app_server_notification(&key, "now")
            .await
            .unwrap();
        state
            .store
            .upsert_assistant_delta("bot", "thread", "turn", "item", "once", &key, "now")
            .await
            .unwrap();
        state
            .ingestion
            .inner
            .lock()
            .unwrap()
            .consumer
            .as_ref()
            .unwrap()
            .abort();
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(!state.ingestion.readiness(&state.store).await.ready);
        drop(guard);
        ready(&state).await;
        assert_eq!(
            state
                .store
                .assistant_messages_for_conversation("bot")
                .await
                .unwrap()[0]
                .text,
            "once"
        );
    }

    #[tokio::test]
    async fn runtime_eof_restarts_reconciles_history_and_expires_old_approvals_without_resubmission(
    ) {
        let (dir, state) = fixture().await;
        let _service = spawn(state.clone()).await;
        ready(&state).await;
        let message = active_message(&state, "turn").await;
        let uncertain = active_message(&state, "unknown-turn").await;
        state
            .app_server
            .lock()
            .await
            .request("thread/read", json!({"mode":"burst","count":1}))
            .await
            .unwrap();
        ready(&state).await;
        let old = state.app_server.lock().await.health();
        assert_eq!(state.store.list_pending_approvals().await.unwrap().len(), 1);
        state
            .app_server
            .lock()
            .await
            .request("thread/read", json!({"mode":"die"}))
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while old.is_alive() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(!state.ingestion.readiness(&state.store).await.ready);
        ready(&state).await;
        assert_ne!(old.id(), state.app_server.lock().await.health().id());
        assert_eq!(
            state
                .store
                .message_by_id(&message.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "completed"
        );
        assert_eq!(
            state
                .store
                .message_by_id(&uncertain.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "uncertain"
        );
        assert!(!state
            .store
            .requeue_message_for_retry(&uncertain.id)
            .await
            .unwrap());
        assert_eq!(
            state
                .store
                .assistant_messages_for_conversation("bot")
                .await
                .unwrap()[0]
                .text,
            "recovered"
        );
        assert!(state
            .store
            .list_pending_approvals()
            .await
            .unwrap()
            .is_empty());
        state
            .app_server
            .lock()
            .await
            .request(
                "thread/read",
                json!({"mode":"burst","count":0,"approvalId":2}),
            )
            .await
            .unwrap();
        ready(&state).await;
        let new_approvals = state.store.list_pending_approvals().await.unwrap();
        assert_eq!(
            new_approvals.len(),
            1,
            "a reused numeric request ID belongs to a new runtime"
        );
        assert!(!new_approvals[0].server_request_id.starts_with(old.id()));
        assert!(!fs::read_to_string(dir.path().join("requests"))
            .unwrap()
            .lines()
            .any(|line| line == "turn/start"));
    }

    #[tokio::test]
    async fn fresh_service_replays_persisted_inbox_and_does_not_resurrect_dead_requests() {
        let (dir, mut state) = fixture().await;
        let message = active_message(&state, "turn").await;
        let old_id = state.app_server.lock().await.health().id().to_owned();
        state.store.enqueue_notification(&json!({"method":"item/agentMessage/delta","params":{"threadId":"thread","turnId":"turn","itemId":"item","delta":{"text":"saved before restart"}}})).await.unwrap();
        state.store.enqueue_notification(&json!({"_wonderRuntimeId":old_id,"id":42,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread","turnId":"turn"}})).await.unwrap();
        state.app_server.lock().await.shutdown().await.unwrap();
        state.store = Store::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        let _service = spawn(state.clone()).await;
        ready(&state).await;
        assert_eq!(
            state
                .store
                .assistant_messages_for_conversation("bot")
                .await
                .unwrap()[0]
                .text,
            "saved before restart"
        );
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
        assert!(state
            .store
            .list_pending_approvals()
            .await
            .unwrap()
            .is_empty());
        assert!(state.store.next_notification().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn incomplete_history_keeps_restarted_runtime_unready_until_reconciliation_succeeds() {
        let (dir, state) = fixture().await;
        let _service = spawn(state.clone()).await;
        ready(&state).await;
        active_message(&state, "turn").await;
        fs::write(dir.path().join("bad-history"), "").unwrap();
        state
            .app_server
            .lock()
            .await
            .request("thread/read", json!({"mode":"die"}))
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert!(
            state.app_server.lock().await.health().is_alive(),
            "the replacement process is live"
        );
        assert!(
            !state.ingestion.readiness(&state.store).await.ready,
            "liveness must not hide failed reconciliation"
        );
        fs::remove_file(dir.path().join("bad-history")).unwrap();
        ready(&state).await;
    }

    #[tokio::test]
    async fn storage_failure_degrades_readiness_and_reader_retries_original_envelope() {
        let (dir, state) = fixture().await;
        let _service = spawn(state.clone()).await;
        ready(&state).await;
        active_message(&state, "turn").await;
        let pool = sqlx::SqlitePool::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        sqlx::query("ALTER TABLE notification_inbox RENAME TO unavailable_inbox")
            .execute(&pool)
            .await
            .unwrap();
        let client = state.app_server.clone();
        let request = tokio::spawn(async move {
            client
                .lock()
                .await
                .request("thread/read", json!({"mode":"burst","count":1}))
                .await
        });
        tokio::time::sleep(Duration::from_millis(350)).await;
        assert!(!state.ingestion.readiness(&state.store).await.ready);
        assert!(state
            .ingestion
            .inner
            .lock()
            .unwrap()
            .health
            .as_ref()
            .unwrap()
            .storage_blocked());
        sqlx::query("ALTER TABLE unavailable_inbox RENAME TO notification_inbox")
            .execute(&pool)
            .await
            .unwrap();
        request.await.unwrap().unwrap();
        ready(&state).await;
        assert_eq!(
            state
                .store
                .assistant_messages_for_conversation("bot")
                .await
                .unwrap()[0]
                .text,
            "x"
        );
        assert_eq!(state.store.list_pending_approvals().await.unwrap().len(), 1);
    }
}
