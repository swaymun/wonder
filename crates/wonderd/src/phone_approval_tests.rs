//! Synthetic paired-phone requests; no live Bot or model work is started.

use super::*;
use axum::{
    body::{to_bytes, Body},
    http::Request,
};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use serde_json::{json, Value};
use tower::ServiceExt;

struct PhoneFixture {
    dir: tempfile::TempDir,
    state: AppState,
    key: SigningKey,
}

impl PhoneFixture {
    async fn new() -> Self {
        let (dir, state) = ingestion::tests::fixture().await;
        let key = SigningKey::from_slice(&[11_u8; 32]).unwrap();
        let point = key.verifying_key().to_sec1_point(false);
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        state.pairing.lock().await.restore_device(
            "owner".into(),
            wonder_api::pairing_protocol::DevicePublicKeyJwk {
                kty: "EC".into(),
                crv: "P-256".into(),
                x: b64.encode(point.x().unwrap()),
                y: b64.encode(point.y().unwrap()),
            },
            false,
            None,
        );
        Self { dir, state, key }
    }

    async fn seed(&self, id: &str, method: &str, mut params: Value) {
        params["threadId"] = json!("thread");
        params["turnId"] = json!("turn");
        params["itemId"] = json!(id);
        self.state
            .store
            .insert_pending_approval(id, method, &params.to_string(), "now")
            .await
            .unwrap();
    }

    async fn body(&self, id: &str, decision: Value, response: Option<Value>) -> Value {
        let approval = self.state.store.approval(id).await.unwrap().unwrap();
        let mut body = json!({
            "decision": decision, "actionNonce": approval.action_nonce,
            "expectedState": "pending", "idempotencyKey": format!("resolve-{id}"),
            "issuedAtMs": now_ms(), "signature": ""
        });
        if let Some(response) = response {
            body["responseJson"] = json!(response.to_string());
        }
        self.sign(id, &mut body);
        body
    }

    fn sign(&self, id: &str, body: &mut Value) {
        let request: ApprovalResolution = serde_json::from_value(body.clone()).unwrap();
        let hash = hex::encode(Sha256::digest(canonical_approval_body(&request).as_bytes()));
        let path = format!("/api/v1/approvals/{id}/resolve");
        let transcript = ActionTranscript {
            action: "approval.resolve",
            target: &path,
            body_sha256: &hash,
            action_nonce: &request.action_nonce,
            session_binding: "phone-session",
            device_id: "owner",
            host_installation_id: &self.state.host_installation_id,
            issued_at_ms: request.issued_at_ms,
            expected_state: &request.expected_state,
        };
        let signature: Signature = self.key.sign(&transcript.to_bytes());
        body["signature"] =
            json!(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(signature.to_bytes()));
    }

    async fn post(&self, id: &str, body: Value) -> (StatusCode, String) {
        let app = Router::new()
            .route(
                "/api/v1/approvals/{approval_id}/resolve",
                post(resolve_approval),
            )
            .layer(Extension(AuthenticatedDevice {
                device_id: "owner".into(),
                session_binding: "phone-session".into(),
            }))
            .with_state(self.state.clone());
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/v1/approvals/{id}/resolve"))
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let body = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
        (status, String::from_utf8(body.to_vec()).unwrap())
    }

    async fn expect_status(&self, id: &str, body: Value, status: StatusCode) {
        let (actual, error) = self.post(id, body).await;
        assert_eq!(actual, status, "approval {id}: {error}");
    }

    async fn assert_forwarded(&self, id: &str, expected: Value) {
        let stored = self.state.store.approval(id).await.unwrap().unwrap();
        assert_eq!(stored.state, "resolved");
        assert_eq!(
            serde_json::from_str::<Value>(stored.resolution_json.as_deref().unwrap()).unwrap(),
            expected
        );
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let responses =
                    std::fs::read_to_string(self.dir.path().join("responses")).unwrap_or_default();
                let matches = responses
                    .lines()
                    .filter_map(|line| serde_json::from_str::<Value>(line).ok())
                    .filter(|response| response["id"] == json!(id))
                    .collect::<Vec<_>>();
                if !matches.is_empty() {
                    assert_eq!(matches.len(), 1, "must forward each approval only once");
                    assert_eq!(matches[0]["result"], expected);
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }

    async fn assert_pending(&self, id: &str) {
        let stored = self.state.store.approval(id).await.unwrap().unwrap();
        assert_eq!(stored.state, "pending");
        assert!(stored.resolution_json.is_none());
    }

    async fn shutdown(self) {
        self.state.app_server.lock().await.shutdown().await.unwrap();
    }
}

#[test]
fn phone_summary_preserves_consent_constraints_without_runtime_secrets() {
    let schema = json!({
        "type": "object", "required": ["format", "amount"], "additionalProperties": false,
        "properties": {
            "format": {"type": "string", "oneOf": [{"const": "png", "title": "PNG"}, {"const": "jpeg", "title": "JPEG"}]},
            "amount": {"type": "integer", "minimum": 1, "maximum": 4, "default": 2},
            "tags": {"type": "array", "items": {"type": "string", "enum": ["a", "b"]}, "minItems": 1, "maxItems": 2},
            "name": {"type": "string", "minLength": 2, "maxLength": 40, "pattern": "^[a-z]+$"}
        }
    });
    let permissions = json!({"fileSystem": {"read": ["/approved"], "globScanMaxDepth": 3}, "network": {"enabled": true}});
    let decision =
        json!({"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["git", "status"]}});
    let params = json!({
        "requestedSchema": schema, "mode": "form", "message": "Choose an export",
        "url": "https://service.example/approve", "grantRoot": "/approved",
        "permissions": permissions, "additionalPermissions": permissions,
        "availableDecisions": ["acceptForSession", decision],
        "networkApprovalContext": {"host": "service.example", "protocol": "https", "secret": "omit"},
        "_wonderRuntimeId": "private-runtime", "_wonderRequestId": 42, "token": "omit"
    });
    let summary = redact_approval_params("mcpServer/elicitation/request", &params);
    for key in [
        "requestedSchema",
        "mode",
        "message",
        "url",
        "grantRoot",
        "permissions",
        "additionalPermissions",
        "availableDecisions",
    ] {
        assert_eq!(
            summary[key], params[key],
            "consent field {key} must survive"
        );
    }
    assert_eq!(
        summary["networkApprovalContext"],
        json!({"host": "service.example", "protocol": "https"})
    );
    for key in ["_wonderRuntimeId", "_wonderRequestId", "token"] {
        assert!(summary.get(key).is_none());
    }
    permission_modes::tests::assert_http_contract(
        "approvalSummary",
        &json!({
            "approvalId": "phone-form", "conversationId": "bot", "method": "mcpServer/elicitation/request",
            "params": summary, "actionNonce": "nonce", "resolutionIdempotencyKey": null
        }),
    );
    let oversized = json!({"type": "object", "description": "x".repeat(64 * 1024)});
    assert!(redact_approval_params(
        "mcpServer/elicitation/request",
        &json!({"requestedSchema": oversized})
    )
    .get("requestedSchema")
    .is_none());
}

#[tokio::test]
async fn phone_forwards_advertised_session_and_structured_command_decisions() {
    let fixture = PhoneFixture::new().await;
    let decisions = [
        json!("acceptForSession"),
        json!({"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["git", "status"]}}),
        json!({"applyNetworkPolicyAmendment": {"network_policy_amendment": {"host": "service.example", "action": "allow"}}}),
    ];
    for (method_index, method) in [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
    ]
    .iter()
    .enumerate()
    {
        for (decision_index, decision) in decisions.iter().enumerate() {
            let id = format!("command-{method_index}-{decision_index}");
            fixture
                .seed(
                    &id,
                    method,
                    json!({"availableDecisions": [decision, "decline"]}),
                )
                .await;
            let body = fixture.body(&id, decision.clone(), None).await;
            fixture
                .expect_status(&id, body, StatusCode::NO_CONTENT)
                .await;
            fixture
                .assert_forwarded(&id, json!({"decision": decision}))
                .await;
        }
    }
    fixture
        .seed(
            "not-advertised",
            "item/commandExecution/requestApproval",
            json!({"availableDecisions": ["accept", "decline"]}),
        )
        .await;
    let body = fixture
        .body("not-advertised", json!("acceptForSession"), None)
        .await;
    fixture
        .expect_status("not-advertised", body, StatusCode::BAD_REQUEST)
        .await;
    fixture.assert_pending("not-advertised").await;
    fixture.shutdown().await;
}

#[test]
fn phone_canonical_signature_body_keeps_structured_decisions_and_utf8() {
    let request = ApprovalResolution {
        decision: json!({"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["tool", "a/b", "café", "line\nbreak"]}}),
        action_nonce: "nonce".into(),
        expected_state: "pending".into(),
        idempotency_key: "key".into(),
        issued_at_ms: 123,
        signature: "not part of body".into(),
        response_json: Some(r#"{"city":"Montréal","count":2}"#.into()),
    };
    assert_eq!(
        canonical_approval_body(&request),
        r#"[{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["tool","a/b","café","line\nbreak"]}},"nonce","pending","key","{\"city\":\"Montréal\",\"count\":2}"]"#
    );
}

#[tokio::test]
async fn phone_permission_grants_stay_within_requested_paths_network_and_depth() {
    let fixture = PhoneFixture::new().await;
    let requested = json!({"fileSystem": {
        "read": ["/approved"], "write": ["/approved/output"], "globScanMaxDepth": 3,
        "entries": [{"access": "read", "path": {"type": "glob_pattern", "pattern": "/approved/*.txt"}}]
    }, "network": {"enabled": false}});
    fixture
        .seed(
            "permissions",
            "item/permissions/requestApproval",
            json!({"permissions": requested}),
        )
        .await;
    for permissions in [
        json!({"fileSystem": {"read": ["/other"]}}),
        json!({"fileSystem": {"write": ["/approved"]}}),
        json!({"fileSystem": {"globScanMaxDepth": 4}}),
        json!({"fileSystem": {"entries": [{"access": "write", "path": {"type": "glob_pattern", "pattern": "/approved/*.txt"}}]}}),
        json!({"network": {"enabled": true}}),
    ] {
        let body = fixture
            .body(
                "permissions",
                json!("accept"),
                Some(json!({"permissions": permissions, "scope": "turn"})),
            )
            .await;
        fixture
            .expect_status("permissions", body, StatusCode::BAD_REQUEST)
            .await;
        fixture.assert_pending("permissions").await;
    }
    let granted = json!({"permissions": {"fileSystem": {"read": ["/approved"], "globScanMaxDepth": 2}}, "scope": "session"});
    let body = fixture
        .body(
            "permissions",
            json!("acceptForSession"),
            Some(granted.clone()),
        )
        .await;
    fixture
        .expect_status("permissions", body, StatusCode::NO_CONTENT)
        .await;
    fixture.assert_forwarded("permissions", granted).await;
    fixture
        .seed(
            "network-narrow",
            "item/permissions/requestApproval",
            json!({"permissions": {"network": {"enabled": true}}}),
        )
        .await;
    let narrowed = json!({"permissions": {"network": {"enabled": false}}, "scope": "turn"});
    let body = fixture
        .body("network-narrow", json!("accept"), Some(narrowed.clone()))
        .await;
    fixture
        .expect_status("network-narrow", body, StatusCode::NO_CONTENT)
        .await;
    fixture.assert_forwarded("network-narrow", narrowed).await;
    fixture.shutdown().await;
}

#[tokio::test]
async fn phone_permission_decline_and_cancel_never_grant_access() {
    let fixture = PhoneFixture::new().await;
    for decision in ["decline", "cancel"] {
        fixture
            .seed(
                decision,
                "item/permissions/requestApproval",
                json!({"permissions": {"network": {"enabled": true}}}),
            )
            .await;
        for response in [
            json!({"permissions": {"network": {"enabled": true}}, "scope": "turn"}),
            json!({"permissions": {}, "scope": "session"}),
            json!({"permissions": {}, "scope": "turn", "strictAutoReview": true}),
        ] {
            let body = fixture
                .body(decision, json!(decision), Some(response))
                .await;
            fixture
                .expect_status(decision, body, StatusCode::BAD_REQUEST)
                .await;
            fixture.assert_pending(decision).await;
        }
        let response = json!({"permissions": {}, "scope": "turn"});
        let body = fixture
            .body(decision, json!(decision), Some(response.clone()))
            .await;
        fixture
            .expect_status(decision, body, StatusCode::NO_CONTENT)
            .await;
        fixture.assert_forwarded(decision, response).await;
    }
    fixture.shutdown().await;
}

#[tokio::test]
async fn phone_mcp_form_and_url_requests_accept_decline_and_cancel() {
    let fixture = PhoneFixture::new().await;
    for mode in ["form", "url"] {
        for action in ["accept", "decline", "cancel"] {
            let id = format!("mcp-{mode}-{action}");
            fixture.seed(&id, "mcpServer/elicitation/request", json!({
                "serverName": "synthetic", "mode": mode, "url": "https://service.example/approve",
                "requestedSchema": {"type": "object", "required": ["count"], "properties": {"count": {"type": "integer", "minimum": 1}}}
            })).await;
            let mut response = json!({"action": action});
            if mode == "form" && action == "accept" {
                response["content"] = json!({"count": 2});
            }
            if action != "accept" {
                let body = fixture
                    .body(
                        &id,
                        json!(action),
                        Some(json!({"action": action, "content": {"count": 2}})),
                    )
                    .await;
                fixture
                    .expect_status(&id, body, StatusCode::BAD_REQUEST)
                    .await;
                fixture.assert_pending(&id).await;
                // Explicit null and omitted content are both valid non-disclosure responses.
                if mode == "url" {
                    response["content"] = Value::Null;
                }
            }
            let body = fixture
                .body(&id, json!(action), Some(response.clone()))
                .await;
            fixture
                .expect_status(&id, body, StatusCode::NO_CONTENT)
                .await;
            fixture.assert_forwarded(&id, response).await;
        }
    }
    fixture.shutdown().await;
}

#[tokio::test]
async fn phone_mcp_rejects_missing_mistyped_and_out_of_bounds_answers() {
    let fixture = PhoneFixture::new().await;
    let schema = json!({
        "type": "object", "required": ["count", "format", "enabled"], "additionalProperties": false,
        "properties": {
            "count": {"type": "integer", "minimum": 1, "maximum": 4},
            "format": {"type": "string", "enum": ["png", "jpeg"]},
            "enabled": {"type": "boolean"}
        }
    });
    for mode in ["form", "openai/form", "openaiForm"] {
        let id = mode.replace('/', "-");
        fixture
            .seed(
                &id,
                "mcpServer/elicitation/request",
                json!({"mode": mode, "serverName": "synthetic", "requestedSchema": schema}),
            )
            .await;
        for content in [
            json!({}),
            json!({"count": "2", "format": "png", "enabled": true}),
            json!({"count": 1.5, "format": "png", "enabled": true}),
            json!({"count": 0, "format": "png", "enabled": true}),
            json!({"count": 5, "format": "png", "enabled": true}),
            json!({"count": 2, "format": "gif", "enabled": true}),
            json!({"count": 2, "format": "png", "enabled": "true"}),
            json!({"count": 2, "format": "png", "enabled": true, "unrequested": "value"}),
        ] {
            let body = fixture
                .body(
                    &id,
                    json!("accept"),
                    Some(json!({"action": "accept", "content": content})),
                )
                .await;
            fixture
                .expect_status(&id, body, StatusCode::BAD_REQUEST)
                .await;
            fixture.assert_pending(&id).await;
        }
        let response =
            json!({"action": "accept", "content": {"count": 2, "format": "png", "enabled": false}});
        let body = fixture
            .body(&id, json!("accept"), Some(response.clone()))
            .await;
        fixture
            .expect_status(&id, body, StatusCode::NO_CONTENT)
            .await;
        fixture.assert_forwarded(&id, response).await;
    }
    fixture.shutdown().await;
}

#[tokio::test]
async fn phone_mcp_url_and_unsupported_forms_cannot_smuggle_answers() {
    let fixture = PhoneFixture::new().await;
    fixture.seed("url-content", "mcpServer/elicitation/request", json!({"mode": "url", "serverName": "synthetic", "url": "https://service.example/approve"})).await;
    let body = fixture
        .body(
            "url-content",
            json!("accept"),
            Some(json!({"action": "accept", "content": {"token": "not a form"}})),
        )
        .await;
    fixture
        .expect_status("url-content", body, StatusCode::BAD_REQUEST)
        .await;
    fixture.assert_pending("url-content").await;
    let response = json!({"action": "accept", "content": null});
    let body = fixture
        .body("url-content", json!("accept"), Some(response.clone()))
        .await;
    fixture
        .expect_status("url-content", body, StatusCode::NO_CONTENT)
        .await;
    fixture.assert_forwarded("url-content", response).await;
    for (id, params) in [
        ("missing-schema", json!({"mode": "form"})),
        (
            "external-metaschema",
            json!({"mode": "form", "requestedSchema": {"$schema": "https://untrusted.invalid/meta.json", "type": "object"}}),
        ),
        ("unknown-mode", json!({"mode": "future-verification"})),
        (
            "external-schema",
            json!({"mode": "form", "requestedSchema": {"type": "object", "$ref": "https://untrusted.invalid/schema.json"}}),
        ),
    ] {
        fixture
            .seed(id, "mcpServer/elicitation/request", params)
            .await;
        let body = fixture
            .body(
                id,
                json!("accept"),
                Some(json!({"action": "accept", "content": {}})),
            )
            .await;
        fixture
            .expect_status(id, body, StatusCode::BAD_REQUEST)
            .await;
        fixture.assert_pending(id).await;
        let response = json!({"action": "decline"});
        let body = fixture
            .body(id, json!("decline"), Some(response.clone()))
            .await;
        fixture
            .expect_status(id, body, StatusCode::NO_CONTENT)
            .await;
        fixture.assert_forwarded(id, response).await;
    }
    fixture.shutdown().await;
}

#[tokio::test]
async fn phone_can_decline_an_unregistered_dynamic_tool_without_executing_it() {
    let fixture = PhoneFixture::new().await;
    fixture.seed("unregistered", "item/tool/call", json!({"tool": "unknown", "callId": "unknown-call", "arguments": {"secret": "not executed"}})).await;
    for response in [
        json!({"success": true, "contentItems": []}),
        json!({"success": false, "contentItems": [{"type": "inputText", "text": "untrusted"}]}),
    ] {
        let body = fixture
            .body("unregistered", json!("respond"), Some(response))
            .await;
        fixture
            .expect_status("unregistered", body, StatusCode::BAD_REQUEST)
            .await;
        fixture.assert_pending("unregistered").await;
    }
    let response = json!({"success": false, "contentItems": []});
    let body = fixture
        .body("unregistered", json!("respond"), Some(response.clone()))
        .await;
    fixture
        .expect_status("unregistered", body, StatusCode::NO_CONTENT)
        .await;
    fixture.assert_forwarded("unregistered", response).await;
    assert!(!fixture.dir.path().join("executions").exists());
    fixture.shutdown().await;
}

#[tokio::test]
async fn phone_signature_binds_form_content_and_replay_cannot_forward_twice() {
    let fixture = PhoneFixture::new().await;
    fixture
        .seed(
            "signed-form",
            "mcpServer/elicitation/request",
            json!({
                "serverName": "synthetic", "mode": "form",
                "requestedSchema": {"type": "object", "properties": {"choice": {"type": "string"}}}
            }),
        )
        .await;
    let response = json!({"action": "accept", "content": {"choice": "first"}});
    let body = fixture
        .body("signed-form", json!("accept"), Some(response.clone()))
        .await;
    let mut tampered = body.clone();
    tampered["responseJson"] =
        json!(json!({"action": "accept", "content": {"choice": "second"}}).to_string());
    fixture
        .expect_status("signed-form", tampered, StatusCode::UNAUTHORIZED)
        .await;
    fixture.assert_pending("signed-form").await;
    let mut wrong_nonce = body.clone();
    wrong_nonce["actionNonce"] = json!("different-nonce");
    fixture.sign("signed-form", &mut wrong_nonce);
    fixture
        .expect_status("signed-form", wrong_nonce, StatusCode::PRECONDITION_FAILED)
        .await;
    fixture.assert_pending("signed-form").await;
    let mut expired = body.clone();
    expired["issuedAtMs"] = json!(now_ms() - 120_000);
    fixture.sign("signed-form", &mut expired);
    fixture
        .expect_status("signed-form", expired, StatusCode::PRECONDITION_FAILED)
        .await;
    fixture.assert_pending("signed-form").await;
    assert!(!fixture.dir.path().join("responses").exists());
    fixture
        .expect_status("signed-form", body.clone(), StatusCode::NO_CONTENT)
        .await;
    fixture
        .expect_status("signed-form", body, StatusCode::CONFLICT)
        .await;
    fixture.assert_forwarded("signed-form", response).await;
    fixture.shutdown().await;
}
