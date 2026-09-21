//! Selected local command file access. Connected apps and computer control are separate.
use super::*;
use wonder_store::BotFileAccess;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Change {
    revision: i64,
    read_roots: Vec<String>,
    write_roots: Vec<String>,
}

pub(super) fn normalize_roots(
    reads: &mut Vec<String>,
    writes: &mut Vec<String>,
) -> Result<(), &'static str> {
    if reads.len() + writes.len() > 32 {
        return Err("Choose up to 32 locations.");
    }
    for path in reads.iter_mut().chain(writes.iter_mut()) {
        let canonical =
            std::fs::canonicalize(&*path).map_err(|_| "Choose an existing file or folder.")?;
        if !canonical.is_file() && !canonical.is_dir() {
            return Err("Choose a regular file or folder.");
        }
        *path = canonical
            .to_str()
            .ok_or("This location's name is not supported.")?
            .to_owned();
    }
    reads.sort();
    reads.dedup();
    writes.sort();
    writes.dedup();
    reads.retain(|path| !writes.contains(path));
    Ok(())
}

fn validate_saved(access: &BotFileAccess) -> Result<(), String> {
    for path in access.read_roots.iter().chain(&access.write_roots) {
        let canonical = std::fs::canonicalize(path).map_err(|_| {
            "An allowed location is missing. Review this Bot's file access.".to_owned()
        })?;
        if canonical.to_string_lossy() != *path {
            return Err("An allowed location changed. Review this Bot's file access.".into());
        }
    }
    Ok(())
}
pub fn configured_override(
    bot: &StoredBot,
    access: &BotFileAccess,
    denies: &[&str],
) -> Result<String, String> {
    validate_saved(access)?;
    // Compare real locations, while leaving the original profile rules intact.
    // A recursive deny names the same protected root for grant validation.
    let protected = denies
        .iter()
        .map(|deny| {
            crate::filesystem::protected_root(FsPath::new(deny.strip_suffix("/**").unwrap_or(deny)))
                .map_err(|(_, message)| message.to_owned())
        })
        .collect::<Result<Vec<_>, _>>()?;
    let workspace = crate::filesystem::protected_root(FsPath::new(&bot.workspace_path))
        .map_err(|(_, message)| message.to_owned())?;
    for path in access.read_roots.iter().chain(&access.write_roots) {
        if protected
            .iter()
            .any(|deny| FsPath::new(path).starts_with(deny))
            && !FsPath::new(path).starts_with(&workspace)
        {
            return Err("Protected Wonder locations cannot be granted.".into());
        }
    }
    if access
        .read_roots
        .iter()
        .any(|path| path == &bot.workspace_path)
    {
        return Err("The Bot workspace already has read and write access.".into());
    }
    build_permission_override(
        &bot.permission_profile,
        &bot.workspace_path,
        &access
            .read_roots
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        &access
            .write_roots
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        denies,
    )
    .map_err(|e| e.to_string())
}
pub(super) async fn dispatch_check(
    state: &AppState,
    bot: &StoredBot,
    profile: &str,
) -> Result<(), String> {
    if bot.is_archived {
        return Err("This Bot is archived. Restore it before starting work.".into());
    }
    if bot.permission_mode.is_some() {
        if profile != bot.effective_permission_profile() {
            return Err("Conversation access cannot override this Bot's permission mode.".into());
        }
        permission_modes::runtime_roots(state, bot).await?;
        let cwd = std::fs::canonicalize(bot.execution_directory())
            .map_err(|_| "The project folder is unavailable. Review Bot settings.".to_owned())?;
        if cwd.to_str() != Some(bot.execution_directory()) || !cwd.is_dir() {
            return Err("The project folder changed. Review Bot settings.".into());
        }
        crate::bot_management::validate_directory(state, bot, bot.execution_directory())
            .await
            .map_err(|(_, message)| message.to_owned())?;
        return Ok(());
    }
    let access = state
        .store
        .bot_file_access(&bot.id)
        .await
        .map_err(|e| e.to_string())?;
    if access.revision > 0 && profile != bot.permission_profile {
        return Err(
            "This conversation uses an older access profile. Reset its access to the Bot default."
                .into(),
        );
    }
    if access.revision != access.applied_revision {
        return Err("File access is saved but not active. Review this Bot’s file access.".into());
    }
    validate_saved(&access)?;
    if bot.working_directory.is_none() {
        return Ok(());
    }
    let cwd = std::fs::canonicalize(bot.execution_directory())
        .map_err(|_| "The project folder is unavailable. Review Bot settings.".to_owned())?;
    if cwd.to_string_lossy() != bot.execution_directory()
        || !(cwd.starts_with(&bot.workspace_path)
            || access
                .read_roots
                .iter()
                .chain(&access.write_roots)
                .any(|root| cwd.starts_with(root)))
    {
        return Err(
            "The project folder is no longer allowed. Review this Bot’s file access.".into(),
        );
    }
    crate::bot_management::validate_directory(state, bot, bot.execution_directory())
        .await
        .map_err(|(_, message)| message.to_owned())?;
    Ok(())
}
pub(super) async fn verify(
    state: &AppState,
    app_server: &mut AppServerClient,
    bot: &StoredBot,
) -> Result<(), String> {
    if bot.permission_mode.is_some() {
        return permission_modes::verify(state, app_server, bot).await;
    }
    let access = state
        .store
        .bot_file_access(&bot.id)
        .await
        .map_err(|e| e.to_string())?;
    // Legacy workspace-only profiles are already checked by the existing readiness gate.
    if access.revision == 0 {
        return Ok(());
    }
    validate_saved(&access)?;
    let listing = app_server
        .request(
            "permissionProfile/list",
            serde_json::json!({"cwd":bot.workspace_path}),
        )
        .await
        .map_err(|e| e.to_string())?;
    let listing = listing
        .result
        .ok_or("File access profile could not be verified")?;
    wonder_app_server::require_named_profile(&listing, &bot.permission_profile)
        .map_err(str::to_owned)?;
    let expected = wonder_app_server::permission_filesystem(
        &bot.workspace_path,
        &access
            .read_roots
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        &access
            .write_roots
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        &state
            .denied_roots
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
    )
    .map_err(|e| e.to_string())?;
    let result = app_server
        .request(
            "config/read",
            serde_json::json!({"cwd":bot.workspace_path,"includeLayers":false}),
        )
        .await
        .map_err(|e| e.to_string())?;
    let config = result.result.ok_or("File access could not be verified")?;
    let profile = &config["config"]["permissions"][&bot.permission_profile];
    let filesystem = profile["filesystem"]
        .as_object()
        .ok_or("File access rules are unavailable")?;
    let actual = filesystem
        .iter()
        .filter(|(_, v)| !v.is_null())
        .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_owned()))
        .collect::<std::collections::BTreeMap<_, _>>();
    if actual != expected
        || !profile["extends"].is_null()
        || profile["workspace_roots"]
            .as_object()
            .is_some_and(|roots| !roots.is_empty())
    {
        return Err("Effective file access does not match the selected locations. Check managed settings on your Mac.".into());
    }
    state
        .store
        .apply_bot_file_access(&bot.id, access.revision)
        .await
        .map_err(|e| e.to_string())
}

pub(super) async fn get(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path(id): Path<String>,
) -> Response {
    let bot = match state.store.list_bots().await {
        Ok(bots) => bots.into_iter().find(|b| b.id == id),
        Err(_) => None,
    };
    let Some(bot) = bot else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let access = match state.store.bot_file_access(&id).await {
        Ok(a) => a,
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    };
    Json(serde_json::json!({"botId":id,"botName":bot.name,"workspacePath":bot.workspace_path,"access":access})).into_response()
}
pub(super) async fn update(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path(id): Path<String>,
    Json(mut change): Json<Change>,
) -> Response {
    if change.revision < 0 {
        return (StatusCode::BAD_REQUEST, "Invalid file access revision.").into_response();
    }
    if let Err(message) = normalize_roots(&mut change.read_roots, &mut change.write_roots) {
        return (StatusCode::BAD_REQUEST, message).into_response();
    }
    let _guard = state.dispatch_lock.lock().await;
    let bot = match state.store.list_bots().await {
        Ok(bots) => bots.into_iter().find(|b| b.id == id),
        Err(_) => None,
    };
    let Some(bot) = bot else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let busy = if bot.permission_mode.is_some() {
        state.store.bot_has_work(&id).await
    } else {
        state.store.has_unsettled_execution().await
    };
    if busy.unwrap_or(true) {
        return (
            StatusCode::CONFLICT,
            "Finish or resolve active work before changing file access.",
        )
            .into_response();
    }
    let access = BotFileAccess {
        revision: change.revision,
        applied_revision: 0,
        read_roots: change.read_roots,
        write_roots: change.write_roots,
    };
    if bot.permission_mode.is_some() {
        if let Err(error) = permission_modes::validate_roots(&bot, &access, &state.denied_roots) {
            return (StatusCode::BAD_REQUEST, error).into_response();
        }
        return match state
            .store
            .save_bot_file_access(
                &id,
                change.revision,
                &access.read_roots,
                &access.write_roots,
            )
            .await
        {
            Ok(true) => {
                if state
                    .store
                    .apply_bot_file_access(&id, change.revision + 1)
                    .await
                    .is_err()
                {
                    return StatusCode::SERVICE_UNAVAILABLE.into_response();
                }
                get(State(state.clone()), Extension(OwnerAuthority), Path(id)).await
            }
            Ok(false) => (
                StatusCode::CONFLICT,
                "File access changed elsewhere. Reload before saving.",
            )
                .into_response(),
            Err(_) => StatusCode::SERVICE_UNAVAILABLE.into_response(),
        };
    }
    let override_value = match configured_override(
        &bot,
        &access,
        &state
            .denied_roots
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
    ) {
        Ok(value) => value,
        Err(_) => return (
            StatusCode::BAD_REQUEST,
            "That location cannot be granted in scoped access. Choose a project file or folder.",
        )
            .into_response(),
    };
    match state
        .store
        .save_bot_file_access(
            &id,
            change.revision,
            &access.read_roots,
            &access.write_roots,
        )
        .await
    {
        Ok(true) => {}
        Ok(false) => {
            return (
                StatusCode::CONFLICT,
                "File access changed elsewhere. Reload before saving.",
            )
                .into_response()
        }
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
    let config = {
        let mut config = state.launch_config.lock().await;
        let prefix = format!("permissions.{}=", bot.permission_profile);
        config
            .permission_overrides
            .retain(|value| !value.starts_with(&prefix));
        config.permission_overrides.push(override_value);
        config.clone()
    };
    let mut runtime = state.app_server.lock().await;
    if runtime.restart(config).await.is_err() || verify(&state, &mut runtime, &bot).await.is_err() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "File access was saved but could not activate. Restart Wonder, then review it.",
        )
            .into_response();
    }
    state.ingestion.request_reconciliation();
    drop(runtime);
    get(State(state.clone()), Extension(OwnerAuthority), Path(id)).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configured_grants_reject_protected_symlink_targets_and_preserve_profile_rules() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let protected = root.join("protected");
        let alias = root.join("protected-alias");
        let workspace = root.join("workspace");
        std::fs::create_dir(&protected).unwrap();
        std::fs::create_dir(&workspace).unwrap();
        std::os::unix::fs::symlink(&protected, &alias).unwrap();
        let secret = protected.join("secret.txt");
        std::fs::write(&secret, "private").unwrap();
        let allowed = root.join("allowed.txt");
        std::fs::write(&allowed, "allowed").unwrap();
        let bot = StoredBot {
            id: "bot".into(),
            name: "Test".into(),
            role: "Test".into(),
            system_prompt: "Test".into(),
            workspace_path: workspace.to_str().unwrap().into(),
            working_directory: None,
            avatar_color: None,
            avatar_shape: None,
            avatar_palette: None,
            avatar_legacy_color: None,
            permission_profile: "test".into(),
            permission_mode: None,
            approval_mode: None,
            model: None,
            reasoning_effort: None,
            service_tier: None,
            is_archived: false,
            conversation_id: None,
        };
        for deny in [
            alias.to_str().unwrap().to_owned(),
            format!("{}/**", alias.display()),
        ] {
            for write in [false, true] {
                let mut access = BotFileAccess::default();
                if write {
                    access.write_roots.push(secret.to_str().unwrap().into());
                } else {
                    access.read_roots.push(secret.to_str().unwrap().into());
                }
                assert_eq!(
                    configured_override(&bot, &access, &[&deny]).unwrap_err(),
                    "Protected Wonder locations cannot be granted."
                );
            }
            let access = BotFileAccess {
                read_roots: vec![allowed.to_str().unwrap().into()],
                ..Default::default()
            };
            assert_eq!(
                configured_override(&bot, &access, &[&deny]).unwrap(),
                build_permission_override(
                    &bot.permission_profile,
                    &bot.workspace_path,
                    &[allowed.to_str().unwrap()],
                    &[],
                    &[&deny],
                )
                .unwrap()
            );
        }
    }
    #[test]
    fn saved_grants_fail_closed_after_removal_or_symlink_replacement() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let file = root.join("selected.txt");
        std::fs::write(&file, "original").unwrap();
        let access = BotFileAccess {
            read_roots: vec![file.to_string_lossy().into_owned()],
            ..Default::default()
        };
        assert!(validate_saved(&access).is_ok());
        std::fs::remove_file(&file).unwrap();
        assert!(validate_saved(&access).is_err());
        #[cfg(unix)]
        {
            let other = root.join("other.txt");
            std::fs::write(&other, "different").unwrap();
            std::os::unix::fs::symlink(other, file).unwrap();
            assert!(validate_saved(&access).is_err());
        }
    }
}
