use super::*;
use axum::body::to_bytes;
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use std::time::{Duration, Instant};

#[tokio::test]
async fn file_changes_use_selected_workspace_and_repair_legacy_history() {
    let store = wonder_store::Store::connect("sqlite::memory:")
        .await
        .unwrap();
    store
        .upsert_bot(
            "bot",
            "Bot",
            "Assistant",
            "Help",
            "/bot-home",
            "test",
            None,
            None,
            "now",
        )
        .await
        .unwrap();
    let chat = store
        .ensure_bot_workspace("bot", "Bot", "now")
        .await
        .unwrap();
    let mut bot = store.bot("bot").await.unwrap().unwrap();
    bot.working_directory = Some("/selected/workspace".into());
    store.update_managed_bot(&bot, [false; 3]).await.unwrap();
    store.start_event_epoch("epoch").await.unwrap();
    let workspace = store
        .conversation_execution_directory(&chat)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(workspace, "/selected/workspace");
    let raw = serde_json::json!({"id":"edit", "type":"fileChange", "status":"completed", "changes":[
        {"path":"/selected/workspace/Tests/BotStartupTests.swift", "kind":{"type":"add"}, "diff":"import XCTest\nlet test = true\n"},
        {"path":"/selected/workspace-other/private.swift", "kind":{"type":"update"}, "diff":"@@ -1 +1 @@\n-old\n+new"}
    ]});
    let legacy = thread_item_upsert_detail_with_authority("turn", &raw, "failed", 2, None).unwrap();
    let mut legacy: serde_json::Value = serde_json::from_str(&legacy).unwrap();
    legacy["item"]
        .as_object_mut()
        .unwrap()
        .remove("fileChangeVersion");
    let mut event = HostEventEnvelope {
        event_id: "old".into(),
        host_epoch: "epoch".into(),
        sequence: 0,
        occurred_at: "1000".into(),
        conversation_id: Some(chat.clone()),
        thread_id: Some("thread".into()),
        turn_id: Some("turn".into()),
        request_id: None,
        device_id: None,
        message_id: None,
        item_id: Some("edit".into()),
        approval_id: None,
        event: WonderEvent::Activity {
            category: "thread_item_upsert".into(),
            state: "updated".into(),
            detail: Some(legacy.to_string()),
        },
    };
    store.commit_event(&mut event).await.unwrap();
    assert!(store
        .needs_file_change_repair(&chat, 100_000)
        .await
        .unwrap());
    assert!(store
        .claim_history_refresh(&chat, "repair", 100_000)
        .await
        .unwrap());
    assert!(!store
        .needs_file_change_repair(&chat, 100_001)
        .await
        .unwrap());
    let repaired = thread_item_upsert_detail("turn", &raw, "completed", Some(&workspace)).unwrap();
    let mut repaired: serde_json::Value = serde_json::from_str(&repaired).unwrap();
    repaired["historyRefresh"] = serde_json::json!(true);
    event.event_id = "repair".into();
    event.occurred_at = "2000".into();
    event.event = WonderEvent::Activity {
        category: "thread_item_upsert".into(),
        state: "updated".into(),
        detail: Some(repaired.to_string()),
    };
    store.commit_event(&mut event).await.unwrap();
    let page = store
        .conversation_history_page("epoch", &chat, None, 100)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(page.workspace_path, workspace);
    let projection = conversation_thread_projection_with_items(
        None,
        &page.messages,
        &page.assistant_messages,
        &page.events,
        &[],
        Some(&page.workspace_path),
    );
    let item = &projection.turns[0].items[0];
    assert_eq!(
        item.state, "failed",
        "repair must not rewrite the original outcome"
    );
    assert_eq!(item.created_at, "1000");
    assert_eq!(item.payload["paths"][0], "Tests/BotStartupTests.swift");
    assert_eq!(item.payload["paths"][1], "[path outside workspace]");
    assert_eq!(
        item.payload["diffs"][0]["diff"],
        "+import XCTest\n+let test = true"
    );
    assert_eq!(item.payload["additions"], 3);
    assert_eq!(item.payload["deletions"], 1);
    assert_eq!(item.payload["fileChangeVersion"], 1);
    store
        .update_history_refresh(&chat, "repair", "completed", 100_002, None)
        .await
        .unwrap();
    assert!(!store
        .needs_file_change_repair(&chat, 999_999)
        .await
        .unwrap());
    bot.working_directory = None;
    store.update_managed_bot(&bot, [false; 3]).await.unwrap();
    assert_eq!(
        store
            .conversation_execution_directory(&chat)
            .await
            .unwrap()
            .as_deref(),
        Some("/bot-home")
    );
}

#[tokio::test]
async fn history_pages_retain_turn_lifecycle_outside_the_item_page() {
    let store = wonder_store::Store::connect("sqlite::memory:")
        .await
        .unwrap();
    store
        .upsert_bot(
            "chat",
            "Bot",
            "Assistant",
            "Help",
            "/tmp",
            "test",
            None,
            None,
            "now",
        )
        .await
        .unwrap();
    store.start_event_epoch("epoch").await.unwrap();
    let event = |id: &str, at: &str, event: WonderEvent| HostEventEnvelope {
        event_id: id.into(),
        host_epoch: "epoch".into(),
        sequence: 0,
        occurred_at: at.into(),
        conversation_id: Some("chat".into()),
        thread_id: Some("thread".into()),
        turn_id: Some("turn".into()),
        request_id: None,
        device_id: None,
        message_id: None,
        item_id: None,
        approval_id: None,
        event,
    };
    let item = |id: &str, status: &str| WonderEvent::Activity {
        category: "thread_item_upsert".into(),
        state: "updated".into(),
        detail: Some(
            serde_json::json!({
                "turnId": "turn", "itemId": id, "state": status, "lifecycleAuthority": 2,
                "item": {"id": id, "type": "commandExecution", "command": "test", "status": status}
            })
            .to_string(),
        ),
    };
    store
        .commit_event(&mut event(
            "start",
            "1700000000000",
            WonderEvent::MessageState {
                state: DeliveryState::AcceptedByCodex,
            },
        ))
        .await
        .unwrap();
    store
        .commit_event(&mut event(
            "failed-command",
            "1700000001000",
            item("failed-command", "failed"),
        ))
        .await
        .unwrap();
    store
        .commit_event(&mut event(
            "passed-command",
            "1700000002000",
            item("passed-command", "completed"),
        ))
        .await
        .unwrap();

    // Neither the failed command nor a successful command ends the response.
    let newest = store
        .conversation_history_page("epoch", "chat", None, 1)
        .await
        .unwrap()
        .unwrap();
    let older_cursor = newest.next_cursor.unwrap();
    for before in [None, Some(&older_cursor)] {
        let page = store
            .conversation_history_page("epoch", "chat", before, 1)
            .await
            .unwrap()
            .unwrap();
        let projection = conversation_thread_projection(
            None,
            &page.messages,
            &page.assistant_messages,
            &page.events,
        );
        assert_eq!(projection.turns.len(), 1);
        assert_eq!(projection.turns[0].status, "inProgress");
        assert_eq!(
            projection.turns[0].started_at.as_deref(),
            Some("1700000000000")
        );
        assert_eq!(
            projection.turns[0].items.len(),
            1,
            "lifecycle context must not expand the item page"
        );
    }

    // An older page must use the latest terminal status, even though the end
    // boundary is newer than its cursor. Preserve actual failure and stop too.
    for (state, expected) in [
        (DeliveryState::Completed, "completed"),
        (DeliveryState::Failed, "failed"),
        (DeliveryState::Interrupted, "interrupted"),
    ] {
        store
            .commit_event(&mut event(
                expected,
                "1700000003000",
                WonderEvent::MessageState { state },
            ))
            .await
            .unwrap();
        let page = store
            .conversation_history_page("epoch", "chat", Some(&older_cursor), 1)
            .await
            .unwrap()
            .unwrap();
        let projection = conversation_thread_projection(
            None,
            &page.messages,
            &page.assistant_messages,
            &page.events,
        );
        let turn = &projection.turns[0];
        assert_eq!(projection.turns.len(), 1);
        assert_eq!(turn.status, expected);
        assert_eq!(turn.started_at.as_deref(), Some("1700000000000"));
        assert_eq!(turn.completed_at.as_deref(), Some("1700000003000"));
        assert_eq!(turn.items.len(), 1);
        assert_eq!(
            turn.items[0].state, "failed",
            "command outcome remains visible"
        );
    }
}

#[test]
fn item_outcomes_do_not_invent_a_turn_lifecycle() {
    for status in ["failed", "completed", "interrupted", "running"] {
        let projection = conversation_thread_projection_with_items(
            Some("thread".into()),
            &[],
            &[],
            &[],
            &[AppServerThreadItem {
                turn_id: "turn".into(),
                item: serde_json::json!({"id":"command", "type":"commandExecution", "command":"test", "status":status}),
            }],
            None,
        );
        assert_eq!(
            projection.turns[0].status, "unknown",
            "item status: {status}"
        );
    }
}

#[test]
fn cursors_are_versioned_scoped_and_survive_restart() {
    let cursor = wonder_store::HistoryCursor {
        sort_ms: 1700000000000,
        sequence: 123,
    };
    let token = encode_history_cursor("chat", &cursor);
    assert_eq!(
        decode_history_cursor(Some(&token), "chat")
            .unwrap()
            .unwrap()
            .sequence,
        123
    );
    assert!(decode_history_cursor(Some(&token), "other").is_err());
    assert!(decode_history_cursor(Some("invalid"), "chat").is_err());
    assert!(decode_history_cursor(Some(&"x".repeat(2049)), "chat").is_err());
}

async fn wait_for(path: &std::path::Path) {
    tokio::time::timeout(Duration::from_secs(3), async {
        while !path.exists() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn delayed_history_does_not_block_controls_or_local_pages() {
    let (dir, state) = crate::ingestion::tests::fixture().await;
    state
        .store
        .set_conversation_thread("bot", "thread", None, "now")
        .await
        .unwrap();
    let pool = sqlx::SqlitePool::connect(&format!(
        "sqlite://{}",
        dir.path().join("state.db").display()
    ))
    .await
    .unwrap();
    sqlx::query("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO messages(id,device_id,client_message_id,body,body_sha256,conversation_id,state,created_at) SELECT printf('history-%05d',x),'owner',printf('history-client-%05d',x),printf('%01024d',x),'hash','bot','completed',CAST(1600000000000+x AS TEXT) FROM n").execute(&pool).await.unwrap();
    pool.close().await;
    let wonder_store::MessageInsert::Inserted(message) = state
        .store
        .insert_message("owner", "active", "hello", "hash", "bot", "1700000000000")
        .await
        .unwrap()
    else {
        panic!("message");
    };
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
    let mut key_bytes = [0_u8; 32];
    key_bytes[31] = 1;
    let key = SigningKey::from_slice(&key_bytes).unwrap();
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
    // Synthetic authenticated-device fixture; the production approval handler
    // still validates the P-256 signature, nonce, state and durable receipt.
    let app = Router::new()
        .route(
            "/api/v1/conversations/{conversation_id}/turns/{turn_id}/interrupt",
            post(interrupt_turn),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/turns/{turn_id}/steer",
            post(steer_turn),
        )
        .route(
            "/api/v1/approvals/{approval_id}/resolve",
            post(resolve_approval),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/history",
            get(conversation_snapshot),
        )
        .layer(Extension(AuthenticatedDevice {
            device_id: "owner".into(),
            session_binding: "test-session".into(),
        }))
        .layer(middleware::from_fn(
            |request: Request<Body>, next: Next| async move {
                let shaped = request.headers().contains_key("x-test-shaped-network");
                let bytes = request
                    .headers()
                    .get(header::CONTENT_LENGTH)
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(0);
                if shaped {
                    tokio::time::sleep(Duration::from_micros(50_000 + bytes * 8 / 20)).await;
                }
                let response = next.run(request).await;
                if !shaped {
                    return response;
                }
                let (parts, body) = response.into_parts();
                let body = to_bytes(body, 2_000_000).await.unwrap();
                tokio::time::sleep(Duration::from_micros(50_000 + body.len() as u64 * 8 / 20))
                    .await;
                Response::from_parts(parts, Body::from(body))
            },
        ))
        .with_state(state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    // Keep restarting the stalled read before the RPC timeout. Each control
    // sample is taken only after the synthetic runtime confirms history arrived.
    let mut measurements = serde_json::Map::new();
    for shaped in [false, true] {
        for control in ["stop", "steer", "approval"] {
            std::fs::write(dir.path().join("delay-history"), "").unwrap();
            let _ = std::fs::remove_file(dir.path().join("history-waiting"));
            let read_state = state.clone();
            let history = tokio::spawn(async move {
                hydrate_app_server_turn_items(&read_state, "thread", "turn").await
            });
            wait_for(&dir.path().join("history-waiting")).await;
            let mut samples = vec![];
            for i in 0..105 {
                assert!(!history.is_finished());
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
                let (path, body, expected) = match control {
                    "stop" => {
                        let turn = uuid::Uuid::new_v4().to_string();
                        let wonder_store::MessageInsert::Inserted(stop_message) = state
                            .store
                            .insert_message(
                                "owner",
                                &turn,
                                "stop me",
                                "hash",
                                "bot",
                                "1700000000000",
                            )
                            .await
                            .unwrap()
                        else {
                            panic!("stop message");
                        };
                        state
                            .store
                            .update_message_delivery(
                                &stop_message.id,
                                "accepted_by_codex",
                                Some("thread"),
                                Some(&turn),
                            )
                            .await
                            .unwrap();
                        (
                            format!("/api/v1/conversations/bot/turns/{turn}/interrupt"),
                            serde_json::json!({}),
                            StatusCode::NO_CONTENT,
                        )
                    }
                    "steer" => (
                        "/api/v1/conversations/bot/turns/turn/steer".into(),
                        serde_json::json!({"deviceId":"owner","clientMessageId":uuid::Uuid::new_v4().to_string(),"body":"Please continue","expectedTurnId":"turn"}),
                        StatusCode::ACCEPTED,
                    ),
                    _ => {
                        let id = uuid::Uuid::new_v4().to_string();
                        state.store.insert_pending_approval(&id,"item/commandExecution/requestApproval",&serde_json::json!({"threadId":"thread","turnId":"turn","itemId":"command","availableDecisions":["accept","decline"]}).to_string(),"now").await.unwrap();
                        let approval = state
                            .store
                            .list_pending_approvals()
                            .await
                            .unwrap()
                            .into_iter()
                            .find(|a| a.approval_id == id)
                            .unwrap();
                        let mut request = ApprovalResolution {
                            decision: serde_json::json!("accept"),
                            action_nonce: approval.action_nonce.clone(),
                            expected_state: "pending".into(),
                            idempotency_key: uuid::Uuid::new_v4().to_string(),
                            issued_at_ms: now_ms(),
                            signature: String::new(),
                            response_json: None,
                        };
                        let path = format!("/api/v1/approvals/{id}/resolve");
                        let hash = hex::encode(Sha256::digest(
                            canonical_approval_body(&request).as_bytes(),
                        ));
                        let transcript = ActionTranscript {
                            action: "approval.resolve",
                            target: &path,
                            body_sha256: &hash,
                            action_nonce: &approval.action_nonce,
                            session_binding: "test-session",
                            device_id: "owner",
                            host_installation_id: &state.host_installation_id,
                            issued_at_ms: request.issued_at_ms,
                            expected_state: "pending",
                        };
                        let signature: Signature = key.sign(&transcript.to_bytes());
                        request.signature = b64.encode(signature.to_bytes());
                        (
                            path,
                            serde_json::json!({"decision":request.decision,"actionNonce":request.action_nonce,"expectedState":request.expected_state,"idempotencyKey":request.idempotency_key,"issuedAtMs":request.issued_at_ms,"signature":request.signature}),
                            StatusCode::NO_CONTENT,
                        )
                    }
                };

                let start = Instant::now();
                // A page read is concurrent with every control, on the same pool.
                let (response, page) = tokio::join!(
                    http_post(&base, &path, &body, shaped),
                    state
                        .store
                        .conversation_history_page("epoch", "bot", None, 100)
                );
                let (status, text) = response;
                assert_eq!(status, expected, "{control}: {text}");
                assert!(page.unwrap().is_some());
                if i >= 5 {
                    samples.push(start.elapsed().as_secs_f64() * 1000.0);
                }
            }
            std::fs::remove_file(dir.path().join("delay-history")).unwrap();
            assert!(history.await.unwrap().is_some());
            let mut sorted = samples.clone();
            sorted.sort_by(f64::total_cmp);
            eprintln!(
                "CONTROL_{control}_SHAPED_{shaped}_P95_MS={}; SAMPLES_MS={samples:?}",
                sorted[94]
            );
            assert!(sorted[94] <= if shaped { 1000.0 } else { 250.0 });
            measurements.insert(
                format!("{control}_shaped_{shaped}"),
                serde_json::json!({"p95Ms":sorted[94],"samplesMs":samples}),
            );
        }
    }
    eprintln!(
        "CONTROL_MEASUREMENTS={}",
        serde_json::Value::Object(measurements)
    );
    server.abort();
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn refresh_receipt_is_prompt_and_transport_restart_fails_old_reads() {
    let (dir, state) = crate::ingestion::tests::fixture().await;
    state
        .store
        .set_conversation_thread("bot", "thread", None, "now")
        .await
        .unwrap();
    std::fs::write(dir.path().join("delay-history"), "").unwrap();
    let start = Instant::now();
    assert_eq!(
        refresh_history(State(state.clone()), Path("bot".into()))
            .await
            .status(),
        StatusCode::ACCEPTED
    );
    assert!(start.elapsed() < Duration::from_millis(250));
    wait_for(&dir.path().join("history-waiting")).await;
    let old = state.app_server.lock().await.rpc();
    state
        .app_server
        .lock()
        .await
        .restart(state.launch_config.lock().await.clone())
        .await
        .unwrap();
    assert!(old
        .request("turn/interrupt", serde_json::json!({}))
        .await
        .is_err());
    tokio::time::timeout(Duration::from_secs(3), async {
        while state
            .store
            .history_refresh_status("bot", now_ms() as i64)
            .await
            .unwrap()["state"]
            == "refreshing"
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        state
            .store
            .history_refresh_status("bot", now_ms() as i64)
            .await
            .unwrap()["state"],
        "failed"
    );
    std::fs::remove_file(dir.path().join("delay-history")).unwrap();
    assert_eq!(
        refresh_history(State(state.clone()), Path("bot".into()))
            .await
            .status(),
        StatusCode::ACCEPTED
    );
    tokio::time::timeout(Duration::from_secs(3), async {
        while state
            .store
            .history_refresh_status("bot", now_ms() as i64)
            .await
            .unwrap()["state"]
            == "refreshing"
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        state
            .store
            .history_refresh_status("bot", now_ms() as i64)
            .await
            .unwrap()["state"],
        "completed"
    );
    state.app_server.lock().await.shutdown().await.unwrap();
}

async fn http_post(
    base: &str,
    path: &str,
    body: &serde_json::Value,
    shaped: bool,
) -> (StatusCode, String) {
    let mut socket = tokio::net::TcpStream::connect(base.strip_prefix("http://").unwrap())
        .await
        .unwrap();
    let payload = body.to_string();
    let shape = if shaped {
        "x-test-shaped-network: 1\r\n"
    } else {
        ""
    };
    let request=format!("POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{shape}\r\n{payload}",payload.len());
    socket.write_all(request.as_bytes()).await.unwrap();
    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), socket.read_to_end(&mut response))
        .await
        .unwrap()
        .unwrap();
    let text = String::from_utf8(response).unwrap();
    let status =
        StatusCode::from_u16(text.split_whitespace().nth(1).unwrap().parse().unwrap()).unwrap();
    (status, text)
}

#[tokio::test]
async fn recovery_reads_beyond_thirty_two_pages_without_collecting_other_turns() {
    let (dir, state) = crate::ingestion::tests::fixture().await;
    std::fs::write(dir.path().join("long-history"), "").unwrap();
    let items = hydrate_app_server_turn_items(&state, "thread", "turn")
        .await
        .unwrap();
    assert_eq!(items.len(), 100);
    assert!(items.iter().all(|item| item.turn_id == "turn"));
    assert_eq!(
        std::fs::read_to_string(dir.path().join("requests"))
            .unwrap()
            .lines()
            .filter(|line| *line == "thread/items/list")
            .count(),
        100
    );
    state.app_server.lock().await.shutdown().await.unwrap();
}
