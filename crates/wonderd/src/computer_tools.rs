//! One computer action per correlated runtime request. Full Access is an owner
//! grant; scoped turns still use the signed approval path.
use super::*;
use serde_json::{json, Value};

pub(super) const TOOL: &str = "wonder_computer_use";

pub(super) fn arguments(params: &Value) -> Result<Value, String> {
    if params.get("tool").and_then(Value::as_str) != Some(TOOL) {
        return Err("This computer tool is not registered by Wonder.".into());
    }
    let args = match params.get("arguments") {
        Some(Value::String(s)) if s.len() <= 40 * 1024 => serde_json::from_str(s)
            .map_err(|_| "Computer action arguments must be a JSON object.")?,
        Some(Value::Object(_)) => params["arguments"].clone(),
        _ => return Err("Computer action arguments must be a JSON object.".into()),
    };
    let object = args
        .as_object()
        .ok_or("Computer action arguments must be an object.")?;
    let action = args
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let fields: &[&str] = match action {
        "status" | "screenshot" => &["action"],
        "click"
            if ["x", "y"].iter().all(|k| {
                args.get(k)
                    .and_then(Value::as_f64)
                    .is_some_and(f64::is_finite)
            }) =>
        {
            &["action", "x", "y"]
        }
        "type"
            if args
                .get("text")
                .and_then(Value::as_str)
                .is_some_and(|s| s.len() <= 32768) =>
        {
            &["action", "text"]
        }
        "key"
            if args
                .get("keyCode")
                .and_then(Value::as_u64)
                .is_some_and(|n| n <= 65535)
                && args
                    .get("modifiers")
                    .is_none_or(|v| v.as_u64().is_some_and(|n| n & !(31 << 16) == 0)) =>
        {
            &["action", "keyCode", "modifiers"]
        }
        "focusApp"
            if args
                .get("bundleId")
                .and_then(Value::as_str)
                .is_some_and(|s| !s.is_empty() && s.len() <= 256) =>
        {
            &["action", "bundleId"]
        }
        _ => return Err("Use a supported computer action with all required fields.".into()),
    };
    if object.keys().any(|key| !fields.contains(&key.as_str())) {
        return Err("This computer action contains unsupported fields.".into());
    }
    Ok(args)
}

/// Recheck scope at execution, including queued automatic actions and owner
/// approvals. A settings change can narrow an accepted turn, never widen it.
pub(super) async fn scope(state: &AppState, params: &Value) -> Result<bool, String> {
    arguments(params)?;
    if !state.computer_use_enabled || state.computer_use_bin.is_none() {
        return Err("Computer use is unavailable on this Mac.".into());
    }
    let thread = params
        .get("threadId")
        .and_then(Value::as_str)
        .ok_or("Missing computer request thread.")?;
    let turn = params
        .get("turnId")
        .and_then(Value::as_str)
        .ok_or("Missing computer request turn.")?;
    let runtime = params
        .get("_wonderRuntimeId")
        .and_then(Value::as_str)
        .ok_or("Missing computer request runtime.")?;
    if !params
        .get("callId")
        .and_then(Value::as_str)
        .is_some_and(|id| !id.is_empty() && id.len() <= 256)
    {
        return Err("Missing computer request identity.".into());
    }
    let message = state
        .store
        .message_for_codex_thread_and_turn(thread, turn)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("This computer request no longer belongs to active work.")?;
    let dispatch_message = state
        .store
        .dispatched_message_for_turn(thread, turn)
        .await
        .map_err(|e| e.to_string())?
        .unwrap_or_else(|| message.clone());
    if !matches!(message.state.as_str(), "accepted_by_codex" | "streaming")
        || !state
            .ingestion
            .runtime_accepts_message(runtime, &dispatch_message.id)
    {
        return Err("This computer request expired when its turn ended.".into());
    }
    if state
        .store
        .conversation_thread(&message.conversation_id)
        .await
        .map_err(|e| e.to_string())?
        .as_deref()
        != Some(thread)
    {
        return Err("This conversation moved to another thread.".into());
    }
    let version = state
        .store
        .conversation_dynamic_tools_version(&message.conversation_id)
        .await
        .map_err(|e| e.to_string())?
        .unwrap_or_default();
    if !version.split('+').any(|v| {
        matches!(
            v,
            "wonder-computer-use-v1" | COMPUTER_USE_DYNAMIC_TOOLS_VERSION
        )
    }) {
        return Err(
            "Computer use was not registered for this conversation. Start a new message.".into(),
        );
    }
    let bot = bot_for_conversation(state, &message.conversation_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("This Bot is unavailable.")?;
    if bot.is_archived
        || !group_collaboration::allows_computer(state, &message.conversation_id, &bot.id).await?
    {
        return Err("Computer use is not allowed for this Bot's work.".into());
    }
    let context = state
        .store
        .dispatch_context(&dispatch_message.id)
        .await
        .map_err(|e| e.to_string())?
        .and_then(|s| serde_json::from_str::<Value>(&s).ok());
    Ok(context
        .as_ref()
        .and_then(|c| c.get("permissionProfile"))
        .and_then(Value::as_str)
        == Some(":danger-full-access")
        && bot.effective_permission_profile() == ":danger-full-access")
}

/// None keeps the ordinary approval flow. All automatic work runs outside the
/// dispatch lock so a slow helper cannot prevent turn cancellation or readiness.
pub(super) async fn route(state: &AppState, params: &Value) -> Option<bool> {
    let automatic = scope(state, params).await;
    if matches!(automatic, Ok(false)) {
        return None;
    }
    let runtime = params.get("_wonderRuntimeId")?.as_str()?;
    let raw_id = params.get("_wonderRequestId")?.clone();
    let id = format!(
        "{runtime}:{}",
        raw_id
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| raw_id.to_string())
    );
    let mut stored = params.clone();
    stored["_wonderAutomatic"] = json!(true);
    if state
        .store
        .insert_pending_approval(
            &id,
            "item/tool/call",
            &stored.to_string(),
            &now_ms().to_string(),
        )
        .await
        .is_err()
    {
        return Some(false);
    }
    let state = state.clone();
    tokio::spawn(async move {
        // Serialize all helper actions and manual resolutions. A request is
        // claimed durably before execution; replay never repeats input.
        let _guard = state.approval_lock.lock().await;
        if automatic_reply(&state, &id, &stored, automatic)
            .await
            .is_err()
        {
            // A persistence failure after executing input must still release
            // the runtime's tool call. Preserve the interrupted receipt and
            // never reset it to an executable request.
            if let Some(client) = state.ingestion.approval_client(&stored) {
                let rpc = client.lock().await.rpc();
                let response = dynamic_tool_response(Err("Wonder could not confirm this computer action. Inspect the screen before requesting another action.".into()));
                let _ = rpc.respond_value(raw_id, Some(response), None).await;
            }
            let _ = state
                .store
                .finish_approval_resolution(&id, "execution_unconfirmed", &now_ms().to_string())
                .await;
        }
    });
    Some(true)
}

/// Caller holds approval_lock and has durably saved an interrupted response
/// before reserving the call. Both automatic and signed owner paths use this.
pub(super) async fn execute_once(state: &AppState, params: &Value, approval_id: &str) -> Value {
    let args = match arguments(params) {
        Ok(args) => args,
        Err(error) => return dynamic_tool_response(Err(error)),
    };
    let key = hex::encode(Sha256::digest(
        json!([
            params["_wonderRuntimeId"],
            params["threadId"],
            params["turnId"],
            params["callId"]
        ])
        .to_string(),
    ));
    let hash = hex::encode(Sha256::digest(args.to_string()));
    let reserved = state
        .store
        .reserve_computer_tool_call(&key, &hash, approval_id)
        .await;
    match reserved {
        Ok((true, _, _)) => dynamic_tool_response(run_computer_use(state.computer_use_bin.as_deref().unwrap(), params).await),
        Ok((false, saved_hash, id)) if saved_hash == hash => {
            state.store.approval(&id).await.ok().flatten()
                .and_then(|a| a.resolution_json).and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_else(|| dynamic_tool_response(Err("The previous action has no confirmed result. Inspect the screen before requesting a new action.".into())))
        }
        Ok(_) => dynamic_tool_response(Err("This computer call was already used with different arguments.".into())),
        Err(_) => dynamic_tool_response(Err("The computer action could not be saved. No action was performed.".into())),
    }
}

async fn automatic_reply(
    state: &AppState,
    id: &str,
    params: &Value,
    initial_scope: Result<bool, String>,
) -> Result<(), String> {
    let Some(client) = state.ingestion.approval_client(params) else {
        return Ok(());
    };
    let rpc = client.lock().await.rpc();
    let Some(raw_id) = params.get("_wonderRequestId") else {
        return Ok(());
    };
    let claimed = state
        .store
        .begin_approval_resolution(id)
        .await
        .map_err(|e| e.to_string())?;
    let response = if let Some(saved) = claimed.as_ref().and_then(|a| a.resolution_json.as_deref())
    {
        serde_json::from_str(saved).map_err(|e| e.to_string())?
    } else if claimed.is_some() {
        let interrupted = dynamic_tool_response(Err("This computer action was interrupted. Inspect the screen before requesting another action.".into()));
        // Persist before touching the computer. If the process dies between
        // input and reply, retry returns this failure instead of repeating input.
        if !state
            .store
            .persist_approval_resolution_intent(id, id, id, &interrupted.to_string())
            .await
            .map_err(|e| e.to_string())?
        {
            return Ok(());
        }
        let params_json = params.to_string();
        let response = if claimed
            .as_ref()
            .is_some_and(|a| a.params_json != params_json)
        {
            dynamic_tool_response(Err(
                "This computer request was already used with different arguments.".into(),
            ))
        } else {
            match initial_scope {
                Err(error) => dynamic_tool_response(Err(error)),
                Ok(_) => match scope(state, params).await {
                    Ok(true) => execute_once(state, params, id).await,
                    Ok(false) => dynamic_tool_response(Err(
                        "The Bot's permissions changed. Request this action again for approval."
                            .into(),
                    )),
                    Err(error) => dynamic_tool_response(Err(error)),
                },
            }
        };
        if !state
            .store
            .persist_approval_resolution_intent(id, id, id, &response.to_string())
            .await
            .map_err(|e| e.to_string())?
        {
            return Ok(());
        }
        if let Some(image_url) = computer_use_screenshot_url(&response) {
            let message = state
                .store
                .message_for_codex_thread_and_turn(
                    params["threadId"].as_str().unwrap_or_default(),
                    params["turnId"].as_str().unwrap_or_default(),
                )
                .await
                .ok()
                .flatten();
            let _ = publish_event_with_context(
                state,
                WonderEvent::ComputerUseScreenshot { image_url },
                EventContext {
                    conversation_id: message.as_ref().map(|m| m.conversation_id.clone()),
                    message_id: message.map(|m| m.id),
                    thread_id: string_field(params, "threadId"),
                    turn_id: string_field(params, "turnId"),
                    item_id: string_field(params, "callId"),
                    ..EventContext::default()
                },
            )
            .await;
        }
        response
    } else {
        let Some(saved) = state.store.approval(id).await.map_err(|e| e.to_string())? else {
            return Ok(());
        };
        let params_json = params.to_string();
        if saved.params_json != params_json {
            return Ok(());
        }
        match saved
            .resolution_json
            .and_then(|s| serde_json::from_str(&s).ok())
        {
            Some(response) => response,
            None => return Ok(()),
        }
    };
    rpc.respond_value(raw_id.clone(), Some(response), None)
        .await
        .map_err(|e| e.to_string())?;
    state
        .store
        .finish_approval_resolution(id, "full_access", &now_ms().to_string())
        .await
        .map_err(|e| e.to_string())
}

pub(super) async fn retire_completed(state: &AppState) -> Result<(), sqlx::Error> {
    for id in state
        .store
        .retire_completed_tool_approvals(&now_ms().to_string())
        .await?
    {
        let _ = publish_event_with_context(
            state,
            WonderEvent::ApprovalResolved {
                request_id: id.clone(),
                decision: "turn_ended".into(),
            },
            EventContext {
                approval_id: Some(id.clone()),
                request_id: Some(id),
                ..EventContext::default()
            },
        )
        .await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::{to_bytes, Body},
        http::Request,
    };
    use p256::ecdsa::{signature::Signer, Signature, SigningKey};
    use std::{fs, os::unix::fs::PermissionsExt};
    use tower::ServiceExt;

    async fn fixture(full: bool) -> (tempfile::TempDir, AppState, Value, String) {
        let (dir, mut state) = ingestion::tests::fixture().await;
        let helper = dir.path().join("computer.py");
        fs::write(&helper, r#"#!/usr/bin/env python3
import json,sys,os
for line in sys.stdin:
 r=json.loads(line)
 if r['method']=='stop': break
 with open(os.path.join(os.path.dirname(__file__),'executions'),'a') as log: log.write(r['method']+'\n')
 print(json.dumps({'id':r['id'],'result':{'action':r['method'],'mimeType':'image/png','imageBase64':'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII='}}),flush=True)
"#).unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();
        state.computer_use_enabled = true;
        state.computer_use_bin = Some(helper);
        let health = state.app_server.lock().await.rpc().health();
        state
            .ingestion
            .register(&state.app_server, health.clone(), None);
        let mut bot = state.store.bot("bot").await.unwrap().unwrap();
        bot.permission_mode = Some(if full { "full-access" } else { "workspace" }.into());
        bot.approval_mode = Some(
            if full {
                "full-access"
            } else {
                "ask-for-approval"
            }
            .into(),
        );
        state
            .store
            .update_managed_bot(&bot, [false; 3])
            .await
            .unwrap();
        state
            .store
            .ensure_conversation_metadata("bot", "bot", "Bot", "now")
            .await
            .unwrap();
        state
            .store
            .set_conversation_thread("bot", "thread", None, "now")
            .await
            .unwrap();
        state
            .store
            .mark_conversation_dynamic_tools("bot", COMPUTER_USE_DYNAMIC_TOOLS_VERSION)
            .await
            .unwrap();
        let wonder_store::MessageInsert::Inserted(message) = state
            .store
            .insert_message("owner", "client", "test", "hash", "bot", "now")
            .await
            .unwrap()
        else {
            panic!()
        };
        assert!(state
            .store
            .claim_message_for_dispatch(&message.id)
            .await
            .unwrap());
        state.store.begin_dispatch_submission_with_context(&message.id, "thread", Some(&json!({"permissionProfile":if full {":danger-full-access"} else {":workspace"}}).to_string())).await.unwrap();
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
        let params = json!({"tool":TOOL,"arguments":{"action":"screenshot"},"threadId":"thread","turnId":"turn","callId":"call","_wonderRuntimeId":health.id(),"_wonderRequestId":2});
        (dir, state, params, message.id)
    }
    async fn response(
        state: &AppState,
        method: &str,
        path: &str,
        body: Value,
        local: bool,
    ) -> (StatusCode, Value) {
        let mut request = Request::builder()
            .method(method)
            .uri(path)
            .header("content-type", "application/json");
        if local {
            request = request.header("x-wonder-loopback-capability", &state.loopback_capability);
        }
        let result = router(state.clone())
            .oneshot(request.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap();
        let status = result.status();
        let bytes = to_bytes(result.into_body(), 16 * 1024 * 1024)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }
    async fn signed_resolution(
        state: &AppState,
        path: &str,
        mut body: Value,
        valid: bool,
    ) -> StatusCode {
        let key = SigningKey::from_slice(&[7_u8; 32]).unwrap();
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
        let request: ApprovalResolution = serde_json::from_value(body.clone()).unwrap();
        let hash = hex::encode(Sha256::digest(canonical_approval_body(&request).as_bytes()));
        let transcript = ActionTranscript {
            action: "approval.resolve",
            target: path,
            body_sha256: &hash,
            action_nonce: &request.action_nonce,
            session_binding: "session",
            device_id: "owner",
            host_installation_id: &state.host_installation_id,
            issued_at_ms: request.issued_at_ms,
            expected_state: &request.expected_state,
        };
        let signature: Signature = key.sign(&transcript.to_bytes());
        body["signature"] = json!(if valid {
            b64.encode(signature.to_bytes())
        } else {
            "invalid".into()
        });
        let app = Router::new()
            .route(
                "/api/v1/approvals/{approval_id}/resolve",
                post(resolve_approval),
            )
            .layer(Extension(AuthenticatedDevice {
                device_id: "owner".into(),
                session_binding: "session".into(),
            }))
            .with_state(state.clone());
        app.oneshot(
            Request::builder()
                .method("POST")
                .uri(path)
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap()
        .status()
    }
    async fn settled(state: &AppState, id: &str) -> wonder_store::StoredApproval {
        timeout(Duration::from_secs(10), async {
            loop {
                if let Some(a) = state.store.approval(id).await.unwrap() {
                    if a.state == "resolved" {
                        return a;
                    }
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap()
    }
    #[test]
    fn only_exact_supported_actions_are_executable() {
        for args in [
            json!({"action":"screenshot","handshake":"spoof"}),
            json!({"action":"click","x":1}),
            json!({"action":"key","keyCode":36,"modifiers":1}),
            json!({"action":"future"}),
        ] {
            assert!(arguments(&json!({"tool":TOOL,"arguments":args})).is_err());
        }
        assert!(arguments(&json!({"tool":"other","arguments":{"action":"screenshot"}})).is_err());
        assert_eq!(
            arguments(&json!({"tool":TOOL,"arguments":"{\"action\":\"screenshot\"}"})).unwrap(),
            json!({"action":"screenshot"})
        );
    }
    #[tokio::test]
    async fn stable_call_retries_with_new_transport_ids_never_repeat_input() {
        let (dir, state, mut params, _) = fixture(true).await;
        let runtime = params["_wonderRuntimeId"].as_str().unwrap().to_owned();
        for request in [2, 3, 4] {
            params["_wonderRequestId"] = json!(request);
            if request == 4 {
                params["arguments"] = json!({"action":"status"});
            }
            assert_eq!(route(&state, &params).await, Some(true));
            let saved = settled(&state, &format!("{runtime}:{request}")).await;
            let result: Value =
                serde_json::from_str(saved.resolution_json.as_deref().unwrap()).unwrap();
            assert_eq!(result["success"], request != 4);
        }
        assert_eq!(
            fs::read_to_string(dir.path().join("executions")).unwrap(),
            "screenshot\n"
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn reset_intents_and_conflicting_claims_cannot_execute_again() {
        let (dir, state, mut params, _) = fixture(true).await;
        params["_wonderAutomatic"] = json!(true);
        let id = format!("{}:2", params["_wonderRuntimeId"].as_str().unwrap());
        state
            .store
            .insert_pending_approval(&id, "item/tool/call", &params.to_string(), "now")
            .await
            .unwrap();
        state
            .store
            .begin_approval_resolution(&id)
            .await
            .unwrap()
            .unwrap();
        let saved = dynamic_tool_response(Err("previous action outcome uncertain".into()));
        assert!(state
            .store
            .persist_approval_resolution_intent(&id, &id, &id, &saved.to_string())
            .await
            .unwrap());
        state.store.reset_approval_resolution(&id).await.unwrap();
        automatic_reply(&state, &id, &params, Ok(true))
            .await
            .unwrap();
        assert!(!dir.path().join("executions").exists());
        assert_eq!(
            state
                .store
                .approval(&id)
                .await
                .unwrap()
                .unwrap()
                .resolution_json,
            Some(saved.to_string())
        );
        let other = format!("{}:3", params["_wonderRuntimeId"].as_str().unwrap());
        params["_wonderRequestId"] = json!(3);
        state
            .store
            .insert_pending_approval(&other, "item/tool/call", &params.to_string(), "now")
            .await
            .unwrap();
        params["arguments"] = json!({"action":"status"});
        automatic_reply(&state, &other, &params, Ok(true))
            .await
            .unwrap();
        assert!(!dir.path().join("executions").exists());
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn guide_inherits_turn_grant_but_downgrade_and_interrupt_remain_authoritative() {
        let (_dir, state, params, original) = fixture(true).await;
        state.ingestion.register(
            &state.app_server,
            state.app_server.lock().await.rpc().health(),
            Some(original),
        );
        let MessageInsert::Inserted(guide) = state
            .store
            .insert_message("owner", "guide", "guide", "hash", "bot", "zz")
            .await
            .unwrap()
        else {
            panic!()
        };
        state
            .store
            .update_message_delivery(&guide.id, "accepted_by_codex", Some("thread"), Some("turn"))
            .await
            .unwrap();
        assert!(scope(&state, &params).await.unwrap());
        let mut bot = state.store.bot("bot").await.unwrap().unwrap();
        bot.permission_mode = Some("workspace".into());
        state
            .store
            .update_managed_bot(&bot, [false; 3])
            .await
            .unwrap();
        assert!(!scope(&state, &params).await.unwrap());
        let id = format!("{}:2", params["_wonderRuntimeId"].as_str().unwrap());
        state
            .store
            .insert_pending_approval(&id, "item/tool/call", &params.to_string(), "now")
            .await
            .unwrap();
        state
            .store
            .update_message_delivery(&guide.id, "interrupted", None, None)
            .await
            .unwrap();
        assert!(scope(&state, &params).await.is_err());
        retire_completed(&state).await.unwrap();
        assert_eq!(
            state.store.approval(&id).await.unwrap().unwrap().state,
            "resolved"
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn full_access_returns_image_without_approval_and_replay_does_not_repeat_action() {
        let (dir, state, params, _) = fixture(true).await;
        let id = format!("{}:2", params["_wonderRuntimeId"].as_str().unwrap());
        let _dispatch = state.dispatch_lock.lock().await;
        assert!(process_app_server_notification(&state, json!({"method":"item/tool/call", "id":2, "_wonderRuntimeId":params["_wonderRuntimeId"], "params":params}), false).await);
        let saved = settled(&state, &id).await;
        let answer: Value = serde_json::from_str(saved.resolution_json.as_ref().unwrap()).unwrap();
        assert_eq!(answer["success"], true);
        assert!(computer_use_screenshot_url(&answer).is_some());
        assert_eq!(
            response(&state, "GET", "/api/v1/approvals", Value::Null, true)
                .await
                .1,
            json!([])
        );
        automatic_reply(
            &state,
            &id,
            &serde_json::from_str(&saved.params_json).unwrap(),
            Ok(true),
        )
        .await
        .unwrap();
        assert_eq!(
            fs::read_to_string(dir.path().join("executions")).unwrap(),
            "screenshot\n"
        );
        let replies = fs::read_to_string(dir.path().join("responses")).unwrap();
        assert!(replies.contains("inputImage"));
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    #[ignore = "Captures the real Mac screen; run explicitly with WONDER_TEST_COMPUTER_HELPER after owner authorization."]
    async fn installed_helper_returns_real_screenshot_to_runtime() {
        let (_dir, mut state, params, _) = fixture(true).await;
        state.computer_use_bin = Some(
            std::env::var_os("WONDER_TEST_COMPUTER_HELPER")
                .expect("explicit helper path")
                .into(),
        );
        let id = format!("{}:2", params["_wonderRuntimeId"].as_str().unwrap());
        assert!(process_app_server_notification(&state, json!({"method":"item/tool/call","id":2,"_wonderRuntimeId":params["_wonderRuntimeId"],"params":params}), false).await);
        let saved = settled(&state, &id).await;
        let response: Value =
            serde_json::from_str(saved.resolution_json.as_deref().unwrap()).unwrap();
        let url = computer_use_screenshot_url(&response)
            .expect("real screenshot returned to the runtime");
        let png = base64::engine::general_purpose::STANDARD
            .decode(url.strip_prefix("data:image/png;base64,").unwrap())
            .unwrap();
        let image = image::load_from_memory(&png).unwrap();
        assert!(image.width() > 1 && image.height() > 1);
        assert_eq!(state.store.list_pending_approvals().await.unwrap().len(), 0);
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn scoped_turn_requires_owner_and_cancelled_turn_cannot_execute() {
        let (dir, state, params, message) = fixture(false).await;
        assert_eq!(route(&state, &params).await, None);
        // Raising current settings cannot widen the already accepted turn.
        let mut bot = state.store.bot("bot").await.unwrap().unwrap();
        bot.permission_mode = Some("full-access".into());
        state
            .store
            .update_managed_bot(&bot, [false; 3])
            .await
            .unwrap();
        assert!(!scope(&state, &params).await.unwrap());
        let id = format!("{}:2", params["_wonderRuntimeId"].as_str().unwrap());
        state
            .store
            .insert_pending_approval(&id, "item/tool/call", &params.to_string(), "now")
            .await
            .unwrap();
        let (_, approvals) = response(&state, "GET", "/api/v1/approvals", Value::Null, true).await;
        permission_modes::tests::assert_http_contract("approvalSummary", &approvals[0]);
        assert_eq!(
            approvals[0]["params"]["arguments"],
            json!({"action":"screenshot"})
        );
        let approval = state.store.approval(&id).await.unwrap().unwrap();
        let request = json!({"decision":"respond","actionNonce":approval.action_nonce,"expectedState":"pending","idempotencyKey":"choice","issuedAtMs":now_ms(),"signature":"","responseJson":"{\"success\":true,\"contentItems\":[]}"});
        let path = format!("/api/v1/approvals/{id}/resolve");
        assert!(!response(&state, "POST", &path, request.clone(), false)
            .await
            .0
            .is_success());
        assert!(!dir.path().join("executions").exists());
        state
            .store
            .update_message_delivery(&message, "interrupted", None, None)
            .await
            .unwrap();
        assert_eq!(
            signed_resolution(&state, &path, request, true).await,
            StatusCode::CONFLICT
        );
        assert!(!dir.path().join("executions").exists());
        assert_eq!(
            response(&state, "GET", "/api/v1/approvals", Value::Null, true)
                .await
                .1,
            json!([])
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn paired_owner_can_allow_or_decline_exact_action_only_once() {
        for allow in [false, true] {
            let (dir, state, params, _) = fixture(false).await;
            let id = format!("{}:2", params["_wonderRuntimeId"].as_str().unwrap());
            state
                .store
                .insert_pending_approval(&id, "item/tool/call", &params.to_string(), "now")
                .await
                .unwrap();
            let approval = state.store.approval(&id).await.unwrap().unwrap();
            let request = json!({"decision":"respond","actionNonce":approval.action_nonce,"expectedState":"pending","idempotencyKey":"choice","issuedAtMs":now_ms(),"signature":"","responseJson":json!({"success":allow,"contentItems":[]}).to_string()});
            let path = format!("/api/v1/approvals/{id}/resolve");
            assert_eq!(
                signed_resolution(&state, &path, request.clone(), false).await,
                StatusCode::UNAUTHORIZED
            );
            assert!(!dir.path().join("executions").exists());
            assert_eq!(
                signed_resolution(&state, &path, request.clone(), true).await,
                StatusCode::NO_CONTENT
            );
            assert_eq!(
                signed_resolution(&state, &path, request, true).await,
                StatusCode::CONFLICT
            );
            assert_eq!(dir.path().join("executions").exists(), allow);
            if allow {
                assert_eq!(
                    fs::read_to_string(dir.path().join("executions")).unwrap(),
                    "screenshot\n"
                );
            }
            state.app_server.lock().await.shutdown().await.unwrap();
        }
    }
}
