//! Group originals belong to the Group; each accepted recipient reads a verified
//! copy in its existing private Bot workspace without broader filesystem grants.
use crate::*;

pub(super) async fn storage_workspace(
    state: &AppState,
    conversation: &str,
    direct_workspace: &str,
    create: bool,
) -> Result<String, String> {
    let group = state
        .store
        .group_id_for_conversation(conversation)
        .await
        .map_err(|e| e.to_string())?;
    let Some(group) = group else {
        return Ok(direct_workspace.to_owned());
    };
    let root = tokio::fs::canonicalize(&state.bots_root)
        .await
        .map_err(|_| "The Group file folder is unavailable.")?;
    let mut path = root.clone();
    for component in [
        ".group-files".to_owned(),
        deterministic_uuid(&format!("group-files:{group}")),
    ] {
        path.push(component);
        if create {
            tokio::fs::create_dir(&path)
                .await
                .or_else(|e| {
                    if e.kind() == std::io::ErrorKind::AlreadyExists {
                        Ok(())
                    } else {
                        Err(e)
                    }
                })
                .map_err(|e| e.to_string())?;
        }
        let metadata = tokio::fs::symlink_metadata(&path)
            .await
            .map_err(|_| "The Group file folder is unavailable.")?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err("The Group file folder changed. Inspect it on the Mac.".into());
        }
    }
    let path = tokio::fs::canonicalize(path)
        .await
        .map_err(|e| e.to_string())?;
    if !path.starts_with(root) {
        return Err("The Group file folder is outside its storage boundary.".into());
    }
    path.to_str()
        .map(str::to_owned)
        .ok_or("The Group file folder is unavailable.".into())
}

pub(super) async fn verified_bytes(
    path: &FsPath,
    file: &StoredConversationFile,
) -> Result<Vec<u8>, String> {
    if file.kind != "attachment"
        || file.state != "available"
        || file.relative_path.as_deref() != Some(attachment_relative_path(&file.id).as_str())
    {
        return Err("An attached file is unavailable. Attach it again.".into());
    }
    let size = file
        .byte_size
        .filter(|size| *size > 0 && *size <= MAX_ATTACHMENT_BYTES as i64)
        .ok_or("The attachment size is invalid.")?;
    let hash = file
        .sha256
        .as_deref()
        .ok_or("The attachment integrity record is missing.")?;
    let input = tokio::fs::File::open(path)
        .await
        .map_err(|_| "An attached file is missing. Attach it again.")?;
    let mut bytes = Vec::new();
    input
        .take(MAX_ATTACHMENT_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .await
        .map_err(|e| e.to_string())?;
    if bytes.len() as i64 != size || hex::encode(Sha256::digest(&bytes)) != hash {
        return Err("An attached file changed. Attach it again before retrying.".into());
    }
    Ok(bytes)
}

pub(super) async fn for_dispatch(
    state: &AppState,
    message: &wonder_store::StoredMessage,
    bot: &StoredBot,
) -> Result<Vec<StoredConversationFile>, String> {
    let parent = state
        .store
        .group_attachment_parent(&message.id, &bot.id)
        .await
        .map_err(|e| e.to_string())?;
    let source = parent.as_ref().unwrap_or(message);
    let files = state
        .store
        .attachments_for_message(&source.id)
        .await
        .map_err(|e| e.to_string())?;
    if files.is_empty() {
        return Ok(files);
    }
    let group = state
        .store
        .group_id_for_conversation(&source.conversation_id)
        .await
        .map_err(|e| e.to_string())?;
    if group.is_none() {
        return Ok(files);
    }
    if parent.is_none() {
        return Err("Group attachments require an accepted Group dispatch.".into());
    }
    let workspace =
        storage_workspace(state, &source.conversation_id, &bot.workspace_path, false).await?;
    for file in &files {
        if file.conversation_id != source.conversation_id {
            return Err("The attachment belongs to another conversation.".into());
        }
        let path = attachment_path(&workspace, &file.id, false)
            .await
            .ok_or("The Group attachment path is unavailable.")?;
        let bytes = verified_bytes(&path, file).await?;
        let destination = attachment_path(&bot.workspace_path, &file.id, true)
            .await
            .ok_or("The Bot attachment folder is unavailable.")?;
        if tokio::fs::try_exists(&destination)
            .await
            .map_err(|e| e.to_string())?
        {
            verified_bytes(&destination, file).await?;
        } else {
            write_immutable(&destination, &bytes).await?;
        }
    }
    Ok(files)
}

/// Publish complete bytes atomically; a crash never leaves a partial file at its
/// durable upload identity. Existing content is verified and never overwritten.
pub(super) async fn write_immutable(destination: &FsPath, bytes: &[u8]) -> Result<bool, String> {
    let temporary = destination.with_file_name(format!(".upload-{}", uuid::Uuid::new_v4()));
    let mut output = tokio::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temporary)
        .await
        .map_err(|e| e.to_string())?;
    let result = async {
        output.write_all(bytes).await.map_err(|e| e.to_string())?;
        output.sync_all().await.map_err(|e| e.to_string())?;
        match tokio::fs::hard_link(&temporary, destination).await {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let input = tokio::fs::File::open(destination)
                    .await
                    .map_err(|e| e.to_string())?;
                let mut existing = Vec::new();
                input
                    .take(MAX_ATTACHMENT_BYTES as u64 + 1)
                    .read_to_end(&mut existing)
                    .await
                    .map_err(|e| e.to_string())?;
                if existing != bytes {
                    return Err("Attachment identity already contains different bytes.".into());
                }
                Ok(false)
            }
            Err(error) => Err(error.to_string()),
        }
    }
    .await;
    let _ = tokio::fs::remove_file(&temporary).await;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};
    use tower::ServiceExt;
    async fn request(
        state: &AppState,
        method: &str,
        path: &str,
        body: Value,
    ) -> (StatusCode, Vec<u8>) {
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(path)
                    .header("x-wonder-loopback-capability", &state.loopback_capability)
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        (
            status,
            axum::body::to_bytes(response.into_body(), 2 * 1024 * 1024)
                .await
                .unwrap()
                .to_vec(),
        )
    }
    async fn fixture() -> (tempfile::TempDir, AppState) {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let path = dir.path().join("worker");
        std::fs::create_dir(&path).unwrap();
        state
            .store
            .upsert_bot(
                "worker",
                "Worker",
                "Specialist",
                "Help",
                path.to_str().unwrap(),
                "test",
                None,
                None,
                "1",
            )
            .await
            .unwrap();
        state
            .store
            .create_channel(
                "group",
                "group-chat",
                "Group",
                None,
                "bot",
                &[("bot", "coordinator"), ("worker", "worker")],
                "1",
            )
            .await
            .unwrap();
        let script = dir.path().join("runtime.py");
        let source = std::fs::read_to_string(&script).unwrap();
        std::fs::write(&script,source.replacen("    result = {}","    with open(root + '/request-details', 'a') as log: log.write(json.dumps(r) + '\\n')\n    result = {}",1)).unwrap();
        let config = state.launch_config.lock().await.clone();
        state.app_server.lock().await.restart(config).await.unwrap();
        for id in ["bot", "worker"] {
            let mut bot = state.store.bot(id).await.unwrap().unwrap();
            bot.permission_mode = Some("read-only".into());
            bot.working_directory = Some(
                std::fs::canonicalize(&bot.workspace_path)
                    .unwrap()
                    .to_string_lossy()
                    .into(),
            );
            state
                .store
                .update_managed_bot(&bot, [false; 3])
                .await
                .unwrap();
            state
                .runtime_catalog
                .write()
                .await
                .apply_permission_profiles(
                    &bot.workspace_path,
                    &json!({"data":[{"name":":read-only","allowed":true}]}),
                );
        }
        state
            .runtime_catalog
            .write()
            .await
            .apply_models_page(&json!({"data":[{"id":"test-model","isDefault":true}]}));
        (dir, state)
    }
    async fn upload(state: &AppState, conversation: &str, upload: &str, text: &str) -> Value {
        let (status,bytes)=request(state,"POST",&format!("/api/v1/conversations/{conversation}/files"),json!({"clientUploadId":upload,"name":"brief.txt","mimeType":"text/plain","contentBase64":base64::engine::general_purpose::STANDARD.encode(text)})).await;
        assert_eq!(
            status,
            StatusCode::OK,
            "{}",
            String::from_utf8_lossy(&bytes)
        );
        serde_json::from_slice(&bytes).unwrap()
    }
    #[tokio::test]
    async fn group_files_replay_dispatch_to_each_accepted_bot_and_preserve_read_only() {
        let (dir, state) = fixture().await;
        let upload_id = uuid::Uuid::new_v4().to_string();
        let file = upload(&state, "group-chat", &upload_id, "Shared brief").await;
        assert_eq!(
            file,
            upload(&state, "group-chat", &upload_id, "Shared brief").await
        );
        let id = file["id"].as_str().unwrap().to_owned();
        let (status,_)=request(&state,"POST","/api/v1/conversations/group-chat/files",json!({"clientUploadId":upload_id,"name":"brief.txt","mimeType":"text/plain","contentBase64":base64::engine::general_purpose::STANDARD.encode("changed")})).await;
        assert_eq!(status, StatusCode::CONFLICT);
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgba8(1, 1)
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let (status,image_bytes) = request(&state,"POST","/api/v1/conversations/group-chat/files",json!({"clientUploadId":uuid::Uuid::new_v4().to_string(),"name":"pixel.png","mimeType":"image/png","contentBase64":base64::engine::general_purpose::STANDARD.encode(png.into_inner())})).await;
        assert_eq!(status, StatusCode::OK);
        let image: Value = serde_json::from_slice(&image_bytes).unwrap();
        let image_id = image["id"].as_str().unwrap().to_owned();
        let mut ids = vec![id.clone(), image_id.clone()];
        ids.sort();
        let client = uuid::Uuid::new_v4().to_string();
        let body =
            json!({"deviceId":"owner","clientMessageId":client,"body":"","attachmentIds":ids});
        // Exercise the real handler; transport readiness is independent of acceptance semantics.
        let response = send_channel_message(
            State(state.clone()),
            Extension(OwnerAuthority),
            Path("group".into()),
            None,
            Some(Extension(LocalOwnerAuthority)),
            Json(serde_json::from_value(body.clone()).unwrap()),
        )
        .await;
        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let receipt: Value = serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), 100000)
                .await
                .unwrap(),
        )
        .unwrap();
        let parent = state
            .store
            .message_by_id(receipt["wonderMessageId"].as_str().unwrap())
            .await
            .unwrap()
            .unwrap();
        let replay = send_channel_message(
            State(state.clone()),
            Extension(OwnerAuthority),
            Path("group".into()),
            None,
            Some(Extension(LocalOwnerAuthority)),
            Json(serde_json::from_value(body).unwrap()),
        )
        .await;
        assert_eq!(replay.status(), StatusCode::ACCEPTED);
        let group = state.store.channel("group").await.unwrap().unwrap();
        let summary = serde_json::to_value(channel_summary(group)).unwrap();
        crate::tests::validate_http_contract("channelSummary", &summary);
        assert_eq!(summary["attachmentsSupported"], true);
        assert_eq!(summary["messages"][0]["attachmentIds"], json!(ids));
        for (bot_id, phase, conversation) in [
            ("worker", "worker", "worker-chat"),
            ("bot", "synthesis", "group-chat"),
        ] {
            if conversation != "group-chat" {
                state
                    .store
                    .create_conversation(conversation, bot_id, "Worker", "2")
                    .await
                    .unwrap();
            }
            let client = uuid::Uuid::new_v4().to_string();
            state
                .store
                .plan_group_node(&parent, &client, bot_id, phase)
                .await
                .unwrap();
            let MessageInsert::Inserted(child) = state
                .store
                .insert_message(
                    "owner",
                    &client,
                    "Read the attached brief",
                    "hash",
                    conversation,
                    "2",
                )
                .await
                .unwrap()
            else {
                panic!()
            };
            let bot = state.store.bot(bot_id).await.unwrap().unwrap();
            let files = for_dispatch(&state, &child, &bot).await.unwrap();
            assert_eq!(files.len(), 2);
            assert!(files.iter().any(|file| file.id == id));
            let destination = attachment_path(&bot.workspace_path, &id, false)
                .await
                .unwrap();
            assert_eq!(
                tokio::fs::read(&destination).await.unwrap(),
                b"Shared brief"
            );
            assert_eq!(for_dispatch(&state, &child, &bot).await.unwrap().len(), 2);
            crate::dispatch_to_codex_inner(state.clone(), child.clone(), Some(bot_id.into()), None)
                .await;
            assert_eq!(
                state
                    .store
                    .message_by_id(&child.id)
                    .await
                    .unwrap()
                    .unwrap()
                    .state,
                "accepted_by_codex",
                "{}",
                std::fs::read_to_string(dir.path().join("logs/test.jsonl")).unwrap_or_default()
            );
            crate::dispatch_to_codex_inner(state.clone(), child.clone(), Some(bot_id.into()), None)
                .await;
            assert_eq!(
                state
                    .store
                    .bot(bot_id)
                    .await
                    .unwrap()
                    .unwrap()
                    .permission_mode
                    .as_deref(),
                Some("read-only")
            );
        }
        let requests: Vec<Value> = std::fs::read_to_string(dir.path().join("request-details"))
            .unwrap()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        let turns: Vec<_> = requests
            .iter()
            .filter(|r| r["method"] == "turn/start")
            .collect();
        assert_eq!(
            turns.len(),
            2,
            "one dispatch per durable child despite redelivery"
        );
        for turn in turns {
            assert_eq!(turn["params"]["permissions"], ":read-only");
            assert!(turn["params"]["input"].to_string().contains(&id));
            assert!(turn["params"]["input"]
                .as_array()
                .unwrap()
                .iter()
                .any(|item| item["type"] == "localImage"
                    && item["path"]
                        .as_str()
                        .is_some_and(|path| path.ends_with(&image_id))));
        }
        // Group originals do not move when the coordinator changes.
        let pool = sqlx::SqlitePool::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        sqlx::query("UPDATE channels SET coordinator_bot_id='worker' WHERE id='group'")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("UPDATE conversation_metadata SET bot_id='worker' WHERE id='group-chat'")
            .execute(&pool)
            .await
            .unwrap();
        let (status, bytes) = request(
            &state,
            "GET",
            &format!("/api/v1/conversations/group-chat/files/{id}"),
            Value::Null,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(bytes, b"Shared brief");
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn foreign_files_forged_recipients_and_tampered_copies_fail_closed() {
        let (_dir, state) = fixture().await;
        state
            .store
            .create_conversation("other", "bot", "Other", "1")
            .await
            .unwrap();
        let foreign = upload(
            &state,
            "other",
            &uuid::Uuid::new_v4().to_string(),
            "Private",
        )
        .await;
        let response = send_channel_message(
            State(state.clone()),
            Extension(OwnerAuthority),
            Path("group".into()),
            None,
            Some(Extension(LocalOwnerAuthority)),
            Json(SendMessageRequest {
                group_routing: None,
                device_id: "owner".into(),
                client_message_id: uuid::Uuid::new_v4().to_string(),
                body: "Read".into(),
                attachment_ids: vec![foreign["id"].as_str().unwrap().into()],
            }),
        )
        .await;
        assert_eq!(response.status(), StatusCode::CONFLICT);
        let file = upload(
            &state,
            "group-chat",
            &uuid::Uuid::new_v4().to_string(),
            "Shared",
        )
        .await;
        let id = file["id"].as_str().unwrap().to_owned();
        let MessageInsert::Inserted(parent) = state
            .store
            .insert_message_with_attachments(
                "owner",
                "parent",
                "Read",
                "hash",
                "group-chat",
                std::slice::from_ref(&id),
                "1",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
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
            .plan_group_node(&parent, &parent.client_message_id, "bot", "direct")
            .await
            .unwrap();
        let bot = state.store.bot("bot").await.unwrap().unwrap();
        assert!(for_dispatch(
            &state,
            &parent,
            &state.store.bot("worker").await.unwrap().unwrap()
        )
        .await
        .is_err());
        for_dispatch(&state, &parent, &bot).await.unwrap();
        let destination = attachment_path(&bot.workspace_path, &id, false)
            .await
            .unwrap();
        tokio::fs::write(&destination, b"tampered").await.unwrap();
        assert!(for_dispatch(&state, &parent, &bot).await.is_err());
        assert_eq!(
            tokio::fs::read(&destination).await.unwrap(),
            b"tampered",
            "never silently overwrite a changed Bot copy"
        );
        let root = storage_workspace(&state, "group-chat", &bot.workspace_path, false)
            .await
            .unwrap();
        tokio::fs::write(
            attachment_path(&root, &id, false).await.unwrap(),
            b"changed original",
        )
        .await
        .unwrap();
        assert!(for_dispatch(&state, &parent, &bot).await.is_err());
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
