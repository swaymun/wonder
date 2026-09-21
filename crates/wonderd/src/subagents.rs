//! Verified runtime discovery and routing for genuine subagent threads.
//!
//! A child is trusted only when the runtime's Thread metadata says it was
//! spawned from the exact parent thread. Activity items are useful UI hints,
//! but they are never an ownership authority.

use crate::{bot_for_conversation, AppState};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use wonder_app_server::RpcClient;
use wonder_store::{Store, StoredBot, StoredSubagentOwnership};

const MAX_PARENT_DEPTH: usize = 16;
const MAX_DISCOVERED_CHILDREN: usize = 100;

#[derive(Clone)]
pub(crate) struct ChildRuntime {
    pub ownership: StoredSubagentOwnership,
    pub thread: Value,
    pub rpc: RpcClient,
}

#[derive(Clone, Debug)]
struct VerifiedThread {
    child_thread_id: String,
    parent_thread_id: String,
    agent_nickname: Option<String>,
    agent_role: Option<String>,
    agent_path: Option<String>,
    source: Value,
    status: String,
    can_accept_direct_input: Option<bool>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SubagentSummary {
    conversation_id: String,
    thread_id: String,
    parent_conversation_id: String,
    parent_thread_id: String,
    title: String,
    agent_nickname: Option<String>,
    agent_role: Option<String>,
    agent_path: Option<String>,
    status: String,
    can_accept_direct_input: Option<bool>,
    is_archived: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SubagentListResponse {
    available: bool,
    detail: Option<String>,
    subagents: Vec<SubagentSummary>,
}

/// User-facing writes must never resume or steer runtime-owned descendants.
/// Ownership is durable, so the policy also holds while the runtime is offline.
pub(crate) async fn reject_user_mutation(state: &AppState, conversation: &str) -> Option<Response> {
    match state
        .store
        .subagent_ownership_for_conversation(conversation)
        .await
    {
        Ok(Some(_)) => Some(
            (
                StatusCode::FORBIDDEN,
                Json(json!({
                    "error": "subagent_read_only",
                    "detail": "Agent tasks are read-only. Continue in the parent conversation."
                })),
            )
                .into_response(),
        ),
        Ok(None) => None,
        Err(_) => Some(StatusCode::SERVICE_UNAVAILABLE.into_response()),
    }
}

fn string_field(value: &Value, camel: &str, snake: &str) -> Option<String> {
    value
        .get(camel)
        .or_else(|| value.get(snake))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn verified_thread(parent_thread_id: &str, thread: &Value) -> Result<VerifiedThread, String> {
    let child_thread_id = string_field(thread, "id", "id")
        .ok_or_else(|| "Runtime returned a child thread without an id".to_owned())?;
    let declared_parent = string_field(thread, "parentThreadId", "parent_thread_id")
        .ok_or_else(|| "Runtime child thread did not declare a parent".to_owned())?;
    if declared_parent != parent_thread_id || child_thread_id == parent_thread_id {
        return Err("Runtime child thread parent does not match the requested parent".into());
    }
    let source = thread
        .get("source")
        .filter(|source| source.is_object())
        .ok_or_else(|| "Runtime child thread has no structured spawn source".to_owned())?;
    let spawn = source
        .get("subAgent")
        .and_then(|value| value.get("thread_spawn"))
        .filter(|spawn| spawn.is_object())
        .ok_or_else(|| "Runtime child thread is not a thread_spawn descendant".to_owned())?;
    let source_parent = string_field(spawn, "parent_thread_id", "parent_thread_id")
        .ok_or_else(|| "Runtime spawn source did not declare parent_thread_id".to_owned())?;
    let depth = spawn
        .get("depth")
        .and_then(Value::as_u64)
        .ok_or_else(|| "Runtime spawn source did not declare depth".to_owned())?;
    if source_parent != parent_thread_id || depth == 0 || depth as usize > MAX_PARENT_DEPTH {
        return Err("Runtime spawn source failed parent/depth verification".into());
    }
    let status = thread
        .get("status")
        .and_then(|status| status.get("type"))
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_owned();
    let can_accept_direct_input = thread
        .get("canAcceptDirectInput")
        .or_else(|| thread.get("can_accept_direct_input"))
        .and_then(Value::as_bool);
    Ok(VerifiedThread {
        child_thread_id,
        parent_thread_id: declared_parent,
        agent_nickname: string_field(spawn, "agent_nickname", "agent_nickname"),
        agent_role: string_field(spawn, "agent_role", "agent_role"),
        agent_path: string_field(spawn, "agent_path", "agent_path"),
        source: source.clone(),
        status,
        can_accept_direct_input,
    })
}

// Thread.idle describes execution, not whether the agent finished its last
// assignment. Read one turn of metadata, without loading transcript items or
// resuming the thread, to distinguish terminal work from a waiting agent.
fn lifecycle_status(thread: &Value, last_turn: Option<&str>) -> String {
    let status = thread
        .pointer("/status/type")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    if status == "active" {
        for waiting in ["waitingOnApproval", "waitingOnUserInput"] {
            if thread
                .pointer("/status/activeFlags")
                .and_then(Value::as_array)
                .is_some_and(|flags| flags.iter().any(|flag| flag.as_str() == Some(waiting)))
            {
                return waiting.into();
            }
        }
        return "active".into();
    }
    if status == "systemError" {
        return "failed".into();
    }
    if matches!(status, "idle" | "notLoaded") {
        if let Some(terminal @ ("completed" | "failed" | "interrupted")) = last_turn {
            return terminal.into();
        }
    }
    status.into()
}
async fn with_lifecycle_status(mut thread: Value, rpc: &RpcClient) -> Value {
    let mut latest = None;
    if matches!(
        thread.pointer("/status/type").and_then(Value::as_str),
        Some("idle" | "notLoaded")
    ) {
        let result = tokio::time::timeout(std::time::Duration::from_secs(2), rpc.request("thread/turns/list", json!({
            "threadId": thread["id"], "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"
        }))).await;
        match result {
            Ok(Ok(response)) if response.error.is_none() => {
                latest = response
                    .result
                    .as_ref()
                    .and_then(|v| v.pointer("/data/0/status"))
                    .and_then(Value::as_str)
                    .map(str::to_owned);
            }
            _ => {
                thread["status"] = json!({"type":"unknown"});
            }
        }
    }
    let status = lifecycle_status(&thread, latest.as_deref());
    thread["status"]["type"] = Value::String(status);
    thread
}

fn child_conversation_id(parent_conversation_id: &str, child_thread_id: &str) -> String {
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(
        &Sha256::digest(
            format!("wonder-subagent-conversation:{parent_conversation_id}:{child_thread_id}")
                .as_bytes(),
        )[..16],
    );
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    uuid::Uuid::from_bytes(bytes).to_string()
}

async fn parent_bot(state: &AppState, conversation_id: &str) -> Result<StoredBot, String> {
    bot_for_conversation(state, conversation_id)
        .await
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "The parent Bot for this subagent is unavailable".to_owned())
}

async fn verify_parent_chain(
    store: &Store,
    parent_conversation_id: &str,
    parent_thread_id: &str,
) -> Result<(), String> {
    let mut conversation_id = parent_conversation_id.to_owned();
    let mut thread_id = parent_thread_id.to_owned();
    let mut seen = std::collections::HashSet::new();
    for _ in 0..MAX_PARENT_DEPTH {
        if !seen.insert(thread_id.clone()) {
            return Err("Subagent parent chain contains a cycle".into());
        }
        if store
            .conversation_thread(&conversation_id)
            .await
            .map_err(|e| e.to_string())?
            .as_deref()
            != Some(thread_id.as_str())
        {
            return Err("Subagent parent thread is not owned by the claimed conversation".into());
        }
        let Some(parent) = store
            .subagent_ownership_for_conversation(&conversation_id)
            .await
            .map_err(|e| e.to_string())?
        else {
            return Ok(());
        };
        if parent.thread_id != thread_id {
            return Err("Subagent ownership thread is inconsistent".into());
        }
        conversation_id = parent.parent_conversation_id;
        thread_id = parent.parent_thread_id;
    }
    Err("Subagent parent chain exceeded the verification limit".into())
}

/// Register one runtime Thread object after verifying its canonical source.
pub(crate) async fn register_from_thread(
    state: &AppState,
    parent_thread_id: &str,
    parent_conversation_id: &str,
    thread: &Value,
    runtime_id: &str,
) -> Result<StoredSubagentOwnership, String> {
    register_from_thread_with_archive(
        state,
        parent_thread_id,
        parent_conversation_id,
        thread,
        runtime_id,
        None,
    )
    .await
}

async fn register_from_thread_with_archive(
    state: &AppState,
    parent_thread_id: &str,
    parent_conversation_id: &str,
    thread: &Value,
    runtime_id: &str,
    is_archived: Option<bool>,
) -> Result<StoredSubagentOwnership, String> {
    let verified = verified_thread(parent_thread_id, thread)?;
    verify_parent_chain(&state.store, parent_conversation_id, parent_thread_id).await?;
    let bot = parent_bot(state, parent_conversation_id).await?;
    let conversation_id = child_conversation_id(parent_conversation_id, &verified.child_thread_id);
    let title = verified
        .agent_nickname
        .as_deref()
        .or(verified.agent_role.as_deref())
        .unwrap_or("Subagent");
    state
        .store
        .register_subagent_ownership(
            &conversation_id,
            parent_conversation_id,
            &verified.child_thread_id,
            &verified.parent_thread_id,
            &bot.id,
            title,
            verified.agent_nickname.as_deref(),
            verified.agent_role.as_deref(),
            verified.agent_path.as_deref(),
            &verified.source.to_string(),
            Some(runtime_id),
            verified.can_accept_direct_input,
            &verified.status,
            is_archived,
            &state.started_at,
        )
        .await
        .map_err(|error| error.to_string())
}

async fn read_thread(
    route: &crate::ingestion::RuntimeRoute,
    thread_id: &str,
) -> Result<Value, String> {
    let rpc = route.rpc().await?;
    let response = rpc
        .request(
            "thread/read",
            json!({"threadId": thread_id, "includeTurns": false}),
        )
        .await
        .map_err(|error| error.to_string())?;
    if response.error.is_some() {
        return Err("Runtime could not read the verified child thread".into());
    }
    let thread = response
        .result
        .and_then(|result| result.get("thread").cloned().or(Some(result)))
        .ok_or_else(|| "Runtime returned no thread metadata".to_owned())?;
    if string_field(&thread, "id", "id").as_deref() != Some(thread_id) {
        return Err("Runtime returned metadata for a different thread".to_owned());
    }
    Ok(with_lifecycle_status(thread, &rpc).await)
}

async fn route_matches_parent(
    state: &AppState,
    route: &crate::ingestion::RuntimeRoute,
    parent_conversation_id: &str,
    parent_thread_id: &str,
) -> Result<bool, String> {
    if state
        .store
        .conversation_thread(parent_conversation_id)
        .await
        .map_err(|error| error.to_string())?
        .as_deref()
        != Some(parent_thread_id)
    {
        return Ok(false);
    }
    if let Some(message_id) = route.message_id.as_deref() {
        return Ok(state
            .store
            .message_by_id(message_id)
            .await
            .map_err(|error| error.to_string())?
            .is_some_and(|message| message.conversation_id == parent_conversation_id));
    }
    let health = state.app_server.lock().await.health();
    Ok(health.is_alive() && health.id() == route.runtime_id)
}

fn child_seed_ids(params: &Value) -> Vec<String> {
    let Some(item) = params.get("item") else {
        return Vec::new();
    };
    let item_type = item.get("type").and_then(Value::as_str);
    if !matches!(item_type, Some("subAgentActivity" | "collabAgentToolCall")) {
        return Vec::new();
    }
    let payload = item.get("payload").filter(|value| value.is_object());
    let values = [item, payload.unwrap_or(&Value::Null)];
    values
        .into_iter()
        .flat_map(|value| {
            value
                .get("agentThreadId")
                .and_then(Value::as_str)
                .into_iter()
                .chain(
                    value
                        .get("receiverThreadIds")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(Value::as_str),
                )
        })
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .take(16)
        .collect()
}

/// Discover an unregistered child notification or re-verify an existing one.
pub(crate) async fn observe(
    state: &AppState,
    notification: &Value,
) -> Result<Option<StoredSubagentOwnership>, String> {
    let params = notification.get("params").unwrap_or(notification);
    let Some(thread_id) = params.get("threadId").and_then(Value::as_str).or_else(|| {
        params
            .get("item")
            .and_then(|item| item.get("threadId"))
            .and_then(Value::as_str)
    }) else {
        return Ok(None);
    };
    let origin_runtime_id = notification
        .get("_wonderRuntimeId")
        .and_then(Value::as_str)
        .or_else(|| params.get("_wonderRuntimeId").and_then(Value::as_str));
    if let Some(existing) = state
        .store
        .subagent_ownership_for_thread(thread_id)
        .await
        .map_err(|e| e.to_string())?
    {
        let origin_runtime_id = origin_runtime_id
            .ok_or_else(|| "Child notification has no runtime origin".to_owned())?;
        if existing.runtime_id.as_deref() != Some(origin_runtime_id) {
            return Err("Child notification came from an unrelated runtime".into());
        }
        let route = state
            .ingestion
            .runtime_route(origin_runtime_id)
            .ok_or_else(|| "Child runtime is no longer available".to_owned())?;
        verify_parent_chain(
            &state.store,
            &existing.parent_conversation_id,
            &existing.parent_thread_id,
        )
        .await?;
        if !route_matches_parent(
            state,
            &route,
            &existing.parent_conversation_id,
            &existing.parent_thread_id,
        )
        .await?
        {
            return Err("Child runtime is not attached to its parent conversation".to_owned());
        }
        return Ok(Some(existing));
    }
    let seeds = child_seed_ids(params);
    let has_child_seed = !seeds.is_empty();
    // Historical and ordinary notifications often have a thread id but no
    // Wonder runtime provenance. They are not an ownership signal. Existing
    // owned children were handled above so a missing origin remains an error
    // for those verified children, while unknown/unmapped ordinary events are
    // safely ignored.
    if !has_child_seed && origin_runtime_id.is_none() {
        return Ok(None);
    }
    if !has_child_seed
        && state
            .store
            .conversation_for_thread(thread_id)
            .await
            .map_err(|e| e.to_string())?
            .is_some()
    {
        return Ok(None);
    }
    let origin_runtime_id =
        origin_runtime_id.ok_or_else(|| "Child notification has no runtime origin".to_owned())?;
    let route = state
        .ingestion
        .runtime_route(origin_runtime_id)
        .ok_or_else(|| "Child runtime is no longer available".to_owned())?;

    // Activity payloads only seed verification. A parent envelope remains a
    // parent envelope even when it mentions child thread ids; register those
    // children as a side effect but never return one as this notification's
    // ownership.
    if !seeds.is_empty() {
        let Some(parent_conversation_id) = state
            .store
            .conversation_for_thread(thread_id)
            .await
            .map_err(|e| e.to_string())?
        else {
            return Ok(None);
        };
        if !route_matches_parent(state, &route, &parent_conversation_id, thread_id).await? {
            return Err("Parent activity runtime is not attached to its conversation".into());
        }
        for child_thread_id in seeds {
            if child_thread_id == thread_id {
                continue;
            }
            if let Ok(child_thread) = read_thread(&route, &child_thread_id).await {
                let _ = register_from_thread(
                    state,
                    thread_id,
                    &parent_conversation_id,
                    &child_thread,
                    origin_runtime_id,
                )
                .await;
            }
        }
        return Ok(None);
    }
    let thread = read_thread(&route, thread_id).await?;
    // A thread/read response is not by itself evidence of a subagent. Do not
    // reject replayed ordinary threads merely because this observer saw them;
    // canonical parent/source verification is required before child routing.
    let Some(declared_parent_thread_id) =
        string_field(&thread, "parentThreadId", "parent_thread_id")
    else {
        return Ok(None);
    };
    let has_thread_spawn_source = thread
        .get("source")
        .and_then(|source| source.get("subAgent"))
        .and_then(|sub_agent| sub_agent.get("thread_spawn"))
        .is_some_and(Value::is_object);
    if !has_thread_spawn_source {
        return Ok(None);
    }
    let parent_thread_id = declared_parent_thread_id;
    let parent_conversation_id = state
        .store
        .conversation_for_thread(&parent_thread_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Unregistered child parent is not a Wonder conversation".to_owned())?;
    if !route_matches_parent(state, &route, &parent_conversation_id, &parent_thread_id).await? {
        return Err("Unregistered child runtime is not attached to its parent conversation".into());
    }
    register_from_thread(
        state,
        &parent_thread_id,
        &parent_conversation_id,
        &thread,
        origin_runtime_id,
    )
    .await
    .map(Some)
}

/// Resolve a verified child conversation to a live, generation-bound RPC
/// client. A dead runtime may be replaced only after exact thread/read proof.
pub(crate) async fn runtime_for_conversation(
    state: &AppState,
    conversation_id: &str,
) -> Result<Option<ChildRuntime>, String> {
    let Some(ownership) = state
        .store
        .subagent_ownership_for_conversation(conversation_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };
    let parent_conversation_id = ownership.parent_conversation_id.clone();
    let parent_thread_id = ownership.parent_thread_id.clone();
    let routes = state.ingestion.runtime_routes();
    if let Some(route) = routes
        .iter()
        .find(|route| ownership.runtime_id.as_deref() == Some(route.runtime_id.as_str()))
    {
        // A live generation remains authoritative. Never silently retarget a
        // live child to another runtime after an unrelated read failure.
        let thread = read_thread(route, &ownership.thread_id).await?;
        let refreshed = register_from_thread(
            state,
            &parent_thread_id,
            &parent_conversation_id,
            &thread,
            &route.runtime_id,
        )
        .await?;
        let rpc = route.rpc().await?;
        return Ok(Some(ChildRuntime {
            ownership: refreshed,
            thread,
            rpc,
        }));
    }
    // The captured runtime is no longer live. A fallback is allowed only when
    // the candidate is attached to the exact parent conversation and proves
    // the exact child Thread metadata again.
    for route in routes {
        if !route_matches_parent(state, &route, &parent_conversation_id, &parent_thread_id).await? {
            continue;
        }
        let Ok(thread) = read_thread(&route, &ownership.thread_id).await else {
            continue;
        };
        let Ok(refreshed) = register_from_thread(
            state,
            &parent_thread_id,
            &parent_conversation_id,
            &thread,
            &route.runtime_id,
        )
        .await
        else {
            continue;
        };
        let rpc = route.rpc().await?;
        return Ok(Some(ChildRuntime {
            ownership: refreshed,
            thread,
            rpc,
        }));
    }
    Err(
        "This child conversation is unavailable on the current host. Reopen the parent to retry."
            .into(),
    )
}

async fn list_runtime_threads(
    state: &AppState,
    parent_conversation_id: &str,
    parent_thread_id: &str,
) -> Result<Vec<ChildRuntime>, String> {
    let routes = state.ingestion.runtime_routes();
    for route in routes {
        if !route_matches_parent(state, &route, parent_conversation_id, parent_thread_id).await? {
            continue;
        }
        let rpc = route.rpc().await?;
        let mut children = Vec::new();
        for archived in [false, true] {
            let response = rpc
                .request(
                    "thread/list",
                    json!({"sourceKinds":["subAgentThreadSpawn"],"parentThreadId":parent_thread_id,"archived":archived,"limit":MAX_DISCOVERED_CHILDREN}),
                )
                .await
                .map_err(|error| error.to_string())?;
            if response.error.is_some() {
                continue;
            }
            let Some(result) = response.result else {
                continue;
            };
            let threads = result
                .get("data")
                .or_else(|| result.get("threads"))
                .and_then(Value::as_array)
                .ok_or_else(|| "Runtime returned an invalid thread/list response".to_owned())?;
            // Verify identity before issuing any extra read; at most four
            // status requests are in flight for this bounded roster.
            let verified: Vec<Value> = threads
                .iter()
                .take(MAX_DISCOVERED_CHILDREN)
                .filter(|thread| verified_thread(parent_thread_id, thread).is_ok())
                .cloned()
                .collect();
            let mut refreshes = tokio::task::JoinSet::new();
            let mut refreshed = Vec::new();
            for thread in verified {
                let rpc = rpc.clone();
                refreshes.spawn(async move { with_lifecycle_status(thread, &rpc).await });
                if refreshes.len() >= 4 {
                    if let Some(Ok(thread)) = refreshes.join_next().await {
                        refreshed.push(thread);
                    }
                }
            }
            while let Some(Ok(thread)) = refreshes.join_next().await {
                refreshed.push(thread);
            }
            for thread in &refreshed {
                if children.len() >= MAX_DISCOVERED_CHILDREN {
                    break;
                }
                let Ok(ownership) = register_from_thread_with_archive(
                    state,
                    parent_thread_id,
                    parent_conversation_id,
                    thread,
                    &route.runtime_id,
                    Some(archived),
                )
                .await
                else {
                    continue;
                };
                if !children.iter().any(|child: &ChildRuntime| {
                    child.ownership.conversation_id == ownership.conversation_id
                }) {
                    children.push(ChildRuntime {
                        ownership,
                        thread: thread.clone(),
                        rpc: rpc.clone(),
                    });
                }
            }
        }
        return Ok(children);
    }
    Err("Subagent discovery is unavailable on this host. Update the host and try again.".into())
}

pub(crate) async fn list(
    State(state): State<AppState>,
    Path(parent_conversation_id): Path<String>,
) -> Response {
    if parent_bot(&state, &parent_conversation_id).await.is_err() {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Some(parent_thread_id) = state
        .store
        .conversation_thread(&parent_conversation_id)
        .await
        .ok()
        .flatten()
    else {
        return Json(SubagentListResponse {
            available: true,
            detail: None,
            subagents: Vec::new(),
        })
        .into_response();
    };
    let discovery = tokio::time::timeout(
        std::time::Duration::from_secs(8),
        list_runtime_threads(&state, &parent_conversation_id, &parent_thread_id),
    )
    .await
    .unwrap_or_else(|_| Err("Agent status refresh timed out. Showing last known tasks.".into()));
    // Discovery refreshes durable ownership. Retain finished descendants even
    // when the runtime omits archived threads or is no longer available.
    let mut pending = std::collections::VecDeque::from([parent_conversation_id]);
    let mut seen = std::collections::HashSet::new();
    let mut children = Vec::new();
    while let Some(parent) = pending.pop_front() {
        let retained = match state.store.list_subagent_ownership(&parent).await {
            Ok(children) => children,
            Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
        };
        for ownership in retained {
            if children.len() >= MAX_DISCOVERED_CHILDREN {
                break;
            }
            if !seen.insert(ownership.conversation_id.clone()) {
                continue;
            }
            pending.push_back(ownership.conversation_id.clone());
            children.push(SubagentSummary {
                title: ownership
                    .agent_nickname
                    .clone()
                    .or_else(|| ownership.agent_role.clone())
                    .unwrap_or_else(|| "Agent".into()),
                conversation_id: ownership.conversation_id,
                thread_id: ownership.thread_id,
                parent_conversation_id: ownership.parent_conversation_id,
                parent_thread_id: ownership.parent_thread_id,
                agent_nickname: ownership.agent_nickname,
                agent_role: ownership.agent_role,
                agent_path: ownership.agent_path,
                status: ownership.status,
                can_accept_direct_input: Some(false),
                is_archived: ownership.is_archived,
            });
        }
        if children.len() >= MAX_DISCOVERED_CHILDREN {
            break;
        }
    }
    Json(SubagentListResponse {
        available: discovery.is_ok(),
        detail: discovery.err(),
        subagents: children,
    })
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_runtime_thread_source_can_verify_a_child() {
        let thread = json!({
            "id": "child-thread",
            "parentThreadId": "parent-thread",
            "source": {"subAgent": {"thread_spawn": {
                "parent_thread_id": "parent-thread",
                "depth": 1,
                "agent_nickname": "Scout",
                "agent_role": "research"
            }}},
            "status": {"type": "idle"},
            "canAcceptDirectInput": true
        });
        let verified = verified_thread("parent-thread", &thread).unwrap();
        assert_eq!(verified.child_thread_id, "child-thread");
        assert_eq!(verified.status, "idle");
        assert_eq!(verified.can_accept_direct_input, Some(true));
        assert!(verified_thread("other", &thread).is_err());
        let mut fake = thread.clone();
        fake["source"] =
            json!({"subAgent": {"thread_spawn": {"parent_thread_id":"parent-thread","depth":1}}});
        assert!(verified_thread("parent-thread", &fake).is_ok());
        fake["source"] = json!({"thread_spawn": {"parent_thread_id":"parent-thread","depth":1}});
        assert!(verified_thread("parent-thread", &fake).is_err());
    }

    #[test]
    fn lifecycle_distinguishes_waiting_completed_failed_and_stopped() {
        for status in ["idle", "notLoaded"] {
            let thread = json!({"status":{"type":status}});
            for terminal in ["completed", "failed", "interrupted"] {
                assert_eq!(lifecycle_status(&thread, Some(terminal)), terminal);
            }
            assert_eq!(lifecycle_status(&thread, None), status);
        }
        let active = json!({"status":{"type":"active","activeFlags":[]}});
        assert_eq!(lifecycle_status(&active, Some("completed")), "active");
        for waiting in ["waitingOnApproval", "waitingOnUserInput"] {
            assert_eq!(
                lifecycle_status(
                    &json!({"status":{"type":"active","activeFlags":[waiting]}}),
                    Some("completed")
                ),
                waiting
            );
        }
        assert_eq!(
            lifecycle_status(&json!({"status":{"type":"systemError"}}), None),
            "failed"
        );
    }

    #[test]
    fn statusless_and_not_loaded_are_not_running() {
        for status in ["notLoaded", "idle", "unknown"] {
            let thread = json!({"id":"child","parentThreadId":"parent","source":{"subAgent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}},"status":{"type":status},"canAcceptDirectInput":false});
            let verified = verified_thread("parent", &thread).unwrap();
            assert_eq!(verified.status, status);
            assert_eq!(verified.can_accept_direct_input, Some(false));
        }
    }
}
