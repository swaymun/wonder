//! Push transport. Preview plaintext, pairing and durable intent remain local.
use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use ring::{
    aead,
    rand::{SecureRandom, SystemRandom},
};
use std::{sync::OnceLock, time::Duration};
const OFFICIAL_ENDPOINT: &str = "https://wonder-push.saimun-shahee.workers.dev";
fn endpoint() -> Option<String> {
    let value = std::env::var("WONDER_PUSH_ENDPOINT").unwrap_or_else(|_| OFFICIAL_ENDPOINT.into());
    let url = reqwest::Url::parse(&value).ok()?;
    (url.scheme() == "https"
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && url.path() == "/")
        .then(|| value.trim_end_matches('/').to_owned())
}
fn client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("push HTTP client configuration")
    })
}
pub(super) async fn config() -> Response {
    Json(serde_json::json!({"endpoint":endpoint(),"topic":std::env::var("WONDER_PUSH_TOPIC").unwrap_or_else(|_|"com.swaymun.wonder".into()),"environment":std::env::var("WONDER_PUSH_ENVIRONMENT").unwrap_or_else(|_|"production".into()),"previewVersion":1})).into_response()
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Registration {
    id: String,
    sender_secret: String,
    preview_key: Option<String>,
    #[serde(flatten)]
    action: SignedActionFields,
}
pub(super) async fn register(
    State(state): State<AppState>,
    Extension(device): Extension<AuthenticatedDevice>,
    Json(request): Json<Registration>,
) -> Response {
    let Some(endpoint) = endpoint() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    if uuid::Uuid::parse_str(&request.id).is_err()
        || request.preview_key.as_ref().is_some_and(|key| {
            URL_SAFE_NO_PAD
                .decode(key)
                .map_or(true, |bytes| bytes.len() != 32)
        })
        || request.sender_secret.len() != 43
        || !request
            .sender_secret
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return StatusCode::BAD_REQUEST.into_response();
    }
    if let Err(error) = verify_signed_action(
        &state,
        &device,
        "push.register",
        "/api/v1/push/registration",
        &action_body_sha256(&match &request.preview_key {
            Some(key) => serde_json::json!([request.id, request.sender_secret, key]),
            None => serde_json::json!([request.id, request.sender_secret]),
        }),
        &request.action,
        "active",
    )
    .await
    {
        return (StatusCode::UNAUTHORIZED, error).into_response();
    }
    // The Mac never accepts an unproven or caller-selected service endpoint.
    let verified = client()
        .post(format!("{endpoint}/v1/registrations/{}/status", request.id))
        .bearer_auth(&request.sender_secret)
        .json(&serde_json::json!({}))
        .send()
        .await;
    if !verified.is_ok_and(|r| r.status() == reqwest::StatusCode::OK) {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Push registration could not be verified.",
        )
            .into_response();
    }
    match state
        .store
        .register_push(
            &device.device_id,
            &request.id,
            &endpoint,
            &request.sender_secret,
        )
        .await
    {
        Ok(()) => {
            if let Some(key) = &request.preview_key {
                if state
                    .store
                    .register_push_preview(&device.device_id, &request.id, key)
                    .await
                    .is_err()
                {
                    return StatusCode::CONFLICT.into_response();
                }
            }
            Json(serde_json::json!({"registered":true})).into_response()
        }
        Err(_) => StatusCode::CONFLICT.into_response(),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Presence {
    state: String,
    #[serde(flatten)]
    action: SignedActionFields,
}
pub(super) async fn presence(
    State(state): State<AppState>,
    Extension(device): Extension<AuthenticatedDevice>,
    Json(request): Json<Presence>,
) -> Response {
    if !matches!(request.state.as_str(), "foreground" | "background") {
        return StatusCode::BAD_REQUEST.into_response();
    }
    if let Err(error) = verify_signed_action(
        &state,
        &device,
        "push.presence",
        "/api/v1/push/presence",
        &action_body_sha256(&serde_json::json!([request.state])),
        &request.action,
        "active",
    )
    .await
    {
        return (StatusCode::UNAUTHORIZED, error).into_response();
    }
    match state
        .store
        .push_presence(
            &device.device_id,
            request.state == "foreground",
            request.action.issued_at_ms.unwrap_or(0) as i64,
            now_ms() as i64,
        )
        .await
    {
        Ok(()) => Json(serde_json::json!({"updated":true})).into_response(),
        Err(_) => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}

fn encrypt_preview(
    key: &str,
    registration: &str,
    route: &str,
    event: &str,
    preview: &wonder_store::PushPreview,
) -> Option<String> {
    let key = URL_SAFE_NO_PAD.decode(key).ok()?;
    let key = aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, &key).ok()?);
    let mut nonce = [0u8; 12];
    SystemRandom::new().fill(&mut nonce).ok()?;
    let mut bytes = serde_json::to_vec(preview).ok()?;
    if bytes.len() > 2400 {
        return None;
    }
    let aad = format!("wonder-push-v1\n{registration}\n{route}\n{event}");
    key.seal_in_place_append_tag(
        aead::Nonce::assume_unique_for_key(nonce),
        aead::Aad::from(aad.as_bytes()),
        &mut bytes,
    )
    .ok()?;
    let mut combined = nonce.to_vec();
    combined.extend(bytes);
    Some(URL_SAFE_NO_PAD.encode(combined))
}
pub(super) async fn revoke(
    State(state): State<AppState>,
    Extension(device): Extension<AuthenticatedDevice>,
    Json(request): Json<SignedActionFields>,
) -> Response {
    if let Err(error) = verify_signed_action(
        &state,
        &device,
        "push.revoke",
        "/api/v1/push/revoke",
        &action_body_sha256(&serde_json::json!([])),
        &request,
        "active",
    )
    .await
    {
        return (StatusCode::UNAUTHORIZED, error).into_response();
    }
    match state.store.revoke_push(&device.device_id).await {
        Ok(()) => Json(serde_json::json!({"revoked":true})).into_response(),
        Err(_) => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}
pub(super) async fn route(
    State(state): State<AppState>,
    Extension(device): Extension<AuthenticatedDevice>,
    Path(route): Path<String>,
) -> Response {
    if uuid::Uuid::parse_str(&route).is_err() {
        return StatusCode::BAD_REQUEST.into_response();
    }
    match state.store.push_route(&device.device_id, &route).await {
        Ok(Some(id)) => Json(serde_json::json!({"conversationId":id})).into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}
pub fn spawn(state: AppState) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(3));
        loop {
            interval.tick().await;
            // Revocation remains queued across restart and takes priority.
            if let Ok(Some(record)) = state.store.next_push_revocation().await {
                if let Ok(response) = client()
                    .post(format!(
                        "{}/v1/registrations/{}/revoke",
                        record.endpoint, record.id
                    ))
                    .bearer_auth(record.sender_secret)
                    .json(&serde_json::json!({}))
                    .send()
                    .await
                {
                    if response.status().is_success()
                        || response.status() == reqwest::StatusCode::GONE
                    {
                        let _ = state.store.finish_push_revocation(&record.id).await;
                    }
                }
            }
            if state.store.distribute_push().await.is_err() {
                continue;
            }
            for _ in 0..10 {
                let Ok(Some(delivery)) = state.store.next_push().await else {
                    break;
                };
                let preview = match state.store.push_preview(&delivery).await {
                    Ok(Some(value)) => value,
                    Ok(None) => {
                        let _ = state.store.finish_push(&delivery.id, "cancelled").await;
                        continue;
                    }
                    Err(_) => {
                        let _ = state.store.finish_push(&delivery.id, "pending").await;
                        continue;
                    }
                };
                let mut body = serde_json::json!({"eventId":delivery.id,"routeId":delivery.route_id,"kind":delivery.kind});
                if let Some(encrypted) = delivery.preview_key.as_deref().and_then(|key| {
                    encrypt_preview(
                        key,
                        &delivery.registration_id,
                        &delivery.route_id,
                        &delivery.id,
                        &preview,
                    )
                }) {
                    body["preview"] = encrypted.into();
                }
                if !state
                    .store
                    .can_send_push(&delivery.id)
                    .await
                    .unwrap_or(false)
                {
                    continue;
                }
                let result = client()
                    .post(format!(
                        "{}/v1/registrations/{}/send",
                        delivery.endpoint, delivery.registration_id
                    ))
                    .bearer_auth(delivery.sender_secret)
                    .json(&body)
                    .send()
                    .await;
                let outcome = match result {
                    Ok(response) if response.status().is_success() => "delivered",
                    Ok(response)
                        if matches!(
                            response.status().as_u16(),
                            400 | 401 | 403 | 404 | 409 | 410
                        ) =>
                    {
                        "failed"
                    }
                    _ if delivery.attempts >= 5 => "failed",
                    _ => "pending",
                };
                let _ = state.store.finish_push(&delivery.id, outcome).await;
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn presence_requires_a_device_signature_and_rejects_replay_and_tampering() {
        use axum::{body::Body, http::Request};
        use p256::ecdsa::{signature::Signer, Signature, SigningKey};
        use tower::ServiceExt;
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        let key = SigningKey::from_slice(&[17u8; 32]).unwrap();
        let point = key.verifying_key().to_sec1_point(false);
        state.pairing.lock().await.restore_device(
            "owner".into(),
            wonder_api::pairing_protocol::DevicePublicKeyJwk {
                kty: "EC".into(),
                crv: "P-256".into(),
                x: URL_SAFE_NO_PAD.encode(point.x().unwrap()),
                y: URL_SAFE_NO_PAD.encode(point.y().unwrap()),
            },
            false,
            None,
        );
        let path = "/api/v1/push/presence";
        let app = Router::new()
            .route(path, post(presence))
            .layer(Extension(AuthenticatedDevice {
                device_id: "owner".into(),
                session_binding: "phone-session".into(),
            }))
            .with_state(state.clone());
        let issued = now_ms();
        let transcript = ActionTranscript {
            action: "push.presence",
            target: path,
            body_sha256: &action_body_sha256(&serde_json::json!(["foreground"])),
            action_nonce: "presence-proof",
            session_binding: "phone-session",
            device_id: "owner",
            host_installation_id: &state.host_installation_id,
            issued_at_ms: issued,
            expected_state: "active",
        };
        let signature: Signature = key.sign(&transcript.to_bytes());
        let valid = serde_json::json!({"state":"foreground","actionNonce":"presence-proof","issuedAtMs":issued,"signature":URL_SAFE_NO_PAD.encode(signature.to_bytes())});
        let mut tampered = valid.clone();
        tampered["state"] = "background".into();
        for (body, expected) in [
            (
                serde_json::json!({"state":"foreground"}),
                StatusCode::UNAUTHORIZED,
            ),
            (tampered, StatusCode::UNAUTHORIZED),
            (valid.clone(), StatusCode::OK),
            (valid, StatusCode::UNAUTHORIZED),
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri(path)
                        .header("content-type", "application/json")
                        .body(Body::from(body.to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), expected);
        }
    }

    #[test]
    fn previews_interoperate_with_cryptokit_and_bind_the_recipient_and_route() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/fixtures/push-preview-v1.json"
        ))
        .unwrap();
        let raw_key = URL_SAFE_NO_PAD
            .decode(fixture["key"].as_str().unwrap())
            .unwrap();
        let key =
            aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, &raw_key).unwrap());
        let payload = &fixture["payload"];
        let combined = URL_SAFE_NO_PAD
            .decode(payload["preview"].as_str().unwrap())
            .unwrap();
        let aad = format!(
            "wonder-push-v1\n{}\n{}\n{}",
            payload["registrationId"].as_str().unwrap(),
            payload["routeId"].as_str().unwrap(),
            payload["eventId"].as_str().unwrap()
        );
        let nonce: [u8; 12] = combined[..12].try_into().unwrap();
        let mut bytes = combined[12..].to_vec();
        let plaintext = key
            .open_in_place(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::from(aad.as_bytes()),
                &mut bytes,
            )
            .unwrap();
        assert_eq!(plaintext, fixture["plaintext"].as_str().unwrap().as_bytes());
        let mut tampered = combined[12..].to_vec();
        assert!(key
            .open_in_place(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::from(format!("{aad}other").as_bytes()),
                &mut tampered
            )
            .is_err());
        let preview = wonder_store::PushPreview {
            title: "Chat".into(),
            body: "Question?".into(),
        };
        let first = encrypt_preview(
            fixture["key"].as_str().unwrap(),
            "registration",
            "route",
            "event",
            &preview,
        )
        .unwrap();
        let second = encrypt_preview(
            fixture["key"].as_str().unwrap(),
            "registration",
            "route",
            "event",
            &preview,
        )
        .unwrap();
        assert_ne!(first, second, "Each delivery attempt needs a fresh nonce");
        assert!(!first.contains("Question"));
        assert!(encrypt_preview("bad-key", "registration", "route", "event", &preview).is_none());
    }

    #[test]
    fn push_fixture_matches_http_contract() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/fixtures/push-v1.json"
        ))
        .unwrap();
        for definition in [
            "pushConfiguration",
            "pushRoute",
            "pushRegistration",
            "pushPresence",
        ] {
            crate::tests::validate_http_contract(definition, &fixture[definition]);
        }
    }
}
