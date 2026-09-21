//! Owner-created project work uses the existing Group dispatcher and turn claims.
use super::*;
use wonder_store::ProjectAssignment;

type Failure = (StatusCode, String);
fn conflict(message: impl Into<String>) -> Failure {
    (StatusCode::CONFLICT, message.into())
}
fn unavailable(error: impl std::fmt::Display) -> Failure {
    (StatusCode::SERVICE_UNAVAILABLE, error.to_string())
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Create {
    client_request_id: String,
    title: String,
    instruction: String,
    bot_id: String,
    base_revision: String,
    #[serde(default)]
    dependency_ids: Vec<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Review {
    result_revision: String,
    validation: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Integrate {
    result_revision: String,
    expected_head: String,
}

pub(super) fn summary(a: &ProjectAssignment) -> serde_json::Value {
    serde_json::json!({"id":a.id,"groupId":a.group_id,"botId":a.bot_id,"title":a.title,
        "projectName":FsPath::new(&a.repository_path).file_name().unwrap_or_default().to_string_lossy(),
        "instruction":a.instruction,"state":a.state,"baseRevision":a.base_revision,
        "resultRevision":a.result_revision,"summary":a.summary,"validation":a.validation,
        "dependencyIds":a.dependency_ids,"createdAt":a.created_at,"updatedAt":a.updated_at,
        "canCancel":a.state=="queued"})
}
pub(super) async fn git(path: &str, args: &[&str]) -> Result<String, String> {
    git_with_index(path, args, None).await
}

/// Run a bounded, read-only Git command for other read-only projections. The
/// caller owns path/scope validation; this helper owns the process boundary so
/// status and diff readers cannot accidentally inherit hooks, fsmonitor,
/// optional locks, an editor, or an external diff helper.
pub(crate) async fn read_only_git_bytes(path: &str, args: &[&str]) -> Result<Vec<u8>, String> {
    use tokio::io::AsyncReadExt;
    let mut command = Command::new("git");
    command
        .arg("-C")
        .arg(path)
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "diff.external=false",
            "-c",
            "diff.trustExitCode=false",
        ])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    let stdout = child.stdout.take().ok_or("Git output unavailable")?;
    let stderr = child.stderr.take().ok_or("Git error output unavailable")?;
    let read = |stream: std::pin::Pin<Box<dyn tokio::io::AsyncRead + Send>>| async move {
        let mut bytes = Vec::new();
        stream
            .take(1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .await
            .map_err(|e| e.to_string())?;
        Ok::<_, String>(bytes)
    };
    let result = tokio::time::timeout(std::time::Duration::from_secs(15), async {
        let (out, err, status) =
            tokio::try_join!(read(Box::pin(stdout)), read(Box::pin(stderr)), async {
                child.wait().await.map_err(|e| e.to_string())
            })?;
        if out.len() > 1024 * 1024 || err.len() > 1024 * 1024 {
            return Err(
                "Git output exceeded its limit. Inspect this change on the Mac.".to_owned(),
            );
        }
        if !status.success() {
            return Err(String::from_utf8_lossy(&err).chars().take(1500).collect());
        }
        Ok(out)
    })
    .await
    .map_err(|_| "Git operation timed out; inspect this workspace on the Mac.".to_owned())?;
    if result.is_err() {
        let _ = child.kill().await;
    }
    result
}
async fn git_with_index(path: &str, args: &[&str], index: Option<&str>) -> Result<String, String> {
    use tokio::io::AsyncReadExt;
    let mut command = Command::new("git");
    command
        .arg("-C")
        .arg(path)
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.fsmonitor=false",
        ])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    if let Some(index) = index {
        command.env("GIT_INDEX_FILE", index);
    }
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    let stdout = child.stdout.take().ok_or("Git output unavailable")?;
    let stderr = child.stderr.take().ok_or("Git error output unavailable")?;
    let read = |stream: std::pin::Pin<Box<dyn tokio::io::AsyncRead + Send>>| async move {
        let mut bytes = Vec::new();
        stream
            .take(1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .await
            .map_err(|e| e.to_string())?;
        if bytes.len() > 1024 * 1024 {
            return Err(
                "Git output exceeded its limit. Inspect this change on the Mac.".to_owned(),
            );
        }
        Ok(bytes)
    };
    let result = tokio::time::timeout(std::time::Duration::from_secs(30), async {
        let (out, err, status) =
            tokio::try_join!(read(Box::pin(stdout)), read(Box::pin(stderr)), async {
                child.wait().await.map_err(|e| e.to_string())
            })?;
        if !status.success() {
            return Err(String::from_utf8_lossy(&err).chars().take(1500).collect());
        }
        Ok(String::from_utf8_lossy(&out).trim().to_owned())
    })
    .await
    .map_err(|_| "Git operation timed out; inspect the assignment before retrying.".to_owned())?;
    if result.is_err() {
        let _ = child.kill().await;
    }
    result
}
fn revision_valid(revision: &str) -> bool {
    matches!(revision.len(), 40 | 64) && revision.bytes().all(|b| b.is_ascii_hexdigit())
}
pub(super) async fn canonical_repo(path: &str) -> Result<String, String> {
    let canonical =
        std::fs::canonicalize(path).map_err(|_| "The project folder is unavailable.")?;
    if canonical.to_str() != Some(path) {
        return Err("The project folder changed. Review Bot settings.".into());
    }
    let root = git(path, &["rev-parse", "--show-toplevel"]).await?;
    if std::fs::canonicalize(&root).map_err(|e| e.to_string())? != canonical {
        return Err("Choose the repository root as this Bot's project folder.".into());
    }
    Ok(root)
}
async fn clean(path: &str) -> Result<(), String> {
    if !git(path, &["status", "--porcelain", "--untracked-files=all"])
        .await?
        .is_empty()
    {
        return Err(
            "The project has uncommitted changes. Commit or review them before continuing.".into(),
        );
    }
    Ok(())
}
// Owner checkouts may contain large generated/untracked trees. Two-tree read-tree
// protects collisions with the incoming result; only tracked changes block upfront.
async fn tracked_clean(path: &str) -> Result<(), String> {
    for args in [
        vec!["diff", "--quiet", "--ignore-submodules=untracked", "--"],
        vec![
            "diff",
            "--cached",
            "--quiet",
            "--ignore-submodules=untracked",
            "HEAD",
            "--",
        ],
    ] {
        git(path, &args).await.map_err(|_| "The project has tracked uncommitted changes. Commit or review them before continuing.".to_owned())?;
    }
    Ok(())
}
async fn ancestor(path: &str, base: &str, result: &str) -> Result<(), String> {
    git(path, &["merge-base", "--is-ancestor", base, result])
        .await
        .map(|_| ())
        .map_err(|_| "The result does not include the required starting revision.".into())
}
async fn authorized_bot(state: &AppState, a: &ProjectAssignment) -> Result<StoredBot, String> {
    let bot = state
        .store
        .bot(&a.bot_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("This Bot is unavailable.")?;
    if bot.is_archived || bot.execution_directory() != a.repository_path {
        return Err(
            "The Bot's project changed. Create a new assignment after reviewing its settings."
                .into(),
        );
    }
    if !matches!(
        bot.permission_mode.as_deref(),
        Some("workspace" | "full-access")
    ) {
        return Err("Project assignments require Workspace or Full access permission mode.".into());
    }
    file_access::dispatch_check(state, &bot, bot.effective_permission_profile()).await?;
    canonical_repo(&a.repository_path).await?;
    if bot.permission_mode.as_deref() == Some("workspace") {
        let roots = permission_modes::runtime_roots(state, &bot).await?;
        if !roots
            .iter()
            .any(|root| FsPath::new(&a.repository_path).starts_with(root))
        {
            return Err("Give this Bot write access to its project folder first.".into());
        }
    }
    let expected = std::fs::canonicalize(&bot.workspace_path)
        .map_err(|_| "The Bot workspace is unavailable.")?
        .join("assignments")
        .join(&a.id);
    if expected.to_str() != Some(&a.worktree_path) {
        return Err("The assignment workspace changed.".into());
    }
    Ok(bot)
}

pub(super) async fn create(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path(group): Path<String>,
    device: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Json(request): Json<Create>,
) -> Result<Json<serde_json::Value>, Failure> {
    let _guard = state.dispatch_lock.lock().await;
    let owner = if let Some(Extension(device)) = device {
        device.device_id
    } else if local.is_some() {
        state
            .store
            .ensure_local_desktop(&now_ms().to_string())
            .await
            .map_err(unavailable)?;
        "wonder-desktop".into()
    } else {
        return Err((StatusCode::FORBIDDEN, "An owner device is required.".into()));
    };
    create_for_owner(&state, group, owner, request).await
}
/// The caller must already hold dispatch_lock and establish owner/Group scope.
pub(super) async fn create_for_owner(
    state: &AppState,
    group: String,
    owner: String,
    request: Create,
) -> Result<Json<serde_json::Value>, Failure> {
    create_for_owner_with_attachments(state, group, owner, request, &[]).await
}

pub(super) async fn create_for_owner_with_attachments(
    state: &AppState,
    group: String,
    owner: String,
    request: Create,
    attachment_ids: &[String],
) -> Result<Json<serde_json::Value>, Failure> {
    if uuid::Uuid::parse_str(&request.client_request_id).is_err() {
        return Err((
            StatusCode::BAD_REQUEST,
            "clientRequestId must be a valid UUID, for example 6f992ae9-851c-4ba4-8472-95381a22a26c. Generate a new UUID for a new assignment and reuse it on retries; task names and descriptive slugs are not valid UUIDs.".into(),
        ));
    }
    if request.title.trim().is_empty() || request.title.len() > 160 {
        return Err((
            StatusCode::BAD_REQUEST,
            "title must contain 1 to 160 bytes of non-blank text.".into(),
        ));
    }
    if request.instruction.trim().is_empty() || request.instruction.len() > 32 * 1024 {
        return Err((
            StatusCode::BAD_REQUEST,
            "instruction must contain 1 to 32768 bytes of non-blank text.".into(),
        ));
    }
    if request.dependency_ids.len() > 16 {
        return Err((
            StatusCode::BAD_REQUEST,
            "dependencyIds may contain at most 16 assignment IDs.".into(),
        ));
    }
    if !revision_valid(&request.base_revision) {
        return Err((StatusCode::BAD_REQUEST, "baseRevision must be a full 40- or 64-character hexadecimal commit revision from the project listing.".into()));
    }
    let mut identity = serde_json::json!({"group":group,"owner":owner,"request":request});
    if !attachment_ids.is_empty() {
        identity["attachmentIds"] = serde_json::json!(attachment_ids);
    }
    let hash = hex::encode(Sha256::digest(serde_json::to_vec(&identity).unwrap()));
    if let Some(a) = state
        .store
        .project_assignment(&request.client_request_id)
        .await
        .map_err(unavailable)?
    {
        if a.creation_hash != hash {
            return Err(conflict(
                "This request already has different assignment settings.",
            ));
        }
        return Ok(Json(summary(&a)));
    }
    let channel = state
        .store
        .channel(&group)
        .await
        .map_err(unavailable)?
        .ok_or((StatusCode::NOT_FOUND, "Group not found.".into()))?;
    if channel.is_archived
        || !channel
            .members
            .iter()
            .any(|m| m.bot_id == request.bot_id && m.role == "worker")
    {
        return Err(conflict("Choose an active specialist Bot in this Group."));
    }
    let bot = state
        .store
        .bot(&request.bot_id)
        .await
        .map_err(unavailable)?
        .ok_or(conflict("Bot not found."))?;
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let parent = deterministic_uuid(&format!(
        "wonder-assignment-parent:{}",
        request.client_request_id
    ));
    let a = ProjectAssignment {
        id: request.client_request_id.clone(),
        creation_hash: hash,
        owner_device_id: owner,
        group_id: group,
        bot_id: request.bot_id.clone(),
        parent_message_id: parent.clone(),
        child_client_id: deterministic_uuid(&format!(
            "wonder-channel-worker:{parent}:{}",
            request.bot_id
        )),
        title: request.title.trim().into(),
        instruction: request.instruction,
        repository_path: bot.execution_directory().into(),
        target_ref: git(bot.execution_directory(), &["symbolic-ref", "HEAD"])
            .await
            .map_err(|_| conflict("Check out the project branch before creating an assignment."))?,
        worktree_path: std::fs::canonicalize(&bot.workspace_path)
            .map_err(unavailable)?
            .join("assignments")
            .join(&request.client_request_id)
            .to_string_lossy()
            .into(),
        branch: format!("codex/wonder-{}", request.client_request_id),
        base_revision: request.base_revision,
        dependency_ids: request.dependency_ids,
        state: "queued".into(),
        result_revision: None,
        summary: None,
        validation: None,
        integration_head: None,
        created_at: now.clone(),
        updated_at: now,
    };
    authorized_bot(state, &a).await.map_err(conflict)?;
    let resolved = git(
        &a.repository_path,
        &[
            "rev-parse",
            "--verify",
            &format!("{}^{{commit}}", a.base_revision),
        ],
    )
    .await
    .map_err(conflict)?;
    if resolved != a.base_revision {
        return Err(conflict("Choose an exact commit revision."));
    }
    if !state
        .store
        .create_project_assignment_with_attachments(&a, &channel.conversation_id, attachment_ids)
        .await
        .map_err(unavailable)?
    {
        return Err(conflict(
            "Dependencies and attached files must belong to this Group; dependencies must use the same project.",
        ));
    }
    Ok(Json(summary(&a)))
}
pub(super) async fn list(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path(group): Path<String>,
) -> Result<Json<serde_json::Value>, Failure> {
    Ok(Json(
        serde_json::json!({"assignments":state.store.project_assignments(&group).await.map_err(unavailable)?.iter().map(summary).collect::<Vec<_>>()}),
    ))
}
pub(super) async fn projects(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path(group): Path<String>,
) -> Result<Json<serde_json::Value>, Failure> {
    let channel = state
        .store
        .channel(&group)
        .await
        .map_err(unavailable)?
        .ok_or((StatusCode::NOT_FOUND, "Group not found.".into()))?;
    let mut projects = Vec::new();
    if !channel.is_archived {
        for member in channel.members.iter().filter(|m| m.role == "worker") {
            let Some(bot) = state.store.bot(&member.bot_id).await.map_err(unavailable)? else {
                continue;
            };
            if bot.is_archived
                || !matches!(
                    bot.permission_mode.as_deref(),
                    Some("workspace" | "full-access")
                )
            {
                continue;
            }
            if file_access::dispatch_check(&state, &bot, bot.effective_permission_profile())
                .await
                .is_err()
            {
                continue;
            }
            if bot.permission_mode.as_deref() == Some("workspace")
                && !permission_modes::runtime_roots(&state, &bot)
                    .await
                    .map_err(conflict)?
                    .iter()
                    .any(|root| FsPath::new(bot.execution_directory()).starts_with(root))
            {
                continue;
            }
            let Ok(repo) = canonical_repo(bot.execution_directory()).await else {
                continue;
            };
            let Ok(head) = git(&repo, &["rev-parse", "HEAD"]).await else {
                continue;
            };
            projects.push(serde_json::json!({"botId":bot.id,"projectName":FsPath::new(&repo).file_name().unwrap_or_default().to_string_lossy(),"baseRevision":head}));
        }
    }
    Ok(Json(serde_json::json!({"projects":projects})))
}
pub(super) async fn inspect(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, Failure> {
    let a = load(&state, &id).await?;
    let mut value = summary(&a);
    value["branch"] = serde_json::json!(a.branch);
    value["worktreePath"] = serde_json::json!(a.worktree_path);
    value["repositoryPath"] = serde_json::json!(a.repository_path);
    value["targetBranch"] = serde_json::json!(a
        .target_ref
        .strip_prefix("refs/heads/")
        .unwrap_or(&a.target_ref));
    value["repositoryHead"] = serde_json::json!(git(&a.repository_path, &["rev-parse", "HEAD"])
        .await
        .map_err(conflict)?);
    if let Some(result) = a.result_revision.as_deref() {
        value["diff"] = serde_json::json!(git(
            &a.repository_path,
            &[
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--no-color",
                &a.base_revision,
                result,
                "--"
            ]
        )
        .await
        .map_err(conflict)?);
    }
    Ok(Json(value))
}
async fn load(state: &AppState, id: &str) -> Result<ProjectAssignment, Failure> {
    state
        .store
        .project_assignment(id)
        .await
        .map_err(unavailable)?
        .ok_or((StatusCode::NOT_FOUND, "Assignment not found.".into()))
}
pub(super) async fn review(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path(id): Path<String>,
    Json(request): Json<Review>,
) -> Result<Json<serde_json::Value>, Failure> {
    let _guard = state.dispatch_lock.lock().await;
    let a = load(&state, &id).await?;
    if request.validation.trim().is_empty() || request.validation.len() > 8000 {
        return Err(conflict(
            "Record the review and validation before accepting this result.",
        ));
    }
    verify_result(&state, &a, &request.result_revision)
        .await
        .map_err(conflict)?;
    if a.state == "reviewed" && a.validation.as_deref() == Some(request.validation.as_str()) {
        return Ok(Json(summary(&a)));
    }
    if !state
        .store
        .review_assignment(
            &id,
            &request.result_revision,
            &request.validation,
            &now_ms().to_string(),
        )
        .await
        .map_err(unavailable)?
    {
        return Err(conflict("This result is no longer awaiting review."));
    }
    Ok(Json(summary(&load(&state, &id).await?)))
}
pub(super) async fn cancel(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, Failure> {
    let _guard = state.dispatch_lock.lock().await;
    let a = load(&state, &id).await?;
    if a.state != "cancelled"
        && !state
            .store
            .cancel_queued_assignment(&id, &now_ms().to_string())
            .await
            .map_err(unavailable)?
    {
        return Err(conflict(
            "This assignment has started. Stop the Bot from its conversation.",
        ));
    }
    Ok(Json(summary(&load(&state, &id).await?)))
}
async fn verify_result(
    state: &AppState,
    a: &ProjectAssignment,
    result: &str,
) -> Result<(), String> {
    authorized_bot(state, a).await?;
    if !revision_valid(result) || a.result_revision.as_deref() != Some(result) {
        return Err("The submitted result changed. Review the current result.".into());
    }
    verify_worktree(a).await?;
    clean(&a.worktree_path).await?;
    if git(&a.worktree_path, &["rev-parse", "HEAD"]).await? != result {
        return Err("The assignment changed after submission. Review it again.".into());
    }
    ancestor(&a.repository_path, &a.base_revision, result).await
}
pub(super) async fn integrate(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path(id): Path<String>,
    Json(request): Json<Integrate>,
) -> Result<Json<serde_json::Value>, Failure> {
    let _guard = state.dispatch_lock.lock().await;
    let a = load(&state, &id).await?;
    if !revision_valid(&request.expected_head) || !revision_valid(&request.result_revision) {
        return Err(conflict(
            "Exact reviewed and target revisions are required.",
        ));
    }
    verify_result(&state, &a, &request.result_revision)
        .await
        .map_err(conflict)?;
    if git(&a.repository_path, &["symbolic-ref", "HEAD"])
        .await
        .map_err(conflict)?
        != a.target_ref
    {
        return Err(conflict(
            "The project branch changed. Restore its original branch before integrating.",
        ));
    }
    let index_path = git(
        &a.repository_path,
        &["rev-parse", "--path-format=absolute", "--git-path", "index"],
    )
    .await
    .map_err(conflict)?;
    if FsPath::new(&format!("{index_path}.lock")).exists() {
        return Err(conflict("The project index is busy or an earlier integration needs recovery. Inspect its files and Git locks on the Mac before retrying."));
    }
    tracked_clean(&a.repository_path).await.map_err(conflict)?;
    let head = git(&a.repository_path, &["rev-parse", "HEAD"])
        .await
        .map_err(conflict)?;
    if matches!(a.state.as_str(), "integrating" | "integrated") {
        if a.integration_head.as_deref() != Some(&request.expected_head) {
            return Err(conflict("The original integration target differs."));
        }
        if head == request.result_revision {
            let _ = state
                .store
                .transition_assignment(
                    &id,
                    "integrating",
                    "integrated",
                    None,
                    &now_ms().to_string(),
                )
                .await
                .map_err(unavailable)?;
            return Ok(Json(summary(&load(&state, &id).await?)));
        }
        if a.state == "integrated" {
            return Err(conflict(
                "The project moved after integration. Inspect its history.",
            ));
        }
    } else if a.state != "reviewed" {
        return Err(conflict("Review this result before integrating it."));
    }
    if head != request.expected_head || head != a.base_revision {
        return Err(conflict(
            "The project changed. Rebase the assignment on its current revision and review again.",
        ));
    }
    ancestor(&a.repository_path, &head, &request.result_revision)
        .await
        .map_err(conflict)?;
    if a.state == "reviewed"
        && !state
            .store
            .begin_assignment_integration(
                &id,
                &request.result_revision,
                &head,
                &now_ms().to_string(),
            )
            .await
            .map_err(unavailable)?
    {
        return Err(conflict("The review changed."));
    }
    // Intent is durable before Git. Git's prepared ref transaction and index lock
    // protect this exact branch from external Git writers, not just daemon requests.
    integrate_git(&a, &request.result_revision, &request.expected_head)
        .await
        .map_err(conflict)?;
    if git(&a.repository_path, &["rev-parse", "HEAD"])
        .await
        .map_err(conflict)?
        != request.result_revision
    {
        return Err(conflict(
            "Integration outcome is uncertain. Inspect the project before retrying.",
        ));
    }
    state
        .store
        .transition_assignment(
            &id,
            "integrating",
            "integrated",
            None,
            &now_ms().to_string(),
        )
        .await
        .map_err(unavailable)?;
    Ok(Json(summary(&load(&state, &id).await?)))
}

/// A prepared HEAD update locks both HEAD and its referent in Git itself. Check
/// the symbolic target while those locks are held, so a pre-prepare checkout is
/// rejected and a later external checkout cannot redirect this update.
struct RefTransaction {
    child: tokio::process::Child,
    input: Option<tokio::process::ChildStdin>,
    output: tokio::io::BufReader<tokio::process::ChildStdout>,
}
impl RefTransaction {
    async fn prepare(path: &str, result: &str, expected: &str) -> Result<Self, String> {
        let mut child = Command::new("git")
            .args([
                "-C",
                path,
                "-c",
                "core.hooksPath=/dev/null",
                "update-ref",
                "-m",
                "Wonder reviewed assignment",
                "--stdin",
            ])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| e.to_string())?;
        let input = child
            .stdin
            .take()
            .ok_or("Git transaction input unavailable.")?;
        let output = tokio::io::BufReader::new(
            child
                .stdout
                .take()
                .ok_or("Git transaction output unavailable.")?,
        );
        let mut tx = Self {
            child,
            input: Some(input),
            output,
        };
        tx.command("start\n", "start: ok").await?;
        tx.command(
            &format!("update HEAD {result} {expected}\nprepare\n"),
            "prepare: ok",
        )
        .await?;
        Ok(tx)
    }
    async fn command(&mut self, input: &str, expected: &str) -> Result<(), String> {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            self.input.as_mut().ok_or("Git transaction input closed.")?.write_all(input.as_bytes()).await.map_err(|e| e.to_string())?;
            self.input.as_mut().ok_or("Git transaction input closed.")?.flush().await.map_err(|e| e.to_string())?;
            let mut line = String::new();
            self.output.read_line(&mut line).await.map_err(|e| e.to_string())?;
            if line.trim() != expected {
                return Err("Git could not reserve the exact project branch. Inspect any other Git operation before retrying.".into());
            }
            Ok(())
        }).await.map_err(|_| "Git transaction timed out. Inspect the project and its locks on the Mac before retrying.".to_owned())?
    }
    async fn end(&mut self, commit: bool) -> Result<(), String> {
        self.command(
            if commit { "commit\n" } else { "abort\n" },
            if commit { "commit: ok" } else { "abort: ok" },
        )
        .await?;
        // Dropping the pipe sends EOF; AsyncWrite::shutdown on a pipe is insufficient.
        drop(self.input.take());
        let status = tokio::time::Duration::from_secs(5);
        let status = tokio::time::timeout(status, self.child.wait())
            .await
            .map_err(|_| {
                "Git transaction did not finish. Inspect the project on the Mac.".to_owned()
            })?
            .map_err(|e| e.to_string())?;
        if !status.success() {
            return Err(
                "Git transaction did not finish successfully. Inspect the project on the Mac."
                    .into(),
            );
        }
        Ok(())
    }
}
struct IntegrationIndex {
    index: String,
    lock: String,
    preserve: bool,
}
impl Drop for IntegrationIndex {
    fn drop(&mut self) {
        if !self.preserve {
            let _ = std::fs::remove_file(&self.lock);
        }
    }
}
impl IntegrationIndex {
    async fn reserve(path: &str) -> Result<Self, String> {
        let index = git(
            path,
            &["rev-parse", "--path-format=absolute", "--git-path", "index"],
        )
        .await?;
        let lock = format!("{index}.lock");
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&lock)
            .map_err(|_| "The project index is busy or an earlier integration needs recovery. Inspect it on the Mac.".to_owned())?;
        let guard = Self {
            index,
            lock,
            preserve: false,
        };
        let mut source = std::fs::File::open(&guard.index).map_err(|e| e.to_string())?;
        std::io::copy(&mut source, &mut file).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        Ok(guard)
    }
}
async fn integrate_git(a: &ProjectAssignment, result: &str, expected: &str) -> Result<(), String> {
    let mut index = IntegrationIndex::reserve(&a.repository_path).await?;
    let mut refs = RefTransaction::prepare(&a.repository_path, result, expected).await?;
    let outcome = async {
        // Both the real index and HEAD/ref are now locked against external Git.
        if git(&a.repository_path, &["symbolic-ref", "HEAD"]).await? != a.target_ref {
            return Err(
                "The project branch changed. Restore its original branch before integrating."
                    .into(),
            );
        }
        tracked_clean(&a.repository_path).await?;
        // Use our reserved index as an alternate index; read-tree uses index.lock.lock
        // internally. Keep recovery evidence from this point onward on any failure.
        index.preserve = true;
        git_with_index(
            &a.repository_path,
            &["read-tree", "-m", "-u", expected, result],
            Some(&index.lock),
        )
        .await?;
        if git_with_index(&a.repository_path, &["write-tree"], Some(&index.lock)).await?
            != git(
                &a.repository_path,
                &["rev-parse", &format!("{result}^{{tree}}")],
            )
            .await?
        {
            return Err(
                "The prepared project index changed. Inspect the integration on the Mac.".into(),
            );
        }
        git_with_index(
            &a.repository_path,
            &["diff-files", "--quiet", "--"],
            Some(&index.lock),
        )
        .await
        .map_err(|_| {
            "The project files changed during integration. Inspect the preserved index on the Mac."
                .to_owned()
        })?;
        // Ref changes are CAS and fixed to the locked branch. Retain the real index
        // lock until commit finishes, so no Git writer can observe an unlocked stale index.
        refs.end(true).await?;
        std::fs::rename(&index.lock, &index.index).map_err(|e| e.to_string())?;
        index.preserve = false;
        Ok(())
    }
    .await;
    if outcome.is_err() {
        let _ = refs.end(false).await;
    }
    outcome.map_err(|error: String| {
        if index.preserve {
            format!("{error} Integration paused. The project and prepared index were retained; review them on the Mac before removing any Git lock or retrying.")
        } else { error }
    })
}

async fn verify_worktree(a: &ProjectAssignment) -> Result<(), String> {
    let canonical = std::fs::canonicalize(&a.worktree_path)
        .map_err(|_| "The assignment workspace is unavailable.")?;
    if canonical.to_str() != Some(&a.worktree_path) {
        return Err("The assignment workspace changed.".into());
    }
    let expected = git(
        &a.repository_path,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )
    .await?;
    let actual = git(
        &a.worktree_path,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )
    .await?;
    if expected != actual
        || git(&a.worktree_path, &["symbolic-ref", "--short", "HEAD"]).await? != a.branch
    {
        return Err("The assignment belongs to a different repository or branch.".into());
    }
    Ok(())
}
pub(super) fn instruction(a: &ProjectAssignment) -> String {
    format!("Project assignment: {}\n\n{}\n\nWork only in the current isolated repository worktree. Starting revision: {}. Run the smallest meaningful validation and commit your finished changes. Report the exact commit and checks. Do not merge, push, deploy, or modify other worktrees.", a.title, a.instruction, a.base_revision)
}
/// Called before a Group claim; dependencies never create another scheduler.
pub(super) async fn ready(state: &AppState, a: &ProjectAssignment) -> Result<bool, String> {
    if !matches!(
        a.state.as_str(),
        "queued" | "working" | "uncertain" | "awaiting_input"
    ) {
        return Ok(false);
    }
    for id in &a.dependency_ids {
        let dep = state
            .store
            .project_assignment(id)
            .await
            .map_err(|e| e.to_string())?
            .ok_or("A dependency is unavailable.")?;
        if dep.state != "integrated" {
            return Ok(false);
        }
    }
    Ok(true)
}
pub(super) async fn prepare(state: &AppState, a: &mut ProjectAssignment) -> Result<(), String> {
    let _guard = state.dispatch_lock.lock().await;
    *a = state
        .store
        .project_assignment(&a.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("Assignment not found.")?;
    if !ready(state, a).await? {
        return Err("This assignment is no longer ready.".into());
    }
    authorized_bot(state, a).await?;
    if a.state == "queued" {
        let mut base = a.base_revision.clone();
        for id in &a.dependency_ids {
            let dep = state
                .store
                .project_assignment(id)
                .await
                .map_err(|e| e.to_string())?
                .ok_or("Dependency missing.")?;
            let result = dep.result_revision.ok_or("Dependency result missing.")?;
            if ancestor(&a.repository_path, &base, &result).await.is_ok() {
                base = result;
            } else {
                ancestor(&a.repository_path, &result, &base).await?;
            }
        }
        state
            .store
            .set_assignment_base(&a.id, &base)
            .await
            .map_err(|e| e.to_string())?;
        a.base_revision = base;
        if !FsPath::new(&a.worktree_path).exists() {
            let parent = FsPath::new(&a.worktree_path)
                .parent()
                .ok_or("Invalid assignment workspace.")?;
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| e.to_string())?;
            if std::fs::canonicalize(parent).map_err(|e| e.to_string())? != parent {
                return Err("The assignment folder changed.".into());
            }
            git(
                &a.repository_path,
                &[
                    "-c",
                    "core.hooksPath=/dev/null",
                    "worktree",
                    "add",
                    "-b",
                    &a.branch,
                    &a.worktree_path,
                    &a.base_revision,
                ],
            )
            .await?;
        }
        verify_worktree(a).await?;
        if git(&a.worktree_path, &["rev-parse", "HEAD"]).await? != a.base_revision {
            return Err("The new assignment has unexpected changes. Inspect its workspace.".into());
        }
        clean(&a.worktree_path).await?;
        if !state
            .store
            .transition_assignment(&a.id, "queued", "working", None, &now_ms().to_string())
            .await
            .map_err(|e| e.to_string())?
        {
            return Err("Assignment state changed.".into());
        }
        a.state = "working".into();
    } else {
        verify_worktree(a).await?;
    }
    Ok(())
}
/// Preserve the Bot defaults; only this durable child conversation uses its worktree.
pub(super) async fn execution_bot(
    state: &AppState,
    conversation: &str,
    mut bot: StoredBot,
) -> Result<StoredBot, String> {
    if let Some(a) = state
        .store
        .assignment_for_conversation(conversation)
        .await
        .map_err(|e| e.to_string())?
    {
        if a.bot_id != bot.id
            || !matches!(a.state.as_str(), "working" | "uncertain" | "awaiting_input")
        {
            return Err("Assignment is not available for execution.".into());
        }
        authorized_bot(state, &a).await?;
        verify_worktree(&a).await?;
        bot.working_directory = Some(a.worktree_path);
        // Assignment execution uses a different cwd from the Bot default.
        // Verify the resolved profile at that exact worktree before dispatch
        // validation; approval_allowed must not borrow a cache entry from a
        // different project or the Bot's default workspace.
        crate::ensure_execution_permission_cache(state, &bot).await?;
    }
    Ok(bot)
}
pub(super) async fn finish(
    state: &AppState,
    a: &ProjectAssignment,
    output: Option<&str>,
) -> Result<(), String> {
    // A bounded Group wait is not evidence that the correlated runtime stopped.
    // Reload because the periodic projection may have changed state while waiting.
    let current = state
        .store
        .project_assignment(&a.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("The assignment is unavailable.")?;
    let a = &current;
    if !matches!(a.state.as_str(), "working" | "uncertain" | "awaiting_input") {
        return Ok(());
    }
    if let Some(activity) = state
        .store
        .assignment_execution_activity(&a.id, now_ms() as i64)
        .await
        .map_err(|e| e.to_string())?
    {
        state
            .store
            .transition_assignment(&a.id, &a.state, &activity, None, &now_ms().to_string())
            .await
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    let child = state
        .store
        .message_by_device_and_client_message_id(&a.owner_device_id, &a.child_client_id)
        .await
        .map_err(|e| e.to_string())?;
    let child_state = child.as_ref().map(|m| m.state.as_str());
    if output.is_some() && child_state == Some("completed") {
        verify_worktree(a).await?;
        clean(&a.worktree_path).await?;
        let result = git(&a.worktree_path, &["rev-parse", "HEAD"]).await?;
        if result == a.base_revision {
            return Err("The Bot finished without a committed change. Inspect its reply and assign a follow-up.".into());
        }
        ancestor(&a.repository_path, &a.base_revision, &result).await?;
        let summary = if let Some(id) = output {
            state
                .store
                .message_by_id(id)
                .await
                .map_err(|e| e.to_string())?
                .map(|m| m.body)
                .unwrap_or_default()
        } else {
            String::new()
        };
        state
            .store
            .submit_assignment(&a.id, &result, &summary, &now_ms().to_string())
            .await
            .map_err(|e| e.to_string())?;
    } else {
        let status = if matches!(
            child_state,
            Some("failed" | "safe_to_retry" | "interrupted")
        ) {
            "failed"
        } else {
            "uncertain"
        };
        state
            .store
            .transition_assignment(
                &a.id,
                &a.state,
                status,
                Some("Inspect the Bot's conversation before starting a follow-up."),
                &now_ms().to_string(),
            )
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use tower::ServiceExt;
    pub(crate) async fn fixture() -> (tempfile::TempDir, AppState, String) {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let repo = dir.path().join("project");
        std::fs::create_dir(&repo).unwrap();
        let repo = std::fs::canonicalize(repo)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        git(&repo, &["init", "-b", "main"]).await.unwrap();
        git(
            &repo,
            &["config", "user.email", "wonder-test@example.invalid"],
        )
        .await
        .unwrap();
        git(&repo, &["config", "user.name", "Wonder Test"])
            .await
            .unwrap();
        std::fs::write(FsPath::new(&repo).join("hello.txt"), "before\n").unwrap();
        git(&repo, &["add", "hello.txt"]).await.unwrap();
        git(&repo, &["commit", "-m", "Initial"]).await.unwrap();
        let mut bot = state.store.bot("bot").await.unwrap().unwrap();
        bot.working_directory = Some(repo);
        bot.permission_mode = Some("full-access".into());
        state
            .store
            .update_managed_bot(&bot, [false; 3])
            .await
            .unwrap();
        state
            .store
            .create_channel(
                "group",
                "group-chat",
                "Developers",
                None,
                "bot",
                &[("bot", "worker")],
                "1",
            )
            .await
            .unwrap();
        let head = git(bot.execution_directory(), &["rev-parse", "HEAD"])
            .await
            .unwrap();
        (dir, state, head)
    }
    async fn request(
        state: &AppState,
        path: &str,
        body: serde_json::Value,
    ) -> (StatusCode, serde_json::Value) {
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(path)
                    .header("x-wonder-loopback-capability", &state.loopback_capability)
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes)
                .unwrap_or_else(|_| serde_json::json!(String::from_utf8_lossy(&bytes))),
        )
    }
    async fn accept(state: &AppState, head: &str, deps: Vec<String>) -> ProjectAssignment {
        let id = uuid::Uuid::new_v4().to_string();
        let (status,value)=request(state,"/api/v1/groups/group/assignments",serde_json::json!({"clientRequestId":id,"title":"Small change","instruction":"Update hello and commit","botId":"bot","baseRevision":head,"dependencyIds":deps})).await;
        assert_eq!(status, StatusCode::OK, "{value}");
        state.store.project_assignment(&id).await.unwrap().unwrap()
    }
    async fn commit_result(a: &ProjectAssignment) -> String {
        std::fs::write(FsPath::new(&a.worktree_path).join("hello.txt"), "after\n").unwrap();
        git(&a.worktree_path, &["add", "hello.txt"]).await.unwrap();
        git(&a.worktree_path, &["commit", "-m", "Update hello"])
            .await
            .unwrap();
        git(&a.worktree_path, &["rev-parse", "HEAD"]).await.unwrap()
    }
    #[tokio::test]
    async fn assignment_acceptance_is_durable_idempotent_and_cancel_blocks_claim() {
        let (dir, mut state, head) = fixture().await;
        let a = accept(&state, &head, vec![]).await;
        let body = serde_json::json!({"clientRequestId":a.id,"title":"Small change","instruction":"Update hello and commit","botId":"bot","baseRevision":head,"dependencyIds":[]});
        assert_eq!(
            request(&state, "/api/v1/groups/group/assignments", body.clone())
                .await
                .0,
            StatusCode::OK
        );
        let mut changed = body;
        changed["title"] = serde_json::json!("Different");
        assert_eq!(
            request(&state, "/api/v1/groups/group/assignments", changed)
                .await
                .0,
            StatusCode::CONFLICT
        );
        state.store = wonder_store::Store::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        assert_eq!(state.store.pending_group_runs().await.unwrap().len(), 1);
        assert_eq!(
            state
                .store
                .project_assignments("group")
                .await
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            request(
                &state,
                &format!("/api/v1/assignments/{}/cancel", a.id),
                serde_json::json!({})
            )
            .await
            .0,
            StatusCode::OK
        );
        assert!(state.store.pending_group_runs().await.unwrap().is_empty());
        assert!(!ready(
            &state,
            &state
                .store
                .project_assignment(&a.id)
                .await
                .unwrap()
                .unwrap()
        )
        .await
        .unwrap());
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn worktree_restart_review_and_integration_are_exact_and_idempotent() {
        let (_dir, state, head) = fixture().await;
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        let path = a.worktree_path.clone();
        prepare(&state, &mut a).await.unwrap();
        assert_eq!(path, a.worktree_path);
        let result = commit_result(&a).await;
        state
            .store
            .submit_assignment(
                &a.id,
                &result,
                "Changed hello; reviewed focused check.",
                "2",
            )
            .await
            .unwrap();
        let integrate_path = format!("/api/v1/assignments/{}/integrate", a.id);
        let integrate_body = serde_json::json!({"resultRevision":result,"expectedHead":head});
        assert_eq!(
            request(&state, &integrate_path, integrate_body.clone())
                .await
                .0,
            StatusCode::CONFLICT
        );
        let review_body =
            serde_json::json!({"resultRevision":result,"validation":"Verified hello change"});
        assert_eq!(
            request(
                &state,
                &format!("/api/v1/assignments/{}/review", a.id),
                review_body.clone()
            )
            .await
            .0,
            StatusCode::OK
        );
        assert_eq!(
            request(
                &state,
                &format!("/api/v1/assignments/{}/review", a.id),
                review_body
            )
            .await
            .0,
            StatusCode::OK
        );
        std::fs::write(
            FsPath::new(&a.repository_path).join("hello.txt"),
            "owner edit",
        )
        .unwrap();
        assert_eq!(
            request(&state, &integrate_path, integrate_body.clone())
                .await
                .0,
            StatusCode::CONFLICT
        );
        std::fs::write(
            FsPath::new(&a.repository_path).join("hello.txt"),
            "before\n",
        )
        .unwrap();
        // Simulate process exit after Git advanced HEAD but before status commit.
        assert!(state
            .store
            .begin_assignment_integration(&a.id, &result, &head, "3")
            .await
            .unwrap());
        git(&a.repository_path, &["merge", "--ff-only", &result])
            .await
            .unwrap();
        assert_eq!(
            request(&state, &integrate_path, integrate_body.clone())
                .await
                .0,
            StatusCode::OK
        );
        assert_eq!(
            request(&state, &integrate_path, integrate_body).await.0,
            StatusCode::OK
        );
        assert_eq!(
            state
                .store
                .project_assignment(&a.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "integrated"
        );
        assert_eq!(
            git(&a.repository_path, &["rev-parse", "HEAD"])
                .await
                .unwrap(),
            result
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn dependency_uses_integrated_revision_and_submitted_result_does_not_unlock() {
        let (_dir, state, head) = fixture().await;
        let mut first = accept(&state, &head, vec![]).await;
        let mut second = accept(&state, &head, vec![first.id.clone()]).await;
        assert!(!ready(&state, &second).await.unwrap());
        prepare(&state, &mut first).await.unwrap();
        let result = commit_result(&first).await;
        state
            .store
            .submit_assignment(&first.id, &result, "Done", "2")
            .await
            .unwrap();
        assert!(!ready(&state, &second).await.unwrap());
        assert!(state
            .store
            .review_assignment(&first.id, &result, "Reviewed", "3")
            .await
            .unwrap());
        let (status, value) = request(
            &state,
            &format!("/api/v1/assignments/{}/integrate", first.id),
            serde_json::json!({"resultRevision":result,"expectedHead":head}),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{value}");
        assert!(ready(&state, &second).await.unwrap());
        prepare(&state, &mut second).await.unwrap();
        assert_eq!(second.base_revision, result);
        assert_eq!(
            git(&second.worktree_path, &["rev-parse", "HEAD"])
                .await
                .unwrap(),
            result
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn authorization_and_returned_revision_are_not_inferred_from_request() {
        let (_dir, state, head) = fixture().await;
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .uri("/api/v1/groups/group/assignments")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert!(!response.status().is_success());
        let mut bot = state.store.bot("bot").await.unwrap().unwrap();
        bot.permission_mode = Some("read-only".into());
        state
            .store
            .update_managed_bot(&bot, [false; 3])
            .await
            .unwrap();
        let body = serde_json::json!({"clientRequestId":uuid::Uuid::new_v4().to_string(),"title":"Change","instruction":"Change","botId":"bot","baseRevision":head});
        assert_eq!(
            request(&state, "/api/v1/groups/group/assignments", body)
                .await
                .0,
            StatusCode::CONFLICT
        );
        bot.permission_mode = Some("full-access".into());
        state
            .store
            .update_managed_bot(&bot, [false; 3])
            .await
            .unwrap();
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        let result = commit_result(&a).await;
        state
            .store
            .submit_assignment(&a.id, &result, "Done", "2")
            .await
            .unwrap();
        let (status, _) = request(
            &state,
            &format!("/api/v1/assignments/{}/review", a.id),
            serde_json::json!({"resultRevision":head,"validation":"Wrong revision"}),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn group_restart_preserves_unknown_child_and_recovers_completed_result_without_execution()
    {
        let (dir, mut state, head) = fixture().await;
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        let result = commit_result(&a).await;
        let bot = state.store.bot("bot").await.unwrap().unwrap();
        let conversation = format!("channel:group:worker:bot:message:{}", a.parent_message_id);
        state
            .store
            .create_conversation(&conversation, "bot", "Specialist", "1")
            .await
            .unwrap();
        let body=format!("You are {} in the Group Chat Developers. Reply directly to the user in your own voice. Keep your answer concise and do not describe internal coordination.\n\n{}",bot.name,instruction(&a));
        let wonder_store::MessageInsert::Inserted(child) = state
            .store
            .insert_message(
                &a.owner_device_id,
                &a.child_client_id,
                &body,
                &hex::encode(Sha256::digest(body.as_bytes())),
                &conversation,
                "2",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        assert!(state
            .store
            .claim_message_for_dispatch(&child.id)
            .await
            .unwrap());
        state
            .store
            .begin_dispatch_submission(&child.id, "assignment-thread")
            .await
            .unwrap();
        state.store.recover_dispatch_claims().await.unwrap();
        state.store = wonder_store::Store::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        state.store.recover_group_runs().await.unwrap();
        let mut tasks = tokio::task::JoinSet::new();
        crate::groups::tick(&state, &mut tasks).await.unwrap();
        while let Some(task) = tasks.join_next().await {
            task.unwrap();
        }
        assert_eq!(
            state
                .store
                .project_assignment(&a.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "uncertain"
        );
        assert!(!state
            .store
            .claim_message_for_dispatch(&child.id)
            .await
            .unwrap());
        // The same durable child can still be live after the Group wait expired.
        state
            .store
            .update_message_delivery(
                &child.id,
                "streaming",
                Some("assignment-thread"),
                Some("assignment-turn"),
            )
            .await
            .unwrap();
        state.store.insert_pending_approval("live-approval", "item/commandExecution/requestApproval", r#"{"threadId":"assignment-thread","turnId":"assignment-turn","conversationId":"forged"}"#, "3").await.unwrap();
        finish(&state, &a, None).await.unwrap();
        assert_eq!(
            state
                .store
                .project_assignment(&a.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "awaiting_input"
        );
        state
            .store
            .resolve_approval_by_server_request_id("live-approval", "accepted", "4")
            .await
            .unwrap();
        state
            .store
            .refresh_assignment_execution_states(now_ms() as i64)
            .await
            .unwrap();
        assert_eq!(
            state
                .store
                .project_assignment(&a.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "working"
        );
        state
            .store
            .update_message_delivery(
                &child.id,
                "completed",
                Some("assignment-thread"),
                Some("assignment-turn"),
            )
            .await
            .unwrap();
        state
            .store
            .complete_assistant_message(
                &conversation,
                "assignment-thread",
                "assignment-turn",
                "answer",
                "Committed the change and checked hello.",
                "3",
            )
            .await
            .unwrap();
        state
            .store
            .finish_group_run(&a.parent_message_id, None, "0")
            .await
            .unwrap();
        crate::groups::tick(&state, &mut tasks).await.unwrap();
        while let Some(task) = tasks.join_next().await {
            task.unwrap();
        }
        let saved = state
            .store
            .project_assignment(&a.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(saved.state, "submitted");
        assert_eq!(saved.result_revision.as_deref(), Some(result.as_str()));
        assert!(!std::fs::read_to_string(dir.path().join("requests"))
            .unwrap()
            .lines()
            .any(|line| line == "turn/start"));
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn assignment_waiting_requires_correlated_pending_input() {
        let (_dir, state, head) = fixture().await;
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        let conversation = format!("channel:group:worker:bot:message:{}", a.parent_message_id);
        state
            .store
            .create_conversation(&conversation, "bot", "Specialist", "1")
            .await
            .unwrap();
        let wonder_store::MessageInsert::Inserted(child) = state
            .store
            .insert_message(
                &a.owner_device_id,
                &a.child_client_id,
                "Would you like another change?",
                "hash",
                &conversation,
                "2",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        state
            .store
            .update_message_delivery(&child.id, "completed", Some("thread"), Some("turn"))
            .await
            .unwrap();
        state
            .store
            .insert_pending_approval(
                "wrong-turn",
                "item/tool/requestUserInput",
                r#"{"threadId":"thread","turnId":"other","conversationId":"group-chat"}"#,
                "3",
            )
            .await
            .unwrap();
        assert_eq!(
            state
                .store
                .assignment_execution_activity(&a.id, 10)
                .await
                .unwrap(),
            None,
            "neither final text nor forged/wrong-turn input proves waiting"
        );
        state
            .store
            .save_async_question(
                &conversation,
                "thread",
                "other",
                "wrong-question",
                "[]",
                100,
            )
            .await
            .unwrap();
        assert_eq!(
            state
                .store
                .assignment_execution_activity(&a.id, 10)
                .await
                .unwrap(),
            None
        );
        state
            .store
            .save_async_question(&conversation, "thread", "turn", "question", "[]", 100)
            .await
            .unwrap();
        assert_eq!(
            state
                .store
                .assignment_execution_activity(&a.id, 10)
                .await
                .unwrap()
                .as_deref(),
            Some("awaiting_input")
        );
        assert_eq!(
            state
                .store
                .assignment_execution_activity(&a.id, 100)
                .await
                .unwrap(),
            None,
            "expired questions do not pause assignments"
        );
        state
            .store
            .save_async_question(
                &conversation,
                "thread",
                "turn",
                "live-question",
                "[]",
                now_ms() as i64 + 60_000,
            )
            .await
            .unwrap();
        let mut tasks = tokio::task::JoinSet::new();
        for _ in 0..4 {
            tasks.spawn(std::future::pending::<()>());
        }
        crate::groups::tick(&state, &mut tasks).await.unwrap();
        assert_eq!(
            state
                .store
                .project_assignment(&a.id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "awaiting_input",
            "projection refreshes even while all Group waits are occupied"
        );
        tasks.abort_all();
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn integration_preserves_large_untracked_tree_and_refuses_collisions() {
        let (_dir, state, head) = fixture().await;
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        let generated = FsPath::new(&a.repository_path).join("generated");
        std::fs::create_dir(&generated).unwrap();
        // Exceeds the Git output bound if enumerated by status --untracked-files=all.
        for n in 0..5000 {
            std::fs::write(
                generated.join(format!("{n:05}-{}", "x".repeat(220))),
                "owner",
            )
            .unwrap();
        }
        let result = commit_result(&a).await;
        tracked_clean(&a.repository_path).await.unwrap();
        integrate_git(&a, &result, &head).await.unwrap();
        assert_eq!(std::fs::read_dir(&generated).unwrap().count(), 5000);
        assert_eq!(
            std::fs::read_to_string(generated.join(format!("00000-{}", "x".repeat(220)))).unwrap(),
            "owner"
        );
        std::fs::write(
            FsPath::new(&a.repository_path).join("hello.txt"),
            "owner tracked edit",
        )
        .unwrap();
        assert!(tracked_clean(&a.repository_path).await.is_err());
        git(&a.repository_path, &["add", "hello.txt"])
            .await
            .unwrap();
        // Restoring HEAD content in the worktree must not hide a staged owner edit.
        let committed = git(&a.repository_path, &["show", "HEAD:hello.txt"])
            .await
            .unwrap();
        std::fs::write(
            FsPath::new(&a.repository_path).join("hello.txt"),
            format!("{committed}\n"),
        )
        .unwrap();
        assert!(tracked_clean(&a.repository_path).await.is_err());
        assert_eq!(
            git(&a.repository_path, &["show", ":hello.txt"])
                .await
                .unwrap(),
            "owner tracked edit"
        );
        state.app_server.lock().await.shutdown().await.unwrap();

        let (_dir, state, head) = fixture().await;
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        std::fs::write(FsPath::new(&a.worktree_path).join("incoming.txt"), "result").unwrap();
        git(&a.worktree_path, &["add", "incoming.txt"])
            .await
            .unwrap();
        git(&a.worktree_path, &["commit", "-m", "New file"])
            .await
            .unwrap();
        let result = git(&a.worktree_path, &["rev-parse", "HEAD"]).await.unwrap();
        let owner_file = FsPath::new(&a.repository_path).join("incoming.txt");
        std::fs::write(&owner_file, "owner untracked").unwrap();
        let index = git(
            &a.repository_path,
            &["rev-parse", "--path-format=absolute", "--git-path", "index"],
        )
        .await
        .unwrap();
        let original_index = std::fs::read(&index).unwrap();
        assert!(integrate_git(&a, &result, &head).await.is_err());
        assert_eq!(
            git(&a.repository_path, &["rev-parse", "HEAD"])
                .await
                .unwrap(),
            head
        );
        assert_eq!(std::fs::read(index).unwrap(), original_index);
        assert_eq!(
            std::fs::read_to_string(owner_file).unwrap(),
            "owner untracked"
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn assignment_dispatch_uses_worktree_without_mutating_bot_defaults() {
        let (dir, state, head) = fixture().await;
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        let bot = state.store.bot("bot").await.unwrap().unwrap();
        {
            let mut catalog = state.runtime_catalog.write().await;
            catalog.apply_models_page(
                &serde_json::json!({"data":[{"id":"test-model","isDefault":true}]}),
            );
            catalog.apply_permission_profiles(
                &bot.workspace_path,
                &serde_json::json!({"data":[{"name":":danger-full-access","allowed":true}]}),
            );
        }
        let conversation = format!("channel:group:worker:bot:message:{}", a.parent_message_id);
        state
            .store
            .create_conversation(&conversation, "bot", "Specialist", "1")
            .await
            .unwrap();
        let wonder_store::MessageInsert::Inserted(child) = state
            .store
            .insert_message(
                &a.owner_device_id,
                &a.child_client_id,
                "Do assigned work",
                "hash",
                &conversation,
                "2",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        crate::dispatch_to_codex_inner(state.clone(), child.clone(), Some("bot".into()), None)
            .await;
        let saved = state.store.message_by_id(&child.id).await.unwrap().unwrap();
        assert_eq!(saved.state, "accepted_by_codex");
        let pool = sqlx::SqlitePool::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        let context:String = sqlx::query_scalar("SELECT context_json FROM dispatch_attempts WHERE message_id=? ORDER BY id DESC LIMIT 1").bind(&child.id).fetch_one(&pool).await.unwrap();
        let context: serde_json::Value = serde_json::from_str(&context).unwrap();
        assert_eq!(context["workingDirectory"], a.worktree_path);
        assert_eq!(
            state
                .store
                .bot("bot")
                .await
                .unwrap()
                .unwrap()
                .working_directory,
            bot.working_directory
        );
        crate::dispatch_to_codex_inner(state.clone(), child, Some("bot".into()), None).await;
        assert_eq!(
            std::fs::read_to_string(dir.path().join("requests"))
                .unwrap()
                .lines()
                .filter(|line| *line == "turn/start")
                .count(),
            1
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn integration_rejects_branch_switch_and_busy_index_then_advances_only_reviewed_branch() {
        let (_dir, state, head) = fixture().await;
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        let result = commit_result(&a).await;
        state
            .store
            .submit_assignment(&a.id, &result, "Done", "2")
            .await
            .unwrap();
        state
            .store
            .review_assignment(&a.id, &result, "Reviewed", "3")
            .await
            .unwrap();
        let path = format!("/api/v1/assignments/{}/integrate", a.id);
        let body = serde_json::json!({"resultRevision":result,"expectedHead":head});
        git(&a.repository_path, &["checkout", "-b", "other"])
            .await
            .unwrap();
        assert_eq!(
            request(&state, &path, body.clone()).await.0,
            StatusCode::CONFLICT
        );
        assert_eq!(
            git(&a.repository_path, &["rev-parse", "other"])
                .await
                .unwrap(),
            head
        );
        git(&a.repository_path, &["checkout", "main"])
            .await
            .unwrap();
        let lock = IntegrationIndex::reserve(&a.repository_path).await.unwrap();
        assert_eq!(
            request(&state, &path, body.clone()).await.0,
            StatusCode::CONFLICT
        );
        assert!(
            FsPath::new(&lock.lock).exists(),
            "do not remove another writer's lock"
        );
        drop(lock);
        let (status, value) = request(&state, &path, body.clone()).await;
        assert_eq!(status, StatusCode::OK, "{value}");
        assert_eq!(value["state"], "integrated");
        assert_eq!(
            git(&a.repository_path, &["rev-parse", "main"])
                .await
                .unwrap(),
            result
        );
        assert_eq!(
            git(&a.repository_path, &["rev-parse", "other"])
                .await
                .unwrap(),
            head
        );
        clean(&a.repository_path).await.unwrap();
        assert_eq!(request(&state, &path, body).await.0, StatusCode::OK);
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn prepared_git_transaction_blocks_external_checkout_and_ref_updates() {
        let (_dir, state, head) = fixture().await;
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        let result = commit_result(&a).await;
        git(&a.repository_path, &["branch", "other", &result])
            .await
            .unwrap();
        let index = IntegrationIndex::reserve(&a.repository_path).await.unwrap();
        let mut refs = RefTransaction::prepare(&a.repository_path, &result, &head)
            .await
            .unwrap();
        assert!(git(&a.repository_path, &["checkout", "other"])
            .await
            .is_err());
        assert!(git(
            &a.repository_path,
            &["symbolic-ref", "HEAD", "refs/heads/other"]
        )
        .await
        .is_err());
        assert!(git(
            &a.repository_path,
            &["update-ref", "refs/heads/main", &result, &head]
        )
        .await
        .is_err());
        assert_eq!(
            git(&a.repository_path, &["symbolic-ref", "HEAD"])
                .await
                .unwrap(),
            a.target_ref
        );
        assert_eq!(
            std::fs::read_to_string(FsPath::new(&a.repository_path).join("hello.txt")).unwrap(),
            "before\n"
        );
        refs.end(false).await.unwrap();
        drop(index);
        assert_eq!(
            git(&a.repository_path, &["rev-parse", "HEAD"])
                .await
                .unwrap(),
            head
        );
        // A changed ref before prepare is rejected atomically too.
        assert!(
            RefTransaction::prepare(&a.repository_path, &result, &result)
                .await
                .is_err()
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn two_tree_update_preserves_owner_edit_after_precondition_check() {
        let (_dir, state, head) = fixture().await;
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        let result = commit_result(&a).await;
        let mut index = IntegrationIndex::reserve(&a.repository_path).await.unwrap();
        let mut refs = RefTransaction::prepare(&a.repository_path, &result, &head)
            .await
            .unwrap();
        clean(&a.repository_path).await.unwrap();
        let file = FsPath::new(&a.repository_path).join("hello.txt");
        std::fs::write(&file, "owner edit after check\n").unwrap();
        index.preserve = true;
        assert!(git_with_index(
            &a.repository_path,
            &["read-tree", "-m", "-u", &head, &result],
            Some(&index.lock)
        )
        .await
        .is_err());
        refs.end(false).await.unwrap();
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            "owner edit after check\n"
        );
        assert_eq!(
            git(&a.repository_path, &["rev-parse", "HEAD"])
                .await
                .unwrap(),
            head
        );
        let retained = index.lock.clone();
        drop(index);
        assert!(
            FsPath::new(&retained).exists(),
            "failed mutation keeps recovery evidence"
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn terminal_and_dependency_blocked_assignments_do_not_starve_group_dispatch() {
        let (dir, mut state, head) = fixture().await;
        let first = accept(&state, &head, vec![]).await;
        state
            .store
            .claim_group_run(&first.parent_message_id)
            .await
            .unwrap();
        state
            .store
            .transition_assignment(
                &first.id,
                "queued",
                "failed",
                Some("Project unavailable"),
                "2",
            )
            .await
            .unwrap();
        for _ in 0..16 {
            accept(&state, &head, vec![first.id.clone()]).await;
        }
        let last = accept(&state, &head, vec![]).await;
        // Reopen at the assignment/run crash boundary. The first run was running.
        state.store = wonder_store::Store::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        state.store.recover_group_runs().await.unwrap();
        state.store.reconcile_assignment_group_runs().await.unwrap();
        let pending = state.store.pending_group_runs().await.unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].parent.id, last.parent_message_id);
        assert_eq!(
            state
                .store
                .message_by_id(&first.parent_message_id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "failed"
        );
        // A committed submission with a still-running parent also reconciles to terminal.
        state
            .store
            .claim_group_run(&last.parent_message_id)
            .await
            .unwrap();
        state
            .store
            .transition_assignment(&last.id, "queued", "working", None, "3")
            .await
            .unwrap();
        state
            .store
            .submit_assignment(&last.id, &head, "Saved result", "4")
            .await
            .unwrap();
        state.store.recover_group_runs().await.unwrap();
        state.store.reconcile_assignment_group_runs().await.unwrap();
        assert!(state.store.pending_group_runs().await.unwrap().is_empty());
        assert_eq!(
            state
                .store
                .message_by_id(&last.parent_message_id)
                .await
                .unwrap()
                .unwrap()
                .state,
            "completed"
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn group_delete_retains_worktree_and_workspace_reset_clears_assignment_foreign_keys() {
        let (_dir, state, head) = fixture().await;
        let mut a = accept(&state, &head, vec![]).await;
        prepare(&state, &mut a).await.unwrap();
        state
            .store
            .transition_assignment(&a.id, "working", "integrating", None, "2")
            .await
            .unwrap();
        state
            .store
            .finish_group_run(&a.parent_message_id, Some("completed-report"), "2")
            .await
            .unwrap();
        assert!(
            !state.store.delete_channel("group").await.unwrap(),
            "keep integration recovery metadata"
        );
        state
            .store
            .transition_assignment(&a.id, "integrating", "failed", Some("Stopped"), "2")
            .await
            .unwrap();
        state.store.reconcile_assignment_group_runs().await.unwrap();
        assert!(state.store.delete_channel("group").await.unwrap());
        assert!(state
            .store
            .project_assignment(&a.id)
            .await
            .unwrap()
            .is_none());
        assert!(FsPath::new(&a.worktree_path).exists());
        state.app_server.lock().await.shutdown().await.unwrap();
        let (_dir, state, head) = fixture().await;
        let a = accept(&state, &head, vec![]).await;
        state
            .store
            .cancel_queued_assignment(&a.id, "2")
            .await
            .unwrap();
        // This tests the store transaction, not the endpoint's existing filesystem reset.
        state
            .store
            .reset_workspace("wonder-desktop", "3")
            .await
            .unwrap();
        assert!(state
            .store
            .project_assignment(&a.id)
            .await
            .unwrap()
            .is_none());
        assert!(state.store.channel("group").await.unwrap().is_none());
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
