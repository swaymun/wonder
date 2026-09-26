//! Local transcript projection and independent runtime hydration.
use super::*;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ConversationMessage {
    pub(super) message_id: String,
    pub(super) client_message_id: String,
    pub(super) original_body_sha256: Option<String>,
    pub(super) body: String,
    pub(super) state: String,
    pub(super) created_at: String,
    pub(super) body_sha256: String,
    pub(super) codex_thread_id: Option<String>,
    pub(super) codex_turn_id: Option<String>,
    pub(super) attachment_ids: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ConversationAssistantMessage {
    pub(super) message_id: String,
    pub(super) codex_thread_id: String,
    pub(super) codex_turn_id: String,
    pub(super) item_id: String,
    pub(super) text: String,
    pub(super) state: String,
    pub(super) created_at: String,
    pub(super) updated_at: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ConversationSnapshot {
    pub(super) initialization: Option<wonder_store::BotInitialization>,
    pub(super) conversation_id: String,
    pub(super) host_epoch: String,
    pub(super) last_sequence: u64,
    pub(super) codex_thread_id: Option<String>,
    pub(super) messages: Vec<ConversationMessage>,
    pub(super) assistant_messages: Vec<ConversationAssistantMessage>,
    pub(super) thread: ConversationThreadProjection,
    pub(super) events: Vec<HostEventEnvelope>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ConversationThreadProjection {
    pub(super) thread_id: Option<String>,
    pub(super) turns: Vec<ConversationTurn>,
    pub(super) next_cursor: Option<String>,
    pub(super) hydrated: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ConversationTurn {
    pub(super) started_at: Option<String>,
    pub(super) completed_at: Option<String>,
    pub(super) id: String,
    pub(super) status: String,
    pub(super) created_at: String,
    pub(super) updated_at: String,
    pub(super) items: Vec<ConversationThreadItem>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ConversationThreadItem {
    pub(super) id: String,
    #[serde(rename = "type")]
    pub(super) item_type: String,
    pub(super) state: String,
    pub(super) text: Option<String>,
    pub(super) payload: serde_json::Value,
    pub(super) created_at: String,
    pub(super) updated_at: String,
    #[serde(skip)]
    pub(super) source_rank: u8,
    /// Lifecycle authority is separate from source rank: a richer hydrated
    /// payload must not turn a known-running status-less item into completed.
    #[serde(skip)]
    pub(super) lifecycle_authority: u8,
}

#[derive(Clone, Debug)]
pub(super) struct AppServerThreadItem {
    pub(super) turn_id: String,
    pub(super) item: serde_json::Value,
}

pub(super) fn thread_item_type_for_activity(category: &str) -> (&'static str, Option<String>) {
    match category.to_ascii_lowercase().as_str() {
        "command" => ("commandExecution", None),
        "file change" | "file" => ("fileChange", None),
        "mcp tool" | "tool" => ("mcpToolCall", None),
        "search" | "web search" => ("webSearch", None),
        "plan" => ("plan", None),
        "reasoning" => ("reasoning", None),
        "compaction" | "context compaction" => ("contextCompaction", None),
        "collaboration" | "collab" => ("collabAgentToolCall", None),
        "image" | "image view" => ("imageView", None),
        "image generation" | "generated image" => ("imageGeneration", None),
        "approval" => ("approval", None),
        "error" => ("error", None),
        _ => ("unknown", Some(category.to_owned())),
    }
}

pub(super) fn thread_activity_payload(
    category: &str,
    detail: Option<&String>,
) -> serde_json::Value {
    if let Some(detail) = detail {
        if let Ok(serde_json::Value::Object(mut object)) =
            serde_json::from_str::<serde_json::Value>(detail)
        {
            object
                .entry("category")
                .or_insert_with(|| serde_json::Value::String(category.to_owned()));
            return serde_json::Value::Object(object);
        }
    }
    let detail_value = detail
        .cloned()
        .map(serde_json::Value::String)
        .unwrap_or(serde_json::Value::Null);
    match category.to_ascii_lowercase().as_str() {
        "command" => serde_json::json!({ "category": category, "command": detail_value }),
        "file change" | "file" => serde_json::json!({
            "category": category,
            "paths": detail.map(String::as_str).unwrap_or("").split(", ").filter(|path| !path.is_empty()).collect::<Vec<_>>(),
        }),
        "search" | "web search" => {
            serde_json::json!({ "category": category, "query": detail_value })
        }
        "compaction" | "context compaction" => {
            serde_json::json!({ "category": category, "summary": detail_value })
        }
        "mcp tool" | "tool" => serde_json::json!({ "category": category, "tool": detail_value }),
        _ => serde_json::json!({ "category": category, "detail": detail_value }),
    }
}

pub(super) fn ensure_conversation_turn(
    turns: &mut HashMap<String, ConversationTurn>,
    order: &mut Vec<String>,
    turn_id: &str,
    created_at: &str,
    updated_at: &str,
) {
    if !turns.contains_key(turn_id) {
        order.push(turn_id.to_owned());
        turns.insert(
            turn_id.to_owned(),
            ConversationTurn {
                started_at: None,
                completed_at: None,
                id: turn_id.to_owned(),
                status: "unknown".into(),
                created_at: created_at.to_owned(),
                updated_at: updated_at.to_owned(),
                items: Vec::new(),
            },
        );
    }
    if let Some(turn) = turns.get_mut(turn_id) {
        if created_at < turn.created_at.as_str() {
            turn.created_at = created_at.to_owned();
        }
        if updated_at > turn.updated_at.as_str() {
            turn.updated_at = updated_at.to_owned();
        }
    }
}

pub(super) fn thread_item_state(value: &str) -> &'static str {
    match value.to_ascii_lowercase().as_str() {
        "started" => "started",
        "working" | "running" | "streaming" | "updated" | "inprogress" | "in_progress"
        | "in-progress" => "streaming",
        "completed" | "complete" | "available" => "completed",
        "failed" | "error" => "failed",
        "interrupted" | "aborted" => "interrupted",
        "waiting" | "pending" => "waiting",
        _ => "unknown",
    }
}

pub(super) fn thread_item_state_rank(state: &str) -> u8 {
    match state {
        "unknown" => 0,
        "started" => 1,
        "waiting" => 2,
        "streaming" => 3,
        "completed" | "failed" | "interrupted" => 4,
        _ => 0,
    }
}

pub(super) fn upsert_conversation_thread_item(
    turn: &mut ConversationTurn,
    incoming: ConversationThreadItem,
) {
    upsert_conversation_thread_item_at(turn, incoming, 1);
}

pub(super) fn upsert_durable_thread_item(
    turn: &mut ConversationTurn,
    incoming: ConversationThreadItem,
) {
    upsert_conversation_thread_item_at(turn, incoming, 2);
}

pub(super) fn upsert_conversation_thread_item_at(
    turn: &mut ConversationTurn,
    mut incoming: ConversationThreadItem,
    source_rank: u8,
) {
    incoming.source_rank = source_rank;
    let Some(index) = turn.items.iter().position(|item| item.id == incoming.id) else {
        turn.items.push(incoming);
        return;
    };
    let existing = &mut turn.items[index];
    let durable_created_at =
        if existing.item_type == "agentMessage" && incoming.item_type == "agentMessage" {
            if incoming.source_rank == 2 {
                Some(incoming.created_at.clone())
            } else if existing.source_rank == 2 {
                Some(existing.created_at.clone())
            } else {
                None
            }
        } else {
            None
        };
    let preserve_payload_state_tiebreaker =
        existing.item_type != "contextCompaction" && incoming.item_type != "contextCompaction";
    let incoming_rank = thread_item_state_rank(&incoming.state);
    let existing_rank = thread_item_state_rank(&existing.state);
    let replace_payload = incoming.source_rank > existing.source_rank
        || (incoming.source_rank == existing.source_rank
            && if preserve_payload_state_tiebreaker {
                incoming_rank > existing_rank
                    || (incoming_rank == existing_rank
                        && incoming.updated_at >= existing.updated_at)
            } else {
                incoming.updated_at >= existing.updated_at
            });
    // Durable text has no phase column. Keep actual lifecycle metadata instead
    // of interpreting every completed assistant item as a final answer.
    let phase = if existing.item_type == "agentMessage" && incoming.item_type == "agentMessage" {
        let (preferred, fallback) = if replace_payload {
            (&incoming.payload, &existing.payload)
        } else {
            (&existing.payload, &incoming.payload)
        };
        preferred
            .get("phase")
            .filter(|v| !v.is_null())
            .or_else(|| fallback.get("phase").filter(|v| !v.is_null()))
            .cloned()
    } else {
        None
    };
    if replace_payload {
        existing.source_rank = incoming.source_rank;
        existing.item_type = incoming.item_type.clone();
        if incoming.text.is_some() {
            existing.text = incoming.text.clone();
        }
        existing.payload = incoming.payload.clone();
    }
    if let (Some(phase), Some(payload)) = (phase, existing.payload.as_object_mut()) {
        payload.insert("phase".into(), phase);
    }
    let compaction_lifecycle =
        existing.item_type == "contextCompaction" || incoming.item_type == "contextCompaction";
    // Keep the pre-existing monotonic rank behavior for every ordinary item:
    // a reconnect may hydrate a completed command after item/started was seen.
    // Compaction is the exception because its typed payload is intentionally
    // status-less and must not infer completed over an explicit lifecycle.
    let lifecycle_wins = if compaction_lifecycle {
        incoming.lifecycle_authority > existing.lifecycle_authority
            || (incoming.lifecycle_authority == existing.lifecycle_authority
                && (incoming_rank > existing_rank
                    || (incoming_rank == existing_rank
                        && incoming.updated_at >= existing.updated_at)))
    } else {
        incoming_rank > existing_rank
            || (incoming_rank == existing_rank && incoming.updated_at >= existing.updated_at)
    };
    if existing_rank < 4 && lifecycle_wins {
        existing.state = incoming.state;
        existing.lifecycle_authority = incoming.lifecycle_authority;
    }
    if incoming.created_at < existing.created_at {
        existing.created_at = incoming.created_at;
    }
    if let Some(timestamp) = durable_created_at {
        existing.created_at = timestamp;
    }
    if incoming.updated_at > existing.updated_at {
        existing.updated_at = incoming.updated_at;
    }
}

pub(super) fn known_thread_item_type(item_type: &str) -> bool {
    matches!(
        item_type,
        "userMessage"
            | "hookPrompt"
            | "agentMessage"
            | "functionCallOutput"
            | "reasoning"
            | "commandExecution"
            | "fileChange"
            | "mcpToolCall"
            | "dynamicToolCall"
            | "subAgentActivity"
            | "webSearch"
            | "plan"
            | "imageView"
            | "imageGeneration"
            | "sleep"
            | "enteredReviewMode"
            | "exitedReviewMode"
            | "collabAgentToolCall"
            | "contextCompaction"
            | "approval"
            | "error"
    )
}

pub(super) fn typed_item_timestamp(item: &serde_json::Value, fallback: &str) -> String {
    item.get("createdAt")
        .or_else(|| item.get("created_at"))
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
        .to_owned()
}

pub(super) fn item_state_from_value(item: &serde_json::Value) -> &'static str {
    item.get("status")
        .or_else(|| item.get("state"))
        .and_then(|value| {
            value
                .as_str()
                .or_else(|| value.get("type").and_then(serde_json::Value::as_str))
        })
        .map(thread_item_state)
        .unwrap_or_else(
            || match item.get("type").and_then(serde_json::Value::as_str) {
                // ContextCompactionThreadItem is intentionally status-less;
                // completion is supplied by item lifecycle or the terminal
                // turn, never inferred from the typed payload.
                Some("contextCompaction") => "unknown",
                Some(
                    "agentMessage" | "reasoning" | "plan" | "commandExecution" | "fileChange"
                    | "mcpToolCall" | "dynamicToolCall",
                ) => "completed",
                Some(_) => "completed",
                None => "unknown",
            },
        )
}

pub(super) fn sanitize_ansi_and_secrets(value: &str, limit: usize) -> String {
    let mut clean = String::with_capacity(value.len().min(limit));
    let mut chars = value.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for next in chars.by_ref() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
            }
            continue;
        }
        clean.push(ch);
        if clean.len() >= limit {
            break;
        }
    }
    for prefix in ["sk-", "ghp_", "github_pat_", "xoxb-", "Bearer ", "token="] {
        let mut offset = 0;
        while let Some(found) = clean[offset..].find(prefix) {
            let start = offset + found;
            let end = clean[start + prefix.len()..]
                .find(char::is_whitespace)
                .map(|idx| start + prefix.len() + idx)
                .unwrap_or(clean.len());
            clean.replace_range(start..end, "[redacted]");
            offset = start + "[redacted]".len();
            if offset >= clean.len() {
                break;
            }
        }
    }
    clean
}

pub(super) fn sanitize_path_value(value: &str, workspace: Option<&str>) -> String {
    if !FsPath::new(value).is_absolute() {
        return value.to_owned();
    }
    if workspace.is_some_and(|root| FsPath::new(value) == FsPath::new(root)) {
        return ".".into();
    }
    workspace
        .and_then(|root| sanitized_relative_path(value, root))
        .unwrap_or_else(|| "[path outside workspace]".into())
}

pub(super) fn sensitive_projection_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase().replace(['_', '-'], "");
    normalized == "env"
        || normalized.contains("environment")
        || normalized.contains("header")
        || normalized.contains("credential")
        || normalized.contains("authorization")
        || normalized.contains("cookie")
        || normalized.contains("approvalpayload")
        || normalized == "method"
}

pub(super) fn secret_projection_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase().replace(['_', '-'], "");
    normalized.contains("token")
        || normalized.contains("secret")
        || normalized.contains("apikey")
        || normalized.contains("password")
}

pub(super) fn projection_path_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase().replace(['_', '-'], "");
    normalized == "cwd" || normalized.ends_with("path")
}

pub(super) fn projection_paths_key(key: &str) -> bool {
    key.to_ascii_lowercase()
        .replace(['_', '-'], "")
        .ends_with("paths")
}

pub(super) fn sanitize_json_value(
    value: &mut serde_json::Value,
    limit: usize,
    workspace: Option<&str>,
) {
    match value {
        serde_json::Value::String(text) => *text = sanitize_ansi_and_secrets(text, limit),
        serde_json::Value::Array(values) => {
            for value in values {
                sanitize_json_value(value, limit, workspace);
            }
        }
        serde_json::Value::Object(values) => {
            values.retain(|key, _| !sensitive_projection_key(key));
            for (key, value) in values.iter_mut() {
                if secret_projection_key(key) {
                    *value = serde_json::Value::String("[redacted]".into());
                    continue;
                }
                if projection_path_key(key) {
                    if let Some(text) = value.as_str() {
                        *value = serde_json::Value::String(sanitize_path_value(
                            &sanitize_ansi_and_secrets(text, limit),
                            workspace,
                        ));
                        continue;
                    }
                }
                if projection_paths_key(key) {
                    if let Some(paths) = value.as_array_mut() {
                        for path in paths {
                            if let Some(text) = path.as_str() {
                                *path = serde_json::Value::String(sanitize_path_value(
                                    &sanitize_ansi_and_secrets(text, limit),
                                    workspace,
                                ));
                            } else {
                                sanitize_json_value(path, limit, workspace);
                            }
                        }
                        continue;
                    }
                }
                sanitize_json_value(value, limit, workspace);
            }
        }
        _ => {}
    }
}

pub(super) fn sanitize_typed_item(
    item: &serde_json::Value,
    workspace: Option<&str>,
) -> serde_json::Value {
    let mut value = item.clone();
    if let Some(object) = value.as_object_mut() {
        let item_type = object
            .get("type")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .to_owned();
        for key in [
            "command",
            "cwd",
            "aggregatedOutput",
            "output",
            "arguments",
            "result",
            "path",
        ] {
            if let Some(raw) = object.get_mut(key) {
                if let Some(text) = raw.as_str() {
                    let mut safe = sanitize_ansi_and_secrets(
                        text,
                        if key == "aggregatedOutput" || key == "output" {
                            64 * 1024
                        } else {
                            16 * 1024
                        },
                    );
                    if key == "cwd" || key == "path" {
                        safe = sanitize_path_value(&safe, workspace);
                    }
                    *raw = serde_json::Value::String(safe);
                } else if key == "arguments" || key == "result" {
                    sanitize_json_value(raw, 16 * 1024, workspace);
                    if serde_json::to_vec(raw).is_ok_and(|bytes| bytes.len() > 16 * 1024) {
                        *raw = serde_json::Value::String("[tool result truncated]".into());
                    }
                }
            }
        }
        if item_type == "commandExecution" {
            if let Some(output) = object.get_mut("aggregatedOutput") {
                if let Some(text) = output.as_str() {
                    *output = serde_json::Value::String(sanitize_ansi_and_secrets(text, 64 * 1024));
                }
            }
            if let Some(output) = object.remove("aggregatedOutput") {
                object.insert("output".into(), output);
            }
            object.remove("commandActions");
            object.remove("processId");
        }
        if item_type == "fileChange" && object.get("changes").is_some() {
            let mut paths = Vec::new();
            let mut diffs = Vec::new();
            let mut additions = 0usize;
            let mut deletions = 0usize;
            if let Some(changes) = object.get("changes").and_then(serde_json::Value::as_array) {
                for change in changes {
                    let path = change
                        .get("path")
                        .and_then(serde_json::Value::as_str)
                        .map(|path| {
                            sanitize_path_value(
                                &sanitize_ansi_and_secrets(path, 16 * 1024),
                                workspace,
                            )
                        });
                    if let Some(path) = &path {
                        paths.push(path.clone());
                    }
                    let diff = change
                        .get("diff")
                        .or_else(|| change.get("unified_diff"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default();
                    let kind = change
                        .get("kind")
                        .and_then(|kind| {
                            kind.as_str()
                                .or_else(|| kind.get("type").and_then(serde_json::Value::as_str))
                        })
                        .unwrap_or("update");
                    let raw_content = matches!(kind, "add" | "delete")
                        && !diff.lines().any(|line| line.starts_with("@@ "));
                    let added = if raw_content {
                        if kind == "add" {
                            diff.lines().count()
                        } else {
                            0
                        }
                    } else {
                        diff.lines()
                            .filter(|line| line.starts_with('+') && !line.starts_with("+++"))
                            .count()
                    };
                    let removed = if raw_content {
                        if kind == "delete" {
                            diff.lines().count()
                        } else {
                            0
                        }
                    } else {
                        diff.lines()
                            .filter(|line| line.starts_with('-') && !line.starts_with("---"))
                            .count()
                    };
                    let safe = sanitize_ansi_and_secrets(diff, 16 * 1024);
                    let display = if raw_content {
                        safe.lines()
                            .map(|line| format!("{}{line}", if kind == "add" { '+' } else { '-' }))
                            .collect::<Vec<_>>()
                            .join("\n")
                    } else {
                        safe
                    };
                    diffs.push(serde_json::json!({"path": path, "diff": display, "kind": kind, "additions": added, "deletions": removed}));
                    additions += added;
                    deletions += removed;
                }
            }
            object.insert("paths".into(), serde_json::json!(paths));
            object.insert("additions".into(), serde_json::json!(additions));
            object.insert("deletions".into(), serde_json::json!(deletions));
            object.insert("diffs".into(), serde_json::json!(diffs));
            object.insert("fileChangeVersion".into(), serde_json::json!(1));
            object.remove("changes");
        }
        sanitize_json_value(&mut value, 16 * 1024, workspace);
    }
    value
}

pub(super) fn typed_thread_item_projection(
    entry: &AppServerThreadItem,
    fallback_time: &str,
    workspace: Option<&str>,
) -> ConversationThreadItem {
    typed_thread_item_projection_with_lifecycle(entry, fallback_time, workspace, None, 0)
}

pub(super) fn typed_thread_item_projection_with_lifecycle(
    entry: &AppServerThreadItem,
    fallback_time: &str,
    workspace: Option<&str>,
    lifecycle_state: Option<&str>,
    lifecycle_authority: u8,
) -> ConversationThreadItem {
    let raw_type = entry
        .item
        .get("type")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let item_type = if known_thread_item_type(raw_type) {
        raw_type
    } else {
        "unknown"
    };
    let timestamp = typed_item_timestamp(&entry.item, fallback_time);
    let payload = sanitize_typed_item(&entry.item, workspace);
    let text = extract_text(&payload).map(|text| sanitize_ansi_and_secrets(&text, 16 * 1024));
    let item_lifecycle_authority = if lifecycle_state.is_some() {
        lifecycle_authority
    } else if entry.item.get("status").is_some() || entry.item.get("state").is_some() {
        1
    } else {
        0
    };
    ConversationThreadItem {
        id: entry
            .item
            .get("id")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("unknown-item")
            .to_owned(),
        item_type: item_type.to_owned(),
        state: lifecycle_state
            .map(thread_item_state)
            .unwrap_or_else(|| item_state_from_value(&entry.item))
            .into(),
        text,
        payload: if item_type == "unknown" {
            serde_json::json!({"originalType": raw_type, "raw": payload})
        } else {
            payload
        },
        created_at: timestamp.clone(),
        updated_at: timestamp,
        source_rank: 3,
        lifecycle_authority: item_lifecycle_authority,
    }
}

#[allow(dead_code)]
pub(super) fn conversation_thread_projection(
    thread_id: Option<String>,
    messages: &[wonder_store::StoredMessage],
    assistant_messages: &[wonder_store::StoredAssistantMessage],
    events: &[HostEventEnvelope],
) -> ConversationThreadProjection {
    conversation_thread_projection_with_items(
        thread_id,
        messages,
        assistant_messages,
        events,
        &[],
        None,
    )
}

pub(super) fn conversation_thread_projection_with_items(
    thread_id: Option<String>,
    messages: &[wonder_store::StoredMessage],
    assistant_messages: &[wonder_store::StoredAssistantMessage],
    events: &[HostEventEnvelope],
    app_server_items: &[AppServerThreadItem],
    workspace: Option<&str>,
) -> ConversationThreadProjection {
    let mut turns: HashMap<String, ConversationTurn> = HashMap::new();
    let mut order = Vec::new();
    for entry in app_server_items {
        let timestamp = typed_item_timestamp(&entry.item, "1970-01-01T00:00:00Z");
        ensure_conversation_turn(
            &mut turns,
            &mut order,
            &entry.turn_id,
            &timestamp,
            &timestamp,
        );
        if let Some(turn) = turns.get_mut(&entry.turn_id) {
            upsert_conversation_thread_item_at(
                turn,
                typed_thread_item_projection(entry, &timestamp, workspace),
                3,
            );
        }
    }
    for message in messages {
        let fallback_turn_id;
        let turn_id = if let Some(turn_id) = message.codex_turn_id.as_deref() {
            turn_id
        } else {
            fallback_turn_id = format!("local:{}", message.id);
            fallback_turn_id.as_str()
        };
        ensure_conversation_turn(
            &mut turns,
            &mut order,
            turn_id,
            &message.created_at,
            &message.created_at,
        );
        if let Some(turn) = turns.get_mut(turn_id) {
            let item_id = turn
                .items
                .iter()
                .find(|item| {
                    item.item_type == "userMessage"
                        && item
                            .payload
                            .get("clientId")
                            .and_then(serde_json::Value::as_str)
                            .is_some_and(|client_id| client_id == message.client_message_id)
                })
                .map(|item| item.id.clone())
                .unwrap_or_else(|| message.id.clone());
            upsert_durable_thread_item(
                turn,
                ConversationThreadItem {
                    id: item_id.clone(),
                    item_type: "userMessage".into(),
                    state: thread_item_state(&message.state).into(),
                    text: Some(message.body.clone()),
                    payload: serde_json::json!({
                        "clientId": message.client_message_id,
                        "deliveryState": message.state,
                        "attachments": []
                    }),
                    created_at: message.created_at.clone(),
                    updated_at: message.created_at.clone(),
                    source_rank: 2,
                    lifecycle_authority: 2,
                },
            );
            if let Some(item) = turn.items.iter_mut().find(|item| item.id == item_id) {
                if let Some(payload) = item.payload.as_object_mut() {
                    payload.insert(
                        "clientId".into(),
                        serde_json::Value::String(message.client_message_id.clone()),
                    );
                    payload.insert(
                        "deliveryState".into(),
                        serde_json::Value::String(message.state.clone()),
                    );
                }
            }
        }
    }
    for message in assistant_messages {
        ensure_conversation_turn(
            &mut turns,
            &mut order,
            &message.codex_turn_id,
            &message.created_at,
            &message.updated_at,
        );
        if let Some(turn) = turns.get_mut(&message.codex_turn_id) {
            upsert_durable_thread_item(
                turn,
                ConversationThreadItem {
                    id: message.item_id.clone(),
                    item_type: "agentMessage".into(),
                    state: thread_item_state(&message.state).into(),
                    text: Some(message.text.clone()),
                    payload: serde_json::json!({}),
                    created_at: message.created_at.clone(),
                    updated_at: message.updated_at.clone(),
                    source_rank: 2,
                    lifecycle_authority: 2,
                },
            );
        }
    }
    for event in events {
        let Some(turn_id) = event.turn_id.as_deref() else {
            continue;
        };
        let timestamp = event.occurred_at.clone();
        ensure_conversation_turn(&mut turns, &mut order, turn_id, &timestamp, &timestamp);
        if let Some(turn) = turns.get_mut(turn_id) {
            match &event.event {
                WonderEvent::MessageState { state } => {
                    if matches!(
                        state,
                        DeliveryState::AcceptedByCodex | DeliveryState::Streaming
                    ) && turn
                        .started_at
                        .as_ref()
                        .is_none_or(|start| timestamp < *start)
                    {
                        turn.started_at = Some(timestamp.clone());
                    }
                    if matches!(
                        state,
                        DeliveryState::Completed
                            | DeliveryState::Failed
                            | DeliveryState::Interrupted
                    ) {
                        turn.completed_at = Some(timestamp.clone());
                    }
                    turn.status = match state {
                        DeliveryState::Completed => "completed",
                        DeliveryState::Failed => "failed",
                        DeliveryState::Interrupted => "interrupted",
                        DeliveryState::Streaming
                        | DeliveryState::AcceptedByCodex
                        | DeliveryState::DispatchingToCodex => "inProgress",
                        _ => "unknown",
                    }
                    .into();
                }
                WonderEvent::ComputerUseScreenshot { image_url } => {
                    upsert_conversation_thread_item(
                        turn,
                        ConversationThreadItem {
                            id: event
                                .item_id
                                .clone()
                                .unwrap_or_else(|| event.event_id.clone()),
                            item_type: "imageView".into(),
                            state: "completed".into(),
                            text: Some("Computer screenshot".into()),
                            payload: serde_json::json!({ "imageUrl": image_url }),
                            created_at: timestamp.clone(),
                            updated_at: timestamp.clone(),
                            source_rank: 1,
                            lifecycle_authority: 1,
                        },
                    )
                }
                WonderEvent::ApprovalOpened { request_id } => upsert_conversation_thread_item(
                    turn,
                    ConversationThreadItem {
                        id: event.item_id.clone().unwrap_or_else(|| request_id.clone()),
                        item_type: "approval".into(),
                        state: "waiting".into(),
                        text: Some("Approval needed".into()),
                        payload: serde_json::json!({ "requestId": request_id }),
                        created_at: timestamp.clone(),
                        updated_at: timestamp.clone(),
                        source_rank: 1,
                        lifecycle_authority: 1,
                    },
                ),
                WonderEvent::ApprovalResolved {
                    request_id,
                    decision,
                } => upsert_conversation_thread_item(
                    turn,
                    ConversationThreadItem {
                        id: event.item_id.clone().unwrap_or_else(|| request_id.clone()),
                        item_type: "approval".into(),
                        state: "completed".into(),
                        text: Some("Approval resolved".into()),
                        payload: serde_json::json!({ "requestId": request_id, "decision": decision }),
                        created_at: timestamp.clone(),
                        updated_at: timestamp.clone(),
                        source_rank: 1,
                        lifecycle_authority: 1,
                    },
                ),
                WonderEvent::TerminalError { message } => upsert_conversation_thread_item(
                    turn,
                    ConversationThreadItem {
                        id: event
                            .item_id
                            .clone()
                            .unwrap_or_else(|| event.event_id.clone()),
                        item_type: "error".into(),
                        state: "failed".into(),
                        text: Some(message.clone()),
                        payload: serde_json::json!({}),
                        created_at: timestamp.clone(),
                        updated_at: timestamp.clone(),
                        source_rank: 1,
                        lifecycle_authority: 1,
                    },
                ),
                WonderEvent::Activity {
                    category,
                    state,
                    detail,
                } => {
                    if category == "thread_item_upsert" {
                        if let Some(detail) = detail.as_deref().and_then(|detail| {
                            serde_json::from_str::<serde_json::Value>(detail).ok()
                        }) {
                            if let (Some(turn_id), Some(item)) = (
                                detail.get("turnId").and_then(serde_json::Value::as_str),
                                detail.get("item"),
                            ) {
                                ensure_conversation_turn(
                                    &mut turns, &mut order, turn_id, &timestamp, &timestamp,
                                );
                                if let Some(target) = turns.get_mut(turn_id) {
                                    let entry = AppServerThreadItem {
                                        turn_id: turn_id.to_owned(),
                                        item: item.clone(),
                                    };
                                    let lifecycle_authority = detail
                                        .get("lifecycleAuthority")
                                        .and_then(serde_json::Value::as_u64)
                                        .map(|value| value.min(u8::MAX as u64) as u8)
                                        .unwrap_or_else(|| {
                                            // Pre-slice events did not carry an explicit authority.
                                            // Refresh events are status-less hydration; every other
                                            // stored upsert has an observed lifecycle state.
                                            if detail
                                                .get("historyRefresh")
                                                .and_then(serde_json::Value::as_bool)
                                                == Some(true)
                                            {
                                                0
                                            } else {
                                                1
                                            }
                                        });
                                    upsert_conversation_thread_item_at(
                                        target,
                                        typed_thread_item_projection_with_lifecycle(
                                            &entry,
                                            &timestamp,
                                            workspace,
                                            (lifecycle_authority > 0)
                                                .then(|| {
                                                    detail
                                                        .get("state")
                                                        .and_then(serde_json::Value::as_str)
                                                })
                                                .flatten(),
                                            lifecycle_authority,
                                        ),
                                        1,
                                    );
                                }
                            }
                        }
                        continue;
                    }
                    if matches!(
                        category.as_str(),
                        "thread/compacted" | "compaction" | "context compaction"
                    ) {
                        // Deprecated thread/compacted has no item identity. It
                        // may settle an already-known canonical marker, but it
                        // cannot fabricate one or merge separate compactions in
                        // the same turn.
                        let legacy_state = thread_item_state(state);
                        let compaction_count = turn
                            .items
                            .iter()
                            .filter(|item| item.item_type == "contextCompaction")
                            .count();
                        if compaction_count == 1 {
                            let item = turn
                                .items
                                .iter_mut()
                                .find(|item| item.item_type == "contextCompaction");
                            if let Some(item) = item {
                                if thread_item_state_rank(&item.state) < 4 {
                                    item.state = legacy_state.into();
                                    item.lifecycle_authority = item.lifecycle_authority.max(1);
                                    item.updated_at = timestamp.clone();
                                }
                            }
                        }
                        continue;
                    }
                    let (item_type, original_category) = thread_item_type_for_activity(category);
                    upsert_conversation_thread_item(
                        turn,
                        ConversationThreadItem {
                            id: event
                                .item_id
                                .clone()
                                .unwrap_or_else(|| event.event_id.clone()),
                            item_type: item_type.into(),
                            state: thread_item_state(state).into(),
                            text: detail.clone(),
                            payload: thread_activity_payload(
                                &original_category.unwrap_or_else(|| category.clone()),
                                detail.as_ref(),
                            ),
                            created_at: timestamp.clone(),
                            updated_at: timestamp.clone(),
                            source_rank: 1,
                            lifecycle_authority: 1,
                        },
                    );
                }
                WonderEvent::AssistantDelta { .. } | WonderEvent::AssistantCompleted { .. } => {}
                _ => upsert_conversation_thread_item(
                    turn,
                    ConversationThreadItem {
                        id: event
                            .item_id
                            .clone()
                            .unwrap_or_else(|| event.event_id.clone()),
                        item_type: "unknown".into(),
                        state: "unknown".into(),
                        text: None,
                        payload: serde_json::json!({ "event": event.event }),
                        created_at: timestamp.clone(),
                        updated_at: timestamp.clone(),
                        source_rank: 1,
                        lifecycle_authority: 1,
                    },
                ),
            }
        }
    }
    // Hydration and replay can add a status-less canonical item after the
    // terminal MessageState event. Reconcile once more from the final turn
    // state so that late history never leaves a compaction permanently
    // unknown.
    for turn in turns.values_mut() {
        let Some(terminal_item_state) = (match turn.status.as_str() {
            "completed" => Some("completed"),
            "failed" => Some("failed"),
            "interrupted" => Some("interrupted"),
            _ => None,
        }) else {
            continue;
        };
        let turn_updated_at = turn.updated_at.clone();
        for item in turn
            .items
            .iter_mut()
            .filter(|item| item.item_type == "contextCompaction")
        {
            if thread_item_state_rank(&item.state) < 4 {
                item.state = terminal_item_state.into();
                item.lifecycle_authority = item.lifecycle_authority.max(3);
                item.updated_at = turn_updated_at.clone();
            }
        }
    }
    let mut result = order
        .into_iter()
        .filter_map(|id| turns.remove(&id))
        .collect::<Vec<_>>();
    result.sort_by(|left, right| left.created_at.cmp(&right.created_at));
    for turn in &mut result {
        turn.items
            .sort_by(|left, right| left.created_at.cmp(&right.created_at));
        // Individual commands can fail, finish, or retain stale running state
        // while the response continues. Only turn lifecycle events set status;
        // older history without those events must remain unknown.
    }
    ConversationThreadProjection {
        thread_id,
        turns: result,
        next_cursor: None,
        hydrated: false,
    }
}

pub(super) async fn hydrate_app_server_turn_items(
    state: &AppState,
    thread_id: &str,
    target_turn: &str,
) -> Option<Vec<AppServerThreadItem>> {
    let app_server = crate::claude::for_thread(state, thread_id).await.ok()?;
    let mut cursor = None;
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for _ in 0..10_000 {
        let mut params = serde_json::json!({
            "threadId": thread_id,
            "limit": 100,
            "sortDirection": "asc",
        });
        if let Some(cursor) = cursor.take() {
            params["cursor"] = serde_json::Value::String(cursor);
        }
        let response = app_server.request("thread/items/list", params).await.ok()?;
        if response.error.is_some() {
            return None;
        }
        let result = response.result?;
        {
            let data = result.get("data").and_then(serde_json::Value::as_array)?;
            for entry in data {
                let turn_id = entry.get("turnId").and_then(serde_json::Value::as_str)?;
                let item = entry.get("item").filter(|item| item.is_object())?;
                if turn_id == target_turn {
                    items.push(AppServerThreadItem {
                        turn_id: turn_id.to_owned(),
                        item: item.clone(),
                    });
                }
            }
        }
        cursor = match result.get("nextCursor") {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(value))
                if !value.is_empty() && seen.insert(value.clone()) =>
            {
                Some(value.clone())
            }
            _ => return None,
        };
        if cursor.is_none() {
            return Some(items);
        }
    }
    None
}

pub(super) async fn conversation_snapshot(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
    Query(query): Query<HistoryQuery>,
) -> Response {
    let before = match decode_history_cursor(query.before.as_deref(), &conversation_id) {
        Ok(value) => value,
        Err(()) => {
            return (
                StatusCode::BAD_REQUEST,
                "Invalid history cursor. Open the conversation again.",
            )
                .into_response()
        }
    };
    if query.limit.is_some_and(|limit| limit == 0 || limit > 100) {
        return (
            StatusCode::BAD_REQUEST,
            "History page size must be between 1 and 100.",
        )
            .into_response();
    }
    let snapshot = match state
        .store
        .conversation_history_page(
            &state.host_epoch,
            &conversation_id,
            before.as_ref(),
            query.limit.unwrap_or(100),
        )
        .await
    {
        Ok(Some(snapshot)) => snapshot,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "conversation lookup failed",
            )
                .into_response()
        }
    };
    let wonder_store::CommittedConversationSnapshot {
        last_sequence,
        workspace_path,
        messages,
        assistant_messages,
        mut attachment_ids,
        codex_thread_id,
        events,
        next_cursor,
    } = snapshot;
    let mut thread = conversation_thread_projection_with_items(
        codex_thread_id.clone(),
        &messages,
        &assistant_messages,
        &events,
        &[],
        Some(&workspace_path),
    );
    // Old versions redacted file paths before knowing the selected workspace.
    // Repair from read-only runtime history once; local pages remain available.
    if thread
        .turns
        .iter()
        .flat_map(|turn| &turn.items)
        .any(|item| item.item_type == "fileChange" && item.payload["fileChangeVersion"] != 1)
        && state
            .store
            .needs_file_change_repair(&conversation_id, now_ms() as i64)
            .await
            .unwrap_or(false)
    {
        let _ = refresh_history(State(state.clone()), Path(conversation_id.clone())).await;
    }
    // Initialization remains durable for execution, but is not a user message.
    let internal = match state
        .store
        .bot_initialization_messages(&conversation_id)
        .await
    {
        Ok(messages) => messages,
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    };
    let initialization = match state
        .store
        .bot_initialization(&conversation_id, now_ms() as i64)
        .await
    {
        Ok(value) => value,
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    };
    let followups = match state
        .store
        .bot_workspace_followup_messages(&conversation_id)
        .await
    {
        Ok(value) => value,
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    };
    thread.turns.retain(|turn| {
        !internal.iter().any(|m| {
            m.codex_turn_id.as_deref() == Some(&turn.id) || turn.id == format!("local:{}", m.id)
        })
    });
    let assistant_messages = assistant_messages
        .into_iter()
        .filter(|m| {
            !internal
                .iter()
                .any(|hidden| hidden.codex_turn_id.as_deref() == Some(&m.codex_turn_id))
        })
        .collect::<Vec<_>>();
    let messages = messages
        .into_iter()
        .filter(|m| !internal.iter().any(|hidden| hidden.id == m.id))
        .collect::<Vec<_>>();
    let mut answers = match state.store.question_answer_messages(&conversation_id).await {
        Ok(messages) => messages,
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    };
    answers.extend(followups);
    for turn in &mut thread.turns {
        turn.items.retain(|item| {
            item.item_type != "userMessage"
                || !answers.iter().any(|m| {
                    item.id == m.id
                        || item
                            .payload
                            .get("clientId")
                            .and_then(serde_json::Value::as_str)
                            == Some(m.client_message_id.as_str())
                })
        });
    }
    let messages = messages
        .into_iter()
        .filter(|m| !answers.iter().any(|hidden| hidden.id == m.id))
        .collect::<Vec<_>>();
    thread.next_cursor = next_cursor.map(|cursor| encode_history_cursor(&conversation_id, &cursor));
    Json(ConversationSnapshot {
        initialization,
        conversation_id,
        host_epoch: state.host_epoch.clone(),
        last_sequence,
        codex_thread_id,
        messages: {
            let mut projected = Vec::with_capacity(messages.len());
            for message in messages {
                let message_attachment_ids = attachment_ids.remove(&message.id).unwrap_or_default();
                projected.push(ConversationMessage {
                    original_body_sha256: state
                        .store
                        .original_body_hash(&message.id)
                        .await
                        .ok()
                        .flatten(),
                    message_id: message.id,
                    client_message_id: message.client_message_id,
                    body: message.body,
                    state: message.state,
                    created_at: message.created_at,
                    body_sha256: message.body_sha256,
                    codex_thread_id: message.codex_thread_id,
                    codex_turn_id: message.codex_turn_id,
                    attachment_ids: message_attachment_ids,
                });
            }
            projected
        },
        assistant_messages: assistant_messages
            .into_iter()
            .map(|message| ConversationAssistantMessage {
                message_id: message.id,
                codex_thread_id: message.codex_thread_id,
                codex_turn_id: message.codex_turn_id,
                item_id: message.item_id,
                text: message.text,
                state: message.state,
                created_at: message.created_at,
                updated_at: message.updated_at,
            })
            .collect(),
        thread,
        events,
    })
    .into_response()
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct HistoryQuery {
    before: Option<String>,
    limit: Option<u32>,
}

fn encode_history_cursor(conversation: &str, cursor: &wonder_store::HistoryCursor) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(serde_json::to_vec(&(1, conversation, cursor.sort_ms, cursor.sequence)).unwrap())
}

fn decode_history_cursor(
    value: Option<&str>,
    conversation: &str,
) -> Result<Option<wonder_store::HistoryCursor>, ()> {
    let Some(value) = value else {
        return Ok(None);
    };
    if value.len() > 2048 {
        return Err(());
    }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| ())?;
    let (version, scope, sort_ms, sequence): (u8, String, i64, i64) =
        serde_json::from_slice(&bytes).map_err(|_| ())?;
    if version != 1 || scope != conversation || sequence < 1 {
        return Err(());
    }
    Ok(Some(wonder_store::HistoryCursor { sort_ms, sequence }))
}

static HISTORY_REFRESH_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

pub(super) async fn history_refresh_status(
    State(state): State<AppState>,
    Path(conversation): Path<String>,
) -> Response {
    match state.store.conversation_thread(&conversation).await {
        Ok(Some(_)) => {}
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "History is temporarily unavailable. Try again.",
            )
                .into_response()
        }
    }
    match state
        .store
        .history_refresh_status(&conversation, now_ms() as i64)
        .await
    {
        Ok(status) => Json(status).into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "History status is temporarily unavailable. Try again.",
        )
            .into_response(),
    }
}

/// The receipt acknowledges a refresh job, never completed hydration. Readers
/// keep serving local pages; failures retain saved history and can be retried.
pub(super) async fn refresh_history(
    State(state): State<AppState>,
    Path(conversation): Path<String>,
) -> Response {
    let thread = match state.store.conversation_thread(&conversation).await {
        Ok(Some(thread)) => thread,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                "No runtime history is available for this chat.",
            )
                .into_response()
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "History is temporarily unavailable. Try again.",
            )
                .into_response()
        }
    };
    let Ok(permit) = HISTORY_REFRESH_SLOTS.try_acquire() else {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            "Other history is refreshing. Try again shortly.",
        )
            .into_response();
    };
    let token = uuid::Uuid::new_v4().to_string();
    match state
        .store
        .claim_history_refresh(&conversation, &token, now_ms() as i64)
        .await
    {
        Ok(true) => {}
        Ok(false) => {
            return (
                StatusCode::ACCEPTED,
                Json(serde_json::json!({"state":"refreshing","detail":null})),
            )
                .into_response()
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "History refresh could not start. Try again.",
            )
                .into_response()
        }
    }
    tokio::spawn(async move {
        let _permit = permit;
        let result = refresh_runtime_history(&state, &conversation, &thread, &token).await;
        let (status, detail) = match result {
            Ok(()) => ("completed", None),
            Err(_) => ("failed", Some("History refresh could not finish. Saved messages are still available. Try refreshing again.")),
        };
        if let Err(error) = state
            .store
            .update_history_refresh(&conversation, &token, status, now_ms() as i64, detail)
            .await
        {
            let _ = state.logger.record(
                "error",
                "history_refresh_status_failed",
                serde_json::json!({"error":error.to_string()}),
            );
        }
    });
    (
        StatusCode::ACCEPTED,
        Json(serde_json::json!({"state":"refreshing","detail":null})),
    )
        .into_response()
}

async fn refresh_runtime_history(
    state: &AppState,
    conversation: &str,
    thread: &str,
    token: &str,
) -> Result<(), String> {
    let workspace = state
        .store
        .conversation_execution_directory(conversation)
        .await
        .map_err(|e| e.to_string())?;
    let runtime = state.app_server.lock().await.rpc();
    let mut cursor = None;
    let mut seen = std::collections::HashSet::new();
    loop {
        let response = runtime.request("thread/items/list", serde_json::json!({"threadId":thread,"limit":100,"sortDirection":"asc","cursor":cursor})).await.map_err(|e| e.to_string())?;
        if response.error.is_some() || !runtime.health().is_alive() {
            return Err("Runtime history is unavailable".into());
        }
        let result = response.result.ok_or("Missing history response")?;
        let entries = result
            .get("data")
            .and_then(serde_json::Value::as_array)
            .ok_or("Invalid history response")?;
        if entries.len() > 100 {
            return Err("Oversized history page".into());
        }
        for entry in entries {
            let turn = entry
                .get("turnId")
                .and_then(serde_json::Value::as_str)
                .ok_or("Missing history turn")?;
            let item = entry
                .get("item")
                .filter(|item| item.is_object())
                .ok_or("Missing history item")?;
            let item = tool_media::normalize(state, conversation, turn, item).await?;
            let detail = thread_item_upsert_detail(
                turn,
                &item,
                item_state_from_value(&item),
                workspace.as_deref(),
            )
            .ok_or("Missing history item identity")?;
            let mut detail: serde_json::Value =
                serde_json::from_str(&detail).map_err(|e| e.to_string())?;
            detail["historyRefresh"] = serde_json::Value::Bool(true);
            let detail = detail.to_string();
            publish_event_with_context(
                state,
                WonderEvent::Activity {
                    category: "thread_item_upsert".into(),
                    state: "updated".into(),
                    detail: Some(detail),
                },
                EventContext {
                    conversation_id: Some(conversation.into()),
                    thread_id: Some(thread.into()),
                    turn_id: Some(turn.into()),
                    item_id: item
                        .get("id")
                        .and_then(serde_json::Value::as_str)
                        .map(str::to_owned),
                    ..Default::default()
                },
            )
            .await
            .map_err(|e| e.to_string())?;
        }
        if !state
            .store
            .update_history_refresh(conversation, token, "refreshing", now_ms() as i64, None)
            .await
            .map_err(|e| e.to_string())?
        {
            return Err("Refresh superseded".into());
        }
        cursor = match result.get("nextCursor") {
            None | Some(serde_json::Value::Null) => return Ok(()),
            Some(serde_json::Value::String(value))
                if !value.is_empty() && value.len() <= 4096 && seen.insert(value.clone()) =>
            {
                Some(value.clone())
            }
            _ => return Err("Invalid history continuation".into()),
        };
        // Bound cursor bookkeeping too; this is an explicit retryable failure,
        // never a successful but silently truncated result.
        if seen.len() > 10_000 {
            return Err("History refresh page limit reached".into());
        }
        tokio::task::yield_now().await;
    }
}

#[cfg(test)]
#[path = "history_tests.rs"]
mod tests;

#[cfg(test)]
mod commentary_tests {
    #[test]
    fn file_diff_survives_sanitized_projection() {
        let value = super::sanitize_typed_item(
            &serde_json::json!({"type":"fileChange", "changes":[{"path":"/tmp/work/hello.txt", "diff":"@@ -1 +1 @@\n-old\n+new"}]}),
            Some("/tmp/work"),
        );
        assert_eq!(value["diffs"][0]["diff"], "@@ -1 +1 @@\n-old\n+new");
        assert_eq!(value["additions"], 1);
        assert_eq!(value["deletions"], 1);
        assert!(value.get("changes").is_none());
        assert_eq!(super::sanitize_typed_item(&value, Some("/tmp/work")), value);
    }

    use super::*;

    #[test]
    fn durable_text_and_lifecycle_phase_reconcile_in_either_order() {
        let entry = AppServerThreadItem {
            turn_id: "turn".into(),
            item: serde_json::json!({"id":"comment", "type":"agentMessage", "text":"Checking", "phase":"commentary"}),
        };
        let lifecycle = || typed_thread_item_projection(&entry, "1000", None);
        let durable = || {
            let mut item = lifecycle();
            item.payload = serde_json::json!({});
            item.text = Some("Checking the files".into());
            item.created_at = "2000".into();
            item
        };
        for lifecycle_first in [true, false] {
            let mut turn = ConversationTurn {
                started_at: None,
                completed_at: None,
                id: "turn".into(),
                status: "unknown".into(),
                created_at: "1000".into(),
                updated_at: "1000".into(),
                items: vec![],
            };
            if lifecycle_first {
                upsert_conversation_thread_item_at(&mut turn, lifecycle(), 1);
                upsert_conversation_thread_item_at(&mut turn, durable(), 2);
            } else {
                upsert_conversation_thread_item_at(&mut turn, durable(), 2);
                upsert_conversation_thread_item_at(&mut turn, lifecycle(), 1);
            }
            assert_eq!(turn.items.len(), 1);
            assert_eq!(turn.items[0].payload["phase"], "commentary");
            assert_eq!(turn.items[0].created_at, "2000");
            assert_eq!(turn.items[0].text.as_deref(), Some("Checking the files"));
        }
    }

    #[test]
    fn reconnect_hydration_can_complete_an_ordinary_started_item() {
        let entry = AppServerThreadItem {
            turn_id: "turn".into(),
            item: serde_json::json!({"id":"command-1", "type":"commandExecution"}),
        };
        let started =
            typed_thread_item_projection_with_lifecycle(&entry, "1000", None, Some("started"), 2);
        let hydrated = typed_thread_item_projection(&entry, "2000", None);
        assert_eq!(hydrated.state, "completed");

        let mut turn = ConversationTurn {
            started_at: None,
            completed_at: None,
            id: "turn".into(),
            status: "inProgress".into(),
            created_at: "1000".into(),
            updated_at: "2000".into(),
            items: vec![],
        };
        upsert_conversation_thread_item_at(&mut turn, started, 1);
        upsert_conversation_thread_item_at(&mut turn, hydrated, 3);
        assert_eq!(turn.items.len(), 1);
        assert_eq!(turn.items[0].state, "completed");
    }

    #[test]
    fn statusless_compaction_hydration_cannot_mask_explicit_lifecycle() {
        let entry = AppServerThreadItem {
            turn_id: "turn".into(),
            item: serde_json::json!({"id":"compact-1", "type":"contextCompaction"}),
        };
        let running =
            typed_thread_item_projection_with_lifecycle(&entry, "1000", None, Some("started"), 2);
        let hydrated = typed_thread_item_projection(&entry, "2000", None);
        assert_eq!(hydrated.state, "unknown");

        let mut turn = ConversationTurn {
            started_at: None,
            completed_at: None,
            id: "turn".into(),
            status: "unknown".into(),
            created_at: "1000".into(),
            updated_at: "1000".into(),
            items: vec![],
        };
        upsert_conversation_thread_item_at(&mut turn, running, 1);
        upsert_conversation_thread_item_at(&mut turn, hydrated, 3);
        assert_eq!(turn.items.len(), 1);
        assert_eq!(turn.items[0].state, "started");

        let completed =
            typed_thread_item_projection_with_lifecycle(&entry, "3000", None, Some("completed"), 2);
        upsert_conversation_thread_item_at(&mut turn, completed, 1);
        upsert_conversation_thread_item_at(
            &mut turn,
            typed_thread_item_projection(&entry, "4000", None),
            3,
        );
        assert_eq!(turn.items[0].state, "completed");
        assert_eq!(turn.items[0].id, "compact-1");
    }

    #[test]
    fn compactions_keep_multiple_item_ids_and_terminal_turn_states() {
        fn upsert_detail(id: &str, state: &str) -> String {
            serde_json::json!({
                "turnId": "turn",
                "itemId": id,
                "state": state,
                "lifecycleAuthority": 2,
                "item": {"id": id, "type": "contextCompaction"}
            })
            .to_string()
        }
        fn envelope(sequence: u64, event: WonderEvent) -> HostEventEnvelope {
            HostEventEnvelope {
                event_id: format!("event-{sequence}"),
                host_epoch: "epoch".into(),
                sequence,
                occurred_at: format!("2026-09-12T00:00:0{sequence}Z"),
                request_id: None,
                device_id: None,
                conversation_id: Some("conversation".into()),
                message_id: None,
                thread_id: Some("thread".into()),
                turn_id: Some("turn".into()),
                item_id: None,
                approval_id: None,
                event,
            }
        }

        let events = vec![
            envelope(
                1,
                WonderEvent::Activity {
                    category: "thread_item_upsert".into(),
                    state: "updated".into(),
                    detail: Some(upsert_detail("compact-1", "started")),
                },
            ),
            envelope(
                2,
                WonderEvent::Activity {
                    category: "thread_item_upsert".into(),
                    state: "updated".into(),
                    detail: Some(upsert_detail("compact-2", "started")),
                },
            ),
            envelope(
                3,
                WonderEvent::Activity {
                    category: "thread/compacted".into(),
                    state: "completed".into(),
                    detail: None,
                },
            ),
            envelope(
                4,
                WonderEvent::MessageState {
                    state: DeliveryState::Failed,
                },
            ),
            // Replay of the same canonical item must update it, not add a
            // second marker or merge the two actual compactions.
            envelope(
                5,
                WonderEvent::Activity {
                    category: "thread_item_upsert".into(),
                    state: "updated".into(),
                    detail: Some(upsert_detail("compact-1", "completed")),
                },
            ),
        ];
        let projection = conversation_thread_projection_with_items(
            Some("thread".into()),
            &[],
            &[],
            &events,
            &[
                AppServerThreadItem {
                    turn_id: "turn".into(),
                    item: serde_json::json!({"id":"compact-1", "type":"contextCompaction"}),
                },
                AppServerThreadItem {
                    turn_id: "turn".into(),
                    item: serde_json::json!({"id":"compact-2", "type":"contextCompaction"}),
                },
            ],
            None,
        );
        let items = &projection.turns[0].items;
        assert_eq!(projection.turns[0].status, "failed");
        assert_eq!(
            items
                .iter()
                .filter(|item| item.item_type == "contextCompaction")
                .count(),
            2
        );
        assert_eq!(
            items
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            ["compact-1", "compact-2"]
        );
        assert_eq!(
            items
                .iter()
                .map(|item| item.state.as_str())
                .collect::<Vec<_>>(),
            ["completed", "failed"]
        );
    }

    #[test]
    fn legacy_lifecycle_and_late_statusless_hydration_reconcile_truthfully() {
        fn envelope(sequence: u64, event: WonderEvent) -> HostEventEnvelope {
            HostEventEnvelope {
                event_id: format!("event-{sequence}"),
                host_epoch: "epoch".into(),
                sequence,
                occurred_at: format!("2026-09-12T00:00:0{sequence}Z"),
                request_id: None,
                device_id: None,
                conversation_id: Some("conversation".into()),
                message_id: None,
                thread_id: Some("thread".into()),
                turn_id: Some("turn".into()),
                item_id: None,
                approval_id: None,
                event,
            }
        }

        let legacy_started = serde_json::json!({
            "turnId": "turn",
            "item": {"id": "compact-legacy", "type": "contextCompaction"},
            "state": "started"
        })
        .to_string();
        let late_hydration = serde_json::json!({
            "turnId": "turn",
            "item": {"id": "compact-late", "type": "contextCompaction"},
            "state": "unknown",
            "historyRefresh": true
        })
        .to_string();
        let legacy_projection = conversation_thread_projection_with_items(
            Some("thread".into()),
            &[],
            &[],
            &[envelope(
                1,
                WonderEvent::Activity {
                    category: "thread_item_upsert".into(),
                    state: "updated".into(),
                    detail: Some(legacy_started),
                },
            )],
            &[],
            None,
        );
        assert_eq!(legacy_projection.turns[0].items.len(), 1);
        assert_eq!(legacy_projection.turns[0].items[0].state, "started");

        let projection = conversation_thread_projection_with_items(
            Some("thread".into()),
            &[],
            &[],
            &[
                envelope(
                    2,
                    WonderEvent::MessageState {
                        state: DeliveryState::Failed,
                    },
                ),
                envelope(
                    3,
                    WonderEvent::Activity {
                        category: "thread_item_upsert".into(),
                        state: "updated".into(),
                        detail: Some(late_hydration),
                    },
                ),
            ],
            &[],
            None,
        );
        let items = &projection.turns[0].items;
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].state, "failed");

        let interrupted = serde_json::json!({
            "turnId": "turn",
            "item": {"id": "compact-interrupted", "type": "contextCompaction"},
            "state": "unknown",
            "historyRefresh": true
        })
        .to_string();
        let projection = conversation_thread_projection_with_items(
            Some("thread".into()),
            &[],
            &[],
            &[
                envelope(
                    4,
                    WonderEvent::MessageState {
                        state: DeliveryState::Interrupted,
                    },
                ),
                envelope(
                    5,
                    WonderEvent::Activity {
                        category: "thread_item_upsert".into(),
                        state: "updated".into(),
                        detail: Some(interrupted),
                    },
                ),
            ],
            &[],
            None,
        );
        assert_eq!(projection.turns[0].items[0].state, "interrupted");
    }
}
