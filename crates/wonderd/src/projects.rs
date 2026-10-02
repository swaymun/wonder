//! Owner-selected source-folder projects on this Mac. A project thread is the
//! owner's native Codex or Claude Code session in its normal provider store, so
//! it continues in the Codex app/CLI or Claude Code. Bots keep their private
//! runtime; nothing here creates a Bot or copies a provider transcript.
use crate::{publish_message_state, AppState, AuthenticatedDevice, DeliveryState, OwnerAuthority};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Extension, Json,
};
use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::{Path as FsPath, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;
use wonder_app_server::{AppServerClient, LaunchConfig, RpcClient};
use wonder_store::{
    AgentFamily, MessageInsert, ProjectConversationCreate, ProjectConversationInsert,
    ProjectConversationPatch, ProjectCreate, ProjectRootInput, StoredProject,
    StoredProjectConversation,
};

pub const FEATURE: &str = "projects-v1";
/// Advertised in `GET /api/v1/projects`: the host accepts `claudeApproval` and
/// `planMode`, and lists pinned threads across included projects.
const MODES_VERSION: u8 = 1;
const MAX_PINNED_THREADS: i64 = 50;
const CODEX_SOURCE_KINDS: [&str; 4] = ["cli", "vscode", "exec", "appServer"];
const CURSOR_TTL: Duration = Duration::from_secs(15 * 60);
const MAX_CURSORS: usize = 128;
const ACCESS_MODES: [&str; 3] = ["read_only", "workspace", "full_access"];
const CLAUDE_APPROVALS: [&str; 3] = ["ask", "accept_edits", "auto"];

/// The normal-home Codex client serves project threads and shared discovery.
pub struct ProjectRuntime {
    codex: Arc<Mutex<AppServerClient>>,
    config: LaunchConfig,
    start: Mutex<()>,
    pub codex_store: String,
    pub claude_store: String,
    cursors: std::sync::Mutex<HashMap<String, (Instant, CatalogCursor)>>,
    /// Latest dispatch problem per conversation, in owner-facing language.
    notices: std::sync::Mutex<HashMap<String, String>>,
    /// Runtime generation that accepted each running turn. A changed or dead
    /// generation means the turn must be reconciled from native history.
    generations: std::sync::Mutex<HashMap<String, String>>,
}

impl ProjectRuntime {
    pub fn configured(
        codex_bin: PathBuf,
        wonder_version: String,
        codex_home: &FsPath,
        claude_home: &FsPath,
        sink: wonder_app_server::NotificationSink,
    ) -> Arc<Self> {
        Arc::new(Self {
            codex: Arc::new(Mutex::new(AppServerClient::unavailable(
                wonder_version.clone(),
                sink,
            ))),
            config: LaunchConfig {
                project_scope: true,
                codex_bin,
                runtime_home: None,
                wonder_version,
                permission_overrides: Vec::new(),
            },
            start: Mutex::new(()),
            codex_store: store_key("codex", codex_home),
            claude_store: store_key("claude", claude_home),
            cursors: std::sync::Mutex::new(HashMap::new()),
            notices: std::sync::Mutex::new(HashMap::new()),
            generations: std::sync::Mutex::new(HashMap::new()),
        })
    }

    pub async fn shutdown(&self) {
        let _ = self.codex.lock().await.shutdown().await;
    }
}

/// Opaque identity for a provider home. The path never leaves the host.
fn store_key(family: &str, home: &FsPath) -> String {
    let canonical = std::fs::canonicalize(home).unwrap_or_else(|_| home.to_path_buf());
    let digest = hex::encode(Sha256::digest(canonical.to_string_lossy().as_bytes()));
    format!("{family}:{}", &digest[..16])
}

pub async fn codex_rpc(state: &AppState) -> Result<RpcClient, String> {
    let runtime = &state.projects;
    let _start = runtime.start.lock().await;
    let mut client = runtime.codex.lock().await;
    if !client.health().is_alive() {
        client.restart(runtime.config.clone()).await.map_err(|_| {
            "Codex could not start on your Mac. Check that ChatGPT is installed and signed in."
                .to_owned()
        })?;
        if let Err(error) = crate::rediscover_runtime(state, &mut client, false).await {
            let _ = client.shutdown().await;
            return Err(error);
        }
        state
            .ingestion
            .register_project_runtime(&runtime.codex, client.health());
    }
    Ok(client.rpc())
}

fn claude_client(state: &AppState) -> Result<Arc<Mutex<AppServerClient>>, String> {
    state
        .claude
        .as_ref()
        .map(|runtime| runtime.client.clone())
        .ok_or_else(|| "Claude is not installed. Update Wonder on your Mac.".to_owned())
}

async fn claude_rpc(state: &AppState) -> Result<RpcClient, String> {
    let rpc = claude_client(state)?.lock().await.rpc();
    if !rpc.health().is_alive() {
        return Err("Claude is reconnecting on your Mac. Try again shortly.".into());
    }
    Ok(rpc)
}

pub(crate) async fn rpc_for(state: &AppState, family: AgentFamily) -> Result<RpcClient, String> {
    match family {
        AgentFamily::Codex => codex_rpc(state).await,
        AgentFamily::Claude => claude_rpc(state).await,
    }
}

fn provider_store(state: &AppState, family: AgentFamily) -> &str {
    match family {
        AgentFamily::Codex => &state.projects.codex_store,
        AgentFamily::Claude => &state.projects.claude_store,
    }
}

fn now_text() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn error(status: StatusCode, message: impl Into<String>) -> Response {
    (status, message.into()).into_response()
}

async fn result(rpc: &RpcClient, method: &str, params: Value) -> Result<Value, String> {
    let response = rpc
        .request(method, params)
        .await
        .map_err(|e| e.to_string())?;
    if let Some(error) = response.error {
        return Err(error.message);
    }
    response
        .result
        .ok_or_else(|| format!("{method} returned no result"))
}

// ---------------------------------------------------------------------------
// Presentation contracts
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FolderSummary {
    id: String,
    path: String,
    name: String,
    is_primary: bool,
    is_available: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectSummary {
    id: String,
    name: String,
    is_included: bool,
    is_pinned: bool,
    roots_revision: i64,
    folders: Vec<FolderSummary>,
    last_family: Option<AgentFamily>,
    last_used_at: Option<String>,
    created_at: String,
}

fn folder_name(path: &str) -> String {
    FsPath::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_owned())
}

fn project_summary(project: &StoredProject) -> ProjectSummary {
    ProjectSummary {
        id: project.id.clone(),
        name: project.name.clone(),
        is_included: project.is_included,
        is_pinned: project.pin_order.is_some(),
        roots_revision: project.roots_revision,
        folders: project
            .roots
            .iter()
            .map(|root| FolderSummary {
                id: root.id.clone(),
                path: root.path.clone(),
                name: folder_name(&root.path),
                is_primary: root.id == project.primary_root_id,
                is_available: FsPath::new(&root.canonical_path).is_dir(),
            })
            .collect(),
        last_family: project.last_family,
        last_used_at: project.last_used_at.clone(),
        created_at: project.created_at.clone(),
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectThreadSummary {
    /// Opaque catalog reference, accepted only by this project's attach route.
    reference: String,
    conversation_id: Option<String>,
    title: String,
    family: AgentFamily,
    updated_at: i64,
    is_pinned: bool,
    has_unread: bool,
    is_working: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectConversationDetail {
    conversation_id: String,
    project_id: String,
    project_name: String,
    title: String,
    family: AgentFamily,
    model: Option<String>,
    effort: Option<String>,
    service_tier: Option<String>,
    access_mode: String,
    claude_approval: String,
    plan_mode: bool,
    working_folder: String,
    working_folder_name: String,
    is_pinned: bool,
    has_unread: bool,
    has_native_session: bool,
    is_archived: bool,
    folder_in_project: bool,
    notice: Option<String>,
}

async fn conversation_detail(
    state: &AppState,
    conversation: &StoredProjectConversation,
) -> Result<ProjectConversationDetail, String> {
    let project = state
        .store
        .project(&conversation.project_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("The project is unavailable")?;
    Ok(ProjectConversationDetail {
        conversation_id: conversation.conversation_id.clone(),
        project_id: project.id.clone(),
        project_name: project.name.clone(),
        title: conversation.title.clone(),
        family: conversation.family,
        model: conversation.model.clone(),
        effort: conversation.effort.clone(),
        service_tier: conversation.service_tier.clone(),
        access_mode: conversation.access_mode.clone(),
        claude_approval: conversation.claude_approval.clone(),
        plan_mode: conversation.plan_mode,
        working_folder: conversation.cwd.clone(),
        working_folder_name: folder_name(&conversation.cwd),
        is_pinned: conversation.is_pinned,
        has_unread: conversation.has_unread,
        has_native_session: conversation.native_session_id.is_some(),
        is_archived: codex_is_archived(state, conversation).await?,
        folder_in_project: project.root_for(&conversation.cwd).is_some(),
        notice: state
            .projects
            .notices
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&conversation.conversation_id)
            .cloned(),
    })
}

/// Read provider-owned archive state without resuming a thread or relying on
/// its unstable rollout path. A failed/incomplete catalog never means active.
async fn archived_codex_ids(
    state: &AppState,
    conversations: &[StoredProjectConversation],
) -> Result<HashSet<String>, String> {
    let mut folders = HashSet::new();
    for conversation in conversations
        .iter()
        .filter(|c| c.family == AgentFamily::Codex && c.native_session_id.is_some())
    {
        if conversation.provider_store != state.projects.codex_store {
            return Err("This thread belongs to a different Codex history on your Mac.".into());
        }
        folders.insert(conversation.cwd.clone());
    }
    if folders.is_empty() {
        return Ok(HashSet::new());
    }
    let rpc = codex_rpc(state).await?;
    let mut archived = HashSet::new();
    let mut cursor: Option<String> = None;
    let mut seen = HashSet::new();
    for _ in 0..200 {
        let page = result(
            &rpc,
            "thread/list",
            json!({
                "cwd": folders, "sourceKinds": CODEX_SOURCE_KINDS, "archived": true,
                "useStateDbOnly": true, "limit": 100, "cursor": cursor,
            }),
        )
        .await?;
        let rows = page["data"]
            .as_array()
            .ok_or("Codex archive state is unavailable.")?;
        for row in rows {
            archived.insert(
                row["id"]
                    .as_str()
                    .ok_or("Codex archive state is incomplete.")?
                    .to_owned(),
            );
        }
        cursor = match page.get("nextCursor") {
            Some(Value::Null) => None,
            Some(Value::String(value)) => Some(value.clone()),
            _ => return Err("Codex archive state is incomplete.".into()),
        };
        let Some(next) = &cursor else {
            return Ok(archived);
        };
        if !seen.insert(next.clone()) {
            break;
        }
    }
    Err("Codex archive state could not be fully refreshed. Try again.".into())
}

async fn codex_is_archived(
    state: &AppState,
    conversation: &StoredProjectConversation,
) -> Result<bool, String> {
    let archived = archived_codex_ids(state, std::slice::from_ref(conversation)).await?;
    Ok(conversation
        .native_session_id
        .as_ref()
        .is_some_and(|id| archived.contains(id)))
}

async fn set_archived(
    state: &AppState,
    conversation: &StoredProjectConversation,
    archived: bool,
) -> Result<(), (StatusCode, String)> {
    let conflict = |message: &str| (StatusCode::CONFLICT, message.to_owned());
    let unavailable = |message: String| (StatusCode::SERVICE_UNAVAILABLE, message);
    if conversation.family != AgentFamily::Codex {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "Archiving in Claude and Wonder together is not available yet.".into(),
        ));
    }
    let Some(native) = conversation.native_session_id.as_deref() else {
        return Err(conflict(
            "Send the first message before archiving this thread.",
        ));
    };
    // Serialize against Wonder dispatch and refuse unsettled user intent.
    let _guard = state.dispatch_lock.lock().await;
    if state
        .store
        .conversation_has_archive_blocking_work(&conversation.conversation_id)
        .await
        .map_err(|_| unavailable("The thread's work could not be checked. Try again.".into()))?
    {
        return Err(conflict(
            "Finish or stop this thread's work and resolve its pending sends before archiving it.",
        ));
    }
    if codex_is_archived(state, conversation)
        .await
        .map_err(unavailable)?
        == archived
    {
        return Ok(()); // A lost response or a desktop action already completed it.
    }
    let rpc = codex_rpc(state).await.map_err(unavailable)?;
    let read = result(&rpc, "thread/read", json!({"threadId": native}))
        .await
        .map_err(unavailable)?;
    if read["thread"]["id"].as_str() != Some(native)
        || read["thread"]["cwd"].as_str() != Some(conversation.cwd.as_str())
    {
        return Err(conflict(
            "This thread's identity on your Mac changed. Reopen it before archiving.",
        ));
    }
    if archived {
        let turns = result(
            &rpc,
            "thread/turns/list",
            json!({
                "threadId": native, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded",
            }),
        )
        .await
        .map_err(unavailable)?;
        if read["thread"]["status"]["type"].as_str() == Some("active")
            || turns.pointer("/data/0/status").and_then(Value::as_str) == Some("inProgress")
        {
            return Err(conflict(
                "This thread is still working on your Mac. Finish or stop it before archiving.",
            ));
        }
        if !turns["data"].is_array() {
            return Err(unavailable(
                "This thread's work could not be checked. Try again.".into(),
            ));
        }
    }
    result(
        &rpc,
        if archived {
            "thread/archive"
        } else {
            "thread/unarchive"
        },
        json!({"threadId": native}),
    )
    .await
    .map_err(|_| {
        unavailable(
            "The archive change could not be confirmed. Refresh before trying again.".into(),
        )
    })?;
    // Existing catalog pages were read before the mutation and can contain it.
    state
        .projects
        .cursors
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
    Ok(())
}

// ---------------------------------------------------------------------------
// Folder validation
// ---------------------------------------------------------------------------

/// Existing, readable directories only. A project folder may not be, contain,
/// or sit inside a protected location such as provider credentials or
/// Wonder's own data; it is metadata and never widens a Mac access grant.
fn validate_folder(path: &str, denied: &[String]) -> Result<ProjectRootInput, &'static str> {
    if path.is_empty() || !path.starts_with('/') || path.len() > 4096 || path.contains('\0') {
        return Err("Choose an existing folder on your Mac.");
    }
    let lexical = FsPath::new(path);
    let canonical = std::fs::canonicalize(lexical)
        .map_err(|_| "A selected folder is no longer available on your Mac.")?;
    if !std::fs::metadata(&canonical).is_ok_and(|m| m.is_dir()) {
        return Err("Choose a folder, not a file.");
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    if canonical == FsPath::new("/")
        || home
            .as_ref()
            .and_then(|home| std::fs::canonicalize(home).ok())
            .is_some_and(|home| home == canonical)
    {
        return Err("Choose a specific project folder, not your whole Mac or home folder.");
    }
    for root in denied {
        let root = FsPath::new(root.strip_suffix("/**").unwrap_or(root));
        let Ok(protected) = crate::filesystem::protected_root(root) else {
            return Err("Protected Mac locations could not be checked.");
        };
        if canonical.starts_with(&protected) || protected.starts_with(&canonical) {
            return Err("This folder contains or is inside protected Mac settings. Choose a more specific project folder.");
        }
    }
    let canonical = canonical
        .to_str()
        .ok_or("Folder names must be valid text.")?
        .to_owned();
    let trimmed = path.trim_end_matches('/');
    Ok(ProjectRootInput {
        path: if trimmed.is_empty() {
            "/".into()
        } else {
            trimmed.to_owned()
        },
        canonical_path: canonical,
    })
}

/// Recheck persisted paths before every execution. A replaced symlink must
/// never redirect the agent to a folder the owner did not select.
pub(crate) fn validate_execution_roots(
    project: &StoredProject,
    denied: &[String],
) -> Result<(), &'static str> {
    for root in &project.roots {
        let current = validate_folder(&root.path, denied)?;
        if current.canonical_path != root.canonical_path {
            return Err(
                "A project folder now points somewhere else. Edit the project before continuing.",
            );
        }
    }
    Ok(())
}

fn validate_folders(
    paths: &[String],
    denied: &[String],
) -> Result<Vec<ProjectRootInput>, &'static str> {
    if paths.is_empty() || paths.len() > wonder_store::MAX_PROJECT_ROOTS {
        return Err("Choose between one and sixteen folders.");
    }
    let mut roots: Vec<ProjectRootInput> = Vec::with_capacity(paths.len());
    for path in paths {
        let root = validate_folder(path, denied)?;
        // Symlinks and trailing slashes may name one folder twice.
        if !roots
            .iter()
            .any(|r| r.canonical_path == root.canonical_path)
        {
            roots.push(root);
        }
    }
    Ok(roots)
}

// ---------------------------------------------------------------------------
// Library routes
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectsResponse {
    projects: Vec<ProjectSummary>,
    families: Vec<FamilyAvailability>,
    modes_version: u8,
    archive_version: u8,
    pinned: Vec<PinnedThread>,
}

/// A pinned, attached thread and the project it belongs to.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PinnedThread {
    project_id: String,
    thread: ProjectThreadSummary,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FamilyAvailability {
    family: AgentFamily,
    available: bool,
}

pub(crate) async fn list(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
) -> Response {
    let projects = match state.store.list_projects().await {
        Ok(projects) => projects,
        Err(_) => {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "Projects are temporarily unavailable. Try again.",
            )
        }
    };
    let pinned = match state
        .store
        .pinned_project_conversations(MAX_PINNED_THREADS)
        .await
    {
        Ok(rows) => rows,
        Err(_) => {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "Projects are temporarily unavailable. Try again.",
            )
        }
    };
    let mut pinned_threads = Vec::with_capacity(pinned.len());
    let archived = match archived_codex_ids(&state, &pinned).await {
        Ok(ids) => ids,
        Err(message) => return error(StatusCode::SERVICE_UNAVAILABLE, message),
    };
    for conversation in &pinned {
        if conversation.family == AgentFamily::Codex
            && conversation
                .native_session_id
                .as_ref()
                .is_some_and(|id| archived.contains(id))
        {
            continue;
        }
        pinned_threads.push(PinnedThread {
            project_id: conversation.project_id.clone(),
            thread: attached_summary(
                &state,
                conversation,
                activity_seconds(&conversation.last_activity_at),
                None,
            )
            .await,
        });
    }
    let catalog = state.runtime_catalog.read().await;
    let families = [AgentFamily::Codex, AgentFamily::Claude]
        .into_iter()
        .map(|family| FamilyAvailability {
            family,
            available: catalog
                .models
                .iter()
                .any(|m| m.agent_family == family && !m.hidden)
                && (family == AgentFamily::Codex || state.claude.is_some()),
        })
        .collect();
    Json(ProjectsResponse {
        projects: projects.iter().map(project_summary).collect(),
        families,
        modes_version: MODES_VERSION,
        archive_version: 1,
        pinned: pinned_threads,
    })
    .into_response()
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Candidate {
    name: String,
    folders: Vec<String>,
    sources: Vec<AgentFamily>,
    updated_at: Option<i64>,
    is_included: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CandidatesResponse {
    candidates: Vec<Candidate>,
    partial: Vec<PartialFailure>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PartialFailure {
    family: AgentFamily,
    detail: String,
}

/// Bounded suggestions from native provider metadata. Nothing is included,
/// scanned or started until the owner explicitly selects a suggestion.
pub(crate) async fn candidates(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
) -> Response {
    let included: Vec<HashSet<String>> = match state.store.list_projects().await {
        Ok(projects) => projects
            .iter()
            .map(|p| p.roots.iter().map(|r| r.canonical_path.clone()).collect())
            .collect(),
        Err(_) => {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "Projects are temporarily unavailable. Try again.",
            )
        }
    };
    let mut candidates: Vec<Candidate> = Vec::new();
    let mut partial = Vec::new();
    let codex = async {
        let rpc = codex_rpc(&state).await?;
        result(
            &rpc,
            "project/list",
            json!({"limit": 50, "sortKey": "recencyAt", "sortDirection": "desc"}),
        )
        .await
    }
    .await;
    match codex {
        Ok(value) => {
            for project in value
                .get("data")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .take(50)
            {
                let folders = project
                    .get("roots")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|r| r.get("path").and_then(Value::as_str))
                    .map(str::to_owned)
                    .collect::<Vec<_>>();
                let name = project
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .trim()
                    .to_owned();
                if folders.is_empty() || name.is_empty() {
                    continue;
                }
                candidates.push(Candidate {
                    name,
                    folders,
                    sources: vec![AgentFamily::Codex],
                    updated_at: project
                        .get("recencyAt")
                        .and_then(Value::as_i64)
                        .or_else(|| project.get("updatedAt").and_then(Value::as_i64)),
                    is_included: false,
                });
            }
        }
        Err(detail)
            if detail.contains("not allowlisted")
                || detail.to_ascii_lowercase().contains("method") => {}
        Err(_) => partial.push(PartialFailure {
            family: AgentFamily::Codex,
            detail: "Codex projects could not be loaded.".into(),
        }),
    }
    if state.claude.is_some() {
        match async {
            result(
                &claude_rpc(&state).await?,
                "project/folders/list",
                json!({"limit": 50}),
            )
            .await
        }
        .await
        {
            Ok(value) => {
                for folder in value
                    .get("data")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    let Some(cwd) = folder.get("cwd").and_then(Value::as_str) else {
                        continue;
                    };
                    let updated = folder.get("updatedAt").and_then(Value::as_i64);
                    if let Some(existing) = candidates
                        .iter_mut()
                        .find(|c| c.folders.len() == 1 && c.folders[0] == cwd)
                    {
                        existing.sources.push(AgentFamily::Claude);
                        existing.updated_at = existing.updated_at.max(updated);
                    } else {
                        candidates.push(Candidate {
                            name: folder_name(cwd),
                            folders: vec![cwd.to_owned()],
                            sources: vec![AgentFamily::Claude],
                            updated_at: updated,
                            is_included: false,
                        });
                    }
                }
            }
            Err(_) => partial.push(PartialFailure {
                family: AgentFamily::Claude,
                detail: "Claude Code folders could not be loaded.".into(),
            }),
        }
    }
    // Suggest only folders that can actually become a project on this Mac;
    // app-managed scratch folders under ~/Library are not owner projects.
    let library = std::env::var_os("HOME").map(|home| PathBuf::from(home).join("Library"));
    candidates.retain(|c| {
        !c.folders.iter().any(|f| {
            library
                .as_ref()
                .is_some_and(|l| FsPath::new(f).starts_with(l))
        })
    });
    let denied = state.denied_roots.clone();
    let candidates = tokio::task::spawn_blocking(move || {
        let mut kept = Vec::new();
        for mut candidate in candidates {
            let Ok(roots) = validate_folders(&candidate.folders, &denied) else {
                continue;
            };
            let set: HashSet<String> = roots.iter().map(|r| r.canonical_path.clone()).collect();
            candidate.is_included = included.contains(&set);
            kept.push(candidate);
        }
        kept.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| a.name.cmp(&b.name))
        });
        kept.truncate(40);
        kept
    })
    .await
    .unwrap_or_default();
    Json(CandidatesResponse {
        candidates,
        partial,
    })
    .into_response()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CreateProjectRequest {
    request_id: String,
    name: String,
    folders: Vec<String>,
    #[serde(default)]
    primary_index: usize,
}

pub(crate) async fn create(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Json(request): Json<CreateProjectRequest>,
) -> Response {
    if uuid::Uuid::parse_str(&request.request_id).is_err() {
        return error(StatusCode::BAD_REQUEST, "requestId must be a UUID");
    }
    let denied = state.denied_roots.clone();
    let folders = request.folders.clone();
    let roots = match tokio::task::spawn_blocking(move || validate_folders(&folders, &denied)).await
    {
        Ok(Ok(roots)) => roots,
        Ok(Err(message)) => return error(StatusCode::UNPROCESSABLE_ENTITY, message),
        Err(_) => {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "Folders could not be checked. Try again.",
            )
        }
    };
    if request.primary_index >= request.folders.len() {
        return error(StatusCode::UNPROCESSABLE_ENTITY, "Choose a primary folder.");
    }
    // The primary is named by the caller's folder; de-duplication can shift indices.
    let primary_canonical = std::fs::canonicalize(&request.folders[request.primary_index]).ok();
    let primary = roots
        .iter()
        .position(|r| {
            primary_canonical
                .as_deref()
                .is_some_and(|p| p == FsPath::new(&r.canonical_path))
        })
        .unwrap_or(0);
    let payload = hex::encode(Sha256::digest(
        serde_json::to_vec(&json!([
            request.name.trim(),
            roots.iter().map(|r| &r.canonical_path).collect::<Vec<_>>(),
            primary
        ]))
        .unwrap_or_default(),
    ));
    match state
        .store
        .create_project(
            &uuid::Uuid::new_v4().to_string(),
            &request.request_id,
            &payload,
            &request.name,
            &roots,
            primary,
            &now_text(),
        )
        .await
    {
        Ok(ProjectCreate::Created(project)) => {
            (StatusCode::CREATED, Json(project_summary(&project))).into_response()
        }
        Ok(ProjectCreate::Existing(project)) => Json(project_summary(&project)).into_response(),
        Ok(ProjectCreate::Conflict) => error(
            StatusCode::CONFLICT,
            "This request was already used for a different project.",
        ),
        Err(sqlx::Error::Protocol(message)) => error(StatusCode::UNPROCESSABLE_ENTITY, message),
        Err(_) => error(
            StatusCode::SERVICE_UNAVAILABLE,
            "The project could not be saved. Try again.",
        ),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct UpdateProjectRequest {
    name: Option<String>,
    is_included: Option<bool>,
    is_pinned: Option<bool>,
    folders: Option<Vec<String>>,
    primary_index: Option<usize>,
    roots_revision: Option<i64>,
}

pub(crate) async fn update(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(id): Path<String>,
    Json(request): Json<UpdateProjectRequest>,
) -> Response {
    let now = now_text();
    if let Some(folders) = request.folders.clone() {
        let Some(revision) = request.roots_revision else {
            return error(
                StatusCode::BAD_REQUEST,
                "rootsRevision is required when folders change",
            );
        };
        let primary_path = folders.get(request.primary_index.unwrap_or(0)).cloned();
        let denied = state.denied_roots.clone();
        let roots =
            match tokio::task::spawn_blocking(move || validate_folders(&folders, &denied)).await {
                Ok(Ok(roots)) => roots,
                Ok(Err(message)) => return error(StatusCode::UNPROCESSABLE_ENTITY, message),
                Err(_) => {
                    return error(
                        StatusCode::SERVICE_UNAVAILABLE,
                        "Folders could not be checked. Try again.",
                    )
                }
            };
        let primary_canonical = primary_path.and_then(|p| std::fs::canonicalize(p).ok());
        let primary = roots
            .iter()
            .position(|r| {
                primary_canonical
                    .as_deref()
                    .is_some_and(|p| p == FsPath::new(&r.canonical_path))
            })
            .unwrap_or(0);
        match state
            .store
            .update_project_roots(&id, revision, &roots, primary, &now)
            .await
        {
            Ok(Some(_)) => {}
            Ok(None) => return StatusCode::NOT_FOUND.into_response(),
            Err(sqlx::Error::Protocol(message)) if message == "roots_revision_changed" => {
                return error(
                    StatusCode::CONFLICT,
                    "These folders changed on another device. Reload and try again.",
                )
            }
            Err(sqlx::Error::Protocol(message)) => {
                return error(StatusCode::UNPROCESSABLE_ENTITY, message)
            }
            Err(_) => {
                return error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "The folders could not be saved. Try again.",
                )
            }
        }
    }
    match state
        .store
        .update_project_metadata(
            &id,
            request.name.as_deref(),
            request.is_included,
            request.is_pinned,
            &now,
        )
        .await
    {
        Ok(Some(project)) => Json(project_summary(&project)).into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(sqlx::Error::Protocol(message)) => error(StatusCode::UNPROCESSABLE_ENTITY, message),
        Err(_) => error(
            StatusCode::SERVICE_UNAVAILABLE,
            "The project could not be saved. Try again.",
        ),
    }
}

// ---------------------------------------------------------------------------
// Thread catalog
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
struct NativeThread {
    family: AgentFamily,
    id: String,
    title: String,
    updated_at: i64,
}

#[derive(Clone, Debug, Default)]
struct ProviderPage {
    cursor: Option<String>,
    offset: usize,
    done: bool,
    buffer: VecDeque<NativeThread>,
    failed: bool,
}

#[derive(Clone, Debug)]
struct CatalogCursor {
    project_id: String,
    roots_revision: i64,
    codex: ProviderPage,
    claude: ProviderPage,
    emitted: HashSet<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ThreadsQuery {
    cursor: Option<String>,
    limit: Option<usize>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadsPage {
    threads: Vec<ProjectThreadSummary>,
    next_cursor: Option<String>,
    partial: Vec<PartialFailure>,
}

fn thread_title(value: &Value) -> String {
    let raw = value
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| !name.trim().is_empty())
        .or_else(|| value.get("preview").and_then(Value::as_str))
        .unwrap_or("Untitled thread");
    let line = raw
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("Untitled thread");
    line.trim().chars().take(120).collect()
}

fn root_paths(project: &StoredProject) -> Vec<String> {
    let mut paths = Vec::new();
    for root in &project.roots {
        for path in [&root.path, &root.canonical_path] {
            if !paths.contains(path) {
                paths.push(path.clone());
            }
        }
    }
    paths
}

async fn fill_codex(
    state: &AppState,
    project: &StoredProject,
    page: &mut ProviderPage,
    limit: usize,
) {
    if page.done || page.failed || page.buffer.len() >= limit {
        return;
    }
    let fetched = async {
        let rpc = codex_rpc(state).await?;
        result(&rpc, "thread/list", json!({
            "cwd": root_paths(project), "sourceKinds": CODEX_SOURCE_KINDS, "archived": false,
            "limit": limit.max(10), "sortKey": "updated_at", "sortDirection": "desc", "cursor": page.cursor,
        }))
        .await
    }
    .await;
    match fetched {
        Ok(value) => {
            for thread in value
                .get("data")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let Some(id) = thread.get("id").and_then(Value::as_str) else {
                    continue;
                };
                // Helper threads remain under their parent.
                if thread
                    .get("parentThreadId")
                    .and_then(Value::as_str)
                    .is_some()
                {
                    continue;
                }
                page.buffer.push_back(NativeThread {
                    family: AgentFamily::Codex,
                    id: id.to_owned(),
                    title: thread_title(thread),
                    updated_at: thread
                        .get("updatedAt")
                        .and_then(Value::as_i64)
                        .unwrap_or_default(),
                });
            }
            page.cursor = value
                .get("nextCursor")
                .and_then(Value::as_str)
                .map(str::to_owned);
            page.done = page.cursor.is_none();
        }
        Err(_) => page.failed = true,
    }
}

async fn fill_claude(
    state: &AppState,
    project: &StoredProject,
    page: &mut ProviderPage,
    limit: usize,
) {
    if page.done || page.failed || page.buffer.len() >= limit {
        return;
    }
    if state.claude.is_none() {
        page.done = true;
        return;
    }
    let fetched = async {
        let excluded = state.store.bot_claude_sessions().await.map_err(|e| e.to_string())?;
        result(&claude_rpc(state).await?, "project/sessions/list", json!({
            "dirs": root_paths(project), "limit": limit.max(10), "offset": page.offset, "excludeSessionIds": excluded,
        }))
        .await
    }
    .await;
    match fetched {
        Ok(value) => {
            let data = value
                .get("data")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            page.offset += data.len();
            for session in &data {
                let Some(id) = session.get("sessionId").and_then(Value::as_str) else {
                    continue;
                };
                page.buffer.push_back(NativeThread {
                    family: AgentFamily::Claude,
                    id: id.to_owned(),
                    title: session
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or("Claude session")
                        .chars()
                        .take(120)
                        .collect(),
                    updated_at: session
                        .get("updatedAt")
                        .and_then(Value::as_i64)
                        .unwrap_or_default(),
                });
            }
            page.done = value.get("hasMore").and_then(Value::as_bool) != Some(true);
        }
        Err(_) => page.failed = true,
    }
}

fn reference(family: AgentFamily, id: &str) -> String {
    format!("{}:{id}", family.as_str())
}

async fn attached_summary(
    state: &AppState,
    conversation: &StoredProjectConversation,
    updated_at: i64,
    title: Option<String>,
) -> ProjectThreadSummary {
    ProjectThreadSummary {
        // A draft has no provider session yet; it opens by conversation ID.
        reference: match conversation.native_session_id.as_deref() {
            Some(native) => reference(conversation.family, native),
            None => format!("wonder:{}", conversation.conversation_id),
        },
        conversation_id: Some(conversation.conversation_id.clone()),
        title: title.unwrap_or_else(|| conversation.title.clone()),
        family: conversation.family,
        updated_at,
        is_pinned: conversation.is_pinned,
        has_unread: conversation.has_unread,
        is_working: state
            .store
            .conversation_has_active_turn(&conversation.conversation_id)
            .await
            .unwrap_or(false),
    }
}

fn activity_seconds(value: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(value)
        .map(|t| t.timestamp())
        .unwrap_or_default()
}

/// Merged native Codex/Claude threads. Each provider keeps its own cursor and
/// buffer, so the combined page is globally ordered by recent activity.
pub(crate) async fn threads(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(id): Path<String>,
    Query(query): Query<ThreadsQuery>,
) -> Response {
    let limit = query.limit.unwrap_or(5).clamp(1, 30);
    let Ok(Some(project)) = state.store.project(&id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let (mut cursor, first) = match query.cursor.as_deref() {
        Some(token) => {
            let cursors = state
                .projects
                .cursors
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            // Cursors are immutable snapshots, so retrying a page after a
            // dropped response returns the same page instead of skipping it.
            match cursors.get(token).cloned() {
                Some((created, cursor))
                    if created.elapsed() < CURSOR_TTL
                        && cursor.project_id == project.id
                        && cursor.roots_revision == project.roots_revision =>
                {
                    (cursor, false)
                }
                _ => {
                    return error(
                        StatusCode::GONE,
                        "This list changed. Refresh to see the latest threads.",
                    )
                }
            }
        }
        None => (
            CatalogCursor {
                project_id: project.id.clone(),
                roots_revision: project.roots_revision,
                codex: ProviderPage::default(),
                claude: ProviderPage::default(),
                emitted: HashSet::new(),
            },
            true,
        ),
    };
    let mut threads = Vec::new();
    if first {
        // Pinned threads lead the first page; Wonder drafts without a native
        // session yet remain visible until the provider reports them.
        let attached = state
            .store
            .project_conversations(&project.id)
            .await
            .unwrap_or_default();
        let archived = match archived_codex_ids(&state, &attached).await {
            Ok(ids) => ids,
            Err(_) => {
                cursor.codex.failed = true;
                HashSet::new()
            }
        };
        for conversation in attached
            .iter()
            .filter(|c| c.is_pinned || c.native_session_id.is_none())
        {
            if conversation.family == AgentFamily::Codex
                && conversation
                    .native_session_id
                    .as_ref()
                    .is_some_and(|id| archived.contains(id))
            {
                continue;
            }
            if let Some(native) = &conversation.native_session_id {
                cursor
                    .emitted
                    .insert(reference(conversation.family, native));
            }
            threads.push(
                attached_summary(
                    &state,
                    conversation,
                    activity_seconds(&conversation.last_activity_at),
                    None,
                )
                .await,
            );
        }
    }
    let mut native_rows = 0;
    while native_rows < limit {
        fill_codex(&state, &project, &mut cursor.codex, limit).await;
        fill_claude(&state, &project, &mut cursor.claude, limit).await;
        let next = match (cursor.codex.buffer.front(), cursor.claude.buffer.front()) {
            (Some(a), Some(b)) if b.updated_at > a.updated_at => cursor.claude.buffer.pop_front(),
            (Some(_), _) => cursor.codex.buffer.pop_front(),
            (None, Some(_)) => cursor.claude.buffer.pop_front(),
            (None, None) => break,
        };
        let Some(native) = next else { break };
        let key = reference(native.family, &native.id);
        if !cursor.emitted.insert(key.clone()) {
            continue;
        }
        let store = provider_store(&state, native.family).to_owned();
        let summary = match state
            .store
            .project_conversation_by_native(native.family, &store, &native.id)
            .await
        {
            Ok(Some(conversation)) => {
                attached_summary(
                    &state,
                    &conversation,
                    native.updated_at,
                    Some(native.title.clone()),
                )
                .await
            }
            _ => ProjectThreadSummary {
                reference: key,
                conversation_id: None,
                title: native.title,
                family: native.family,
                updated_at: native.updated_at,
                is_pinned: false,
                has_unread: false,
                is_working: false,
            },
        };
        threads.push(summary);
        native_rows += 1;
    }
    let mut partial = Vec::new();
    if cursor.codex.failed {
        partial.push(PartialFailure {
            family: AgentFamily::Codex,
            detail: "Codex threads could not be loaded.".into(),
        });
    }
    if cursor.claude.failed {
        partial.push(PartialFailure {
            family: AgentFamily::Claude,
            detail: "Claude Code threads could not be loaded.".into(),
        });
    }
    let more = |page: &ProviderPage| !page.buffer.is_empty() || (!page.done && !page.failed);
    let next_cursor = if more(&cursor.codex) || more(&cursor.claude) {
        let token = uuid::Uuid::new_v4().to_string();
        let mut cursors = state
            .projects
            .cursors
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        cursors.retain(|_, (created, _)| created.elapsed() < CURSOR_TTL);
        while cursors.len() >= MAX_CURSORS {
            let Some(oldest) = cursors
                .iter()
                .min_by_key(|(_, (created, _))| *created)
                .map(|(k, _)| k.clone())
            else {
                break;
            };
            cursors.remove(&oldest);
        }
        cursors.insert(token.clone(), (Instant::now(), cursor));
        Some(token)
    } else {
        None
    };
    Json(ThreadsPage {
        threads,
        next_cursor,
        partial,
    })
    .into_response()
}

// ---------------------------------------------------------------------------
// Attaching an existing native thread
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AttachRequest {
    reference: String,
}

fn default_model(catalog: &crate::RuntimeCatalog, family: AgentFamily) -> Option<String> {
    catalog
        .models
        .iter()
        .find(|m| m.agent_family == family && !m.hidden && m.id != "claude:haiku")
        .or_else(|| {
            catalog
                .models
                .iter()
                .find(|m| m.agent_family == family && !m.hidden)
        })
        .map(|m| m.id.clone())
}

pub(crate) async fn attach(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(id): Path<String>,
    Json(request): Json<AttachRequest>,
) -> Response {
    let Ok(Some(project)) = state.store.project(&id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some((family, native)) = request
        .reference
        .split_once(':')
        .and_then(|(family, native)| {
            let family = match family {
                "codex" => AgentFamily::Codex,
                "claude" => AgentFamily::Claude,
                _ => return None,
            };
            (!native.is_empty()
                && native.len() <= 128
                && native.chars().all(|c| c.is_ascii_hexdigit() || c == '-'))
            .then(|| (family, native.to_owned()))
        })
    else {
        return error(StatusCode::BAD_REQUEST, "Invalid thread reference.");
    };
    match attach_native(&state, &project, family, &native).await {
        Ok(conversation) => {
            if family == AgentFamily::Codex {
                if let Err(message) = associate_codex_project(&state, &project, &native).await {
                    return error(StatusCode::SERVICE_UNAVAILABLE, message);
                }
            }
            let summary = attached_summary(
                &state,
                &conversation,
                activity_seconds(&conversation.last_activity_at),
                None,
            )
            .await;
            // Load native history for the timeline; this starts no model work.
            let _ = crate::refresh_history(
                State(state.clone()),
                Path(conversation.conversation_id.clone()),
            )
            .await;
            Json(summary).into_response()
        }
        Err((status, message)) => error(status, message),
    }
}

async fn attach_native(
    state: &AppState,
    project: &StoredProject,
    family: AgentFamily,
    native: &str,
) -> Result<StoredProjectConversation, (StatusCode, String)> {
    let store = provider_store(state, family).to_owned();
    if let Ok(Some(existing)) = state
        .store
        .project_conversation_by_native(family, &store, native)
        .await
    {
        // Overlapping folder groups share one conversation; a caller-supplied
        // ID alone never opens a thread outside this project's folders.
        return if project.root_for(&existing.cwd).is_some() {
            Ok(existing)
        } else {
            Err((
                StatusCode::FORBIDDEN,
                "This thread is outside the project's folders.".into(),
            ))
        };
    }
    let unavailable = |_| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            "This thread could not be opened. Try again.".to_owned(),
        )
    };
    let (cwd, title, thread_id, session) = match family {
        AgentFamily::Codex => {
            let rpc = codex_rpc(state)
                .await
                .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e))?;
            let thread = result(&rpc, "thread/read", json!({"threadId": native}))
                .await
                .map_err(|_| {
                    (
                        StatusCode::NOT_FOUND,
                        "This Codex thread is no longer available on your Mac.".to_owned(),
                    )
                })?;
            let thread = thread.get("thread").cloned().unwrap_or_default();
            let cwd = thread
                .get("cwd")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            if thread
                .get("parentThreadId")
                .and_then(Value::as_str)
                .is_some()
            {
                return Err((
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "Open this helper thread from its parent.".into(),
                ));
            }
            (cwd, thread_title(&thread), native.to_owned(), None)
        }
        AgentFamily::Claude => {
            if state
                .store
                .bot_claude_sessions()
                .await
                .map_err(unavailable)?
                .iter()
                .any(|s| s == native)
            {
                return Err((
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "This session belongs to a Bot.".into(),
                ));
            }
            let listed = result(
                &claude_rpc(state)
                    .await
                    .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e))?,
                "project/sessions/list",
                json!({"dirs": root_paths(project), "limit": 100}),
            )
            .await
            .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e))?;
            let Some(session) = listed
                .get("data")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .find(|s| s.get("sessionId").and_then(Value::as_str) == Some(native))
                .cloned()
            else {
                return Err((
                    StatusCode::NOT_FOUND,
                    "This Claude Code session is no longer in this project.".into(),
                ));
            };
            let cwd = session
                .get("cwd")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let model = default_model(&*state.runtime_catalog.read().await, AgentFamily::Claude)
                .ok_or((
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Claude is not available on your Mac.".to_owned(),
                ))?;
            let root = project.root_for(&cwd).ok_or((
                StatusCode::FORBIDDEN,
                "This session is outside the project's folders.".to_owned(),
            ))?;
            let attached = result(
                &claude_rpc(state)
                    .await
                    .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e))?,
                "project/session/attach",
                json!({"sessionId": native, "model": model, "cwd": root.path,
                    "wonderProject": claude_project(project, &root.path),
                    "wonderPolicy": claude_policy(state, project, ClaudeModes::default(), &root.path)}),
            )
            .await
            .map_err(|e| (StatusCode::NOT_FOUND, e))?;
            let thread = attached
                .pointer("/thread/id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let title = session
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or("Claude session")
                .chars()
                .take(120)
                .collect();
            (root.path.clone(), title, thread, Some(native.to_owned()))
        }
    };
    // Exact folder membership; a sibling with a shared prefix is not a match.
    let Some(root) = project.root_for(&cwd) else {
        return Err((
            StatusCode::FORBIDDEN,
            "This thread is outside the project's folders.".into(),
        ));
    };
    let conversation_id = uuid::Uuid::new_v4().to_string();
    let now = now_text();
    let created = state
        .store
        .create_project_conversation(ProjectConversationInsert {
            conversation_id: &conversation_id,
            project_id: &project.id,
            family,
            provider_store: &store,
            native_session_id: Some(native),
            cwd: &root.path,
            roots_revision: project.roots_revision,
            title: &title,
            model: None,
            effort: None,
            service_tier: None,
            access_mode: "workspace",
            claude_approval: "ask",
            plan_mode: false,
            creation_request_id: None,
            now: &now,
        })
        .await
        .map_err(unavailable)?;
    let conversation = match created {
        ProjectConversationCreate::Created(c) | ProjectConversationCreate::Existing(c) => c,
    };
    if conversation.conversation_id == conversation_id {
        state
            .store
            .bind_project_runtime(
                &conversation_id,
                family,
                &store,
                &thread_id,
                session.as_deref(),
                &now,
            )
            .await
            .map_err(unavailable)?;
    }
    Ok(conversation)
}

// ---------------------------------------------------------------------------
// Conversation metadata
// ---------------------------------------------------------------------------

pub(crate) async fn conversation(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(id): Path<String>,
) -> Response {
    let Ok(Some(conversation)) = state.store.project_conversation(&id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match conversation_detail(&state, &conversation).await {
        Ok(detail) => Json(detail).into_response(),
        Err(message) => error(StatusCode::SERVICE_UNAVAILABLE, message),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct UpdateConversationRequest {
    title: Option<String>,
    is_pinned: Option<bool>,
    is_archived: Option<bool>,
    has_unread: Option<bool>,
    model: Option<String>,
    #[serde(default, deserialize_with = "patch_effort")]
    effort: Option<Option<String>>,
    #[serde(default, deserialize_with = "patch_effort")]
    service_tier: Option<Option<String>>,
    access_mode: Option<String>,
    claude_approval: Option<String>,
    plan_mode: Option<bool>,
}

// Serde's ordinary nested Option treats both null and an omitted field as None.
// A present field must retain its null so PATCH can clear an old model's effort.
fn patch_effort<'de, D>(deserializer: D) -> Result<Option<Option<String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer).map(Some)
}

/// Approval modes exist only for Claude threads, and only with known values.
fn validate_claude_approval(
    family: AgentFamily,
    approval: Option<&str>,
) -> Result<(), &'static str> {
    match approval {
        None => Ok(()),
        Some(_) if family != AgentFamily::Claude => {
            Err("Approval modes are available for Claude threads.")
        }
        Some(approval) if !CLAUDE_APPROVALS.contains(&approval) => {
            Err("Choose Ask, Accept edits or Auto.")
        }
        Some(_) => Ok(()),
    }
}

fn validate_model(
    catalog: &crate::RuntimeCatalog,
    family: AgentFamily,
    model: Option<&str>,
    effort: Option<&str>,
    service_tier: Option<&str>,
) -> Result<(), &'static str> {
    let Some(model) = model else {
        return if effort.is_some() || service_tier.is_some() {
            Err("Choose a model before changing its settings.")
        } else {
            Ok(())
        };
    };
    let option = catalog
        .models
        .iter()
        .find(|m| m.id == model && m.agent_family == family && !m.hidden)
        .ok_or("This model is not available for this conversation.")?;
    if let Some(effort) = effort {
        if !option.reasoning_efforts.iter().any(|e| e.id == effort) {
            return Err("This model does not support that effort.");
        }
    }
    if let Some(tier) = service_tier {
        if !option.service_tiers.iter().any(|choice| choice.id == tier)
            && option.default_service_tier.as_deref() != Some(tier)
        {
            return Err("This model does not support that speed.");
        }
    }
    Ok(())
}

fn supports_tier(
    catalog: &crate::RuntimeCatalog,
    family: AgentFamily,
    model: &str,
    tier: &str,
) -> bool {
    catalog
        .models
        .iter()
        .find(|option| option.agent_family == family && option.id == model)
        .is_some_and(|option| {
            option.service_tiers.iter().any(|choice| choice.id == tier)
                || option.default_service_tier.as_deref() == Some(tier)
        })
}

pub(crate) async fn update_conversation(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(id): Path<String>,
    Json(request): Json<UpdateConversationRequest>,
) -> Response {
    let Ok(Some(existing)) = state.store.project_conversation(&id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if let Some(archived) = request.is_archived {
        if request.title.is_some()
            || request.is_pinned.is_some()
            || request.has_unread.is_some()
            || request.model.is_some()
            || request.effort.is_some()
            || request.service_tier.is_some()
            || request.access_mode.is_some()
            || request.claude_approval.is_some()
            || request.plan_mode.is_some()
        {
            return error(
                StatusCode::UNPROCESSABLE_ENTITY,
                "Save the archive change separately from other thread settings.",
            );
        }
        if let Err((status, message)) = set_archived(&state, &existing, archived).await {
            return error(status, message);
        }
        return match conversation_detail(&state, &existing).await {
            Ok(detail) if detail.is_archived == archived => Json(detail).into_response(),
            _ => error(
                StatusCode::SERVICE_UNAVAILABLE,
                "The archive change could not be confirmed. Refresh before trying again.",
            ),
        };
    }
    let catalog = state.runtime_catalog.read().await;
    let model = request.model.as_deref().or(existing.model.as_deref());
    let service_tier = request
        .service_tier
        .as_ref()
        .map_or(existing.service_tier.as_deref(), |tier| tier.as_deref());
    let clear_incompatible_tier = request.model.is_some()
        && request.service_tier.is_none()
        && service_tier.is_some_and(|tier| {
            !supports_tier(&catalog, existing.family, model.unwrap_or_default(), tier)
        });
    if request.model.is_some() || request.effort.is_some() || request.service_tier.is_some() {
        if let Err(message) = validate_model(
            &catalog,
            existing.family,
            model,
            request
                .effort
                .as_ref()
                .map_or(existing.effort.as_deref(), |effort| effort.as_deref()),
            if clear_incompatible_tier {
                None
            } else {
                service_tier
            },
        ) {
            return error(StatusCode::UNPROCESSABLE_ENTITY, message);
        }
    }
    drop(catalog);
    if request
        .access_mode
        .as_deref()
        .is_some_and(|mode| !ACCESS_MODES.contains(&mode))
    {
        return error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Choose Read only, Workspace or Full access.",
        );
    }
    if let Err(message) =
        validate_claude_approval(existing.family, request.claude_approval.as_deref())
    {
        return error(StatusCode::UNPROCESSABLE_ENTITY, message);
    }
    let patch = ProjectConversationPatch {
        title: request.title.as_deref(),
        pinned: request.is_pinned,
        unread: request.has_unread,
        model: request.model.as_deref(),
        effort: request.effort.as_ref().map(|effort| effort.as_deref()),
        service_tier: if clear_incompatible_tier {
            Some(None)
        } else {
            request.service_tier.as_ref().map(|tier| tier.as_deref())
        },
        access_mode: request.access_mode.as_deref(),
        claude_approval: request.claude_approval.as_deref(),
        plan_mode: request.plan_mode,
    };
    let now = now_text();
    let updated =
        if request.model.is_some() || request.effort.is_some() || request.service_tier.is_some() {
            state
                .store
                .update_project_conversation_if_settings_match(
                    &id,
                    patch,
                    existing.model.as_deref(),
                    existing.effort.as_deref(),
                    existing.service_tier.as_deref(),
                    &now,
                )
                .await
        } else {
            state
                .store
                .update_project_conversation(&id, patch, &now)
                .await
        };
    match updated {
        Ok(Some(conversation)) => match conversation_detail(&state, &conversation).await {
            Ok(detail) => Json(detail).into_response(),
            Err(message) => error(StatusCode::SERVICE_UNAVAILABLE, message),
        },
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(sqlx::Error::Protocol(message)) if message == "project_settings_changed" => error(
            StatusCode::CONFLICT,
            "The thread settings changed on another device. Refresh and try again.",
        ),
        Err(sqlx::Error::Protocol(message)) => error(StatusCode::UNPROCESSABLE_ENTITY, message),
        Err(_) => error(
            StatusCode::SERVICE_UNAVAILABLE,
            "The conversation could not be saved. Try again.",
        ),
    }
}

// ---------------------------------------------------------------------------
// New thread: the first message is the only thing that starts provider work
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CreateThreadRequest {
    device_id: String,
    client_message_id: String,
    family: AgentFamily,
    model: String,
    effort: Option<String>,
    service_tier: Option<String>,
    #[serde(default = "default_access")]
    access_mode: String,
    /// Claude threads only; part of the frozen creation request.
    claude_approval: Option<String>,
    #[serde(default)]
    plan_mode: bool,
    folder_id: Option<String>,
    roots_revision: Option<i64>,
    body: String,
    /// Reserve Wonder metadata for authenticated attachment uploads. This does
    /// not start a provider session or enqueue a message.
    #[serde(default)]
    prepare_only: bool,
    #[serde(default)]
    attachment_ids: Vec<String>,
}

fn default_access() -> String {
    "workspace".into()
}

// Frozen request identity excludes the draft body and staged attachments:
// prepareOnly reserves a chat before either exists. The accepted message row
// compares both when replaying a submitted first message.
fn creation_request_digest(project_id: &str, request: &CreateThreadRequest) -> String {
    let intent = json!({
        "projectId": project_id,
        "deviceId": request.device_id,
        "clientMessageId": request.client_message_id,
        "family": request.family,
        "model": request.model,
        "effort": request.effort,
        "serviceTier": request.service_tier,
        "accessMode": request.access_mode,
        "claudeApproval": request.claude_approval.as_deref().unwrap_or("ask"),
        "planMode": request.plan_mode,
        "folderId": request.folder_id,
        "rootsRevision": request.roots_revision,
    });
    hex::encode(Sha256::digest(
        serde_json::to_vec(&intent).unwrap_or_default(),
    ))
}

fn legacy_creation_matches(
    payload: &Value,
    project_id: &str,
    request: &CreateThreadRequest,
    conversation: &StoredProjectConversation,
) -> bool {
    let Some(fields) = payload.as_array() else {
        return false;
    };
    fields.len()
        == if request.service_tier.is_some() {
            11
        } else {
            10
        }
        && fields[0] == json!(project_id)
        && fields[1] == json!(request.family.as_str())
        && fields[3] == json!(conversation.cwd)
        && fields[4] == json!(conversation.roots_revision)
        && fields[5] == json!(request.model)
        && fields[6] == json!(request.effort)
        && fields[7] == json!(request.access_mode)
        && fields[8] == json!(request.claude_approval.as_deref().unwrap_or("ask"))
        && fields[9] == json!(i64::from(request.plan_mode))
        && request
            .roots_revision
            .is_none_or(|value| value == conversation.roots_revision)
        && request
            .service_tier
            .as_ref()
            .is_none_or(|tier| fields[10] == json!(tier))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CreateThreadResponse {
    conversation: ProjectThreadSummary,
    receipt: Option<wonder_api::ClientMessageReceipt>,
}

pub(crate) async fn create_thread(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<CreateThreadRequest>,
) -> Response {
    if let Some(Extension(device)) = authenticated_device {
        if device.device_id != request.device_id {
            return error(StatusCode::FORBIDDEN, "device identity mismatch");
        }
    }
    if uuid::Uuid::parse_str(&request.client_message_id).is_err() {
        return error(StatusCode::BAD_REQUEST, "clientMessageId must be a UUID");
    }
    if (!request.prepare_only
        && request.body.trim().is_empty()
        && request.attachment_ids.is_empty())
        || request.body.len() > 64 * 1024
    {
        return error(
            StatusCode::PAYLOAD_TOO_LARGE,
            "message body must be between 1 and 65536 bytes",
        );
    }
    if !crate::valid_attachment_ids(&request.attachment_ids) {
        return error(StatusCode::BAD_REQUEST, "invalid attachmentIds");
    }
    if !ACCESS_MODES.contains(&request.access_mode.as_str()) {
        return error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Choose Read only, Workspace or Full access.",
        );
    }
    if let Err(message) =
        validate_claude_approval(request.family, request.claude_approval.as_deref())
    {
        return error(StatusCode::UNPROCESSABLE_ENTITY, message);
    }
    let request_digest = creation_request_digest(&id, &request);
    let body_sha256 = hex::encode(Sha256::digest(request.body.as_bytes()));
    let existing_creation = match state
        .store
        .project_creation_by_request(&request.client_message_id)
        .await
    {
        Ok(value) => value,
        Err(_) => {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "The thread could not be checked. Try again.",
            )
        }
    };
    let existing_conversation = if let Some((conversation, payload)) = existing_creation {
        if conversation.project_id != id {
            return error(
                StatusCode::CONFLICT,
                "This request belongs to another Project.",
            );
        }
        let matches = if payload["version"] == 2 {
            payload["requestDigest"].as_str() == Some(request_digest.as_str())
        } else {
            let legacy = legacy_creation_matches(&payload, &id, &request, &conversation);
            if legacy {
                // Old records stored only the resolved folder path. When an
                // explicit folder ID is gone, its original identity cannot
                // be proven; do not silently treat a changed ID as exact.
                if let Some(folder_id) = request.folder_id.as_deref() {
                    let project = match state.store.project(&id).await {
                        Ok(Some(project)) => project,
                        _ => return error(StatusCode::CONFLICT, "The original Project folder could not be verified for this older request."),
                    };
                    project
                        .roots
                        .iter()
                        .any(|root| root.id == folder_id && root.path == conversation.cwd)
                } else {
                    true
                }
            } else {
                false
            }
        };
        if !matches {
            return error(
                StatusCode::CONFLICT,
                "This thread was already created with different settings or a different folder.",
            );
        }
        let now = now_text();
        if request.prepare_only {
            return Json(CreateThreadResponse {
                conversation: attached_summary(&state, &conversation, activity_seconds(&now), None)
                    .await,
                receipt: None,
            })
            .into_response();
        }
        let prior = match state
            .store
            .message_by_device_and_client_message_id(&request.device_id, &request.client_message_id)
            .await
        {
            Ok(value) => value,
            Err(_) => {
                return error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "The message could not be checked. Try again.",
                )
            }
        };
        if let Some(message) = prior {
            let saved_ids = match state.store.attachment_ids_for_message(&message.id).await {
                Ok(value) => value,
                Err(_) => {
                    return error(
                        StatusCode::SERVICE_UNAVAILABLE,
                        "The message attachments could not be checked. Try again.",
                    )
                }
            };
            let mut requested_ids = request.attachment_ids.clone();
            requested_ids.sort();
            if message.conversation_id != conversation.conversation_id
                || message.body_sha256 != body_sha256
                || saved_ids != requested_ids
            {
                return error(
                    StatusCode::CONFLICT,
                    "This message was already sent differently.",
                );
            }
            let Some(receipt) = crate::message_receipt(message) else {
                return error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Stored message has an unknown delivery state.",
                );
            };
            return (
                StatusCode::ACCEPTED,
                Json(CreateThreadResponse {
                    conversation: attached_summary(
                        &state,
                        &conversation,
                        activity_seconds(&now),
                        None,
                    )
                    .await,
                    receipt: Some(receipt),
                }),
            )
                .into_response();
        }
        Some(conversation)
    } else {
        None
    };
    // The update lease fences first acceptance and fresh metadata creation.
    // A stored receipt (or metadata-only reservation replay) above is a read,
    // so it remains recoverable while the host prepares an update.
    let Some(_admission) = state.update_admission.claim_guard().await else {
        return error(
            StatusCode::CONFLICT,
            "Wonder is preparing to update. Try again shortly.",
        );
    };
    if request.family == AgentFamily::Claude && state.claude.is_none() {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "Claude is not installed. Update Wonder on your Mac.",
        );
    }
    let readiness = state.ingestion.project_readiness(&state.store).await;
    if !readiness.ready {
        return error(StatusCode::SERVICE_UNAVAILABLE, readiness.detail);
    }
    let Ok(Some(project)) = state.store.project(&id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if !project.is_included {
        return error(
            StatusCode::CONFLICT,
            "This Project is not included in Wonder. Restore it before starting work.",
        );
    }
    if request
        .roots_revision
        .is_some_and(|revision| revision != project.roots_revision)
    {
        return error(
            StatusCode::PRECONDITION_FAILED,
            "The project's folders changed. Review them before sending.",
        );
    }
    let root = match request.folder_id.as_deref() {
        Some(folder) => project.roots.iter().find(|r| r.id == folder),
        None => Some(project.primary_root()),
    };
    let Some(root) = root.cloned() else {
        return error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Choose one of this project's folders.",
        );
    };
    let checked_project = project.clone();
    let denied = state.denied_roots.clone();
    let folders_valid =
        tokio::task::spawn_blocking(move || validate_execution_roots(&checked_project, &denied))
            .await;
    match folders_valid {
        Ok(Ok(())) => {}
        Ok(Err(detail)) => return error(StatusCode::CONFLICT, detail),
        Err(_) => {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "Project folders could not be checked. Try again.",
            )
        }
    }
    if let Some(existing) = &existing_conversation {
        if existing.cwd != root.path || existing.roots_revision != project.roots_revision {
            return error(
                StatusCode::PRECONDITION_FAILED,
                "The original Project folder changed. Review it before sending.",
            );
        }
    }
    let now = now_text();
    let title: String = request
        .body
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("New thread")
        .trim()
        .chars()
        .take(80)
        .collect();
    let conversation_id = uuid::Uuid::new_v4().to_string();
    let insert = ProjectConversationInsert {
        conversation_id: &conversation_id,
        project_id: &project.id,
        family: request.family,
        provider_store: provider_store(&state, request.family),
        native_session_id: None,
        cwd: &root.path,
        roots_revision: project.roots_revision,
        title: &title,
        model: Some(&request.model),
        effort: request.effort.as_deref(),
        service_tier: request.service_tier.as_deref(),
        access_mode: &request.access_mode,
        claude_approval: request.claude_approval.as_deref().unwrap_or("ask"),
        plan_mode: request.plan_mode,
        creation_request_id: Some(&request.client_message_id),
        now: &now,
    };
    if existing_conversation.is_none() {
        if let Err(message) = validate_model(
            &*state.runtime_catalog.read().await,
            request.family,
            Some(&request.model),
            request.effort.as_deref(),
            request.service_tier.as_deref(),
        ) {
            return error(StatusCode::UNPROCESSABLE_ENTITY, message);
        }
    }
    let created = match existing_conversation {
        Some(conversation) => Ok(ProjectConversationCreate::Existing(conversation)),
        None => {
            state
                .store
                .create_project_conversation_with_request_digest(insert, &request_digest)
                .await
        }
    };
    let conversation = match created {
        Ok(ProjectConversationCreate::Created(c) | ProjectConversationCreate::Existing(c)) => c,
        Err(sqlx::Error::Protocol(message)) => return error(StatusCode::CONFLICT, message),
        Err(_) => {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "The thread could not be saved. Try again.",
            )
        }
    };
    if request.prepare_only {
        return Json(CreateThreadResponse {
            conversation: attached_summary(&state, &conversation, activity_seconds(&now), None)
                .await,
            receipt: None,
        })
        .into_response();
    }
    if let Err((status, detail)) = crate::artifact_annotations::validate_first_acceptance(
        &state,
        &conversation.conversation_id,
        &request.device_id,
        &request.client_message_id,
        &request.attachment_ids,
    )
    .await
    {
        return error(status, detail);
    }
    let stored = match state
        .store
        .insert_dispatch_message_with_model_selection(
            &request.device_id,
            &request.client_message_id,
            &request.body,
            &body_sha256,
            &conversation.conversation_id,
            &request.attachment_ids,
            &now,
            true,
            None,
        )
        .await
    {
        Ok(MessageInsert::Inserted(m) | MessageInsert::Existing(m)) => m,
        Ok(MessageInsert::Conflict) => {
            return error(
                StatusCode::CONFLICT,
                "This message was already sent differently.",
            )
        }
        Err(sqlx::Error::Protocol(message)) if message == "annotation_already_sent" => {
            return error(
                StatusCode::CONFLICT,
                "This annotation was already sent. Add a new annotation to send another note.",
            )
        }
        Err(_) => {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "Message saved state is unknown. Retry to finish sending.",
            )
        }
    };
    let _ = state
        .store
        .touch_project(&project.id, request.family, &now)
        .await;
    let Some(receipt) = crate::message_receipt(stored) else {
        return error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "stored message has an unknown delivery state",
        );
    };
    let conversation = attached_summary(&state, &conversation, activity_seconds(&now), None).await;
    (
        StatusCode::ACCEPTED,
        Json(CreateThreadResponse {
            conversation,
            receipt: Some(receipt),
        }),
    )
        .into_response()
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

/// Codex sandbox/approval for a Wonder turn. Always explicit: a resumed thread
/// otherwise inherits whatever the last desktop client used (P0 finding).
fn codex_policy(mode: &str, roots: &[String]) -> (&'static str, &'static str, Value) {
    match mode {
        "read_only" => (
            "read-only",
            "on-request",
            json!({"type": "readOnly", "networkAccess": false}),
        ),
        "full_access" => (
            "danger-full-access",
            "never",
            json!({"type": "dangerFullAccess"}),
        ),
        _ => (
            "workspace-write",
            "on-request",
            json!({"type": "workspaceWrite", "writableRoots": roots, "networkAccess": false}),
        ),
    }
}

fn claude_project(project: &StoredProject, cwd: &str) -> Value {
    json!({"cwd": cwd, "additionalDirectories": project.roots.iter().map(|r| r.path.clone()).filter(|p| p != cwd).collect::<Vec<_>>()})
}

/// A Claude thread's stored access, approval and plan settings.
#[derive(Clone, Copy, Debug)]
struct ClaudeModes<'a> {
    access_mode: &'a str,
    approval: &'a str,
    plan: bool,
}

impl Default for ClaudeModes<'_> {
    fn default() -> Self {
        Self {
            access_mode: "workspace",
            approval: "ask",
            plan: false,
        }
    }
}

impl<'a> From<&'a StoredProjectConversation> for ClaudeModes<'a> {
    fn from(conversation: &'a StoredProjectConversation) -> Self {
        Self {
            access_mode: &conversation.access_mode,
            approval: &conversation.claude_approval,
            plan: conversation.plan_mode,
        }
    }
}

/// The bridge policy for one turn. Access decides the file scope; Claude's
/// approval mode only refines Workspace, so Read only always asks and Full
/// access never does. Unknown stored values fall back to the safest mode.
fn claude_policy_value(
    roots: Vec<String>,
    denied_roots: &[String],
    modes: ClaudeModes<'_>,
    cwd: &str,
) -> Value {
    let (mode, approval, writes) = match modes.access_mode {
        "read_only" => ("read_only", "ask", Vec::new()),
        "full_access" => ("full_access", "full_access", roots),
        _ => (
            "workspace",
            match modes.approval {
                "accept_edits" => "accept_edits",
                "auto" => "auto",
                _ => "ask",
            },
            roots,
        ),
    };
    json!({"mode": mode, "approvalMode": approval, "planMode": modes.plan, "workspace": cwd,
        "readRoots": ["/"], "writeRoots": writes, "deniedRoots": denied_roots})
}

fn claude_policy(
    state: &AppState,
    project: &StoredProject,
    modes: ClaudeModes<'_>,
    cwd: &str,
) -> Value {
    claude_policy_value(root_paths(project), &state.denied_roots, modes, cwd)
}

/// Codex `turn/start` parameters. Sandbox and approval stay explicit, and the
/// collaboration mode is always sent so a thread that left plan mode does not
/// keep the previous turn's mode.
fn codex_turn_params(
    thread_id: &str,
    client_message_id: &str,
    input: &[Value],
    turn: &CodexTurn<'_>,
) -> Value {
    let (_, approval, sandbox_policy) = codex_policy(turn.access_mode, turn.roots);
    json!({"threadId": thread_id, "clientUserMessageId": client_message_id, "input": input,
        "model": turn.model, "effort": turn.effort, "serviceTier": turn.service_tier, "cwd": turn.cwd,
        "approvalPolicy": approval, "sandboxPolicy": sandbox_policy, "runtimeWorkspaceRoots": turn.roots,
        "collaborationMode": {"mode": if turn.plan { "plan" } else { "default" },
            "settings": {"model": turn.model, "reasoning_effort": turn.effort, "developer_instructions": null}}})
}

struct CodexTurn<'a> {
    access_mode: &'a str,
    roots: &'a [String],
    model: &'a str,
    effort: Option<&'a str>,
    service_tier: Option<&'a str>,
    cwd: &'a str,
    plan: bool,
}

/// Reuse normal execution's root checks before restoring frozen update policy.
pub(crate) async fn validate_update_policy(
    state: &AppState,
    conversation: &StoredProjectConversation,
    resume: &Value,
    turn: &Value,
) -> Result<(), String> {
    let project = state
        .store
        .project(&conversation.project_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("The paused project was removed")?;
    let roots = root_paths(&project);
    let checked = project.clone();
    let denied = state.denied_roots.clone();
    tokio::task::spawn_blocking(move || validate_execution_roots(&checked, &denied))
        .await
        .map_err(|e| e.to_string())?
        .map_err(str::to_owned)?;
    if project.root_for(&conversation.cwd).is_none()
        || resume["cwd"].as_str() != Some(&conversation.cwd)
    {
        return Err("The paused project folder is no longer authorized".into());
    }
    let compatible = match conversation.family {
        AgentFamily::Codex => {
            let (_, approval, policy) = codex_policy(&conversation.access_mode, &roots);
            resume["runtimeWorkspaceRoots"] == json!(roots)
                && turn["sandboxPolicy"] == policy
                && turn["approvalPolicy"] == approval
        }
        AgentFamily::Claude => {
            let mut policy = claude_policy(
                state,
                &project,
                ClaudeModes::from(conversation),
                &conversation.cwd,
            );
            policy["workspace"] = json!(media_workspace(state, &conversation.conversation_id)
                .await
                .ok_or("The paused attachment folder is unavailable")?);
            resume["wonderPolicy"] == policy && turn["wonderPolicy"] == policy
        }
    };
    if !compatible {
        return Err("Project access changed while work was paused. Review the conversation before continuing.".into());
    }
    Ok(())
}

pub(crate) async fn is_project(state: &AppState, conversation: &str) -> bool {
    matches!(
        state.store.project_conversation(conversation).await,
        Ok(Some(_))
    )
}

pub(crate) async fn ready(state: &AppState) -> bool {
    state.ingestion.project_readiness(&state.store).await.ready
}

/// Durable project send. Mirrors Bot dispatch: claim, resolve, persist the
/// receipt before turn/start, and never blindly resend an uncertain request.
pub(crate) async fn dispatch(state: AppState, message: wonder_store::StoredMessage) {
    let guard = state
        .update_admission
        .dispatch_guard(&state.dispatch_lock)
        .await;
    match state.store.claim_message_for_dispatch(&message.id).await {
        Ok(true) => {}
        _ => return,
    }
    let Ok(Some(message)) = state.store.message_by_id(&message.id).await else {
        return;
    };
    let mut submitting = false;
    let outcome = dispatch_inner(&state, &message, &mut submitting).await;
    match outcome {
        Ok((thread_id, turn_id, generation)) => {
            state
                .projects
                .generations
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(message.id.clone(), generation);
            if state
                .store
                .update_message_delivery(
                    &message.id,
                    "accepted_by_codex",
                    Some(&thread_id),
                    Some(&turn_id),
                )
                .await
                .is_err()
            {
                return;
            }
            publish_message_state(
                &state,
                &message,
                DeliveryState::AcceptedByCodex,
                Some(&thread_id),
                Some(&turn_id),
            )
            .await;
            // A buffered completion must remain the last delivery event.
            crate::drain_pending_app_server_notifications(&state, &thread_id, &turn_id).await;
            state
                .projects
                .notices
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&message.conversation_id);
            let _ = state
                .store
                .touch_project_conversation(&message.conversation_id, &now_text())
                .await;
            drop(guard);
        }
        Err(failure) => {
            let (status, delivery) = if submitting {
                ("uncertain", DeliveryState::Uncertain)
            } else {
                ("safe_to_retry", DeliveryState::SafeToRetry)
            };
            if state
                .store
                .update_message_delivery(&message.id, status, None, None)
                .await
                .is_ok()
            {
                publish_message_state(&state, &message, delivery, None, None).await;
            }
            // Kept for the conversation's recovery notice; never a raw payload.
            state
                .projects
                .notices
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(message.conversation_id.clone(), failure.clone());
            let _ = state.logger.record(
                "error",
                "project_dispatch_failed",
                json!({"messageId": message.id, "error": failure}),
            );
        }
    }
}

async fn dispatch_inner(
    state: &AppState,
    message: &wonder_store::StoredMessage,
    submitting: &mut bool,
) -> Result<(String, String, String), String> {
    let conversation = state
        .store
        .project_conversation(&message.conversation_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("This project conversation is unavailable.")?;
    if codex_is_archived(state, &conversation).await? {
        return Err("This thread is archived. Restore it on your Mac before sending.".into());
    }
    let project = state
        .store
        .project(&conversation.project_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("This project is unavailable.")?;
    if !project.is_included {
        return Err("This Project is not included in Wonder. Restore it before continuing.".into());
    }
    let validation_project = project.clone();
    let denied = state.denied_roots.clone();
    tokio::task::spawn_blocking(move || validate_execution_roots(&validation_project, &denied))
        .await
        .map_err(|_| "Project folders could not be checked.")?
        .map_err(str::to_owned)?;
    // Execution needs the recorded folder to still belong to the project and
    // exist; Wonder never rebases a session onto a different folder.
    let root = project
        .root_for(&conversation.cwd)
        .ok_or("This thread's folder was removed from the project. Add it back to continue.")?;
    if !FsPath::new(&root.canonical_path).is_dir() {
        return Err("This thread's folder is no longer available on your Mac.".into());
    }
    let catalog = state.runtime_catalog.read().await.clone();
    let (selected_model, effort, selected_tier) = state
        .store
        .project_message_execution_settings(&message.id)
        .await
        .map_err(|e| e.to_string())?
        .unwrap_or_else(|| {
            (
                conversation.model.clone(),
                conversation.effort.clone(),
                conversation.service_tier.clone(),
            )
        });
    let model = selected_model
        .clone()
        .or_else(|| default_model(&catalog, conversation.family))
        .ok_or("Choose a model for this thread.")?;
    let service_tier = selected_tier.or_else(|| {
        if conversation.family == AgentFamily::Codex {
            return Some("default".to_owned());
        }
        catalog
            .models
            .iter()
            .find(|option| option.id == model && option.agent_family == conversation.family)
            .and_then(|option| option.default_service_tier.clone())
    });
    validate_model(
        &catalog,
        conversation.family,
        Some(&model),
        effort.as_deref(),
        service_tier.as_deref(),
    )
    .map_err(str::to_owned)?;
    let roots = project
        .roots
        .iter()
        .map(|r| r.path.clone())
        .collect::<Vec<_>>();
    let files = state
        .store
        .attachments_for_message(&message.id)
        .await
        .map_err(|e| e.to_string())?;
    let media = media_workspace(state, &message.conversation_id)
        .await
        .ok_or("The attachment folder is unavailable.")?;
    for file in &files {
        if file.conversation_id != message.conversation_id {
            return Err("The attachment belongs to another conversation.".into());
        }
        let path = crate::attachment_path(&media, &file.id, false)
            .await
            .ok_or("The attachment path is unavailable.")?;
        crate::group_attachments::verified_bytes(&path, file).await?;
    }
    // Reuse the bridge's existing owned-workspace exception for this exact
    // conversation's media. Other Wonder data and Bot homes remain denied.
    let mut permission = claude_policy(
        state,
        &project,
        ClaudeModes::from(&conversation),
        &conversation.cwd,
    );
    permission["workspace"] = json!(media);
    let binding = state
        .store
        .runtime_binding(&message.conversation_id)
        .await
        .map_err(|e| e.to_string())?;
    let rpc = rpc_for(state, conversation.family).await?;
    let store = provider_store(state, conversation.family).to_owned();
    let now = now_text();
    let thread_id = match (conversation.family, binding) {
        (_, Some(binding)) if binding.execution_scope != wonder_store::EXECUTION_SCOPE_PROJECTS => {
            return Err("This conversation belongs to a Bot.".into());
        }
        (AgentFamily::Codex, Some(binding)) => {
            associate_codex_project(state, &project, &binding.thread_id).await?;
            let (sandbox, approval, _) = codex_policy(&conversation.access_mode, &roots);
            // Read-only check first: a desktop client may be running this thread.
            let turns = result(&rpc, "thread/turns/list", json!({"threadId": binding.thread_id, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"})).await
                .map_err(|_| "This Codex thread is no longer available on your Mac.".to_owned())?;
            if turns.pointer("/data/0/status").and_then(Value::as_str) == Some("inProgress") {
                return Err(
                    "This thread is still working on your Mac. Send again after it finishes."
                        .into(),
                );
            }
            let resumed = result(&rpc, "thread/resume", json!({
                "threadId": binding.thread_id, "excludeTurns": true, "cwd": conversation.cwd, "model": model,
                "serviceTier": service_tier,
                "sandbox": sandbox, "approvalPolicy": approval, "runtimeWorkspaceRoots": roots,
            }))
            .await
            .map_err(|_| "This Codex thread could not be reopened. Its history on your Mac is unchanged.".to_owned())?;
            if resumed.pointer("/thread/id").and_then(Value::as_str)
                != Some(binding.thread_id.as_str())
            {
                return Err("Codex returned a different thread. Nothing was sent.".into());
            }
            binding.thread_id
        }
        (AgentFamily::Codex, None) => {
            let project_id = native_codex_project(state, &rpc, &project).await;
            let (sandbox, approval, _) = codex_policy(&conversation.access_mode, &roots);
            let started = result(&rpc, "thread/start", json!({
                "cwd": conversation.cwd, "projectId": project_id, "model": model, "serviceTier": service_tier, "sandbox": sandbox,
                "approvalPolicy": approval, "runtimeWorkspaceRoots": roots,
            }))
            .await?;
            let thread = started
                .pointer("/thread/id")
                .and_then(Value::as_str)
                .ok_or("Codex returned no thread")?
                .to_owned();
            state
                .store
                .set_project_native_session(&conversation.conversation_id, &thread, &now)
                .await
                .map_err(|e| e.to_string())?;
            state
                .store
                .bind_project_runtime(
                    &conversation.conversation_id,
                    AgentFamily::Codex,
                    &store,
                    &thread,
                    None,
                    &now,
                )
                .await
                .map_err(|e| e.to_string())?;
            thread
        }
        (AgentFamily::Claude, Some(binding)) => binding.thread_id,
        (AgentFamily::Claude, None) => {
            let started = result(
                &rpc,
                "thread/start",
                json!({
                    "cwd": conversation.cwd, "model": model, "serviceTier": service_tier,
                    "wonderPolicy": permission,
                    "wonderProject": claude_project(&project, &conversation.cwd),
                }),
            )
            .await?;
            let thread = started
                .pointer("/thread/id")
                .and_then(Value::as_str)
                .ok_or("Claude returned no session")?
                .to_owned();
            let session = started
                .pointer("/thread/sessionId")
                .and_then(Value::as_str)
                .ok_or("Claude returned no session")?
                .to_owned();
            state
                .store
                .set_project_native_session(&conversation.conversation_id, &session, &now)
                .await
                .map_err(|e| e.to_string())?;
            state
                .store
                .bind_project_runtime(
                    &conversation.conversation_id,
                    AgentFamily::Claude,
                    &store,
                    &thread,
                    Some(&session),
                    &now,
                )
                .await
                .map_err(|e| e.to_string())?;
            thread
        }
    };
    let annotation_inputs = crate::artifact_annotations::selected_inputs(
        state,
        &message.conversation_id,
        &files,
        false,
    )
    .await
    .map_err(|(_, detail)| detail)?;
    let ordinary_files = files
        .into_iter()
        .filter(|file| file.mime_type.as_deref() != Some(crate::artifact_annotations::MIME))
        .collect::<Vec<_>>();
    let mut input = crate::turn_input(&message.body, &media, &ordinary_files);
    input.extend(annotation_inputs);
    let context = json!({
        "schemaVersion": 1, "scope": "projects", "projectId": project.id, "rootsRevision": project.roots_revision,
        "workingDirectory": conversation.cwd, "model": model, "effort": effort, "serviceTier": service_tier,
        "accessMode": conversation.access_mode, "family": conversation.family,
        "claudeApproval": conversation.claude_approval, "planMode": conversation.plan_mode,
        "inputSha256": hex::encode(Sha256::digest(serde_json::to_vec(&input).unwrap_or_default())),
    })
    .to_string();
    state
        .store
        .begin_dispatch_submission_with_context(&message.id, &thread_id, Some(&context))
        .await
        .map_err(|e| e.to_string())?;
    *submitting = true;
    let params = match conversation.family {
        AgentFamily::Codex => codex_turn_params(
            &thread_id,
            &message.client_message_id,
            &input,
            &CodexTurn {
                access_mode: &conversation.access_mode,
                roots: &roots,
                model: &model,
                effort: effort.as_deref(),
                service_tier: service_tier.as_deref(),
                cwd: &conversation.cwd,
                plan: conversation.plan_mode,
            },
        ),
        AgentFamily::Claude => {
            json!({"threadId": thread_id, "clientUserMessageId": message.client_message_id,
            "input": input, "model": model, "effort": effort, "serviceTier": service_tier,
            "wonderPolicy": permission,
            "wonderProject": claude_project(&project, &conversation.cwd)})
        }
    };
    let resume = match conversation.family {
        AgentFamily::Codex => {
            let (sandbox, approval, _) = codex_policy(&conversation.access_mode, &roots);
            json!({"threadId":thread_id,"excludeTurns":true,"cwd":conversation.cwd,"model":model,"serviceTier":service_tier,
                "sandbox":sandbox,"approvalPolicy":approval,"runtimeWorkspaceRoots":roots})
        }
        AgentFamily::Claude => json!({"threadId":thread_id,"excludeTurns":true,
            "cwd":conversation.cwd,"model":model,"serviceTier":service_tier,"wonderPolicy":permission,
            "wonderProject":claude_project(&project, &conversation.cwd)}),
    };
    crate::update_handoff::remember_settings(state, &thread_id, &resume, &params).await?;
    let started = result(&rpc, "turn/start", params).await?;
    let turn = started
        .pointer("/turn/id")
        .or_else(|| started.get("turnId"))
        .and_then(Value::as_str)
        .ok_or("The provider returned no message receipt")?
        .to_owned();
    Ok((thread_id, turn, rpc.health().id().to_owned()))
}

/// Native history also settles a missed completion from a still-live runtime.
/// An uncertain receipt is completed only with proof for its exact native turn;
/// incomplete history never authorizes resubmission.
pub(crate) async fn recover(state: &AppState) {
    let _dispatch = state.dispatch_lock.lock().await;
    let Ok(messages) = state.store.active_runtime_messages().await else {
        return;
    };
    for message in messages {
        let Ok(Some(conversation)) = state
            .store
            .project_conversation(&message.conversation_id)
            .await
        else {
            continue;
        };
        let (Some(thread), Some(turn)) = (
            message.codex_thread_id.clone(),
            message.codex_turn_id.clone(),
        ) else {
            continue;
        };
        let accepted = state
            .projects
            .generations
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&message.id)
            .cloned();
        let current = match conversation.family {
            AgentFamily::Codex => Some(state.projects.codex.lock().await.health()),
            AgentFamily::Claude => match claude_client(state) {
                Ok(client) => Some(client.lock().await.health()),
                Err(_) => None,
            },
        };
        let same_live_runtime = accepted.is_some()
            && current
                .as_ref()
                .is_some_and(|h| h.is_alive() && Some(h.id()) == accepted.as_deref());
        let Ok(rpc) = rpc_for(state, conversation.family).await else {
            continue;
        };
        let Ok(status) = native_turn_status(&rpc, &thread, &turn).await else {
            continue;
        };
        match status.as_deref() {
            Some("completed" | "failed" | "interrupted") => {
                if let Some(items) =
                    crate::hydrate_app_server_turn_items(state, &thread, &turn).await
                {
                    for entry in items {
                        if entry.item.get("type").and_then(Value::as_str) == Some("agentMessage") {
                            crate::process_app_server_notification(state, json!({"method": "item/completed",
                                "params": {"threadId": thread, "turnId": turn, "item": entry.item}}), false).await;
                        }
                    }
                }
                if !crate::process_app_server_notification(state, json!({"method": "turn/completed",
                    "params": {"threadId": thread, "turnId": turn, "turn": {"id": turn, "status": status}}}), false).await {
                    continue;
                }
            }
            _ if same_live_runtime || message.state == "uncertain" => continue,
            _ => {
                if state
                    .store
                    .mark_runtime_turn_uncertain(&thread, &turn)
                    .await
                    .is_ok()
                {
                    let _ = crate::publish_message_state_checked(
                        state,
                        &message,
                        DeliveryState::Uncertain,
                        Some(&thread),
                        Some(&turn),
                    )
                    .await;
                }
            }
        }
        state
            .projects
            .generations
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&message.id);
    }
    release_idle_codex_runtime(state).await;
}

async fn native_turn_status(
    rpc: &RpcClient,
    thread: &str,
    turn: &str,
) -> Result<Option<String>, String> {
    let mut cursor: Option<String> = None;
    let mut seen = HashSet::new();
    for _ in 0..100 {
        let page = result(
            rpc,
            "thread/turns/list",
            json!({"threadId": thread,
            "limit": 20, "sortDirection": "desc", "itemsView": "notLoaded", "cursor": cursor}),
        )
        .await?;
        let turns = page["data"].as_array().ok_or("Missing native turns")?;
        if let Some(found) = turns.iter().find(|t| t["id"].as_str() == Some(turn)) {
            return found["status"]
                .as_str()
                .map(|s| Some(s.to_owned()))
                .ok_or_else(|| "Missing native turn status".into());
        }
        cursor = page["nextCursor"].as_str().map(str::to_owned);
        let Some(next) = cursor.as_ref() else {
            return Ok(None);
        };
        if !seen.insert(next.clone()) {
            return Err("Native turns repeated a cursor".into());
        }
    }
    Err("Native turn history is incomplete".into())
}

/// Unsubscribe retains Codex's writer lock for an inactivity grace period.
/// Close our normal-home process once all of its loaded work is idle instead.
/// Other project work, native children, goals, terminals and captured read/RPC
/// handles retain the process; the private Bot runtime is never stopped here.
async fn release_idle_codex_runtime(state: &AppState) {
    let runtime = &state.projects;
    let _start = runtime.start.lock().await;
    let mut client = runtime.codex.lock().await;
    if !client.health().is_alive() || client.health().storage_blocked() || client.has_rpc_handles()
    {
        return;
    }
    let rpc = client.rpc();
    let Ok(loaded) = result(&rpc, "thread/loaded/list", json!({})).await else {
        return;
    };
    let Some(threads) = loaded["data"].as_array() else {
        return;
    };
    // Discovery alone holds no writer and needs no restart. Incomplete or
    // unsupported lifecycle responses must never authorize process shutdown.
    if threads.is_empty() || !loaded["nextCursor"].is_null() {
        return;
    }
    let Ok(messages) = state.store.active_runtime_messages().await else {
        return;
    };
    // Queued user intent remains in SQLite for the next dispatch tick. An
    // admitted turn with unconfirmed completion keeps its runtime alive.
    if messages.iter().any(|m| {
        m.state != "uncertain"
            && threads
                .iter()
                .any(|t| t.as_str() == m.codex_thread_id.as_deref())
    }) {
        return;
    }
    for thread in threads {
        let Some(thread) = thread.as_str() else {
            return;
        };
        let Ok(read) = result(&rpc, "thread/read", json!({"threadId": thread})).await else {
            return;
        };
        if read["thread"]["id"].as_str() != Some(thread)
            || read["thread"]["status"]["type"].as_str() != Some("idle")
        {
            return;
        }
        let Ok(goal) = result(&rpc, "thread/goal/get", json!({"threadId": thread})).await else {
            return;
        };
        if !goal.get("goal").is_some_and(|g| {
            g.is_null()
                || matches!(
                    g["status"].as_str(),
                    Some("complete" | "blocked" | "paused" | "budgetLimited" | "usageLimited")
                )
        }) {
            return;
        }
        let Ok(background) = result(
            &rpc,
            "thread/backgroundTerminals/list",
            json!({"threadId": thread, "limit": 1}),
        )
        .await
        else {
            return;
        };
        if !background["data"].as_array().is_some_and(Vec::is_empty)
            || !background["nextCursor"].is_null()
        {
            return;
        }
    }
    drop(rpc);
    if !client.has_rpc_handles() {
        let _ = client.shutdown().await;
    }
}

/// Reuse a native Codex project with the same folders, otherwise create one
/// with an idempotency key. Unsupported runtimes simply omit project identity.
async fn native_codex_project(
    state: &AppState,
    rpc: &RpcClient,
    project: &StoredProject,
) -> Option<String> {
    let store = state.projects.codex_store.clone();
    let existing = state
        .store
        .project_provider_ref(&project.id, AgentFamily::Codex, &store)
        .await
        .ok()?;
    let wanted: HashSet<String> = project
        .roots
        .iter()
        .map(|r| r.canonical_path.clone())
        .collect();
    if let Some(id) = existing.as_deref() {
        if let Ok(read) = result(rpc, "project/read", json!({"projectId": id})).await {
            if read.pointer("/project/id").and_then(Value::as_str) == Some(id)
                && native_project_roots_match(&read["project"], &wanted)
            {
                return Some(id.to_owned());
            }
        }
    }
    let listed = result(rpc, "project/list", json!({"limit": 100}))
        .await
        .ok()?;
    let matched = listed
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find_map(|native| {
            native_project_roots_match(native, &wanted)
                .then(|| native.get("id").and_then(Value::as_str).map(str::to_owned))
                .flatten()
        });
    let id = match matched {
        Some(id) => id,
        None => {
            let primary = project.primary_root();
            let mut roots = vec![json!({"path": primary.path})];
            roots.extend(
                project
                    .roots
                    .iter()
                    .filter(|r| r.id != primary.id)
                    .map(|r| json!({"path": r.path})),
            );
            // A folder edit needs a new identity even when an older project
            // creation key still points at the previous folders.
            let mut identity_roots = wanted.iter().collect::<Vec<_>>();
            identity_roots.sort();
            let roots_hash = hex::encode(Sha256::digest(serde_json::to_vec(&identity_roots).ok()?));
            let created = result(rpc, "project/create", json!({"idempotencyKey": format!("wonder-{}-{roots_hash}", project.id), "name": project.name, "roots": roots})).await.ok()?;
            if !native_project_roots_match(&created["project"], &wanted) {
                return None;
            }
            created
                .pointer("/project/id")
                .and_then(Value::as_str)?
                .to_owned()
        }
    };
    let winner = match existing {
        Some(previous) => {
            state
                .store
                .replace_project_provider_ref(
                    &project.id,
                    AgentFamily::Codex,
                    &store,
                    &previous,
                    &id,
                )
                .await
        }
        None => {
            state
                .store
                .set_project_provider_ref(&project.id, AgentFamily::Codex, &store, &id)
                .await
        }
    }
    .ok()?;
    if winner == id {
        return Some(winner);
    }
    // Another caller won the first insert or stale-reference replacement.
    // Never associate a thread using that unchecked destination.
    let read = result(rpc, "project/read", json!({"projectId": winner}))
        .await
        .ok()?;
    (read.pointer("/project/id").and_then(Value::as_str) == Some(winner.as_str())
        && native_project_roots_match(&read["project"], &wanted))
    .then_some(winner)
}

fn native_project_roots_match(native: &Value, wanted: &HashSet<String>) -> bool {
    let Some(roots) = native.get("roots").and_then(Value::as_array) else {
        return false;
    };
    let Some(paths) = roots
        .iter()
        .map(|root| root.get("path").and_then(Value::as_str))
        .collect::<Option<Vec<_>>>()
    else {
        return false;
    };
    let canonical: HashSet<String> = paths
        .into_iter()
        .map(|path| {
            std::fs::canonicalize(path)
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| path.to_owned())
        })
        .collect();
    canonical == *wanted
}

/// Imported or older native threads can have a cwd without a desktop project.
/// Repair only unassigned, in-project roots; preserve an owner's existing choice.
async fn associate_codex_project(
    state: &AppState,
    project: &StoredProject,
    native: &str,
) -> Result<(), String> {
    let rpc = codex_rpc(state).await?;
    let read = result(&rpc, "thread/read", json!({"threadId": native}))
        .await
        .map_err(|_| "This Codex thread could not be checked on your Mac.".to_owned())?;
    let thread = read.get("thread").ok_or("Codex returned no thread.")?;
    if thread.get("id").and_then(Value::as_str) != Some(native) {
        return Err("Codex returned a different thread. Nothing was changed.".into());
    }
    let cwd = thread
        .get("cwd")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if project.root_for(cwd).is_none()
        || thread
            .get("parentThreadId")
            .and_then(Value::as_str)
            .is_some()
    {
        return Err("This thread is outside the project's folders.".into());
    }
    if thread
        .get("projectId")
        .and_then(Value::as_str)
        .is_some_and(|id| !id.is_empty())
    {
        return Ok(());
    }
    let Some(id) = native_codex_project(state, &rpc, project).await else {
        // Older runtimes can still continue a thread by cwd alone.
        return Ok(());
    };
    let response = rpc
        .request(
            "thread/metadata/update",
            json!({"threadId": native, "projectId": id}),
        )
        .await
        .map_err(|_| {
            "This thread's desktop project could not be saved. Try opening it again.".to_owned()
        })?;
    if let Some(error) = response.error {
        return if error.code == -32601 {
            Ok(())
        } else {
            Err("This thread's desktop project could not be saved. Try opening it again.".into())
        };
    }
    let saved = response.result.ok_or("Codex returned no saved project.")?;
    if saved.pointer("/thread/id").and_then(Value::as_str) != Some(native)
        || saved.pointer("/thread/projectId").and_then(Value::as_str) != Some(id.as_str())
    {
        return Err("This thread's desktop project was not saved. Try opening it again.".into());
    }
    Ok(())
}

/// Resolve an uncertain project send by its client message identity.
pub(crate) async fn find_accepted_turn(
    state: &AppState,
    message: &wonder_store::StoredMessage,
) -> Result<Option<String>, String> {
    let Some(thread) = message.codex_thread_id.as_deref() else {
        return Ok(None);
    };
    let Some(conversation) = state
        .store
        .project_conversation(&message.conversation_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };
    let rpc = rpc_for(state, conversation.family).await?;
    let mut cursor: Option<String> = None;
    for _ in 0..200 {
        let page = result(
            &rpc,
            "thread/items/list",
            json!({"threadId": thread, "limit": 100, "cursor": cursor}),
        )
        .await?;
        if let Some(turn) = crate::find_client_message(&page, &message.client_message_id) {
            return Ok(Some(turn));
        }
        cursor = page
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(str::to_owned);
        if cursor.is_none() {
            return Ok(None);
        }
    }
    Ok(None)
}

/// Wonder-owned storage for media a project tool returned. It is never the
/// owner's project folder.
pub(crate) async fn media_workspace(state: &AppState, conversation: &str) -> Option<String> {
    state
        .store
        .project_conversation(conversation)
        .await
        .ok()??;
    // A local symlink must never redirect an authenticated upload or grant the
    // provider access to a different conversation's private data.
    uuid::Uuid::parse_str(conversation).ok()?;
    let parent = tokio::fs::canonicalize(PathBuf::from(&state.bots_root).parent()?)
        .await
        .ok()?;
    let mut root = parent.clone();
    for component in ["project-media", conversation] {
        root.push(component);
        match tokio::fs::create_dir(&root).await {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(_) => return None,
        }
        let metadata = tokio::fs::symlink_metadata(&root).await.ok()?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return None;
        }
    }
    let root = tokio::fs::canonicalize(root).await.ok()?;
    if !root.starts_with(&parent) {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = tokio::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).await;
    }
    root.to_str().map(str::to_owned)
}

// ---------------------------------------------------------------------------
// Continue on Mac
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ContinuationOption {
    id: &'static str,
    title: String,
    detail: String,
    command: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ContinuationResponse {
    options: Vec<ContinuationOption>,
    notes: Vec<String>,
}

pub(crate) fn shell_quote(value: &str) -> String {
    if !value.is_empty()
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_./:@%+=,".contains(c))
    {
        return value.to_owned();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Exact-ID terminal commands generated from validated metadata. Copying a
/// command never executes it; Wonder does not open desktop apps remotely.
pub(crate) async fn continuation(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(id): Path<String>,
) -> Response {
    let Ok(Some(conversation)) = state.store.project_conversation(&id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some(native) = conversation.native_session_id.clone() else {
        return error(
            StatusCode::CONFLICT,
            "Send the first message before continuing on your Mac.",
        );
    };
    let Ok(Some(project)) = state.store.project(&conversation.project_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let extra = project
        .roots
        .iter()
        .filter(|r| r.path != conversation.cwd)
        .flat_map(|r| ["--add-dir".to_owned(), shell_quote(&r.path)])
        .collect::<Vec<_>>();
    let cd = format!("cd {}", shell_quote(&conversation.cwd));
    let mut notes = Vec::new();
    let options = match conversation.family {
        AgentFamily::Codex => vec![ContinuationOption {
            id: "codex-cli",
            title: "Continue in Codex CLI".into(),
            detail: "Resumes this exact thread in Terminal with your usual Codex settings.".into(),
            command: [
                vec![
                    cd,
                    "&&".into(),
                    "codex".into(),
                    "resume".into(),
                    shell_quote(&native),
                ],
                extra,
            ]
            .concat()
            .join(" "),
        }],
        AgentFamily::Claude => {
            notes.push("Use a current Claude Code version. Older versions can split the conversation when resuming.".into());
            vec![ContinuationOption {
                id: "claude-code",
                title: "Continue in Claude Code".into(),
                detail: "Resumes this exact session in Terminal. Type /desktop there to move it to the Claude app.".into(),
                command: [vec![cd, "&&".into(), "claude".into(), "--resume".into(), shell_quote(&native)], extra].concat().join(" "),
            }]
        }
    };
    if state
        .store
        .conversation_has_active_turn(&id)
        .await
        .unwrap_or(false)
    {
        notes.push("Wonder is still working in this thread. Wait for it to finish, or stop it, before continuing on your Mac.".into());
    }
    notes.push("When you come back, Wonder shows the turns you added on your Mac.".into());
    Json(ContinuationResponse { options, notes }).into_response()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    // Blank, structurally valid two-page PDF for provider-input tests. Offsets
    // are calculated from the emitted objects so a PDF parser can check page 2.
    #[cfg(target_os = "macos")]
    fn two_page_pdf() -> Vec<u8> {
        let mut bytes = b"%PDF-1.4\n".to_vec();
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>",
        ];
        let mut offsets = Vec::with_capacity(objects.len());
        for (index, object) in objects.iter().enumerate() {
            offsets.push(bytes.len());
            bytes.extend_from_slice(format!("{} 0 obj\n{object}\nendobj\n", index + 1).as_bytes());
        }
        let xref = bytes.len();
        bytes.extend_from_slice(
            format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes(),
        );
        for offset in offsets {
            bytes.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
        }
        bytes.extend_from_slice(
            format!("trailer\n<< /Root 1 0 R /Size 5 >>\nstartxref\n{xref}\n").as_bytes(),
        );
        bytes.extend_from_slice(b"%%EOF\n");
        bytes
    }

    pub(crate) async fn handoff_fixture(
    ) -> (tempfile::TempDir, AppState, wonder_store::StoredMessage) {
        let (dir, mut state) = crate::ingestion::tests::fixture().await;
        let source = dir.path().join("project-source");
        std::fs::create_dir(&source).unwrap();
        let roots = validate_folders(&[source.to_string_lossy().into_owned()], &[]).unwrap();
        state
            .store
            .create_project("project", "request", "hash", "Test", &roots, 0, "now")
            .await
            .unwrap();
        state.projects = ProjectRuntime::configured(
            dir.path().join("codex"),
            "test".into(),
            &dir.path().join("home"),
            &dir.path().join("claude"),
            crate::ingestion::notification_sink(state.store.clone()),
        );
        state
            .store
            .create_project_conversation(ProjectConversationInsert {
                conversation_id: "project-chat",
                project_id: "project",
                family: AgentFamily::Codex,
                provider_store: &state.projects.codex_store,
                native_session_id: Some("thread"),
                cwd: source.to_str().unwrap(),
                roots_revision: 1,
                title: "Recovery",
                model: None,
                effort: None,
                service_tier: None,
                access_mode: "read_only",
                claude_approval: "ask",
                plan_mode: false,
                creation_request_id: None,
                now: "now",
            })
            .await
            .unwrap();
        state
            .store
            .bind_project_runtime(
                "project-chat",
                AgentFamily::Codex,
                &state.projects.codex_store,
                "thread",
                None,
                "now",
            )
            .await
            .unwrap();
        let MessageInsert::Inserted(message) = state
            .store
            .insert_dispatch_message(
                "owner",
                "receipt",
                "work",
                "hash",
                "project-chat",
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!("new receipt")
        };
        state
            .store
            .update_message_delivery(&message.id, "streaming", Some("thread"), Some("turn"))
            .await
            .unwrap();
        std::fs::write(
            dir.path().join("idle-fixture.json"),
            json!({"thread":{
            "id":"thread", "status":{"type":"idle"}}})
            .to_string(),
        )
        .unwrap();
        std::fs::write(dir.path().join("lock-fixture"), "").unwrap();
        let rpc = codex_rpc(&state).await.unwrap();
        state
            .projects
            .generations
            .lock()
            .unwrap()
            .insert(message.id.clone(), rpc.health().id().into());
        drop(rpc);
        (dir, state, message)
    }

    fn writer_available(dir: &FsPath) -> bool {
        std::fs::File::open(dir.join("writer.lock"))
            .unwrap()
            .try_lock()
            .is_ok()
    }

    // Contract: one provider-owned archive hides even pinned chats, failures
    // preserve visibility, restart/retry retain identity, and desktop changes
    // reconcile both ways without resuming archived work.
    #[tokio::test]
    async fn codex_archive_reconciles_pins_retry_restart_and_desktop_restore() {
        let (dir, state, message) = handoff_fixture().await;
        let conversation = state
            .store
            .project_conversation("project-chat")
            .await
            .unwrap()
            .unwrap();
        std::fs::write(dir.path().join("archive-fixture"), "").unwrap();
        std::fs::write(
            dir.path().join("idle-fixture.json"),
            json!({"thread": {
                "id": "thread", "cwd": conversation.cwd, "name": "Recovery", "updatedAt": 1,
                "status": {"type": "idle"}, "parentThreadId": null,
            }})
            .to_string(),
        )
        .unwrap();
        state
            .store
            .update_project_conversation(
                "project-chat",
                ProjectConversationPatch {
                    pinned: Some(true),
                    ..Default::default()
                },
                "now",
            )
            .await
            .unwrap();
        assert_eq!(
            set_archived(&state, &conversation, true)
                .await
                .unwrap_err()
                .0,
            StatusCode::CONFLICT
        );
        state
            .store
            .update_message_delivery(&message.id, "completed", Some("thread"), Some("turn"))
            .await
            .unwrap();
        std::fs::write(dir.path().join("completed"), "").unwrap();

        std::fs::write(dir.path().join("archive-fail"), "").unwrap();
        assert_eq!(
            set_archived(&state, &conversation, true)
                .await
                .unwrap_err()
                .0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        assert!(
            !conversation_detail(&state, &conversation)
                .await
                .unwrap()
                .is_archived
        );
        std::fs::remove_file(dir.path().join("archive-fail")).unwrap();

        let request: UpdateConversationRequest =
            serde_json::from_value(json!({"isArchived": true})).unwrap();
        let archived = update_conversation(
            State(state.clone()),
            Extension(OwnerAuthority),
            Path("project-chat".into()),
            Json(request),
        )
        .await;
        let status = archived.status();
        let body = axum::body::to_bytes(archived.into_body(), 100_000)
            .await
            .unwrap();
        assert_eq!(status, StatusCode::OK, "{}", String::from_utf8_lossy(&body));
        let body: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(body["isArchived"], true);
        crate::tests::validate_http_contract("projectConversationDetail", &body);
        assert!(
            state
                .store
                .project_conversation("project-chat")
                .await
                .unwrap()
                .unwrap()
                .is_pinned
        );
        let library = list(State(state.clone()), Extension(OwnerAuthority)).await;
        let body = axum::body::to_bytes(library.into_body(), 100_000)
            .await
            .unwrap();
        let body: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(body["pinned"], json!([]));
        let mut submitting = false;
        assert!(dispatch_inner(&state, &message, &mut submitting)
            .await
            .unwrap_err()
            .contains("archived"));
        assert!(!submitting);
        let attempts = std::fs::read_to_string(dir.path().join("requests"))
            .unwrap()
            .lines()
            .filter(|method| *method == "thread/archive")
            .count();
        set_archived(&state, &conversation, true).await.unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.path().join("requests"))
                .unwrap()
                .lines()
                .filter(|method| *method == "thread/archive")
                .count(),
            attempts
        );
        state.projects.shutdown().await;
        assert!(
            conversation_detail(&state, &conversation)
                .await
                .unwrap()
                .is_archived
        );

        // Desktop restoration does not call Wonder's mutation endpoint.
        std::fs::remove_file(dir.path().join("archived-thread")).unwrap();
        assert!(
            !conversation_detail(&state, &conversation)
                .await
                .unwrap()
                .is_archived
        );
        let library = list(State(state.clone()), Extension(OwnerAuthority)).await;
        let body = axum::body::to_bytes(library.into_body(), 100_000)
            .await
            .unwrap();
        let body: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(
            body["pinned"][0]["thread"]["conversationId"],
            "project-chat"
        );
        // Desktop archive is likewise authoritative without a Wonder write.
        std::fs::write(dir.path().join("archived-thread"), "").unwrap();
        assert!(
            conversation_detail(&state, &conversation)
                .await
                .unwrap()
                .is_archived
        );
        set_archived(&state, &conversation, false).await.unwrap();
        assert!(
            !conversation_detail(&state, &conversation)
                .await
                .unwrap()
                .is_archived
        );
        let mut claude = conversation.clone();
        claude.family = AgentFamily::Claude;
        assert_eq!(
            set_archived(&state, &claude, true).await.unwrap_err().0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
        state.projects.shutdown().await;
    }

    // Contract: a lost terminal notification cannot leave a live-generation
    // receipt busy forever. The existing transport/SQLite owner checks exact
    // turn proof, paged history, durable intent and the actual OS writer lock.
    #[tokio::test]
    async fn project_recovery_settles_live_and_uncertain_receipts_without_resending() {
        let (dir, state, message) = handoff_fixture().await;
        assert!(!writer_available(dir.path()));
        std::fs::write(
            dir.path().join("idle-fixture.json"),
            json!({"thread":{
            "id":"thread", "status":{"type":"active"}}})
            .to_string(),
        )
        .unwrap();
        for (delivery, native) in [("streaming", "inProgress"), ("uncertain", "inProgress")] {
            state
                .store
                .update_message_delivery(&message.id, delivery, Some("thread"), Some("turn"))
                .await
                .unwrap();
            std::fs::write(
                dir.path().join("turn-pages.json"),
                json!([[{"id":"turn", "status":native}]]).to_string(),
            )
            .unwrap();
            recover(&state).await;
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
        }
        std::fs::write(
            dir.path().join("turn-pages.json"),
            json!([[{"id":"other", "status":"completed"}]]).to_string(),
        )
        .unwrap();
        recover(&state).await;
        assert_eq!(
            state
                .store
                .message_by_id(&message.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "uncertain"
        );
        // Restore the original same-live-generation case. A terminal turn on
        // the second page settles it and an uncertain receipt for the same turn.
        assert!(state.projects.codex.lock().await.health().is_alive());
        state
            .store
            .update_message_delivery(&message.id, "streaming", Some("thread"), Some("turn"))
            .await
            .unwrap();
        let MessageInsert::Inserted(uncertain) = state
            .store
            .insert_message("owner", "uncertain", "work", "hash", "project-chat", "now")
            .await
            .unwrap()
        else {
            panic!("new uncertain receipt")
        };
        state
            .store
            .update_message_delivery(&uncertain.id, "uncertain", Some("thread"), Some("turn"))
            .await
            .unwrap();
        let MessageInsert::Inserted(queued) = state
            .store
            .insert_dispatch_message(
                "owner",
                "queued",
                "next",
                "hash",
                "project-chat",
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!("new queued receipt")
        };
        std::fs::write(dir.path().join("completed"), "").unwrap();
        std::fs::write(
            dir.path().join("idle-fixture.json"),
            json!({"thread":{
            "id":"thread", "status":{"type":"idle"}}})
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            dir.path().join("turn-pages.json"),
            json!([
                [{"id":"other", "status":"completed"}], [{"id":"turn", "status":"completed"}]
            ])
            .to_string(),
        )
        .unwrap();
        recover(&state).await;
        for receipt in [&message, &uncertain] {
            assert_eq!(
                state
                    .store
                    .message_by_id(&receipt.id)
                    .await
                    .unwrap()
                    .unwrap()
                    .state,
                "completed"
            );
        }
        assert_eq!(
            state
                .store
                .message_by_id(&queued.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "accepted_by_wonder"
        );
        assert!(writer_available(dir.path()));
        assert!(!state.projects.codex.lock().await.health().is_alive());
        assert!(state.app_server.lock().await.health().is_alive());
        let requests = std::fs::read_to_string(dir.path().join("requests")).unwrap();
        for method in ["thread/start", "thread/resume", "turn/start"] {
            assert!(
                !requests.lines().any(|line| line == method),
                "{method} must not run during recovery"
            );
        }
        assert!(state
            .store
            .assistant_messages_for_conversation("project-chat")
            .await
            .unwrap()
            .iter()
            .any(|m| m.text == "recovered"));
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    // Contract: handing the writer back cannot stop another loaded thread,
    // autonomous goal, background command or a captured history/approval RPC.
    // Unmapped native children are checked directly, rather than assumed idle.
    #[tokio::test]
    async fn project_handoff_preserves_other_native_work_and_readers() {
        let (dir, state, message) = handoff_fixture().await;
        state
            .store
            .update_message_delivery(&message.id, "completed", Some("thread"), Some("turn"))
            .await
            .unwrap();
        let rpc = codex_rpc(&state).await.unwrap();
        release_idle_codex_runtime(&state).await;
        assert!(!writer_available(dir.path()));
        drop(rpc);
        let mut idle = json!({"thread":{"id":"thread", "status":{"type":"idle"}},
            "child-thread":{"id":"child-thread", "status":{"type":"idle"}}});
        for (path, value) in [
            ("/child-thread/status/type", json!("active")),
            ("/thread/goal", json!({"status":"active"})),
            ("/thread/goal", json!({"status":"futureStatus"})),
            ("/thread/background", json!([{"processId":"running"}])),
        ] {
            // Goal/background keys are optional in native snapshots.
            if path == "/thread/goal" {
                idle["thread"]["goal"] = value;
            } else if path == "/thread/background" {
                idle["thread"]["background"] = value;
            } else {
                *idle.pointer_mut(path).unwrap() = value;
            }
            std::fs::write(dir.path().join("idle-fixture.json"), idle.to_string()).unwrap();
            release_idle_codex_runtime(&state).await;
            assert!(
                state.projects.codex.lock().await.health().is_alive(),
                "{path}"
            );
            assert!(!writer_available(dir.path()));
            idle = json!({"thread":{"id":"thread", "status":{"type":"idle"}},
                "child-thread":{"id":"child-thread", "status":{"type":"idle"}}});
        }
        idle["thread"]["goal"] = json!({"status":"complete"});
        std::fs::write(dir.path().join("idle-fixture.json"), idle.to_string()).unwrap();
        release_idle_codex_runtime(&state).await;
        assert!(writer_available(dir.path()));
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    // Contract: generated commands keep paths and IDs as single arguments even
    // with spaces or quotes; nothing can inject a second shell command.
    #[test]
    fn continuation_arguments_are_shell_quoted() {
        assert_eq!(shell_quote("01a0-ff"), "01a0-ff");
        assert_eq!(shell_quote("/Users/owner/My App"), "'/Users/owner/My App'");
        assert_eq!(shell_quote("it's; rm -rf ~"), "'it'\\''s; rm -rf ~'");
        assert_eq!(shell_quote(""), "''");
    }

    // Contract: Projects responses match the published HTTP schema, so an
    // older or newer client decodes them or fails loudly in review.
    #[test]
    fn project_responses_match_the_http_contract() {
        let project = StoredProject {
            id: "p1".into(),
            name: "Wonder".into(),
            is_included: true,
            pin_order: Some(1),
            primary_root_id: "r1".into(),
            roots_revision: 2,
            last_family: Some(AgentFamily::Claude),
            created_at: "2026-09-29T00:00:00Z".into(),
            updated_at: "2026-09-29T00:00:00Z".into(),
            last_used_at: None,
            roots: vec![wonder_store::StoredProjectRoot {
                id: "r1".into(),
                path: "/work/app".into(),
                canonical_path: "/work/app".into(),
                ordinal: 0,
            }],
        };
        let summary = serde_json::to_value(project_summary(&project)).unwrap();
        crate::tests::validate_http_contract("projectSummary", &summary);
        let thread = ProjectThreadSummary {
            reference: "codex:01a0".into(),
            conversation_id: None,
            title: "Fix reconnect".into(),
            family: AgentFamily::Codex,
            updated_at: 1,
            is_pinned: false,
            has_unread: false,
            is_working: false,
        };
        let page = serde_json::to_value(ThreadsPage {
            threads: vec![thread.clone()],
            next_cursor: Some("token".into()),
            partial: vec![PartialFailure {
                family: AgentFamily::Claude,
                detail: "Claude Code threads could not be loaded.".into(),
            }],
        })
        .unwrap();
        crate::tests::validate_http_contract("projectThreadsPage", &page);
        let pinned = ProjectThreadSummary {
            conversation_id: Some("c1".into()),
            is_pinned: true,
            ..thread.clone()
        };
        let library = serde_json::to_value(ProjectsResponse {
            projects: vec![project_summary(&project)],
            families: vec![FamilyAvailability {
                family: AgentFamily::Claude,
                available: true,
            }],
            modes_version: MODES_VERSION,
            archive_version: 1,
            pinned: vec![PinnedThread {
                project_id: "p1".into(),
                thread: pinned,
            }],
        })
        .unwrap();
        crate::tests::validate_http_contract("projectsResponse", &library);
        assert_eq!(library["modesVersion"], 1);
        let detail = serde_json::to_value(ProjectConversationDetail {
            conversation_id: "c1".into(),
            project_id: "p1".into(),
            project_name: "Wonder".into(),
            title: "Fix reconnect".into(),
            family: AgentFamily::Claude,
            model: Some("claude:sonnet".into()),
            effort: None,
            service_tier: None,
            access_mode: "workspace".into(),
            claude_approval: "accept_edits".into(),
            plan_mode: true,
            working_folder: "/work/app".into(),
            working_folder_name: "app".into(),
            is_pinned: false,
            has_unread: false,
            has_native_session: true,
            is_archived: false,
            folder_in_project: true,
            notice: None,
        })
        .unwrap();
        crate::tests::validate_http_contract("projectConversationDetail", &detail);
        let continuation = serde_json::to_value(ContinuationResponse {
            options: vec![ContinuationOption {
                id: "codex-cli",
                title: "t".into(),
                detail: "d".into(),
                command: "codex resume x".into(),
            }],
            notes: vec![],
        })
        .unwrap();
        crate::tests::validate_http_contract("desktopContinuation", &continuation);
    }

    // Contract: opening an imported native thread repairs its missing desktop
    // project without starting a turn, retargeting an assigned thread, or using
    // a sibling folder. The existing real transport fixture owns this boundary.
    #[tokio::test]
    async fn native_project_association_repairs_only_unassigned_member_threads() {
        let (dir, mut state) = crate::ingestion::tests::fixture().await;
        let source = dir.path().join("project-source");
        std::fs::create_dir(&source).unwrap();
        let roots = validate_folders(&[source.to_string_lossy().into_owned()], &[]).unwrap();
        state
            .store
            .create_project("project", "request", "hash", "Test", &roots, 0, "now")
            .await
            .unwrap();
        let project = state.store.project("project").await.unwrap().unwrap();
        state.projects = ProjectRuntime::configured(
            dir.path().join("codex"),
            "test".into(),
            &dir.path().join("home"),
            &dir.path().join("claude"),
            crate::ingestion::notification_sink(state.store.clone()),
        );
        let saved = dir.path().join("native-thread.json");
        let write = |cwd: &FsPath, project: Value| {
            std::fs::write(
                &saved,
                json!({"id":"native-thread", "cwd":cwd, "projectId":project}).to_string(),
            )
            .unwrap();
        };
        write(&source, Value::Null);
        associate_codex_project(&state, &project, "native-thread")
            .await
            .unwrap();
        let assigned: Value = serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
        assert_eq!(assigned["projectId"], "native-project");
        // Reopening is idempotent; an explicit desktop choice wins.
        associate_codex_project(&state, &project, "native-thread")
            .await
            .unwrap();
        write(&source, json!("owner-project"));
        associate_codex_project(&state, &project, "native-thread")
            .await
            .unwrap();
        let assigned: Value = serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
        assert_eq!(assigned["projectId"], "owner-project");

        // A cached provider reference may now describe another folder set.
        // Replace it only after finding an exact current-folder match.
        let listed = dir.path().join("native-projects.json");
        std::fs::write(
            &listed,
            json!([
                {"id":"native-project","roots":[{"path":dir.path().join("old-source")}]},
                {"id":"current-native-project","roots":[{"path":source}]}
            ])
            .to_string(),
        )
        .unwrap();
        write(&source, Value::Null);
        associate_codex_project(&state, &project, "native-thread")
            .await
            .unwrap();
        let assigned: Value = serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
        assert_eq!(assigned["projectId"], "current-native-project");
        assert_eq!(
            state
                .store
                .project_provider_ref(&project.id, AgentFamily::Codex, &state.projects.codex_store)
                .await
                .unwrap()
                .as_deref(),
            Some("current-native-project")
        );

        // If no desktop project still owns these roots, creation must not
        // reuse the old folder set through its original idempotency key.
        std::fs::write(
            &listed,
            json!([
                {"id":"native-project","roots":[{"path":dir.path().join("old-source")}]}
            ])
            .to_string(),
        )
        .unwrap();
        write(&source, Value::Null);
        associate_codex_project(&state, &project, "native-thread")
            .await
            .unwrap();
        let assigned: Value = serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
        assert_eq!(assigned["projectId"], "created-native-project");
        std::fs::write(
            &listed,
            json!([
                {"id":"created-native-project","roots":[{"path":source}]}
            ])
            .to_string(),
        )
        .unwrap();

        // Only the protocol's optional-method code is a compatibility fallback.
        // A supported persistence error must fail even with similar wording.
        let rpc_error = dir.path().join("native-metadata-error.json");
        std::fs::write(
            &rpc_error,
            json!({"code":-32601,"message":"feature unavailable"}).to_string(),
        )
        .unwrap();
        write(&source, Value::Null);
        associate_codex_project(&state, &project, "native-thread")
            .await
            .unwrap();
        let unassigned: Value = serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
        assert!(unassigned["projectId"].is_null());
        std::fs::write(
            &rpc_error,
            json!({"code":-32000,"message":"method not found while saving project metadata"})
                .to_string(),
        )
        .unwrap();
        assert!(associate_codex_project(&state, &project, "native-thread")
            .await
            .is_err());
        write(&dir.path().join("project-source-sibling"), Value::Null);
        assert!(associate_codex_project(&state, &project, "native-thread")
            .await
            .is_err());
        let requests: Vec<Value> = std::fs::read_to_string(dir.path().join("requests-jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let updates: Vec<_> = requests
            .iter()
            .filter(|r| r["method"] == "thread/metadata/update")
            .collect();
        assert_eq!(updates.len(), 5);
        assert_eq!(
            updates[0]["params"],
            json!({"threadId":"native-thread", "projectId":"native-project"})
        );
        let created = requests
            .iter()
            .find(|r| r["method"] == "project/create")
            .unwrap();
        assert_ne!(created["params"]["idempotencyKey"], "wonder-project");
        assert_eq!(created["params"]["roots"], json!([{"path":source}]));
        assert!(!requests.iter().any(|r| matches!(
            r["method"].as_str(),
            Some("thread/start" | "thread/resume" | "turn/start")
        )));
        state.projects.shutdown().await;
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    // First-send preparation owns metadata and request recovery only. Native
    // sessions and messages must remain absent until the durable Send arrives.
    #[tokio::test]
    async fn preparation_retries_one_conversation_without_starting_work() {
        use crate::permission_modes::tests::{call, fixture};
        let (dir, state) = fixture().await;
        {
            let mut catalog = state.runtime_catalog.write().await;
            catalog.models[0].service_tiers = vec![
                crate::ChoiceOption {
                    id: "default".into(),
                    label: "Standard".into(),
                    description: None,
                },
                crate::ChoiceOption {
                    id: "fast".into(),
                    label: "Fast".into(),
                    description: None,
                },
            ];
        }
        let source = dir.path().join("project-source");
        std::fs::create_dir(&source).unwrap();
        let roots = validate_folders(&[source.to_string_lossy().into_owned()], &[]).unwrap();
        state
            .store
            .create_project(
                "prepare-project",
                "request",
                "hash",
                "Test",
                &roots,
                0,
                "now",
            )
            .await
            .unwrap();
        let _service = crate::ingestion::spawn(state.clone()).await;
        for _ in 0..100 {
            if state.ingestion.project_readiness(&state.store).await.ready {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let request = json!({"deviceId":"owner", "clientMessageId":uuid::Uuid::new_v4().to_string(),
            "family":"codex", "model":"fake", "serviceTier":"fast", "body":"First message", "rootsRevision":1, "prepareOnly":true});
        crate::tests::validate_http_contract("createProjectThreadRequest", &request);
        let mut unsupported = request.clone();
        unsupported["clientMessageId"] = json!(uuid::Uuid::new_v4().to_string());
        unsupported["serviceTier"] = json!("priority");
        assert_eq!(
            call(
                &state,
                "POST",
                "/api/v1/projects/prepare-project/threads",
                unsupported
            )
            .await
            .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
        let first = call(
            &state,
            "POST",
            "/api/v1/projects/prepare-project/threads",
            request.clone(),
        )
        .await;
        assert_eq!(first.0, StatusCode::OK, "{}", first.1);
        crate::tests::validate_http_contract("createProjectThreadResponse", &first.1);
        assert!(first.1["receipt"].is_null());
        let second = call(
            &state,
            "POST",
            "/api/v1/projects/prepare-project/threads",
            request.clone(),
        )
        .await;
        assert_eq!(second.0, StatusCode::OK, "{}", second.1);
        assert_eq!(
            first.1["conversation"]["conversationId"],
            second.1["conversation"]["conversationId"]
        );
        // A prepared first message must validate annotation source bytes just
        // like an ordinary Project send. The invalid record must never be
        // accepted for dispatch, even with the exact creation request ID.
        let prepared_id = first.1["conversation"]["conversationId"].as_str().unwrap();
        std::fs::write(source.join("note.txt"), b"current source\n").unwrap();
        let annotation = json!({
            "version": 1, "projectId": "prepare-project", "conversationId": prepared_id,
            "rootId": "workspace", "path": "note.txt", "sourceSha256": "0".repeat(64),
            "anchor": {"kind":"textLines", "startLine":1, "endLine":1},
            "note": "Check this source"
        });
        let upload = crate::upload_conversation_file(
            State(state.clone()),
            Path(prepared_id.to_owned()),
            Json(crate::CreateConversationFileRequest {
                client_upload_id: Some(uuid::Uuid::new_v4().to_string()),
                name: "annotation.json".into(),
                mime_type: Some(crate::artifact_annotations::MIME.into()),
                content_base64: {
                    use base64::Engine as _;
                    base64::engine::general_purpose::STANDARD.encode(annotation.to_string())
                },
            }),
        )
        .await;
        assert_eq!(upload.status(), StatusCode::OK);
        let uploaded: Value = serde_json::from_slice(
            &axum::body::to_bytes(upload.into_body(), 8192)
                .await
                .unwrap(),
        )
        .unwrap();
        let mut invalid_first_send = request.clone();
        invalid_first_send["prepareOnly"] = json!(false);
        invalid_first_send["attachmentIds"] = json!([uploaded["id"]]);
        let rejected = call(
            &state,
            "POST",
            "/api/v1/projects/prepare-project/threads",
            invalid_first_send,
        )
        .await;
        assert_eq!(rejected.0, StatusCode::CONFLICT, "{}", rejected.1);
        assert!(state
            .store
            .message_by_device_and_client_message_id(
                "owner",
                request["clientMessageId"].as_str().unwrap(),
            )
            .await
            .unwrap()
            .is_none());
        let original_model = {
            let mut catalog = state.runtime_catalog.write().await;
            let original = catalog.models[0].clone();
            catalog.models[0].hidden = true;
            catalog.models[0]
                .service_tiers
                .retain(|tier| tier.id == "default");
            original
        };
        let recovered = call(
            &state,
            "POST",
            "/api/v1/projects/prepare-project/threads",
            request.clone(),
        )
        .await;
        assert_eq!(recovered.0, StatusCode::OK, "{}", recovered.1);
        assert_eq!(
            first.1["conversation"]["conversationId"],
            recovered.1["conversation"]["conversationId"]
        );
        let mut conflicting = request.clone();
        conflicting["serviceTier"] = json!("default");
        let conflict = call(
            &state,
            "POST",
            "/api/v1/projects/prepare-project/threads",
            conflicting,
        )
        .await;
        assert_eq!(conflict.0, StatusCode::CONFLICT, "{}", conflict.1);
        state.runtime_catalog.write().await.models[0] = original_model;
        let id = first.1["conversation"]["conversationId"].as_str().unwrap();
        // The HTTP/store boundary preserves omitted effort and clears explicit
        // null when switching to an effort-less model, avoiding a rejected Send.
        let mut effortful = state
            .runtime_catalog
            .read()
            .await
            .models
            .iter()
            .find(|model| model.id == "fake")
            .unwrap()
            .clone();
        effortful.id = "effortful".into();
        effortful.reasoning_efforts = vec![crate::ChoiceOption {
            id: "high".into(),
            label: "High".into(),
            description: None,
        }];
        state.runtime_catalog.write().await.models.push(effortful);
        state
            .store
            .update_project_conversation(
                id,
                ProjectConversationPatch {
                    model: Some("effortful"),
                    effort: Some(Some("high")),
                    ..Default::default()
                },
                "later",
            )
            .await
            .unwrap();
        let path = format!("/api/v1/project-conversations/{id}");
        let preserved = call(&state, "PATCH", &path, json!({"isPinned": false})).await;
        assert_eq!(preserved.0, StatusCode::OK, "{}", preserved.1);
        assert_eq!(preserved.1["effort"], "high");
        let incompatible = call(&state, "PATCH", &path, json!({"model": "fake"})).await;
        assert_eq!(
            incompatible.0,
            StatusCode::UNPROCESSABLE_ENTITY,
            "{}",
            incompatible.1
        );
        let clear = json!({"model": "fake", "effort": null});
        crate::tests::validate_http_contract("updateProjectConversationRequest", &clear);
        let cleared = call(&state, "PATCH", &path, clear).await;
        assert_eq!(cleared.0, StatusCode::OK, "{}", cleared.1);
        assert!(cleared.1["effort"].is_null());
        assert_eq!(cleared.1["serviceTier"], "fast");
        let mut standard_only = state
            .runtime_catalog
            .read()
            .await
            .models
            .iter()
            .find(|model| model.id == "fake")
            .unwrap()
            .clone();
        standard_only.id = "standard-only".into();
        standard_only
            .service_tiers
            .retain(|tier| tier.id == "default");
        state
            .runtime_catalog
            .write()
            .await
            .models
            .push(standard_only);
        let changed = call(&state, "PATCH", &path, json!({"model":"standard-only"})).await;
        assert_eq!(changed.0, StatusCode::OK, "{}", changed.1);
        assert!(
            changed.1["serviceTier"].is_null(),
            "Model changes clear an unsupported speed"
        );
        let unavailable = call(&state, "PATCH", &path, json!({"serviceTier":"fast"})).await;
        assert_eq!(unavailable.0, StatusCode::UNPROCESSABLE_ENTITY);
        assert!(state.store.runtime_binding(id).await.unwrap().is_none());
        assert!(state
            .store
            .project_conversation(id)
            .await
            .unwrap()
            .unwrap()
            .native_session_id
            .is_none());
        let mut stale = request;
        stale["rootsRevision"] = json!(2);
        let rejected = call(
            &state,
            "POST",
            "/api/v1/projects/prepare-project/threads",
            stale,
        )
        .await;
        assert_eq!(rejected.0, StatusCode::CONFLICT);
        // Plan mode is part of the frozen creation request, Claude approval
        // has no meaning for Codex, and pinned threads join the library.
        let planned = json!({"deviceId":"owner", "clientMessageId":uuid::Uuid::new_v4().to_string(),
            "family":"codex", "model":"fake", "body":"Plan first", "rootsRevision":1, "prepareOnly":true, "planMode":true});
        crate::tests::validate_http_contract("createProjectThreadRequest", &planned);
        let created = call(
            &state,
            "POST",
            "/api/v1/projects/prepare-project/threads",
            planned.clone(),
        )
        .await;
        assert_eq!(created.0, StatusCode::OK, "{}", created.1);
        let planned_id = created.1["conversation"]["conversationId"]
            .as_str()
            .unwrap()
            .to_owned();
        let detail_path = format!("/api/v1/project-conversations/{planned_id}");
        let detail = call(&state, "GET", &detail_path, Value::Null).await;
        assert_eq!(detail.0, StatusCode::OK, "{}", detail.1);
        crate::tests::validate_http_contract("projectConversationDetail", &detail.1);
        assert_eq!(detail.1["planMode"], true);
        assert_eq!(detail.1["claudeApproval"], "ask");
        let mut changed = planned.clone();
        changed["planMode"] = json!(false);
        let conflict = call(
            &state,
            "POST",
            "/api/v1/projects/prepare-project/threads",
            changed,
        )
        .await;
        assert_eq!(conflict.0, StatusCode::CONFLICT, "{}", conflict.1);
        let mut codex_approval = planned.clone();
        codex_approval["clientMessageId"] = json!(uuid::Uuid::new_v4().to_string());
        codex_approval["claudeApproval"] = json!("auto");
        let unsupported = call(
            &state,
            "POST",
            "/api/v1/projects/prepare-project/threads",
            codex_approval,
        )
        .await;
        assert_eq!(unsupported.0, StatusCode::UNPROCESSABLE_ENTITY);
        for bad in [
            json!({"claudeApproval": "auto"}),
            json!({"claudeApproval": "yolo"}),
        ] {
            let rejected = call(&state, "PATCH", &detail_path, bad).await;
            assert_eq!(
                rejected.0,
                StatusCode::UNPROCESSABLE_ENTITY,
                "{}",
                rejected.1
            );
        }
        let updated = call(
            &state,
            "PATCH",
            &detail_path,
            json!({"planMode": false, "isPinned": true}),
        )
        .await;
        assert_eq!(updated.0, StatusCode::OK, "{}", updated.1);
        assert_eq!(updated.1["planMode"], false);
        // Retry against the immutable original plan setting after PATCH.
        let retry = call(
            &state,
            "POST",
            "/api/v1/projects/prepare-project/threads",
            planned,
        )
        .await;
        assert_eq!(retry.0, StatusCode::OK, "{}", retry.1);
        assert_eq!(retry.1["conversation"]["conversationId"], planned_id);
        let library = call(&state, "GET", "/api/v1/projects", Value::Null).await;
        assert_eq!(library.0, StatusCode::OK, "{}", library.1);
        crate::tests::validate_http_contract("projectsResponse", &library.1);
        assert_eq!(library.1["modesVersion"], 1);
        assert_eq!(library.1["pinned"][0]["projectId"], "prepare-project");
        assert_eq!(
            library.1["pinned"][0]["thread"]["conversationId"],
            planned_id
        );
        // The project thread never appears in the Bot and Group Chat list.
        let chats = call(&state, "GET", "/api/v1/conversations", Value::Null).await;
        assert_eq!(chats.0, StatusCode::OK, "{}", chats.1);
        assert!(!chats
            .1
            .as_array()
            .unwrap()
            .iter()
            .any(|chat| chat["conversationId"] == planned_id || chat["conversationId"] == id));
        let status = call(&state, "GET", "/api/v1/host/status", Value::Null).await;
        assert_eq!(status.0, StatusCode::OK, "{}", status.1);
        for feature in [FEATURE, crate::computer_sessions::HOST_VIEW_FEATURE] {
            assert!(status.1["features"]
                .as_array()
                .unwrap()
                .contains(&json!(feature)));
        }
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    // An accepted first Send has a durable receipt. Its exact retry must not
    // depend on today's Project visibility, folders or ingestion readiness.
    // A new request and a prepared-only first Send still use those gates.
    #[tokio::test]
    async fn accepted_creation_replays_receipt_after_project_changes() {
        use crate::permission_modes::tests::{call, fixture};
        let (dir, state) = fixture().await;
        let source = dir.path().join("retry-source");
        std::fs::create_dir(&source).unwrap();
        let roots = validate_folders(&[source.to_string_lossy().into_owned()], &[]).unwrap();
        state
            .store
            .create_project(
                "retry-project",
                "request",
                "hash",
                "Retry",
                &roots,
                0,
                "now",
            )
            .await
            .unwrap();
        let project = state.store.project("retry-project").await.unwrap().unwrap();
        let service = crate::ingestion::spawn(state.clone()).await;
        for _ in 0..100 {
            if state.ingestion.project_readiness(&state.store).await.ready {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(state.ingestion.project_readiness(&state.store).await.ready);
        let path = "/api/v1/projects/retry-project/threads";
        let request = json!({"deviceId":"owner", "clientMessageId":uuid::Uuid::new_v4().to_string(),
            "family":"codex", "model":"fake", "body":"Review this folder", "folderId":project.primary_root_id,
            "rootsRevision":1});
        let accepted = call(&state, "POST", path, request.clone()).await;
        assert_eq!(accepted.0, StatusCode::ACCEPTED, "{}", accepted.1);
        let receipt = accepted.1["receipt"].clone();
        assert!(!receipt.is_null());
        let retry = call(&state, "POST", path, request.clone()).await;
        assert_eq!(retry.0, StatusCode::ACCEPTED, "{}", retry.1);
        assert_eq!(retry.1["receipt"], receipt);
        assert_eq!(
            retry.1["conversation"]["conversationId"],
            accepted.1["conversation"]["conversationId"]
        );
        for (key, value) in [
            ("body", json!("A different message")),
            ("model", json!("different-model")),
            ("folderId", json!(uuid::Uuid::new_v4().to_string())),
            ("rootsRevision", json!(2)),
            ("attachmentIds", json!([uuid::Uuid::new_v4().to_string()])),
        ] {
            let mut changed = request.clone();
            changed[key] = value;
            assert_eq!(
                call(&state, "POST", path, changed).await.0,
                StatusCode::CONFLICT,
                "changed {key}"
            );
        }
        let mut fresh = request.clone();
        fresh["clientMessageId"] = json!(uuid::Uuid::new_v4().to_string());

        state
            .store
            .update_project_metadata("retry-project", None, Some(false), None, "later")
            .await
            .unwrap();
        assert_eq!(
            call(&state, "POST", path, request.clone()).await.1["receipt"],
            receipt
        );
        assert_eq!(
            call(&state, "POST", path, fresh.clone()).await.0,
            StatusCode::CONFLICT
        );
        state
            .store
            .update_project_metadata("retry-project", None, Some(true), None, "later")
            .await
            .unwrap();

        state
            .store
            .update_project_roots("retry-project", 1, &roots, 0, "later")
            .await
            .unwrap();
        assert_eq!(
            call(&state, "POST", path, request.clone()).await.1["receipt"],
            receipt
        );
        assert_eq!(
            call(&state, "POST", path, fresh.clone()).await.0,
            StatusCode::PRECONDITION_FAILED
        );
        fresh["rootsRevision"] = json!(2);
        let mut prepared = fresh.clone();
        prepared["clientMessageId"] = json!(uuid::Uuid::new_v4().to_string());
        prepared["prepareOnly"] = json!(true);
        let reservation = call(&state, "POST", path, prepared.clone()).await;
        assert_eq!(reservation.0, StatusCode::OK, "{}", reservation.1);
        assert!(reservation.1["receipt"].is_null());
        std::fs::rename(&source, dir.path().join("moved-source")).unwrap();
        assert_eq!(
            call(&state, "POST", path, request.clone()).await.1["receipt"],
            receipt
        );
        assert_eq!(
            call(&state, "POST", path, fresh.clone()).await.0,
            StatusCode::CONFLICT
        );
        #[cfg(unix)]
        {
            let replacement = dir.path().join("unrelated-source");
            std::fs::create_dir(&replacement).unwrap();
            std::os::unix::fs::symlink(&replacement, &source).unwrap();
            assert_eq!(
                call(&state, "POST", path, fresh.clone()).await.0,
                StatusCode::CONFLICT,
                "A symlink at the original path cannot redirect a new request"
            );
        }

        drop(service);
        for _ in 0..100 {
            if !state.ingestion.project_readiness(&state.store).await.ready {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(!state.ingestion.project_readiness(&state.store).await.ready);
        assert_eq!(
            call(&state, "POST", path, request.clone()).await.1["receipt"],
            receipt
        );
        assert_eq!(
            call(&state, "POST", path, fresh).await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        assert_eq!(
            call(&state, "POST", path, prepared.clone()).await.0,
            StatusCode::OK
        );
        prepared["prepareOnly"] = json!(false);
        assert_eq!(
            call(&state, "POST", path, prepared).await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        state
            .update_admission
            .prepare_update("retry-update", &state)
            .await
            .unwrap();
        let replay_during_update = call(&state, "POST", path, request.clone()).await;
        assert_eq!(
            replay_during_update.0,
            StatusCode::ACCEPTED,
            "{}",
            replay_during_update.1
        );
        assert_eq!(
            replay_during_update.1["receipt"]["wonderMessageId"],
            receipt["wonderMessageId"]
        );
        let mut new_work = request;
        new_work["clientMessageId"] = json!(uuid::Uuid::new_v4().to_string());
        assert_eq!(
            call(&state, "POST", path, new_work).await.0,
            StatusCode::CONFLICT
        );
        assert!(state.update_admission.cancel_lease("retry-update").await);
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    // The provider receives the speed frozen with each accepted message,
    // including after a settings edit and when resuming an existing thread.
    #[tokio::test]
    async fn project_speed_reaches_exact_provider_requests() {
        let (dir, mut state) = crate::permission_modes::tests::fixture().await;
        let source = dir.path().join("project-source");
        std::fs::create_dir(&source).unwrap();
        let roots = validate_folders(&[source.to_string_lossy().into_owned()], &[]).unwrap();
        state
            .store
            .create_project(
                "speed-project",
                "request",
                "hash",
                "Speed",
                &roots,
                0,
                "now",
            )
            .await
            .unwrap();
        state.projects = ProjectRuntime::configured(
            dir.path().join("codex"),
            "test".into(),
            &dir.path().join("home"),
            &dir.path().join("claude"),
            crate::ingestion::notification_sink(state.store.clone()),
        );
        let script = dir.path().join("runtime.py");
        let source_code = std::fs::read_to_string(&script).unwrap().replace(
            "else {'thread':{'status':{'type':'idle'}}}",
            "else {'thread':{'id':'thread','status':{'type':'idle'}}}",
        );
        std::fs::write(script, source_code).unwrap();
        std::fs::write(
            dir.path().join("models.json"),
            json!({"data":[{
                "id":"fake","displayName":"Fake","serviceTiers":[
                    {"id":"default","label":"Standard"},{"id":"fast","label":"Fast"}]
            }]})
            .to_string(),
        )
        .unwrap();
        let mut catalog = state.runtime_catalog.write().await;
        catalog.models[0].service_tiers = vec![
            crate::ChoiceOption {
                id: "default".into(),
                label: "Standard".into(),
                description: None,
            },
            crate::ChoiceOption {
                id: "fast".into(),
                label: "Fast".into(),
                description: None,
            },
        ];
        drop(catalog);
        let conversation = uuid::Uuid::new_v4().to_string();
        state
            .store
            .create_project_conversation(ProjectConversationInsert {
                conversation_id: &conversation,
                project_id: "speed-project",
                family: AgentFamily::Codex,
                provider_store: &state.projects.codex_store,
                native_session_id: None,
                cwd: source.to_str().unwrap(),
                roots_revision: 1,
                title: "Speed",
                model: Some("fake"),
                effort: None,
                service_tier: Some("fast"),
                access_mode: "read_only",
                claude_approval: "ask",
                plan_mode: false,
                creation_request_id: None,
                now: "now",
            })
            .await
            .unwrap();
        let MessageInsert::Inserted(first) = state
            .store
            .insert_dispatch_message(
                "owner",
                "first",
                "first",
                "hash-first",
                &conversation,
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!("first message")
        };
        state
            .store
            .update_project_conversation(
                &conversation,
                ProjectConversationPatch {
                    service_tier: Some(Some("default")),
                    ..Default::default()
                },
                "later",
            )
            .await
            .unwrap();
        assert!(state
            .store
            .claim_message_for_dispatch(&first.id)
            .await
            .unwrap());
        let mut submitting = false;
        dispatch_inner(&state, &first, &mut submitting)
            .await
            .unwrap();
        assert!(submitting);
        state
            .store
            .update_message_delivery(&first.id, "completed", Some("thread"), Some("turn"))
            .await
            .unwrap();
        std::fs::write(dir.path().join("idle-fixture.json"),
            json!({"thread":{"id":"thread","cwd":source,"projectId":"native-project","status":{"type":"idle"}}}).to_string()).unwrap();
        // The second turn selects a preview note through the same immutable
        // attachment path as the native composer. The fake runtime records
        // the exact turn/start payload without starting model work.
        let annotated_source = source.join("annotated.txt");
        std::fs::write(&annotated_source, b"one\ntwo\n").unwrap();
        let annotation = json!({
            "version": 1, "projectId": "speed-project", "conversationId": conversation,
            "rootId": "workspace", "path": "annotated.txt",
            "sourceSha256": hex::encode(Sha256::digest(std::fs::read(&annotated_source).unwrap())),
            "anchor": {"kind":"textLines","startLine":2,"endLine":2},
            "note": "Review line two"
        });
        let upload = crate::upload_conversation_file(
            State(state.clone()),
            Path(conversation.clone()),
            Json(crate::CreateConversationFileRequest {
                client_upload_id: Some(uuid::Uuid::new_v4().to_string()),
                name: "annotation.json".into(),
                mime_type: Some(crate::artifact_annotations::MIME.into()),
                content_base64: {
                    use base64::Engine as _;
                    base64::engine::general_purpose::STANDARD.encode(annotation.to_string())
                },
            }),
        )
        .await;
        assert_eq!(upload.status(), StatusCode::OK);
        let uploaded: Value = serde_json::from_slice(
            &axum::body::to_bytes(upload.into_body(), 8192)
                .await
                .unwrap(),
        )
        .unwrap();
        let annotation_id = uploaded["id"].as_str().unwrap().to_owned();
        let image_bytes = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;".to_vec();
        let media_notes = vec![(
            "marked.gif",
            image_bytes,
            json!({"kind":"imageRegion","x":0.1,"y":0.2,"width":0.3,"height":0.4}),
            "Check image crop",
            "image region (normalized 0-1, origin at top left) x=0.1, y=0.2, width=0.3, height=0.4",
        )];
        #[cfg(target_os = "macos")]
        let media_notes = {
            let mut media_notes = media_notes;
            media_notes.push((
                "marked.pdf",
                two_page_pdf(),
                json!({"kind":"pdfRegion","page":2,"x":0.25,"y":0.5,"width":0.5,"height":0.25}),
                "Check PDF page two",
                "PDF page 2, region (normalized 0-1, origin at top left) x=0.25, y=0.5, width=0.5, height=0.25",
            ));
            media_notes
        };
        let mut selected_ids = vec![annotation_id.clone()];
        let mut media_sources = Vec::new();
        for (name, bytes, anchor, note, _) in &media_notes {
            let source_path = source.join(name);
            std::fs::write(&source_path, bytes).unwrap();
            let record = json!({
                "version":1, "projectId":"speed-project", "conversationId":conversation,
                "rootId":"workspace", "path":name,
                "sourceSha256":hex::encode(Sha256::digest(bytes)), "anchor":anchor, "note":note,
            });
            let upload = crate::upload_conversation_file(
                State(state.clone()),
                Path(conversation.clone()),
                Json(crate::CreateConversationFileRequest {
                    client_upload_id: Some(uuid::Uuid::new_v4().to_string()),
                    name: format!("{name}.annotation.json"),
                    mime_type: Some(crate::artifact_annotations::MIME.into()),
                    content_base64: {
                        use base64::Engine as _;
                        base64::engine::general_purpose::STANDARD.encode(record.to_string())
                    },
                }),
            )
            .await;
            assert_eq!(upload.status(), StatusCode::OK);
            let uploaded: Value = serde_json::from_slice(
                &axum::body::to_bytes(upload.into_body(), 8192)
                    .await
                    .unwrap(),
            )
            .unwrap();
            selected_ids.push(uploaded["id"].as_str().unwrap().to_owned());
            media_sources.push(source_path);
        }
        // A valid PDF container is not enough: a crafted annotation cannot
        // send a region on a page the document does not contain.
        #[cfg(target_os = "macos")]
        {
            let missing_page_record = json!({
                "version":1, "projectId":"speed-project", "conversationId":conversation,
                "rootId":"workspace", "path":"marked.pdf",
                "sourceSha256":hex::encode(Sha256::digest(&media_notes[1].1)),
                "anchor":{"kind":"pdfRegion","page":3,"x":0.25,"y":0.5,"width":0.5,"height":0.25},
                "note":"This page does not exist",
            });
            let upload = crate::upload_conversation_file(
                State(state.clone()),
                Path(conversation.clone()),
                Json(crate::CreateConversationFileRequest {
                    client_upload_id: Some(uuid::Uuid::new_v4().to_string()),
                    name: "missing-page.annotation.json".into(),
                    mime_type: Some(crate::artifact_annotations::MIME.into()),
                    content_base64: {
                        use base64::Engine as _;
                        base64::engine::general_purpose::STANDARD
                            .encode(missing_page_record.to_string())
                    },
                }),
            )
            .await;
            assert_eq!(upload.status(), StatusCode::OK);
            let uploaded: Value = serde_json::from_slice(
                &axum::body::to_bytes(upload.into_body(), 8192)
                    .await
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(
                crate::artifact_annotations::validate_first_acceptance(
                    &state,
                    &conversation,
                    "owner",
                    "invalid-page",
                    &[uploaded["id"].as_str().unwrap().to_owned()],
                )
                .await
                .unwrap_err()
                .0,
                StatusCode::UNPROCESSABLE_ENTITY
            );
        }
        crate::artifact_annotations::validate_first_acceptance(
            &state,
            &conversation,
            "owner",
            "second",
            &selected_ids,
        )
        .await
        .unwrap();
        std::fs::write(&annotated_source, b"changed after acceptance\n").unwrap();
        for source_path in &media_sources {
            std::fs::remove_file(source_path).unwrap();
        }
        let MessageInsert::Inserted(second) = state
            .store
            .insert_dispatch_message(
                "owner",
                "second",
                "second",
                "hash-second",
                &conversation,
                &selected_ids,
                "later",
                true,
            )
            .await
            .unwrap()
        else {
            panic!("second message")
        };
        // The accepted annotation must still dispatch from its frozen copy
        // after an unrelated Project root edit increments roots_revision.
        let unrelated = dir.path().join("unrelated-project-root");
        std::fs::create_dir(&unrelated).unwrap();
        let changed_roots = validate_folders(
            &[
                source.to_string_lossy().into_owned(),
                unrelated.to_string_lossy().into_owned(),
            ],
            &[],
        )
        .unwrap();
        let updated = state
            .store
            .update_project_roots("speed-project", 1, &changed_roots, 0, "after-acceptance")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(updated.roots_revision, 2);
        assert_eq!(
            state
                .store
                .project_conversation(&conversation)
                .await
                .unwrap()
                .unwrap()
                .roots_revision,
            1
        );
        assert!(state
            .store
            .claim_message_for_dispatch(&second.id)
            .await
            .unwrap());
        submitting = false;
        dispatch_inner(&state, &second, &mut submitting)
            .await
            .unwrap();
        assert!(submitting);
        let requests: Vec<Value> = std::fs::read_to_string(dir.path().join("requests-jsonl"))
            .unwrap()
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .collect();
        for (method, expected) in [("thread/start", "fast"), ("thread/resume", "default")] {
            let request = requests
                .iter()
                .find(|request| request["method"] == method)
                .unwrap();
            assert_eq!(request["params"]["serviceTier"], expected, "{method}");
        }
        let turns: Vec<_> = requests
            .iter()
            .filter(|request| request["method"] == "turn/start")
            .collect();
        assert_eq!(turns.len(), 2);
        assert_eq!(turns[0]["params"]["serviceTier"], "fast");
        assert_eq!(turns[1]["params"]["serviceTier"], "default");
        let second_input = turns[1]["params"]["input"].as_array().unwrap();
        assert_eq!(
            second_input.len(),
            2 + media_notes.len(),
            "body plus one text and each supported media note"
        );
        assert_eq!(
            second_input
                .iter()
                .filter(|input| input["text"]
                    .as_str()
                    .is_some_and(|text| text.contains("Review line two")))
                .count(),
            1
        );
        let media = media_workspace(&state, &conversation).await.unwrap();
        let source_copy_id = crate::deterministic_uuid(&format!("artifact-source:{annotation_id}"));
        let source_copy = crate::attachment_path(&media, &source_copy_id, false)
            .await
            .unwrap();
        assert!(second_input.iter().any(|input| input["text"]
            .as_str()
            .is_some_and(|text| text.contains(source_copy.to_str().unwrap())
                && text.contains("Original file: workspace/annotated.txt"))));
        assert_eq!(std::fs::read(&source_copy).unwrap(), b"one\ntwo\n");
        for (index, (name, bytes, _, note, anchor)) in media_notes.iter().enumerate() {
            let copy_id =
                crate::deterministic_uuid(&format!("artifact-source:{}", selected_ids[index + 1]));
            let copy = crate::attachment_path(&media, &copy_id, false)
                .await
                .unwrap();
            assert_eq!(std::fs::read(&copy).unwrap(), *bytes);
            assert_eq!(
                second_input
                    .iter()
                    .filter(|input| input["text"].as_str().is_some_and(|text| text
                        .contains(&format!("Original file: workspace/{name}"))
                        && text.contains(copy.to_str().unwrap())
                        && text.contains(anchor)
                        && text.contains(note)))
                    .count(),
                1,
                "{name} anchor must reach one provider text input"
            );
        }
        assert!(!second_input.iter().any(|input| input["text"]
            .as_str()
            .is_some_and(|text| text.contains("annotation.json"))));
        state.projects.shutdown().await;
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    // The existing upload/storage boundary owns this regression: project
    // uploads must retain verified bytes under their own conversation, without
    // writing into a source folder or following a substituted media symlink.
    #[tokio::test]
    async fn project_attachments_use_owned_verified_storage() {
        use base64::Engine as _;
        let (dir, mut state) = crate::ingestion::tests::fixture().await;
        let bots = dir.path().join("bots");
        std::fs::create_dir(&bots).unwrap();
        state.bots_root = bots.to_string_lossy().into_owned();
        let source = dir.path().join("source");
        std::fs::create_dir(&source).unwrap();
        let roots = validate_folders(&[source.to_string_lossy().into_owned()], &[]).unwrap();
        state
            .store
            .create_project("project", "request", "hash", "Test", &roots, 0, "now")
            .await
            .unwrap();
        let conversation = uuid::Uuid::new_v4().to_string();
        state
            .store
            .create_project_conversation(ProjectConversationInsert {
                conversation_id: &conversation,
                project_id: "project",
                family: AgentFamily::Codex,
                provider_store: "native-home",
                native_session_id: None,
                cwd: source.to_str().unwrap(),
                roots_revision: 1,
                title: "Draft",
                model: None,
                effort: None,
                service_tier: None,
                access_mode: "read_only",
                claude_approval: "ask",
                plan_mode: false,
                creation_request_id: Some("creation"),
                now: "now",
            })
            .await
            .unwrap();
        let upload_id = uuid::Uuid::new_v4().to_string();
        let bytes = b"owned attachment";
        let upload = || crate::CreateConversationFileRequest {
            client_upload_id: Some(upload_id.clone()),
            name: "notes.txt".into(),
            mime_type: Some("text/plain".into()),
            content_base64: base64::engine::general_purpose::STANDARD.encode(bytes),
        };
        let response = crate::upload_conversation_file(
            State(state.clone()),
            Path(conversation.clone()),
            Json(upload()),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let first: Value = serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), 8192)
                .await
                .unwrap(),
        )
        .unwrap();
        let response = crate::upload_conversation_file(
            State(state.clone()),
            Path(conversation.clone()),
            Json(upload()),
        )
        .await;
        let retry: Value = serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), 8192)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(first["id"], retry["id"]);
        assert!(!source.join(".wonder").exists());
        assert!(state
            .store
            .runtime_binding(&conversation)
            .await
            .unwrap()
            .is_none());
        let files = state
            .store
            .list_conversation_files(&conversation)
            .await
            .unwrap();
        assert_eq!(files.len(), 1);
        let media = media_workspace(&state, &conversation).await.unwrap();
        let path = crate::attachment_path(&media, &files[0].id, false)
            .await
            .unwrap();
        assert_eq!(
            crate::group_attachments::verified_bytes(&path, &files[0])
                .await
                .unwrap(),
            bytes
        );
        std::fs::write(&path, b"changed").unwrap();
        let response = crate::upload_conversation_file(
            State(state.clone()),
            Path(conversation.clone()),
            Json(upload()),
        )
        .await;
        assert_eq!(response.status(), StatusCode::CONFLICT);
        #[cfg(unix)]
        {
            std::fs::rename(&media, format!("{media}-original")).unwrap();
            std::os::unix::fs::symlink(&source, &media).unwrap();
            assert!(media_workspace(&state, &conversation).await.is_none());
        }
    }

    // Contract: a Wonder turn never inherits a desktop client's broader policy.
    #[test]
    fn codex_turn_policy_is_always_explicit() {
        let roots = vec!["/work/app".to_owned(), "/work/docs".to_owned()];
        let (sandbox, approval, policy) = codex_policy("workspace", &roots);
        assert_eq!((sandbox, approval), ("workspace-write", "on-request"));
        assert_eq!(policy["writableRoots"], json!(roots));
        assert_eq!(policy["networkAccess"], false);
        assert_eq!(codex_policy("read_only", &roots).2["type"], "readOnly");
        // Unknown stored values fail toward the ordinary workspace boundary.
        assert_eq!(codex_policy("unexpected", &roots).0, "workspace-write");
    }

    // Contract: every Codex turn names its collaboration mode and reasoning
    // effort so leaving plan mode takes effect, and the sandbox and approval
    // policy stay exactly the access mode's.
    #[test]
    fn codex_turn_always_names_its_collaboration_mode() {
        let roots = vec!["/work/app".to_owned()];
        let input = vec![json!({"type": "text", "text": "Hi"})];
        for (plan, effort, expected) in [(false, None, "default"), (true, Some("high"), "plan")] {
            for access in ["read_only", "workspace", "full_access"] {
                let params = codex_turn_params(
                    "thread",
                    "client",
                    &input,
                    &CodexTurn {
                        access_mode: access,
                        roots: &roots,
                        model: "gpt-x",
                        effort,
                        service_tier: Some("default"),
                        cwd: "/work/app",
                        plan,
                    },
                );
                assert_eq!(
                    params["collaborationMode"],
                    json!({"mode": expected, "settings": {"model": "gpt-x",
                        "reasoning_effort": effort, "developer_instructions": null}})
                );
                let (_, approval, sandbox) = codex_policy(access, &roots);
                assert_eq!(params["approvalPolicy"], approval);
                assert_eq!(params["sandboxPolicy"], sandbox);
                assert_eq!(params["model"], "gpt-x");
                assert_eq!(params["effort"], json!(effort));
            }
        }
    }

    // Contract: the bridge policy follows access first. Approval modes refine
    // Workspace only; Read only always asks, Full access never does, and plan
    // mode is independent of both.
    #[test]
    fn claude_policy_maps_access_approval_and_plan() {
        let roots = vec!["/work/app".to_owned(), "/work/docs".to_owned()];
        let denied = vec!["/secrets".to_owned()];
        let policy = |access_mode, approval, plan| {
            claude_policy_value(
                roots.clone(),
                &denied,
                ClaudeModes {
                    access_mode,
                    approval,
                    plan,
                },
                "/work/app",
            )
        };
        for (access, approval, mode, expected, writes) in [
            ("read_only", "auto", "read_only", "ask", false),
            ("read_only", "accept_edits", "read_only", "ask", false),
            ("workspace", "ask", "workspace", "ask", true),
            (
                "workspace",
                "accept_edits",
                "workspace",
                "accept_edits",
                true,
            ),
            ("workspace", "auto", "workspace", "auto", true),
            ("workspace", "unexpected", "workspace", "ask", true),
            ("full_access", "ask", "full_access", "full_access", true),
            ("full_access", "auto", "full_access", "full_access", true),
            ("unexpected", "auto", "workspace", "auto", true),
        ] {
            for plan in [false, true] {
                let value = policy(access, approval, plan);
                assert_eq!(value["mode"], mode, "{access}/{approval}");
                assert_eq!(value["approvalMode"], expected, "{access}/{approval}");
                assert_eq!(value["planMode"], plan);
                assert_eq!(
                    value["writeRoots"],
                    json!(if writes { roots.clone() } else { vec![] })
                );
                assert_eq!(value["workspace"], "/work/app");
                assert_eq!(value["readRoots"], json!(["/"]));
                assert_eq!(value["deniedRoots"], json!(denied));
            }
        }
        assert_eq!(ClaudeModes::default().approval, "ask");
    }

    // Contract: protected locations and whole-home folders cannot become
    // project roots, while an ordinary folder resolves to its canonical path.
    #[test]
    fn project_folders_exclude_protected_locations() {
        let temp = tempfile::tempdir().unwrap();
        let protected = temp.path().join("secrets");
        let project = temp.path().join("app");
        std::fs::create_dir_all(protected.join("inner")).unwrap();
        std::fs::create_dir_all(&project).unwrap();
        let denied = vec![protected.to_string_lossy().into_owned()];
        assert!(validate_folder(project.to_str().unwrap(), &denied).is_ok());
        assert!(validate_folder(protected.join("inner").to_str().unwrap(), &denied).is_err());
        assert!(validate_folder(temp.path().to_str().unwrap(), &denied).is_err());
        assert!(validate_folder("relative", &denied).is_err());
        assert!(validate_folder(temp.path().join("missing").to_str().unwrap(), &denied).is_err());
        let roots = validate_folders(
            &[
                project.to_string_lossy().into_owned(),
                format!("{}/", project.display()),
            ],
            &denied,
        )
        .unwrap();
        assert_eq!(roots.len(), 1);
        #[cfg(unix)]
        {
            let linked = temp.path().join("linked");
            let replacement = temp.path().join("other");
            std::fs::create_dir(&replacement).unwrap();
            std::os::unix::fs::symlink(&project, &linked).unwrap();
            let selected = validate_folder(linked.to_str().unwrap(), &denied).unwrap();
            let stored = StoredProject {
                id: "p".into(),
                name: "Project".into(),
                is_included: true,
                pin_order: None,
                primary_root_id: "r".into(),
                roots_revision: 1,
                last_family: None,
                created_at: "now".into(),
                updated_at: "now".into(),
                last_used_at: None,
                roots: vec![wonder_store::StoredProjectRoot {
                    id: "r".into(),
                    path: selected.path.clone(),
                    canonical_path: selected.canonical_path.clone(),
                    ordinal: 0,
                }],
            };
            assert!(validate_execution_roots(&stored, &denied).is_ok());
            std::fs::remove_file(&linked).unwrap();
            std::os::unix::fs::symlink(&replacement, &linked).unwrap();
            let current = validate_folder(linked.to_str().unwrap(), &denied).unwrap();
            assert_ne!(selected.canonical_path, current.canonical_path);
            assert!(validate_execution_roots(&stored, &denied).is_err());
            std::fs::remove_file(&linked).unwrap();
            std::os::unix::fs::symlink(&protected, &linked).unwrap();
            assert!(validate_folder(linked.to_str().unwrap(), &denied).is_err());
        }
    }
}
