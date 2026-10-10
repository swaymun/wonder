//! Convert inline tool media to verified, authenticated conversation files before
//! projection truncation. External URLs remain inert; they are never fetched.
use super::*;
use serde_json::{json, Value};

pub(super) async fn normalize(
    state: &AppState,
    conversation: &str,
    turn: &str,
    item: &Value,
) -> Result<Value, String> {
    let mut item = item.clone();
    let item_id = item
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    if item_id.is_empty() {
        return Ok(item);
    }
    if item.get("type").and_then(Value::as_str) == Some("userMessage") {
        return user_images(state, conversation, turn, &item_id, item).await;
    }
    // Generated images carry bare base64 rather than a tool content block.
    // Normalize before projection truncates strings, including history refresh.
    // Paired clients use the retained bytes; never resolve the runtime savedPath.
    if item.get("type").and_then(Value::as_str) == Some("imageGeneration") {
        item.as_object_mut().unwrap().remove("savedPath");
        if item.get("result").is_some_and(Value::is_string) {
            let encoded = item["result"].take();
            item["result"] = json!({"content":[{"type":"image","data":encoded}]});
        } else if item.get("result").is_none_or(Value::is_null)
            && item.get("status").and_then(Value::as_str) == Some("completed")
        {
            item["result"] =
                json!({"content":[unavailable("The image was not returned by the generator")]});
        }
    }
    // imageView carries a host-local path, not inline image bytes. Resolve it
    // before event redaction and retain a verified copy for paired clients.
    if item.get("type").and_then(Value::as_str) == Some("imageView") && item.get("result").is_none()
    {
        let source_id = format!("tool-media:{turn}:{item_id}:0");
        if let Some(file) = state
            .store
            .list_conversation_files(conversation)
            .await
            .map_err(|e| e.to_string())?
            .into_iter()
            .find(|file| file.source_id.as_deref() == Some(&source_id) && file.state == "available")
        {
            item["result"] = json!({"content":[{"type":"wonderArtifact","file":{
                "id":file.id,"name":file.name,"mimeType":file.mime_type,"byteSize":file.byte_size,
                "sha256":file.sha256,"state":file.state,"updatedAt":file.updated_at}}]});
            return Ok(item);
        }
        let source = item
            .get("path")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        let (_, roots, own) = media_scope(state, conversation)
            .await?
            .ok_or("Image has no conversation workspace")?;
        let denies = state.denied_roots.clone();
        let loaded = tokio::task::spawn_blocking(move || {
            local_image(&source, &roots, &denies, own.as_deref())
        })
        .await
        .map_err(|e| e.to_string())?;
        item["result"] = match loaded {
            Ok((bytes, mime, _)) => json!({"content":[{"type":"image","mimeType":mime,
                "data":base64::engine::general_purpose::STANDARD.encode(bytes)}]}),
            Err(reason) => json!({"content":[unavailable(reason)]}),
        };
    }
    let mut paths = Vec::new();
    for key in ["result", "contentItems", "output"] {
        if let Some(value) = item.get(key) {
            collect(value, vec![key.to_owned()], &mut paths, 0);
        }
    }
    if paths.is_empty() {
        return Ok(item);
    }
    let (storage, _, _) = media_scope(state, conversation)
        .await?
        .ok_or("Tool result has no conversation workspace")?;
    let mut total = 0;
    for (index, path) in paths.iter().enumerate() {
        let Some(value) = at_mut(&mut item, path) else {
            continue;
        };
        let decoded = if index < 16 {
            decode(value)
        } else {
            Err("Too many previews in this result")
        };
        let (bytes, mime, name) = match decoded {
            Ok(file) if total + file.0.len() <= 16 * 1024 * 1024 => file,
            Ok(_) => {
                *value = unavailable("This result exceeds the preview size limit");
                continue;
            }
            Err(reason) => {
                *value = unavailable(reason);
                continue;
            }
        };
        total += bytes.len();
        let checked = tokio::task::spawn_blocking(move || {
            validate(&bytes, &mime).map(|_| (bytes, mime, name))
        })
        .await
        .map_err(|e| e.to_string())?;
        let (bytes, mime, name) = match checked {
            Ok(file) => file,
            Err(reason) => {
                *value = unavailable(reason);
                continue;
            }
        };
        let source_id = format!("tool-media:{turn}:{item_id}:{index}");
        let id_seed = format!("tool-media:{conversation}:{turn}:{item_id}:{index}");
        *value = store(
            state,
            conversation,
            &storage,
            &id_seed,
            &source_id,
            &name,
            &mime,
            &bytes,
        )
        .await?;
    }
    Ok(item)
}

/// Persist verified bytes under a stable ID derived from `id_seed` and the
/// content, record the conversation file, and return its artifact reference.
#[allow(clippy::too_many_arguments)]
async fn store(
    state: &AppState,
    conversation: &str,
    storage: &str,
    id_seed: &str,
    source_id: &str,
    name: &str,
    mime: &str,
    bytes: &[u8],
) -> Result<Value, String> {
    let digest = hex::encode(Sha256::digest(bytes));
    let id = deterministic_uuid(&format!("{id_seed}:{mime}:{digest}"));
    let target = attachment_path(storage, &id, true)
        .await
        .ok_or("Preview storage unavailable")?;
    if target.exists() {
        if tokio::fs::read(&target).await.map_err(|e| e.to_string())? != bytes {
            return Err("Stored preview failed integrity verification".into());
        }
    } else {
        // Publish only complete bytes. A crash cannot poison the stable ID
        // with a partial file and permanently prevent inbox replay.
        let temporary = target.with_extension(uuid::Uuid::new_v4().to_string());
        let written = async {
            let mut file = tokio::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
                .await?;
            file.write_all(bytes).await?;
            file.sync_all().await?;
            tokio::fs::rename(&temporary, &target).await
        }
        .await;
        if let Err(error) = written {
            let _ = tokio::fs::remove_file(&temporary).await;
            return Err(error.to_string());
        }
    }
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    state
        .store
        .upsert_conversation_file(
            &id,
            conversation,
            "attachment",
            name,
            Some(mime),
            Some(bytes.len() as i64),
            Some(&digest),
            Some(&attachment_relative_path(&id)),
            "available",
            None,
            None,
            Some(source_id),
            &now,
        )
        .await
        .map_err(|e| e.to_string())?;
    Ok(
        json!({"type":"wonderArtifact","file":{"id":id,"name":name,"mimeType":mime,
        "byteSize":bytes.len(),"sha256":digest,"state":"available","updatedAt":now}}),
    )
}

/// Images the owner attached to a prompt in Claude Code or the Claude desktop
/// app arrive as base64 blocks in the user item. Store each one as a verified
/// conversation file (same MIME, size and integrity checks as tool media) and
/// list them as the bubble's `attachmentIds`. A history refresh reuses the
/// stored file instead of decoding the image again.
async fn user_images(
    state: &AppState,
    conversation: &str,
    turn: &str,
    item_id: &str,
    mut item: Value,
) -> Result<Value, String> {
    let positions: Vec<usize> = item["content"]
        .as_array()
        .map(|content| {
            content
                .iter()
                .enumerate()
                .filter(|(_, block)| {
                    block["type"] == "image"
                        && (block["data"].is_string() || block["unavailable"].is_string())
                })
                .map(|(position, _)| position)
                .collect()
        })
        .unwrap_or_default();
    if positions.is_empty() {
        return Ok(item);
    }
    let Some((storage, _, _)) = media_scope(state, conversation).await? else {
        return Ok(item);
    };
    let existing = state
        .store
        .list_conversation_files(conversation)
        .await
        .map_err(|e| e.to_string())?;
    let mut ids = Vec::new();
    let mut total = 0;
    for (index, position) in positions.iter().enumerate() {
        let source_id = format!("user-media:{turn}:{item_id}:{index}");
        let block = &mut item["content"][*position];
        if let Some(file) = existing
            .iter()
            .find(|file| file.source_id.as_deref() == Some(&source_id) && file.state == "available")
        {
            ids.push(json!(file.id));
            *block = json!({"type":"wonderArtifact","file":{"id":file.id,"name":file.name,
                "mimeType":file.mime_type,"byteSize":file.byte_size,"sha256":file.sha256,
                "state":file.state,"updatedAt":file.updated_at}});
            continue;
        }
        // An image the owner attached is never replaced by words in their
        // message; an unusable one keeps only the reason, without bytes.
        let decoded = match block["unavailable"].as_str() {
            Some(reason) => Err(reason.to_owned()),
            None => decode(block).map_err(str::to_owned),
        };
        let checked = match decoded {
            Ok((bytes, _, _)) if total + bytes.len() > 16 * 1024 * 1024 => {
                Err("These images exceed the preview size limit".to_owned())
            }
            Ok((bytes, mime, _)) => {
                total += bytes.len();
                tokio::task::spawn_blocking(move || {
                    validate(&bytes, &mime)
                        .map(|_| (bytes, mime))
                        .map_err(str::to_owned)
                })
                .await
                .map_err(|e| e.to_string())?
            }
            Err(reason) => Err(reason),
        };
        let (bytes, mime) = match checked {
            Ok(file) => file,
            Err(reason) => {
                *block = json!({"type":"imageUnavailable","reason":reason});
                continue;
            }
        };
        let extension = mime.trim_start_matches("image/").replace("jpeg", "jpg");
        let name = if positions.len() == 1 {
            format!("Image.{extension}")
        } else {
            format!("Image {}.{extension}", index + 1)
        };
        let id_seed = format!("user-media:{conversation}:{turn}:{item_id}:{index}");
        let file = store(
            state,
            conversation,
            &storage,
            &id_seed,
            &source_id,
            &name,
            &mime,
            &bytes,
        )
        .await?;
        ids.push(file["file"]["id"].clone());
        item["content"][*position] = file;
    }
    item["attachmentIds"] = Value::Array(ids);
    Ok(item)
}
/// Where verified previews are stored and which folders a tool image may be
/// read from. Project previews use Wonder storage, never the project folder.
async fn media_scope(
    state: &AppState,
    conversation: &str,
) -> Result<Option<(String, Vec<String>, Option<String>)>, String> {
    let temp = [
        std::env::temp_dir().to_string_lossy().into_owned(),
        "/tmp".to_owned(),
    ];
    if let Some(project) = state
        .store
        .project_conversation(conversation)
        .await
        .map_err(|e| e.to_string())?
    {
        let storage = crate::projects::media_workspace(state, conversation)
            .await
            .ok_or("Preview storage unavailable")?;
        let mut roots = state
            .store
            .project(&project.project_id)
            .await
            .map_err(|e| e.to_string())?
            .map(|p| {
                p.roots
                    .into_iter()
                    .map(|r| r.canonical_path)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        roots.extend(temp);
        return Ok(Some((storage, roots, None)));
    }
    let Some(bot) = bot_for_conversation(state, conversation)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };
    let access = state
        .store
        .bot_file_access(&bot.id)
        .await
        .map_err(|e| e.to_string())?;
    let mut roots = vec![
        bot.workspace_path.clone(),
        bot.execution_directory().to_owned(),
    ];
    roots.extend(temp);
    roots.extend(access.read_roots);
    roots.extend(access.write_roots);
    Ok(Some((
        bot.workspace_path.clone(),
        roots,
        Some(bot.workspace_path),
    )))
}

fn local_image(
    path: &str,
    roots: &[String],
    denies: &[String],
    workspace: Option<&str>,
) -> Result<(Vec<u8>, String, String), &'static str> {
    let path =
        std::fs::canonicalize(path).map_err(|_| "The image is no longer available on your Mac")?;
    let allowed = roots
        .iter()
        .filter_map(|root| std::fs::canonicalize(root).ok())
        .any(|root| path.starts_with(root));
    let owned = workspace.and_then(|p| std::fs::canonicalize(p).ok());
    let denied = denies
        .iter()
        .filter_map(|root| std::fs::canonicalize(root.trim_end_matches("/**")).ok())
        .any(|root| {
            path.starts_with(&root)
                && !owned.as_ref().is_some_and(|own| {
                    path.starts_with(own) && own != &root && own.starts_with(&root)
                })
        });
    if !allowed || denied {
        return Err("This image is outside the allowed file locations");
    }
    let file = std::fs::File::open(&path).map_err(|_| "The image could not be opened")?;
    let metadata = file
        .metadata()
        .map_err(|_| "The image could not be checked")?;
    if !metadata.is_file() || metadata.len() > MAX_ATTACHMENT_BYTES as u64 {
        return Err("Image is not a regular file or is larger than 8 MB");
    }
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(
        &mut std::io::Read::take(file, MAX_ATTACHMENT_BYTES as u64 + 1),
        &mut bytes,
    )
    .map_err(|_| "The image could not be read")?;
    if bytes.len() > MAX_ATTACHMENT_BYTES {
        return Err("Image is larger than 8 MB");
    }
    let mime = image::guess_format(&bytes)
        .map_err(|_| "Invalid image")?
        .to_mime_type()
        .to_owned();
    validate(&bytes, &mime)?;
    Ok((
        bytes,
        mime,
        path.file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
    ))
}

fn unavailable(reason: &str) -> Value {
    json!({"type":"text","text":format!("Preview unavailable: {reason}.")})
}
fn collect(value: &Value, path: Vec<String>, paths: &mut Vec<Vec<String>>, depth: usize) {
    if depth > 12 {
        return;
    }
    match value {
        Value::Array(values) => {
            for (index, value) in values.iter().enumerate() {
                let mut next = path.clone();
                next.push(index.to_string());
                collect(value, next, paths, depth + 1);
            }
        }
        Value::Object(fields) => {
            if matches!(
                fields.get("type").and_then(Value::as_str),
                Some("image" | "inputImage" | "input_image" | "resource" | "resource_link")
            ) {
                paths.push(path);
                return;
            }
            for key in ["content", "contentItems"] {
                if let Some(value) = fields.get(key) {
                    let mut next = path.clone();
                    next.push(key.into());
                    collect(value, next, paths, depth + 1);
                }
            }
        }
        _ => {}
    }
}
fn at_mut<'a>(value: &'a mut Value, path: &[String]) -> Option<&'a mut Value> {
    let Some((first, rest)) = path.split_first() else {
        return Some(value);
    };
    let next = match value {
        Value::Array(values) => values.get_mut(first.parse::<usize>().ok()?)?,
        _ => value.get_mut(first)?,
    };
    at_mut(next, rest)
}
fn decode(value: &Value) -> Result<(Vec<u8>, String, String), &'static str> {
    let resource = value.get("resource").unwrap_or(value);
    let mut mime = resource
        .get("mimeType")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let mut encoded = resource
        .get("data")
        .or_else(|| resource.get("blob"))
        .and_then(Value::as_str);
    if encoded.is_none() {
        if let Some(url) = resource
            .get("imageUrl")
            .or_else(|| resource.get("image_url"))
            .and_then(Value::as_str)
        {
            let (header, body) = url
                .strip_prefix("data:")
                .and_then(|s| s.split_once(";base64,"))
                .ok_or("Ask the Bot to attach this image as a file")?;
            mime = header.into();
            encoded = Some(body);
        }
    }
    let bytes = if let Some(encoded) = encoded {
        if encoded.len() > MAX_ATTACHMENT_BYTES.div_ceil(3) * 4 {
            return Err("File is larger than 8 MB");
        }
        base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| "Invalid encoded file")?
    } else if let Some(text) = resource.get("text").and_then(Value::as_str) {
        if text.len() > MAX_ATTACHMENT_BYTES {
            return Err("File is larger than 8 MB");
        }
        if mime.is_empty() {
            mime = "text/plain".into();
        }
        text.as_bytes().to_vec()
    } else {
        return Err("Ask the Bot to attach this resource as a file");
    };
    if bytes.is_empty() || bytes.len() > MAX_ATTACHMENT_BYTES {
        return Err("File is empty or larger than 8 MB");
    }
    if mime.is_empty() && value.get("type").and_then(Value::as_str) == Some("image") {
        mime = image::guess_format(&bytes)
            .map_err(|_| "Invalid image")?
            .to_mime_type()
            .to_owned();
    }
    let extension = match mime.as_str() {
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "application/pdf" => "pdf",
        "text/plain" => "txt",
        "text/markdown" => "md",
        _ => return Err("This file type is not supported"),
    };
    Ok((bytes, mime, format!("Tool result.{extension}")))
}
fn validate(bytes: &[u8], mime: &str) -> Result<(), &'static str> {
    if mime.starts_with("image/") {
        let format = image::guess_format(bytes).map_err(|_| "Invalid image")?;
        if format.to_mime_type() != mime {
            return Err("Image type does not match its contents");
        }
        let mut reader = image::ImageReader::with_format(std::io::Cursor::new(bytes), format);
        let mut limits = image::Limits::default();
        limits.max_image_width = Some(8192);
        limits.max_image_height = Some(8192);
        limits.max_alloc = Some(64 * 1024 * 1024);
        reader.limits(limits);
        reader
            .decode()
            .map_err(|_| "Image is damaged or exceeds preview limits")?;
    } else if mime == "application/pdf" {
        if artifact_mime_type("result.pdf", bytes) != Some(mime) {
            return Err("Invalid PDF");
        }
    } else if std::str::from_utf8(bytes).is_err() {
        return Err("Invalid text file");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn images_the_owner_attached_on_the_mac_become_verified_bubble_attachments() {
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        let mut encoded = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(32, 32)
            .write_to(&mut encoded, image::ImageFormat::Png)
            .unwrap();
        let bytes = encoded.into_inner();
        let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
        // The bridge's projection of a Claude Code prompt with two images, one
        // too large to forward, plus a block that claims to be a PNG.
        let raw = json!({"type":"userMessage","id":"prompt","content":[
            {"type":"text","text":"What changed in [Image #1]?"},
            {"type":"image","mimeType":"image/png","data":data},
            {"type":"image","mimeType":"image/png","unavailable":"This image is larger than 8 MB"},
            {"type":"image","mimeType":"image/png","data":"bm90IGFuIGltYWdl"},
        ]});
        let first = normalize(&state, "bot", "turn", &raw).await.unwrap();
        let ids = first["attachmentIds"].as_array().unwrap().clone();
        assert_eq!(ids.len(), 1, "{first}");
        let file = &first["content"][1]["file"];
        assert_eq!(file["id"], ids[0]);
        assert_eq!(file["mimeType"], "image/png");
        assert_eq!(file["sha256"], hex::encode(Sha256::digest(&bytes)));
        assert_eq!(first["content"][2]["type"], "imageUnavailable");
        assert_eq!(first["content"][3]["type"], "imageUnavailable");
        assert!(
            first.to_string().len() < 2048,
            "No base64 reaches projection"
        );
        // Words stay the owner's; nothing is appended to them.
        assert_eq!(
            crate::extract_text(&first).as_deref(),
            Some("What changed in [Image #1]?")
        );
        let stored = state
            .store
            .list_conversation_files("bot")
            .await
            .unwrap()
            .into_iter()
            .find(|f| Some(f.id.as_str()) == ids[0].as_str())
            .unwrap();
        assert_eq!(stored.name, "Image 1.png");
        assert_eq!(stored.byte_size, Some(bytes.len() as i64));
        // A history refresh resolves to the same file.
        let again = normalize(&state, "bot", "turn", &raw).await.unwrap();
        assert_eq!(again["attachmentIds"], first["attachmentIds"]);
        // A prompt Wonder sent keeps its own attachment records.
        let sent = json!({"type":"userMessage","id":"sent","content":[
            {"type":"text","text":"hi"},{"type":"localImage","path":"/tmp/a.png"}]});
        assert_eq!(normalize(&state, "bot", "turn", &sent).await.unwrap(), sent);
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn generated_images_survive_projection_replay_and_authenticated_download() {
        use axum::body::to_bytes;
        use tower::ServiceExt;
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        for (index, format) in [image::ImageFormat::Png, image::ImageFormat::Jpeg]
            .into_iter()
            .enumerate()
        {
            let mut encoded = std::io::Cursor::new(Vec::new());
            image::DynamicImage::new_rgb8(128, 128)
                .write_to(&mut encoded, format)
                .unwrap();
            let bytes = encoded.into_inner();
            let raw = json!({"id":format!("generated-{index}"),"type":"imageGeneration","status":"completed",
                "result":base64::engine::general_purpose::STANDARD.encode(&bytes),
                "savedPath":"/private/not-readable/generated.png","failure":null});
            let first = normalize(&state, "bot", "turn", &raw).await.unwrap();
            let file = &first["result"]["content"][0]["file"];
            assert_eq!(file["mimeType"], format.to_mime_type());
            assert_eq!(file["sha256"], hex::encode(Sha256::digest(&bytes)));
            assert_eq!(file["byteSize"], bytes.len());
            assert!(first.get("savedPath").is_none());
            let detail = thread_item_upsert_detail("turn", &first, "completed", None).unwrap();
            let projected: Value = serde_json::from_str(&detail).unwrap();
            assert_eq!(
                projected["item"]["result"]["content"][0]["file"]["id"],
                file["id"]
            );
            assert!(!detail.contains(raw["result"].as_str().unwrap()));
            let replay = normalize(&state, "bot", "turn", &raw).await.unwrap();
            assert_eq!(replay["result"]["content"][0]["file"]["id"], file["id"]);
            assert_eq!(
                normalize(&state, "bot", "turn", &first).await.unwrap(),
                first
            );
            let uri = format!(
                "/api/v1/conversations/bot/files/{}",
                file["id"].as_str().unwrap()
            );
            let response = router(state.clone())
                .oneshot(
                    Request::builder()
                        .uri(&uri)
                        .header("x-wonder-loopback-capability", &state.loopback_capability)
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(response.headers()["content-type"], format.to_mime_type());
            assert_eq!(
                to_bytes(response.into_body(), MAX_ATTACHMENT_BYTES)
                    .await
                    .unwrap()
                    .as_ref(),
                bytes
            );
            let denied = router(state.clone())
                .oneshot(Request::builder().uri(&uri).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_ne!(denied.status(), StatusCode::OK);
        }
        assert_eq!(
            state
                .store
                .list_conversation_files("bot")
                .await
                .unwrap()
                .len(),
            2
        );
    }

    #[tokio::test]
    async fn invalid_generated_images_are_inert_and_never_read_saved_paths() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let path = dir.path().join("valid.png");
        image::DynamicImage::new_rgb8(2, 2).save(&path).unwrap();
        for result in [
            Value::Null,
            json!(""),
            json!("invalid base64"),
            json!(base64::engine::general_purpose::STANDARD.encode(b"not an image")),
            json!("A".repeat(MAX_ATTACHMENT_BYTES.div_ceil(3) * 4 + 4)),
        ] {
            let raw = json!({"id":"bad","type":"imageGeneration","status":"completed","result":result,"savedPath":path});
            let normalized = normalize(&state, "bot", "turn", &raw).await.unwrap();
            assert_eq!(normalized["result"]["content"][0]["type"], "text");
            assert!(normalized["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .starts_with("Preview unavailable:"));
            assert!(normalized.get("savedPath").is_none());
        }
        let pending =
            json!({"id":"pending","type":"imageGeneration","status":"inProgress","result":null});
        assert_eq!(
            normalize(&state, "bot", "turn", &pending).await.unwrap(),
            pending
        );
        let failure = json!({"id":"failed","type":"imageGeneration","status":"failed","result":null,"failure":"Generation failed"});
        assert_eq!(
            normalize(&state, "bot", "turn", &failure).await.unwrap(),
            failure
        );
        assert!(state
            .store
            .list_conversation_files("bot")
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn local_image_view_becomes_a_replay_safe_file_and_denied_paths_stay_private() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let path = dir.path().join("screenshot.png");
        image::DynamicImage::new_rgb8(2, 2).save(&path).unwrap();
        let raw = json!({"id":"local-picture","type":"imageView","path":path});
        let normalized = normalize(&state, "bot", "turn", &raw).await.unwrap();
        assert_eq!(normalized["result"]["content"][0]["type"], "wonderArtifact");
        std::fs::remove_file(&path).unwrap();
        let replay = normalize(&state, "bot", "turn", &raw).await.unwrap();
        image::DynamicImage::new_rgb8(2, 2).save(&path).unwrap();
        assert_eq!(
            normalized["result"]["content"][0]["file"]["id"],
            replay["result"]["content"][0]["file"]["id"]
        );
        assert!(local_image(path.to_str().unwrap(), &[], &[], None).is_err());
        let root = dir.path().to_string_lossy().into_owned();
        assert!(local_image(
            path.to_str().unwrap(),
            std::slice::from_ref(&root),
            std::slice::from_ref(&root),
            None
        )
        .is_err());
        std::fs::write(&path, b"not an image").unwrap();
        assert!(local_image(path.to_str().unwrap(), &[root], &[], None).is_err());
    }

    #[tokio::test]
    async fn replay_keeps_one_verified_authenticated_file() {
        use axum::body::to_bytes;
        use tower::ServiceExt;
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(2, 2)
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let bytes = png.into_inner();
        assert!(validate(&bytes, "image/jpeg").is_err());
        let raw = json!({"id":"image-item","type":"mcpToolCall","result":{"content":[
            {"type":"text","text":"Result"},{"type":"image","mimeType":"image/png","data":base64::engine::general_purpose::STANDARD.encode(&bytes)}]}});
        let first = normalize(&state, "bot", "turn", &raw).await.unwrap();
        let second = normalize(&state, "bot", "turn", &raw).await.unwrap();
        let file = &first["result"]["content"][1]["file"];
        assert_eq!(file["id"], second["result"]["content"][1]["file"]["id"]);
        assert_eq!(
            state
                .store
                .list_conversation_files("bot")
                .await
                .unwrap()
                .len(),
            1
        );
        assert!(!first.to_string().contains("\"data\""));
        let uri = format!(
            "/api/v1/conversations/bot/files/{}",
            file["id"].as_str().unwrap()
        );
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .uri(&uri)
                    .header("x-wonder-loopback-capability", &state.loopback_capability)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            to_bytes(response.into_body(), MAX_ATTACHMENT_BYTES)
                .await
                .unwrap()
                .as_ref(),
            bytes
        );
        let denied = router(state.clone())
            .oneshot(Request::builder().uri(&uri).body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_ne!(denied.status(), StatusCode::OK);
        // The reference resolves to the complete persisted bytes.
        let bot = bot_for_conversation(&state, "bot").await.unwrap().unwrap();
        let path = attachment_path(&bot.workspace_path, file["id"].as_str().unwrap(), false)
            .await
            .unwrap();
        assert_eq!(tokio::fs::read(path).await.unwrap(), bytes);
    }

    #[test]
    fn rejects_external_resources_and_malformed_images() {
        assert!(
            decode(&json!({"type":"inputImage","imageUrl":"https://example.com/private"})).is_err()
        );
        assert!(decode(&json!({"type":"resource_link","uri":"file:///private/secret"})).is_err());
        assert!(validate(b"\x89PNG\r\n\x1a\n", "image/png").is_err());
        assert!(validate(b"%PDF-1.7", "application/pdf").is_err());
    }
    #[test]
    fn mixed_output_preserves_text_and_locates_only_media() {
        let mut value = json!({"result":{"content":[{"type":"text","text":"Keep this"},{"type":"image","mimeType":"image/png","data":"bad"}]}});
        let mut paths = vec![];
        collect(&value["result"], vec!["result".into()], &mut paths, 0);
        assert_eq!(paths.len(), 1);
        *at_mut(&mut value, &paths[0]).unwrap() = unavailable("Invalid image");
        assert_eq!(value["result"]["content"][0]["text"], "Keep this");
        assert!(!value.to_string().contains("\"data\""));
        let file =
            decode(&json!({"type":"resource","resource":{"text":"notes","mimeType":"text/plain"}}))
                .unwrap();
        assert_eq!(file.0, b"notes");
    }
}
