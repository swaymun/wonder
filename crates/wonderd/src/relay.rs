//! Experimental encrypted JSON API adapter. No listener or product enablement.
//!
//! Call only after a fresh endpoint handshake with a durably enrolled peer key.
//! Existing HTTP handlers remain the authority; transport delivery is not a receipt.
use super::*;
use tower::ServiceExt;
use wonder_relay::{EndpointConfig, Responder, MAX_FRAME_SIZE, MAX_PAYLOAD_SIZE};

/// Serve one ordered byte stream with pre-enrolled pins. The caller owns secure
/// key loading and outbound WSS bridging; this function opens no network port.
/// Every stream starts fresh and ends on any malformed, stale or revoked input.
pub async fn serve_stream<S>(
    state: &AppState,
    config: EndpointConfig<'_>,
    stream: &mut S,
) -> Result<(), &'static str>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let result = serve_stream_inner(state, config, stream).await;
    let _ = timeout(Duration::from_secs(1), stream.shutdown()).await;
    result
}

async fn serve_stream_inner<S>(
    state: &AppState,
    config: EndpointConfig<'_>,
    stream: &mut S,
) -> Result<(), &'static str>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    if config.context.host_identity != state.host_installation_id {
        return Err("wrong host");
    }
    let device_id = config.context.device_identity.to_owned();
    let mut revocations = state.revocations.subscribe();
    let first = read_packet(stream, 1024).await?;
    let (reply, mut session) =
        Responder::accept(config, &first).map_err(|_| "handshake rejected")?;
    write_packet(stream, &reply).await?;
    loop {
        let packet = tokio::select! {
            result = read_packet(stream, MAX_FRAME_SIZE - 4) => result?,
            revoked = revocations.recv() => match revoked {
                Ok(id) if id != device_id => continue,
                _ => return Err("device access unavailable"),
            },
        };
        let mut frame = (packet.len() as u32).to_be_bytes().to_vec();
        frame.extend_from_slice(&packet);
        let plaintext = session.open_frame(&frame).map_err(|_| "frame rejected")?;
        let request = serde_json::from_slice(&plaintext).map_err(|_| "request rejected")?;
        let response = dispatch_json(state, &device_id, request).await;
        let response = serde_json::to_vec(&response).map_err(|_| "response unavailable")?;
        if response.len() > MAX_PAYLOAD_SIZE {
            // Dispatch may have committed. Never turn this into an automatic retry.
            return Err("response unavailable; reconcile before retry");
        }
        let encrypted = session.seal_frame(&response).map_err(|_| "channel ended")?;
        timeout(Duration::from_secs(30), stream.write_all(&encrypted))
            .await
            .map_err(|_| "write timeout")?
            .map_err(|_| "stream closed")?;
    }
}

async fn read_packet<S: tokio::io::AsyncRead + Unpin>(
    stream: &mut S,
    maximum: usize,
) -> Result<Vec<u8>, &'static str> {
    timeout(Duration::from_secs(30), async {
        let length = stream.read_u32().await.map_err(|_| "stream closed")? as usize;
        if length == 0 || length > maximum {
            return Err("invalid packet size");
        }
        let mut bytes = vec![0; length];
        stream
            .read_exact(&mut bytes)
            .await
            .map_err(|_| "stream closed")?;
        Ok(bytes)
    })
    .await
    .map_err(|_| "read timeout")?
}

async fn write_packet<S: tokio::io::AsyncWrite + Unpin>(
    stream: &mut S,
    packet: &[u8],
) -> Result<(), &'static str> {
    timeout(Duration::from_secs(30), async {
        stream
            .write_u32(packet.len() as u32)
            .await
            .map_err(|_| "stream closed")?;
        stream.write_all(packet).await.map_err(|_| "stream closed")
    })
    .await
    .map_err(|_| "write timeout")?
}

/// JSON-only first slice. Binary uploads and the event socket need separate framing.
pub const MAX_BODY: usize = 24 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelayRequest {
    pub request_id: String,
    pub method: String,
    pub path: String,
    pub session_token: String,
    pub csrf_token: String,
    pub body: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelayResponse {
    pub request_id: String,
    pub status: u16,
    pub body: String,
}

/// Dispatch once. Errors after dispatch never imply that work is safe to repeat.
/// The request ID is correlation only: durable clientMessageId stays in the body.
pub async fn dispatch_json(
    state: &AppState,
    enrolled_device_id: &str,
    request: RelayRequest,
) -> RelayResponse {
    let respond = |status: StatusCode, body: &str| RelayResponse {
        request_id: request.request_id.clone(),
        status: status.as_u16(),
        body: body.to_owned(),
    };
    if request.request_id.is_empty()
        || request.request_id.len() > 128
        || request.body.len() > MAX_BODY
        || request.path.len() > 2048
        || request.session_token.len() > 512
        || request.csrf_token.len() > 512
    {
        return respond(StatusCode::BAD_REQUEST, "invalid relay request");
    }
    let Ok(uri) = request.path.parse::<axum::http::Uri>() else {
        return respond(StatusCode::BAD_REQUEST, "invalid relay path");
    };
    // Do not allow absolute URLs, authority, local-only pairing, upgrades, or
    // encoded path aliases. Origin/Host and all privilege headers are host-owned.
    if uri.scheme().is_some()
        || uri.authority().is_some()
        || !uri.path().starts_with("/api/v1/")
        || uri.path().contains('%')
        || uri.path().contains("..")
        || uri.path().contains("//")
        || uri.path().starts_with("/api/v1/pairing/")
        || uri.path() == "/api/v1/events"
        || uri.path().starts_with("/api/v1/asr/")
    {
        return respond(StatusCode::BAD_REQUEST, "unsupported relay path");
    }
    let method = match request.method.as_str() {
        "GET" => axum::http::Method::GET,
        "POST" => axum::http::Method::POST,
        "PUT" => axum::http::Method::PUT,
        "PATCH" => axum::http::Method::PATCH,
        "DELETE" => axum::http::Method::DELETE,
        _ => return respond(StatusCode::BAD_REQUEST, "unsupported relay method"),
    };
    // A valid cookie belonging to another device cannot borrow this peer's pin.
    let authenticated = state.pairing.lock().await.verify_session(
        &request.session_token,
        Some(&request.csrf_token),
        now_ms(),
    );
    if authenticated.as_deref() != Ok(enrolled_device_id) {
        return respond(StatusCode::UNAUTHORIZED, "device access unavailable");
    }
    let Some(origin) = current_public_origin(state).await else {
        return respond(StatusCode::SERVICE_UNAVAILABLE, "host unavailable");
    };
    let built = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::ORIGIN, origin)
        .header(header::CONTENT_TYPE, "application/json")
        .header(
            header::COOKIE,
            format!("__Host-wonder_session={}", request.session_token),
        )
        .header("x-wonder-csrf", &request.csrf_token)
        .body(Body::from(request.body.clone()));
    let Ok(built) = built else {
        return respond(StatusCode::BAD_REQUEST, "invalid relay credentials");
    };
    let response = match router(state.clone()).oneshot(built).await {
        Ok(response) => response,
        Err(never) => match never {},
    };
    let status = response.status();
    match axum::body::to_bytes(response.into_body(), MAX_BODY).await {
        Ok(bytes) => match String::from_utf8(bytes.to_vec()) {
            Ok(body) => respond(status, &body),
            Err(_) => respond(
                StatusCode::BAD_GATEWAY,
                "response unavailable; reconcile before retry",
            ),
        },
        Err(_) => respond(
            StatusCode::BAD_GATEWAY,
            "response unavailable; reconcile before retry",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn authorize(state: &AppState) {
        let mut pairing = state.pairing.lock().await;
        // Synthetic restored enrollment, never production enrollment evidence.
        pairing.restore_device(
            "owner".into(),
            DevicePublicKeyJwk {
                kty: "EC".into(),
                crv: "P-256".into(),
                x: String::new(),
                y: String::new(),
            },
            false,
            None,
        );
        pairing.restore_session(
            session_token_hash("relay-test-session"),
            "owner".into(),
            Sha256::digest(b"relay-test-csrf").into(),
            now_ms() + 60_000,
        );
    }

    fn request(path: &str) -> RelayRequest {
        RelayRequest {
            request_id: "transport-correlation".into(),
            method: "GET".into(),
            path: path.into(),
            session_token: "relay-test-session".into(),
            csrf_token: "relay-test-csrf".into(),
            body: String::new(),
        }
    }

    #[tokio::test]
    async fn existing_router_checks_device_session_and_revocation_on_each_request() {
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        authorize(&state).await;
        let path = "/api/v1/sync/checkpoint";
        let first = dispatch_json(&state, "owner", request(path)).await;
        assert_eq!(first.status, 200);
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&first.body).unwrap()["hostInstallationId"],
            "test"
        );
        assert_eq!(
            dispatch_json(&state, "different-device", request(path))
                .await
                .status,
            401
        );
        let mut wrong_csrf = request(path);
        wrong_csrf.csrf_token = "wrong".into();
        assert_eq!(dispatch_json(&state, "owner", wrong_csrf).await.status, 401);
        state.pairing.lock().await.revoke_device("owner");
        assert_eq!(
            dispatch_json(&state, "owner", request(path)).await.status,
            401
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn relay_cannot_reach_local_pairing_or_supply_privilege_headers() {
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        authorize(&state).await;
        for path in [
            "https://attacker.test/api/v1/bots",
            "//attacker.test/api/v1/bots",
            "/api/v1/pairing/offers",
            "/healthz",
            "/api/v1/events",
            "/api/v1/%70airing/offers",
            "/api/v1/../pairing/offers",
            "/api/v1/asr/jobs",
        ] {
            assert_eq!(
                dispatch_json(&state, "owner", request(path)).await.status,
                400,
                "{path}"
            );
        }
        let mut value = serde_json::to_value(request("/api/v1/bots")).unwrap();
        value["headers"] = serde_json::json!({"x-wonder-loopback-capability":"test"});
        assert!(serde_json::from_value::<RelayRequest>(value).is_err());
        let mut oversized = request("/api/v1/bots");
        oversized.body = "x".repeat(MAX_BODY + 1);
        assert_eq!(dispatch_json(&state, "owner", oversized).await.status, 400);
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn encrypted_stream_reconnects_with_new_keys_and_rechecks_revocation() {
        use wonder_relay::{Initiator, SessionContext, StaticKeyPair};
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        authorize(&state).await;
        let host = StaticKeyPair::generate().unwrap();
        let phone = StaticKeyPair::generate().unwrap();
        let context = SessionContext::new("test", "owner", "synthetic-route");
        let mut old_frame = Vec::new();
        for attempt in 0..3 {
            let (mut client, mut server) = tokio::io::duplex(128 * 1024);
            let host_config = EndpointConfig::new(host.private_key(), phone.public_key(), context);
            let phone_config = EndpointConfig::new(phone.private_key(), host.public_key(), context);
            let serving = serve_stream(&state, host_config, &mut server);
            let exchange = async {
                let (initiator, first) = Initiator::start(phone_config).unwrap();
                write_packet(&mut client, &first).await.unwrap();
                let second = read_packet(&mut client, 1024).await.unwrap();
                let mut session = initiator.finish(&second).unwrap();
                let frame = session
                    .seal_frame(&serde_json::to_vec(&request("/api/v1/sync/checkpoint")).unwrap())
                    .unwrap();
                if attempt == 1 {
                    // Captured ciphertext cannot cross a network/restart handshake.
                    client.write_all(&old_frame).await.unwrap();
                    client.shutdown().await.unwrap();
                    return;
                }
                if attempt == 2 {
                    state.pairing.lock().await.revoke_device("owner");
                }
                client.write_all(&frame).await.unwrap();
                let ciphertext = read_packet(&mut client, MAX_FRAME_SIZE - 4).await.unwrap();
                let mut reply = (ciphertext.len() as u32).to_be_bytes().to_vec();
                reply.extend_from_slice(&ciphertext);
                let response: RelayResponse =
                    serde_json::from_slice(&session.open_frame(&reply).unwrap()).unwrap();
                assert_eq!(response.status, if attempt == 2 { 401 } else { 200 });
                old_frame = frame;
                client.shutdown().await.unwrap();
            };
            let (result, ()) = tokio::join!(serving, exchange);
            assert_eq!(
                result,
                Err(if attempt == 1 {
                    "frame rejected"
                } else {
                    "stream closed"
                })
            );
        }
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn lost_response_and_store_reopen_keep_the_same_durable_submission() {
        let (dir, mut state) = crate::ingestion::tests::fixture().await;
        authorize(&state).await;
        let _ingestion = crate::ingestion::spawn(state.clone()).await;
        timeout(Duration::from_secs(5), async {
            while !state.ingestion.readiness(&state.store).await.ready {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let client_id = uuid::Uuid::new_v4().to_string();
        let send = || {
            let mut send = request("/api/v1/conversations/bot/messages");
            send.method = "POST".into();
            send.body = serde_json::json!({"deviceId":"owner", "clientMessageId":client_id, "body":"synthetic relay send"}).to_string();
            send
        };
        let discarded = dispatch_json(&state, "owner", send()).await;
        assert_eq!(discarded.status, 202, "{}", discarded.body);
        let first: serde_json::Value = serde_json::from_str(&discarded.body).unwrap();
        drop(discarded); // Model acceptance before the client receives its response.
        state.store = Store::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        let recovered = dispatch_json(&state, "owner", send()).await;
        assert_eq!(recovered.status, 202);
        let second: serde_json::Value = serde_json::from_str(&recovered.body).unwrap();
        assert_eq!(first, second);
        let stored = state
            .store
            .message_by_device_and_client_message_id("owner", &client_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(stored.client_message_id, client_id);
        let mut conflict = send();
        conflict.body = conflict
            .body
            .replace("synthetic relay send", "changed body");
        assert_eq!(dispatch_json(&state, "owner", conflict).await.status, 409);
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    /// Run only against the disposable local Worker configured by services/relay.
    #[tokio::test]
    #[ignore = "requires a disposable local Wrangler Worker; see services/relay/README.md"]
    async fn local_worker_carries_encrypted_authenticated_daemon_request() {
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};
        use wonder_relay::{Initiator, SessionContext, StaticKeyPair};
        let url = std::env::var("WONDER_RELAY_TEST_URL").expect("local Worker URL");
        let uri: axum::http::Uri = url.parse().unwrap();
        assert_eq!(uri.scheme_str(), Some("ws"));
        assert_eq!(uri.host(), Some("127.0.0.1"));
        assert!(uri.query().is_none());
        let route = uri.path().strip_prefix("/v1/relay/").unwrap();
        assert_eq!(route.len(), 43);
        let mut host_request = url.clone().into_client_request().unwrap();
        host_request
            .headers_mut()
            .insert("Authorization", "Bearer local-host-test".parse().unwrap());
        let (mut host_socket, _) = tokio_tungstenite::connect_async(host_request)
            .await
            .unwrap();
        let mut phone_request = url.into_client_request().unwrap();
        phone_request
            .headers_mut()
            .insert("Authorization", "Bearer local-device-test".parse().unwrap());
        let (mut phone_socket, _) = tokio_tungstenite::connect_async(phone_request)
            .await
            .unwrap();
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        authorize(&state).await;
        let host = StaticKeyPair::generate().unwrap();
        let phone = StaticKeyPair::generate().unwrap();
        let context = SessionContext::new("test", "owner", route);
        let host_task = async {
            let Message::Binary(first) = host_socket.next().await.unwrap().unwrap() else {
                panic!("binary handshake");
            };
            let (reply, mut session) = Responder::accept(
                EndpointConfig::new(host.private_key(), phone.public_key(), context),
                &first,
            )
            .unwrap();
            host_socket
                .send(Message::Binary(reply.into()))
                .await
                .unwrap();
            let Message::Binary(frame) = host_socket.next().await.unwrap().unwrap() else {
                panic!("encrypted frame");
            };
            let request = serde_json::from_slice(&session.open_frame(&frame).unwrap()).unwrap();
            let response = dispatch_json(&state, "owner", request).await;
            host_socket
                .send(Message::Binary(
                    session
                        .seal_frame(&serde_json::to_vec(&response).unwrap())
                        .unwrap()
                        .into(),
                ))
                .await
                .unwrap();
        };
        let phone_task = async {
            let (initiator, first) = Initiator::start(EndpointConfig::new(
                phone.private_key(),
                host.public_key(),
                context,
            ))
            .unwrap();
            phone_socket
                .send(Message::Binary(first.into()))
                .await
                .unwrap();
            let Message::Binary(second) = phone_socket.next().await.unwrap().unwrap() else {
                panic!("binary handshake");
            };
            let mut session = initiator.finish(&second).unwrap();
            phone_socket
                .send(Message::Binary(
                    session
                        .seal_frame(
                            &serde_json::to_vec(&request("/api/v1/sync/checkpoint")).unwrap(),
                        )
                        .unwrap()
                        .into(),
                ))
                .await
                .unwrap();
            let Message::Binary(reply) = phone_socket.next().await.unwrap().unwrap() else {
                panic!("encrypted reply");
            };
            let response: RelayResponse =
                serde_json::from_slice(&session.open_frame(&reply).unwrap()).unwrap();
            assert_eq!(response.status, 200);
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(&response.body).unwrap()
                    ["hostInstallationId"],
                "test"
            );
        };
        timeout(Duration::from_secs(10), async {
            tokio::join!(host_task, phone_task);
        })
        .await
        .unwrap();
        let _ = phone_socket.close(None).await;
        let _ = host_socket.close(None).await;
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
