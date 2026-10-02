//! Direct Bot and Project goals. The owning runtime keeps the objective and
//! status; Wonder stores only its thread mapping and optional active-time limit.
use crate::{bot_for_conversation, projects, subagents, AppState};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Map, Value};
use std::path::Path as FsPath;
use std::sync::atomic::{AtomicI64, Ordering};
use wonder_app_server::RpcClient;
use wonder_store::{AgentFamily, StoredProject, EXECUTION_SCOPE_PROJECTS};

static LAST_LIMIT_CHECK_MS: AtomicI64 = AtomicI64::new(0);

struct GoalRoute {
    thread: String,
    rpc: RpcClient,
    project: Option<StoredProject>,
}

async fn direct_thread(
    state: &AppState,
    conversation: &str,
) -> Result<Option<GoalRoute>, Box<Response>> {
    if let Some(response) = subagents::reject_user_mutation(state, conversation).await {
        return Err(Box::new(response));
    }
    if state
        .store
        .group_id_for_conversation(conversation)
        .await
        .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?
        .is_some()
    {
        return Err(Box::new(
            (
                StatusCode::CONFLICT,
                "Goals are available in direct conversations.",
            )
                .into_response(),
        ));
    }
    if let Some(project_conversation) = state
        .store
        .project_conversation(conversation)
        .await
        .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?
    {
        if project_conversation.family != AgentFamily::Codex {
            return Err(Box::new(
                (
                    StatusCode::CONFLICT,
                    "Goals are not available for Claude yet.",
                )
                    .into_response(),
            ));
        }
        let project = state
            .store
            .project(&project_conversation.project_id)
            .await
            .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?
            .ok_or_else(|| Box::new(StatusCode::NOT_FOUND.into_response()))?;
        if !project.is_included
            || !project
                .root_for(&project_conversation.cwd)
                .is_some_and(|root| FsPath::new(&root.canonical_path).is_dir())
        {
            return Err(Box::new(
                (
                    StatusCode::CONFLICT,
                    "This Project is no longer available. Review its folders before continuing.",
                )
                    .into_response(),
            ));
        }
        if project_conversation.provider_store != state.projects.codex_store {
            return Err(Box::new(
                (
                    StatusCode::CONFLICT,
                    "This Project thread belongs to a different Codex history.",
                )
                    .into_response(),
            ));
        }
        let binding = state
            .store
            .runtime_binding(conversation)
            .await
            .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?;
        let (native, binding) = match (project_conversation.native_session_id, binding) {
            (None, None) => return Ok(None),
            (Some(native), Some(binding)) => (native, binding),
            _ => {
                return Err(Box::new((StatusCode::CONFLICT, "This Project thread's runtime identity changed. Reopen it before changing its Goal.").into_response()));
            }
        };
        let recorded = state
            .store
            .conversation_thread(conversation)
            .await
            .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?;
        if binding.family != AgentFamily::Codex
            || binding.execution_scope != EXECUTION_SCOPE_PROJECTS
            || binding.thread_id != native
            || recorded.as_deref() != Some(native.as_str())
        {
            return Err(Box::new((StatusCode::CONFLICT, "This Project thread's runtime identity changed. Reopen it before changing its Goal.").into_response()));
        }
        let rpc = projects::codex_rpc(state).await.map_err(|_| {
            Box::new(
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Project Goals are unavailable on this Mac. Try again.",
                )
                    .into_response(),
            )
        })?;
        return Ok(Some(GoalRoute {
            thread: native,
            rpc,
            project: Some(project),
        }));
    }
    let bot = bot_for_conversation(state, conversation)
        .await
        .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?
        .ok_or_else(|| Box::new(StatusCode::NOT_FOUND.into_response()))?;
    if bot.agent_family == wonder_store::AgentFamily::Claude {
        return Err(Box::new(
            (
                StatusCode::CONFLICT,
                "Goals are not available for Claude yet.",
            )
                .into_response(),
        ));
    }
    let thread = state
        .store
        .conversation_thread(conversation)
        .await
        .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?;
    let Some(thread) = thread else {
        return Ok(None);
    };
    Ok(Some(GoalRoute {
        thread,
        rpc: state.app_server.lock().await.rpc(),
        project: None,
    }))
}

async fn runtime_goal(route: &GoalRoute) -> Result<Value, Box<Response>> {
    let response = route
        .rpc
        .request("thread/goal/get", json!({"threadId":route.thread}))
        .await
        .map_err(|_| {
            Box::new(
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Goal status is unavailable. Try again.",
                )
                    .into_response(),
            )
        })?;
    if response.error.is_some() {
        return Err(Box::new(
            (
                StatusCode::SERVICE_UNAVAILABLE,
                "Goal status is unavailable. Try again.",
            )
                .into_response(),
        ));
    }
    Ok(response.result.unwrap_or(json!({"goal":null})))
}

async fn decorate(
    state: &AppState,
    conversation: &str,
    thread: &str,
    mut result: Value,
) -> Result<Value, Box<Response>> {
    if result.get("goal").is_some_and(|goal| !goal.is_null()) {
        state
            .store
            .set_goal_thread(conversation, thread)
            .await
            .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?;
        if let Some(limit) = state
            .store
            .goal_time_limit(conversation)
            .await
            .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?
        {
            if limit.thread_id == thread {
                result["goal"]["timeBudgetSeconds"] = json!(limit.budget_seconds);
            }
        }
    } else {
        state
            .store
            .clear_goal_thread(thread)
            .await
            .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?;
        state
            .store
            .clear_goal_time_limit(conversation)
            .await
            .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?;
    }
    Ok(result)
}

pub async fn get(State(state): State<AppState>, Path(conversation): Path<String>) -> Response {
    let route = match direct_thread(&state, &conversation).await {
        Ok(Some(route)) => route,
        Ok(None) => return Json(json!({"goal":null})).into_response(),
        Err(response) => return *response,
    };
    match runtime_goal(&route).await {
        Ok(result) => match decorate(&state, &conversation, &route.thread, result).await {
            Ok(result) => Json(result).into_response(),
            Err(response) => *response,
        },
        Err(response) => *response,
    }
}

pub async fn set(
    State(state): State<AppState>,
    Path(conversation): Path<String>,
    Json(body): Json<Value>,
) -> Response {
    let route = match direct_thread(&state, &conversation).await {
        Ok(Some(route)) => route,
        Ok(None) => {
            return (
                StatusCode::CONFLICT,
                "Send a message before setting a Goal.",
            )
                .into_response()
        }
        Err(response) => return *response,
    };
    let Some(input) = body.as_object() else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let mut params = Map::new();
    params.insert("threadId".into(), json!(route.thread));
    if let Some(objective) = input.get("objective") {
        let Some(objective) = objective
            .as_str()
            .map(str::trim)
            .filter(|value| !value.is_empty() && value.len() <= 4096)
        else {
            return (
                StatusCode::BAD_REQUEST,
                "Goal text must be between 1 and 4096 characters.",
            )
                .into_response();
        };
        params.insert("objective".into(), json!(objective));
    }
    if let Some(status) = input.get("status") {
        let Some(status) = status
            .as_str()
            .filter(|status| matches!(*status, "active" | "paused"))
        else {
            return StatusCode::BAD_REQUEST.into_response();
        };
        params.insert("status".into(), json!(status));
    }
    if let Some(budget) = input.get("tokenBudget") {
        if !budget.is_null() && !budget.as_i64().is_some_and(|budget| budget > 0) {
            return StatusCode::BAD_REQUEST.into_response();
        }
        params.insert("tokenBudget".into(), budget.clone());
    }
    let time_budget = input.get("timeBudgetSeconds");
    if let Some(time_budget) = time_budget {
        if !time_budget.is_null() && !time_budget.as_i64().is_some_and(|seconds| seconds > 0) {
            return StatusCode::BAD_REQUEST.into_response();
        }
    }
    if params.len() == 1 && time_budget.is_none() {
        return StatusCode::BAD_REQUEST.into_response();
    }
    if let Some(project) = route.project.as_ref() {
        let checked = project.clone();
        let denied = state.denied_roots.clone();
        match tokio::task::spawn_blocking(move || {
            projects::validate_execution_roots(&checked, &denied)
        })
        .await
        {
            Ok(Ok(())) => {}
            Ok(Err(detail)) => return (StatusCode::CONFLICT, detail).into_response(),
            Err(_) => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Project folders could not be checked. Try again.",
                )
                    .into_response()
            }
        }
    }
    let response = if params.len() > 1 {
        match route
            .rpc
            .request("thread/goal/set", Value::Object(params))
            .await
        {
            Ok(response) if response.error.is_none() => response,
            _ => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Goal could not be saved. Try again.",
                )
                    .into_response()
            }
        }
    } else {
        match route
            .rpc
            .request("thread/goal/get", json!({"threadId":route.thread}))
            .await
        {
            Ok(response) if response.error.is_none() => response,
            _ => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Goal could not be loaded. Try again.",
                )
                    .into_response()
            }
        }
    };
    if let Some(time_budget) = time_budget {
        if state
            .store
            .set_goal_time_limit(&conversation, &route.thread, time_budget.as_i64())
            .await
            .is_err()
        {
            return StatusCode::SERVICE_UNAVAILABLE.into_response();
        }
    }
    match decorate(
        &state,
        &conversation,
        &route.thread,
        response.result.unwrap_or(json!({"goal":null})),
    )
    .await
    {
        Ok(result) => Json(result).into_response(),
        Err(response) => *response,
    }
}

pub async fn clear(State(state): State<AppState>, Path(conversation): Path<String>) -> Response {
    let route = match direct_thread(&state, &conversation).await {
        Ok(Some(route)) => route,
        Ok(None) => return StatusCode::NO_CONTENT.into_response(),
        Err(response) => return *response,
    };
    match route
        .rpc
        .request("thread/goal/clear", json!({"threadId":route.thread}))
        .await
    {
        Ok(response) if response.error.is_none() => {
            if state.store.clear_goal_thread(&route.thread).await.is_err()
                || state
                    .store
                    .clear_goal_time_limit(&conversation)
                    .await
                    .is_err()
            {
                return StatusCode::SERVICE_UNAVAILABLE.into_response();
            }
            StatusCode::NO_CONTENT.into_response()
        }
        _ => (
            StatusCode::SERVICE_UNAVAILABLE,
            "Goal could not be removed. Try again.",
        )
            .into_response(),
    }
}

/// The runtime counts only active Goal time, so pauses do not consume a time limit.
pub async fn enforce_time_limits(state: &AppState) {
    let now = crate::now_ms() as i64;
    let last = LAST_LIMIT_CHECK_MS.load(Ordering::Relaxed);
    if now - last < 5_000
        || LAST_LIMIT_CHECK_MS
            .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
            .is_err()
    {
        return;
    }
    enforce_time_limits_now(state).await;
}

pub(crate) async fn enforce_time_limits_now(state: &AppState) {
    let Ok(limits) = state.store.active_goal_time_limits().await else {
        return;
    };
    for limit in limits {
        let Ok(Some(route)) = direct_thread(state, &limit.conversation_id).await else {
            continue;
        };
        if route.thread != limit.thread_id {
            continue;
        }
        let Ok(response) = route
            .rpc
            .request("thread/goal/get", json!({"threadId":limit.thread_id}))
            .await
        else {
            continue;
        };
        let Some(goal) = response
            .result
            .as_ref()
            .and_then(|result| result.get("goal"))
        else {
            continue;
        };
        if goal.is_null() {
            let _ = state
                .store
                .clear_goal_time_limit(&limit.conversation_id)
                .await;
            let _ = state.store.clear_goal_thread(&limit.thread_id).await;
        } else if goal.get("status").and_then(Value::as_str) == Some("active")
            && goal
                .get("timeUsedSeconds")
                .and_then(Value::as_i64)
                .is_some_and(|used| used >= limit.budget_seconds)
        {
            let _ = route
                .rpc
                .request(
                    "thread/goal/set",
                    json!({"threadId":limit.thread_id,"status":"paused"}),
                )
                .await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{symlink, PermissionsExt},
    };
    use wonder_store::{ProjectConversationInsert, ProjectRootInput};

    async fn fixture() -> (tempfile::TempDir, AppState) {
        let (dir, mut state) = crate::permission_modes::tests::fixture().await;
        let original = dir.path().join("codex");
        let project_bin = dir.path().join("project-codex");
        let script = fs::read_to_string(&original).unwrap().replacen(
            "#!/bin/sh",
            "#!/bin/sh\nexport WONDER_FIXTURE_SCOPE=project",
            1,
        );
        fs::write(&project_bin, script).unwrap();
        fs::set_permissions(&project_bin, fs::Permissions::from_mode(0o755)).unwrap();
        state.projects = projects::ProjectRuntime::configured(
            project_bin,
            "test".into(),
            &dir.path().join("codex-home"),
            &dir.path().join("claude-home"),
            crate::ingestion::notification_sink(state.store.clone()),
        );
        let root = dir.path().join("project-source");
        fs::create_dir(&root).unwrap();
        let path = root.to_str().unwrap();
        state
            .store
            .create_project(
                "project",
                "create-project",
                "hash",
                "Project",
                &[ProjectRootInput {
                    path: path.into(),
                    canonical_path: fs::canonicalize(&root).unwrap().to_str().unwrap().into(),
                }],
                0,
                "now",
            )
            .await
            .unwrap();
        state
            .store
            .update_project_metadata("project", None, Some(true), None, "now")
            .await
            .unwrap();
        state
            .store
            .create_project_conversation(ProjectConversationInsert {
                conversation_id: "project-chat",
                project_id: "project",
                family: AgentFamily::Codex,
                provider_store: &state.projects.codex_store,
                native_session_id: None,
                cwd: path,
                roots_revision: 1,
                title: "Project chat",
                model: None,
                effort: None,
                service_tier: None,
                access_mode: "workspace",
                claude_approval: "ask",
                plan_mode: false,
                creation_request_id: None,
                now: "now",
            })
            .await
            .unwrap();
        state
            .store
            .set_project_native_session("project-chat", "project-thread", "now")
            .await
            .unwrap();
        state
            .store
            .bind_project_runtime(
                "project-chat",
                AgentFamily::Codex,
                &state.projects.codex_store,
                "project-thread",
                None,
                "now",
            )
            .await
            .unwrap();
        (dir, state)
    }

    fn goal_requests(dir: &tempfile::TempDir) -> Vec<Value> {
        fs::read_to_string(dir.path().join("routing-requests-jsonl"))
            .unwrap()
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|request| {
                request["method"]
                    .as_str()
                    .unwrap_or_default()
                    .starts_with("thread/goal/")
            })
            .collect()
    }

    #[tokio::test]
    async fn project_goal_uses_its_owner_runtime_for_controls_and_active_time() {
        let (dir, state) = fixture().await;
        state
            .store
            .set_conversation_thread("bot", "bot-thread", None, "now")
            .await
            .unwrap();
        let bot = get(State(state.clone()), Path("bot".into())).await;
        assert_eq!(bot.status(), StatusCode::OK);
        let initial = get(State(state.clone()), Path("project-chat".into())).await;
        assert_eq!(initial.status(), StatusCode::OK);
        let created = set(
            State(state.clone()),
            Path("project-chat".into()),
            Json(json!({"objective":"Finish the Project review","timeBudgetSeconds":60})),
        )
        .await;
        assert_eq!(created.status(), StatusCode::OK);
        assert_eq!(
            state
                .store
                .goal_conversation_for_thread("project-thread")
                .await
                .unwrap()
                .as_deref(),
            Some("project-chat")
        );
        let fetched = get(State(state.clone()), Path("project-chat".into())).await;
        assert_eq!(fetched.status(), StatusCode::OK);
        let body = axum::body::to_bytes(fetched.into_body(), 65_536)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(result["goal"]["timeBudgetSeconds"], 60);

        let goal_path = dir.path().join("goal.json");
        let mut goal: Value = serde_json::from_slice(&fs::read(&goal_path).unwrap()).unwrap();
        goal["timeUsedSeconds"] = json!(60);
        fs::write(&goal_path, serde_json::to_vec(&goal).unwrap()).unwrap();
        enforce_time_limits_now(&state).await;
        let goal: Value = serde_json::from_slice(&fs::read(&goal_path).unwrap()).unwrap();
        assert_eq!(goal["status"], "paused");

        let removed = clear(State(state.clone()), Path("project-chat".into())).await;
        assert_eq!(removed.status(), StatusCode::NO_CONTENT);
        assert!(state
            .store
            .goal_time_limit("project-chat")
            .await
            .unwrap()
            .is_none());
        let requests = goal_requests(&dir);
        for method in ["thread/goal/get", "thread/goal/set", "thread/goal/clear"] {
            assert!(
                requests.iter().any(|request| request["scope"] == "project"
                    && request["method"] == method
                    && request["params"]["threadId"] == "project-thread"),
                "{method}"
            );
        }
        assert!(requests
            .iter()
            .any(|request| request["scope"] == "bot"
                && request["params"]["threadId"] == "bot-thread"));
        assert!(requests.iter().any(|request| request["scope"] == "project"
            && request["method"] == "thread/goal/set"
            && request["params"]["status"] == "paused"));
        assert!(requests.iter().any(
            |request| request["scope"] == "project" && request["method"] == "thread/goal/clear"
        ));
        assert!(requests
            .iter()
            .filter(|request| request["params"]["threadId"] == "project-thread")
            .all(|request| request["scope"] == "project"));
        state.projects.shutdown().await;
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn project_goal_rejects_replaced_folder_before_provider_mutation() {
        let (dir, state) = fixture().await;
        let source = dir.path().join("project-source");
        let original = dir.path().join("original-source");
        let replacement = dir.path().join("replacement-source");
        fs::rename(&source, &original).unwrap();
        fs::create_dir(&replacement).unwrap();
        symlink(&replacement, &source).unwrap();

        let before = goal_requests(&dir).len();
        let response = set(
            State(state.clone()),
            Path("project-chat".into()),
            Json(json!({"objective":"Inspect the changed folder"})),
        )
        .await;
        assert_eq!(response.status(), StatusCode::CONFLICT);
        assert_eq!(goal_requests(&dir).len(), before);
        state.projects.shutdown().await;
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn project_goal_rejects_revoked_claude_and_unbound_threads() {
        let (dir, state) = fixture().await;
        let path = dir.path().join("project-source");
        for (id, family, store, native) in [
            (
                "claude-chat",
                AgentFamily::Claude,
                state.projects.claude_store.as_str(),
                None,
            ),
            (
                "unbound-chat",
                AgentFamily::Codex,
                state.projects.codex_store.as_str(),
                Some("unbound-thread"),
            ),
            (
                "foreign-chat",
                AgentFamily::Codex,
                "codex:another-home",
                None,
            ),
        ] {
            state
                .store
                .create_project_conversation(ProjectConversationInsert {
                    conversation_id: id,
                    project_id: "project",
                    family,
                    provider_store: store,
                    native_session_id: native,
                    cwd: path.to_str().unwrap(),
                    roots_revision: 1,
                    title: id,
                    model: None,
                    effort: None,
                    service_tier: None,
                    access_mode: "workspace",
                    claude_approval: "ask",
                    plan_mode: false,
                    creation_request_id: None,
                    now: "now",
                })
                .await
                .unwrap();
        }
        for id in ["claude-chat", "unbound-chat", "foreign-chat"] {
            assert_eq!(
                get(State(state.clone()), Path(id.into())).await.status(),
                StatusCode::CONFLICT
            );
            assert_eq!(
                set(
                    State(state.clone()),
                    Path(id.into()),
                    Json(json!({"objective":"Unsafe"}))
                )
                .await
                .status(),
                StatusCode::CONFLICT
            );
        }
        state
            .store
            .create_channel(
                "group",
                "group-chat",
                "Group",
                None,
                "bot",
                &[("bot", "coordinator")],
                "now",
            )
            .await
            .unwrap();
        assert_eq!(
            get(State(state.clone()), Path("group-chat".into()))
                .await
                .status(),
            StatusCode::CONFLICT
        );
        let parent = state
            .store
            .ensure_bot_workspace("bot", "Bot", "now")
            .await
            .unwrap();
        state
            .store
            .set_conversation_thread(&parent, "parent-thread", None, "now")
            .await
            .unwrap();
        state
            .store
            .register_subagent_ownership(
                "child-chat",
                &parent,
                "child-thread",
                "parent-thread",
                "bot",
                "Child",
                Some("Child"),
                None,
                None,
                r#"{"subAgent":{"thread_spawn":{"parent_thread_id":"parent-thread","depth":1}}}"#,
                Some("runtime"),
                Some(false),
                "idle",
                None,
                "now",
            )
            .await
            .unwrap();
        assert_eq!(
            get(State(state.clone()), Path("child-chat".into()))
                .await
                .status(),
            StatusCode::FORBIDDEN
        );
        state
            .store
            .update_project_metadata("project", None, Some(false), None, "later")
            .await
            .unwrap();
        assert_eq!(
            get(State(state.clone()), Path("project-chat".into()))
                .await
                .status(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            clear(State(state.clone()), Path("project-chat".into()))
                .await
                .status(),
            StatusCode::CONFLICT
        );
        assert!(goal_requests(&dir).is_empty());
        state.projects.shutdown().await;
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
