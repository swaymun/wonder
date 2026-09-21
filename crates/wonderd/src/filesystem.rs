//! Authenticated metadata browsing for choosing Mac file-access locations.
use crate::{AppState, OwnerAuthority};
use axum::{
    extract::{Extension, Path as AxumPath, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
#[cfg(unix)]
use std::os::unix::{
    ffi::OsStrExt,
    fs::OpenOptionsExt,
    io::{AsRawFd, FromRawFd},
};
use std::{
    ffi::{CStr, CString},
    fs, io,
    io::Read,
    path::{Path, PathBuf},
    time::Duration,
};
use wonder_store::StoredConversationFile;

const PAGE_SIZE: usize = 200;
const MAX_ENTRIES: usize = 20_000;
const MAX_WORKSPACE_FILE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_DIFF_BYTES: usize = 1024 * 1024;
const TOO_MANY_ENTRIES_DETAIL: &str =
    "This folder has too many entries to browse. Open a more specific subfolder.";
static BROWSE_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct BrowseQuery {
    path: Option<String>,
    #[serde(default)]
    show_hidden: bool,
    #[serde(default)]
    offset: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DirectoryPage {
    path: String,
    parent_path: Option<String>,
    entries: Vec<DirectoryEntry>,
    next_offset: Option<usize>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DirectoryEntry {
    name: String,
    path: String,
    is_directory: bool,
}

type BrowseError = (StatusCode, &'static str);

fn too_many_entries_error() -> BrowseError {
    (StatusCode::PAYLOAD_TOO_LARGE, TOO_MANY_ENTRIES_DETAIL)
}

pub(super) async fn browse(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Query(query): Query<BrowseQuery>,
) -> Response {
    let path = match query.path {
        Some(path) if path.is_empty() || !Path::new(&path).is_absolute() => {
            return (
                StatusCode::BAD_REQUEST,
                "Choose an absolute Mac folder path.",
            )
                .into_response();
        }
        Some(path) => PathBuf::from(path),
        None => match std::env::var_os("HOME") {
            Some(home) => PathBuf::from(home),
            None => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Your Mac home folder is unavailable.",
                )
                    .into_response()
            }
        },
    };
    if query.offset > MAX_ENTRIES {
        return (
            StatusCode::BAD_REQUEST,
            "This folder page is invalid. Reload the folder.",
        )
            .into_response();
    }
    let permit = match BROWSE_SLOTS.try_acquire() {
        Ok(permit) => permit,
        Err(_) => {
            return (
                StatusCode::TOO_MANY_REQUESTS,
                "Folders are still loading. Try again shortly.",
            )
                .into_response()
        }
    };
    let task = tokio::task::spawn_blocking(move || {
        // Keep the slot until disk work ends, even if the request is cancelled.
        let _permit = permit;
        list_directory(
            &path,
            &state.denied_roots,
            query.show_hidden,
            query.offset,
            MAX_ENTRIES,
        )
    });
    match tokio::time::timeout(Duration::from_secs(10), task).await {
        Ok(Ok(Ok(page))) => Json(page).into_response(),
        Ok(Ok(Err(error))) => error.into_response(),
        Ok(Err(_)) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "This folder could not be loaded. Try again.",
        )
            .into_response(),
        Err(_) => (
            StatusCode::GATEWAY_TIMEOUT,
            "This folder is taking too long to respond. Check that its disk is connected.",
        )
            .into_response(),
    }
}

fn disk_error(error: io::Error) -> BrowseError {
    match error.kind() {
        io::ErrorKind::NotFound => (
            StatusCode::NOT_FOUND,
            "This folder is no longer available on your Mac.",
        ),
        io::ErrorKind::PermissionDenied => (
            StatusCode::FORBIDDEN,
            "Your Mac does not allow Wonder to browse this folder.",
        ),
        io::ErrorKind::InvalidInput | io::ErrorKind::NotADirectory => {
            (StatusCode::BAD_REQUEST, "Choose an existing Mac folder.")
        }
        _ => (
            StatusCode::SERVICE_UNAVAILABLE,
            "This folder could not be read. Check that its disk is available.",
        ),
    }
}

/// Resolve existing ancestors too: a protected folder may not exist yet, and
/// /var versus /private/var must not change its protection when it appears.
pub(super) fn protected_root(path: &Path) -> Result<PathBuf, BrowseError> {
    if !path.is_absolute() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "Protected Mac locations could not be checked.",
        ));
    }
    let mut existing = path;
    let mut tail = Vec::new();
    loop {
        match fs::canonicalize(existing) {
            Ok(mut canonical) => {
                for part in tail.into_iter().rev() {
                    canonical.push(part);
                }
                return Ok(canonical);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let Some(name) = existing.file_name() else {
                    return Err(disk_error(error));
                };
                tail.push(name.to_os_string());
                existing = existing.parent().ok_or((
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Protected Mac locations could not be checked.",
                ))?;
            }
            Err(_) => {
                return Err((
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Protected Mac locations could not be checked.",
                ))
            }
        }
    }
}

fn list_directory(
    path: &Path,
    denied_roots: &[String],
    show_hidden: bool,
    offset: usize,
    max_entries: usize,
) -> Result<DirectoryPage, BrowseError> {
    if path.to_str().is_none() {
        return Err((
            StatusCode::BAD_REQUEST,
            "This folder name cannot be displayed. Choose another folder.",
        ));
    }
    let denied = denied_roots
        .iter()
        .map(|root| protected_root(Path::new(root)))
        .collect::<Result<Vec<_>, _>>()?;
    let canonical = fs::canonicalize(path).map_err(disk_error)?;
    let protected = |path: &Path| denied.iter().any(|root| path.starts_with(root));
    if protected(&canonical) {
        return Err((
            StatusCode::FORBIDDEN,
            "This location is protected by Wonder.",
        ));
    }
    if !fs::metadata(&canonical).map_err(disk_error)?.is_dir() {
        return Err((StatusCode::BAD_REQUEST, "Choose a folder to browse."));
    }
    let canonical_string = canonical
        .to_str()
        .ok_or((
            StatusCode::BAD_REQUEST,
            "This folder name cannot be displayed. Choose another folder.",
        ))?
        .to_owned();
    let mut entries = Vec::new();
    for (index, entry) in fs::read_dir(&canonical).map_err(disk_error)?.enumerate() {
        if index >= max_entries {
            return Err(too_many_entries_error());
        }
        let entry = entry.map_err(disk_error)?;
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if !show_hidden && name.starts_with('.') {
            continue;
        }
        let target = match fs::canonicalize(entry.path()) {
            Ok(target) => target,
            Err(_) => continue,
        };
        if protected(&target) {
            continue;
        }
        let Some(target_string) = target.to_str() else {
            continue;
        };
        let metadata = match fs::metadata(&target) {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        if !metadata.is_file() && !metadata.is_dir() {
            continue;
        }
        entries.push(DirectoryEntry {
            name,
            path: target_string.to_owned(),
            is_directory: metadata.is_dir(),
        });
    }
    entries.sort_by_cached_key(|entry| {
        (
            !entry.is_directory,
            entry.name.to_lowercase(),
            entry.name.clone(),
        )
    });
    let next_offset =
        (entries.len() > offset.saturating_add(PAGE_SIZE)).then(|| offset + PAGE_SIZE);
    let entries = entries.into_iter().skip(offset).take(PAGE_SIZE).collect();
    Ok(DirectoryPage {
        path: canonical_string,
        parent_path: canonical
            .parent()
            .filter(|parent| !protected(parent))
            .and_then(Path::to_str)
            .map(str::to_owned),
        entries,
        next_offset,
    })
}

// -------------------------------------------------------------------------
// Conversation-scoped workspace browser
// -------------------------------------------------------------------------

#[derive(Clone, Debug)]
struct WorkspaceRoot {
    id: String,
    label: String,
    path: PathBuf,
    is_directory: bool,
    kind: &'static str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceRootResponse {
    id: String,
    label: String,
    path: String,
    is_directory: bool,
    kind: &'static str,
    read_only: bool,
    byte_size: Option<u64>,
    mime_type: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceRootsResponse {
    available: bool,
    detail: Option<String>,
    roots: Vec<WorkspaceRootResponse>,
    attachments: Vec<serde_json::Value>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceEntry {
    name: String,
    path: String,
    is_directory: bool,
    byte_size: Option<u64>,
    mime_type: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceDirectoryPage {
    root_id: String,
    path: String,
    parent_path: Option<String>,
    entries: Vec<WorkspaceEntry>,
    next_offset: Option<usize>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceGitChange {
    path: String,
    original_path: Option<String>,
    state: String,
    index_status: String,
    worktree_status: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceGitStatusResponse {
    available: bool,
    detail: Option<String>,
    repository_path: Option<String>,
    changes: Vec<WorkspaceGitChange>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceDiffResponse {
    path: String,
    staged: bool,
    diff: String,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct WorkspaceQuery {
    root: Option<String>,
    path: Option<String>,
    #[serde(default)]
    show_hidden: bool,
    #[serde(default)]
    offset: usize,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct WorkspaceDiffQuery {
    root: Option<String>,
    path: Option<String>,
    #[serde(default)]
    staged: bool,
}

fn workspace_error(status: StatusCode, message: impl Into<String>) -> Response {
    (status, message.into()).into_response()
}

fn canonical_existing(path: &Path) -> Result<(PathBuf, fs::Metadata), BrowseError> {
    let canonical = fs::canonicalize(path).map_err(disk_error)?;
    let metadata = fs::symlink_metadata(&canonical).map_err(disk_error)?;
    if !metadata.is_file() && !metadata.is_dir() {
        return Err((
            StatusCode::FORBIDDEN,
            "Special files cannot be opened in Wonder.",
        ));
    }
    Ok((canonical, metadata))
}

fn denied_paths(denied_roots: &[String]) -> Result<Vec<PathBuf>, BrowseError> {
    denied_roots
        .iter()
        .map(|root| protected_root(Path::new(root.strip_suffix("/**").unwrap_or(root))))
        .collect()
}

fn protected_by_denies(path: &Path, denied: &[PathBuf], own_workspace: Option<&Path>) -> bool {
    denied.iter().any(|root| {
        let authorized_exception = own_workspace.is_some_and(|workspace| {
            // A broad daemon/data-root deny may contain the explicitly
            // authorized workspace. A deny nested inside that workspace must
            // still win; otherwise a protected child would be re-authorized.
            path.starts_with(workspace) && workspace.starts_with(root)
        });
        path.starts_with(root) && !authorized_exception
    })
}

fn add_root(
    roots: &mut Vec<WorkspaceRoot>,
    id: impl Into<String>,
    label: impl Into<String>,
    path: &Path,
    kind: &'static str,
    denied: &[PathBuf],
    own_workspace: Option<&Path>,
) -> Result<(), String> {
    let (canonical, metadata) = canonical_existing(path).map_err(|(_, message)| message)?;
    if protected_by_denies(&canonical, denied, own_workspace) {
        return Err("This location is protected by Wonder.".into());
    }
    if roots.iter().any(|root| root.path == canonical) {
        return Ok(());
    }
    roots.push(WorkspaceRoot {
        id: id.into(),
        label: label.into(),
        path: canonical,
        is_directory: metadata.is_dir(),
        kind,
    });
    Ok(())
}

fn applied_grant_label(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

fn child_cwd(thread: &serde_json::Value) -> Option<PathBuf> {
    thread
        .get("cwd")
        .or_else(|| thread.get("workingDirectory"))
        .or_else(|| thread.get("working_directory"))
        .and_then(serde_json::Value::as_str)
        .filter(|path| Path::new(path).is_absolute())
        .map(PathBuf::from)
}

fn attachment_summary(file: StoredConversationFile) -> serde_json::Value {
    serde_json::json!({
        "id": file.id,
        "kind": file.kind,
        "name": file.name,
        "mimeType": file.mime_type,
        "byteSize": file.byte_size,
        "sha256": file.sha256,
        "relativePath": file.relative_path,
        "state": file.state,
        "updatedAt": file.updated_at,
        "createdAt": file.created_at,
        "additions": file.additions,
        "deletions": file.deletions,
    })
}

async fn conversation_workspace_roots(
    state: &crate::AppState,
    conversation_id: &str,
) -> Result<(Vec<WorkspaceRoot>, Vec<StoredConversationFile>), (StatusCode, String)> {
    let denied = denied_paths(&state.denied_roots)
        .map_err(|(_, message)| (StatusCode::SERVICE_UNAVAILABLE, message.to_owned()))?;
    let ownership = state
        .store
        .subagent_ownership_for_conversation(conversation_id)
        .await
        .map_err(|error| (StatusCode::SERVICE_UNAVAILABLE, error.to_string()))?;
    let bot = crate::bot_for_conversation(state, conversation_id)
        .await
        .map_err(|error| (StatusCode::SERVICE_UNAVAILABLE, error.to_string()))?
        .ok_or((
            StatusCode::NOT_FOUND,
            "This conversation is unavailable.".to_owned(),
        ))?;
    let own_workspace = canonical_existing(Path::new(&bot.workspace_path))
        .map_err(|(_, message)| (StatusCode::SERVICE_UNAVAILABLE, message.to_owned()))?
        .0;
    let group_id = state
        .store
        .group_id_for_conversation(conversation_id)
        .await
        .map_err(|error| (StatusCode::SERVICE_UNAVAILABLE, error.to_string()))?;
    // Group roots are intentionally independent of the coordinator Bot's
    // file-access grants. Children need grants only to validate their own
    // verified cwd, never to expose those parent roots.
    let access = if ownership.is_some() || group_id.is_none() {
        state
            .store
            .bot_file_access(&bot.id)
            .await
            .map_err(|error| (StatusCode::SERVICE_UNAVAILABLE, error.to_string()))?
    } else {
        Default::default()
    };
    let grant_roots = if access.revision == access.applied_revision {
        access
            .read_roots
            .iter()
            .chain(access.write_roots.iter())
            .map(|path| {
                canonical_existing(Path::new(path))
                    .map(|(canonical, _)| canonical)
                    .map_err(|(_, message)| (StatusCode::SERVICE_UNAVAILABLE, message.to_owned()))
            })
            .collect::<Result<Vec<_>, _>>()?
    } else {
        Vec::new()
    };
    let mut roots = Vec::new();

    if ownership.is_some() {
        // The child is a verified runtime descendant, not an arbitrary thread
        // id supplied by the phone. Resolve its current cwd from thread/read
        // and do not fall back to the parent Bot's cwd.
        let child = crate::subagents::runtime_for_conversation(state, conversation_id)
            .await
            .map_err(|error| (StatusCode::SERVICE_UNAVAILABLE, error))?
            .ok_or((StatusCode::SERVICE_UNAVAILABLE, "This child workspace is unavailable. Reopen the parent chat and update Wonder on your Mac.".to_owned()))?;
        let cwd = child_cwd(&child.thread).ok_or((
            StatusCode::SERVICE_UNAVAILABLE,
            "This child did not provide a verified working directory.".to_owned(),
        ))?;
        let (canonical, metadata) = canonical_existing(&cwd)
            .map_err(|(_, message)| (StatusCode::SERVICE_UNAVAILABLE, message.to_owned()))?;
        let full_access = bot.effective_permission_profile() == ":danger-full-access";
        if !metadata.is_dir()
            || protected_by_denies(&canonical, &denied, Some(&own_workspace))
            || !(full_access
                || canonical.starts_with(&own_workspace)
                || grant_roots.iter().any(|grant| canonical.starts_with(grant)))
        {
            return Err((
                StatusCode::FORBIDDEN,
                "This child working directory is outside the conversation's verified access."
                    .into(),
            ));
        }
        add_root(
            &mut roots,
            "child-cwd",
            "Workspace",
            &canonical,
            "childWorkingDirectory",
            &denied,
            Some(&own_workspace),
        )
        .map_err(|message| (StatusCode::FORBIDDEN, message))?;
    } else if let Some(group_id) = group_id.as_deref() {
        let config = state
            .store
            .collaboration_config(group_id)
            .await
            .map_err(|error| (StatusCode::SERVICE_UNAVAILABLE, error.to_string()))?
            .and_then(|value| serde_json::from_str::<serde_json::Value>(&value).ok());
        let shared = config
            .and_then(|value| {
                value
                    .get("workspace")
                    .and_then(serde_json::Value::as_str)
                    .map(PathBuf::from)
            })
            .ok_or((
                StatusCode::SERVICE_UNAVAILABLE,
                "This Group Chat has no verified shared workspace.".to_owned(),
            ))?;
        let shared_canonical = canonical_existing(&shared)
            .map_err(|(_, message)| (StatusCode::SERVICE_UNAVAILABLE, message.to_owned()))?
            .0;
        add_root(
            &mut roots,
            "shared-workspace",
            "Workspace",
            &shared_canonical,
            "groupWorkspace",
            &denied,
            Some(&shared_canonical),
        )
        .map_err(|message| (StatusCode::FORBIDDEN, message))?;
    } else {
        add_root(
            &mut roots,
            "workspace",
            "Workspace",
            Path::new(bot.execution_directory()),
            "workingDirectory",
            &denied,
            Some(&own_workspace),
        )
        .map_err(|message| (StatusCode::FORBIDDEN, message))?;
    }

    if ownership.is_none() && group_id.is_none() && access.revision == access.applied_revision {
        for (index, canonical) in grant_roots.iter().enumerate() {
            if canonical == &own_workspace {
                continue;
            }
            if protected_by_denies(canonical, &denied, Some(&own_workspace))
                && !canonical.starts_with(&own_workspace)
            {
                continue;
            }
            add_root(
                &mut roots,
                format!("grant-{index}"),
                applied_grant_label(canonical),
                canonical,
                "appliedGrant",
                &denied,
                Some(&own_workspace),
            )
            .map_err(|message| (StatusCode::FORBIDDEN, message))?;
        }
    }
    let attachments = state
        .store
        .list_conversation_files(conversation_id)
        .await
        .map_err(|error| (StatusCode::SERVICE_UNAVAILABLE, error.to_string()))?;
    Ok((roots, attachments))
}

fn root_for<'a>(roots: &'a [WorkspaceRoot], id: &str) -> Result<&'a WorkspaceRoot, BrowseError> {
    roots.iter().find(|root| root.id == id).ok_or((
        StatusCode::NOT_FOUND,
        "This workspace location is no longer available.",
    ))
}

fn relative_path(value: Option<&str>) -> Result<PathBuf, BrowseError> {
    let value = value.unwrap_or_default();
    if value.contains('\0') || Path::new(value).is_absolute() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Choose a file inside this workspace.",
        ));
    }
    let mut relative = PathBuf::new();
    for component in Path::new(value).components() {
        match component {
            std::path::Component::Normal(component) => relative.push(component),
            std::path::Component::CurDir => {}
            _ => return Err((StatusCode::BAD_REQUEST, "This workspace path is invalid.")),
        }
    }
    Ok(relative)
}

fn resolve_workspace_path(
    root: &WorkspaceRoot,
    relative: &Path,
    denied: &[PathBuf],
    own_workspace: Option<&Path>,
    allow_missing_leaf: bool,
) -> Result<PathBuf, BrowseError> {
    let lexical = root.path.join(relative);
    let canonical = match fs::canonicalize(&lexical) {
        Ok(path) => path,
        Err(error) if allow_missing_leaf && error.kind() == io::ErrorKind::NotFound => {
            let parent = lexical
                .parent()
                .ok_or((StatusCode::BAD_REQUEST, "This workspace path is invalid."))?;
            let parent = fs::canonicalize(parent).map_err(disk_error)?;
            parent.join(
                lexical
                    .file_name()
                    .ok_or((StatusCode::BAD_REQUEST, "This workspace path is invalid."))?,
            )
        }
        Err(error) => return Err(disk_error(error)),
    };
    let canonical_root = fs::canonicalize(&root.path).map_err(disk_error)?;
    if !canonical.starts_with(&canonical_root)
        || protected_by_denies(&canonical, denied, own_workspace)
    {
        return Err((
            StatusCode::FORBIDDEN,
            "This path is outside the conversation's verified workspace.",
        ));
    }
    let mut cursor = canonical_root;
    for component in relative.components() {
        cursor.push(component.as_os_str());
        let metadata = match fs::symlink_metadata(&cursor) {
            Ok(metadata) => metadata,
            Err(error) if allow_missing_leaf && error.kind() == io::ErrorKind::NotFound => break,
            Err(error) => return Err(disk_error(error)),
        };
        if metadata.file_type().is_symlink() {
            return Err((
                StatusCode::FORBIDDEN,
                "Symlinks cannot be opened in Wonder.",
            ));
        }
        if !metadata.is_file() && !metadata.is_dir() {
            return Err((
                StatusCode::FORBIDDEN,
                "Special files cannot be opened in Wonder.",
            ));
        }
    }
    Ok(canonical)
}

#[cfg(unix)]
fn secure_open_error(error: io::Error) -> BrowseError {
    match error.raw_os_error() {
        Some(code) if code == libc::ELOOP => (
            StatusCode::FORBIDDEN,
            "Symlinks cannot be opened in Wonder.",
        ),
        Some(code) if code == libc::ENOTDIR => {
            (StatusCode::BAD_REQUEST, "Choose a folder or regular file.")
        }
        _ => disk_error(error),
    }
}

#[cfg(unix)]
fn openat_directory(parent: &fs::File, name: &std::ffi::OsStr) -> Result<fs::File, BrowseError> {
    let name = CString::new(name.as_bytes()).map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            "This workspace path contains an invalid name.",
        )
    })?;
    let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            metadata.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(secure_open_error(io::Error::last_os_error()));
    }
    let metadata = unsafe { metadata.assume_init() };
    let kind = metadata.st_mode as libc::mode_t & libc::S_IFMT;
    if kind == libc::S_IFLNK {
        return Err((
            StatusCode::FORBIDDEN,
            "Symlinks cannot be opened in Wonder.",
        ));
    }
    if kind != libc::S_IFDIR {
        return Err((StatusCode::BAD_REQUEST, "Choose a folder to browse."));
    }
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        return Err(secure_open_error(io::Error::last_os_error()));
    }
    Ok(unsafe { fs::File::from_raw_fd(fd) })
}

#[cfg(unix)]
fn open_directory_nofollow(path: &Path) -> Result<fs::File, BrowseError> {
    if !path.is_absolute() {
        return Err((
            StatusCode::BAD_REQUEST,
            "This workspace path must be absolute.",
        ));
    }
    let mut options = fs::OpenOptions::new();
    options.read(true);
    options.custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let mut directory = options.open(Path::new("/")).map_err(secure_open_error)?;
    for component in path.components() {
        if let std::path::Component::Normal(name) = component {
            directory = openat_directory(&directory, name)?;
        }
    }
    Ok(directory)
}

#[cfg(unix)]
fn open_relative_directory(root: &Path, relative: &Path) -> Result<fs::File, BrowseError> {
    let mut directory = open_directory_nofollow(root)?;
    for component in relative.components() {
        match component {
            std::path::Component::Normal(name) => {
                directory = openat_directory(&directory, name)?;
            }
            _ => return Err((StatusCode::BAD_REQUEST, "This workspace path is invalid.")),
        }
    }
    Ok(directory)
}

#[cfg(unix)]
fn open_file_at(directory: &fs::File, name: &std::ffi::OsStr) -> Result<fs::File, BrowseError> {
    let name = CString::new(name.as_bytes()).map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            "This workspace path contains an invalid name.",
        )
    })?;
    let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        return Err(secure_open_error(io::Error::last_os_error()));
    }
    Ok(unsafe { fs::File::from_raw_fd(fd) })
}

#[cfg(unix)]
#[cfg(test)]
fn open_file_path_nofollow(path: &Path) -> Result<fs::File, BrowseError> {
    let parent = path
        .parent()
        .ok_or((StatusCode::BAD_REQUEST, "This workspace path is invalid."))?;
    let name = path
        .file_name()
        .ok_or((StatusCode::BAD_REQUEST, "This workspace path is invalid."))?;
    let directory = open_directory_nofollow(parent)?;
    open_file_at(&directory, name)
}

#[cfg(unix)]
fn open_workspace_file(root: &WorkspaceRoot, relative: &Path) -> Result<fs::File, BrowseError> {
    if !root.is_directory && !relative.as_os_str().is_empty() {
        return Err((StatusCode::BAD_REQUEST, "Choose a regular file."));
    }
    if relative.as_os_str().is_empty() {
        let parent = root
            .path
            .parent()
            .ok_or((StatusCode::BAD_REQUEST, "This workspace path is invalid."))?;
        let name = root
            .path
            .file_name()
            .ok_or((StatusCode::BAD_REQUEST, "This workspace path is invalid."))?;
        let directory = open_directory_nofollow(parent)?;
        return open_file_at(&directory, name);
    }
    let directory = if root.is_directory {
        open_relative_directory(&root.path, relative.parent().unwrap_or(Path::new("")))?
    } else {
        return Err((StatusCode::BAD_REQUEST, "Choose a regular file."));
    };
    let name = relative
        .file_name()
        .ok_or((StatusCode::BAD_REQUEST, "This workspace path is invalid."))?;
    open_file_at(&directory, name)
}

#[cfg(unix)]
fn open_workspace_directory(
    root: &WorkspaceRoot,
    relative: &Path,
) -> Result<fs::File, BrowseError> {
    if !root.is_directory {
        return Err((StatusCode::BAD_REQUEST, "Choose a folder to browse."));
    }
    open_relative_directory(&root.path, relative)
}

#[cfg(unix)]
fn read_directory_entries(
    directory: &fs::File,
    max_entries: usize,
) -> Result<Vec<(String, bool, Option<u64>)>, BrowseError> {
    let duplicate = unsafe { libc::dup(directory.as_raw_fd()) };
    if duplicate < 0 {
        return Err(disk_error(io::Error::last_os_error()));
    }
    let stream = unsafe { libc::fdopendir(duplicate) };
    if stream.is_null() {
        unsafe { libc::close(duplicate) };
        return Err(disk_error(io::Error::last_os_error()));
    }
    let directory_fd = unsafe { libc::dirfd(stream) };
    let mut entries = Vec::new();
    loop {
        #[cfg(target_os = "macos")]
        unsafe {
            *libc::__error() = 0;
        }
        #[cfg(not(target_os = "macos"))]
        unsafe {
            *libc::__errno_location() = 0;
        }
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            let error = io::Error::last_os_error();
            unsafe { libc::closedir(stream) };
            if error.raw_os_error().unwrap_or(0) != 0 {
                return Err(disk_error(error));
            }
            return Ok(entries);
        }
        let name_bytes = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name_bytes == b"." || name_bytes == b".." {
            continue;
        }
        let Ok(name) = String::from_utf8(name_bytes.to_vec()) else {
            continue;
        };
        let name_c = CString::new(name.as_bytes()).map_err(|_| {
            (
                StatusCode::BAD_REQUEST,
                "This workspace path contains an invalid name.",
            )
        })?;
        let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe {
            libc::fstatat(
                directory_fd,
                name_c.as_ptr(),
                metadata.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            continue;
        }
        let metadata = unsafe { metadata.assume_init() };
        let kind = metadata.st_mode as libc::mode_t & libc::S_IFMT;
        let is_directory = kind == libc::S_IFDIR;
        if kind != libc::S_IFREG && !is_directory {
            continue;
        }
        // Count entries before the UI's hidden/protected filtering. A hidden
        // entry must not let a large directory evade the descriptor scan cap.
        if entries.len() >= max_entries {
            unsafe { libc::closedir(stream) };
            return Err(too_many_entries_error());
        }
        entries.push((
            name,
            is_directory,
            (!is_directory).then_some(metadata.st_size.max(0) as u64),
        ));
    }
}

fn mime_for_path(path: &Path) -> Option<String> {
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(
        match extension.as_str() {
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "webp" => "image/webp",
            "pdf" => "application/pdf",
            "html" | "htm" => "text/html",
            "md" => "text/markdown",
            "txt" | "log" | "json" | "toml" | "yaml" | "yml" | "swift" | "rs" | "ts" => {
                "text/plain"
            }
            _ => "application/octet-stream",
        }
        .to_owned(),
    )
}

fn list_workspace_directory(
    root: &WorkspaceRoot,
    relative: &Path,
    denied: &[PathBuf],
    own_workspace: Option<&Path>,
    show_hidden: bool,
    offset: usize,
) -> Result<WorkspaceDirectoryPage, BrowseError> {
    if !root.is_directory {
        return Err((StatusCode::BAD_REQUEST, "Choose a folder to browse."));
    }
    let lexical_directory = root.path.join(relative);
    if protected_by_denies(&lexical_directory, denied, own_workspace) {
        return Err((
            StatusCode::FORBIDDEN,
            "This path is outside the conversation's verified workspace.",
        ));
    }
    let directory = open_workspace_directory(root, relative)?;
    let raw_entries = read_directory_entries(&directory, MAX_ENTRIES)?;
    let mut entries = Vec::new();
    for (name, is_directory, byte_size) in raw_entries {
        if !show_hidden && name.starts_with('.') {
            continue;
        }
        let child_relative = relative.join(&name);
        let child = root.path.join(&child_relative);
        if protected_by_denies(&child, denied, own_workspace) {
            continue;
        }
        entries.push(WorkspaceEntry {
            name,
            path: child_relative.to_string_lossy().into_owned(),
            is_directory,
            byte_size,
            mime_type: (!is_directory).then(|| mime_for_path(&child)).flatten(),
        });
    }
    entries.sort_by_cached_key(|entry| {
        (
            !entry.is_directory,
            entry.name.to_lowercase(),
            entry.name.clone(),
        )
    });
    let next_offset =
        (entries.len() > offset.saturating_add(PAGE_SIZE)).then(|| offset + PAGE_SIZE);
    let parent_path = relative.parent().and_then(|parent| {
        if parent.as_os_str().is_empty() {
            None
        } else {
            Some(parent.to_string_lossy().into_owned())
        }
    });
    Ok(WorkspaceDirectoryPage {
        root_id: root.id.clone(),
        path: relative.to_string_lossy().into_owned(),
        parent_path,
        entries: entries.into_iter().skip(offset).take(PAGE_SIZE).collect(),
        next_offset,
    })
}

fn read_bounded_file(mut file: fs::File) -> Result<Vec<u8>, BrowseError> {
    // Check the descriptor, not a path lookup performed before open. This
    // keeps a concurrent replacement from changing a validated regular file
    // into a special file or an oversized read between the checks.
    let metadata = file.metadata().map_err(disk_error)?;
    if !metadata.is_file() {
        return Err((StatusCode::BAD_REQUEST, "Choose a regular file to preview."));
    }
    if metadata.len() > MAX_WORKSPACE_FILE_BYTES {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            "This file is too large to preview in Wonder.",
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len().min(MAX_WORKSPACE_FILE_BYTES) as usize);
    io::Read::take(&mut file, MAX_WORKSPACE_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(disk_error)?;
    if bytes.len() as u64 > MAX_WORKSPACE_FILE_BYTES {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            "This file is too large to preview in Wonder.",
        ));
    }
    Ok(bytes)
}

#[cfg(test)]
fn open_bounded_file(path: &Path) -> Result<Vec<u8>, BrowseError> {
    #[cfg(unix)]
    let file = open_file_path_nofollow(path)?;
    #[cfg(not(unix))]
    let file = fs::File::open(path).map_err(disk_error)?;
    read_bounded_file(file)
}

fn open_workspace_bounded_file(
    root: &WorkspaceRoot,
    relative: &Path,
    denied: &[PathBuf],
    own_workspace: Option<&Path>,
) -> Result<Vec<u8>, BrowseError> {
    let lexical = root.path.join(relative);
    if protected_by_denies(&lexical, denied, own_workspace) {
        return Err((
            StatusCode::FORBIDDEN,
            "This path is outside the conversation's verified workspace.",
        ));
    }
    let file = open_workspace_file(root, relative)?;
    read_bounded_file(file)
}

fn git_state(index: u8, worktree: u8) -> &'static str {
    if index == b'?' && worktree == b'?' {
        "untracked"
    } else if index == b'U' || worktree == b'U' || (index == b'A' && worktree == b'A') {
        "conflicted"
    } else if index == b'R' || worktree == b'R' || index == b'C' || worktree == b'C' {
        "renamed"
    } else if index == b'D' || worktree == b'D' {
        "deleted"
    } else if index != b' ' {
        "staged"
    } else if worktree != b' ' {
        "unstaged"
    } else {
        "modified"
    }
}

fn parse_git_status(bytes: &[u8]) -> Vec<(String, Option<String>, String, String, String)> {
    let mut fields = bytes.split(|byte| *byte == 0);
    let mut output = Vec::new();
    while let Some(record) = fields.next() {
        if record.len() < 4 {
            continue;
        }
        let index = record[0];
        let worktree = record[1];
        if record[2] != b' ' {
            continue;
        }
        let path = String::from_utf8_lossy(&record[3..]).into_owned();
        let original = if index == b'R' || index == b'C' || worktree == b'R' || worktree == b'C' {
            fields
                .next()
                .map(|value| String::from_utf8_lossy(value).into_owned())
        } else {
            None
        };
        output.push((
            path,
            original,
            git_state(index, worktree).to_owned(),
            (index as char).to_string(),
            (worktree as char).to_string(),
        ));
    }
    output
}

async fn git_repository(root: &Path) -> Option<PathBuf> {
    let bytes = crate::project_assignments::read_only_git_bytes(
        root.to_str()?,
        &["rev-parse", "--show-toplevel"],
    )
    .await
    .ok()?;
    let path = PathBuf::from(String::from_utf8_lossy(&bytes).trim());
    fs::canonicalize(path).ok()
}

fn git_pathspec(repository: &Path, root: &Path) -> Option<String> {
    let relative = root.strip_prefix(repository).ok()?.to_string_lossy();
    if relative.is_empty() {
        Some(":(top,literal).".into())
    } else {
        Some(format!(":(top,literal){relative}/"))
    }
}

fn synthetic_untracked_diff(path: &str, bytes: Vec<u8>) -> Result<String, BrowseError> {
    if bytes.contains(&0) {
        return Ok(format!(
            "diff --git a/{path} b/{path}\nnew file mode 100644\nBinary files /dev/null and b/{path} differ\n"
        ));
    }
    let text = String::from_utf8(bytes).map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            "This binary file has no textual diff preview.",
        )
    })?;
    let line_count = text.lines().count();
    let mut diff = format!(
        "diff --git a/{path} b/{path}\nnew file mode 100644\n--- /dev/null\n+++ b/{path}\n@@ -0,0 +1,{line_count} @@\n"
    );
    for line in text.lines() {
        diff.push('+');
        diff.push_str(line);
        diff.push('\n');
    }
    Ok(diff)
}

async fn read_workspace_git_status(
    root: &WorkspaceRoot,
    denied: &[PathBuf],
    own_workspace: Option<&Path>,
) -> WorkspaceGitStatusResponse {
    if !root.is_directory {
        return WorkspaceGitStatusResponse {
            available: false,
            detail: Some("Git status is available for folders only.".into()),
            repository_path: None,
            changes: Vec::new(),
        };
    }
    let Ok(directory) = resolve_workspace_path(root, Path::new(""), denied, own_workspace, false)
    else {
        return WorkspaceGitStatusResponse {
            available: false,
            detail: Some("This workspace location is unavailable.".into()),
            repository_path: None,
            changes: Vec::new(),
        };
    };
    let Some(repository) = git_repository(&directory).await else {
        return WorkspaceGitStatusResponse {
            available: true,
            detail: None,
            repository_path: None,
            changes: Vec::new(),
        };
    };
    if protected_by_denies(&repository, denied, own_workspace)
        || !repository.starts_with(&directory) && !directory.starts_with(&repository)
    {
        return WorkspaceGitStatusResponse {
            available: false,
            detail: Some(
                "This repository is outside the conversation's verified workspace.".into(),
            ),
            repository_path: None,
            changes: Vec::new(),
        };
    }
    let Some(pathspec) = git_pathspec(&repository, &directory) else {
        return WorkspaceGitStatusResponse {
            available: false,
            detail: Some("Git scope could not be verified.".into()),
            repository_path: None,
            changes: Vec::new(),
        };
    };
    let args = [
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--",
        pathspec.as_str(),
    ];
    let bytes = match crate::project_assignments::read_only_git_bytes(
        repository.to_str().unwrap_or_default(),
        &args,
    )
    .await
    {
        Ok(bytes) => bytes,
        Err(error) => {
            return WorkspaceGitStatusResponse {
                available: false,
                detail: Some(workspace_git_status_error_detail(&error).to_owned()),
                repository_path: Some(repository.to_string_lossy().into_owned()),
                changes: Vec::new(),
            }
        }
    };
    let mut changes = Vec::new();
    for (path, original, state, index_status, worktree_status) in parse_git_status(&bytes) {
        let full = repository.join(&path);
        let allowed = full.starts_with(&directory)
            || (directory.starts_with(&repository) && full.starts_with(&directory));
        if !allowed || protected_by_denies(&full, denied, own_workspace) {
            continue;
        }
        let display_path = full
            .strip_prefix(&directory)
            .unwrap_or(Path::new(&path))
            .to_string_lossy()
            .trim_start_matches('/')
            .to_owned();
        let original_path = original.map(|value| {
            repository
                .join(&value)
                .strip_prefix(&directory)
                .unwrap_or(Path::new(&value))
                .to_string_lossy()
                .trim_start_matches('/')
                .to_owned()
        });
        changes.push(WorkspaceGitChange {
            path: display_path,
            original_path,
            state,
            index_status,
            worktree_status,
        });
    }
    WorkspaceGitStatusResponse {
        available: true,
        detail: None,
        repository_path: Some(repository.to_string_lossy().into_owned()),
        changes,
    }
}

fn workspace_git_status_error_detail(error: &str) -> &'static str {
    if error.contains("timed out") {
        "Git status took too long to finish. Try again on the Mac."
    } else if error.contains("exceeded its limit") {
        "This workspace has too much Git status data to preview."
    } else {
        "Git status is temporarily unavailable for this workspace."
    }
}

pub(super) async fn workspace_roots(
    State(state): State<crate::AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    AxumPath(conversation_id): AxumPath<String>,
) -> Response {
    match conversation_workspace_roots(&state, &conversation_id).await {
        Ok((roots, attachments)) => Json(WorkspaceRootsResponse {
            available: true,
            detail: None,
            roots: roots
                .into_iter()
                .map(|root| {
                    let byte_size = if root.is_directory {
                        None
                    } else {
                        open_workspace_file(&root, Path::new(""))
                            .ok()
                            .and_then(|file| file.metadata().ok())
                            .map(|metadata| metadata.len())
                    };
                    let mime_type = (!root.is_directory)
                        .then(|| mime_for_path(&root.path))
                        .flatten();
                    WorkspaceRootResponse {
                        id: root.id,
                        label: root.label,
                        path: root.path.to_string_lossy().into_owned(),
                        is_directory: root.is_directory,
                        kind: root.kind,
                        read_only: true,
                        byte_size,
                        mime_type,
                    }
                })
                .collect(),
            attachments: attachments.into_iter().map(attachment_summary).collect(),
        })
        .into_response(),
        Err((status, detail)) => workspace_error(status, detail),
    }
}

pub(super) async fn workspace_directory(
    State(state): State<crate::AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    AxumPath(conversation_id): AxumPath<String>,
    Query(query): Query<WorkspaceQuery>,
) -> Response {
    if query.offset > MAX_ENTRIES {
        return workspace_error(
            StatusCode::BAD_REQUEST,
            "This folder page is invalid. Reload the folder.",
        );
    }
    let (roots, _) = match conversation_workspace_roots(&state, &conversation_id).await {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let Some(root_id) = query.root.as_deref() else {
        return workspace_error(StatusCode::BAD_REQUEST, "Choose a workspace location.");
    };
    let root = match root_for(&roots, root_id) {
        Ok(root) => root,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let denied = match denied_paths(&state.denied_roots) {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let relative = match relative_path(query.path.as_deref()) {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    match list_workspace_directory(
        root,
        &relative,
        &denied,
        Some(root.path.as_path()),
        query.show_hidden,
        query.offset,
    ) {
        Ok(page) => Json(page).into_response(),
        Err((status, detail)) => workspace_error(status, detail),
    }
}

pub(super) async fn workspace_file(
    State(state): State<crate::AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    AxumPath(conversation_id): AxumPath<String>,
    Query(query): Query<WorkspaceQuery>,
) -> Response {
    let (roots, _) = match conversation_workspace_roots(&state, &conversation_id).await {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let Some(root_id) = query.root.as_deref() else {
        return workspace_error(StatusCode::BAD_REQUEST, "Choose a workspace location.");
    };
    let root = match root_for(&roots, root_id) {
        Ok(root) => root,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let denied = match denied_paths(&state.denied_roots) {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let relative = match relative_path(query.path.as_deref()) {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let bytes =
        match open_workspace_bounded_file(root, &relative, &denied, Some(root.path.as_path())) {
            Ok(bytes) => bytes,
            Err((status, detail)) => return workspace_error(status, detail),
        };
    let mime = mime_for_path(&root.path.join(&relative))
        .unwrap_or_else(|| "application/octet-stream".into());
    let mut response = bytes.into_response();
    response.headers_mut().insert(
        axum::http::header::CONTENT_TYPE,
        axum::http::HeaderValue::from_str(&mime)
            .unwrap_or_else(|_| axum::http::HeaderValue::from_static("application/octet-stream")),
    );
    response
}

pub(super) async fn workspace_git_status(
    State(state): State<crate::AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    AxumPath(conversation_id): AxumPath<String>,
    Query(query): Query<WorkspaceQuery>,
) -> Response {
    let (roots, _) = match conversation_workspace_roots(&state, &conversation_id).await {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let Some(root_id) = query.root.as_deref() else {
        return workspace_error(StatusCode::BAD_REQUEST, "Choose a workspace location.");
    };
    let root = match root_for(&roots, root_id) {
        Ok(root) => root,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let denied = match denied_paths(&state.denied_roots) {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    Json(read_workspace_git_status(root, &denied, Some(root.path.as_path())).await).into_response()
}

pub(super) async fn workspace_git_diff(
    State(state): State<crate::AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    AxumPath(conversation_id): AxumPath<String>,
    Query(query): Query<WorkspaceDiffQuery>,
) -> Response {
    let (roots, _) = match conversation_workspace_roots(&state, &conversation_id).await {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let Some(root_id) = query.root.as_deref() else {
        return workspace_error(StatusCode::BAD_REQUEST, "Choose a workspace location.");
    };
    let root = match root_for(&roots, root_id) {
        Ok(root) => root,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let denied = match denied_paths(&state.denied_roots) {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let relative = match relative_path(query.path.as_deref()) {
        Ok(value) => value,
        Err((status, detail)) => return workspace_error(status, detail),
    };
    let path =
        match resolve_workspace_path(root, &relative, &denied, Some(root.path.as_path()), true) {
            Ok(path) => path,
            Err((status, detail)) => return workspace_error(status, detail),
        };
    let status = read_workspace_git_status(root, &denied, Some(root.path.as_path())).await;
    if !status.available {
        return workspace_error(
            StatusCode::NOT_FOUND,
            status
                .detail
                .unwrap_or_else(|| "This workspace location is not a Git repository.".into()),
        );
    }
    let requested_path = query.path.as_deref().unwrap_or_default();
    let Some(change) = status
        .changes
        .iter()
        .find(|change| change.path == requested_path)
    else {
        return workspace_error(
            StatusCode::CONFLICT,
            "This file is no longer a modified file in the selected workspace. Reload Modified.",
        );
    };
    let staged_change = change.index_status != " " && change.index_status != "?";
    let worktree_change = change.worktree_status != " " || change.index_status == "?";
    if (query.staged && !staged_change) || (!query.staged && !worktree_change) {
        return workspace_error(
            StatusCode::CONFLICT,
            "This file changed sides. Reload Modified before opening its diff.",
        );
    }
    let git_base = if root.is_directory {
        root.path.as_path()
    } else {
        root.path.parent().unwrap_or(root.path.as_path())
    };
    let Some(repository) = git_repository(git_base).await else {
        return workspace_error(
            StatusCode::NOT_FOUND,
            "This workspace location is not a Git repository.",
        );
    };
    let repo_relative = match path.strip_prefix(&repository) {
        Ok(value) => value.to_string_lossy().into_owned(),
        Err(_) => {
            return workspace_error(
                StatusCode::FORBIDDEN,
                "This file is outside the verified repository.",
            )
        }
    };
    let pathspec = format!(":(literal,top){repo_relative}");
    let args = if query.staged {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--cached",
            "--",
            pathspec.as_str(),
        ]
    } else {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--",
            pathspec.as_str(),
        ]
    };
    let output = match crate::project_assignments::read_only_git_bytes(
        repository.to_str().unwrap_or_default(),
        &args,
    )
    .await
    {
        Ok(bytes) => bytes,
        Err(error) => return workspace_error(StatusCode::SERVICE_UNAVAILABLE, error),
    };
    let mut diff = String::from_utf8_lossy(&output).into_owned();
    if diff.is_empty() && !query.staged {
        if path.exists() {
            let bytes = match open_workspace_bounded_file(
                root,
                &relative,
                &denied,
                Some(root.path.as_path()),
            ) {
                Ok(bytes) => bytes,
                Err((status, detail)) => return workspace_error(status, detail),
            };
            diff = match synthetic_untracked_diff(&repo_relative, bytes) {
                Ok(diff) => diff,
                Err((status, detail)) => return workspace_error(status, detail),
            };
        } else {
            diff = format!("diff --git a/{repo_relative} b/{repo_relative}\n--- a/{repo_relative}\n+++ /dev/null\n");
        }
    }
    if diff.len() > MAX_DIFF_BYTES {
        return workspace_error(
            StatusCode::PAYLOAD_TOO_LARGE,
            "This diff is too large to preview in Wonder.",
        );
    }
    Json(WorkspaceDiffResponse {
        path: query.path.unwrap_or_default(),
        staged: query.staged,
        diff,
    })
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::{ffi::OsStringExt, fs::symlink, net::UnixListener};

    #[tokio::test]
    async fn filesystem_browse_http_requires_owner_and_respects_protection() {
        use axum::{
            body::{to_bytes, Body},
            http::Request,
        };
        use tower::ServiceExt;
        let (folder, mut state) = crate::ingestion::tests::fixture().await;
        let requested = folder.path().join("browse");
        fs::create_dir(&requested).unwrap();
        fs::write(
            requested.join("visible.txt"),
            b"contents are never returned",
        )
        .unwrap();
        let uri = format!("/api/v1/filesystem?path={}", requested.display());
        let unauthorized = crate::router(state.clone())
            .oneshot(Request::builder().uri(&uri).body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert!(!unauthorized.status().is_success());
        let response = crate::router(state.clone())
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
        let bytes = to_bytes(response.into_body(), 65536).await.unwrap();
        let page: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(page["entries"][0]["name"], "visible.txt");
        assert_eq!(page["entries"][0]["isDirectory"], false);
        assert!(!String::from_utf8_lossy(&bytes).contains("contents are never returned"));
        state
            .denied_roots
            .push(requested.to_string_lossy().into_owned());
        let response = crate::router(state.clone())
            .oneshot(
                Request::builder()
                    .uri(&uri)
                    .header("x-wonder-loopback-capability", &state.loopback_capability)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[test]
    fn filesystem_browse_sorts_directories_first_and_paginates() {
        let folder = tempfile::tempdir().unwrap();
        fs::create_dir(folder.path().join("z-folder")).unwrap();
        for number in 0..205 {
            fs::write(folder.path().join(format!("file-{number:03}")), b"").unwrap();
        }
        let first = list_directory(folder.path(), &[], false, 0, MAX_ENTRIES).unwrap();
        assert_eq!(first.entries.len(), 200);
        assert_eq!(first.entries[0].name, "z-folder");
        assert!(first.entries[0].is_directory);
        assert_eq!(first.next_offset, Some(200));
        let second = list_directory(folder.path(), &[], false, 200, MAX_ENTRIES).unwrap();
        assert_eq!(second.entries.len(), 6);
        assert_eq!(second.entries[0].name, "file-199");
        assert_eq!(second.next_offset, None);
        assert_eq!(
            first.path,
            folder.path().canonicalize().unwrap().to_str().unwrap()
        );
        assert!(list_directory(folder.path(), &[], false, 0, 10)
            .unwrap_err()
            .1
            .contains("too many"));
    }

    #[test]
    fn filesystem_browse_hides_protected_targets_hidden_and_unsupported_entries() {
        let folder = tempfile::tempdir().unwrap();
        let protected = folder.path().join("private");
        fs::create_dir(&protected).unwrap();
        fs::write(protected.join("secret"), b"private").unwrap();
        fs::create_dir(folder.path().join("visible")).unwrap();
        fs::write(folder.path().join(".hidden"), b"").unwrap();
        fs::write(folder.path().join("allowed"), b"").unwrap();
        symlink(&protected, folder.path().join("private-alias")).unwrap();
        symlink(protected.join("secret"), folder.path().join("secret-alias")).unwrap();
        symlink(
            folder.path().join("visible"),
            folder.path().join("visible-alias"),
        )
        .unwrap();
        symlink(
            folder.path().join("missing"),
            folder.path().join("broken-alias"),
        )
        .unwrap();
        symlink(
            folder.path().join("loop-alias"),
            folder.path().join("loop-alias"),
        )
        .unwrap();
        let _socket = UnixListener::bind(folder.path().join("socket")).unwrap();
        #[cfg(not(target_os = "macos"))]
        fs::write(
            folder.path().join(std::ffi::OsString::from_vec(vec![0xff])),
            b"",
        )
        .unwrap();
        let denied = vec![protected.to_string_lossy().into_owned()];
        let page = list_directory(folder.path(), &denied, false, 0, MAX_ENTRIES).unwrap();
        assert_eq!(
            page.entries
                .iter()
                .map(|entry| entry.name.as_str())
                .collect::<Vec<_>>(),
            vec!["visible", "visible-alias", "allowed"]
        );
        assert_eq!(page.entries[0].path, page.entries[1].path);
        assert_eq!(
            list_directory(&protected, &denied, false, 0, MAX_ENTRIES)
                .unwrap_err()
                .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            list_directory(
                &folder.path().join("private-alias"),
                &denied,
                false,
                0,
                MAX_ENTRIES
            )
            .unwrap_err()
            .0,
            StatusCode::FORBIDDEN
        );
        let shown = list_directory(folder.path(), &denied, true, 0, MAX_ENTRIES).unwrap();
        assert!(shown.entries.iter().any(|entry| entry.name == ".hidden"));
        assert!(!shown
            .entries
            .iter()
            .any(|entry| entry.name.starts_with("private") || entry.name == "secret-alias"));
        let missing = folder.path().join("visible/future");
        assert_eq!(
            protected_root(&missing).unwrap(),
            folder.path().canonicalize().unwrap().join("visible/future")
        );
    }

    #[test]
    fn filesystem_browse_rejects_files_and_invalid_display_paths() {
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("file");
        fs::write(&file, b"").unwrap();
        assert_eq!(
            list_directory(&file, &[], false, 0, MAX_ENTRIES)
                .unwrap_err()
                .0,
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            list_directory(&folder.path().join("missing"), &[], false, 0, MAX_ENTRIES)
                .unwrap_err()
                .0,
            StatusCode::NOT_FOUND
        );
        let invalid = folder.path().join(std::ffi::OsString::from_vec(vec![0xff]));
        assert_eq!(
            list_directory(&invalid, &[], false, 0, MAX_ENTRIES)
                .unwrap_err()
                .0,
            StatusCode::BAD_REQUEST
        );
    }

    #[test]
    fn workspace_scope_enforces_lexical_canonical_and_protected_boundaries() {
        let root_dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        fs::create_dir(root_dir.path().join("inside")).unwrap();
        fs::write(root_dir.path().join("inside/file.txt"), b"ok").unwrap();
        fs::write(outside.path().join("secret.txt"), b"secret").unwrap();
        symlink(
            outside.path().join("secret.txt"),
            root_dir.path().join("escape.txt"),
        )
        .unwrap();
        symlink(
            root_dir.path().join("inside"),
            root_dir.path().join("alias"),
        )
        .unwrap();
        let _socket = UnixListener::bind(root_dir.path().join("socket")).unwrap();
        let root_path = root_dir.path().canonicalize().unwrap();
        let root = WorkspaceRoot {
            id: "workspace".into(),
            label: "Workspace".into(),
            path: root_path.clone(),
            is_directory: true,
            kind: "workingDirectory",
        };
        assert_eq!(
            relative_path(Some("../secret.txt")).unwrap_err().0,
            StatusCode::BAD_REQUEST
        );
        assert!(resolve_workspace_path(
            &root,
            Path::new("inside/file.txt"),
            &[],
            Some(&root_path),
            false
        )
        .is_ok());
        assert_eq!(
            resolve_workspace_path(&root, Path::new("escape.txt"), &[], Some(&root_path), false)
                .unwrap_err()
                .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            resolve_workspace_path(
                &root,
                Path::new("alias/file.txt"),
                &[],
                Some(&root_path),
                false
            )
            .unwrap_err()
            .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            resolve_workspace_path(&root, Path::new("socket"), &[], Some(&root_path), false)
                .unwrap_err()
                .0,
            StatusCode::FORBIDDEN
        );

        let protected_parent = root_path.parent().unwrap().to_path_buf();
        let denied = vec![protected_parent.clone()];
        assert!(resolve_workspace_path(
            &root,
            Path::new("inside/file.txt"),
            &denied,
            Some(&root_path),
            false
        )
        .is_ok());
        let nested_denied = vec![root_path.join("inside")];
        assert_eq!(
            resolve_workspace_path(
                &root,
                Path::new("inside/file.txt"),
                &nested_denied,
                Some(&root_path),
                false,
            )
            .unwrap_err()
            .0,
            StatusCode::FORBIDDEN
        );
        let sibling_dir = tempfile::Builder::new()
            .prefix("sibling-")
            .tempdir_in(&protected_parent)
            .unwrap();
        let sibling = sibling_dir.path().to_path_buf();
        fs::write(sibling.join("private.txt"), b"private").unwrap();
        let sibling_root = WorkspaceRoot {
            id: "sibling".into(),
            label: "Sibling".into(),
            path: sibling.canonicalize().unwrap(),
            is_directory: true,
            kind: "appliedGrant",
        };
        assert_eq!(
            resolve_workspace_path(
                &sibling_root,
                Path::new("private.txt"),
                &denied,
                Some(&root_path),
                false
            )
            .unwrap_err()
            .0,
            StatusCode::FORBIDDEN
        );
    }

    #[test]
    fn workspace_directory_is_bounded_and_supports_hidden_files() {
        let folder = tempfile::tempdir().unwrap();
        for number in 0..205 {
            fs::write(folder.path().join(format!("file-{number:03}")), b"").unwrap();
        }
        fs::write(folder.path().join(".hidden"), b"").unwrap();
        let root = WorkspaceRoot {
            id: "workspace".into(),
            label: "Workspace".into(),
            path: folder.path().canonicalize().unwrap(),
            is_directory: true,
            kind: "workingDirectory",
        };
        let first = list_workspace_directory(&root, Path::new(""), &[], Some(&root.path), false, 0)
            .unwrap();
        assert_eq!(first.entries.len(), 200);
        assert_eq!(first.next_offset, Some(200));
        assert!(!first.entries.iter().any(|entry| entry.name == ".hidden"));
        let second =
            list_workspace_directory(&root, Path::new(""), &[], Some(&root.path), false, 200)
                .unwrap();
        assert_eq!(second.entries.len(), 5);
        assert!(
            list_workspace_directory(&root, Path::new(""), &[], Some(&root.path), true, 0)
                .unwrap()
                .entries
                .iter()
                .any(|entry| entry.name == ".hidden")
        );
    }

    #[cfg(unix)]
    #[test]
    fn workspace_descriptor_scan_caps_before_collecting_hidden_entries() {
        let folder = tempfile::tempdir().unwrap();
        fs::write(folder.path().join("visible-a"), b"").unwrap();
        fs::write(folder.path().join("visible-b"), b"").unwrap();
        fs::write(folder.path().join(".hidden"), b"").unwrap();
        let directory = open_directory_nofollow(&folder.path().canonicalize().unwrap()).unwrap();
        let error = read_directory_entries(&directory, 2).unwrap_err();
        assert_eq!(error.0, StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(error.1, TOO_MANY_ENTRIES_DETAIL);
    }

    #[test]
    fn workspace_git_status_parses_every_user_visible_state() {
        let bytes = b" M unstaged.txt\0M  staged.txt\0?? untracked.txt\0R  renamed-new.txt\0renamed-old.txt\0UU conflict.txt\0 D deleted.txt\0";
        let changes = parse_git_status(bytes);
        let states = changes
            .iter()
            .map(|(_, _, state, _, _)| state.as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            states,
            [
                "unstaged",
                "staged",
                "untracked",
                "renamed",
                "conflicted",
                "deleted"
            ]
        );
        assert_eq!(changes[3].1.as_deref(), Some("renamed-old.txt"));
        assert_eq!(
            git_pathspec(Path::new("/repo"), Path::new("/repo/src")),
            Some(":(top,literal)src/".into())
        );
        assert_eq!(
            git_pathspec(Path::new("/repo"), Path::new("/repo")),
            Some(":(top,literal).".into())
        );
    }

    #[test]
    fn workspace_git_status_errors_are_product_facing() {
        for raw in [
            "fatal: not a git repository: '/private/workspace'",
            "Git operation timed out; inspect this workspace on the Mac.",
            "Git output exceeded its limit. Inspect this change on the Mac.",
        ] {
            let detail = workspace_git_status_error_detail(raw);
            assert!(!detail.contains("fatal"));
            assert!(!detail.contains("/private/workspace"));
            assert!(!detail.contains("git repository"));
        }
    }

    #[test]
    fn workspace_file_grants_can_target_regular_files() {
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("notes.txt");
        fs::write(&file, b"read-only").unwrap();
        let root = WorkspaceRoot {
            id: "grant-0".into(),
            label: "notes.txt".into(),
            path: file.canonicalize().unwrap(),
            is_directory: false,
            kind: "appliedGrant",
        };
        let resolved =
            resolve_workspace_path(&root, Path::new(""), &[], Some(&root.path), false).unwrap();
        assert_eq!(open_bounded_file(&resolved).unwrap(), b"read-only");
        assert!(
            list_workspace_directory(&root, Path::new(""), &[], Some(&root.path), false, 0)
                .is_err()
        );
    }

    #[test]
    fn workspace_descriptor_access_rejects_intermediate_symlink_swaps() {
        let root_dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        fs::create_dir(root_dir.path().join("nested")).unwrap();
        fs::write(root_dir.path().join("nested/file.txt"), b"inside").unwrap();
        fs::write(outside.path().join("file.txt"), b"outside").unwrap();
        let root_path = root_dir.path().canonicalize().unwrap();
        let root = WorkspaceRoot {
            id: "workspace".into(),
            label: "Workspace".into(),
            path: root_path.clone(),
            is_directory: true,
            kind: "workingDirectory",
        };
        let validated = resolve_workspace_path(
            &root,
            Path::new("nested/file.txt"),
            &[],
            Some(&root_path),
            false,
        )
        .unwrap();
        assert_eq!(fs::read(&validated).unwrap(), b"inside");

        fs::rename(
            root_dir.path().join("nested"),
            root_dir.path().join("nested-real"),
        )
        .unwrap();
        symlink(outside.path(), root_dir.path().join("nested")).unwrap();

        assert_eq!(
            open_workspace_bounded_file(
                &root,
                Path::new("nested/file.txt"),
                &[],
                Some(&root_path),
            )
            .unwrap_err()
            .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            list_workspace_directory(&root, Path::new("nested"), &[], Some(&root_path), false, 0,)
                .unwrap_err()
                .0,
            StatusCode::FORBIDDEN
        );
    }

    async fn workspace_route(
        state: &crate::AppState,
        uri: &str,
        authenticated: bool,
    ) -> (StatusCode, Vec<u8>) {
        use axum::{body::to_bytes, body::Body, http::Request};
        use tower::ServiceExt;
        let mut request = Request::builder().uri(uri);
        if authenticated {
            request = request.header("x-wonder-loopback-capability", &state.loopback_capability);
        }
        let response = crate::router(state.clone())
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 2 * 1024 * 1024)
            .await
            .unwrap();
        (status, bytes.to_vec())
    }

    #[tokio::test]
    async fn workspace_routes_are_authenticated_scoped_and_support_group_and_grant_roots() {
        let (dir, mut state) = crate::ingestion::tests::fixture().await;
        let mut bot = state.store.bot("bot").await.unwrap().unwrap();
        let private_workspace = PathBuf::from(&bot.workspace_path).canonicalize().unwrap();
        let selected_workspace = tempfile::tempdir().unwrap();
        fs::write(selected_workspace.path().join("visible.txt"), b"visible").unwrap();
        fs::write(selected_workspace.path().join(".hidden"), b"hidden").unwrap();
        bot.working_directory = Some(selected_workspace.path().to_string_lossy().into_owned());
        state
            .store
            .update_managed_bot(&bot, [false; 3])
            .await
            .unwrap();

        let (status, _) =
            workspace_route(&state, "/api/v1/conversations/bot/workspace/roots", false).await;
        assert!(!status.is_success());

        let (status, bytes) =
            workspace_route(&state, "/api/v1/conversations/bot/workspace/roots", true).await;
        assert_eq!(status, StatusCode::OK);
        let roots: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(roots["roots"][0]["id"], "workspace");
        assert_eq!(roots["roots"][0]["label"], "Workspace");
        assert_eq!(roots["roots"][0]["kind"], "workingDirectory");
        assert_eq!(roots["roots"][0]["readOnly"], true);
        let selected_workspace_path = selected_workspace.path().canonicalize().unwrap();
        assert!(roots["roots"]
            .as_array()
            .unwrap()
            .iter()
            .any(|root| root["path"].as_str() == selected_workspace_path.to_str()));
        assert!(!roots["roots"]
            .as_array()
            .unwrap()
            .iter()
            .any(|root| { root["path"].as_str() == private_workspace.to_str() }));

        let (status, bytes) = workspace_route(
            &state,
            "/api/v1/conversations/bot/workspace/directory?root=workspace&offset=0",
            true,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let page: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert!(page["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["name"] == "visible.txt"));
        assert!(!page["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["name"] == ".hidden"));

        let (status, bytes) = workspace_route(
            &state,
            "/api/v1/conversations/bot/workspace/file?root=workspace&path=visible.txt",
            true,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(bytes, b"visible");
        assert_eq!(
            workspace_route(
                &state,
                "/api/v1/conversations/bot/workspace/directory?root=unrelated",
                true,
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );

        let grant_dir = tempfile::tempdir().unwrap();
        fs::write(grant_dir.path().join("granted.txt"), b"grant").unwrap();
        let grant = grant_dir.path().canonicalize().unwrap();
        assert!(state
            .store
            .save_bot_file_access(
                "bot",
                0,
                &[
                    selected_workspace_path.to_string_lossy().into_owned(),
                    grant.to_string_lossy().into_owned(),
                ],
                &[],
            )
            .await
            .unwrap());
        state.store.apply_bot_file_access("bot", 1).await.unwrap();
        let (status, bytes) =
            workspace_route(&state, "/api/v1/conversations/bot/workspace/roots", true).await;
        assert_eq!(status, StatusCode::OK);
        let roots: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(roots["roots"].as_array().unwrap().len(), 2);
        assert!(roots["roots"]
            .as_array()
            .unwrap()
            .iter()
            .any(|root| root["kind"] == "appliedGrant"
                && root["label"] == grant.file_name().unwrap().to_str().unwrap()));
        assert!(!roots["roots"]
            .as_array()
            .unwrap()
            .iter()
            .any(|root| { root["path"].as_str() == private_workspace.to_str() }));

        state
            .denied_roots
            .push(grant.to_string_lossy().into_owned());
        let (status, bytes) =
            workspace_route(&state, "/api/v1/conversations/bot/workspace/roots", true).await;
        assert_eq!(status, StatusCode::OK);
        let roots: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(roots["roots"].as_array().unwrap().len(), 1);
        assert!(!roots["roots"]
            .as_array()
            .unwrap()
            .iter()
            .any(|root| root["kind"] == "appliedGrant"));

        let shared = dir.path().join("shared-workspace");
        fs::create_dir(&shared).unwrap();
        fs::write(shared.join("shared.txt"), b"shared").unwrap();
        state
            .store
            .create_channel(
                "group",
                "group-chat",
                "Group",
                None,
                "bot",
                &[("bot", "worker")],
                "now",
            )
            .await
            .unwrap();
        state
            .store
            .save_collaboration_config(
                "group",
                &serde_json::json!({"workspace": shared.to_string_lossy()}).to_string(),
            )
            .await
            .unwrap();
        let (status, bytes) = workspace_route(
            &state,
            "/api/v1/conversations/group-chat/workspace/roots",
            true,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let roots: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(roots["roots"][0]["kind"], "groupWorkspace");
        assert_eq!(roots["roots"][0]["label"], "Workspace");
        assert_eq!(
            roots["roots"][0]["path"],
            shared.canonicalize().unwrap().to_string_lossy().to_string()
        );
        assert_eq!(roots["roots"].as_array().unwrap().len(), 1);
        assert!(!roots["roots"]
            .as_array()
            .unwrap()
            .iter()
            .any(|root| root["kind"] == "appliedGrant"));
        assert_eq!(
            workspace_route(
                &state,
                "/api/v1/conversations/unrelated/workspace/roots",
                true,
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn workspace_child_route_uses_verified_child_cwd_and_rejects_unrelated_ids() {
        let (dir, mut state) = crate::ingestion::tests::fixture().await;
        let parent_grant = dir.path().join("parent-grant");
        fs::create_dir(&parent_grant).unwrap();
        assert!(state
            .store
            .save_bot_file_access(
                "bot",
                0,
                &[parent_grant.to_string_lossy().into_owned()],
                &[],
            )
            .await
            .unwrap());
        state.store.apply_bot_file_access("bot", 1).await.unwrap();
        let child_cwd = dir.path().join("child-full-access");
        fs::create_dir(&child_cwd).unwrap();
        let mut full_access_bot = state.store.bot("bot").await.unwrap().unwrap();
        full_access_bot.permission_mode = Some("full-access".into());
        full_access_bot.approval_mode = Some("full-access".into());
        state
            .store
            .update_managed_bot(&full_access_bot, [false; 3])
            .await
            .unwrap();
        let runtime_path = dir.path().join("runtime.py");
        let source = fs::read_to_string(&runtime_path).unwrap();
        fs::write(
            &runtime_path,
            source.replace(
                "'cwd':'/child/work'",
                &format!("'cwd':'{}'", child_cwd.display()),
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
        let health = state.app_server.lock().await.health();
        state
            .ingestion
            .register(&state.app_server, health.clone(), None);
        state
            .store
            .ensure_conversation_metadata("parent", "bot", "Parent", "now")
            .await
            .unwrap();
        state
            .store
            .set_conversation_thread("parent", "thread", None, "now")
            .await
            .unwrap();
        let child = crate::subagents::register_from_thread(
            &state,
            "thread",
            "parent",
            &serde_json::json!({
                "id":"child-thread",
                "parentThreadId":"thread",
                "source":{"subAgent":{"thread_spawn":{"parent_thread_id":"thread","depth":1,"agent_nickname":"Scout","agent_role":"research"}}},
                "status":{"type":"idle"},
                "canAcceptDirectInput":true,
                "cwd":child_cwd.to_string_lossy()
            }),
            health.id(),
        )
        .await
        .unwrap();
        let (status, bytes) = workspace_route(
            &state,
            &format!(
                "/api/v1/conversations/{}/workspace/roots",
                child.conversation_id
            ),
            true,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let roots: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(roots["roots"][0]["id"], "child-cwd");
        assert_eq!(roots["roots"][0]["label"], "Workspace");
        assert_eq!(roots["roots"][0]["kind"], "childWorkingDirectory");
        assert_eq!(
            roots["roots"][0]["path"],
            child_cwd
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .to_string()
        );
        assert_eq!(roots["roots"].as_array().unwrap().len(), 1);
        assert!(!roots["roots"]
            .as_array()
            .unwrap()
            .iter()
            .any(|root| root["kind"] == "appliedGrant"));
        state
            .denied_roots
            .push(child_cwd.to_string_lossy().into_owned());
        assert_eq!(
            workspace_route(
                &state,
                &format!(
                    "/api/v1/conversations/{}/workspace/roots",
                    child.conversation_id
                ),
                true,
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        state.denied_roots.pop();
        let mut workspace_bot = state.store.bot("bot").await.unwrap().unwrap();
        workspace_bot.permission_mode = Some("workspace".into());
        workspace_bot.approval_mode = Some("ask-for-approval".into());
        state
            .store
            .update_managed_bot(&workspace_bot, [false; 3])
            .await
            .unwrap();
        assert_eq!(
            workspace_route(
                &state,
                &format!(
                    "/api/v1/conversations/{}/workspace/roots",
                    child.conversation_id
                ),
                true,
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            workspace_route(
                &state,
                "/api/v1/conversations/not-a-child/workspace/roots",
                true,
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
