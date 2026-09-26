use super::*;
use serde_json::{json, Value};
use tower::ServiceExt;

async fn message(
    state: &AppState,
    client: &str,
    conversation: &str,
    thread: &str,
    turn: &str,
) -> wonder_store::StoredMessage {
    let MessageInsert::Inserted(message) = state
        .store
        .insert_message("owner", client, "Work", "hash", conversation, "1")
        .await
        .unwrap()
    else {
        panic!()
    };
    state
        .store
        .update_message_delivery(&message.id, "accepted_by_codex", Some(thread), Some(turn))
        .await
        .unwrap();
    message
}
async fn approval(state: &AppState, id: &str, thread: &str, turn: &str) {
    state.store.insert_pending_approval(id,"item/commandExecution/requestApproval",&json!({"threadId":thread,"turnId":turn,"itemId":"command","conversationId":"forged-chat","cwd":"/forged/group/path","availableDecisions":["accept","decline"]}).to_string(),"1").await.unwrap();
}
async fn list(state: &AppState) -> Value {
    let response = router(state.clone())
        .oneshot(
            Request::builder()
                .uri("/api/v1/approvals")
                .header("x-wonder-loopback-capability", &state.loopback_capability)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    serde_json::from_slice(
        &axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .unwrap(),
    )
    .unwrap()
}

#[tokio::test]
async fn direct_approval_routes_from_exact_turn_and_preserves_nonce() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    message(&state, "direct", "bot", "direct-thread", "direct-turn").await;
    approval(&state, "direct-approval", "direct-thread", "direct-turn").await;
    let before = state
        .store
        .list_pending_approvals()
        .await
        .unwrap()
        .remove(0);
    let result = list(&state).await;
    assert_eq!(result[0]["conversationId"], "bot");
    assert!(result[0]["params"].get("conversationId").is_none());
    assert_eq!(result[0]["params"]["cwd"], "/forged/group/path");
    assert_eq!(result[0]["actionNonce"], before.action_nonce);
    assert_eq!(
        state
            .store
            .list_pending_approvals()
            .await
            .unwrap()
            .remove(0),
        before
    );
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn phone_question_preserves_multiple_choice_semantics_through_redaction() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    message(&state, "question", "bot", "thread", "turn").await;
    let params = json!({"threadId":"thread","turnId":"turn","questions":[
        {"id":"q","question":"Which fixtures?","multiSelect":true,"privateField":"hidden",
         "options":[{"label":"A, B"},{"label":"C"}]}]});
    state
        .store
        .insert_pending_approval(
            "question",
            "item/tool/requestUserInput",
            &params.to_string(),
            "1",
        )
        .await
        .unwrap();
    let visible = list(&state).await;
    let question = &visible[0]["params"]["questions"][0];
    assert_eq!(question["multiSelect"], true);
    assert_eq!(question["options"][0]["label"], "A, B");
    assert!(question.get("privateField").is_none());
    let reply = json!({"answers":{"q":{"answers":["A, B","C"]}}});
    assert!(validate_user_input_response(&params.to_string(), &reply).is_ok());
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn group_worker_and_guided_worker_approvals_route_to_persisted_parent_chat() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    state
        .store
        .create_channel(
            "group",
            "visible-group-chat",
            "Team",
            None,
            "bot",
            &[("bot", "coordinator")],
            "1",
        )
        .await
        .unwrap();
    let parent = message(
        &state,
        "parent",
        "visible-group-chat",
        "parent-thread",
        "parent-turn",
    )
    .await;
    state
        .store
        .add_channel_message(NewChannelMessage {
            channel_id: "group",
            message_id: &parent.id,
            author_kind: "user",
            author_bot_id: None,
            phase: "user",
            created_at: "1",
            presentation_kind: "message",
            outcome: Some("completed"),
            retryable: false,
        })
        .await
        .unwrap();
    state
        .store
        .plan_group_node(&parent, "worker", "bot", "worker")
        .await
        .unwrap();
    message(
        &state,
        "worker",
        "opaque-internal-worker-chat",
        "worker-thread",
        "worker-turn",
    )
    .await;
    approval(&state, "worker-approval", "worker-thread", "worker-turn").await;
    assert_eq!(
        list(&state).await[0]["conversationId"],
        "visible-group-chat"
    );
    // Guide can become the newest message for the same turn without owning a node.
    message(
        &state,
        "guide",
        "opaque-internal-worker-chat",
        "worker-thread",
        "worker-turn",
    )
    .await;
    let result = list(&state).await;
    assert_eq!(result[0]["conversationId"], "visible-group-chat");
    assert_eq!(result[0]["params"]["threadId"], "worker-thread");
    assert_eq!(result[0]["params"]["turnId"], "worker-turn");
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn wrong_thread_turn_or_missing_mapping_never_uses_forged_route() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    message(
        &state,
        "direct",
        "actual-chat",
        "actual-thread",
        "actual-turn",
    )
    .await;
    for (id, thread, turn) in [
        ("wrong-thread", "wrong-thread", "actual-turn"),
        ("wrong-turn", "actual-thread", "wrong-turn"),
        ("unmapped", "missing-thread", "missing-turn"),
        ("empty-thread", "", "actual-turn"),
    ] {
        approval(&state, id, thread, turn).await;
    }
    let result = list(&state).await;
    assert_eq!(result.as_array().unwrap().len(), 4);
    for approval in result.as_array().unwrap() {
        assert!(approval.get("conversationId").is_none(), "{approval}");
        assert!(approval["params"].get("conversationId").is_none());
    }
    state.app_server.lock().await.shutdown().await.unwrap();
}
