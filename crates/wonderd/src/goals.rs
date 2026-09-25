//! Direct Bot goals. The runtime owns the objective and status; Wonder only
//! keeps the thread mapping and an optional user-specified active-time limit.
use crate::{bot_for_conversation, subagents, AppState};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Map, Value};
use std::sync::atomic::{AtomicI64, Ordering};

static LAST_LIMIT_CHECK_MS: AtomicI64 = AtomicI64::new(0);

async fn direct_thread(
    state: &AppState,
    conversation: &str,
) -> Result<Option<String>, Box<Response>> {
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
                "Goals are available in direct Bot conversations.",
            )
                .into_response(),
        ));
    }
    if bot_for_conversation(state, conversation)
        .await
        .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))?
        .is_none()
    {
        return Err(Box::new(StatusCode::NOT_FOUND.into_response()));
    }
    state
        .store
        .conversation_thread(conversation)
        .await
        .map_err(|_| Box::new(StatusCode::SERVICE_UNAVAILABLE.into_response()))
}

async fn runtime_goal(state: &AppState, thread: &str) -> Result<Value, Box<Response>> {
    let rpc = state.app_server.lock().await.rpc();
    let response = rpc
        .request("thread/goal/get", json!({"threadId":thread}))
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
    let thread = match direct_thread(&state, &conversation).await {
        Ok(Some(thread)) => thread,
        Ok(None) => return Json(json!({"goal":null})).into_response(),
        Err(response) => return *response,
    };
    match runtime_goal(&state, &thread).await {
        Ok(result) => match decorate(&state, &conversation, &thread, result).await {
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
    let thread = match direct_thread(&state, &conversation).await {
        Ok(Some(thread)) => thread,
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
    params.insert("threadId".into(), json!(thread));
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
    let rpc = state.app_server.lock().await.rpc();
    let response = if params.len() > 1 {
        match rpc.request("thread/goal/set", Value::Object(params)).await {
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
        match rpc
            .request("thread/goal/get", json!({"threadId":thread}))
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
            .set_goal_time_limit(&conversation, &thread, time_budget.as_i64())
            .await
            .is_err()
        {
            return StatusCode::SERVICE_UNAVAILABLE.into_response();
        }
    }
    match decorate(
        &state,
        &conversation,
        &thread,
        response.result.unwrap_or(json!({"goal":null})),
    )
    .await
    {
        Ok(result) => Json(result).into_response(),
        Err(response) => *response,
    }
}

pub async fn clear(State(state): State<AppState>, Path(conversation): Path<String>) -> Response {
    let thread = match direct_thread(&state, &conversation).await {
        Ok(Some(thread)) => thread,
        Ok(None) => return StatusCode::NO_CONTENT.into_response(),
        Err(response) => return *response,
    };
    let rpc = state.app_server.lock().await.rpc();
    match rpc
        .request("thread/goal/clear", json!({"threadId":thread}))
        .await
    {
        Ok(response) if response.error.is_none() => {
            if state.store.clear_goal_thread(&thread).await.is_err()
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
    let rpc = state.app_server.lock().await.rpc();
    for limit in limits {
        let Ok(response) = rpc
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
            let _ = rpc
                .request(
                    "thread/goal/set",
                    json!({"threadId":limit.thread_id,"status":"paused"}),
                )
                .await;
        }
    }
}
