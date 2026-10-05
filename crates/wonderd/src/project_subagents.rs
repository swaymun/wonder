//! Read-only Project helper history. Every request rechecks the owning Project
//! and the provider's exact parent/spawn source; activity item IDs are hints.

use crate::{history, projects, subagents, AppState, OwnerAuthority};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Extension, Json,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;
use wonder_app_server::RpcClient;
use wonder_store::{AgentFamily, StoredProject, StoredProjectConversation};

const MAX_CHILDREN: usize = 100;
const PAGE_SIZE: usize = 100;
const MAX_ARCHIVE_LOOKUP_PAGES: usize = 10;

struct ProjectParent {
    conversation: StoredProjectConversation,
    project: StoredProject,
    thread_id: String,
    rpc: RpcClient,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectSubagentSummary {
    parent_conversation_id: String,
    thread_id: String,
    title: String,
    agent_nickname: Option<String>,
    agent_role: Option<String>,
    status: String,
    is_archived: bool,
    can_accept_direct_input: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectSubagentList {
    available: bool,
    detail: Option<String>,
    subagents: Vec<ProjectSubagentSummary>,
    next_current_cursor: Option<String>,
    next_archived_cursor: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectSubagentTranscript {
    subagent: ProjectSubagentSummary,
    snapshot: history::ConversationSnapshot,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ListQuery {
    archived: Option<bool>,
    cursor: Option<String>,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct TranscriptQuery {
    cursor: Option<String>,
}

async fn request(rpc: &RpcClient, method: &str, params: Value) -> Result<Value, String> {
    let response = rpc
        .request(method, params)
        .await
        .map_err(|e| e.to_string())?;
    if let Some(error) = response.error {
        return Err(error.message);
    }
    response
        .result
        .ok_or_else(|| format!("{method} returned no result"))
}

fn unavailable(detail: &str) -> Response {
    (StatusCode::SERVICE_UNAVAILABLE, detail.to_owned()).into_response()
}

async fn parent(state: &AppState, conversation_id: &str) -> Result<ProjectParent, Box<Response>> {
    let conversation = state
        .store
        .project_conversation(conversation_id)
        .await
        .map_err(|_| Box::new(unavailable("The Project thread could not be checked.")))?
        .ok_or_else(|| Box::new(StatusCode::NOT_FOUND.into_response()))?;
    let project = state
        .store
        .project(&conversation.project_id)
        .await
        .map_err(|_| Box::new(unavailable("The Project could not be checked.")))?
        .ok_or_else(|| Box::new(StatusCode::NOT_FOUND.into_response()))?;
    if !project.is_included || project.root_for(&conversation.cwd).is_none() {
        return Err(Box::new(StatusCode::FORBIDDEN.into_response()));
    }
    let checked = project.clone();
    let denied = state.denied_roots.clone();
    let roots_valid =
        tokio::task::spawn_blocking(move || projects::validate_execution_roots(&checked, &denied))
            .await
            .map_err(|_| Box::new(unavailable("The Project folders could not be checked.")))?;
    if roots_valid.is_err() {
        return Err(Box::new(StatusCode::CONFLICT.into_response()));
    }
    let store = match conversation.family {
        AgentFamily::Codex => &state.projects.codex_store,
        AgentFamily::Claude => &state.projects.claude_store,
    };
    if &conversation.provider_store != store {
        return Err(Box::new(StatusCode::CONFLICT.into_response()));
    }
    let native_session = conversation.native_session_id.clone().ok_or_else(|| {
        Box::new(
            (
                StatusCode::CONFLICT,
                "This Project thread has no agent history yet.",
            )
                .into_response(),
        )
    })?;
    let binding = state
        .store
        .runtime_binding(conversation_id)
        .await
        .map_err(|_| {
            Box::new(unavailable(
                "The Project runtime identity could not be checked.",
            ))
        })?
        .ok_or_else(|| Box::new(StatusCode::CONFLICT.into_response()))?;
    if !binding_matches(conversation.family, &native_session, &binding) {
        return Err(Box::new(StatusCode::CONFLICT.into_response()));
    }
    let thread_id = binding.thread_id.clone();
    let rpc = projects::rpc_for(state, conversation.family)
        .await
        .map_err(|_| Box::new(unavailable("The agent runtime is unavailable on your Mac.")))?;
    let read = request(
        &rpc,
        "thread/read",
        json!({"threadId": thread_id, "includeTurns": false}),
    )
    .await
    .map_err(|_| Box::new(unavailable("The Project thread could not be verified.")))?;
    let thread = read.get("thread").unwrap_or(&read);
    if thread.get("id").and_then(Value::as_str) != Some(thread_id.as_str())
        || (conversation.family == AgentFamily::Claude
            && thread.get("sessionId").and_then(Value::as_str) != Some(native_session.as_str()))
        || thread.get("cwd").and_then(Value::as_str) != Some(conversation.cwd.as_str())
        || thread
            .get("parentThreadId")
            .and_then(Value::as_str)
            .is_some()
    {
        return Err(Box::new(StatusCode::CONFLICT.into_response()));
    }
    Ok(ProjectParent {
        conversation,
        project,
        thread_id,
        rpc,
    })
}

/// Codex binds the provider thread itself. Claude binds Wonder's bridge thread,
/// whose session is the native Claude Code session.
fn binding_matches(
    family: AgentFamily,
    native_session: &str,
    binding: &wonder_store::RuntimeBinding,
) -> bool {
    binding.execution_scope == "projects"
        && binding.family == family
        && match family {
            AgentFamily::Codex => binding.thread_id == native_session,
            AgentFamily::Claude => binding.session_id.as_deref() == Some(native_session),
        }
}

fn verified_child(
    parent: &ProjectParent,
    thread: &Value,
    archived: bool,
) -> Option<ProjectSubagentSummary> {
    let verified = subagents::verified_thread(&parent.thread_id, thread).ok()?;
    let cwd = thread.get("cwd").and_then(Value::as_str)?;
    parent.project.root_for(cwd)?;
    let title = verified
        .agent_nickname
        .as_deref()
        .or(verified.agent_role.as_deref())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("Agent")
        .to_owned();
    Some(ProjectSubagentSummary {
        parent_conversation_id: parent.conversation.conversation_id.clone(),
        thread_id: verified.child_thread_id,
        title,
        agent_nickname: verified.agent_nickname,
        agent_role: verified.agent_role,
        status: project_child_status(thread, &verified.status),
        is_archived: archived,
        can_accept_direct_input: false,
    })
}

fn project_child_status(thread: &Value, verified_status: &str) -> String {
    if verified_status == "active" {
        let flags = thread
            .pointer("/status/activeFlags")
            .and_then(Value::as_array);
        for waiting in ["waitingOnApproval", "waitingOnUserInput"] {
            if flags.is_some_and(|flags| flags.iter().any(|flag| flag.as_str() == Some(waiting))) {
                return waiting.into();
            }
        }
    }
    if verified_status == "systemError" {
        return "failed".into();
    }
    verified_status.into()
}

// `thread/read` has no archive field. Scan bounded parent-list pages only when
// opening one child, without adding requests for every roster row.
async fn child_in_list(
    parent: &ProjectParent,
    thread_id: &str,
    archived: bool,
) -> Result<(bool, bool), Box<Response>> {
    let mut cursor: Option<String> = None;
    let mut seen_cursors = HashSet::new();
    for _ in 0..MAX_ARCHIVE_LOOKUP_PAGES {
        let result = request(
            &parent.rpc,
            "thread/list",
            json!({
                "sourceKinds": ["subAgentThreadSpawn"],
                "parentThreadId": parent.thread_id,
                "archived": archived,
                "limit": MAX_CHILDREN,
                "cursor": cursor,
            }),
        )
        .await
        .map_err(|_| {
            Box::new(unavailable(
                "The agent task's archive state could not be checked.",
            ))
        })?;
        let threads = result
            .get("data")
            .and_then(Value::as_array)
            .filter(|threads| threads.len() <= MAX_CHILDREN)
            .ok_or_else(|| Box::new(unavailable("Codex returned an invalid agent task list.")))?;
        if let Some(thread) = threads
            .iter()
            .find(|thread| thread.get("id").and_then(Value::as_str) == Some(thread_id))
        {
            return verified_child(parent, thread, archived)
                .map(|_| (true, false))
                .ok_or_else(|| {
                    Box::new(unavailable(
                        "The agent task's archive state could not be verified.",
                    ))
                });
        }
        cursor = match result.get("nextCursor") {
            None | Some(Value::Null) => return Ok((false, false)),
            Some(Value::String(next))
                if !next.is_empty() && next.len() <= 2048 && seen_cursors.insert(next.clone()) =>
            {
                Some(next.clone())
            }
            _ => {
                return Err(Box::new(unavailable(
                    "Codex returned an invalid agent task cursor.",
                )))
            }
        };
    }
    Ok((false, true))
}

async fn child_archived(parent: &ProjectParent, thread_id: &str) -> Result<bool, Box<Response>> {
    let (current, more_current) = child_in_list(parent, thread_id, false).await?;
    if current {
        return Ok(false);
    }
    let (archived, more_archived) = child_in_list(parent, thread_id, true).await?;
    if archived {
        return Ok(true);
    }
    if more_current || more_archived {
        return Err(Box::new(unavailable(
            "The agent task's archive state could not be checked.",
        )));
    }
    Err(Box::new(StatusCode::NOT_FOUND.into_response()))
}

pub(crate) async fn list(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(conversation_id): Path<String>,
    Query(query): Query<ListQuery>,
) -> Response {
    if query
        .cursor
        .as_ref()
        .is_some_and(|cursor| cursor.is_empty() || cursor.len() > 2048 || query.archived.is_none())
    {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let parent = match parent(&state, &conversation_id).await {
        Ok(parent) => parent,
        Err(response) if response.status() == StatusCode::NOT_IMPLEMENTED => {
            return Json(ProjectSubagentList {
                available: false,
                detail: Some("Agent task history is available for Codex Projects.".into()),
                subagents: Vec::new(),
                next_current_cursor: None,
                next_archived_cursor: None,
            })
            .into_response();
        }
        Err(response) if response.status() == StatusCode::CONFLICT => {
            return *response;
        }
        Err(response) => return *response,
    };
    if parent.conversation.family == AgentFamily::Claude {
        // Claude agent tasks and background commands come from the session
        // transcript itself; they have no archive or paging of their own.
        if query.archived == Some(true) || query.cursor.is_some() {
            return Json(ProjectSubagentList {
                available: true,
                detail: None,
                subagents: Vec::new(),
                next_current_cursor: None,
                next_archived_cursor: None,
            })
            .into_response();
        }
        return match claude_tasks(&parent).await {
            Ok(subagents) => Json(ProjectSubagentList {
                available: true,
                detail: None,
                subagents,
                next_current_cursor: None,
                next_archived_cursor: None,
            })
            .into_response(),
            Err(response) => *response,
        };
    }
    let mut children = Vec::new();
    let mut seen = HashSet::new();
    let mut next_current_cursor = None;
    let mut next_archived_cursor = None;
    for archived in query
        .archived
        .map_or(vec![false, true], |value| vec![value])
    {
        let result = match request(
            &parent.rpc,
            "thread/list",
            json!({
                "sourceKinds": ["subAgentThreadSpawn"],
                "parentThreadId": parent.thread_id,
                "archived": archived,
                "limit": MAX_CHILDREN,
                "cursor": query.cursor,
            }),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => return unavailable("Agent tasks could not be loaded. Try again."),
        };
        let Some(threads) = result.get("data").and_then(Value::as_array) else {
            return unavailable("Codex returned an invalid agent task list.");
        };
        if threads.len() > MAX_CHILDREN {
            return unavailable("Codex returned too many agent tasks.");
        }
        let next_cursor = match result.get("nextCursor") {
            None | Some(Value::Null) => None,
            Some(Value::String(cursor)) if !cursor.is_empty() && cursor.len() <= 2048 => {
                Some(cursor.clone())
            }
            _ => return unavailable("Codex returned an invalid agent task cursor."),
        };
        if archived {
            next_archived_cursor = next_cursor;
        } else {
            next_current_cursor = next_cursor;
        }
        for thread in threads {
            if let Some(child) = verified_child(&parent, thread, archived) {
                if seen.insert(child.thread_id.clone()) {
                    children.push(child);
                }
            }
        }
    }
    Json(ProjectSubagentList {
        available: true,
        detail: (next_current_cursor.is_some() || next_archived_cursor.is_some())
            .then(|| "More agent tasks are available.".into()),
        subagents: children,
        next_current_cursor,
        next_archived_cursor,
    })
    .into_response()
}

pub(crate) async fn transcript(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path((conversation_id, thread_id)): Path<(String, String)>,
    Query(query): Query<TranscriptQuery>,
) -> Response {
    if thread_id.is_empty()
        || thread_id.len() > 256
        || query
            .cursor
            .as_ref()
            .is_some_and(|cursor| cursor.is_empty() || cursor.len() > 2048)
    {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let parent = match parent(&state, &conversation_id).await {
        Ok(parent) => parent,
        Err(response) => return *response,
    };
    if parent.conversation.family == AgentFamily::Claude {
        return claude_transcript(&state, &parent, &conversation_id, &thread_id).await;
    }
    let read = match request(
        &parent.rpc,
        "thread/read",
        json!({"threadId": thread_id, "includeTurns": false}),
    )
    .await
    {
        Ok(read) => read,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let thread = read.get("thread").unwrap_or(&read);
    if thread.get("id").and_then(Value::as_str) != Some(thread_id.as_str()) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Some(mut child) = verified_child(&parent, thread, false) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    child.is_archived = match child_archived(&parent, &thread_id).await {
        Ok(archived) => archived,
        Err(response) => return *response,
    };
    let result = match request(
        &parent.rpc,
        "thread/items/list",
        json!({
            "threadId": thread_id,
            "limit": PAGE_SIZE,
            "sortDirection": "desc",
            "cursor": query.cursor,
        }),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => return unavailable("Agent task history could not be loaded."),
    };
    let Some(entries) = result.get("data").and_then(Value::as_array) else {
        return unavailable("Codex returned invalid agent task history.");
    };
    if entries.len() > PAGE_SIZE {
        return unavailable("Codex returned too much agent task history.");
    }
    let mut items = Vec::with_capacity(entries.len());
    for entry in entries.iter().rev() {
        let (Some(turn_id), Some(item)) = (
            entry
                .get("turnId")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty()),
            entry.get("item").filter(|item| item.is_object()),
        ) else {
            return unavailable("Codex returned invalid agent task history.");
        };
        items.push(history::AppServerThreadItem {
            turn_id: turn_id.to_owned(),
            item: item.clone(),
        });
    }
    let next_cursor = match result.get("nextCursor") {
        None | Some(Value::Null) => None,
        Some(Value::String(cursor)) if !cursor.is_empty() && cursor.len() <= 2048 => {
            Some(cursor.clone())
        }
        _ => return unavailable("Codex returned an invalid history cursor."),
    };
    let mut projection = history::conversation_thread_projection_with_items(
        Some(thread_id.clone()),
        &[],
        &[],
        &[],
        &items,
        Some(&parent.conversation.cwd),
    );
    projection.next_cursor = next_cursor;
    Json(ProjectSubagentTranscript {
        subagent: child,
        snapshot: history::ConversationSnapshot {
            conversation_id: format!("project-agent:{}:{}", conversation_id, thread_id),
            host_epoch: state.host_epoch,
            last_sequence: 0,
            codex_thread_id: Some(thread_id),
            messages: Vec::new(),
            assistant_messages: Vec::new(),
            thread: projection,
            events: Vec::new(),
        },
    })
    .into_response()
}

fn claude_task_summary(
    parent_conversation_id: &str,
    task: &Value,
) -> Option<ProjectSubagentSummary> {
    let id = task
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && id.len() <= 256)?;
    let title = task
        .get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|title| !title.is_empty())?;
    let role = match task.get("kind").and_then(Value::as_str)? {
        "agent" => task
            .get("role")
            .and_then(Value::as_str)
            .filter(|role| !role.trim().is_empty())
            .unwrap_or("Agent"),
        "command" => "Background command",
        _ => return None,
    };
    let status = match task.get("status").and_then(Value::as_str)? {
        status @ ("running" | "completed" | "failed" | "interrupted") => status,
        _ => "unknown",
    };
    Some(ProjectSubagentSummary {
        parent_conversation_id: parent_conversation_id.to_owned(),
        thread_id: id.to_owned(),
        title: title.chars().take(200).collect(),
        agent_nickname: None,
        agent_role: Some(role.chars().take(80).collect()),
        status: status.to_owned(),
        is_archived: false,
        can_accept_direct_input: false,
    })
}

async fn claude_tasks(
    parent: &ProjectParent,
) -> Result<Vec<ProjectSubagentSummary>, Box<Response>> {
    let result = request(
        &parent.rpc,
        "thread/backgroundTasks/list",
        json!({"threadId": parent.thread_id}),
    )
    .await
    .map_err(|_| Box::new(unavailable("Agent tasks could not be loaded. Try again.")))?;
    let tasks = result
        .get("data")
        .and_then(Value::as_array)
        .filter(|tasks| tasks.len() <= MAX_CHILDREN)
        .ok_or_else(|| Box::new(unavailable("Claude returned an invalid agent task list.")))?;
    Ok(tasks
        .iter()
        .filter_map(|task| claude_task_summary(&parent.conversation.conversation_id, task))
        .collect())
}

async fn claude_transcript(
    state: &AppState,
    parent: &ProjectParent,
    conversation_id: &str,
    task_id: &str,
) -> Response {
    let result = match request(
        &parent.rpc,
        "thread/backgroundTask/read",
        json!({"threadId": parent.thread_id, "taskId": task_id}),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let Some(child) = result
        .get("task")
        .and_then(|task| claude_task_summary(&parent.conversation.conversation_id, task))
        .filter(|child| child.thread_id == task_id)
    else {
        return unavailable("Claude returned an invalid agent task.");
    };
    let Some(entries) = result
        .get("items")
        .and_then(Value::as_array)
        .filter(|items| items.len() <= PAGE_SIZE)
    else {
        return unavailable("Claude returned invalid agent task history.");
    };
    let items: Vec<history::AppServerThreadItem> = entries
        .iter()
        .filter(|item| {
            item.get("type").and_then(Value::as_str) == Some("agentMessage")
                && item.get("id").and_then(Value::as_str).is_some()
                && item.get("text").and_then(Value::as_str).is_some()
        })
        .map(|item| history::AppServerThreadItem {
            turn_id: task_id.to_owned(),
            item: item.clone(),
        })
        .collect();
    let projection = history::conversation_thread_projection_with_items(
        Some(task_id.to_owned()),
        &[],
        &[],
        &[],
        &items,
        Some(&parent.conversation.cwd),
    );
    Json(ProjectSubagentTranscript {
        subagent: child,
        snapshot: history::ConversationSnapshot {
            conversation_id: format!("project-agent:{}:{}", conversation_id, task_id),
            host_epoch: state.host_epoch.clone(),
            last_sequence: 0,
            codex_thread_id: Some(task_id.to_owned()),
            messages: Vec::new(),
            assistant_messages: Vec::new(),
            thread: projection,
            events: Vec::new(),
        },
    })
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    // A Claude Project conversation stores the Claude Code session; its binding
    // names Wonder's bridge thread. Both families must accept their own shape.
    #[test]
    fn project_bindings_match_each_family_identity() {
        let binding = |family, thread: &str, session: Option<&str>| wonder_store::RuntimeBinding {
            conversation_id: "chat".into(),
            family,
            thread_id: thread.into(),
            session_id: session.map(str::to_owned),
            execution_scope: "projects".into(),
        };
        let claude = binding(AgentFamily::Claude, "claude-bridge", Some("native-session"));
        assert!(binding_matches(
            AgentFamily::Claude,
            "native-session",
            &claude
        ));
        assert!(!binding_matches(
            AgentFamily::Claude,
            "other-session",
            &claude
        ));
        assert!(!binding_matches(
            AgentFamily::Codex,
            "native-session",
            &claude
        ));
        let codex = binding(AgentFamily::Codex, "thread", None);
        assert!(binding_matches(AgentFamily::Codex, "thread", &codex));
        assert!(!binding_matches(AgentFamily::Codex, "other", &codex));
        let mut bot = codex.clone();
        bot.execution_scope = "bots".into();
        assert!(!binding_matches(AgentFamily::Codex, "thread", &bot));
    }

    // Claude agent tasks and background commands share the read-only roster;
    // unknown kinds are dropped and unrecognized states are not claimed.
    #[test]
    fn claude_tasks_map_to_read_only_roster_rows() {
        let row = |task: Value| claude_task_summary("chat", &task);
        let command = row(
            json!({"id":"toolu_1","kind":"command","title":"Build the app","status":"running"}),
        )
        .unwrap();
        assert_eq!(
            (command.agent_role.as_deref(), command.status.as_str()),
            (Some("Background command"), "running")
        );
        assert!(!command.can_accept_direct_input);
        let agent = row(json!({"id":"toolu_2","kind":"agent","title":"Review","role":"Explore","status":"completed"})).unwrap();
        assert_eq!(agent.agent_role.as_deref(), Some("Explore"));
        assert_eq!(
            row(json!({"id":"toolu_3","kind":"agent","title":"Old","status":"lost"}))
                .unwrap()
                .status,
            "unknown"
        );
        assert!(
            row(json!({"id":"toolu_4","kind":"shell","title":"x","status":"running"})).is_none()
        );
        assert!(row(json!({"id":"","kind":"command","title":"x","status":"running"})).is_none());
    }

    #[test]
    fn project_child_status_preserves_waiting_and_provider_failures() {
        for (thread, verified, expected) in [
            (
                json!({"status":{"type":"active","activeFlags":["waitingOnApproval"]}}),
                "active",
                "waitingOnApproval",
            ),
            (
                json!({"status":{"type":"active","activeFlags":["waitingOnUserInput"]}}),
                "active",
                "waitingOnUserInput",
            ),
            (
                json!({"status":{"type":"active","activeFlags":[]}}),
                "active",
                "active",
            ),
            (
                json!({"status":{"type":"systemError"}}),
                "systemError",
                "failed",
            ),
            (
                json!({"status":{"type":"notLoaded"}}),
                "notLoaded",
                "notLoaded",
            ),
        ] {
            assert_eq!(project_child_status(&thread, verified), expected);
        }
    }

    async fn body(response: Response) -> (StatusCode, Value) {
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    #[tokio::test]
    async fn project_child_history_requires_exact_spawn_and_current_project_roots() {
        let (dir, state, _) = crate::projects::tests::handoff_fixture().await;
        let cwd = dir
            .path()
            .join("project-source")
            .to_string_lossy()
            .into_owned();
        let child = json!({
            "id":"child-thread", "parentThreadId":"thread", "cwd":cwd,
            "source":{"subAgent":{"thread_spawn":{"parent_thread_id":"thread","depth":1,"agent_nickname":"Scout"}}},
            "status":{"type":"notLoaded"}, "isArchived":true
        });
        let forged = json!({
            "id":"forged-thread", "parentThreadId":"thread", "cwd":cwd,
            "source":{"subAgent":{"thread_spawn":{"parent_thread_id":"other-thread","depth":1}}},
            "status":{"type":"idle"}
        });
        let outside = json!({
            "id":"outside-thread", "parentThreadId":"thread", "cwd":"/outside",
            "source":{"subAgent":{"thread_spawn":{"parent_thread_id":"thread","depth":1}}},
            "status":{"type":"idle"}
        });
        std::fs::write(dir.path().join("project-subagents-fixture.json"), json!({
            "listNextCursor":"older-tasks",
            "threads":{
                "thread":{"id":"thread","cwd":cwd,"parentThreadId":null},
                "child-thread":child,"forged-thread":forged,"outside-thread":outside
            },
            "items":{"child-thread":[
                {"turnId":"child-turn","item":{"id":"answer-item","type":"agentMessage","text":"Found the issue"}},
                {"turnId":"child-turn","item":{"id":"user-item","type":"userMessage","content":[{"type":"text","text":"Investigate the parser"}]}}
            ]}
        }).to_string()).unwrap();

        let (status, roster) = body(
            list(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path("project-chat".into()),
                Query(ListQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        crate::tests::validate_http_contract("projectSubagentList", &roster);
        assert_eq!(roster["subagents"].as_array().unwrap().len(), 1, "{roster}");
        assert_eq!(roster["subagents"][0]["threadId"], "child-thread");
        assert_eq!(roster["subagents"][0]["status"], "notLoaded");
        assert_eq!(roster["subagents"][0]["isArchived"], true);
        assert_eq!(roster["subagents"][0]["canAcceptDirectInput"], false);
        assert!(roster["detail"]
            .as_str()
            .unwrap()
            .contains("More agent tasks"));
        assert_eq!(roster["nextCurrentCursor"], "older-tasks");

        let (status, read) = body(
            transcript(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path(("project-chat".into(), "child-thread".into())),
                Query(TranscriptQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{read}");
        crate::tests::validate_http_contract("projectSubagentTranscript", &read);
        assert_eq!(read["subagent"]["isArchived"], true);
        assert_eq!(read["snapshot"]["thread"]["threadId"], "child-thread");
        assert_eq!(
            read["snapshot"]["thread"]["turns"][0]["items"][1]["text"],
            "Found the issue"
        );
        let fixture_path = dir.path().join("project-subagents-fixture.json");
        let mut fixture: Value =
            serde_json::from_str(&std::fs::read_to_string(&fixture_path).unwrap()).unwrap();
        fixture["listPageSize"] = json!(1);
        fixture["threads"]["aaa-archived"] = json!({
            "id":"aaa-archived", "parentThreadId":"thread", "cwd":"/outside",
            "source":{"subAgent":{"thread_spawn":{"parent_thread_id":"thread","depth":1}}},
            "status":{"type":"idle"}, "isArchived":true
        });
        std::fs::write(&fixture_path, fixture.to_string()).unwrap();
        let (status, first_page) = body(
            list(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path("project-chat".into()),
                Query(ListQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        crate::tests::validate_http_contract("projectSubagentList", &first_page);
        assert_eq!(first_page["subagents"].as_array().unwrap().len(), 0);
        assert_eq!(first_page["nextArchivedCursor"], "1");
        let (status, older_page) = body(
            list(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path("project-chat".into()),
                Query(ListQuery {
                    archived: Some(true),
                    cursor: Some("1".into()),
                }),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        crate::tests::validate_http_contract("projectSubagentList", &older_page);
        assert_eq!(older_page["subagents"][0]["threadId"], "child-thread");
        assert_eq!(older_page["nextArchivedCursor"], Value::Null);
        let (status, paged) = body(
            transcript(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path(("project-chat".into(), "child-thread".into())),
                Query(TranscriptQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(
            status,
            StatusCode::OK,
            "an archived child on page two must open: {paged}"
        );
        assert_eq!(paged["subagent"]["isArchived"], true);
        fixture["repeatListCursor"] = json!(true);
        std::fs::write(&fixture_path, fixture.to_string()).unwrap();
        let (status, _) = body(
            transcript(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path(("project-chat".into(), "child-thread".into())),
                Query(TranscriptQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(
            status,
            StatusCode::SERVICE_UNAVAILABLE,
            "a cyclic cursor cannot establish archive state"
        );
        fixture.as_object_mut().unwrap().remove("repeatListCursor");
        fixture["threads"]["child-thread"]["isArchived"] = Value::Bool(false);
        std::fs::write(&fixture_path, fixture.to_string()).unwrap();
        let (status, unarchived) = body(
            transcript(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path(("project-chat".into(), "child-thread".into())),
                Query(TranscriptQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(unarchived["subagent"]["isArchived"], false);
        for id in ["forged-thread", "outside-thread"] {
            let (status, _) = body(
                transcript(
                    State(state.clone()),
                    Extension(OwnerAuthority),
                    Path(("project-chat".into(), id.into())),
                    Query(TranscriptQuery::default()),
                )
                .await,
            )
            .await;
            assert_eq!(
                status,
                StatusCode::NOT_FOUND,
                "{id} must not inherit Project ownership"
            );
        }

        let pool = sqlx::SqlitePool::connect(&format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        sqlx::query("DELETE FROM runtime_bindings WHERE conversation_id='project-chat'")
            .execute(&pool)
            .await
            .unwrap();
        let (status, _) = body(
            list(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path("project-chat".into()),
                Query(ListQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(
            status,
            StatusCode::CONFLICT,
            "a stale runtime binding cannot authorize discovery"
        );
        let (status, _) = body(
            transcript(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path(("project-chat".into(), "child-thread".into())),
                Query(TranscriptQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        state
            .store
            .bind_project_runtime(
                "project-chat",
                AgentFamily::Codex,
                &state.projects.codex_store,
                "thread",
                None,
                "later",
            )
            .await
            .unwrap();
        sqlx::query("UPDATE runtime_bindings SET runtime_thread_id='another-thread' WHERE conversation_id='project-chat'")
            .execute(&pool)
            .await
            .unwrap();
        let (status, _) = body(
            list(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path("project-chat".into()),
                Query(ListQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(
            status,
            StatusCode::CONFLICT,
            "a retargeted binding cannot expose helpers"
        );
        sqlx::query("UPDATE runtime_bindings SET runtime_thread_id='thread' WHERE conversation_id='project-chat'")
            .execute(&pool)
            .await
            .unwrap();

        state
            .store
            .update_project_metadata("project", None, Some(false), None, "later")
            .await
            .unwrap();
        let (status, _) = body(
            list(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path("project-chat".into()),
                Query(ListQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        let (status, _) = body(
            transcript(
                State(state.clone()),
                Extension(OwnerAuthority),
                Path(("project-chat".into(), "child-thread".into())),
                Query(TranscriptQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);

        state
            .store
            .update_project_metadata("project", None, Some(true), None, "later")
            .await
            .unwrap();
        let replacement = dir.path().join("different-root");
        std::fs::create_dir(&replacement).unwrap();
        let roots = [wonder_store::ProjectRootInput {
            path: replacement.to_string_lossy().into_owned(),
            canonical_path: replacement
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
        }];
        state
            .store
            .update_project_roots("project", 1, &roots, 0, "later")
            .await
            .unwrap();
        let (status, _) = body(
            list(
                State(state),
                Extension(OwnerAuthority),
                Path("project-chat".into()),
                Query(ListQuery::default()),
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }
}
