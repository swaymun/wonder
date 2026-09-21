use super::*;
use axum::body::to_bytes;
use serde_json::{json, Value};
use tower::ServiceExt;

async fn call(state: &AppState, method: &str, path: &str, body: Value) -> (StatusCode, Value) {
    let response = router(state.clone())
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("x-wonder-loopback-capability", &state.loopback_capability)
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 65536).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| json!({"error":String::from_utf8_lossy(&bytes)})),
    )
}
fn create_body() -> Value {
    json!({"name":"Morning brief","kind":"continuation","botId":"bot","conversationId":"bot","prompt":"Prepare a brief.","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","timezone":"America/New_York","clientRequestId":"create-once"})
}
#[tokio::test]
async fn automation_http_create_edit_preview_and_archive_fences() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    let (status, preview) = call(
        &state,
        "POST",
        "/api/v1/automations/preview",
        json!({"rrule":"FREQ=MONTHLY;BYMONTHDAY=15;BYHOUR=9","timezone":"America/New_York"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    assert!(preview["nextRunAt"].is_string());
    let (status, created) = call(&state, "POST", "/api/v1/automations", create_body()).await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    let (status, duplicate) = call(&state, "POST", "/api/v1/automations", create_body()).await;
    assert_eq!(status, StatusCode::OK, "{duplicate}");
    assert_eq!(created["id"], duplicate["id"]);
    assert_eq!(state.store.list_automations().await.unwrap().len(), 1);
    let path = format!("/api/v1/automations/{}", created["id"].as_str().unwrap());
    let (status,edited)=call(&state,"PATCH",&path,json!({"name":"Weekend review","prompt":"Review the week.","rrule":"FREQ=WEEKLY;BYDAY=SA;BYHOUR=10","timezone":"Europe/London","status":"paused"})).await;
    assert_eq!(status, StatusCode::OK, "{edited}");
    assert_eq!(edited["name"], "Weekend review");
    assert_eq!(edited["prompt"], "Review the week.");
    assert!(edited["nextRunAt"].is_null());
    let (status, invalid) = call(
        &state,
        "PATCH",
        &path,
        json!({"rrule":"FREQ=YEARLY","status":"paused"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{invalid}");
    assert_eq!(
        state.store.list_automations().await.unwrap()[0].rrule,
        "FREQ=WEEKLY;BYDAY=SA;BYHOUR=10"
    );
    let (status, resumed) = call(&state, "PATCH", &path, json!({"status":"active"})).await;
    assert_eq!(status, StatusCode::OK, "{resumed}");
    assert!(resumed["nextRunAt"].is_string());
    state.store.set_bot_archived("bot", true).await.unwrap();
    let (status, error) = call(&state, "PATCH", &path, json!({"status":"active"})).await;
    assert_eq!(status, StatusCode::CONFLICT, "{error}");
    let (status, _) = call(&state, "DELETE", &path, Value::Null).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    state.app_server.lock().await.shutdown().await.unwrap();
}
#[tokio::test]
async fn automation_run_now_retries_return_one_durable_run() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    let request: CreateAutomationRequest = serde_json::from_value(create_body()).unwrap();
    let response = create_automation(State(state.clone()), Json(request)).await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let automation = state.store.list_automations().await.unwrap().remove(0);
    // Hold runtime admission while checking independent concurrent requests.
    let guard = state.dispatch_lock.lock().await;
    let run = || {
        Some(Json(RunAutomationRequest {
            client_request_id: Some("run-once".into()),
        }))
    };
    let first = run_automation_now(State(state.clone()), Path(automation.id.clone()), run()).await;
    assert_eq!(first.status(), StatusCode::ACCEPTED);
    let duplicate =
        run_automation_now(State(state.clone()), Path(automation.id.clone()), run()).await;
    assert_eq!(duplicate.status(), StatusCode::OK);
    let different = run_automation_now(
        State(state.clone()),
        Path(automation.id.clone()),
        Some(Json(RunAutomationRequest {
            client_request_id: Some("run-twice".into()),
        })),
    )
    .await;
    assert_eq!(different.status(), StatusCode::CONFLICT);
    assert_eq!(
        state
            .store
            .list_automation_runs(&automation.id)
            .await
            .unwrap()
            .len(),
        1
    );
    let deletion = delete_automation(State(state.clone()), Path(automation.id.clone())).await;
    assert_eq!(deletion.status(), StatusCode::CONFLICT);
    let history = state
        .store
        .list_automation_runs(&automation.id)
        .await
        .unwrap();
    assert_eq!(history[0].conversation_id.as_deref(), Some("bot"));
    state.app_server.lock().await.shutdown().await.unwrap();
    drop(guard);
}

#[tokio::test]
async fn automation_failed_turn_does_not_report_success() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    let automation = state
        .store
        .insert_automation(
            "auto",
            "Daily",
            "continuation",
            "bot",
            Some("bot"),
            "Task",
            "FREQ=DAILY",
            "UTC",
            "active",
            "all_runs",
            None,
            None,
            None,
            "now",
        )
        .await
        .unwrap();
    state
        .store
        .claim_scheduled_automation("run", &automation, "now", "now", None, false)
        .await
        .unwrap();
    let message = state
        .store
        .materialize_automation_message("run", "owner", &automation, "bot", "now")
        .await
        .unwrap();
    state
        .store
        .update_message_delivery(
            &message.id,
            "accepted_by_codex",
            Some("thread"),
            Some("turn"),
        )
        .await
        .unwrap();
    publish_app_server_notification(&state,json!({"method":"turn/completed","params":{"threadId":"thread","turnId":"turn","turn":{"id":"turn","status":"failed"}}})).await;
    state
        .store
        .reconcile_automation_runs("2026-09-01T00:00:00.000Z")
        .await
        .unwrap();
    let run = state
        .store
        .automation_run_by_id("run")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(run.status, "failed");
    assert!(run.error.is_some());
    assert!(state
        .store
        .automation_by_id("auto")
        .await
        .unwrap()
        .unwrap()
        .last_success_at
        .is_none());
    state.app_server.lock().await.shutdown().await.unwrap();
}
