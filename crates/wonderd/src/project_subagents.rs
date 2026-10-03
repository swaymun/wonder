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
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectSubagentTranscript {
    subagent: ProjectSubagentSummary,
    snapshot: history::ConversationSnapshot,
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
    if conversation.family != AgentFamily::Codex {
        return Err(Box::new(
            (
                StatusCode::NOT_IMPLEMENTED,
                "Project agent tasks are available for Codex threads.",
            )
                .into_response(),
        ));
    }
    if conversation.provider_store != state.projects.codex_store {
        return Err(Box::new(StatusCode::CONFLICT.into_response()));
    }
    let thread_id = conversation.native_session_id.clone().ok_or_else(|| {
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
    if binding.execution_scope != "projects"
        || binding.family != conversation.family
        || binding.thread_id != thread_id
    {
        return Err(Box::new(StatusCode::CONFLICT.into_response()));
    }
    let rpc = projects::codex_rpc(state)
        .await
        .map_err(|_| Box::new(unavailable("Codex is unavailable on your Mac.")))?;
    let read = request(
        &rpc,
        "thread/read",
        json!({"threadId": thread_id, "includeTurns": false}),
    )
    .await
    .map_err(|_| Box::new(unavailable("The Project thread could not be verified.")))?;
    let thread = read.get("thread").unwrap_or(&read);
    if thread.get("id").and_then(Value::as_str) != Some(thread_id.as_str())
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

// `thread/read` has no archive field. Check the provider's exact parent list
// when opening one child, without adding requests for every roster row.
async fn child_in_list(
    parent: &ProjectParent,
    thread_id: &str,
    archived: bool,
) -> Result<(bool, bool), Response> {
    let result = request(
        &parent.rpc,
        "thread/list",
        json!({
            "sourceKinds": ["subAgentThreadSpawn"],
            "parentThreadId": parent.thread_id,
            "archived": archived,
            "limit": MAX_CHILDREN,
        }),
    )
    .await
    .map_err(|_| unavailable("The agent task's archive state could not be checked."))?;
    let threads = result
        .get("data")
        .and_then(Value::as_array)
        .filter(|threads| threads.len() <= MAX_CHILDREN)
        .ok_or_else(|| unavailable("Codex returned an invalid agent task list."))?;
    if let Some(thread) = threads
        .iter()
        .find(|thread| thread.get("id").and_then(Value::as_str) == Some(thread_id))
    {
        return verified_child(parent, thread, archived)
            .map(|_| (true, false))
            .ok_or_else(|| unavailable("The agent task's archive state could not be verified."));
    }
    let more = result
        .get("nextCursor")
        .and_then(Value::as_str)
        .is_some_and(|cursor| !cursor.is_empty());
    Ok((false, more))
}

async fn child_archived(parent: &ProjectParent, thread_id: &str) -> Result<bool, Response> {
    let (current, more_current) = child_in_list(parent, thread_id, false).await?;
    if current {
        return Ok(false);
    }
    let (archived, more_archived) = child_in_list(parent, thread_id, true).await?;
    if archived {
        return Ok(true);
    }
    if more_current || more_archived {
        return Err(unavailable(
            "The agent task's archive state could not be checked.",
        ));
    }
    Err(StatusCode::NOT_FOUND.into_response())
}

pub(crate) async fn list(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(conversation_id): Path<String>,
) -> Response {
    let parent = match parent(&state, &conversation_id).await {
        Ok(parent) => parent,
        Err(response) if response.status() == StatusCode::NOT_IMPLEMENTED => {
            return Json(ProjectSubagentList {
                available: false,
                detail: Some("Agent task history is available for Codex Projects.".into()),
                subagents: Vec::new(),
            })
            .into_response();
        }
        Err(response) if response.status() == StatusCode::CONFLICT => {
            return *response;
        }
        Err(response) => return *response,
    };
    let mut children = Vec::new();
    let mut seen = HashSet::new();
    let mut truncated = false;
    for archived in [false, true] {
        let result = match request(
            &parent.rpc,
            "thread/list",
            json!({
                "sourceKinds": ["subAgentThreadSpawn"],
                "parentThreadId": parent.thread_id,
                "archived": archived,
                "limit": MAX_CHILDREN,
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
        truncated |= result
            .get("nextCursor")
            .and_then(Value::as_str)
            .is_some_and(|cursor| !cursor.is_empty());
        for thread in threads {
            if children.len() >= MAX_CHILDREN {
                truncated = true;
                break;
            }
            if let Some(child) = verified_child(&parent, thread, archived) {
                if seen.insert(child.thread_id.clone()) {
                    children.push(child);
                }
            }
        }
    }
    Json(ProjectSubagentList {
        available: true,
        detail: truncated
            .then(|| "Showing the newest 100 agent tasks. Older tasks are not shown.".into()),
        subagents: children,
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
        Err(response) => return response,
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

#[cfg(test)]
mod tests {
    use super::*;

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
        assert!(roster["detail"].as_str().unwrap().contains("Older tasks"));

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
            )
            .await,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }
}
