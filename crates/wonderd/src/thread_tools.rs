//! Agents in a Project work with its other threads through Wonder's own tools.
//! Codex receives them as dynamic tools and Claude through the bridge's `wonder`
//! tool server; both reach this module as the same correlated runtime request.
//! Every call is re-scoped to the caller's own Project, so a thread can never
//! see or message another Project, and no tool starts work except `send` and
//! `delegate`, which the agent initiates on purpose.
use super::*;
use serde_json::{json, Value};
use std::{collections::HashSet, time::Duration};
use wonder_store::{
    MessageInsert, MessageSource, NewMessageSource, ProjectConversationCreate,
    ProjectConversationInsert, StoredProject, StoredProjectConversation,
};

pub(super) const LIST: &str = "wonder_thread_list";
pub(super) const READ: &str = "wonder_thread_read";
pub(super) const SEND: &str = "wonder_thread_send";
pub(super) const WAIT: &str = "wonder_thread_wait";
pub(super) const DELEGATE: &str = "wonder_delegate";

const CALLS_PER_TURN: i64 = 200;
const MAX_DEPTH: i64 = 3;
const MAX_CHILDREN: i64 = 16;
const DEFAULT_WAIT: u64 = 600;
const MAX_WAIT: u64 = 1800;
const MAX_PAGES: usize = 200;
const POLL: Duration = Duration::from_millis(400);

pub(super) fn registered(name: &str) -> bool {
    matches!(name, LIST | READ | SEND | WAIT | DELEGATE)
}

pub(super) fn specs() -> Vec<Value> {
    let object = |properties: Value, required: Value| json!({"type":"object","additionalProperties":false,"properties":properties,"required":required});
    let spec = |name: &str, description: &str, schema: Value| json!({"type":"function","name":name,"description":description,"inputSchema":schema});
    let request_id = json!({"type":"string","format":"uuid","description":"A new UUID for this action (8-4-4-4-12 hexadecimal). Reuse it when you retry the same action; never reuse it for a different one."});
    vec![
        spec(LIST, "List the threads of this Project (not other Projects) with their id, title, provider, model, status (working, waiting or idle), queued message count and last activity. Read-only.",
            object(json!({"limit":{"type":"integer","minimum":1,"maximum":50},"cursor":{"type":"string","description":"nextCursor from the previous page."}}), json!([]))),
        spec(READ, "Read messages from another thread of this Project: user and agent text plus one-line summaries of commands and tool use, never raw output. Pages forward: pass the previous nextPosition as afterPosition. A long item is cut at maxCharsPerItem; continue it with textOffset (applies to the first returned item). Read-only.",
            object(json!({"threadId":{"type":"string"},"afterPosition":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":50},"maxCharsPerItem":{"type":"integer","minimum":200,"maximum":20000},"textOffset":{"type":"integer","minimum":0}}), json!(["threadId"]))),
        spec(SEND, "Send a message to another thread of this Project. mode queue (default) runs it after the thread's current work; steer adds it to the thread's running response and works only on providers that support it. The thread sees who wrote it. The target's access cannot be wider than yours. Reuse clientRequestId on retries.",
            object(json!({"threadId":{"type":"string"},"message":{"type":"string","maxLength":32768},"mode":{"type":"string","enum":["queue","steer"]},"clientRequestId":request_id.clone()}), json!(["threadId","message","clientRequestId"]))),
        spec(WAIT, "Wait for a thread's current work to finish. Returns finished, idle (nothing was running) or still_running after the timeout (default 600 s, at most 1800 s). A timeout never stops the thread; wait again or read it later.",
            object(json!({"threadId":{"type":"string"},"messageId":{"type":"string","description":"Wait for this message only, as returned by wonder_thread_send or wonder_delegate."},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":1800}}), json!(["threadId"]))),
        spec(DELEGATE, "Create a new thread in this Project's folder on the chosen provider and model, and give it a task. It receives only the prompt, not your conversation, so include everything it needs. Its access is at most yours. mode async returns at once; Wonder tells you when it finishes. mode wait blocks like wonder_thread_wait. Reuse clientRequestId on retries.",
            object(json!({"clientRequestId":request_id,"prompt":{"type":"string","maxLength":32768},"provider":{"type":"string","enum":["codex","claude"]},"model":{"type":"string","description":"A model id from the provider's catalog; omit for its default."},"effort":{"type":"string"},"accessMode":{"type":"string","enum":["read_only","workspace","full_access"],"description":"Defaults to yours; cannot be wider."},"claudeApproval":{"type":"string","enum":["ask","accept_edits","auto"]},"title":{"type":"string","maxLength":80},"mode":{"type":"string","enum":["async","wait"]},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":1800}}), json!(["clientRequestId","prompt","provider"]))),
    ]
}

/// A failure the agent can act on: `code` is stable, `message` is for the model.
#[derive(Debug)]
pub(super) struct ToolError {
    code: &'static str,
    message: String,
}
impl ToolError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}
impl From<sqlx::Error> for ToolError {
    fn from(_: sqlx::Error) -> Self {
        Self::new(
            "unavailable",
            "Wonder could not read its data. Try again shortly.",
        )
    }
}

fn response(result: Result<Value, ToolError>) -> Value {
    match result {
        Ok(value) => {
            let text = value.to_string();
            if text.len() > 1024 * 1024 {
                return response(Err(ToolError::new(
                    "too_large",
                    "This result is too large. Ask for fewer items or a smaller maxCharsPerItem.",
                )));
            }
            json!({"success":true,"contentItems":[{"type":"inputText","text":text}]})
        }
        Err(error) => {
            let text = json!({"error":{"code":error.code,"message":error.message}}).to_string();
            json!({"success":false,"contentItems":[{"type":"inputText","text":text}]})
        }
    }
}

struct Caller {
    message: wonder_store::StoredMessage,
    conversation: StoredProjectConversation,
    project: StoredProject,
}

async fn caller(
    state: &AppState,
    runtime: &str,
    thread: &str,
    message: &wonder_store::StoredMessage,
) -> Result<Caller, ToolError> {
    if !state
        .ingestion
        .runtime_accepts_message(runtime, &message.id)
    {
        return Err(ToolError::new(
            "wrong_runtime",
            "The request does not belong to this live runtime.",
        ));
    }
    if message.codex_thread_id.as_deref() != Some(thread) {
        return Err(ToolError::new(
            "wrong_turn",
            "The request targets different work.",
        ));
    }
    let conversation = state
        .store
        .project_conversation(&message.conversation_id)
        .await?
        .ok_or_else(|| {
            ToolError::new(
                "not_project",
                "Thread tools are available only in Project threads.",
            )
        })?;
    let project = state
        .store
        .project(&conversation.project_id)
        .await?
        .filter(|project| project.is_included)
        .ok_or_else(|| ToolError::new("project_unavailable", "This Project is not available."))?;
    Ok(Caller {
        message: message.clone(),
        conversation,
        project,
    })
}

/// The target must belong to the caller's own Project. Another Project's
/// thread is reported exactly like a missing one.
async fn target(
    state: &AppState,
    caller: &Caller,
    thread: &str,
) -> Result<StoredProjectConversation, ToolError> {
    state
        .store
        .project_conversation(thread)
        .await?
        .filter(|found| found.project_id == caller.project.id)
        .ok_or_else(|| ToolError::new("not_found", "No such thread in this Project."))
}

fn now_text() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

/// A UUID derived from the caller's identity and request, so a retried call
/// finds the message or thread the first attempt made.
fn derived_uuid(parts: &[&str]) -> String {
    let digest = Sha256::digest(json!(parts).to_string().as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    uuid::Uuid::from_bytes(bytes).to_string()
}

fn request_id(args: &Value) -> Result<String, ToolError> {
    let id = args
        .get("clientRequestId")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolError::new("invalid", "clientRequestId is required."))?;
    uuid::Uuid::parse_str(id)
        .map(|id| id.to_string())
        .map_err(|_| ToolError::new("invalid", "clientRequestId must be a UUID."))
}

fn text_arg(args: &Value, name: &str, max: usize) -> Result<String, ToolError> {
    let value = args
        .get(name)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ToolError::new("invalid", format!("{name} is required.")))?;
    if value.len() > max {
        return Err(ToolError::new(
            "invalid",
            format!("{name} is longer than {max} bytes."),
        ));
    }
    Ok(value.to_owned())
}

fn int_arg(args: &Value, name: &str, default: u64, min: u64, max: u64) -> Result<u64, ToolError> {
    match args.get(name) {
        None | Some(Value::Null) => Ok(default),
        Some(value) => value
            .as_u64()
            .filter(|value| (min..=max).contains(value))
            .ok_or_else(|| ToolError::new("invalid", format!("{name} must be {min} to {max}."))),
    }
}

fn only_known(args: &Value, known: &[&str]) -> Result<(), ToolError> {
    match args.as_object() {
        Some(object) if object.keys().all(|key| known.contains(&key.as_str())) => Ok(()),
        _ => Err(ToolError::new(
            "invalid",
            format!("Use only these fields: {}.", known.join(", ")),
        )),
    }
}

fn access_rank(mode: &str) -> u8 {
    match mode {
        "read_only" => 0,
        "workspace" => 1,
        _ => 2,
    }
}

fn approval_rank(mode: &str) -> u8 {
    match mode {
        "auto" => 2,
        "accept_edits" => 1,
        _ => 0,
    }
}

/// The widest approval a thread started by `parent` may have. Codex threads
/// always ask, so a Codex parent allows only Ask.
fn approval_ceiling(parent: &StoredProjectConversation) -> u8 {
    if parent.family.allows_approval_choice() {
        approval_rank(&parent.claude_approval)
    } else {
        0
    }
}

/// The provider's default approval, lowered to the parent's own level.
fn default_approval(family: AgentFamily, parent: &StoredProjectConversation) -> String {
    let default = agent_defaults::claude_approval(family);
    if !family.allows_approval_choice() || approval_rank(default) <= approval_ceiling(parent) {
        return default.to_owned();
    }
    family
        .provider()
        .approval_modes
        .iter()
        .find(|mode| approval_rank(mode) == approval_ceiling(parent))
        .copied()
        .unwrap_or("ask")
        .to_owned()
}

/// A thread may only direct a thread whose access is no wider than its own.
fn within_authority(
    from: &StoredProjectConversation,
    to: &StoredProjectConversation,
) -> Result<(), ToolError> {
    let wider_access = access_rank(&to.access_mode) > access_rank(&from.access_mode);
    // Approval refines Workspace only; Read only and Full access ignore it.
    let wider_approval = to.family.allows_approval_choice()
        && to.access_mode == "workspace"
        && approval_rank(&to.claude_approval) > approval_ceiling(from);
    if wider_access || wider_approval {
        return Err(ToolError::new(
            "permission_escalation",
            "That thread has wider access than this one. An agent can only direct threads with the same or narrower access.",
        ));
    }
    Ok(())
}

fn forbid_plan_mode(caller: &Caller) -> Result<(), ToolError> {
    if caller.conversation.plan_mode {
        return Err(ToolError::new(
            "plan_mode",
            "This thread is planning. Finish the plan before starting work in other threads.",
        ));
    }
    Ok(())
}

fn provider_name(family: AgentFamily) -> &'static str {
    family.as_str()
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

async fn status(state: &AppState, conversation: &str) -> Result<(&'static str, i64), ToolError> {
    let run = state.store.thread_run_state(conversation).await?;
    let status = if run.waiting {
        "waiting"
    } else if run.working || run.queued > 0 {
        "working"
    } else {
        "idle"
    };
    Ok((status, run.queued))
}

async fn summary(
    state: &AppState,
    caller: &Caller,
    thread: &StoredProjectConversation,
) -> Result<Value, ToolError> {
    let (status, queued) = status(state, &thread.conversation_id).await?;
    let parent = state
        .store
        .thread_delegation(&thread.conversation_id)
        .await?
        .map(|link| link.parent_conversation_id);
    Ok(json!({
        "id": thread.conversation_id, "title": thread.title,
        "provider": provider_name(thread.family), "model": thread.model,
        "accessMode": thread.access_mode, "status": status, "queuedMessages": queued,
        "lastActivityAt": thread.last_activity_at,
        "isCurrent": thread.conversation_id == caller.conversation.conversation_id,
        "delegatedBy": parent,
    }))
}

async fn list(state: &AppState, caller: &Caller, args: Value) -> Result<Value, ToolError> {
    only_known(&args, &["limit", "cursor"])?;
    let limit = int_arg(&args, "limit", 20, 1, 50)? as usize;
    let mut threads = state
        .store
        .project_conversations(&caller.project.id)
        .await?;
    // Newest activity first, with the id breaking ties, so a cursor is a
    // position in that order and pages stay put while threads run.
    threads.sort_by(|a, b| {
        b.last_activity_at
            .cmp(&a.last_activity_at)
            .then_with(|| a.conversation_id.cmp(&b.conversation_id))
    });
    if let Some(cursor) = args.get("cursor").and_then(Value::as_str) {
        let (at, id) = cursor
            .split_once('|')
            .ok_or_else(|| ToolError::new("invalid", "cursor is not valid."))?;
        threads.retain(|t| {
            t.last_activity_at.as_str() < at
                || (t.last_activity_at == at && t.conversation_id.as_str() > id)
        });
    }
    let more = threads.len() > limit;
    threads.truncate(limit);
    let mut items = Vec::with_capacity(threads.len());
    for thread in &threads {
        items.push(summary(state, caller, thread).await?);
    }
    let next = if more {
        threads
            .last()
            .map(|t| format!("{}|{}", t.last_activity_at, t.conversation_id))
    } else {
        None
    };
    Ok(json!({"threads": items, "nextCursor": next}))
}

// ---------------------------------------------------------------------------
// read
// ---------------------------------------------------------------------------

pub(crate) fn clip(value: &str, max: usize) -> String {
    value.chars().take(max).collect()
}

pub(crate) fn content_text(item: &Value) -> String {
    if let Some(text) = item.get("text").and_then(Value::as_str) {
        return text.to_owned();
    }
    item.get("content")
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .filter(|text| !crate::provider_switch::is_handoff_text(text))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// One timeline entry as an agent should read it: messages in full, work as
/// a single line. Reasoning and raw tool output are never included.
pub(crate) fn summarize(item: &Value) -> Option<(&'static str, String)> {
    let kind = item.get("type").and_then(Value::as_str)?;
    let field = |name: &str| item.get(name).and_then(Value::as_str).unwrap_or_default();
    let line = match kind {
        "userMessage" => return Some(("user", content_text(item))),
        "agentMessage" => return Some(("agent", content_text(item))),
        "plan" => return Some(("agent", format!("Plan: {}", content_text(item)))),
        "commandExecution" => {
            let exit = item
                .get("exitCode")
                .and_then(Value::as_i64)
                .map(|code| format!(", exit {code}"))
                .unwrap_or_default();
            format!("Ran `{}` ({}{exit})", clip(field("command"), 200), {
                match field("status") {
                    "" => "done",
                    status => status,
                }
            })
        }
        "fileChange" => {
            let paths = item
                .get("changes")
                .and_then(Value::as_array)
                .map(|changes| {
                    changes
                        .iter()
                        .filter_map(|c| c.get("path").and_then(Value::as_str))
                        .map(|path| path.rsplit('/').next().unwrap_or(path).to_owned())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            match paths.len() {
                0 => "Edited files".into(),
                1..=5 => format!("Edited {}", paths.join(", ")),
                more => format!(
                    "Edited {} and {} more files",
                    paths[..5].join(", "),
                    more - 5
                ),
            }
        }
        "mcpToolCall" => format!("Used tool {}/{}", field("server"), field("tool")),
        "dynamicToolCall" => format!("Used tool {}", field("tool")),
        "webSearch" => format!("Searched the web for {}", clip(field("query"), 120)),
        "imageView" | "imageGeneration" => "Worked with an image".into(),
        "subAgentActivity" | "collabAgentToolCall" => "Ran an agent task".into(),
        _ => return None,
    };
    Some(("tool", line))
}

/// The provider thread behind a conversation, once its first message started
/// one. The store reports a thread that has none as an empty id.
async fn native_thread(state: &AppState, conversation: &str) -> Option<String> {
    state
        .store
        .conversation_thread(conversation)
        .await
        .ok()
        .flatten()
        .filter(|thread| !thread.is_empty())
}

/// Walks a thread's visible entries in order and keeps one page of them.
struct Page {
    after: u64,
    limit: usize,
    position: u64,
    items: Vec<(u64, &'static str, String, Option<String>)>,
    more: bool,
}
impl Page {
    fn new(after: u64, limit: usize) -> Self {
        Self {
            after,
            limit,
            position: 0,
            items: Vec::new(),
            more: false,
        }
    }
    /// True once the page is full and a further entry proves there is more.
    fn push(&mut self, item: &Value) -> bool {
        let Some((role, text)) = summarize(item) else {
            return false;
        };
        self.position += 1;
        if self.position <= self.after {
            return false;
        }
        if self.items.len() == self.limit {
            self.more = true;
            return true;
        }
        let client = item
            .get("clientId")
            .and_then(Value::as_str)
            .map(str::to_owned);
        self.items.push((self.position, role, text, client));
        false
    }
}

/// Runtime entries for a thread, oldest first, until `visit` says stop.
async fn walk(
    state: &AppState,
    thread: &str,
    visit: impl FnMut(&Value) -> bool,
) -> Result<(), ToolError> {
    let rpc = claude::for_thread(state, thread)
        .await
        .map_err(|_| unavailable())?;
    walk_with(&rpc, thread, visit).await
}

fn unavailable() -> ToolError {
    ToolError::new(
        "unavailable",
        "That thread's history is unavailable right now.",
    )
}

/// Walks one provider session's entries through `rpc`. Sessions a thread left
/// behind when it changed provider no longer have a binding to route by.
pub(crate) async fn walk_with(
    rpc: &wonder_app_server::RpcClient,
    thread: &str,
    mut visit: impl FnMut(&Value) -> bool,
) -> Result<(), ToolError> {
    let mut cursor: Option<String> = None;
    let mut seen = HashSet::new();
    for _ in 0..MAX_PAGES {
        let mut params = json!({"threadId":thread,"limit":100,"sortDirection":"asc"});
        if let Some(cursor) = cursor.take() {
            params["cursor"] = json!(cursor);
        }
        let result = rpc
            .request("thread/items/list", params)
            .await
            .ok()
            .filter(|response| response.error.is_none())
            .and_then(|response| response.result)
            .ok_or_else(unavailable)?;
        for entry in result
            .get("data")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(item) = entry.get("item") {
                if visit(item) {
                    return Ok(());
                }
            }
        }
        match result.get("nextCursor").and_then(Value::as_str) {
            Some(next) if !next.is_empty() && seen.insert(next.to_owned()) => {
                cursor = Some(next.to_owned())
            }
            _ => return Ok(()),
        }
    }
    Err(ToolError::new(
        "too_long",
        "That thread is too long to scan from the start. Read its most recent work in Wonder.",
    ))
}

/// Every provider session behind a thread, oldest first: the ones it left when
/// it changed provider, then the active one. Positions count across all of them.
#[cfg(test)]
pub(crate) async fn segments_for_test(
    state: &AppState,
    conversation: &str,
) -> Vec<(wonder_store::AgentFamily, String, bool)> {
    segments(state, conversation).await.unwrap_or_default()
}

pub(crate) async fn segments(
    state: &AppState,
    conversation: &str,
) -> Result<Vec<(wonder_store::AgentFamily, String, bool)>, ToolError> {
    let mut found = Vec::new();
    for old in state.store.project_runtime_history(conversation).await? {
        if let Some(thread) = old.runtime_thread_id.or(old.native_session_id) {
            found.push((old.family, thread, false));
        }
    }
    if let Some(native) = native_thread(state, conversation).await {
        let family = match state.store.runtime_binding(conversation).await? {
            Some(binding) => binding.family,
            None => AgentFamily::issuing_thread(&native),
        };
        found.push((family, native, true));
    }
    Ok(found)
}

async fn read(state: &AppState, caller: &Caller, args: Value) -> Result<Value, ToolError> {
    only_known(
        &args,
        &[
            "threadId",
            "afterPosition",
            "limit",
            "maxCharsPerItem",
            "textOffset",
        ],
    )?;
    let thread = target(state, caller, &text_arg(&args, "threadId", 128)?).await?;
    let after = int_arg(&args, "afterPosition", 0, 0, u64::MAX / 2)?;
    let limit = int_arg(&args, "limit", 20, 1, 50)? as usize;
    let max_chars = int_arg(&args, "maxCharsPerItem", 4000, 200, 20000)? as usize;
    let offset = int_arg(&args, "textOffset", 0, 0, u64::MAX / 2)? as usize;
    let mut page = Page::new(after, limit);
    for (family, native, active) in segments(state, &thread.conversation_id).await? {
        let mut full = false;
        let stop = |item: &Value| {
            full = page.push(item);
            full
        };
        if active {
            walk(state, &native, stop).await?;
        } else {
            let rpc = crate::projects::rpc_for(state, family)
                .await
                .map_err(|_| unavailable())?;
            walk_with(&rpc, &native, stop).await?;
        }
        if full {
            break;
        }
    }
    let labels = state
        .store
        .message_source_labels(&thread.conversation_id)
        .await?;
    let mut items = Vec::new();
    for (index, (position, role, text, client)) in page.items.iter().enumerate() {
        let total = text.chars().count();
        let start = if index == 0 { offset.min(total) } else { 0 };
        let end = (start + max_chars).min(total);
        let shown = crate::history::sanitize_ansi_and_secrets(
            &text
                .chars()
                .skip(start)
                .take(end - start)
                .collect::<String>(),
            max_chars * 4,
        );
        let mut item = json!({"position":position,"role":role,"text":shown,"totalChars":total});
        if end < total {
            item["truncated"] = json!(true);
            item["nextTextOffset"] = json!(end);
        }
        if let Some(source) = client.as_deref().and_then(|client| labels.get(client)) {
            item["from"] = json!(source.source_title);
        }
        items.push(item);
    }
    // Messages queued behind the thread's work are not in its history yet.
    let mut pending = Vec::new();
    if !page.more {
        for (body, source) in state
            .store
            .queued_message_bodies(&thread.conversation_id)
            .await?
        {
            pending.push(
                json!({"role":"user","text":clip(&body, max_chars),"queued":true,
                "from": source.map(|s| s.source_title)}),
            );
        }
    }
    let (status, _) = status(state, &thread.conversation_id).await?;
    if !page.more && status == "idle" {
        observe(state, caller, &thread).await;
    }
    let next = page.items.last().map(|i| i.0).unwrap_or(after);
    Ok(
        json!({"threadId":thread.conversation_id,"title":thread.title,"status":status,
        "items":items,"queuedMessages":pending,"nextPosition":next,"hasMore":page.more}),
    )
}

/// A parent that has read its idle child's result needs no wake-up for it.
async fn observe(state: &AppState, caller: &Caller, child: &StoredProjectConversation) {
    let _ = state
        .store
        .observe_thread_delegation(
            &caller.conversation.conversation_id,
            &child.conversation_id,
            &now_text(),
        )
        .await;
}

// ---------------------------------------------------------------------------
// send
// ---------------------------------------------------------------------------

fn source_for<'a>(caller: &'a Caller) -> NewMessageSource<'a> {
    NewMessageSource {
        kind: "thread",
        conversation: Some(&caller.conversation.conversation_id),
        title: &caller.conversation.title,
        wake_children: &[],
        wake_parent: None,
    }
}

async fn send(state: &AppState, caller: &Caller, args: Value) -> Result<Value, ToolError> {
    only_known(&args, &["threadId", "message", "mode", "clientRequestId"])?;
    forbid_plan_mode(caller)?;
    let thread = target(state, caller, &text_arg(&args, "threadId", 128)?).await?;
    if thread.conversation_id == caller.conversation.conversation_id {
        return Err(ToolError::new("invalid", "A thread cannot message itself."));
    }
    let body = text_arg(&args, "message", 32 * 1024)?;
    let request = request_id(&args)?;
    let mode = args.get("mode").and_then(Value::as_str).unwrap_or("queue");
    within_authority(&caller.conversation, &thread)?;
    let id = derived_uuid(&[
        "thread-send",
        &caller.conversation.conversation_id,
        &thread.conversation_id,
        &request,
    ]);
    let device = &caller.message.device_id;
    let Some(_admission) = state.update_admission.claim_guard().await else {
        return Err(ToolError::new(
            "updating",
            "Wonder is preparing to update. Try again shortly.",
        ));
    };
    let source = source_for(caller);
    let insert = match mode {
        "queue" => {
            state
                .store
                .insert_agent_message(
                    device,
                    &id,
                    &body,
                    &thread.conversation_id,
                    &now_text(),
                    &source,
                )
                .await?
        }
        "steer" => {
            if !thread.family.provider().capabilities.guide {
                return Err(ToolError::new(
                    "steer_unsupported",
                    format!(
                        "{} threads cannot take a message during a response. Use mode \"queue\" to run it next.",
                        thread.family.provider().display_name
                    ),
                ));
            }
            // A retry that already steered must not need the turn to still run.
            let prior = state
                .store
                .message_by_device_and_client_message_id(device, &id)
                .await?;
            if let Some(prior) = prior {
                MessageInsert::Existing(prior)
            } else {
                let running = state
                    .store
                    .running_message(&thread.conversation_id)
                    .await?
                    .and_then(|m| m.codex_turn_id)
                    .ok_or_else(|| {
                        ToolError::new(
                            "not_running",
                            "That thread is not in a response right now. Use mode \"queue\".",
                        )
                    })?;
                state
                    .store
                    .insert_agent_guide(
                        device,
                        &id,
                        &body,
                        &thread.conversation_id,
                        &now_text(),
                        &running,
                        &source,
                    )
                    .await?
            }
        }
        _ => return Err(ToolError::new("invalid", "mode must be queue or steer.")),
    };
    let (message, duplicate) = match insert {
        MessageInsert::Inserted(message) => (message, false),
        MessageInsert::Existing(message) => (message, true),
        MessageInsert::Conflict => {
            return Err(ToolError::new(
                "request_reused",
                "That clientRequestId was already used for a different message. Use a new one.",
            ))
        }
    };
    if !duplicate {
        // Work sent to a delegated child is reported to its parent again.
        if let Some(link) = state
            .store
            .thread_delegation(&thread.conversation_id)
            .await?
        {
            if link.parent_conversation_id == caller.conversation.conversation_id {
                state
                    .store
                    .rearm_thread_delegation(&thread.conversation_id)
                    .await?;
            }
        }
    }
    Ok(
        json!({"threadId":thread.conversation_id,"messageId":message.id,"mode":mode,
        "deliveryState":message.state,"duplicate":duplicate}),
    )
}

// ---------------------------------------------------------------------------
// wait
// ---------------------------------------------------------------------------

const OPEN_STATES: [&str; 4] = [
    "accepted_by_wonder",
    "dispatching_to_codex",
    "accepted_by_codex",
    "streaming",
];

/// Polls the store until every watched message has ended, the timeout passes
/// or the calling turn ends. A timeout is a normal answer, never a stop.
async fn wait_for(
    state: &AppState,
    caller: &Caller,
    thread: &StoredProjectConversation,
    watch: Vec<String>,
    timeout: Duration,
) -> Result<Value, ToolError> {
    let deadline = tokio::time::Instant::now() + timeout;
    let mut open = watch;
    let had_work = !open.is_empty();
    loop {
        let mut still = Vec::new();
        for id in &open {
            match state.store.message_by_id(id).await? {
                Some(message) if OPEN_STATES.contains(&message.state.as_str()) => {
                    still.push(id.clone())
                }
                _ => {}
            }
        }
        open = still;
        if open.is_empty() {
            break;
        }
        let alive = state
            .store
            .message_by_id(&caller.message.id)
            .await?
            .is_some_and(|m| matches!(m.state.as_str(), "accepted_by_codex" | "streaming"));
        if !alive {
            return Err(ToolError::new(
                "cancelled",
                "The calling response ended before the wait did.",
            ));
        }
        if tokio::time::Instant::now() >= deadline {
            let (thread_status, _) = status(state, &thread.conversation_id).await?;
            return Ok(
                json!({"status":"still_running","threadId":thread.conversation_id,
                "threadStatus":thread_status,
                "note":"The thread is still working; nothing was stopped. Wait again or read it later."}),
            );
        }
        tokio::time::sleep(POLL).await;
    }
    let (thread_status, _) = status(state, &thread.conversation_id).await?;
    let latest = state.store.latest_message(&thread.conversation_id).await?;
    let mut result = json!({"status": if had_work {"finished"} else {"idle"},
        "threadId":thread.conversation_id,"threadStatus":thread_status,
        "outcome": latest.as_ref().map(|m| m.state.clone())});
    if had_work && thread_status == "idle" {
        if let Some((text, total)) = last_agent_message(state, &thread.conversation_id).await {
            result["lastAgentMessage"] = json!(clip(&text, 6000));
            if total > 6000 {
                result["lastAgentMessageTruncated"] = json!(true);
            }
        }
        observe(state, caller, thread).await;
    }
    Ok(result)
}

async fn last_agent_message(state: &AppState, conversation: &str) -> Option<(String, usize)> {
    let native = native_thread(state, conversation).await?;
    let mut last = None;
    walk(state, &native, |item| {
        if let Some(("agent", text)) = summarize(item) {
            if item.get("type").and_then(Value::as_str) == Some("agentMessage") {
                last = Some(text);
            }
        }
        false
    })
    .await
    .ok()?;
    last.map(|text| {
        let total = text.chars().count();
        (text, total)
    })
}

async fn wait(state: &AppState, caller: &Caller, args: Value) -> Result<Value, ToolError> {
    only_known(&args, &["threadId", "messageId", "timeoutSeconds"])?;
    let thread = target(state, caller, &text_arg(&args, "threadId", 128)?).await?;
    if thread.conversation_id == caller.conversation.conversation_id {
        return Err(ToolError::new(
            "invalid",
            "A thread cannot wait for itself.",
        ));
    }
    let timeout = int_arg(&args, "timeoutSeconds", DEFAULT_WAIT, 1, MAX_WAIT)?;
    let watch = match args.get("messageId").and_then(Value::as_str) {
        Some(id) => {
            let message = state
                .store
                .message_by_id(id)
                .await?
                .filter(|m| m.conversation_id == thread.conversation_id)
                .ok_or_else(|| ToolError::new("not_found", "No such message in that thread."))?;
            vec![message.id]
        }
        None => {
            state
                .store
                .open_message_ids(&thread.conversation_id)
                .await?
        }
    };
    wait_for(state, caller, &thread, watch, Duration::from_secs(timeout)).await
}

// ---------------------------------------------------------------------------
// delegate
// ---------------------------------------------------------------------------

async fn delegate(state: &AppState, caller: &Caller, args: Value) -> Result<Value, ToolError> {
    only_known(
        &args,
        &[
            "clientRequestId",
            "prompt",
            "provider",
            "model",
            "effort",
            "accessMode",
            "claudeApproval",
            "title",
            "mode",
            "timeoutSeconds",
        ],
    )?;
    forbid_plan_mode(caller)?;
    let request = request_id(&args)?;
    let prompt = text_arg(&args, "prompt", 32 * 1024)?;
    let family = match args.get("provider").and_then(Value::as_str) {
        Some("codex") => AgentFamily::Codex,
        Some("claude") => AgentFamily::Claude,
        _ => {
            return Err(ToolError::new(
                "invalid",
                "provider must be codex or claude.",
            ))
        }
    };
    let parent = &caller.conversation;
    let id = derived_uuid(&["delegate", &parent.conversation_id, &request]);
    let existing = state
        .store
        .thread_delegation_by_request(&parent.conversation_id, &request)
        .await?;
    if existing.is_none() {
        if state
            .store
            .thread_delegation_depth(&parent.conversation_id)
            .await?
            >= MAX_DEPTH
        {
            return Err(ToolError::new(
                "depth_limit",
                "Delegated threads can delegate at most three levels deep.",
            ));
        }
        if state
            .store
            .thread_delegation_count(&parent.conversation_id)
            .await?
            >= MAX_CHILDREN
        {
            return Err(ToolError::new(
                "too_many_threads",
                "This thread has already delegated 16 tasks. Reuse a finished thread with wonder_thread_send.",
            ));
        }
    }
    // Access: the default is the parent's own, and nothing may be wider.
    let access = args
        .get("accessMode")
        .and_then(Value::as_str)
        .unwrap_or(&parent.access_mode);
    if !["read_only", "workspace", "full_access"].contains(&access) {
        return Err(ToolError::new("invalid", "accessMode is not valid."));
    }
    if access_rank(access) > access_rank(&parent.access_mode) {
        return Err(ToolError::new(
            "permission_escalation",
            format!(
                "A delegated thread cannot have wider access than this one ({}).",
                parent.access_mode
            ),
        ));
    }
    let approval = match args.get("claudeApproval").and_then(Value::as_str) {
        Some(value) => {
            if !family.allows_approval_choice() {
                return Err(ToolError::new(
                    "invalid",
                    "Approval modes are available for Claude threads.",
                ));
            }
            if !family.provider().approval_modes.contains(&value) {
                return Err(ToolError::new("invalid", "claudeApproval is not valid."));
            }
            if access == "workspace" && approval_rank(value) > approval_ceiling(parent) {
                return Err(ToolError::new(
                    "permission_escalation",
                    "A delegated thread cannot ask for approval less often than this one.",
                ));
            }
            value.to_owned()
        }
        None => default_approval(family, parent),
    };
    if family == AgentFamily::Claude && state.claude.is_none() {
        return Err(ToolError::new(
            "unavailable_provider",
            "Claude is not installed on this Mac.",
        ));
    }
    let readiness = state.ingestion.project_readiness(&state.store).await;
    if !readiness.ready {
        return Err(ToolError::new("unavailable_provider", readiness.detail));
    }
    let catalog = state.runtime_catalog.read().await.clone();
    let (model, effort, tier) = projects::execution_settings(
        &catalog,
        family,
        args.get("model").and_then(Value::as_str),
        args.get("effort").and_then(Value::as_str),
        None,
    )
    .map_err(|detail| {
        ToolError::new(
            "unavailable_model",
            format!("{detail} Choose a model the provider lists."),
        )
    })?;
    let title: String = args
        .get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            prompt
                .lines()
                .find(|l| !l.trim().is_empty())
                .unwrap_or("Delegated task")
                .trim()
                .to_owned()
        })
        .chars()
        .take(80)
        .collect();
    let project = &caller.project;
    let root = project.root_for(&parent.cwd).ok_or_else(|| {
        ToolError::new(
            "project_unavailable",
            "This thread's folder is no longer in the Project.",
        )
    })?;
    let checked = project.clone();
    let denied = state.denied_roots.clone();
    tokio::task::spawn_blocking(move || projects::validate_execution_roots(&checked, &denied))
        .await
        .map_err(|_| ToolError::new("unavailable", "Project folders could not be checked."))?
        .map_err(|detail| ToolError::new("project_unavailable", detail))?;
    let Some(_admission) = state.update_admission.claim_guard().await else {
        return Err(ToolError::new(
            "updating",
            "Wonder is preparing to update. Try again shortly.",
        ));
    };
    let now = now_text();
    let digest = hex::encode(Sha256::digest(
        json!([
            "delegate",
            parent.conversation_id,
            family.as_str(),
            model,
            effort,
            access,
            approval,
            title,
            hex::encode(Sha256::digest(prompt.as_bytes()))
        ])
        .to_string()
        .as_bytes(),
    ));
    let created = state
        .store
        .create_project_conversation_with_request_digest(
            ProjectConversationInsert {
                conversation_id: &id,
                project_id: &project.id,
                family,
                provider_store: crate::providers::provider_store(state, family),
                native_session_id: None,
                cwd: &root.path,
                roots_revision: project.roots_revision,
                title: &title,
                model: Some(&model),
                effort: effort.as_deref(),
                service_tier: tier.as_deref(),
                access_mode: access,
                claude_approval: &approval,
                plan_mode: false,
                creation_request_id: Some(&id),
                now: &now,
            },
            &digest,
        )
        .await;
    let (child, new_thread) =
        match created {
            Ok(ProjectConversationCreate::Created(child)) => (child, true),
            Ok(ProjectConversationCreate::Existing(child)) => (child, false),
            Err(sqlx::Error::Protocol(_)) => return Err(ToolError::new(
                "request_reused",
                "That clientRequestId was already used for a different delegation. Use a new one.",
            )),
            Err(error) => return Err(error.into()),
        };
    state
        .store
        .record_thread_delegation(
            &child.conversation_id,
            &parent.conversation_id,
            &request,
            &caller.message.device_id,
            &now,
        )
        .await?;
    let source = NewMessageSource {
        kind: "delegation",
        conversation: Some(&parent.conversation_id),
        title: &parent.title,
        wake_children: &[],
        wake_parent: None,
    };
    let message =
        match state
            .store
            .insert_agent_message(
                &caller.message.device_id,
                &id,
                &prompt,
                &child.conversation_id,
                &now,
                &source,
            )
            .await?
        {
            MessageInsert::Inserted(message) | MessageInsert::Existing(message) => message,
            MessageInsert::Conflict => return Err(ToolError::new(
                "request_reused",
                "That clientRequestId was already used for a different delegation. Use a new one.",
            )),
        };
    let _ = state.store.touch_project(&project.id, family, &now).await;
    let mut result = json!({"threadId":child.conversation_id,"messageId":message.id,
        "title":child.title,"provider":provider_name(family),"model":child.model,
        "accessMode":child.access_mode,"created":new_thread,"status":"queued"});
    if args.get("mode").and_then(Value::as_str) == Some("wait") {
        let timeout = int_arg(&args, "timeoutSeconds", DEFAULT_WAIT, 1, MAX_WAIT)?;
        drop(_admission);
        let waited = wait_for(
            state,
            caller,
            &child,
            vec![message.id.clone()],
            Duration::from_secs(timeout),
        )
        .await?;
        if let (Some(into), Some(from)) = (result.as_object_mut(), waited.as_object()) {
            into.extend(from.clone());
        }
    }
    Ok(result)
}

// ---------------------------------------------------------------------------
// dispatch
// ---------------------------------------------------------------------------

async fn execute(
    state: &AppState,
    caller: &Caller,
    tool: &str,
    args: Value,
) -> Result<Value, ToolError> {
    match tool {
        LIST => list(state, caller, args).await,
        READ => read(state, caller, args).await,
        SEND => send(state, caller, args).await,
        WAIT => wait(state, caller, args).await,
        DELEGATE => delegate(state, caller, args).await,
        _ => Err(ToolError::new(
            "unknown_tool",
            "That tool is not registered.",
        )),
    }
}

/// Acknowledges the runtime's request at once and answers from a task. A wait
/// can last half an hour and a history read can be slow; neither may hold the
/// shared notification consumer, which also delivers the finish they wait for.
pub(super) async fn handle(
    state: &AppState,
    notification: &Value,
    params: &Value,
    message: Option<&wonder_store::StoredMessage>,
) -> bool {
    let Some(runtime) = notification.get("_wonderRuntimeId").and_then(Value::as_str) else {
        return true;
    };
    let mut actual = params.clone();
    actual["_wonderRuntimeId"] = json!(runtime);
    let Some(client) = state.ingestion.approval_client(&actual) else {
        return true;
    };
    let Some(request_id) = notification.get("id").cloned() else {
        return true;
    };
    let rpc = client.lock().await.rpc();
    if rpc.health().id() != runtime {
        return true;
    }
    let (state, runtime, params, message) = (
        state.clone(),
        runtime.to_owned(),
        params.clone(),
        message.cloned(),
    );
    tokio::spawn(async move {
        let value = handle_call(&state, &runtime, &params, message.as_ref()).await;
        if rpc.health().id() == runtime {
            let _ = rpc.respond_value(request_id, Some(value), None).await;
        }
    });
    true
}

async fn handle_call(
    state: &AppState,
    runtime: &str,
    params: &Value,
    message: Option<&wonder_store::StoredMessage>,
) -> Value {
    let fail = |error: ToolError| response(Err(error));
    let Some(message) = message else {
        return fail(ToolError::new(
            "uncorrelated",
            "The request is not correlated with accepted work.",
        ));
    };
    let (Some(thread), Some(turn)) = (
        params.get("threadId").and_then(Value::as_str),
        params.get("turnId").and_then(Value::as_str),
    ) else {
        return fail(ToolError::new(
            "uncorrelated",
            "Thread and turn identity are required.",
        ));
    };
    if message.codex_turn_id.as_deref() != Some(turn) {
        return fail(ToolError::new(
            "wrong_turn",
            "The request targets different work.",
        ));
    }
    let tool = params
        .get("tool")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !registered(tool) {
        return fail(ToolError::new(
            "unknown_tool",
            "That tool is not registered.",
        ));
    }
    let caller = match caller(state, runtime, thread, message).await {
        Ok(caller) => caller,
        Err(error) => return fail(error),
    };
    let Some(call_id) = params
        .get("callId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && id.len() <= 256)
    else {
        return fail(ToolError::new(
            "uncorrelated",
            "A stable runtime call identity is required.",
        ));
    };
    let key = hex::encode(Sha256::digest(
        json!([runtime, thread, turn, call_id]).to_string(),
    ));
    let hash = hex::encode(Sha256::digest(
        json!({"tool":tool,"arguments":params.get("arguments")}).to_string(),
    ));
    match state.store.pm_tool_call(&key).await {
        Ok(Some((saved, _))) if saved != hash => {
            return fail(ToolError::new(
                "call_reused",
                "This runtime call was already used with different arguments.",
            ))
        }
        // A finished call replays its saved answer, errors included.
        Ok(Some((_, Some(answer)))) => {
            if let Ok(value) = serde_json::from_str(&answer) {
                return value;
            }
        }
        Ok(_) => {}
        Err(error) => return fail(error.into()),
    }
    if !matches!(message.state.as_str(), "accepted_by_codex" | "streaming") {
        return fail(ToolError::new(
            "turn_ended",
            "This turn is no longer active.",
        ));
    }
    match state
        .store
        .reserve_tool_call(
            &key,
            &hash,
            &message.id,
            runtime,
            tool,
            &now_text(),
            CALLS_PER_TURN,
        )
        .await
    {
        Ok(true) => {}
        Ok(false) => {
            return fail(ToolError::new(
                "call_limit",
                "This turn reached its limit of thread tool calls. Finish your response first.",
            ))
        }
        Err(error) => return fail(error.into()),
    }
    let args = match crate::pm_tools::arguments(params) {
        Ok(args) => args,
        Err(detail) => return fail(ToolError::new("invalid", detail)),
    };
    let value = response(execute(state, &caller, tool, args).await);
    // Sends and delegations are idempotent by their own request ids, so a
    // crash before this save repeats nothing.
    let _ = state
        .store
        .complete_pm_tool_call(&key, &hash, &value.to_string())
        .await;
    value
}

// ---------------------------------------------------------------------------
// wake-ups
// ---------------------------------------------------------------------------

fn wake_body(children: &[wonder_store::WakeChild]) -> String {
    let named = children
        .iter()
        .map(|c| format!("\"{}\" ({})", c.title, c.outcome))
        .collect::<Vec<_>>()
        .join(", ");
    let ids = children
        .iter()
        .map(|c| c.conversation_id.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "Automatic message from Wonder, not from the user. Delegated tasks finished: {named}. \
         Review each result with wonder_thread_read (thread ids: {ids}) and continue your work."
    )
}

/// Tells an idle parent, once, that delegated threads finished. Run from the
/// dispatch loop: it reads only the database, so it never interrupts a turn,
/// and a parent that is running or has queued messages is simply not picked.
pub(crate) async fn wake_parents(state: &AppState) {
    let Ok(candidates) = state.store.wake_candidates().await else {
        return;
    };
    // A thread about to be told of its own finished tasks has more work coming;
    // its parent hears of it once that is done.
    let waking: HashSet<String> = candidates
        .iter()
        .map(|c| c.parent_conversation_id.clone())
        .collect();
    for mut candidate in candidates {
        candidate
            .children
            .retain(|child| !waking.contains(&child.conversation_id));
        // A parent the Mac is running keeps the wake-up queued like any message.
        if candidate.children.is_empty() {
            continue;
        }
        let ids = candidate
            .children
            .iter()
            .map(|c| c.conversation_id.clone())
            .collect::<Vec<_>>();
        // The compact row in the timeline reads this title.
        let title = format!(
            "Agent tasks finished: {}",
            candidate
                .children
                .iter()
                .map(|c| format!("{} ({})", c.title, c.outcome))
                .collect::<Vec<_>>()
                .join(", ")
        );
        let source = NewMessageSource {
            kind: "wake",
            conversation: None,
            title: &title,
            wake_children: &ids,
            wake_parent: Some(&candidate.parent_conversation_id),
        };
        let _ = state
            .store
            .insert_agent_message(
                &candidate.device_id,
                &uuid::Uuid::new_v4().to_string(),
                &wake_body(&candidate.children),
                &candidate.parent_conversation_id,
                &now_text(),
                &source,
            )
            .await;
    }
}

/// How the agent is told who wrote a message. The stored body stays exactly
/// what was sent, so the timeline can show its own "From" label instead.
pub(crate) fn provider_text(source: Option<&MessageSource>, body: &str) -> String {
    match source {
        Some(source) if source.kind == "thread" => format!(
            "[Message from the thread \"{}\"{}. Reply with wonder_thread_send if it needs an answer.]\n\n{body}",
            source.source_title,
            source
                .source_conversation_id
                .as_deref()
                .map(|id| format!(", id {id}"))
                .unwrap_or_default()
        ),
        _ => body.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::tests::handoff_fixture;
    use wonder_store::{ProjectConversationPatch, ProjectRootInput};

    struct Fx {
        dir: tempfile::TempDir,
        state: AppState,
        parent: Caller,
        _service: crate::ingestion::NotificationService,
    }

    async fn caller_of(state: &AppState, message: &str) -> Caller {
        let message = state.store.message_by_id(message).await.unwrap().unwrap();
        let conversation = state
            .store
            .project_conversation(&message.conversation_id)
            .await
            .unwrap()
            .unwrap();
        let project = state
            .store
            .project(&conversation.project_id)
            .await
            .unwrap()
            .unwrap();
        Caller {
            message,
            conversation,
            project,
        }
    }

    // The parent is a Workspace Codex thread with a running turn, in a Project
    // whose catalog offers one Codex model.
    async fn fx() -> Fx {
        let (dir, state, message) = handoff_fixture().await;
        state
            .runtime_catalog
            .write()
            .await
            .models
            .push(ModelOption {
                agent_family: AgentFamily::Codex,
                capabilities: ModelCapabilities::for_family(AgentFamily::Codex),
                id: "fake".into(),
                display_name: "Fake".into(),
                description: None,
                model_specialty: None,
                hidden: false,
                reasoning_efforts: vec![],
                default_reasoning_effort: None,
                service_tiers: vec![],
                default_service_tier: Some("default".into()),
                is_default: false,
                provider_default: None,
                native_ids: vec![],
            });
        state
            .store
            .update_project_conversation(
                "project-chat",
                ProjectConversationPatch {
                    access_mode: Some("workspace"),
                    ..Default::default()
                },
                "now",
            )
            .await
            .unwrap();
        let service = crate::ingestion::spawn(state.clone()).await;
        for _ in 0..200 {
            if state.ingestion.project_readiness(&state.store).await.ready {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let parent = caller_of(&state, &message.id).await;
        Fx {
            dir,
            state,
            parent,
            _service: service,
        }
    }

    async fn add_thread(
        fx: &Fx,
        id: &str,
        title: &str,
        family: AgentFamily,
        access: &str,
        at: &str,
    ) -> StoredProjectConversation {
        let parent = &fx.parent;
        let created = fx
            .state
            .store
            .create_project_conversation(ProjectConversationInsert {
                conversation_id: id,
                project_id: &parent.project.id,
                family,
                provider_store: crate::providers::provider_store(&fx.state, family),
                native_session_id: None,
                cwd: &parent.conversation.cwd,
                roots_revision: parent.project.roots_revision,
                title,
                model: (family == AgentFamily::Codex).then_some("fake"),
                effort: None,
                service_tier: None,
                access_mode: access,
                claude_approval: if family == AgentFamily::Claude {
                    "ask"
                } else {
                    agent_defaults::claude_approval(family)
                },
                plan_mode: false,
                creation_request_id: None,
                now: at,
            })
            .await
            .unwrap();
        match created {
            ProjectConversationCreate::Created(thread)
            | ProjectConversationCreate::Existing(thread) => thread,
        }
    }

    // A thread in a second Project, which no tool of the first may reach.
    async fn add_foreign_thread(fx: &Fx) {
        let source = fx.dir.path().join("other-source");
        std::fs::create_dir(&source).unwrap();
        let path = std::fs::canonicalize(&source)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let root = ProjectRootInput {
            path: path.clone(),
            canonical_path: path.clone(),
        };
        fx.state
            .store
            .create_project("other", "r2", "h2", "Other", &[root], 0, "now")
            .await
            .unwrap();
        fx.state
            .store
            .create_project_conversation(ProjectConversationInsert {
                conversation_id: "foreign",
                project_id: "other",
                family: AgentFamily::Codex,
                provider_store: &fx.state.projects.codex_store,
                native_session_id: None,
                cwd: &path,
                roots_revision: 1,
                title: "Foreign",
                model: Some("fake"),
                effort: None,
                service_tier: None,
                access_mode: "workspace",
                claude_approval: "ask",
                plan_mode: false,
                creation_request_id: None,
                now: "now",
            })
            .await
            .unwrap();
    }

    async fn queue(fx: &Fx, conversation: &str, text: &str) -> wonder_store::StoredMessage {
        let MessageInsert::Inserted(message) = fx
            .state
            .store
            .insert_dispatch_message(
                "owner",
                &uuid::Uuid::new_v4().to_string(),
                text,
                "hash",
                conversation,
                &[],
                "2026-01-01T00:00:00Z",
                true,
            )
            .await
            .unwrap()
        else {
            panic!("new message")
        };
        message
    }

    async fn settle(fx: &Fx, message: &str, state: &str) {
        fx.state
            .store
            .update_message_delivery(message, state, None, None)
            .await
            .unwrap();
    }

    fn fresh() -> String {
        uuid::Uuid::new_v4().to_string()
    }

    async fn run(fx: &Fx, tool: &str, args: Value) -> Result<Value, String> {
        execute(&fx.state, &fx.parent, tool, args)
            .await
            .map_err(|e| e.code.to_owned())
    }

    #[test]
    fn every_registered_tool_has_one_object_schema() {
        let specs = specs();
        let names: Vec<_> = specs.iter().map(|s| s["name"].as_str().unwrap()).collect();
        assert_eq!(
            names,
            [
                "wonder_thread_list",
                "wonder_thread_read",
                "wonder_thread_send",
                "wonder_thread_wait",
                "wonder_delegate"
            ]
        );
        for spec in &specs {
            assert!(registered(spec["name"].as_str().unwrap()));
            assert_eq!(spec["inputSchema"]["type"], "object");
        }
        assert!(!registered("wonder_assign_project"));
    }

    #[tokio::test]
    async fn list_is_limited_to_the_callers_project_and_pages_without_repeats() {
        let fx = fx().await;
        for (n, title) in ["One", "Two", "Three", "Four"].into_iter().enumerate() {
            let at = format!("2026-01-01T00:00:0{n}Z");
            add_thread(
                &fx,
                &format!("t{n}"),
                title,
                AgentFamily::Codex,
                "workspace",
                &at,
            )
            .await;
        }
        add_foreign_thread(&fx).await;
        let mut seen = Vec::new();
        let mut cursor: Option<String> = None;
        let mut pages = 0;
        loop {
            let mut args = json!({"limit": 2});
            if let Some(cursor) = &cursor {
                args["cursor"] = json!(cursor);
            }
            let page = run(&fx, LIST, args).await.unwrap();
            pages += 1;
            assert!(page["threads"].as_array().unwrap().len() <= 2);
            seen.extend(
                page["threads"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|t| t["id"].as_str().unwrap().to_owned()),
            );
            cursor = page["nextCursor"].as_str().map(str::to_owned);
            if cursor.is_none() {
                break;
            }
        }
        assert_eq!(pages, 3);
        assert_eq!(seen, ["project-chat", "t3", "t2", "t1", "t0"]);
        let first = run(&fx, LIST, json!({})).await.unwrap();
        assert_eq!(first["threads"][0]["isCurrent"], true);
        assert_eq!(first["threads"][0]["status"], "working");
        assert_eq!(first["threads"][1]["status"], "idle");
    }

    #[tokio::test]
    async fn no_tool_reaches_a_thread_of_another_project() {
        let fx = fx().await;
        add_foreign_thread(&fx).await;
        for (tool, args) in [
            (READ, json!({"threadId":"foreign"})),
            (
                SEND,
                json!({"threadId":"foreign","message":"hi","clientRequestId":fresh()}),
            ),
            (WAIT, json!({"threadId":"foreign","timeoutSeconds":1})),
            (READ, json!({"threadId":"missing"})),
        ] {
            assert_eq!(
                run(&fx, tool, args).await.unwrap_err(),
                "not_found",
                "{tool}"
            );
        }
        assert!(fx
            .state
            .store
            .open_message_ids("foreign")
            .await
            .unwrap()
            .is_empty());
    }

    #[test]
    fn a_page_of_history_resumes_after_the_last_position_and_hides_work_output() {
        let items: Vec<Value> = (0..7)
            .map(|n| match n % 3 {
                0 => json!({"type":"userMessage","content":[{"type":"text","text":format!("ask {n}")}],"clientId":format!("c{n}")}),
                1 => json!({"type":"reasoning","text":"private thoughts"}),
                _ => json!({"type":"agentMessage","text":format!("answer {n}")}),
            })
            .collect();
        let read = |after| {
            let mut page = Page::new(after, 2);
            for item in &items {
                if page.push(item) {
                    break;
                }
            }
            page
        };
        let first = read(0);
        assert_eq!(first.items.iter().map(|i| i.0).collect::<Vec<_>>(), [1, 2]);
        assert!(first.more);
        let second = read(2);
        assert_eq!(
            second.items.iter().map(|i| i.2.clone()).collect::<Vec<_>>(),
            ["ask 3", "answer 5"]
        );
        let last = read(4);
        assert_eq!(last.items.len(), 1);
        assert_eq!(last.items[0].3.as_deref(), Some("c6"));
        assert!(!last.more);
        let command = json!({"type":"commandExecution","command":"cargo test","status":"completed","exitCode":0,"aggregatedOutput":"SECRET OUTPUT"});
        let (role, line) = summarize(&command).unwrap();
        assert_eq!(
            (role, line.as_str()),
            ("tool", "Ran `cargo test` (completed, exit 0)")
        );
        assert!(summarize(&json!({"type":"reasoning","text":"x"})).is_none());
    }

    #[tokio::test]
    async fn read_shows_queued_messages_and_who_sent_them() {
        let fx = fx().await;
        add_thread(
            &fx,
            "peer",
            "Peer",
            AgentFamily::Codex,
            "workspace",
            "2026-01-01T00:00:00Z",
        )
        .await;
        let sent =
            json!({"threadId":"peer","message":"look at the tests","clientRequestId":fresh()});
        run(&fx, SEND, sent).await.unwrap();
        let read = run(&fx, READ, json!({"threadId":"peer"})).await.unwrap();
        assert_eq!(read["items"], json!([]));
        assert_eq!(read["queuedMessages"][0]["text"], "look at the tests");
        assert_eq!(read["queuedMessages"][0]["from"], "Recovery");
        assert_eq!(read["status"], "working");
    }

    #[tokio::test]
    async fn send_queues_with_its_source_and_a_retry_changes_nothing() {
        let fx = fx().await;
        add_thread(
            &fx,
            "peer",
            "Peer",
            AgentFamily::Codex,
            "workspace",
            "2026-01-01T00:00:00Z",
        )
        .await;
        let request = fresh();
        let args = json!({"threadId":"peer","message":"please review","clientRequestId":request});
        let first = run(&fx, SEND, args.clone()).await.unwrap();
        assert_eq!(first["duplicate"], false);
        assert_eq!(first["mode"], "queue");
        let again = run(&fx, SEND, args).await.unwrap();
        assert_eq!(again["messageId"], first["messageId"]);
        assert_eq!(again["duplicate"], true);
        let queued = fx.state.store.pending_queue("peer").await.unwrap();
        assert_eq!(queued.len(), 1);
        assert_eq!(queued[0].body, "please review");
        let id = first["messageId"].as_str().unwrap();
        let source = fx.state.store.message_source(id).await.unwrap().unwrap();
        assert_eq!(
            (source.kind.as_str(), source.source_title.as_str()),
            ("thread", "Recovery")
        );
        assert_eq!(
            source.source_conversation_id.as_deref(),
            Some("project-chat")
        );
        // The agent reading it is told who wrote it; the stored text is untouched.
        assert!(provider_text(Some(&source), "please review").contains("\"Recovery\""));
        assert_eq!(provider_text(None, "plain"), "plain");
        // The same request id with another message is refused, not queued.
        let reused =
            json!({"threadId":"peer","message":"something else","clientRequestId":request});
        assert_eq!(run(&fx, SEND, reused).await.unwrap_err(), "request_reused");
        assert_eq!(fx.state.store.pending_queue("peer").await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn send_cannot_direct_a_thread_with_wider_access_or_itself() {
        let fx = fx().await;
        add_thread(
            &fx,
            "full",
            "Full",
            AgentFamily::Codex,
            "full_access",
            "2026-01-01T00:00:00Z",
        )
        .await;
        let to_full = json!({"threadId":"full","message":"rm it","clientRequestId":fresh()});
        assert_eq!(
            run(&fx, SEND, to_full).await.unwrap_err(),
            "permission_escalation"
        );
        add_thread(
            &fx,
            "reader",
            "Reader",
            AgentFamily::Codex,
            "read_only",
            "2026-01-01T00:00:00Z",
        )
        .await;
        let down = json!({"threadId":"reader","message":"summarize","clientRequestId":fresh()});
        assert!(run(&fx, SEND, down).await.is_ok());
        let itself = json!({"threadId":"project-chat","message":"x","clientRequestId":fresh()});
        assert_eq!(run(&fx, SEND, itself).await.unwrap_err(), "invalid");
        assert!(fx
            .state
            .store
            .open_message_ids("full")
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn steer_is_refused_where_unsupported_and_needs_a_running_response() {
        let fx = fx().await;
        let claude = add_thread(
            &fx,
            "claude",
            "Claude peer",
            AgentFamily::Claude,
            "workspace",
            "2026-01-01T00:00:00Z",
        )
        .await;
        let steer = |thread: &str| json!({"threadId":thread,"message":"change course","mode":"steer","clientRequestId":fresh()});
        assert_eq!(
            run(&fx, SEND, steer(&claude.conversation_id))
                .await
                .unwrap_err(),
            "steer_unsupported"
        );
        add_thread(
            &fx,
            "codex",
            "Codex peer",
            AgentFamily::Codex,
            "workspace",
            "2026-01-01T00:00:00Z",
        )
        .await;
        assert_eq!(
            run(&fx, SEND, steer("codex")).await.unwrap_err(),
            "not_running"
        );
        let running = queue(&fx, "codex", "work").await;
        fx.state
            .store
            .update_message_delivery(
                &running.id,
                "streaming",
                Some("peer-thread"),
                Some("peer-turn"),
            )
            .await
            .unwrap();
        let sent = run(&fx, SEND, steer("codex")).await.unwrap();
        assert_eq!(sent["mode"], "steer");
        let guides = fx.state.store.pending_guides().await.unwrap();
        assert_eq!(guides.len(), 1);
        assert_eq!(
            (guides[0].0.id.as_str(), guides[0].1.as_str()),
            (sent["messageId"].as_str().unwrap(), "peer-turn")
        );
        assert!(fx
            .state
            .store
            .message_source(&guides[0].0.id)
            .await
            .unwrap()
            .is_some());
    }

    // The phone's Guide button posts to the steer route; a Project Codex
    // thread's running turn takes it, a Project Claude thread's refuses it.
    #[tokio::test]
    async fn phone_guide_steers_a_project_codex_turn_and_refuses_claude() {
        let fx = fx().await;
        for (id, family) in [
            ("codex", AgentFamily::Codex),
            ("claude", AgentFamily::Claude),
        ] {
            add_thread(&fx, id, id, family, "workspace", "2026-01-01T00:00:00Z").await;
            let running = queue(&fx, id, "busy").await;
            let (thread, turn) = (format!("{id}-thread"), format!("{id}-turn"));
            fx.state
                .store
                .update_message_delivery(&running.id, "streaming", Some(&thread), Some(&turn))
                .await
                .unwrap();
            let (status, body) = crate::permission_modes::tests::call(
                &fx.state,
                "POST",
                &format!("/api/v1/conversations/{id}/turns/{turn}/steer"),
                json!({"deviceId":"owner","clientMessageId":fresh(),"body":"use the new API","expectedTurnId":turn}),
            )
            .await;
            if family == AgentFamily::Codex {
                assert_eq!(status, StatusCode::ACCEPTED, "{body}");
                let guides = fx.state.store.pending_guides().await.unwrap();
                assert!(guides
                    .iter()
                    .any(|(m, t)| m.conversation_id == id && t == &turn));
            } else {
                assert_eq!(status, StatusCode::CONFLICT, "{body}");
            }
        }
    }

    // The Guide path used to serve Bot chats only; a Project thread's running
    // turn must take the steer through its own provider runtime.
    #[tokio::test]
    async fn a_steer_reaches_the_running_turn_of_a_project_thread() {
        let fx = fx().await;
        add_thread(
            &fx,
            "sender",
            "Sender",
            AgentFamily::Codex,
            "full_access",
            "2026-01-01T00:00:00Z",
        )
        .await;
        let working = queue(&fx, "sender", "coordinate").await;
        fx.state
            .store
            .update_message_delivery(
                &working.id,
                "streaming",
                Some("sender-thread"),
                Some("sender-turn"),
            )
            .await
            .unwrap();
        let sender = caller_of(&fx.state, &working.id).await;
        // The target is mid-turn on a runtime thread of its own.
        let target = fresh();
        add_thread(
            &fx,
            &target,
            "Target",
            AgentFamily::Codex,
            "workspace",
            "2026-01-01T00:00:00Z",
        )
        .await;
        fx.state
            .store
            .bind_project_runtime(
                &target,
                AgentFamily::Codex,
                &fx.state.projects.codex_store,
                "target-thread",
                None,
                "now",
            )
            .await
            .unwrap();
        let running = queue(&fx, &target, "busy").await;
        fx.state
            .store
            .update_message_delivery(
                &running.id,
                "streaming",
                Some("target-thread"),
                Some("target-turn"),
            )
            .await
            .unwrap();
        let steer = json!({"threadId":target,"message":"use the new API","mode":"steer","clientRequestId":fresh()});
        let sent = execute(&fx.state, &sender, SEND, steer).await.unwrap();
        let guide = fx.state.store.pending_guides().await.unwrap().remove(0);
        assert_eq!(guide.0.id, sent["messageId"].as_str().unwrap());
        let response = crate::dispatch_guide(fx.state.clone(), guide.0.clone(), guide.1).await;
        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let stored = fx
            .state
            .store
            .message_by_id(&guide.0.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(stored.state, "accepted_by_codex");
        let requests = std::fs::read_to_string(fx.dir.path().join("requests-jsonl")).unwrap();
        let steer: Value = requests
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .find(|request| request["method"] == "turn/steer")
            .unwrap();
        assert_eq!(steer["params"]["threadId"], "target-thread");
        let text = steer["params"]["input"][0]["text"].as_str().unwrap();
        assert!(
            text.contains("\"Sender\"") && text.ends_with("use the new API"),
            "{text}"
        );
    }

    #[tokio::test]
    async fn wait_times_out_as_still_running_without_stopping_the_thread() {
        let fx = fx().await;
        add_thread(
            &fx,
            "peer",
            "Peer",
            AgentFamily::Codex,
            "workspace",
            "2026-01-01T00:00:00Z",
        )
        .await;
        let running = queue(&fx, "peer", "long work").await;
        fx.state
            .store
            .update_message_delivery(
                &running.id,
                "streaming",
                Some("peer-thread"),
                Some("peer-turn"),
            )
            .await
            .unwrap();
        let timed_out = run(&fx, WAIT, json!({"threadId":"peer","timeoutSeconds":1}))
            .await
            .unwrap();
        assert_eq!(timed_out["status"], "still_running");
        assert_eq!(timed_out["threadStatus"], "working");
        let after = fx
            .state
            .store
            .message_by_id(&running.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(after.state, "streaming");
        // The same wait answers as soon as the work ends, and idle threads do not wait.
        let store = fx.state.store.clone();
        let finishing = running.id.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            store
                .update_message_delivery(&finishing, "completed", None, None)
                .await
                .unwrap();
        });
        let done = run(&fx, WAIT, json!({"threadId":"peer","timeoutSeconds":20}))
            .await
            .unwrap();
        assert_eq!(
            (done["status"].as_str(), done["outcome"].as_str()),
            (Some("finished"), Some("completed"))
        );
        let idle = run(&fx, WAIT, json!({"threadId":"peer"})).await.unwrap();
        assert_eq!(idle["status"], "idle");
    }

    #[tokio::test]
    async fn delegate_creates_a_narrowed_child_with_lineage_and_replays_once() {
        let fx = fx().await;
        let request = fresh();
        let args = json!({"clientRequestId":request,"prompt":"Fix the flaky test","provider":"codex","model":"fake","accessMode":"read_only","title":"Flaky test"});
        let first = run(&fx, DELEGATE, args.clone()).await.unwrap();
        let child_id = first["threadId"].as_str().unwrap();
        assert_eq!(
            (first["created"].as_bool(), first["accessMode"].as_str()),
            (Some(true), Some("read_only"))
        );
        let child = fx
            .state
            .store
            .project_conversation(child_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(child.project_id, "project");
        assert_eq!(child.cwd, fx.parent.conversation.cwd);
        assert_eq!(
            (child.title.as_str(), child.model.as_deref()),
            ("Flaky test", Some("fake"))
        );
        let link = fx
            .state
            .store
            .thread_delegation(child_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(link.parent_conversation_id, "project-chat");
        // The child receives only the prompt, labelled as delegated by the parent.
        let queued = fx.state.store.pending_queue(child_id).await.unwrap();
        assert_eq!(
            queued.iter().map(|q| q.body.as_str()).collect::<Vec<_>>(),
            ["Fix the flaky test"]
        );
        let source = fx
            .state
            .store
            .message_source(first["messageId"].as_str().unwrap())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(source.kind, "delegation");
        // A retry finds the same thread and message.
        let again = run(&fx, DELEGATE, args).await.unwrap();
        assert_eq!(
            (again["threadId"].as_str(), again["created"].as_bool()),
            (Some(child_id), Some(false))
        );
        assert_eq!(again["messageId"], first["messageId"]);
        assert_eq!(
            fx.state
                .store
                .project_conversations("project")
                .await
                .unwrap()
                .len(),
            2
        );
        assert_eq!(
            fx.state.store.pending_queue(child_id).await.unwrap().len(),
            1
        );
        // Reusing the request for another task is refused.
        let other = json!({"clientRequestId":request,"prompt":"Something else","provider":"codex","model":"fake"});
        assert_eq!(
            run(&fx, DELEGATE, other).await.unwrap_err(),
            "request_reused"
        );
    }

    #[tokio::test]
    async fn delegate_defaults_to_the_parents_access_and_never_exceeds_it() {
        let fx = fx().await;
        let inherited =
            json!({"clientRequestId":fresh(),"prompt":"Do it","provider":"codex","model":"fake"});
        assert_eq!(
            run(&fx, DELEGATE, inherited).await.unwrap()["accessMode"],
            "workspace"
        );
        let wider = json!({"clientRequestId":fresh(),"prompt":"Do it all","provider":"codex","model":"fake","accessMode":"full_access"});
        assert_eq!(
            run(&fx, DELEGATE, wider).await.unwrap_err(),
            "permission_escalation"
        );
        assert_eq!(
            fx.state
                .store
                .project_conversations("project")
                .await
                .unwrap()
                .len(),
            2,
            "the refused delegation created nothing"
        );
        // Approval: a Codex parent always asks, so no child may ask less.
        let parent = &fx.parent.conversation;
        assert_eq!(default_approval(AgentFamily::Claude, parent), "ask");
        assert_eq!(default_approval(AgentFamily::Codex, parent), "ask");
        let mut claude_parent = parent.clone();
        claude_parent.family = AgentFamily::Claude;
        claude_parent.claude_approval = "accept_edits".into();
        assert_eq!(
            default_approval(AgentFamily::Claude, &claude_parent),
            "accept_edits"
        );
        claude_parent.claude_approval = "auto".into();
        assert_eq!(
            default_approval(AgentFamily::Claude, &claude_parent),
            "auto"
        );
        let mut asking = claude_parent.clone();
        asking.claude_approval = "ask".into();
        assert!(within_authority(&asking, &claude_parent).is_err());
        assert!(within_authority(&claude_parent, &asking).is_ok());
    }

    #[tokio::test]
    async fn delegate_rejects_unavailable_targets_plan_mode_and_runaway_depth() {
        let fx = fx().await;
        let bad_model = json!({"clientRequestId":fresh(),"prompt":"x","provider":"codex","model":"not-a-model"});
        assert_eq!(
            run(&fx, DELEGATE, bad_model).await.unwrap_err(),
            "unavailable_model"
        );
        let no_claude = json!({"clientRequestId":fresh(),"prompt":"x","provider":"claude","model":"claude:sonnet"});
        assert_eq!(
            run(&fx, DELEGATE, no_claude).await.unwrap_err(),
            "unavailable_provider"
        );
        let bad_provider = json!({"clientRequestId":fresh(),"prompt":"x","provider":"gemini"});
        assert_eq!(
            run(&fx, DELEGATE, bad_provider).await.unwrap_err(),
            "invalid"
        );
        assert_eq!(
            fx.state
                .store
                .project_conversations("project")
                .await
                .unwrap()
                .len(),
            1
        );
        // A chain three deep cannot grow another level.
        for (child, parent) in [("a", "project-chat"), ("b", "a"), ("c", "b")] {
            add_thread(
                &fx,
                child,
                child,
                AgentFamily::Codex,
                "workspace",
                "2026-01-01T00:00:00Z",
            )
            .await;
            fx.state
                .store
                .record_thread_delegation(child, parent, &fresh(), "owner", "now")
                .await
                .unwrap();
        }
        let mut deep = caller_of(&fx.state, &fx.parent.message.id).await;
        deep.conversation = fx
            .state
            .store
            .project_conversation("c")
            .await
            .unwrap()
            .unwrap();
        let args =
            json!({"clientRequestId":fresh(),"prompt":"x","provider":"codex","model":"fake"});
        assert_eq!(
            execute(&fx.state, &deep, DELEGATE, args.clone())
                .await
                .unwrap_err()
                .code,
            "depth_limit"
        );
        let mut planning = caller_of(&fx.state, &fx.parent.message.id).await;
        planning.conversation.plan_mode = true;
        assert_eq!(
            execute(&fx.state, &planning, DELEGATE, args)
                .await
                .unwrap_err()
                .code,
            "plan_mode"
        );
        let send = json!({"threadId":"a","message":"x","clientRequestId":fresh()});
        assert_eq!(
            execute(&fx.state, &planning, SEND, send)
                .await
                .unwrap_err()
                .code,
            "plan_mode"
        );
    }

    #[tokio::test]
    async fn delegate_wait_blocks_until_the_child_ends() {
        let fx = fx().await;
        let args = json!({"clientRequestId":fresh(),"prompt":"Quick job","provider":"codex","model":"fake","mode":"wait","timeoutSeconds":20});
        let store = fx.state.store.clone();
        let watcher = tokio::spawn(async move {
            // Stand in for the dispatcher: finish whatever the child was given.
            for _ in 0..200 {
                let children = store.project_conversations("project").await.unwrap();
                if let Some(child) = children
                    .into_iter()
                    .find(|c| c.conversation_id != "project-chat")
                {
                    if let Some(message) = store
                        .open_message_ids(&child.conversation_id)
                        .await
                        .unwrap()
                        .first()
                    {
                        tokio::time::sleep(Duration::from_millis(300)).await;
                        store
                            .update_message_delivery(message, "completed", None, None)
                            .await
                            .unwrap();
                        return;
                    }
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        });
        let done = run(&fx, DELEGATE, args).await.unwrap();
        watcher.await.unwrap();
        assert_eq!(
            (done["status"].as_str(), done["outcome"].as_str()),
            (Some("finished"), Some("completed"))
        );
        // The parent has now seen the result itself, so no wake-up follows.
        settle(&fx, &fx.parent.message.id, "completed").await;
        wake_parents(&fx.state).await;
        assert!(fx
            .state
            .store
            .open_message_ids("project-chat")
            .await
            .unwrap()
            .is_empty());
    }

    async fn delegated(
        fx: &Fx,
        id: &str,
        title: &str,
        parent: &str,
    ) -> wonder_store::StoredMessage {
        add_thread(
            fx,
            id,
            title,
            AgentFamily::Codex,
            "workspace",
            "2026-01-01T00:00:00Z",
        )
        .await;
        fx.state
            .store
            .record_thread_delegation(id, parent, &fresh(), "owner", "now")
            .await
            .unwrap();
        queue(fx, id, "task").await
    }

    #[tokio::test]
    async fn two_finished_children_wake_an_idle_parent_once() {
        let fx = fx().await;
        let a = delegated(&fx, "a", "Tests", "project-chat").await;
        let b = delegated(&fx, "b", "Docs", "project-chat").await;
        settle(&fx, &a.id, "completed").await;
        settle(&fx, &b.id, "failed").await;
        // The parent is still running its turn: nothing is sent into it.
        wake_parents(&fx.state).await;
        assert_eq!(
            fx.state
                .store
                .open_message_ids("project-chat")
                .await
                .unwrap()
                .len(),
            1
        );
        settle(&fx, &fx.parent.message.id, "completed").await;
        wake_parents(&fx.state).await;
        wake_parents(&fx.state).await;
        let open = fx
            .state
            .store
            .open_message_ids("project-chat")
            .await
            .unwrap();
        assert_eq!(
            open.len(),
            1,
            "one batched wake-up, however often the loop runs"
        );
        let wake = fx
            .state
            .store
            .message_by_id(&open[0])
            .await
            .unwrap()
            .unwrap();
        assert!(
            wake.body.contains("\"Tests\" (completed)") && wake.body.contains("\"Docs\" (failed)"),
            "{}",
            wake.body
        );
        assert!(wake.body.contains("wonder_thread_read"));
        let source = fx
            .state
            .store
            .message_source(&wake.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(source.kind, "wake");
        // It reaches the timeline but not the owner's queue.
        assert!(fx
            .state
            .store
            .pending_queue("project-chat")
            .await
            .unwrap()
            .is_empty());
        assert!(fx
            .state
            .store
            .queued_message_bodies("project-chat")
            .await
            .unwrap()
            .is_empty());
        assert_eq!(provider_text(Some(&source), &wake.body), wake.body);
    }

    #[tokio::test]
    async fn a_later_completion_waits_for_the_next_idle_moment() {
        let fx = fx().await;
        settle(&fx, &fx.parent.message.id, "completed").await;
        let a = delegated(&fx, "a", "First", "project-chat").await;
        settle(&fx, &a.id, "completed").await;
        wake_parents(&fx.state).await;
        let first = fx
            .state
            .store
            .open_message_ids("project-chat")
            .await
            .unwrap();
        assert_eq!(first.len(), 1);
        // Another child ends while the wake-up is still queued or running.
        let c = delegated(&fx, "c", "Late", "project-chat").await;
        settle(&fx, &c.id, "completed").await;
        wake_parents(&fx.state).await;
        assert_eq!(
            fx.state
                .store
                .open_message_ids("project-chat")
                .await
                .unwrap(),
            first
        );
        settle(&fx, &first[0], "completed").await;
        wake_parents(&fx.state).await;
        let second = fx
            .state
            .store
            .open_message_ids("project-chat")
            .await
            .unwrap();
        assert_eq!(second.len(), 1);
        let body = fx
            .state
            .store
            .message_by_id(&second[0])
            .await
            .unwrap()
            .unwrap()
            .body;
        assert!(
            body.contains("\"Late\"") && !body.contains("\"First\""),
            "{body}"
        );
    }

    #[tokio::test]
    async fn a_nested_child_wakes_its_parent_not_the_root_and_queued_user_work_blocks_a_wake() {
        let fx = fx().await;
        settle(&fx, &fx.parent.message.id, "completed").await;
        let mid = delegated(&fx, "mid", "Middle", "project-chat").await;
        settle(&fx, &mid.id, "completed").await;
        let leaf = delegated(&fx, "leaf", "Leaf", "mid").await;
        settle(&fx, &leaf.id, "completed").await;
        // The user has typed a follow-up for the middle thread: it is not idle,
        // so neither it nor the root is told anything yet.
        let typed = queue(&fx, "mid", "one more thing").await;
        wake_parents(&fx.state).await;
        assert!(fx
            .state
            .store
            .open_message_ids("project-chat")
            .await
            .unwrap()
            .is_empty());
        assert_eq!(
            fx.state.store.open_message_ids("mid").await.unwrap(),
            std::slice::from_ref(&typed.id)
        );
        // Once it is done the leaf's result goes to Middle, not to the root, and
        // the root waits until Middle has finished acting on it.
        settle(&fx, &typed.id, "completed").await;
        wake_parents(&fx.state).await;
        assert!(fx
            .state
            .store
            .open_message_ids("project-chat")
            .await
            .unwrap()
            .is_empty());
        let mid_open = fx.state.store.open_message_ids("mid").await.unwrap();
        assert_eq!(mid_open.len(), 1);
        let body = fx
            .state
            .store
            .message_by_id(&mid_open[0])
            .await
            .unwrap()
            .unwrap()
            .body;
        assert!(body.contains("\"Leaf\""));
        settle(&fx, &mid_open[0], "completed").await;
        wake_parents(&fx.state).await;
        let root = fx
            .state
            .store
            .open_message_ids("project-chat")
            .await
            .unwrap();
        assert_eq!(root.len(), 1);
        let root_body = fx
            .state
            .store
            .message_by_id(&root[0])
            .await
            .unwrap()
            .unwrap()
            .body;
        assert!(root_body.contains("Middle") && !root_body.contains("Leaf"));
    }

    #[tokio::test]
    async fn new_work_for_a_child_is_reported_again_and_reading_it_cancels_a_wake() {
        let fx = fx().await;
        let a = delegated(&fx, "a", "Worker", "project-chat").await;
        settle(&fx, &a.id, "completed").await;
        settle(&fx, &fx.parent.message.id, "completed").await;
        wake_parents(&fx.state).await;
        let wake = fx
            .state
            .store
            .open_message_ids("project-chat")
            .await
            .unwrap();
        settle(&fx, &wake[0], "completed").await;
        wake_parents(&fx.state).await;
        assert!(
            fx.state
                .store
                .open_message_ids("project-chat")
                .await
                .unwrap()
                .is_empty(),
            "already reported"
        );
        // A new message from the parent rearms the child.
        let mut running_parent = caller_of(&fx.state, &fx.parent.message.id).await;
        running_parent.message.state = "streaming".into();
        let again = json!({"threadId":"a","message":"again","clientRequestId":fresh()});
        execute(&fx.state, &running_parent, SEND, again)
            .await
            .unwrap();
        let open = fx.state.store.open_message_ids("a").await.unwrap();
        settle(&fx, &open[0], "completed").await;
        // Reading the idle child's result makes a wake-up unnecessary.
        let read = execute(&fx.state, &running_parent, READ, json!({"threadId":"a"}))
            .await
            .unwrap();
        assert_eq!(read["status"], "idle");
        wake_parents(&fx.state).await;
        assert!(fx
            .state
            .store
            .open_message_ids("project-chat")
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn runtime_calls_are_correlated_scoped_and_replayed() {
        let fx = fx().await;
        let rpc = crate::projects::codex_rpc(&fx.state).await.unwrap();
        let runtime = rpc.health().id().to_owned();
        let params = |call: &str, tool: &str, arguments: Value| json!({"threadId":"thread","turnId":"turn","callId":call,"tool":tool,"arguments":arguments});
        let message = Some(&fx.parent.message);
        let first = handle_call(&fx.state, &runtime, &params("c1", LIST, json!({})), message).await;
        assert_eq!(first["success"], true);
        // The same runtime call replays its saved answer; new arguments are refused.
        assert_eq!(
            handle_call(&fx.state, &runtime, &params("c1", LIST, json!({})), message).await,
            first
        );
        let reused = handle_call(
            &fx.state,
            &runtime,
            &params("c1", LIST, json!({"limit":1})),
            message,
        )
        .await;
        assert_eq!(reused["success"], false);
        assert!(reused["contentItems"][0]["text"]
            .as_str()
            .unwrap()
            .contains("call_reused"));
        // Another turn's request is not accepted for this message.
        let wrong =
            json!({"threadId":"thread","turnId":"other","callId":"c2","tool":LIST,"arguments":{}});
        assert_eq!(
            handle_call(&fx.state, &runtime, &wrong, message).await["success"],
            false
        );
        assert_eq!(
            handle_call(&fx.state, &runtime, &params("c3", LIST, json!({})), None).await["success"],
            false
        );
        // A conversation that is not a Project thread has no thread tools.
        let mut elsewhere = fx.parent.message.clone();
        elsewhere.conversation_id = "not-a-project".into();
        let answer = handle_call(
            &fx.state,
            &runtime,
            &params("c4", LIST, json!({})),
            Some(&elsewhere),
        )
        .await;
        assert!(answer["contentItems"][0]["text"]
            .as_str()
            .unwrap()
            .contains("not_project"));
    }

    #[tokio::test]
    async fn a_new_codex_project_thread_registers_the_tools_at_start() {
        let fx = fx().await;
        // The fake runtime would hand out the id the parent already owns.
        let script = fx.dir.path().join("runtime.py");
        let source = std::fs::read_to_string(&script).unwrap();
        let original = "elif method == 'thread/start': result = {'thread':{'id':'thread'}}";
        assert!(source.contains(original));
        std::fs::write(
            &script,
            source.replace(
                original,
                "elif method == 'thread/start': result = {'thread':{'id':'fresh-thread'}}",
            ),
        )
        .unwrap();
        fx.state.projects.shutdown().await;
        let id = fresh();
        add_thread(
            &fx,
            &id,
            "Fresh",
            AgentFamily::Codex,
            "workspace",
            "2026-01-01T00:00:00Z",
        )
        .await;
        let message = queue(&fx, &id, "Hello").await;
        assert!(fx
            .state
            .store
            .claim_message_for_dispatch(&message.id)
            .await
            .unwrap());
        let message = fx
            .state
            .store
            .message_by_id(&message.id)
            .await
            .unwrap()
            .unwrap();
        let mut submitting = false;
        crate::projects::dispatch_inner(&fx.state, &message, &mut submitting)
            .await
            .unwrap();
        let requests = std::fs::read_to_string(fx.dir.path().join("requests-jsonl")).unwrap();
        let start: Value = requests
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .find(|request| request["method"] == "thread/start")
            .unwrap();
        let names: Vec<_> = start["params"]["dynamicTools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert_eq!(
            names,
            [
                "wonder_thread_list",
                "wonder_thread_read",
                "wonder_thread_send",
                "wonder_thread_wait",
                "wonder_delegate"
            ]
        );
    }
}
