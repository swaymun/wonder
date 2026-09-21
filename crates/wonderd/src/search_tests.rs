use super::*;
use tower::ServiceExt;
async fn get(state: &AppState, uri: &str, owner: bool) -> (StatusCode, serde_json::Value) {
    let mut request = Request::builder().uri(uri);
    if owner {
        request = request.header("x-wonder-loopback-capability", &state.loopback_capability);
    }
    let response = router(state.clone())
        .oneshot(request.body(axum::body::Body::empty()).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let body = axum::body::to_bytes(response.into_body(), 1024 * 1024)
        .await
        .unwrap();
    (status, serde_json::from_slice(&body).unwrap_or_default())
}
#[tokio::test]
async fn search_pages_require_owner_and_bind_cursor_to_query_scope_and_epoch() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    state
        .store
        .create_conversation("bot", "bot", "Bot", "1")
        .await
        .unwrap();
    for n in 0..7 {
        state
            .store
            .insert_message(
                "owner",
                &format!("search-{n}"),
                "needle message",
                "hash",
                "bot",
                "1000",
            )
            .await
            .unwrap();
    }
    assert_ne!(
        get(&state, "/api/v1/search?q=needle", false).await.0,
        StatusCode::OK
    );
    let (status, first) = get(
        &state,
        "/api/v1/search?q=needle&conversationId=bot&limit=3",
        true,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{first}");
    let schema: serde_json::Value = serde_json::from_str(include_str!(
        "../../../packages/protocol/schemas/wonder-http-v1.json"
    ))
    .unwrap();
    let validator = jsonschema::validator_for(&schema).unwrap();
    assert!(validator.is_valid(&serde_json::json!({"apiVersion":"v1","searchResponse":first})));
    assert_eq!(first["results"].as_array().unwrap().len(), 3);
    let cursor = first["nextCursor"].as_str().unwrap();
    let (status, next) = get(
        &state,
        &format!("/api/v1/search?q=needle&conversationId=bot&limit=3&cursor={cursor}"),
        true,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    for item in first["results"].as_array().unwrap() {
        assert!(!next["results"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == item["id"]));
        assert_eq!(item["kind"], "message");
        assert_eq!(item["conversationId"], "bot");
    }
    for uri in [
        format!("/api/v1/search?q=other&conversationId=bot&cursor={cursor}"),
        format!("/api/v1/search?q=needle&cursor={cursor}"),
        "/api/v1/search?q=needle&cursor=garbage".into(),
        "/api/v1/search?q=needle&deviceId=forged".into(),
        "/api/v1/search?q=needle&limit=0".into(),
    ] {
        assert_eq!(
            get(&state, &uri, true).await.0,
            StatusCode::BAD_REQUEST,
            "{uri}"
        );
    }
    let mut restarted = state.clone();
    restarted.host_epoch = "changed".into();
    assert_eq!(
        get(
            &restarted,
            &format!("/api/v1/search?q=needle&conversationId=bot&cursor={cursor}"),
            true
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    state.app_server.lock().await.shutdown().await.unwrap();
}
