use super::*;
use axum::body::to_bytes;
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use tower::ServiceExt;

async fn call(
    state: &AppState,
    path: &str,
    body: serde_json::Value,
    local: bool,
) -> (StatusCode, serde_json::Value) {
    let mut request = Request::builder()
        .method("POST")
        .uri(path)
        .header("content-type", "application/json")
        .header("origin", &state.public_origin);
    if local {
        request = request.header("x-wonder-loopback-capability", &state.loopback_capability);
    }
    let response = router(state.clone())
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let data = to_bytes(response.into_body(), 65536).await.unwrap();
    (
        status,
        serde_json::from_slice(&data).unwrap_or(serde_json::Value::Null),
    )
}

#[tokio::test]
async fn enrollment_requires_local_confirmation_and_revoke_blocks_renewal() {
    let (dir, mut state) = crate::ingestion::tests::fixture().await;
    state.public_origin = "https://wonder.example.ts.net".into();
    state.public_origin_file = None;
    let key = SigningKey::from_slice(&[7_u8; 32]).unwrap();
    let point = key.verifying_key().to_sec1_point(false);
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let (status, offer) = call(
        &state,
        "/api/v1/pairing/offers",
        serde_json::Value::Null,
        true,
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let body = serde_json::json!({"humanCode": offer["humanCode"], "publicKey": {"kty":"EC","crv":"P-256", "x":b64.encode(point.x().unwrap()),"y":b64.encode(point.y().unwrap())},"label":"Test iPhone","sessionExpiration":"never"});
    let (status, claim) = call(&state, "/api/v1/pairing/code", body.clone(), false).await;
    assert_eq!(status, StatusCode::OK);
    let id = claim["deviceId"].as_str().unwrap();
    assert!(!state
        .store
        .list_owner_devices()
        .await
        .unwrap()
        .iter()
        .any(|d| d.id == id));
    assert_eq!(
        call(&state, "/api/v1/pairing/code", body, false).await.0,
        StatusCode::GONE
    );
    let challenge: wonder_api::pairing_protocol::Challenge =
        serde_json::from_value(claim["challenge"].clone()).unwrap();
    let transcript = wonder_api::pairing::ChallengeTranscript {
        device_id: id,
        challenge_id: &challenge.challenge_id,
        nonce: &challenge.nonce,
        origin: &challenge.origin,
        host_installation_id: &challenge.host_installation_id,
        issued_at_ms: challenge.issued_at_ms,
        expires_at_ms: challenge.expires_at_ms,
    };
    let signature: Signature = key.sign(&transcript.to_bytes());
    let signed = serde_json::json!({"challengeId":challenge.challenge_id,"signature":b64.encode(signature.to_bytes())});
    assert_eq!(
        call(&state, "/api/v1/pairing/session", signed.clone(), false)
            .await
            .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        call(
            &state,
            "/api/v1/pairing/session/refresh-challenge",
            serde_json::json!({"deviceId":id}),
            false
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let confirm = format!("/api/v1/pairing/pending/{id}/confirm");
    assert_eq!(
        call(&state, &confirm, serde_json::Value::Null, false)
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    let pool = sqlx::SqlitePool::connect(&format!(
        "sqlite://{}",
        dir.path().join("state.db").display()
    ))
    .await
    .unwrap();
    sqlx::query("CREATE TRIGGER fail_confirmation BEFORE INSERT ON devices BEGIN SELECT RAISE(ABORT, 'test storage failure'); END").execute(&pool).await.unwrap();
    assert_eq!(
        call(&state, &confirm, serde_json::Value::Null, true)
            .await
            .0,
        StatusCode::INTERNAL_SERVER_ERROR
    );
    assert_eq!(
        call(&state, "/api/v1/pairing/session", signed.clone(), false)
            .await
            .0,
        StatusCode::CONFLICT
    );
    sqlx::query("DROP TRIGGER fail_confirmation")
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
    assert_eq!(
        call(&state, &confirm, serde_json::Value::Null, true)
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    assert!(state
        .store
        .list_owner_devices()
        .await
        .unwrap()
        .iter()
        .any(|d| d.id == id));
    let (status, credential) = call(&state, "/api/v1/pairing/session", signed, false).await;
    assert_eq!(status, StatusCode::OK);
    let token = credential["sessionToken"].as_str().unwrap();
    assert_eq!(
        state
            .pairing
            .lock()
            .await
            .verify_session(token, None, now_ms())
            .unwrap(),
        id
    );
    assert_eq!(
        call(
            &state,
            &format!("/api/v1/devices/{id}/revoke"),
            serde_json::Value::Null,
            true
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    assert!(state
        .pairing
        .lock()
        .await
        .verify_session(token, None, now_ms())
        .is_err());
    assert!(state
        .store
        .list_active_sessions(now_ms())
        .await
        .unwrap()
        .is_empty());
    assert_ne!(
        call(
            &state,
            "/api/v1/pairing/session/refresh-challenge",
            serde_json::json!({"deviceId":id}),
            false
        )
        .await
        .0,
        StatusCode::OK
    );
}
