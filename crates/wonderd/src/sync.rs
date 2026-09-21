//! Snapshot/replay transport reads committed storage; broadcast is only a wakeup.
use super::*;
use axum::extract::ws::{Message, WebSocket};

/// Read before fetching independent projections. The client invalidates every
/// old scope before installing this checkpoint, then replays strictly after it.
pub(super) async fn checkpoint(State(state): State<AppState>) -> Response {
    match state.store.committed_sequence(&state.host_epoch).await {
        Ok(sequence) => Json(serde_json::json!({
            "hostEpoch": state.host_epoch, "lastSequence": sequence,
            "hostInstallationId": state.host_installation_id
        }))
        .into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "Chats could not be refreshed. Try again.",
        )
            .into_response(),
    }
}

pub(super) async fn stream_events(
    mut socket: WebSocket,
    state: AppState,
    session_token: Option<String>,
    local_capability: bool,
) {
    // Subscribe before authentication/replay so a revocation cannot race the
    // setup window and leave a live socket authorized after its device is
    // revoked.
    let mut revocations = state.revocations.subscribe();
    let subscription = match socket.recv().await {
        Some(Ok(Message::Text(text))) => serde_json::from_str::<EventSubscription>(&text).ok(),
        _ => None,
    };
    let Some(subscription) = subscription else {
        return;
    };
    if !local_capability {
        let Some(session_token) = session_token else {
            return;
        };
        let Some(csrf_token) = subscription.csrf_token.as_deref() else {
            return;
        };
        let device_id = {
            let pairing = state.pairing.lock().await;
            let Ok(device_id) = pairing.verify_session(&session_token, Some(csrf_token), now_ms())
            else {
                return;
            };
            device_id
        };
        if device_id != subscription.device_id {
            return;
        }
        let Some(challenge_id) = subscription.challenge_id.as_deref() else {
            return;
        };
        let Some(signature) = subscription.signature.as_deref() else {
            return;
        };
        let mut pairing = state.pairing.lock().await;
        if pairing
            .verify_fresh_challenge(challenge_id, &device_id, signature, now_ms())
            .is_err()
        {
            return;
        }
    }
    let mut receiver = state.events.subscribe();
    if subscription.host_epoch != state.host_epoch {
        send_resync(&mut socket, &state, ResyncReason::EpochChanged).await;
        return;
    }
    let mut last_sent = subscription.last_sequence;
    let mut last_acknowledged = subscription.last_sequence;
    let mut poll = tokio::time::interval(std::time::Duration::from_millis(100));
    loop {
        tokio::select! {
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Text(text))) => {
                    if let Ok(ack) = serde_json::from_str::<EventAcknowledgement>(&text) {
                        if ack.message_type == "ack"
                            && ack.host_epoch == state.host_epoch
                            && ack.sequence >= last_acknowledged
                            && ack.sequence <= last_sent
                        {
                            last_acknowledged = ack.sequence;
                        }
                    }
                }
                Some(Ok(Message::Close(_))) | None => return,
                Some(Ok(_)) | Some(Err(_)) => return,
            },
            _ = poll.tick() => {
                if !send_committed_events(&mut socket, &state, &mut last_sent).await { return; }
            },
            wakeup = receiver.recv() => {
                if matches!(wakeup, Err(tokio::sync::broadcast::error::RecvError::Closed)) { return; }
                // Broadcast order and lag do not determine delivery order.
                if !send_committed_events(&mut socket, &state, &mut last_sent).await { return; }
            },
            revoked = revocations.recv() => match revoked {
                Ok(device_id) if device_id == subscription.device_id => return,
                Ok(_) => {},
                Err(_) => return,
            },
        }
    }
}

async fn send_committed_events(
    socket: &mut WebSocket,
    state: &AppState,
    last_sent: &mut u64,
) -> bool {
    let events = match state
        .store
        .replay_batch(&state.host_epoch, *last_sent)
        .await
    {
        Ok(wonder_store::ReplayBatch::Events(events)) => events,
        Ok(wonder_store::ReplayBatch::Resync(reason)) => {
            send_resync(socket, state, reason).await;
            return false;
        }
        Err(_) => {
            send_resync(socket, state, ResyncReason::ReplayWindowExpired).await;
            return false;
        }
    };
    for event in events {
        let Ok(payload) = serde_json::to_string(&event) else {
            return false;
        };
        if socket.send(Message::Text(payload.into())).await.is_err() {
            return false;
        }
        *last_sent = event.sequence;
    }
    true
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct EventSubscription {
    device_id: String,
    host_epoch: String,
    last_sequence: u64,
    csrf_token: Option<String>,
    challenge_id: Option<String>,
    signature: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct EventAcknowledgement {
    #[serde(rename = "type")]
    message_type: String,
    host_epoch: String,
    sequence: u64,
}

async fn send_resync(socket: &mut WebSocket, state: &AppState, reason: ResyncReason) {
    let envelope = HostEventEnvelope {
        event_id: uuid::Uuid::new_v4().to_string(),
        host_epoch: state.host_epoch.clone(),
        sequence: match state.store.committed_sequence(&state.host_epoch).await {
            Ok(sequence) => sequence,
            Err(_) => return,
        },
        occurred_at: time::OffsetDateTime::now_utc()
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_else(|_| state.started_at.clone()),
        request_id: None,
        device_id: None,
        conversation_id: None,
        message_id: None,
        thread_id: None,
        turn_id: None,
        item_id: None,
        approval_id: None,
        event: WonderEvent::ResyncRequired { reason },
    };
    let _ = socket
        .send(Message::Text(
            serde_json::to_string(&envelope).unwrap_or_default().into(),
        ))
        .await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::{
        tungstenite::{client::IntoClientRequest, Message as ClientMessage},
        MaybeTlsStream, WebSocketStream,
    };
    type Client = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

    #[tokio::test]
    async fn checkpoint_requires_auth_and_reads_committed_head() {
        use tower::ServiceExt;
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        let unauthenticated = router(state.clone())
            .oneshot(
                axum::http::Request::builder()
                    .uri("/api/v1/sync/checkpoint")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(unauthenticated.status(), StatusCode::FORBIDDEN);
        state
            .store
            .set_conversation_thread("bot", "thread", None, "now")
            .await
            .unwrap();
        let _runtime_busy = state.app_server.lock().await;
        let response = router(state.clone())
            .oneshot(
                axum::http::Request::builder()
                    .uri("/api/v1/sync/checkpoint")
                    .header("x-wonder-loopback-capability", "test")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), 10000)
            .await
            .unwrap();
        let result: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        crate::tests::validate_http_contract("readCheckpoint", &result);
        assert_eq!(result["hostEpoch"], "epoch");
        assert_eq!(
            result["lastSequence"],
            state.store.committed_sequence("epoch").await.unwrap()
        );
        assert_eq!(result["hostInstallationId"], state.host_installation_id);
    }

    async fn connect(
        state: &AppState,
        epoch: &str,
        cursor: u64,
    ) -> (Client, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = router(state.clone());
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let mut request = format!("ws://{addr}/api/v1/events")
            .into_client_request()
            .unwrap();
        request
            .headers_mut()
            .insert("x-wonder-loopback-capability", "test".parse().unwrap());
        let (mut socket, _) = tokio_tungstenite::connect_async(request).await.unwrap();
        socket.send(ClientMessage::Text(serde_json::json!({"deviceId":"test-device", "hostEpoch":epoch, "lastSequence":cursor}).to_string().into())).await.unwrap();
        (socket, server)
    }

    async fn receive(socket: &mut Client) -> HostEventEnvelope {
        let message = tokio::time::timeout(std::time::Duration::from_secs(2), socket.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        serde_json::from_str(message.to_text().unwrap()).unwrap()
    }

    #[tokio::test]
    async fn http_snapshot_uses_committed_cursor_without_waiting_for_runtime_history() {
        use tower::ServiceExt;
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        state
            .store
            .set_conversation_thread("bot", "thread", None, "now")
            .await
            .unwrap();
        let _runtime_busy = state.app_server.lock().await;
        let response = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            router(state.clone()).oneshot(
                axum::http::Request::builder()
                    .uri("/api/v1/conversations/bot")
                    .header("x-wonder-loopback-capability", "test")
                    .body(Body::empty())
                    .unwrap(),
            ),
        )
        .await
        .expect("snapshot must not wait for App Server")
        .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), 1_000_000)
            .await
            .unwrap();
        let snapshot: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        crate::tests::validate_http_contract("conversationSnapshot", &snapshot);
        assert_eq!(snapshot["hostEpoch"], "epoch");
        assert_eq!(
            snapshot["lastSequence"],
            state.store.committed_sequence("epoch").await.unwrap()
        );
        assert_eq!(snapshot["codexThreadId"], "thread");
    }

    #[tokio::test]
    async fn websocket_reads_durable_order_despite_missing_and_reversed_wakeups() {
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        let (mut client, server) = connect(&state, "epoch", 0).await;
        // Projection writes don't send broadcasts. The durable journal still streams them.
        state
            .store
            .set_conversation_thread("bot", "thread", None, "now")
            .await
            .unwrap();
        let first = receive(&mut client).await;
        assert_eq!(first.sequence, 1);
        assert!(
            matches!(first.event, WonderEvent::Activity { ref category, .. } if category == "projection_changed")
        );
        let second = publish_event(
            &state,
            WonderEvent::HostStatus {
                state: "ready".into(),
            },
        )
        .await
        .unwrap();
        assert_eq!(receive(&mut client).await.sequence, second.sequence);
        let _ = state.events.send(second.clone());
        let _ = state.events.send(first);
        let third = publish_event(
            &state,
            WonderEvent::HostStatus {
                state: "ready".into(),
            },
        )
        .await
        .unwrap();
        assert_eq!(receive(&mut client).await.sequence, third.sequence);
        // Reconnect after 1 replays 2,3 exactly once, irrespective of wakeups.
        let (mut reconnected, replay_server) = connect(&state, "epoch", 1).await;
        assert_eq!(receive(&mut reconnected).await.sequence, second.sequence);
        assert_eq!(receive(&mut reconnected).await.sequence, third.sequence);
        let _ = state.revocations.send("test-device".into());
        let closed = tokio::time::timeout(std::time::Duration::from_secs(2), reconnected.next())
            .await
            .unwrap();
        assert!(
            closed.is_none() || matches!(closed, Some(Ok(ClientMessage::Close(_))) | Some(Err(_)))
        );
        server.abort();
        replay_server.abort();
    }

    #[tokio::test]
    async fn websocket_resyncs_future_empty_epoch_and_interior_gaps_without_partial_replay() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let schema: serde_json::Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/schemas/wonder-websocket-v1.json"
        ))
        .unwrap();
        let validator = jsonschema::validator_for(&schema).unwrap();
        for (epoch, cursor) in [("old", 0), ("epoch", u64::MAX)] {
            let (mut client, server) = connect(&state, epoch, cursor).await;
            let event = receive(&mut client).await;
            assert!(matches!(event.event, WonderEvent::ResyncRequired { .. }));
            assert_eq!(event.sequence, 0);
            assert!(validator.is_valid(&serde_json::to_value(event).unwrap()));
            server.abort();
        }
        for _ in 0..3 {
            publish_event(
                &state,
                WonderEvent::HostStatus {
                    state: "ready".into(),
                },
            )
            .await
            .unwrap();
        }
        let pool = sqlx::SqlitePool::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        sqlx::query("DELETE FROM sync_journal WHERE sequence = 2")
            .execute(&pool)
            .await
            .unwrap();
        let (mut client, server) = connect(&state, "epoch", 0).await;
        let event = receive(&mut client).await;
        assert!(matches!(
            event.event,
            WonderEvent::ResyncRequired {
                reason: ResyncReason::ReplayWindowExpired
            }
        ));
        assert_eq!(event.sequence, 3);
        server.abort();
    }
}
