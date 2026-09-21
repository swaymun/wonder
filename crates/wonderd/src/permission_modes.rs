//! Codex's built-in permission profiles, selected per Bot.
use super::*;
use wonder_store::BotFileAccess;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub(super) enum PermissionMode {
    ReadOnly,
    Workspace,
    FullAccess,
}
impl PermissionMode {
    pub(super) fn id(self) -> &'static str {
        match self {
            Self::ReadOnly => "read-only",
            Self::Workspace => "workspace",
            Self::FullAccess => "full-access",
        }
    }
    fn profile(self) -> &'static str {
        match self {
            Self::ReadOnly => ":read-only",
            Self::Workspace => ":workspace",
            Self::FullAccess => ":danger-full-access",
        }
    }
    fn approval(self) -> &'static str {
        match self {
            Self::FullAccess => "never",
            _ => "on-request",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum ApprovalMode {
    AskForApproval,
    ApproveForMe,
    FullAccess,
}
impl ApprovalMode {
    pub(super) fn id(self) -> &'static str {
        match self {
            Self::AskForApproval => "ask-for-approval",
            Self::ApproveForMe => "approve-for-me",
            Self::FullAccess => "full-access",
        }
    }
    fn profile(self) -> &'static str {
        match self {
            Self::FullAccess => ":danger-full-access",
            _ => ":workspace",
        }
    }
    fn policy(self) -> &'static str {
        match self {
            Self::FullAccess => "never",
            _ => "on-request",
        }
    }
    fn reviewer(self) -> &'static str {
        match self {
            Self::ApproveForMe => "auto_review",
            _ => "user",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ApprovalModeOption {
    pub id: &'static str,
    pub allowed: bool,
}

#[derive(Clone, Debug)]
pub(super) struct ResolvedPermissions {
    pub permission_profile: String,
    pub approval_policy: &'static str,
    pub approvals_reviewer: &'static str,
}

pub(super) fn resolve(bot: &StoredBot) -> ResolvedPermissions {
    let permission_profile = bot.effective_permission_profile().to_owned();
    // Scope remains authoritative. In particular, group_collaboration has
    // already attenuated a Full Bot before this resolver is called.
    let (approval_policy, approvals_reviewer) =
        if bot.permission_mode.as_deref() == Some("full-access") {
            ("never", "user")
        } else {
            match bot.approval_mode.as_deref() {
                Some("approve-for-me") => ("on-request", "auto_review"),
                Some("full-access") => ("never", "user"),
                Some("ask-for-approval") => ("on-request", "user"),
                _ => (bot.approval_policy(), "user"),
            }
        };
    ResolvedPermissions {
        permission_profile,
        approval_policy,
        approvals_reviewer,
    }
}

pub(super) fn legacy_approval_mode(permission_mode: Option<&str>) -> Option<ApprovalMode> {
    match permission_mode {
        Some("read-only" | "workspace") => Some(ApprovalMode::AskForApproval),
        Some("full-access") => Some(ApprovalMode::FullAccess),
        _ => None,
    }
}

fn profile_allowed(catalog: &RuntimeCatalog, profile: &str, cwd: Option<&str>) -> bool {
    match cwd {
        Some(cwd) => catalog
            .profiles_for(cwd)
            .iter()
            .any(|p| p.id == profile && p.allowed),
        None => catalog
            .permission_profiles_by_cwd
            .values()
            .flatten()
            .any(|p| p.id == profile && p.allowed),
    }
}

fn requirements_allow(
    catalog: &RuntimeCatalog,
    profile: &str,
    approval: &str,
    reviewer: &str,
) -> bool {
    (!catalog.permission_profiles_restricted
        || catalog.allowed_permission_profiles.get(profile) == Some(&true))
        && (!catalog.approval_policies_restricted
            || catalog
                .allowed_approval_policies
                .iter()
                .any(|p| p == approval))
        && (!catalog.approval_reviewers_restricted
            || catalog
                .allowed_approval_reviewers
                .iter()
                .any(|p| p == reviewer))
}

fn reviewer_allowed_for_model(
    catalog: &RuntimeCatalog,
    bot: &StoredBot,
    reviewer: &str,
    policy: &str,
) -> bool {
    policy == "never"
        || !catalog
            .auto_review_required_on_models
            .as_ref()
            .is_some_and(|models| {
                bot.model
                    .as_deref()
                    .or_else(|| model_option(catalog, None).map(|model| model.id.as_str()))
                    .is_some_and(|model| models.iter().any(|required| required == model))
            })
        || reviewer == "auto_review"
}

pub(super) fn approval_options(
    catalog: &RuntimeCatalog,
    cwd: Option<&str>,
) -> Vec<ApprovalModeOption> {
    approval_option_values(catalog, cwd, None)
}

pub(super) fn approval_options_for_bot(
    catalog: &RuntimeCatalog,
    bot: &StoredBot,
) -> Vec<ApprovalModeOption> {
    approval_option_values(catalog, Some(bot.execution_directory()), Some(bot))
}

fn approval_option_values(
    catalog: &RuntimeCatalog,
    cwd: Option<&str>,
    bot: Option<&StoredBot>,
) -> Vec<ApprovalModeOption> {
    [
        ApprovalMode::AskForApproval,
        ApprovalMode::ApproveForMe,
        ApprovalMode::FullAccess,
    ]
    .into_iter()
    .map(|mode| {
        let candidate = bot.map(|bot| {
            let mut candidate = bot.clone();
            let _ = apply_selection(&mut candidate, None, Some(mode));
            candidate
        });
        let profile = candidate
            .as_ref()
            .map(|bot| bot.effective_permission_profile())
            .unwrap_or(mode.profile());
        let candidate_cwd = candidate
            .as_ref()
            .map(|bot| bot.execution_directory())
            .or(cwd);
        let resolved = candidate
            .as_ref()
            .map(resolve)
            .unwrap_or(ResolvedPermissions {
                permission_profile: profile.to_owned(),
                approval_policy: mode.policy(),
                approvals_reviewer: mode.reviewer(),
            });
        ApprovalModeOption {
            id: mode.id(),
            allowed: profile_allowed(catalog, profile, candidate_cwd)
                && requirements_allow(
                    catalog,
                    profile,
                    resolved.approval_policy,
                    resolved.approvals_reviewer,
                )
                && candidate.as_ref().is_none_or(|bot| {
                    reviewer_allowed_for_model(
                        catalog,
                        bot,
                        resolved.approvals_reviewer,
                        resolved.approval_policy,
                    )
                }),
        }
    })
    .collect()
}

pub(super) fn approval_allowed(catalog: &RuntimeCatalog, bot: &StoredBot) -> bool {
    let resolved = resolve(bot);
    profile_allowed(
        catalog,
        &resolved.permission_profile,
        Some(bot.execution_directory()),
    ) && requirements_allow(
        catalog,
        &resolved.permission_profile,
        resolved.approval_policy,
        resolved.approvals_reviewer,
    ) && reviewer_allowed_for_model(
        catalog,
        bot,
        resolved.approvals_reviewer,
        resolved.approval_policy,
    )
}

pub(super) fn normalize_create_request(request: &mut CreateBotRequest) -> Result<(), String> {
    match (request.permission_mode, request.approval_mode) {
        (Some(scope), Some(approval)) => {
            if matches!(approval, ApprovalMode::FullAccess)
                && !matches!(scope, PermissionMode::FullAccess)
            {
                return Err("Approval and access choices conflict. Choose Full access with unrestricted access, or choose an approval option for the selected access.".into());
            }
            request.permission_mode = Some(match approval {
                ApprovalMode::FullAccess => PermissionMode::FullAccess,
                ApprovalMode::AskForApproval | ApprovalMode::ApproveForMe => match scope {
                    PermissionMode::FullAccess => PermissionMode::Workspace,
                    other => other,
                },
            });
        }
        (Some(scope), None) => {
            request.approval_mode = legacy_approval_mode(Some(scope.id()));
        }
        (None, Some(approval)) => {
            request.permission_mode = Some(match approval {
                ApprovalMode::FullAccess => PermissionMode::FullAccess,
                ApprovalMode::AskForApproval | ApprovalMode::ApproveForMe => {
                    PermissionMode::Workspace
                }
            });
        }
        (None, None) => {
            // New Bot creation has a bounded product default. Existing custom or
            // mode-less Bots never pass through this migration path.
            request.permission_mode = Some(PermissionMode::Workspace);
            request.approval_mode = Some(ApprovalMode::AskForApproval);
        }
    }
    Ok(())
}

pub(super) fn apply_update(
    bot: &mut StoredBot,
    request: &UpdateBotRequest,
) -> Result<bool, String> {
    apply_selection(bot, request.permission_mode, request.approval_mode)
}

pub(super) fn apply_selection(
    bot: &mut StoredBot,
    permission_mode: Option<PermissionMode>,
    approval_mode: Option<ApprovalMode>,
) -> Result<bool, String> {
    let changed = permission_mode.is_some() || approval_mode.is_some();
    if matches!(approval_mode, Some(ApprovalMode::FullAccess))
        && matches!(
            permission_mode,
            Some(PermissionMode::ReadOnly | PermissionMode::Workspace)
        )
    {
        return Err("Approval and access choices conflict. Choose Full access with unrestricted access, or choose an approval option for the selected access.".into());
    }
    if let Some(approval) = approval_mode {
        let was_full = bot.permission_mode.as_deref() == Some("full-access");
        bot.approval_mode = Some(approval.id().into());
        bot.permission_mode = match approval {
            ApprovalMode::FullAccess => Some("full-access".into()),
            ApprovalMode::AskForApproval | ApprovalMode::ApproveForMe => {
                if was_full {
                    Some("workspace".into())
                } else {
                    bot.permission_mode.clone()
                }
            }
        };
    }
    if let Some(scope) = permission_mode {
        bot.permission_mode = Some(scope.id().into());
        if approval_mode.is_none() {
            bot.approval_mode = legacy_approval_mode(Some(scope.id())).map(|m| m.id().into());
        } else if matches!(
            approval_mode,
            Some(ApprovalMode::AskForApproval | ApprovalMode::ApproveForMe)
        ) && matches!(scope, PermissionMode::FullAccess)
        {
            bot.permission_mode = Some("workspace".into());
        }
    }
    Ok(changed)
}

pub(super) fn options(catalog: &RuntimeCatalog) -> Vec<serde_json::Value> {
    [
        PermissionMode::ReadOnly,
        PermissionMode::Workspace,
        PermissionMode::FullAccess,
    ]
    .into_iter()
    .map(|mode| {
        let allowed = catalog
            .permission_profiles_by_cwd
            .values()
            .flatten()
            .any(|p| p.id == mode.profile() && p.allowed)
            && requirements_allow(catalog, mode.profile(), mode.approval(), "user");
        serde_json::json!({"id":mode.id(),"allowed":allowed})
    })
    .collect()
}

pub(super) async fn verify(
    state: &AppState,
    runtime: &mut AppServerClient,
    bot: &StoredBot,
) -> Result<(), String> {
    let resolved = resolve(bot);
    let profile = resolved.permission_profile.as_str();
    if !requirements_allow(
        &*state.runtime_catalog.read().await,
        profile,
        resolved.approval_policy,
        resolved.approvals_reviewer,
    ) {
        return Err("This permission mode is unavailable under your Mac's Codex settings.".into());
    }
    if !reviewer_allowed_for_model(
        &*state.runtime_catalog.read().await,
        bot,
        resolved.approvals_reviewer,
        resolved.approval_policy,
    ) {
        return Err("This model requires automatic approval review on your Mac.".into());
    }
    let response = runtime
        .request(
            "permissionProfile/list",
            serde_json::json!({"cwd":bot.execution_directory()}),
        )
        .await
        .map_err(|e| e.to_string())?;
    let result = response
        .result
        .ok_or("Permission modes could not be checked.")?;
    wonder_app_server::require_named_profile(&result, profile).map_err(str::to_owned)?;
    let mut catalog = state.runtime_catalog.write().await;
    catalog.apply_permission_profiles(bot.execution_directory(), &result);
    Ok(())
}

pub(super) fn validate_roots(
    bot: &StoredBot,
    access: &BotFileAccess,
    denied: &[String],
) -> Result<(), String> {
    if bot.permission_mode.as_deref() != Some("workspace") {
        return Ok(());
    }
    // Native workspace permissions read broadly. Only selected writes are sandbox roots.
    let writes = BotFileAccess {
        write_roots: access.write_roots.clone(),
        ..Default::default()
    };
    file_access::configured_override(
        bot,
        &writes,
        &denied.iter().map(String::as_str).collect::<Vec<_>>(),
    )
    .map(|_| ())
}

pub(super) async fn runtime_roots(
    state: &AppState,
    bot: &StoredBot,
) -> Result<Vec<String>, String> {
    let mut roots = vec![bot.workspace_path.clone()];
    // A collaborative turn writes only inside its shared group folder. The
    // Bot's private additional write grants do not leak into this assignment.
    let group_workspace = FsPath::new(&bot.workspace_path)
        .starts_with(FsPath::new(&state.bots_root).join(".group-files"));
    if bot.permission_mode.as_deref() == Some("workspace") {
        roots.push(bot.execution_directory().to_owned());
        if !group_workspace {
            let access = state
                .store
                .bot_file_access(&bot.id)
                .await
                .map_err(|e| e.to_string())?;
            validate_roots(bot, &access, &state.denied_roots)?;
            roots.extend(access.write_roots);
        }
    }
    roots.sort();
    roots.dedup();
    Ok(roots)
}

pub(super) async fn create_native(
    state: &AppState,
    mut bot: StoredBot,
    request: &CreateBotRequest,
) -> Result<BotSummary, (StatusCode, String)> {
    let unavailable = |error: String| (StatusCode::SERVICE_UNAVAILABLE, error);
    bot.permission_mode = request.permission_mode.map(|mode| mode.id().to_owned());
    bot.approval_mode = request
        .approval_mode
        .map(|mode| mode.id().to_owned())
        .or_else(|| {
            legacy_approval_mode(request.permission_mode.map(|mode| mode.id()))
                .map(|mode| mode.id().to_owned())
        });
    let access = BotFileAccess {
        read_roots: request.read_roots.clone(),
        write_roots: request.write_roots.clone(),
        ..Default::default()
    };
    validate_roots(&bot, &access, &state.denied_roots)
        .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    if !access.read_roots.is_empty() || !access.write_roots.is_empty() {
        if !state
            .store
            .save_bot_file_access(&bot.id, 0, &access.read_roots, &access.write_roots)
            .await
            .map_err(|e| unavailable(e.to_string()))?
        {
            return Err(unavailable(
                "File access changed. Retry creating this Bot.".into(),
            ));
        }
        state
            .store
            .apply_bot_file_access(&bot.id, 1)
            .await
            .map_err(|e| unavailable(e.to_string()))?;
    }
    if let Some(directory) = request
        .working_directory
        .as_deref()
        .filter(|p| !p.is_empty())
    {
        bot_management::validate_directory(state, &bot, directory)
            .await
            .map_err(|(s, m)| (s, m.to_owned()))?;
        bot.working_directory = Some(directory.into());
    }
    verify(state, &mut *state.app_server.lock().await, &bot)
        .await
        .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    bot.avatar_color = request.avatar_color.clone();
    state
        .store
        .update_managed_bot(&bot, [false; 3])
        .await
        .map_err(|e| unavailable(e.to_string()))?;
    bot.conversation_id = Some(
        state
            .store
            .ensure_bot_workspace(&bot.id, &bot.name, &now_ms().to_string())
            .await
            .map_err(|e| unavailable(e.to_string()))?,
    );
    Ok(bot_summary(bot))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use axum::body::to_bytes;
    use serde_json::{json, Value};
    use tower::ServiceExt;

    pub(crate) async fn fixture() -> (tempfile::TempDir, AppState) {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let file = dir.path().join("runtime.py");
        let source = std::fs::read_to_string(&file).unwrap()
            .replace("{'data': [{'name': 'test', 'allowed': True}, {'name': ':read-only', 'allowed': True}, {'name': ':workspace', 'allowed': True}, {'name': ':danger-full-access', 'allowed': True}]}", "{'data': [{'id': p, 'allowed': True} for p in ['test', ':read-only', ':workspace', ':danger-full-access']]}")
            .replace("with open(root + '/requests', 'a') as log: log.write(method + '\\n')", "with open(root + '/requests', 'a') as log: log.write(method + '\\n')\n    with open(root + '/payloads', 'a') as log: log.write(json.dumps(r) + '\\n')");
        std::fs::write(file, source).unwrap();
        state
            .app_server
            .lock()
            .await
            .restart(state.launch_config.lock().await.clone())
            .await
            .unwrap();
        let home = std::fs::canonicalize(&state.bot_home).unwrap();
        state
            .store
            .upsert_bot(
                "bot",
                "Bot",
                "Assistant",
                "Help",
                home.to_str().unwrap(),
                "test",
                None,
                None,
                "now",
            )
            .await
            .unwrap();
        state
            .runtime_catalog
            .write()
            .await
            .models
            .push(ModelOption {
                id: "fake".into(),
                display_name: "Fake".into(),
                description: None,
                model_specialty: None,
                hidden: false,
                reasoning_efforts: vec![],
                default_reasoning_effort: None,
                service_tiers: vec![],
                default_service_tier: None,
            });
        (dir, state)
    }
    pub(crate) async fn call(
        state: &AppState,
        method: &str,
        path: &str,
        body: Value,
    ) -> (StatusCode, Value) {
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

    pub(crate) fn assert_http_contract(definition: &str, value: &Value) {
        let authority: Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/schemas/wonder-http-v1.json"
        ))
        .unwrap();
        let schema = json!({
            "$ref": format!("#/$defs/{definition}"),
            "$defs": authority["$defs"].clone()
        });
        let validator = jsonschema::validator_for(&schema).unwrap();
        let errors: Vec<_> = validator
            .iter_errors(value)
            .map(|error| error.to_string())
            .collect();
        assert!(errors.is_empty(), "{definition}: {errors:?}");
    }

    fn bot_with_modes(permission_mode: Option<&str>, approval_mode: Option<&str>) -> StoredBot {
        StoredBot {
            id: "bot".into(),
            name: "Bot".into(),
            role: "Assistant".into(),
            system_prompt: "Help".into(),
            workspace_path: "/workspace".into(),
            working_directory: Some("/workspace".into()),
            avatar_color: None,
            avatar_shape: None,
            avatar_palette: None,
            avatar_legacy_color: None,
            permission_profile: "custom-profile".into(),
            permission_mode: permission_mode.map(str::to_owned),
            approval_mode: approval_mode.map(str::to_owned),
            model: Some("required-model".into()),
            reasoning_effort: None,
            service_tier: None,
            is_archived: false,
            conversation_id: None,
        }
    }

    #[test]
    fn approval_modes_have_exact_mappings_and_preserve_scope_axes() {
        let ask = resolve(&bot_with_modes(Some("workspace"), Some("ask-for-approval")));
        assert_eq!(
            (
                ask.permission_profile.as_str(),
                ask.approval_policy,
                ask.approvals_reviewer
            ),
            (":workspace", "on-request", "user")
        );
        let automatic = resolve(&bot_with_modes(Some("read-only"), Some("approve-for-me")));
        assert_eq!(
            (
                automatic.permission_profile.as_str(),
                automatic.approval_policy,
                automatic.approvals_reviewer
            ),
            (":read-only", "on-request", "auto_review")
        );
        let full = resolve(&bot_with_modes(Some("full-access"), Some("full-access")));
        assert_eq!(
            (
                full.permission_profile.as_str(),
                full.approval_policy,
                full.approvals_reviewer
            ),
            (":danger-full-access", "never", "user")
        );
        let custom = resolve(&bot_with_modes(None, Some("approve-for-me")));
        assert_eq!(custom.permission_profile, "custom-profile");
        assert_eq!(
            (custom.approval_policy, custom.approvals_reviewer),
            ("on-request", "auto_review")
        );
    }

    #[test]
    fn create_and_update_reject_conflicting_legacy_scope_and_approval() {
        let request = |permission_mode, approval_mode| CreateBotRequest {
            permission_mode,
            approval_mode,
            read_roots: vec![],
            write_roots: vec![],
            client_request_id: None,
            avatar_color: None,
            working_directory: None,
            name: "Bot".into(),
            role: "Assistant".into(),
            system_prompt: "Help".into(),
            model: None,
            reasoning_effort: None,
            service_tier: None,
        };
        let mut new_default = request(None, None);
        normalize_create_request(&mut new_default).unwrap();
        assert_eq!(new_default.permission_mode, Some(PermissionMode::Workspace));
        assert_eq!(
            new_default.approval_mode,
            Some(ApprovalMode::AskForApproval)
        );
        let mut legacy = request(Some(PermissionMode::ReadOnly), None);
        normalize_create_request(&mut legacy).unwrap();
        assert_eq!(legacy.approval_mode, Some(ApprovalMode::AskForApproval));
        let mut conflict = request(
            Some(PermissionMode::Workspace),
            Some(ApprovalMode::FullAccess),
        );
        assert!(normalize_create_request(&mut conflict).is_err());
        let mut bot = bot_with_modes(Some("workspace"), Some("ask-for-approval"));
        assert!(apply_selection(
            &mut bot,
            Some(PermissionMode::ReadOnly),
            Some(ApprovalMode::FullAccess)
        )
        .is_err());
        assert_eq!(bot.permission_mode.as_deref(), Some("workspace"));
        assert_eq!(bot.approval_mode.as_deref(), Some("ask-for-approval"));
    }

    #[test]
    fn scoped_options_preserve_read_only_and_model_required_auto_review() {
        let mut catalog = RuntimeCatalog::default();
        catalog.permission_profiles_by_cwd.insert(
            "/workspace".into(),
            vec![
                PermissionProfileOption {
                    id: ":read-only".into(),
                    description: None,
                    allowed: true,
                },
                PermissionProfileOption {
                    id: ":workspace".into(),
                    description: None,
                    allowed: false,
                },
                PermissionProfileOption {
                    id: ":danger-full-access".into(),
                    description: None,
                    allowed: false,
                },
            ],
        );
        catalog.auto_review_required_on_models = Some(vec!["required-model".into()]);
        let values = approval_options_for_bot(
            &catalog,
            &bot_with_modes(Some("read-only"), Some("ask-for-approval")),
        );
        assert_eq!(
            values
                .iter()
                .map(|value| (value.id, value.allowed))
                .collect::<Vec<_>>(),
            vec![
                ("ask-for-approval", false),
                ("approve-for-me", true),
                ("full-access", false)
            ]
        );
    }
    #[tokio::test]
    async fn native_permission_modes_persist_and_allow_next_message_choices_during_work() {
        let (dir, state) = fixture().await;
        assert!(state
            .store
            .bot("bot")
            .await
            .unwrap()
            .unwrap()
            .permission_mode
            .is_none());
        let id = "11111111-1111-4111-8111-111111111111";
        let body = json!({"clientRequestId":id,"name":"Native","role":"Assistant","systemPrompt":"Help","permissionMode":"read-only"});
        let (status, created) = call(&state, "POST", "/api/v1/bots", body.clone()).await;
        assert!(status.is_success(), "{status} {created}");
        assert_eq!(created["permissionMode"], "read-only");
        assert_eq!(created["approvalMode"], "ask-for-approval");
        assert_eq!(created["permissionProfile"], ":read-only");
        assert_http_contract("botSummary", &created);
        let (_, host_options) = call(&state, "GET", "/api/v1/bot-options", json!(null)).await;
        assert_eq!(host_options["groupCollaboration"], true);
        assert!(host_options["approvalModes"].is_array());
        assert!(host_options["permissionModes"].is_array());
        assert_http_contract("botOptions", &host_options);
        let conversation = created["conversationId"].as_str().unwrap();
        let (_, scoped_options) = call(
            &state,
            "GET",
            &format!("/api/v1/conversations/{conversation}/composer-options"),
            json!(null),
        )
        .await;
        assert!(scoped_options["approvalModes"].is_array());
        assert!(scoped_options["timezone"].is_string());
        assert_http_contract("composerOptions", &scoped_options);
        let path = format!("/api/v1/bots/{id}");
        let (status, full) = call(
            &state,
            "PATCH",
            &path,
            json!({"permissionMode":"full-access"}),
        )
        .await;
        assert!(status.is_success(), "{status} {full}");
        assert_eq!(full["approvalMode"], "full-access");
        // Composer choices persist as Bot defaults and replace older chat overrides.
        state
            .store
            .upsert_conversation_settings(
                conversation,
                Some("old-model"),
                Some("high"),
                None,
                None,
                "2026-09-08T00:00:00Z",
            )
            .await
            .unwrap();
        let (status, saved) = call(
            &state,
            "PATCH",
            &path,
            json!({"model":"", "reasoningEffort":""}),
        )
        .await;
        assert!(status.is_success(), "{status} {saved}");
        assert!(saved["model"].is_null());
        assert_eq!(saved["permissionMode"], "full-access");
        assert_eq!(saved["approvalMode"], "full-access");
        let (_, settings) = call(
            &state,
            "GET",
            &format!("/api/v1/conversations/{conversation}/settings"),
            json!(null),
        )
        .await;
        assert_ne!(settings["effective"]["model"], "old-model");
        assert!(state
            .store
            .conversation_settings(conversation)
            .await
            .unwrap()
            .unwrap()
            .model
            .is_none());
        let (status, selected) = call(
            &state,
            "PATCH",
            &path,
            json!({"model":"fake", "reasoningEffort":""}),
        )
        .await;
        assert!(status.is_success(), "{status} {selected}");
        assert_eq!(selected["model"], "fake");
        let (_, retry) = call(&state, "POST", "/api/v1/bots", body).await;
        assert_eq!(retry["permissionMode"], "full-access");
        assert_eq!(retry["approvalMode"], "full-access");
        assert!(state
            .store
            .bot("bot")
            .await
            .unwrap()
            .unwrap()
            .permission_mode
            .is_none());
        let reopened = Store::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        assert_eq!(
            reopened.bot(id).await.unwrap().unwrap().model.as_deref(),
            Some("fake")
        );
        assert_eq!(
            reopened
                .bot(id)
                .await
                .unwrap()
                .unwrap()
                .permission_mode
                .as_deref(),
            Some("full-access")
        );
        let conversation = created["conversationId"].as_str().unwrap();
        let MessageInsert::Inserted(message) = state
            .store
            .insert_message("owner", "pending", "Work", "hash", conversation, "now")
            .await
            .unwrap()
        else {
            panic!()
        };
        assert_eq!(
            call(
                &state,
                "PATCH",
                &path,
                json!({"permissionMode":"workspace"})
            )
            .await
            .0,
            StatusCode::OK
        );
        state
            .store
            .update_message_delivery(&message.id, "uncertain", None, None)
            .await
            .unwrap();
        assert_eq!(
            call(
                &state,
                "PATCH",
                &path,
                json!({"permissionMode":"workspace"})
            )
            .await
            .0,
            StatusCode::OK
        );
        state
            .store
            .update_message_delivery(&message.id, "failed", None, None)
            .await
            .unwrap();
        assert!(call(
            &state,
            "PATCH",
            &path,
            json!({"permissionMode":"workspace"})
        )
        .await
        .0
        .is_success());
        assert_eq!(
            call(&state, "PATCH", &path, json!({"permissionMode":"custom"}))
                .await
                .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
        state
            .runtime_catalog
            .write()
            .await
            .permission_profiles_restricted = true;
        state
            .runtime_catalog
            .write()
            .await
            .allowed_permission_profiles
            .insert(":read-only".into(), false);
        assert_eq!(
            call(
                &state,
                "PATCH",
                &path,
                json!({"permissionMode":"read-only"})
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn native_permission_modes_cover_start_resume_turn_and_group_dispatch_without_read_promotion(
    ) {
        let (dir, state) = fixture().await;
        let root = dir.path().canonicalize().unwrap();
        let reads = root.join("read-folder");
        let writes = root.join("write-file");
        std::fs::create_dir(&reads).unwrap();
        std::fs::write(&writes, "keep").unwrap();
        state
            .store
            .save_bot_file_access(
                "bot",
                0,
                &[reads.to_str().unwrap().into()],
                &[writes.to_str().unwrap().into()],
            )
            .await
            .unwrap();
        let mut bot = state.store.bot("bot").await.unwrap().unwrap();
        bot.working_directory = Some(reads.to_str().unwrap().into());
        for mode in [
            PermissionMode::ReadOnly,
            PermissionMode::Workspace,
            PermissionMode::FullAccess,
        ] {
            bot.permission_mode = Some(mode.id().into());
            state
                .store
                .update_managed_bot(&bot, [false; 3])
                .await
                .unwrap();
            verify(&state, &mut *state.app_server.lock().await, &bot)
                .await
                .unwrap();
            for group in [false, true] {
                let conversation = format!(
                    "{}-{}",
                    mode.id(),
                    if group { "group-worker" } else { "direct" }
                );
                state
                    .store
                    .create_conversation(&conversation, "bot", "Test", "now")
                    .await
                    .unwrap();
                // Persisted wider conversation overrides must never bypass the Bot mode.
                state
                    .store
                    .upsert_conversation_settings(
                        &conversation,
                        None,
                        None,
                        None,
                        Some(":danger-full-access"),
                        "now",
                    )
                    .await
                    .unwrap();
                for attempt in 0..2 {
                    let client = format!("{conversation}-{attempt}");
                    let MessageInsert::Inserted(message) = state
                        .store
                        .insert_message("owner", &client, "Work", "hash", &conversation, "now")
                        .await
                        .unwrap()
                    else {
                        panic!()
                    };
                    dispatch_to_codex_inner(
                        state.clone(),
                        message.clone(),
                        group.then(|| "bot".to_owned()),
                        None,
                    )
                    .await;
                    let dispatched = state
                        .store
                        .message_by_id(&message.id)
                        .await
                        .unwrap()
                        .unwrap();
                    assert_eq!(
                        dispatched.state, "accepted_by_codex",
                        "{conversation}: {dispatched:?}"
                    );
                    state
                        .store
                        .update_message_delivery(&message.id, "completed", None, None)
                        .await
                        .unwrap();
                }
            }
        }
        let payloads = std::fs::read_to_string(dir.path().join("payloads")).unwrap();
        let mut starts = 0;
        let mut resumes = 0;
        let mut turns = 0;
        for payload in payloads
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
        {
            match payload["method"].as_str().unwrap() {
                "thread/start" => starts += 1,
                "thread/resume" => resumes += 1,
                "turn/start" => turns += 1,
                _ => continue,
            }
            let params = &payload["params"];
            let profile = params["permissions"].as_str().unwrap();
            assert_eq!(
                params["approvalPolicy"],
                if profile == ":danger-full-access" {
                    "never"
                } else {
                    "on-request"
                }
            );
            let roots = params["runtimeWorkspaceRoots"].as_array().unwrap();
            assert_eq!(roots.contains(&json!(reads)), profile == ":workspace");
            assert!(roots.contains(&json!(bot.workspace_path)));
            assert_eq!(roots.contains(&json!(writes)), profile == ":workspace");
            assert!(!roots.contains(&json!(root)));
        }
        assert_eq!((starts, resumes, turns), (6, 6, 12));
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
