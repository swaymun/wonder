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
fn create_body(id: &str) -> Value {
    json!({"name":"Research","role":"Research helper","systemPrompt":"Research the requested topic.","avatarColor":"#167a7a","clientRequestId":id})
}

async fn deny_workspace_profile(dir: &FsPath, state: &AppState) {
    let path = dir.join("runtime.py");
    let source = std::fs::read_to_string(&path).unwrap();
    assert!(source.contains("'name': ':workspace', 'allowed': True"));
    std::fs::write(
        path,
        source.replace(
            "'name': ':workspace', 'allowed': True",
            "'name': ':workspace', 'allowed': False",
        ),
    )
    .unwrap();
    state
        .app_server
        .lock()
        .await
        .restart(state.launch_config.lock().await.clone())
        .await
        .unwrap();
}

#[tokio::test]
async fn bot_http_creation_is_idempotent_and_uuid_prefix_collision_cannot_delete_files() {
    let (dir, state) = crate::ingestion::tests::fixture().await;
    let first = "12345678-1234-4234-8234-123456789001";
    let second = "12345678-1234-4234-8234-123456789002";
    let (status, created) = call(&state, "POST", "/api/v1/bots", create_body(first)).await;
    assert!(status.is_success(), "{status} {created}");
    assert_eq!(created["id"], first);
    let home = PathBuf::from(created["workspacePath"].as_str().unwrap());
    let important = home.join("keep.txt");
    std::fs::write(&important, "First Bot's work").unwrap();
    let (status, duplicate) = call(&state, "POST", "/api/v1/bots", create_body(first)).await;
    assert!(status.is_success(), "{duplicate}");
    assert_eq!(duplicate["id"], created["id"]);
    let mut changed = create_body(first);
    changed["name"] = json!("Changed");
    assert_eq!(
        call(&state, "POST", "/api/v1/bots", changed).await.0,
        StatusCode::CONFLICT
    );
    // Native defaults use :workspace, not a generated custom profile. Reject
    // that actual profile on the second creation to exercise owned rollback.
    deny_workspace_profile(dir.path(), &state).await;
    let (status, error) = call(&state, "POST", "/api/v1/bots", create_body(second)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{error}");
    assert_eq!(
        std::fs::read_to_string(&important).unwrap(),
        "First Bot's work"
    );
    assert!(state.store.bot(second).await.unwrap().is_none());
    assert!(state.store.bot(first).await.unwrap().is_some());
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn bot_avatar_contract_supports_old_new_and_omitted_updates() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    let new_id = "12345678-1234-4234-8234-123456789101";
    let (status, created) = call(
        &state,
        "POST",
        "/api/v1/bots",
        json!({
            "name": "Orbit",
            "role": "Research helper",
            "systemPrompt": "Research carefully.",
            "clientRequestId": new_id,
            "avatarShape": "orbit",
            "avatarPalette": "coral"
        }),
    )
    .await;
    assert!(status.is_success(), "{status} {created}");
    assert_eq!(created["avatarShape"], "orbit");
    assert_eq!(created["avatarPalette"], "coral");
    assert_eq!(created["avatarColor"], "#ff925c");

    let default_id = "12345678-1234-4234-8234-123456789104";
    let (status, default_bot) = call(
        &state,
        "POST",
        "/api/v1/bots",
        json!({
            "name": "Default Avatar",
            "role": "Helper",
            "systemPrompt": "Help.",
            "clientRequestId": default_id
        }),
    )
    .await;
    assert!(status.is_success(), "{status} {default_bot}");
    assert_eq!(default_bot["avatarShape"], "sun");
    assert_eq!(default_bot["avatarPalette"], "amber");
    assert_eq!(default_bot["avatarColor"], "#ffb51c");

    let old_id = "12345678-1234-4234-8234-123456789102";
    let (status, old_client) = call(
        &state,
        "POST",
        "/api/v1/bots",
        json!({
            "name": "Old Client",
            "role": "Helper",
            "systemPrompt": "Help.",
            "clientRequestId": old_id,
            "avatarColor": "#167a7a"
        }),
    )
    .await;
    assert!(status.is_success(), "{status} {old_client}");
    assert_eq!(old_client["avatarShape"], "sun");
    assert_eq!(old_client["avatarPalette"], "teal");
    assert_eq!(old_client["avatarColor"], "#57b8b3");

    let (status, unknown_color) = call(
        &state,
        "POST",
        "/api/v1/bots",
        json!({
            "name": "Nearest",
            "role": "Helper",
            "systemPrompt": "Help.",
            "clientRequestId": "12345678-1234-4234-8234-123456789103",
            "avatarColor": "#123456"
        }),
    )
    .await;
    assert!(status.is_success(), "{status} {unknown_color}");
    assert_eq!(unknown_color["avatarPalette"], "teal");
    assert_eq!(unknown_color["avatarColor"], "#57b8b3");

    let (status, renamed) = call(
        &state,
        "PATCH",
        &format!("/api/v1/bots/{new_id}"),
        json!({"name": "Renamed Orbit"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{renamed}");
    assert_eq!(renamed["avatarShape"], "orbit");
    assert_eq!(renamed["avatarPalette"], "coral");
    assert_eq!(renamed["avatarColor"], "#ff925c");

    let (status, recolored) = call(
        &state,
        "PATCH",
        &format!("/api/v1/bots/{new_id}"),
        json!({"avatarColor": "#3478cb"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{recolored}");
    assert_eq!(recolored["avatarShape"], "orbit");
    assert_eq!(recolored["avatarPalette"], "ocean");
    assert_eq!(recolored["avatarColor"], "#5699e7");

    let (status, invalid) = call(
        &state,
        "PATCH",
        &format!("/api/v1/bots/{new_id}"),
        json!({"avatarPalette": "not-a-palette"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{invalid}");

    let (status, invalid) = call(
        &state,
        "PATCH",
        &format!("/api/v1/bots/{new_id}"),
        json!({"avatarShape": "not-a-shape"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{invalid}");

    let mut future = state.store.bot(new_id).await.unwrap().unwrap();
    future.avatar_shape = Some("future-character".into());
    future.avatar_palette = Some("future-palette".into());
    future.avatar_color = Some("#123456".into());
    future.avatar_legacy_color = None;
    state
        .store
        .update_managed_bot(&future, [false, false, false])
        .await
        .unwrap();
    let (status, future_read) = call(
        &state,
        "PATCH",
        &format!("/api/v1/bots/{new_id}"),
        json!({"name": "Future Orbit"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{future_read}");
    assert_eq!(future_read["avatarShape"], "future-character");
    assert_eq!(future_read["avatarPalette"], "future-palette");
    assert_eq!(future_read["avatarColor"], "#123456");

    // Older clients echo avatarColor on every profile save. An unchanged
    // compatibility color must behave like omission and preserve future IDs.
    let (status, legacy_rename) = call(
        &state,
        "PATCH",
        &format!("/api/v1/bots/{new_id}"),
        json!({"name": "Legacy Renamed Future Orbit", "avatarColor": "#123456"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{legacy_rename}");
    assert_eq!(legacy_rename["avatarShape"], "future-character");
    assert_eq!(legacy_rename["avatarPalette"], "future-palette");
    assert_eq!(legacy_rename["avatarColor"], "#123456");

    let (status, list) = call(&state, "GET", "/api/v1/bots", Value::Null).await;
    assert_eq!(status, StatusCode::OK, "{list}");
    let listed = list
        .as_array()
        .unwrap()
        .iter()
        .find(|bot| bot["id"] == new_id)
        .unwrap();
    assert_eq!(listed["avatarShape"], "future-character");
    assert_eq!(listed["avatarPalette"], "future-palette");
    assert_eq!(listed["avatarColor"], "#123456");
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn bot_http_directory_edits_require_existing_grants_and_delete_requires_archive() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    let external = tempfile::tempdir().unwrap();
    let path = external.path().canonicalize().unwrap();
    std::fs::write(path.join("keep.txt"), "External project").unwrap();
    let (status, error) = call(
        &state,
        "PATCH",
        "/api/v1/bots/bot",
        json!({"workingDirectory":path}),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{error}");
    assert_eq!(
        call(&state, "DELETE", "/api/v1/bots/bot", Value::Null)
            .await
            .0,
        StatusCode::CONFLICT
    );
    // A legacy Bot may point at a project outside private Bot storage.
    let bot = state.store.bot("bot").await.unwrap().unwrap();
    state
        .store
        .upsert_bot(
            "bot",
            "Bot",
            "Helper",
            "Help",
            path.to_str().unwrap(),
            &bot.permission_profile,
            None,
            None,
            "now",
        )
        .await
        .unwrap();
    assert_eq!(
        call(&state, "POST", "/api/v1/bots/bot/archive", Value::Null)
            .await
            .0,
        StatusCode::OK
    );
    let (status, error) = call(&state, "DELETE", "/api/v1/bots/bot", Value::Null).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{error}");
    assert_eq!(
        std::fs::read_to_string(path.join("keep.txt")).unwrap(),
        "External project"
    );
    assert!(state.store.bot("bot").await.unwrap().is_none());
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn bot_deletion_removes_owned_directory_but_does_not_follow_nested_symlinks() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    let external = tempfile::tempdir().unwrap();
    std::fs::write(external.path().join("keep.txt"), "Shared").unwrap();
    let bot = state.store.bot("bot").await.unwrap().unwrap();
    std::os::unix::fs::symlink(
        external.path(),
        PathBuf::from(&bot.workspace_path).join("external"),
    )
    .unwrap();
    std::fs::write(
        PathBuf::from(&bot.workspace_path).join("private.txt"),
        "Private",
    )
    .unwrap();
    state.store.archive_bot_safely("bot", true).await.unwrap();
    let (status, error) = call(&state, "DELETE", "/api/v1/bots/bot", Value::Null).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{error}");
    assert!(
        !FsPath::new(&bot.workspace_path).exists(),
        "The private workspace must actually be removed."
    );
    assert_eq!(
        std::fs::read_to_string(external.path().join("keep.txt")).unwrap(),
        "Shared"
    );
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn bot_archive_fences_an_accepted_automation_before_message_materialization() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    let automation = state
        .store
        .insert_automation(
            "auto",
            "Daily",
            "standalone",
            "bot",
            None,
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
    let (status, error) = call(&state, "POST", "/api/v1/bots/bot/archive", Value::Null).await;
    assert_eq!(status, StatusCode::CONFLICT, "{error}");
    assert!(!state.store.bot("bot").await.unwrap().unwrap().is_archived);
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn bot_deletion_preserves_shared_folder_and_keeps_cleanup_retryable() {
    let (dir, state) = crate::ingestion::tests::fixture().await;
    let other = tempfile::tempdir().unwrap();
    state
        .store
        .upsert_bot(
            "other",
            "Other",
            "Helper",
            "Help",
            other.path().to_str().unwrap(),
            "test",
            None,
            None,
            "now",
        )
        .await
        .unwrap();
    // An ancestor grant also shares every descendant; deletion cannot infer
    // exclusive ownership just because there is no exact-path grant.
    state
        .store
        .save_bot_file_access(
            "other",
            0,
            &[dir
                .path()
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .into_owned()],
            &[],
        )
        .await
        .unwrap();
    let bot = state.store.bot("bot").await.unwrap().unwrap();
    let file = PathBuf::from(&bot.workspace_path).join("shared.txt");
    std::fs::write(&file, "Shared").unwrap();
    state.store.archive_bot_safely("bot", true).await.unwrap();
    let (status, error) = call(&state, "DELETE", "/api/v1/bots/bot", Value::Null).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{error}");
    assert!(state.store.bot("bot").await.unwrap().is_some());
    assert!(file.exists());
    assert_eq!(state.store.pending_bot_deletions().await.unwrap().len(), 1);
    state
        .store
        .save_bot_file_access("other", 1, &[], &[])
        .await
        .unwrap();
    let (status, error) = call(&state, "DELETE", "/api/v1/bots/bot", Value::Null).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{error}");
    assert!(!file.exists());
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn bot_deletion_refuses_a_symlink_workspace() {
    let (dir, state) = crate::ingestion::tests::fixture().await;
    let external = tempfile::tempdir().unwrap();
    let file = external.path().join("keep.txt");
    std::fs::write(&file, "Keep").unwrap();
    let link = dir.path().join("linked-workspace");
    std::os::unix::fs::symlink(external.path(), &link).unwrap();
    state
        .store
        .upsert_bot(
            "bot",
            "Bot",
            "Helper",
            "Help",
            link.to_str().unwrap(),
            "test",
            None,
            None,
            "now",
        )
        .await
        .unwrap();
    state.store.archive_bot_safely("bot", true).await.unwrap();
    let (status, error) = call(&state, "DELETE", "/api/v1/bots/bot", Value::Null).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{error}");
    assert!(state.store.bot("bot").await.unwrap().is_some());
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "Keep");
    assert!(std::fs::symlink_metadata(&link)
        .unwrap()
        .file_type()
        .is_symlink());
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn group_http_send_and_delete_remain_live_and_remove_completed_chat() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    state
        .store
        .create_channel(
            "delete-test",
            "delete-chat",
            "Disposable",
            None,
            "bot",
            &[("bot", "coordinator")],
            "now",
        )
        .await
        .unwrap();
    let _service = crate::ingestion::spawn(state.clone()).await;
    tokio::time::timeout(Duration::from_secs(10), async {
        while !state.ingestion.readiness(&state.store).await.ready {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    let (status,receipt)=tokio::time::timeout(Duration::from_secs(2),call(&state,"POST","/api/v1/group-chats/delete-test/messages",json!({"deviceId":"owner","clientMessageId":uuid::Uuid::new_v4().to_string(),"body":"Disposable Group message"}))).await.expect("Group acceptance must not deadlock");
    assert_eq!(status, StatusCode::ACCEPTED, "{receipt}");
    let (status, error) = tokio::time::timeout(
        Duration::from_secs(2),
        call(
            &state,
            "DELETE",
            "/api/v1/group-chats/delete-test",
            Value::Null,
        ),
    )
    .await
    .expect("Group deletion must not deadlock");
    assert_eq!(status, StatusCode::CONFLICT, "{error}");
    state
        .store
        .finish_group_run(
            receipt["wonderMessageId"].as_str().unwrap(),
            Some("completed-output"),
            "later",
        )
        .await
        .unwrap();
    let (status, error) = call(
        &state,
        "DELETE",
        "/api/v1/group-chats/delete-test",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{error}");
    let (status, chats) = call(&state, "GET", "/api/v1/conversations", Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!chats
        .as_array()
        .unwrap()
        .iter()
        .any(|chat| chat["conversationId"] == "delete-chat"));
    state.app_server.lock().await.shutdown().await.unwrap();
}

// Model the runtime's effective config response independently of the HTTP handler.
fn grant_runtime(
    dir: &FsPath,
    profile: &str,
    home: &str,
    reads: &[&str],
    writes: &[&str],
    denies: &[&str],
) {
    let filesystem = wonder_app_server::permission_filesystem(home, reads, writes, denies).unwrap();
    let config = json!({"config":{"permissions":{profile:{"filesystem":filesystem}}}});
    let path = dir.join("runtime.py");
    let source = std::fs::read_to_string(&path).unwrap()
        .replace("result = {'data': [{'name': 'test', 'allowed': True}, {'name': ':read-only', 'allowed': True}, {'name': ':workspace', 'allowed': True}, {'name': ':danger-full-access', 'allowed': True}]}",
            &format!("result = {{'data': [{{'name': 'test', 'allowed': True}}, {{'name': ':read-only', 'allowed': True}}, {{'name': ':workspace', 'allowed': True}}, {{'name': ':danger-full-access', 'allowed': True}}, {{'name': '{profile}', 'allowed': True}}]}}"))
        .replace("    elif method == 'thread/start':", &format!("    elif method == 'config/read': result = json.loads({})\n    elif method == 'thread/start':", serde_json::to_string(&config.to_string()).unwrap()));
    std::fs::write(path, source).unwrap();
}

#[tokio::test]
async fn creation_activates_selected_files_before_publication_and_retry_preserves_later_access() {
    let (dir, state) = crate::ingestion::tests::fixture().await;
    let selected = tempfile::tempdir().unwrap();
    let project = selected.path().canonicalize().unwrap();
    let reference = project.join("reference.txt");
    std::fs::write(&reference, "Read only").unwrap();
    let id = "22345678-1234-4234-8234-123456789001";
    let home = std::fs::canonicalize(&state.bots_root).unwrap().join(id);
    grant_runtime(
        dir.path(),
        &format!("wonder_bot_{}", id.replace('-', "")),
        home.to_str().unwrap(),
        &[reference.to_str().unwrap()],
        &[project.to_str().unwrap()],
        &state
            .denied_roots
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
    );
    let mut body = create_body(id);
    body["readRoots"] = json!([reference]);
    body["writeRoots"] = json!([project]);
    body["workingDirectory"] = json!(project);
    let (status, created) = call(&state, "POST", "/api/v1/bots", body.clone()).await;
    assert_eq!(status, StatusCode::OK, "{created}");
    assert_eq!(created["workingDirectory"], json!(project));
    assert_ne!(created["workspacePath"], created["workingDirectory"]);
    let access = state.store.bot_file_access(id).await.unwrap();
    assert_eq!((access.revision, access.applied_revision), (1, 1));
    assert_eq!(access.read_roots, vec![reference.to_str().unwrap()]);
    assert_eq!(access.write_roots, vec![project.to_str().unwrap()]);
    assert!(state
        .store
        .list_bots()
        .await
        .unwrap()
        .iter()
        .any(|b| b.id == id));
    // A retried creation receipt must not restore a grant the owner later removed.
    assert!(state
        .store
        .save_bot_file_access(id, 1, &[], &[])
        .await
        .unwrap());
    let (status, _) = call(&state, "POST", "/api/v1/bots", body).await;
    assert_eq!(status, StatusCode::OK);
    assert!(state
        .store
        .bot_file_access(id)
        .await
        .unwrap()
        .write_roots
        .is_empty());
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn creation_with_unverified_grants_rolls_back_and_preserves_selected_files() {
    let (dir, state) = crate::ingestion::tests::fixture().await;
    deny_workspace_profile(dir.path(), &state).await;
    let selected = tempfile::tempdir().unwrap();
    let file = selected.path().join("keep.txt");
    std::fs::write(&file, "Keep").unwrap();
    let id = "32345678-1234-4234-8234-123456789001";
    let mut body = create_body(id);
    body["writeRoots"] = json!([file]);
    let (status, _) = call(&state, "POST", "/api/v1/bots", body).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(state.store.bot(id).await.unwrap().is_none());
    assert_eq!(state.store.bot_file_access(id).await.unwrap().revision, 0);
    assert_eq!(std::fs::read_to_string(file).unwrap(), "Keep");
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn file_access_accepts_owner_authority_without_local_confirmation_and_fences_stale_edits() {
    let (dir, state) = crate::ingestion::tests::fixture().await;
    let selected = tempfile::tempdir().unwrap();
    let path = selected
        .path()
        .canonicalize()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let bot = state.store.bot("bot").await.unwrap().unwrap();
    grant_runtime(dir.path(), "test", &bot.workspace_path, &[], &[&path], &[]);
    let app = Router::new()
        .route(
            "/access",
            axum::routing::put(
                |State(state): State<AppState>,
                 Extension(owner): Extension<OwnerAuthority>,
                 Json(change): Json<file_access::Change>| async move {
                    file_access::update(
                        State(state),
                        Extension(owner),
                        Path("bot".to_owned()),
                        Json(change),
                    )
                    .await
                },
            ),
        )
        .layer(Extension(OwnerAuthority))
        .with_state(state.clone());
    for expected in [StatusCode::OK, StatusCode::CONFLICT] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri("/access")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({"revision":0,"readRoots":[],"writeRoots":[path]}).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 65536).await.unwrap();
        assert_eq!(status, expected, "{}", String::from_utf8_lossy(&bytes));
    }
    let unauthenticated = router(state.clone())
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri("/api/v1/bots/bot/file-access")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert!(!unauthenticated.status().is_success());
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn read_ack_http_requires_displayed_snapshot_and_keeps_unseen_update() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    state
        .store
        .ensure_conversation_metadata("bot", "bot", "Bot", "now")
        .await
        .unwrap();
    state
        .store
        .update_conversation("bot", None, None, None, Some(true), "now")
        .await
        .unwrap();
    let seen = state
        .store
        .committed_sequence(&state.host_epoch)
        .await
        .unwrap();
    let path = "/api/v1/conversations/bot";
    assert_eq!(
        call(&state, "PATCH", path, json!({"markRead":true}))
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    assert!(
        state
            .store
            .conversation("bot")
            .await
            .unwrap()
            .unwrap()
            .has_unread
    );
    // A new unread projection overtakes this acknowledgement in transit.
    state
        .store
        .update_conversation("bot", None, None, None, Some(true), "later")
        .await
        .unwrap();
    let (status, _) = call(
        &state,
        "PATCH",
        path,
        json!({"markRead":true,"hostEpoch":state.host_epoch,"readThroughSequence":seen}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        state
            .store
            .conversation("bot")
            .await
            .unwrap()
            .unwrap()
            .has_unread
    );
    let latest = state
        .store
        .committed_sequence(&state.host_epoch)
        .await
        .unwrap();
    let (status, _) = call(
        &state,
        "PATCH",
        path,
        json!({"markRead":true,"hostEpoch":state.host_epoch,"readThroughSequence":latest}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        !state
            .store
            .conversation("bot")
            .await
            .unwrap()
            .unwrap()
            .has_unread
    );
    let _ = state.app_server.lock().await.shutdown().await;
}

#[tokio::test]
async fn group_read_http_returns_fenced_projection_and_preserves_newer_update() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    state
        .store
        .create_channel(
            "group",
            "group-conversation",
            "Team",
            None,
            "bot",
            &[("bot", "coordinator")],
            "now",
        )
        .await
        .unwrap();
    state
        .store
        .update_conversation("group-conversation", None, None, None, Some(true), "now")
        .await
        .unwrap();
    let (status, snapshot) = call(&state, "GET", "/api/v1/group-chats/group", json!({})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(snapshot["hasUnread"], true);
    assert_eq!(snapshot["hostEpoch"], state.host_epoch);
    let path = "/api/v1/group-chats/group/read";
    assert_eq!(
        call(
            &state,
            "POST",
            path,
            json!({"hostEpoch":"old-epoch","readThroughSequence":snapshot["lastSequence"]})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    state
        .store
        .update_conversation("group-conversation", None, None, None, Some(true), "later")
        .await
        .unwrap();
    let (status, current) = call(
        &state,
        "POST",
        path,
        json!({"hostEpoch":snapshot["hostEpoch"],"readThroughSequence":snapshot["lastSequence"]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(current["hasUnread"], true);
    let (status, read) = call(
        &state,
        "POST",
        path,
        json!({"hostEpoch":current["hostEpoch"],"readThroughSequence":current["lastSequence"]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(read["hasUnread"], false);
    let response = router(state.clone()).oneshot(Request::builder().method("POST").uri(path).header("content-type","application/json")
        .body(Body::from(json!({"hostEpoch":state.host_epoch,"readThroughSequence":read["lastSequence"]}).to_string())).unwrap()).await.unwrap();
    assert!(!response.status().is_success());
    let _ = state.app_server.lock().await.shutdown().await;
}

#[tokio::test]
async fn avatar_updates_persist_with_active_or_uncertain_work_and_unchanged_profile_fields() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    let bot = state.store.bot("bot").await.unwrap().unwrap();
    state
        .store
        .ensure_conversation_metadata("bot", "bot", "Bot", "now")
        .await
        .unwrap();
    state
        .store
        .insert_dispatch_message(
            "owner",
            "avatar-save-work",
            "work",
            "hash",
            "bot",
            &[],
            "now",
            true,
        )
        .await
        .unwrap();
    let message = state
        .store
        .message_by_device_and_client_message_id("owner", "avatar-save-work")
        .await
        .unwrap()
        .unwrap();

    for (delivery, shape, palette) in [
        ("accepted_by_wonder", "orbit", "coral"),
        ("streaming", "atom", "rose"),
        ("uncertain", "luna", "ocean"),
    ] {
        state
            .store
            .update_message_delivery(&message.id, delivery, None, None)
            .await
            .unwrap();
        assert!(state.store.bot_has_work("bot").await.unwrap());
        // Existing iOS clients include the unchanged profile fields on Save.
        let (status, saved) = call(
            &state,
            "PATCH",
            "/api/v1/bots/bot",
            json!({
                "name": bot.name, "role": bot.role, "systemPrompt": bot.system_prompt,
                "avatarShape": shape, "avatarPalette": palette
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{delivery}: {saved}");
        assert_eq!(saved["avatarShape"], shape);
        assert_eq!(saved["avatarPalette"], palette);
        let (status, fetched) = call(&state, "GET", "/api/v1/bots/bot", json!({})).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(fetched["avatarShape"], shape);
        assert_eq!(fetched["avatarPalette"], palette);
        let (_, listed) = call(&state, "GET", "/api/v1/bots", json!({})).await;
        assert_eq!(
            listed
                .as_array()
                .unwrap()
                .iter()
                .find(|entry| entry["id"] == "bot")
                .unwrap()["avatarShape"],
            shape
        );
        assert_eq!(
            state
                .store
                .message_by_id(&message.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            delivery
        );

        for change in [
            json!({"name":"Changed"}),
            json!({"role":"Changed"}),
            json!({"systemPrompt":"Changed"}),
            json!({"workingDirectory":bot.workspace_path}),
        ] {
            assert_eq!(
                call(&state, "PATCH", "/api/v1/bots/bot", change).await.0,
                StatusCode::CONFLICT
            );
        }
        assert_eq!(
            call(&state, "POST", "/api/v1/bots/bot/archive", json!({}))
                .await
                .0,
            StatusCode::CONFLICT
        );
        assert_eq!(
            call(
                &state,
                "PATCH",
                "/api/v1/bots/bot",
                json!({"avatarShape":"unsupported"})
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
    }
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn execution_choices_can_change_while_profile_edits_and_archive_remain_fenced() {
    let (_dir, state) = crate::ingestion::tests::fixture().await;
    let bot = state.store.bot("bot").await.unwrap().unwrap();
    state
        .store
        .ensure_conversation_metadata("bot", "bot", "Bot", "now")
        .await
        .unwrap();
    state
        .store
        .insert_dispatch_message(
            "owner",
            "active-settings",
            "work",
            "hash",
            "bot",
            &[],
            "now",
            true,
        )
        .await
        .unwrap();
    assert!(
        super::bot_management::validate_edit(&state, &bot, None, None, None, None, false)
            .await
            .is_ok()
    );
    assert!(
        super::bot_management::validate_edit(&state, &bot, None, None, None, None, true)
            .await
            .is_err()
    );
    let response = super::bot_management::archive(&state, "bot", true).await;
    assert_eq!(response.status(), axum::http::StatusCode::CONFLICT);
    assert!(!state.store.bot("bot").await.unwrap().unwrap().is_archived);
}
