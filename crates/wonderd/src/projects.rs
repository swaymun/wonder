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

/// The normal-home Codex client for project threads. It starts on first use so
/// a Mac that never opens Projects runs no additional provider process.
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

pub(crate) async fn codex_rpc(state: &AppState) -> Result<RpcClient, String> {
    let runtime = &state.projects;
    let _start = runtime.start.lock().await;
    let mut client = runtime.codex.lock().await;
    if !client.health().is_alive() {
        client.restart(runtime.config.clone()).await.map_err(|_| {
            "Codex could not start on your Mac. Check that ChatGPT is installed and signed in."
                .to_owned()
        })?;
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
    access_mode: String,
    claude_approval: String,
    plan_mode: bool,
    working_folder: String,
    working_folder_name: String,
    is_pinned: bool,
    has_unread: bool,
    has_native_session: bool,
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
        access_mode: conversation.access_mode.clone(),
        claude_approval: conversation.claude_approval.clone(),
        plan_mode: conversation.plan_mode,
        working_folder: conversation.cwd.clone(),
        working_folder_name: folder_name(&conversation.cwd),
        is_pinned: conversation.is_pinned,
        has_unread: conversation.has_unread,
        has_native_session: conversation.native_session_id.is_some(),
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
fn validate_execution_roots(
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
    for conversation in &pinned {
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
        for conversation in attached
            .iter()
            .filter(|c| c.is_pinned || c.native_session_id.is_none())
        {
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
    has_unread: Option<bool>,
    model: Option<String>,
    #[serde(default, deserialize_with = "patch_effort")]
    effort: Option<Option<String>>,
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
) -> Result<(), &'static str> {
    let Some(model) = model else {
        return effort.map_or(Ok(()), |_| {
            Err("Choose a model before changing its effort.")
        });
    };
    let option = catalog
        .models
        .iter()
        .find(|m| m.id == model && m.agent_family == family)
        .ok_or("This model is not available for this conversation.")?;
    if let Some(effort) = effort {
        if !option.reasoning_efforts.iter().any(|e| e.id == effort) {
            return Err("This model does not support that effort.");
        }
    }
    Ok(())
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
    if request.model.is_some() || request.effort.is_some() {
        let model = request.model.as_deref().or(existing.model.as_deref());
        if let Err(message) = validate_model(
            &*state.runtime_catalog.read().await,
            existing.family,
            model,
            request
                .effort
                .as_ref()
                .map_or(existing.effort.as_deref(), |effort| effort.as_deref()),
        ) {
            return error(StatusCode::UNPROCESSABLE_ENTITY, message);
        }
    }
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
    match state
        .store
        .update_project_conversation(
            &id,
            ProjectConversationPatch {
                title: request.title.as_deref(),
                pinned: request.is_pinned,
                unread: request.has_unread,
                model: request.model.as_deref(),
                effort: request.effort.as_ref().map(|effort| effort.as_deref()),
                access_mode: request.access_mode.as_deref(),
                claude_approval: request.claude_approval.as_deref(),
                plan_mode: request.plan_mode,
            },
            &now_text(),
        )
        .await
    {
        Ok(Some(conversation)) => match conversation_detail(&state, &conversation).await {
            Ok(detail) => Json(detail).into_response(),
            Err(message) => error(StatusCode::SERVICE_UNAVAILABLE, message),
        },
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
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
    if request.family == AgentFamily::Claude && state.claude.is_none() {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "Claude is not installed. Update Wonder on your Mac.",
        );
    }
    if let Err(message) = validate_model(
        &*state.runtime_catalog.read().await,
        request.family,
        Some(&request.model),
        request.effort.as_deref(),
    ) {
        return error(StatusCode::UNPROCESSABLE_ENTITY, message);
    }
    let readiness = state.ingestion.project_readiness(&state.store).await;
    if !readiness.ready {
        return error(StatusCode::SERVICE_UNAVAILABLE, readiness.detail);
    }
    let Ok(Some(project)) = state.store.project(&id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
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
    if !FsPath::new(&root.canonical_path).is_dir() {
        return error(
            StatusCode::CONFLICT,
            "This project folder is no longer available on your Mac. Edit the project.",
        );
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
    let created = state
        .store
        .create_project_conversation(ProjectConversationInsert {
            conversation_id: &uuid::Uuid::new_v4().to_string(),
            project_id: &project.id,
            family: request.family,
            provider_store: provider_store(&state, request.family),
            native_session_id: None,
            cwd: &root.path,
            roots_revision: project.roots_revision,
            title: &title,
            model: Some(&request.model),
            effort: request.effort.as_deref(),
            access_mode: &request.access_mode,
            claude_approval: request.claude_approval.as_deref().unwrap_or("ask"),
            plan_mode: request.plan_mode,
            creation_request_id: Some(&request.client_message_id),
            now: &now,
        })
        .await;
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
    let body_sha256 = hex::encode(Sha256::digest(request.body.as_bytes()));
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
        "model": turn.model, "effort": turn.effort, "cwd": turn.cwd,
        "approvalPolicy": approval, "sandboxPolicy": sandbox_policy, "runtimeWorkspaceRoots": turn.roots,
        "collaborationMode": {"mode": if turn.plan { "plan" } else { "default" },
            "settings": {"model": turn.model, "reasoning_effort": turn.effort, "developer_instructions": null}}})
}

struct CodexTurn<'a> {
    access_mode: &'a str,
    roots: &'a [String],
    model: &'a str,
    effort: Option<&'a str>,
    cwd: &'a str,
    plan: bool,
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
    let guard = state.dispatch_lock.lock().await;
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
            crate::drain_pending_app_server_notifications(&state, &thread_id, &turn_id).await;
            publish_message_state(
                &state,
                &message,
                DeliveryState::AcceptedByCodex,
                Some(&thread_id),
                Some(&turn_id),
            )
            .await;
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
    let project = state
        .store
        .project(&conversation.project_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("This project is unavailable.")?;
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
    let model = conversation
        .model
        .clone()
        .or_else(|| default_model(&catalog, conversation.family))
        .ok_or("Choose a model for this thread.")?;
    validate_model(
        &catalog,
        conversation.family,
        Some(&model),
        conversation.effort.as_deref(),
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
                "cwd": conversation.cwd, "projectId": project_id, "model": model, "sandbox": sandbox,
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
                    "cwd": conversation.cwd, "model": model,
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
    let input = crate::turn_input(&message.body, &media, &files);
    let context = json!({
        "schemaVersion": 1, "scope": "projects", "projectId": project.id, "rootsRevision": project.roots_revision,
        "workingDirectory": conversation.cwd, "model": model, "effort": conversation.effort,
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
                effort: conversation.effort.as_deref(),
                cwd: &conversation.cwd,
                plan: conversation.plan_mode,
            },
        ),
        AgentFamily::Claude => {
            json!({"threadId": thread_id, "clientUserMessageId": message.client_message_id,
            "input": input, "model": model, "effort": conversation.effort,
            "wonderPolicy": permission,
            "wonderProject": claude_project(&project, &conversation.cwd)})
        }
    };
    let started = result(&rpc, "turn/start", params).await?;
    let turn = started
        .pointer("/turn/id")
        .or_else(|| started.get("turnId"))
        .and_then(Value::as_str)
        .ok_or("The provider returned no message receipt")?
        .to_owned();
    Ok((thread_id, turn, rpc.health().id().to_owned()))
}

/// Settle project turns whose runtime generation ended (daemon restart,
/// provider exit). Completed native turns are projected; anything else is
/// uncertain for the owner to review, never resent automatically.
pub(crate) async fn recover(state: &AppState) {
    let Ok(messages) = state.store.active_runtime_messages().await else {
        return;
    };
    for message in messages {
        if message.state == "uncertain" {
            continue;
        }
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
        if accepted.is_some()
            && current
                .as_ref()
                .is_some_and(|h| h.is_alive() && Some(h.id()) == accepted.as_deref())
        {
            continue;
        }
        let Ok(rpc) = rpc_for(state, conversation.family).await else {
            continue;
        };
        let Ok(page) = result(&rpc, "thread/turns/list", json!({"threadId": thread, "limit": 20, "sortDirection": "desc", "itemsView": "notLoaded"})).await else {
            continue;
        };
        let status = page
            .get("data")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .find(|t| t.get("id").and_then(Value::as_str) == Some(turn.as_str()))
            .and_then(|t| t.get("status").and_then(Value::as_str))
            .map(str::to_owned);
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
                crate::process_app_server_notification(state, json!({"method": "turn/completed",
                    "params": {"threadId": thread, "turnId": turn, "turn": {"id": turn, "status": status}}}), false).await;
            }
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
mod tests {
    use super::*;

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
            access_mode: "workspace".into(),
            claude_approval: "accept_edits".into(),
            plan_mode: true,
            working_folder: "/work/app".into(),
            working_folder_name: "app".into(),
            is_pinned: false,
            has_unread: false,
            has_native_session: true,
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
            "family":"codex", "model":"fake", "body":"First message", "rootsRevision":1, "prepareOnly":true});
        crate::tests::validate_http_contract("createProjectThreadRequest", &request);
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
        assert_eq!(rejected.0, StatusCode::PRECONDITION_FAILED);
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
