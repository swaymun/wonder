//! Owner-facing lifecycle operations. Private workspace ownership is separate from execution cwd.
use super::*;
use wonder_store::{avatar, BotFileRequest};

static CREATE_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
fn problem(status: StatusCode, message: impl Into<String>) -> Response {
    (status, message.into()).into_response()
}
fn color_valid(color: Option<&str>) -> bool {
    avatar::valid_color(color)
}

fn avatar_selection(
    shape: Option<&str>,
    palette: Option<&str>,
    legacy_color: Option<&str>,
    default_shape: &str,
) -> (String, String) {
    let shape = shape.unwrap_or(default_shape).to_owned();
    let palette = palette
        .or_else(|| legacy_color.and_then(avatar::palette_for_legacy_color))
        .unwrap_or_else(|| avatar::default_palette_for_shape(&shape))
        .to_owned();
    (shape, palette)
}

fn validate_avatar(
    shape: Option<&str>,
    palette: Option<&str>,
    color: Option<&str>,
) -> Result<(), &'static str> {
    if !avatar::valid_shape(shape) {
        return Err("Choose a supported Bot character.");
    }
    if !avatar::valid_palette(palette) {
        return Err("Choose a supported Bot palette.");
    }
    if !color_valid(color) {
        return Err("Choose a valid Bot color.");
    }
    Ok(())
}

pub(super) async fn prepare_private_home(
    root: &str,
    home: &FsPath,
    id: &str,
) -> Result<(), String> {
    tokio::fs::create_dir_all(root)
        .await
        .map_err(|_| "Bot storage could not be created.".to_owned())?;
    match tokio::fs::create_dir(home).await {
        Ok(()) => {
            tokio::fs::write(home.join(".wonder-bot-owner"), id)
                .await
                .map_err(|_| "Could not record ownership of the new Bot folder.".to_owned())?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let metadata = tokio::fs::symlink_metadata(home)
                .await
                .map_err(|_| "Could not verify the existing Bot folder.".to_owned())?;
            if metadata.file_type().is_symlink()
                || !metadata.is_dir()
                || tokio::fs::read_to_string(home.join(".wonder-bot-owner"))
                    .await
                    .ok()
                    .as_deref()
                    != Some(id)
            {
                return Err("A different folder already uses this Bot identity. Its files were left untouched; start a new Bot draft.".into());
            }
        }
        Err(_) => return Err("The Bot folder could not be created.".into()),
    }
    Ok(())
}

pub(super) async fn options(State(state): State<AppState>) -> Response {
    let catalog = state.runtime_catalog.read().await;
    let timezone = std::fs::read_link("/etc/localtime")
        .ok()
        .and_then(|p| {
            p.to_str()
                .and_then(|s| s.split("zoneinfo/").nth(1))
                .map(str::to_owned)
        })
        .unwrap_or_else(|| "UTC".into());
    Json(serde_json::json!({"groupCollaboration":true,"models":catalog.models.iter().filter(|m| !m.hidden).collect::<Vec<_>>(),"timezone":timezone,"allowedApprovalPolicies":if catalog.approval_policies_restricted {catalog.allowed_approval_policies.clone()} else {vec!["on-request".to_owned(),"never".to_owned()]},"permissionModes":permission_modes::options(&catalog),"approvalModes":permission_modes::approval_options(&catalog, None)})).into_response()
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct AvatarCreateBotRequest {
    #[serde(flatten)]
    pub(super) base: CreateBotRequest,
    pub(super) avatar_shape: Option<String>,
    pub(super) avatar_palette: Option<String>,
}

/// Internal callers still use the pre-avatar create struct. The public HTTP
/// route below owns the additive avatar fields so existing Rust struct
/// literals remain source-compatible.
pub(super) async fn create(
    State(state): State<AppState>,
    Extension(authority): Extension<OwnerAuthority>,
    Json(request): Json<CreateBotRequest>,
) -> Response {
    create_inner(state, authority, request, None, None, None).await
}

pub(super) async fn create_with_avatar(
    State(state): State<AppState>,
    Extension(authority): Extension<OwnerAuthority>,
    Json(request): Json<AvatarCreateBotRequest>,
) -> Response {
    let payload = serde_json::to_vec(&request).ok();
    let AvatarCreateBotRequest {
        base,
        avatar_shape,
        avatar_palette,
    } = request;
    create_inner(
        state,
        authority,
        base,
        avatar_shape,
        avatar_palette,
        payload,
    )
    .await
}

/// Conversational creation uses a generated name. Keep its original request
/// identity across default-name changes so an interrupted pre-upgrade creation
/// can be retried without resetting a profile or avatar edited in the meantime.
pub(super) async fn create_conversational(
    state: AppState,
    authority: OwnerAuthority,
    request: AvatarCreateBotRequest,
) -> Response {
    let mut identity = request.clone();
    identity.base.name = "New Bot".into();
    let payload = serde_json::to_vec(&identity).ok();
    create_inner(
        state,
        authority,
        request.base,
        request.avatar_shape,
        request.avatar_palette,
        payload,
    )
    .await
}

async fn create_inner(
    state: AppState,
    authority: OwnerAuthority,
    request: CreateBotRequest,
    requested_shape: Option<String>,
    requested_palette: Option<String>,
    payload: Option<Vec<u8>>,
) -> Response {
    if let Err(message) = validate_avatar(
        requested_shape.as_deref(),
        requested_palette.as_deref(),
        request.avatar_color.as_deref(),
    ) {
        return problem(StatusCode::BAD_REQUEST, message);
    }
    let (shape, palette) = avatar_selection(
        requested_shape.as_deref(),
        requested_palette.as_deref(),
        request.avatar_color.as_deref(),
        avatar::DEFAULT_SHAPE,
    );
    let color = request.avatar_color.clone();
    let _guard = CREATE_LOCK.lock().await;
    if let Some(id) = request.client_request_id.as_deref() {
        if uuid::Uuid::parse_str(id).is_err() {
            return problem(StatusCode::BAD_REQUEST, "Invalid creation request.");
        }
        if state.store.bot_was_deleted(id).await.unwrap_or(true) {
            return problem(
                StatusCode::GONE,
                "This Bot was deleted. Discard this draft to create a new Bot.",
            );
        }
        let hash =
            hex::encode(sha2::Sha256::digest(payload.unwrap_or_else(|| {
                serde_json::to_vec(&request).unwrap_or_default()
            })));
        match state.store.reserve_bot_creation(id, &hash).await {
            Ok(true) => {}
            Ok(false) => {
                return problem(
                    StatusCode::CONFLICT,
                    "This creation request already has different Bot settings. Start a new draft.",
                )
            }
            Err(_) => {
                return problem(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Could not save the Bot creation request. Try again.",
                )
            }
        }
        if let Ok(Some(bot)) = state.store.bot(id).await {
            if bot.conversation_id.is_some() {
                if ((bot.avatar_shape.is_none() && bot.avatar_palette.is_none())
                    && state
                        .store
                        .save_bot_presentation(
                            id,
                            Some(&shape),
                            Some(&palette),
                            color.as_deref(),
                            None,
                        )
                        .await
                        .is_err())
                    || state.store.finish_bot_creation(id).await.is_err()
                {
                    return problem(
                        StatusCode::SERVICE_UNAVAILABLE,
                        "Bot created; reconnect to check its saved settings.",
                    );
                }
                return bot_get_endpoint(State(state), Path(id.to_owned())).await;
            }
        }
    }
    let response =
        super::create_bot(State(state.clone()), Extension(authority), Json(request)).await;
    if !response.status().is_success() {
        return response;
    }
    let Ok(bytes) = axum::body::to_bytes(response.into_body(), 128 * 1024).await else {
        return problem(
            StatusCode::SERVICE_UNAVAILABLE,
            "Check whether the Bot was created before trying again.",
        );
    };
    let Ok(result) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return problem(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Bot response could not be read.",
        );
    };
    let Some(id) = result["id"].as_str() else {
        return problem(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Bot response is missing its identity.",
        );
    };
    if state
        .store
        .save_bot_presentation(id, Some(&shape), Some(&palette), color.as_deref(), None)
        .await
        .is_err()
        || state.store.finish_bot_creation(id).await.is_err()
    {
        return problem(
            StatusCode::SERVICE_UNAVAILABLE,
            "Bot created; reconnect to check its saved settings.",
        );
    }
    bot_get_endpoint(State(state), Path(id.to_owned())).await
}

fn validation(status: StatusCode, message: &'static str) -> (StatusCode, &'static str) {
    (status, message)
}
pub(super) async fn validate_edit(
    state: &AppState,
    bot: &StoredBot,
    shape: Option<&str>,
    palette: Option<&str>,
    color: Option<&str>,
    directory: Option<&str>,
    requires_idle: bool,
) -> Result<(), (StatusCode, &'static str)> {
    if let Err(message) = validate_avatar(shape, palette, color) {
        return Err(validation(StatusCode::BAD_REQUEST, message));
    }
    if requires_idle && state.store.bot_has_work(&bot.id).await.unwrap_or(true) {
        return Err(validation(
            StatusCode::CONFLICT,
            "Finish or stop this Bot's work and clear its queue before changing settings.",
        ));
    }
    if let Some(path) = directory {
        validate_directory(state, bot, path).await?;
    }
    Ok(())
}
pub(super) async fn validate_directory(
    state: &AppState,
    bot: &StoredBot,
    path: &str,
) -> Result<(), (StatusCode, &'static str)> {
    let canonical = tokio::fs::canonicalize(path).await.map_err(|_| {
        validation(
            StatusCode::BAD_REQUEST,
            "The project folder is unavailable on your Mac.",
        )
    })?;
    if canonical.to_string_lossy() != path || !canonical.is_dir() {
        return Err(validation(
            StatusCode::BAD_REQUEST,
            "Choose an existing folder using its resolved path.",
        ));
    }
    // A canonical path is required at both request and dispatch time. Keep
    // protected Wonder storage protected even for a full-access Bot, while
    // allowing the Bot's own identity folder to remain usable.
    let protected = state
        .denied_roots
        .iter()
        .map(|deny| {
            filesystem::protected_root(FsPath::new(deny.strip_suffix("/**").unwrap_or(deny)))
                .map_err(|_| {
                    validation(
                        StatusCode::SERVICE_UNAVAILABLE,
                        "Protected Mac locations could not be checked.",
                    )
                })
        })
        .collect::<Result<Vec<_>, _>>()?;
    let workspace = filesystem::protected_root(FsPath::new(&bot.workspace_path)).map_err(|_| {
        validation(
            StatusCode::SERVICE_UNAVAILABLE,
            "The Bot workspace could not be checked.",
        )
    })?;
    if protected.iter().any(|deny| {
        let workspace_exception = canonical.starts_with(&workspace) && workspace.starts_with(deny);
        canonical.starts_with(deny) && !workspace_exception
    }) {
        return Err(validation(
            StatusCode::BAD_REQUEST,
            "This folder is protected and cannot be used as a working folder.",
        ));
    }
    if bot.permission_mode.is_some() {
        return Ok(());
    }
    let access = state.store.bot_file_access(&bot.id).await.map_err(|_| {
        validation(
            StatusCode::SERVICE_UNAVAILABLE,
            "Could not check this Bot's folder access.",
        )
    })?;
    let allowed = canonical.starts_with(&bot.workspace_path)
        || access
            .read_roots
            .iter()
            .chain(&access.write_roots)
            .any(|p| canonical.starts_with(p));
    if !allowed || access.revision != access.applied_revision {
        return Err(validation(
            StatusCode::CONFLICT,
            "Allow this folder in File access before using it as the project folder.",
        ));
    }
    Ok(())
}

pub(super) async fn archive(state: &AppState, id: &str, archived: bool) -> Response {
    let _guard = state.dispatch_lock.lock().await;
    if !matches!(state.store.bot(id).await, Ok(Some(_))) {
        return StatusCode::NOT_FOUND.into_response();
    }
    if state
        .store
        .pending_bot_deletions()
        .await
        .map_or(true, |jobs| jobs.iter().any(|(bot, _)| bot == id))
    {
        return problem(
            StatusCode::CONFLICT,
            "This Bot is being deleted. Retry Delete forever to finish cleanup.",
        );
    }
    if archived && state.store.bot_has_work(id).await.unwrap_or(true) {
        return problem(
            StatusCode::CONFLICT,
            "Finish or stop this Bot's work and clear its queue before archiving it.",
        );
    }
    if archived && state.store.bot_leads_group(id).await.unwrap_or(true) {
        return problem(
            StatusCode::CONFLICT,
            "Choose another lead in this Bot's Group Chats before archiving it.",
        );
    }
    if state.store.archive_bot_safely(id, archived).await.is_err() {
        return problem(
            StatusCode::SERVICE_UNAVAILABLE,
            "Could not save the archive change. Try again.",
        );
    }
    bot_get_endpoint(State(state.clone()), Path(id.to_owned())).await
}

pub(super) async fn delete(state: &AppState, id: &str) -> Response {
    let _guard = state.dispatch_lock.lock().await;
    match state.store.bot(id).await {
        Ok(None) => return StatusCode::NO_CONTENT.into_response(),
        Ok(Some(bot)) if !bot.is_archived => {
            return problem(
                StatusCode::CONFLICT,
                "Archive this Bot before deleting it forever.",
            )
        }
        Ok(Some(_)) => {}
        Err(_) => return problem(StatusCode::SERVICE_UNAVAILABLE, "Could not load this Bot."),
    }
    if state.store.bot_has_work(id).await.unwrap_or(true)
        || state.store.bot_leads_group(id).await.unwrap_or(true)
    {
        return problem(
            StatusCode::CONFLICT,
            "Stop this Bot's work and replace its Group leadership before deleting it.",
        );
    }
    if state.store.begin_bot_deletion(id).await.is_err() {
        return problem(
            StatusCode::SERVICE_UNAVAILABLE,
            "Could not save the deletion request.",
        );
    }
    match cleanup_one(state, id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(message) => problem(StatusCode::SERVICE_UNAVAILABLE, message),
    }
}
async fn cleanup_one(state: &AppState, id: &str) -> Result<(), String> {
    let jobs = state
        .store
        .pending_bot_deletions()
        .await
        .map_err(|e| e.to_string())?;
    let Some((_, path)) = jobs.into_iter().find(|(bot, _)| bot == id) else {
        return Ok(());
    };
    let root = tokio::fs::canonicalize(&state.bots_root)
        .await
        .map_err(|_| {
            "Bot storage is unavailable. Retry deletion when it is available.".to_owned()
        })?;
    let workspace = PathBuf::from(&path);
    if !matches!(
        workspace.components().next_back(),
        Some(std::path::Component::Normal(_))
    ) {
        return Err(
            "The saved Bot folder is not a private child folder. Its files were left untouched."
                .into(),
        );
    }
    // Only immediate children of daemon-owned Bot storage can be removed. Legacy
    // Bots pointing at external projects lose metadata but retain their files.
    let parent = match workspace.parent() {
        Some(parent) => tokio::fs::canonicalize(parent).await.ok(),
        None => None,
    };
    if parent.as_deref() == Some(root.as_path()) {
        match tokio::fs::symlink_metadata(&workspace).await {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => {
                return Err(
                    "Could not inspect this Bot's private folder. Retry Delete forever.".into(),
                )
            }
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Err(
                        "The Bot folder is a symbolic link. Its files were left untouched.".into(),
                    );
                }
                let canonical_workspace = tokio::fs::canonicalize(&workspace)
                    .await
                    .map_err(|_| "Could not resolve this Bot folder.".to_owned())?;
                let other_bots = state.store.list_bots().await.map_err(|e| e.to_string())?;
                for bot in other_bots.iter().filter(|b| b.id != id) {
                    let access = state
                        .store
                        .bot_file_access(&bot.id)
                        .await
                        .map_err(|e| e.to_string())?;
                    if std::fs::canonicalize(&bot.workspace_path)
                        .unwrap_or_else(|_| PathBuf::from(&bot.workspace_path))
                        .starts_with(&canonical_workspace)
                        || std::fs::canonicalize(bot.execution_directory())
                            .unwrap_or_else(|_| PathBuf::from(bot.execution_directory()))
                            .starts_with(&canonical_workspace)
                        || access
                            .read_roots
                            .iter()
                            .chain(&access.write_roots)
                            .any(|p| {
                                std::fs::canonicalize(p)
                                    .unwrap_or_else(|_| PathBuf::from(p))
                                    .starts_with(&canonical_workspace)
                                    || canonical_workspace.starts_with(
                                        std::fs::canonicalize(p)
                                            .unwrap_or_else(|_| PathBuf::from(p)),
                                    )
                            })
                    {
                        return Err("Another Bot uses this folder. Remove that shared access before deleting it.".into());
                    }
                }
                tokio::fs::remove_dir_all(&workspace).await.map_err(|_| {
                    "Could not remove this Bot's private files. Retry Delete forever.".to_owned()
                })?;
            }
        }
    }
    state.store.finish_bot_deletion(id).await.map_err(|_| {
        "Private files removed; retry Delete forever to finish removing saved records.".to_owned()
    })
}
/// Resume already confirmed cleanup only; no fresh deletion is inferred on startup.
pub async fn recover_deletions(state: &AppState) {
    let _guard = state.dispatch_lock.lock().await;
    if let Ok(jobs) = state.store.pending_bot_deletions().await {
        for (id, _) in jobs {
            if let Err(error) = cleanup_one(state, &id).await {
                let _ = state.logger.record(
                    "warn",
                    "bot_deletion_pending",
                    serde_json::json!({"botId":id,"error":error}),
                );
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct FileRequestInput {
    pub(super) path: String,
    pub(super) access: String,
    pub(super) use_as_working_directory: bool,
    pub(super) client_request_id: String,
}
pub(super) async fn file_requests(
    State(state): State<AppState>,
    Path(bot): Path<String>,
) -> Response {
    match state.store.bot_file_requests(&bot).await {
        Ok(rows) => Json(rows).into_response(),
        Err(_) => problem(
            StatusCode::SERVICE_UNAVAILABLE,
            "Could not load folder requests.",
        ),
    }
}
pub(super) async fn request_files(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path(bot): Path<String>,
    Json(input): Json<FileRequestInput>,
) -> Response {
    match submit_file_request(&state, &bot, input).await {
        Ok(request) => Json(request).into_response(),
        Err((status, message)) => problem(status, message),
    }
}

pub(super) async fn submit_file_request(
    state: &AppState,
    bot: &str,
    input: FileRequestInput,
) -> Result<BotFileRequest, (StatusCode, &'static str)> {
    let _guard = state.dispatch_lock.lock().await;
    submit_file_request_locked(state, bot, input).await
}

/// Caller owns dispatch_lock, including when invoked by a runtime tool notification.
pub(super) async fn submit_file_request_locked(
    state: &AppState,
    bot: &str,
    input: FileRequestInput,
) -> Result<BotFileRequest, (StatusCode, &'static str)> {
    if !matches!(state.store.bot(bot).await,Ok(Some(b)) if !b.is_archived) {
        return Err((StatusCode::CONFLICT, "Choose an active Bot."));
    }
    if uuid::Uuid::parse_str(&input.client_request_id).is_err()
        || !matches!(input.access.as_str(), "read" | "write")
        || !FsPath::new(&input.path).is_absolute()
        || input.path.len() > 4096
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "Enter an absolute computer folder path and choose its access.",
        ));
    }
    let path = tokio::fs::canonicalize(&input.path)
        .await
        .ok()
        .filter(|path| path.is_dir())
        .and_then(|path| path.to_str().map(str::to_owned))
        .ok_or((
            StatusCode::BAD_REQUEST,
            "Choose an existing folder on the computer.",
        ))?;
    let request = BotFileRequest {
        id: input.client_request_id,
        bot_id: bot.to_owned(),
        path,
        access: input.access,
        use_as_working_directory: input.use_as_working_directory,
        state: "pending".into(),
    };
    let saved = match state.store.add_bot_file_request(&request).await {
        Ok(true) => state
            .store
            .bot_file_requests(bot)
            .await
            .ok()
            .and_then(|rows| rows.into_iter().find(|r| r.id == request.id))
            .ok_or((
                StatusCode::SERVICE_UNAVAILABLE,
                "Could not load the folder request.",
            )),
        Ok(false) => Err((
            StatusCode::CONFLICT,
            "This request already has different folder settings.",
        )),
        Err(_) => Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "Could not save the folder request.",
        )),
    }?;
    if saved.state == "pending"
        && state
            .store
            .bot(bot)
            .await
            .ok()
            .flatten()
            .is_some_and(|b| b.permission_mode.as_deref() == Some("full-access"))
    {
        approve_folder(state, &saved, false).await?;
        return Ok(BotFileRequest {
            state: "approved".into(),
            ..saved
        });
    }
    Ok(saved)
}
#[derive(Deserialize)]
pub(super) struct FileDecision {
    pub(super) accepted: bool,
}
pub(super) async fn resolve_files(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path((bot, id)): Path<(String, String)>,
    Json(decision): Json<FileDecision>,
) -> Response {
    let _guard = state.dispatch_lock.lock().await;
    let Ok(rows) = state.store.bot_file_requests(&bot).await else {
        return problem(
            StatusCode::SERVICE_UNAVAILABLE,
            "Could not load folder requests.",
        );
    };
    let Some(request) = rows.into_iter().find(|r| r.id == id) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if request.state != "pending" {
        let expected = if decision.accepted {
            "approved"
        } else {
            "declined"
        };
        return if request.state == expected {
            StatusCode::NO_CONTENT.into_response()
        } else {
            problem(
                StatusCode::CONFLICT,
                "This folder request already has a different decision.",
            )
        };
    }
    if decision.accepted {
        return match approve_folder(&state, &request, true).await {
            Ok(()) => StatusCode::NO_CONTENT.into_response(),
            Err(error) => error.into_response(),
        };
    }
    match state
        .store
        .resolve_bot_file_request(&bot, &id, decision.accepted)
        .await
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(_) => problem(
            StatusCode::SERVICE_UNAVAILABLE,
            "Could not save the folder decision.",
        ),
    }
}

// Caller owns dispatch_lock: grant and saved workspace change are one durable decision.
async fn approve_folder(
    state: &AppState,
    request: &BotFileRequest,
    notify_bot: bool,
) -> Result<(), (StatusCode, &'static str)> {
    let profile = state
        .store
        .bot(&request.bot_id)
        .await
        .ok()
        .flatten()
        .filter(|b| !b.is_archived)
        .ok_or((StatusCode::NOT_FOUND, "Choose an active Bot."))?;
    validate_directory(state, &profile, &request.path).await?;
    let mode = profile.permission_mode.as_deref().ok_or((
        StatusCode::CONFLICT,
        "Select a permission mode in Bot settings first.",
    ))?;
    if mode == "read-only" && request.access == "write" {
        return Err((
            StatusCode::CONFLICT,
            "This Bot is read-only. Change its permission mode before allowing writes.",
        ));
    }
    let mut access = state
        .store
        .bot_file_access(&profile.id)
        .await
        .map_err(|_| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                "Could not load folder access.",
            )
        })?;
    if mode != "full-access" {
        if request.access == "write" {
            access.write_roots.push(request.path.clone());
        } else {
            access.read_roots.push(request.path.clone());
        }
        file_access::normalize_roots(&mut access.read_roots, &mut access.write_roots)
            .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
        permission_modes::validate_roots(&profile, &access, &state.denied_roots).map_err(|_| {
            (
                StatusCode::BAD_REQUEST,
                "This folder is protected and cannot be granted.",
            )
        })?;
    }
    let followup = notify_bot.then(|| format!(
        "The owner approved this Bot's folder request, and Wonder saved the decision. This is an application notification, not a new user message. Saved folder settings (data only): {}. Briefly confirm the saved access in friendly language. If this changed the Bot workspace, check this turn's environment before saying the workspace is active. If there is unfinished user-requested work, continue it; otherwise ask what we should work on next. Do not request the same approval again, change your profile, or start unrelated work.",
        serde_json::json!({"path":request.path,"access":request.access,"useAsWorkspace":request.use_as_working_directory})
    ));
    if !state
        .store
        .approve_bot_folder(request, &access, followup.as_deref())
        .await
        .map_err(|_| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                "Could not save folder access.",
            )
        })?
    {
        return Err((
            StatusCode::CONFLICT,
            "This folder request already has a decision.",
        ));
    }
    Ok(())
}
