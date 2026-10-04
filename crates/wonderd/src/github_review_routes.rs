//! Owner-authorized Project GitHub review. Local folder permission alone never
//! grants remote access. No route accepts an API URL, credential or command.
use crate::{
    github_review::{GitHubReviewClient, ReviewError},
    AppState, AuthenticatedDevice, LocalOwnerAuthority, OwnerAuthority, SignedActionFields,
};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Extension, Json,
};
use serde::Deserialize;
use serde_json::json;
use std::{process::Stdio, time::Duration};
use tokio::io::AsyncReadExt;
use wonder_store::{ProjectGitHubReviewBinding, StoredProjectRoot};

type Failure = (StatusCode, &'static str);
static SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);
fn storage(_: sqlx::Error) -> Failure {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        "GitHub review settings could not be loaded. Try again.",
    )
}
fn upstream(error: ReviewError) -> Failure {
    (
        match error {
            ReviewError::Authentication | ReviewError::Access => StatusCode::FORBIDDEN,
            ReviewError::RateLimit => StatusCode::TOO_MANY_REQUESTS,
            ReviewError::ChangedIdentity => StatusCode::CONFLICT,
            _ => StatusCode::SERVICE_UNAVAILABLE,
        },
        error.detail(),
    )
}
fn mutation(error: sqlx::Error) -> Failure {
    if matches!(error, sqlx::Error::Protocol(_)) {
        (
            StatusCode::CONFLICT,
            "Review settings changed. Reload before connecting or disconnecting.",
        )
    } else {
        storage(error)
    }
}
#[derive(Clone, Eq, PartialEq)]
struct Scope {
    project_id: String,
    root: StoredProjectRoot,
    roots_revision: i64,
    authorization_revision: i64,
}
async fn stored_scope(state: &AppState, project_id: &str, root_id: &str) -> Result<Scope, Failure> {
    let project = state
        .store
        .project(project_id)
        .await
        .map_err(storage)?
        .filter(|p| p.is_included)
        .ok_or((
            StatusCode::NOT_FOUND,
            "This Project is no longer included in Wonder.",
        ))?;
    let root = project
        .roots
        .iter()
        .find(|r| r.id == root_id)
        .cloned()
        .ok_or((
            StatusCode::FORBIDDEN,
            "This folder is no longer in the Project.",
        ))?;
    let revision = state
        .store
        .project_github_review_authorization_revision(project_id)
        .await
        .map_err(storage)?
        .ok_or((
            StatusCode::FORBIDDEN,
            "This Project is no longer included in Wonder.",
        ))?;
    Ok(Scope {
        project_id: project_id.into(),
        root,
        roots_revision: project.roots_revision,
        authorization_revision: revision,
    })
}
async fn scope(state: &AppState, project_id: &str, root_id: &str) -> Result<Scope, Failure> {
    let scope = stored_scope(state, project_id, root_id).await?;
    let project = state
        .store
        .project(project_id)
        .await
        .map_err(storage)?
        .ok_or((StatusCode::NOT_FOUND, "This Project was removed."))?;
    if project.roots_revision != scope.roots_revision || !project.is_included {
        return Err((
            StatusCode::CONFLICT,
            "Project folders changed. Reload this review.",
        ));
    }
    let checked = project.clone();
    let denied = state.denied_roots.clone();
    tokio::task::spawn_blocking(move || {
        crate::projects::validate_execution_roots(&checked, &denied)
    })
    .await
    .map_err(|_| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            "Project folders could not be checked.",
        )
    })?
    .map_err(|_| {
        (
            StatusCode::FORBIDDEN,
            "A Project folder changed or is no longer allowed. Review its folders.",
        )
    })?;
    Ok(scope)
}
// Keep this short guard through the grant transaction. Device revocation holds
// the same lock while changing durable and in-memory authority.
async fn current_owner<'a>(
    state: &'a AppState,
    headers: &HeaderMap,
    local: bool,
) -> Result<tokio::sync::MutexGuard<'a, wonder_api::pairing_protocol::PairingState>, Failure> {
    let pairing = state.pairing.lock().await;
    if local {
        return Ok(pairing);
    }
    let error = (
        StatusCode::UNAUTHORIZED,
        "Reconnect your device before reviewing GitHub.",
    );
    let session = crate::cookie_value(headers, "__Host-wonder_session").ok_or(error)?;
    let csrf = headers.get("x-wonder-csrf").and_then(|h| h.to_str().ok());
    pairing
        .verify_session(&session, csrf, crate::now_ms())
        .map_err(|_| error)?;
    Ok(pairing)
}

async fn recheck(state: &AppState, before: &Scope) -> Result<(), Failure> {
    let after = scope(state, &before.project_id, &before.root.id).await?;
    if after != *before {
        return Err((
            StatusCode::CONFLICT,
            "Project folders or review authorization changed. Reload this review.",
        ));
    }
    Ok(())
}
async fn recheck_stored(state: &AppState, before: &Scope) -> Result<(), Failure> {
    if stored_scope(state, &before.project_id, &before.root.id).await? != *before {
        return Err((
            StatusCode::CONFLICT,
            "Review settings changed. Reload this review.",
        ));
    }
    Ok(())
}
fn parse_remote(value: &str) -> Option<String> {
    if value.contains(['%', '\\']) || value.split('/').any(|part| part == "." || part == "..") {
        return None;
    }
    let path = if let Some(path) = value.strip_prefix("git@github.com:") {
        path.to_owned()
    } else {
        let url = reqwest::Url::parse(value).ok()?;
        if url.host_str() != Some("github.com")
            || url.port().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || url.password().is_some()
            || !((url.scheme() == "https" && url.username().is_empty())
                || (url.scheme() == "ssh" && url.username() == "git"))
        {
            return None;
        }
        url.path().strip_prefix('/')?.to_owned()
    };
    let path = path.strip_suffix(".git").unwrap_or(&path);
    let (owner, name) = path.split_once('/')?;
    if owner.is_empty()
        || owner.len() > 100
        || !owner
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        || name.is_empty()
        || name.len() > 100
        || name == "."
        || name == ".."
        || !name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
    {
        return None;
    }
    Some(path.into())
}
async fn repository(scope: &Scope) -> Result<String, Failure> {
    let error = (
        StatusCode::UNPROCESSABLE_ENTITY,
        "Choose a Project folder that is a GitHub repository with an origin remote.",
    );
    let path = &scope.root.canonical_path;
    let top =
        crate::project_assignments::read_only_git_bytes(path, &["rev-parse", "--show-toplevel"])
            .await
            .map_err(|_| error)?;
    let top = std::str::from_utf8(&top).map_err(|_| error)?.trim();
    let top = tokio::fs::canonicalize(top).await.map_err(|_| error)?;
    // Do not inherit repository metadata from an unselected ancestor folder.
    if top.as_path() != std::path::Path::new(path) {
        return Err(error);
    }
    let remote = crate::project_assignments::read_only_git_bytes(
        path,
        &["config", "--local", "--get", "remote.origin.url"],
    )
    .await
    .map_err(|_| error)?;
    if remote.len() > 4096 {
        return Err(error);
    }
    parse_remote(std::str::from_utf8(&remote).map_err(|_| error)?.trim()).ok_or(error)
}
async fn credential() -> Result<GitHubReviewClient, Failure> {
    let error = (
        StatusCode::SERVICE_UNAVAILABLE,
        "GitHub CLI must be installed and signed in on your Mac before connecting this repository.",
    );
    let mut child = tokio::process::Command::new("gh")
        .args(["auth", "token", "--hostname", "github.com"])
        .env("GH_PROMPT_DISABLED", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| error)?;
    let stdout = child.stdout.take().ok_or(error)?;
    let token = tokio::time::timeout(Duration::from_secs(5), async {
        let mut bytes = Vec::new();
        stdout
            .take(16 * 1024 + 1)
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| error)?;
        let status = child.wait().await.map_err(|_| error)?;
        if !status.success() || bytes.len() > 16 * 1024 {
            return Err(error);
        }
        String::from_utf8(bytes).map_err(|_| error)
    })
    .await
    .map_err(|_| error)??;
    GitHubReviewClient::new(token.trim()).map_err(upstream)
}
async fn consent(
    state: &AppState,
    owner: &RequestOwner<'_>,
    action: &str,
    target: &str,
    body: &serde_json::Value,
    fields: &SignedActionFields,
    revision: i64,
) -> Result<(), Failure> {
    if owner.local {
        return Ok(());
    }
    let device = owner.device.ok_or((
        StatusCode::UNAUTHORIZED,
        "A paired owner device is required.",
    ))?;
    crate::verify_signed_action(
        state,
        device,
        action,
        target,
        &crate::action_body_sha256(body),
        fields,
        &revision.to_string(),
    )
    .await
    .map_err(|_| {
        (
            StatusCode::FORBIDDEN,
            "Confirm this GitHub review change again on your device.",
        )
    })
}

pub(super) async fn status(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path((project, root)): Path<(String, String)>,
    headers: HeaderMap,
    local: Option<Extension<LocalOwnerAuthority>>,
) -> Response {
    async {
        let scope = stored_scope(&state, &project, &root).await?;
        let binding = state
            .store
            .project_github_review_binding(&project, &root)
            .await
            .map_err(storage)?;
        let _owner = current_owner(&state, &headers, local.is_some()).await?;
        recheck_stored(&state, &scope).await?;
        let response = json!({
            "hostInstallationId": state.host_installation_id,
            "projectId": project,
            "rootId": root,
            "rootsRevision": scope.roots_revision,
            "authorizationRevision": scope.authorization_revision,
            "connected": binding.is_some(),
            "repository": binding.as_ref().map(|b| &b.repository),
            "repositoryId": binding.as_ref().map(|b| b.repository_id),
            "accountId": binding.as_ref().map(|b| b.account_id),
        });
        Ok::<_, Failure>(Json(response))
    }
    .await
    .into_response()
}
pub(super) async fn prepare(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path((project, root)): Path<(String, String)>,
    headers: HeaderMap,
    local: Option<Extension<LocalOwnerAuthority>>,
) -> Response {
    prepare_review(
        &state,
        &project,
        &root,
        &headers,
        local.is_some(),
        credential(),
    )
    .await
    .into_response()
}
async fn prepare_review(
    state: &AppState,
    project: &str,
    root: &str,
    headers: &HeaderMap,
    local: bool,
    client: impl std::future::Future<Output = Result<GitHubReviewClient, Failure>>,
) -> Result<Json<serde_json::Value>, Failure> {
    let _slot = SLOTS.try_acquire().map_err(|_| {
        (
            StatusCode::TOO_MANY_REQUESTS,
            "Another GitHub review is loading. Try again shortly.",
        )
    })?;
    let scope = scope(state, project, root).await?;
    let repository = repository(&scope).await?;
    let client = client.await?;
    let identity = client.connection(&repository).await.map_err(upstream)?;
    if !repository.eq_ignore_ascii_case(&self::repository(&scope).await?) {
        return Err((
            StatusCode::CONFLICT,
            "This folder's repository changed. Reload before connecting.",
        ));
    }
    recheck(state, &scope).await?;
    let _owner = current_owner(state, headers, local).await?;
    recheck_stored(state, &scope).await?;
    Ok::<_, Failure>(Json(
        json!({"hostInstallationId":state.host_installation_id,"projectId":project,"rootId":root,
            "rootsRevision":scope.roots_revision,"authorizationRevision":scope.authorization_revision,"identity":identity}),
    ))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Authorize {
    roots_revision: i64,
    authorization_revision: i64,
    account_id: i64,
    repository_id: i64,
    repository: String,
    confirm_read_access: bool,
    action_nonce: Option<String>,
    issued_at_ms: Option<u64>,
    signature: Option<String>,
}
pub(super) async fn authorize(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path((project, root)): Path<(String, String)>,
    device: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    headers: HeaderMap,
    Json(request): Json<Authorize>,
) -> Response {
    authorize_review(
        &state,
        &project,
        &root,
        RequestOwner {
            device: device.as_ref().map(|d| &d.0),
            local: local.is_some(),
            headers: &headers,
        },
        request,
        credential(),
    )
    .await
    .into_response()
}
struct RequestOwner<'a> {
    device: Option<&'a AuthenticatedDevice>,
    local: bool,
    headers: &'a HeaderMap,
}
async fn authorize_review(
    state: &AppState,
    project: &str,
    root: &str,
    owner: RequestOwner<'_>,
    request: Authorize,
    client: impl std::future::Future<Output = Result<GitHubReviewClient, Failure>>,
) -> Result<StatusCode, Failure> {
    if !request.confirm_read_access {
        return Err((
            StatusCode::BAD_REQUEST,
            "Confirm read access to this GitHub repository.",
        ));
    }
    let _slot = SLOTS.try_acquire().map_err(|_| {
        (
            StatusCode::TOO_MANY_REQUESTS,
            "Another GitHub review is loading. Try again shortly.",
        )
    })?;
    let scope = scope(state, project, root).await?;
    if scope.roots_revision != request.roots_revision
        || scope.authorization_revision != request.authorization_revision
    {
        return Err((
            StatusCode::CONFLICT,
            "Project folders or review settings changed. Reload before connecting.",
        ));
    }
    let remote = repository(&scope).await?;
    if !remote.eq_ignore_ascii_case(&request.repository) {
        return Err((
            StatusCode::CONFLICT,
            "This folder's repository changed. Reload before connecting.",
        ));
    }
    let client = client.await?;
    let identity = client.connection(&remote).await.map_err(upstream)?;
    if identity.account_id != request.account_id
        || identity.repository_id != request.repository_id
        || identity.repository != request.repository
    {
        return Err((
            StatusCode::CONFLICT,
            "The GitHub account or repository changed. Confirm the connection again.",
        ));
    }
    recheck(state, &scope).await?;
    if !remote.eq_ignore_ascii_case(&repository(&scope).await?) {
        return Err((
            StatusCode::CONFLICT,
            "This folder's repository changed. Reload before connecting.",
        ));
    }
    let target = format!("/api/v1/projects/{project}/github-review/{root}");
    let body = json!([
        request.roots_revision,
        request.authorization_revision,
        request.account_id,
        request.repository_id,
        request.repository,
        true
    ]);
    let fields = SignedActionFields {
        action_nonce: request.action_nonce,
        issued_at_ms: request.issued_at_ms,
        signature: request.signature,
    };
    consent(
        state,
        &owner,
        "github.review.authorize",
        &target,
        &body,
        &fields,
        scope.authorization_revision,
    )
    .await?;
    recheck(state, &scope).await?;
    let _owner = current_owner(state, owner.headers, owner.local).await?;
    recheck_stored(state, &scope).await?;
    state
        .store
        .authorize_project_github_review(
            &ProjectGitHubReviewBinding {
                project_id: project.into(),
                root_id: root.into(),
                roots_revision: scope.roots_revision,
                account_id: identity.account_id,
                repository_id: identity.repository_id,
                repository: identity.repository,
                authorized_at: chrono::Utc::now().to_rfc3339(),
            },
            scope.authorization_revision,
        )
        .await
        .map_err(mutation)?;
    Ok::<_, Failure>(StatusCode::NO_CONTENT)
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Revoke {
    authorization_revision: i64,
    action_nonce: Option<String>,
    issued_at_ms: Option<u64>,
    signature: Option<String>,
}
pub(super) async fn revoke(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path((project, root)): Path<(String, String)>,
    device: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    headers: HeaderMap,
    Json(request): Json<Revoke>,
) -> Response {
    async {
        // Disconnect must work even if a folder is denied, replaced or gone.
        let record = state
            .store
            .project(&project)
            .await
            .map_err(storage)?
            .ok_or((StatusCode::NOT_FOUND, "This Project was removed."))?;
        if !record.roots.iter().any(|r| r.id == root) {
            return Err((StatusCode::NOT_FOUND, "This Project folder was removed."));
        }
        let target = format!("/api/v1/projects/{project}/github-review/{root}");
        let fields = SignedActionFields {
            action_nonce: request.action_nonce,
            issued_at_ms: request.issued_at_ms,
            signature: request.signature,
        };
        consent(
            &state,
            &RequestOwner {
                device: device.as_ref().map(|d| &d.0),
                local: local.is_some(),
                headers: &headers,
            },
            "github.review.revoke",
            &target,
            &json!([request.authorization_revision]),
            &fields,
            request.authorization_revision,
        )
        .await?;
        let _owner = current_owner(&state, &headers, local.is_some()).await?;
        state
            .store
            .revoke_project_github_review(&project, &root, request.authorization_revision)
            .await
            .map_err(mutation)?;
        Ok::<_, Failure>(StatusCode::NO_CONTENT)
    }
    .await
    .into_response()
}
pub(super) async fn snapshot(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Path((project, root, number)): Path<(String, String, u64)>,
    headers: HeaderMap,
    local: Option<Extension<LocalOwnerAuthority>>,
) -> Response {
    snapshot_review(
        &state,
        &project,
        &root,
        number,
        &headers,
        local.is_some(),
        credential(),
    )
    .await
    .into_response()
}
async fn snapshot_review(
    state: &AppState,
    project: &str,
    root: &str,
    number: u64,
    headers: &HeaderMap,
    local: bool,
    client: impl std::future::Future<Output = Result<GitHubReviewClient, Failure>>,
) -> Result<Json<serde_json::Value>, Failure> {
    let _slot = SLOTS.try_acquire().map_err(|_| {
        (
            StatusCode::TOO_MANY_REQUESTS,
            "Another GitHub review is loading. Try again shortly.",
        )
    })?;
    let scope = scope(state, project, root).await?;
    let binding = state
        .store
        .project_github_review_binding(project, root)
        .await
        .map_err(storage)?
        .ok_or((
            StatusCode::FORBIDDEN,
            "Connect this repository before reviewing its pull requests.",
        ))?;
    let remote = repository(&scope).await?;
    if !remote.eq_ignore_ascii_case(&binding.repository) {
        return Err((
            StatusCode::CONFLICT,
            "This folder's repository changed. Reconnect it before reviewing.",
        ));
    }
    let client = client.await?;
    let snapshot = client.snapshot(&binding, number).await.map_err(upstream)?;
    if !remote.eq_ignore_ascii_case(&repository(&scope).await?) {
        return Err((
            StatusCode::CONFLICT,
            "This folder's repository changed. Reload this review.",
        ));
    }
    recheck(state, &scope).await?;
    finish_snapshot(state, &scope, &binding, headers, local, snapshot).await
}
async fn finish_snapshot(
    state: &AppState,
    scope: &Scope,
    binding: &ProjectGitHubReviewBinding,
    headers: &HeaderMap,
    local: bool,
    snapshot: crate::github_review::PullRequestSnapshot,
) -> Result<Json<serde_json::Value>, Failure> {
    let _owner = current_owner(state, headers, local).await?;
    recheck_stored(state, scope).await?;
    if state
        .store
        .project_github_review_binding(&scope.project_id, &scope.root.id)
        .await
        .map_err(storage)?
        .as_ref()
        != Some(binding)
    {
        return Err((
            StatusCode::CONFLICT,
            "Review authority changed. Reload this review.",
        ));
    }
    Ok(Json(
        json!({"hostInstallationId":state.host_installation_id,"authorizationRevision":scope.authorization_revision,"snapshot":snapshot}),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::validate_http_contract as validate;
    use axum::body::{to_bytes, Body};
    use base64::Engine;
    use p256::ecdsa::{signature::Signer, Signature, SigningKey};
    use sha2::{Digest, Sha256};
    use tower::ServiceExt;
    use wonder_api::pairing_protocol::{session_token_hash, DevicePublicKeyJwk};
    static RUN: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    async fn fixture() -> (tempfile::TempDir, AppState, String) {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let root = dir.path().join("repo");
        std::fs::create_dir(&root).unwrap();
        for args in [
            vec!["init", "--quiet"],
            vec!["remote", "add", "origin", "git@github.com:owner/repo.git"],
        ] {
            assert!(std::process::Command::new("git")
                .arg("-C")
                .arg(&root)
                .args(args)
                .status()
                .unwrap()
                .success());
        }
        let path = root.canonicalize().unwrap().to_str().unwrap().to_owned();
        state
            .store
            .create_project(
                "project",
                "create",
                "hash",
                "App",
                &[wonder_store::ProjectRootInput {
                    path: path.clone(),
                    canonical_path: path,
                }],
                0,
                "now",
            )
            .await
            .unwrap();
        let root = state
            .store
            .project("project")
            .await
            .unwrap()
            .unwrap()
            .primary_root_id;
        (dir, state, root)
    }
    fn request() -> Authorize {
        Authorize {
            roots_revision: 1,
            authorization_revision: 0,
            account_id: 42,
            repository_id: 123,
            repository: "owner/repo".into(),
            confirm_read_access: true,
            action_nonce: None,
            issued_at_ms: None,
            signature: None,
        }
    }
    async fn grant(state: &AppState, root: &str) {
        state
            .store
            .authorize_project_github_review(
                &ProjectGitHubReviewBinding {
                    project_id: "project".into(),
                    root_id: root.into(),
                    roots_revision: 1,
                    account_id: 42,
                    repository_id: 123,
                    repository: "owner/repo".into(),
                    authorized_at: "now".into(),
                },
                0,
            )
            .await
            .unwrap();
    }
    async fn session(
        state: &AppState,
        expires: u64,
    ) -> (HeaderMap, AuthenticatedDevice, SigningKey) {
        let key = SigningKey::from_slice(&[11_u8; 32]).unwrap();
        let point = key.verifying_key().to_sec1_point(false);
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let mut pairing = state.pairing.lock().await;
        pairing.restore_device(
            "owner".into(),
            DevicePublicKeyJwk {
                kty: "EC".into(),
                crv: "P-256".into(),
                x: b64.encode(point.x().unwrap()),
                y: b64.encode(point.y().unwrap()),
            },
            false,
            None,
        );
        pairing.restore_session(
            session_token_hash("test-session"),
            "owner".into(),
            Sha256::digest(b"csrf").into(),
            expires,
        );
        let mut headers = HeaderMap::new();
        headers.insert(
            "cookie",
            "__Host-wonder_session=test-session".parse().unwrap(),
        );
        headers.insert("x-wonder-csrf", "csrf".parse().unwrap());
        (
            headers,
            AuthenticatedDevice {
                device_id: "owner".into(),
                session_binding: "csrf".into(),
            },
            key,
        )
    }
    fn signed(state: &AppState, root: &str, key: &SigningKey) -> Authorize {
        let mut r = request();
        let issued = crate::now_ms();
        let path = format!("/api/v1/projects/project/github-review/{root}");
        let body = crate::action_body_sha256(&json!([1, 0, 42, 123, "owner/repo", true]));
        let transcript = wonder_api::pairing::ActionTranscript {
            action: "github.review.authorize",
            target: &path,
            body_sha256: &body,
            action_nonce: "authorize-test",
            session_binding: "csrf",
            device_id: "owner",
            host_installation_id: &state.host_installation_id,
            issued_at_ms: issued,
            expected_state: "0",
        };
        let signature: Signature = key.sign(&transcript.to_bytes());
        r.action_nonce = Some("authorize-test".into());
        r.issued_at_ms = Some(issued);
        r.signature =
            Some(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(signature.to_bytes()));
        r
    }
    async fn expire(state: &AppState) {
        state.pairing.lock().await.restore_session(
            session_token_hash("test-session"),
            "owner".into(),
            Sha256::digest(b"csrf").into(),
            crate::now_ms(),
        );
    }
    async fn call(
        state: &AppState,
        method: &str,
        path: &str,
        body: serde_json::Value,
        local: bool,
    ) -> Response {
        let mut request = axum::http::Request::builder()
            .method(method)
            .uri(path)
            .header("content-type", "application/json");
        if local {
            request = request.header("x-wonder-loopback-capability", &state.loopback_capability);
        }
        crate::router(state.clone())
            .oneshot(request.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap()
    }
    async fn data(response: Response) -> serde_json::Value {
        serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap()
    }
    async fn no_credential() -> Result<GitHubReviewClient, Failure> {
        panic!("unauthorized request must not discover credentials")
    }

    #[test]
    fn remote_is_exact_github_repository_without_url_normalization() {
        for remote in [
            "git@github.com:owner/repo.git",
            "https://github.com/owner/repo",
            "ssh://git@github.com/owner/repo.git",
        ] {
            assert_eq!(parse_remote(remote).as_deref(), Some("owner/repo"));
        }
        for remote in [
            "https://github.com/owner/x/../repo",
            "https://github.com/owner/%2e%2e/repo",
            "https://token@github.com/owner/repo",
            "https://github.com/owner/repo?token=x",
            "https://evil.test/owner/repo",
            "git@github.com:owner/../repo",
            "https://github.com/owner/repo/extra",
            "ssh://other@github.com/owner/repo",
        ] {
            assert!(parse_remote(remote).is_none(), "{remote}");
        }
    }

    // Existing store CAS owns stale grants. These routes own disk-independent
    // disconnect, session fencing after awaited reads and credential discovery.
    #[tokio::test]
    async fn unavailable_folder_status_still_allows_disconnect_and_stale_disconnect_cannot_remove_new_grant(
    ) {
        let _run = RUN.lock().await;
        for missing in [false, true] {
            let (_dir, mut state, root) = fixture().await;
            grant(&state, &root).await;
            let path = format!("/api/v1/projects/project/github-review/{root}");
            let folder = state.store.project("project").await.unwrap().unwrap().roots[0]
                .canonical_path
                .clone();
            if missing {
                std::fs::remove_dir_all(folder).unwrap();
            } else {
                state.denied_roots = vec![folder];
            }
            assert_eq!(
                call(&state, "GET", &path, json!(null), false)
                    .await
                    .status(),
                StatusCode::FORBIDDEN
            );
            let response = call(&state, "GET", &path, json!(null), true).await;
            assert_eq!(response.status(), StatusCode::OK);
            let status = data(response).await;
            validate("projectGitHubReviewStatus", &status);
            assert_eq!(status["authorizationRevision"], 1);
            assert_eq!(status["connected"], true);
            assert_eq!(
                call(
                    &state,
                    "DELETE",
                    &path,
                    json!({"authorizationRevision":1}),
                    true
                )
                .await
                .status(),
                StatusCode::NO_CONTENT
            );
            assert_eq!(
                data(call(&state, "GET", &path, json!(null), true).await).await["connected"],
                false
            );
        }
        let (_dir, state, root) = fixture().await;
        grant(&state, &root).await;
        let path = format!("/api/v1/projects/project/github-review/{root}");
        let mut binding = state
            .store
            .project_github_review_binding("project", &root)
            .await
            .unwrap()
            .unwrap();
        binding.repository_id = 456;
        state
            .store
            .authorize_project_github_review(&binding, 1)
            .await
            .unwrap();
        assert_eq!(
            call(
                &state,
                "DELETE",
                &path,
                json!({"authorizationRevision":1}),
                true
            )
            .await
            .status(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            state
                .store
                .project_github_review_binding("project", &root)
                .await
                .unwrap(),
            Some(binding)
        );
    }

    #[tokio::test]
    async fn held_upstream_cannot_return_private_data_after_device_revocation_or_session_expiry() {
        let _run = RUN.lock().await;
        for revoked in [false, true] {
            let (_dir, state, root) = fixture().await;
            grant(&state, &root).await;
            let (headers, _, _) = session(&state, u64::MAX).await;
            let (server, entered, release) = crate::github_review::tests::held_server(1).await;
            let client = server.review_client();
            let pending = snapshot_review(&state, "project", &root, 7, &headers, false, async {
                Ok(client)
            });
            let revoke = async {
                entered.notified().await;
                if revoked {
                    state.pairing.lock().await.revoke_device("owner");
                } else {
                    expire(&state).await;
                }
                release.notify_one();
            };
            let (result, ()) = tokio::join!(pending, revoke);
            assert_eq!(result.err().unwrap().0, StatusCode::UNAUTHORIZED);
        }
        let (_dir, state, root) = fixture().await;
        let (headers, _, _) = session(&state, u64::MAX).await;
        let (server, entered, release) = crate::github_review::tests::held_server(1).await;
        let client = server.review_client();
        let (result, ()) = tokio::join!(
            prepare_review(&state, "project", &root, &headers, false, async {
                Ok(client)
            }),
            async {
                entered.notified().await;
                state.pairing.lock().await.revoke_device("owner");
                release.notify_one();
            }
        );
        assert_eq!(result.err().unwrap().0, StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn held_consent_cannot_create_grant_after_revocation_or_expiry() {
        let _run = RUN.lock().await;
        for revoked in [false, true] {
            let (_dir, state, root) = fixture().await;
            let (headers, device, key) = session(&state, u64::MAX).await;
            let r = signed(&state, &root, &key);
            let (server, entered, release) = crate::github_review::tests::held_server(1).await;
            let client = server.review_client();
            let (result, ()) = tokio::join!(
                authorize_review(
                    &state,
                    "project",
                    &root,
                    RequestOwner {
                        headers: &headers,
                        device: Some(&device),
                        local: false
                    },
                    r,
                    async { Ok(client) }
                ),
                async {
                    entered.notified().await;
                    if revoked {
                        state.pairing.lock().await.revoke_device("owner");
                    } else {
                        expire(&state).await;
                    }
                    release.notify_one();
                }
            );
            assert_eq!(
                result.unwrap_err().0,
                if revoked {
                    StatusCode::FORBIDDEN
                } else {
                    StatusCode::UNAUTHORIZED
                }
            );
            assert!(state
                .store
                .project_github_review_binding("project", &root)
                .await
                .unwrap()
                .is_none());
        }
    }

    #[tokio::test]
    async fn verified_owner_connection_and_snapshot_work_and_ungranted_reads_do_not_load_credentials(
    ) {
        let _run = RUN.lock().await;
        let (_dir, state, root) = fixture().await;
        let headers = HeaderMap::new();
        assert_eq!(
            snapshot_review(&state, "project", &root, 7, &headers, true, no_credential())
                .await
                .err()
                .unwrap()
                .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            prepare_review(&state, "other", &root, &headers, true, no_credential())
                .await
                .err()
                .unwrap()
                .0,
            StatusCode::NOT_FOUND
        );
        let (server, _, release) = crate::github_review::tests::held_server(1).await;
        release.notify_one();
        let prepared = prepare_review(&state, "project", &root, &headers, true, async {
            Ok(server.review_client())
        })
        .await
        .unwrap();
        validate("prepareProjectGitHubReviewResponse", &prepared.0);
        assert_eq!(prepared.0["identity"]["accountId"], 42);
        assert_eq!(prepared.0["identity"]["repositoryId"], 123);
        let (paired_headers, device, key) = session(&state, u64::MAX).await;
        let consent_request = signed(&state, &root, &key);
        assert_eq!(
            authorize_review(
                &state,
                "project",
                &root,
                RequestOwner {
                    headers: &paired_headers,
                    device: Some(&device),
                    local: false
                },
                consent_request,
                async { Ok(server.review_client()) }
            )
            .await
            .unwrap(),
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            authorize_review(
                &state,
                "project",
                &root,
                RequestOwner {
                    headers: &headers,
                    device: None,
                    local: true
                },
                request(),
                no_credential()
            )
            .await
            .unwrap_err()
            .0,
            StatusCode::CONFLICT
        );
        let snapshot = snapshot_review(&state, "project", &root, 7, &headers, true, async {
            Ok(server.review_client())
        })
        .await
        .unwrap();
        validate("projectGitHubReviewResponse", &snapshot.0);
        assert_eq!(snapshot.0["snapshot"]["files"].as_array().unwrap().len(), 1);
    }
    #[tokio::test]
    async fn upstream_wait_cannot_hide_changed_remote_or_disconnected_grant() {
        let _run = RUN.lock().await;
        let (_dir, state, root) = fixture().await;
        let scope = scope(&state, "project", &root).await.unwrap();
        let (server, entered, release) = crate::github_review::tests::held_server(1).await;
        let client = server.review_client();
        let headers = HeaderMap::new();
        let (result, ()) = tokio::join!(
            prepare_review(&state, "project", &root, &headers, true, async {
                Ok(client)
            }),
            async {
                entered.notified().await;
                let status = std::process::Command::new("git")
                    .arg("-C")
                    .arg(&scope.root.canonical_path)
                    .args([
                        "remote",
                        "set-url",
                        "origin",
                        "git@github.com:owner/changed.git",
                    ])
                    .status()
                    .unwrap();
                assert!(status.success());
                release.notify_one();
            }
        );
        assert_eq!(result.err().unwrap().0, StatusCode::CONFLICT);
        let (_dir, state, root) = fixture().await;
        grant(&state, &root).await;
        let (server, entered, release) = crate::github_review::tests::held_server(1).await;
        let client = server.review_client();
        let (result, ()) = tokio::join!(
            snapshot_review(&state, "project", &root, 7, &headers, true, async {
                Ok(client)
            }),
            async {
                entered.notified().await;
                state
                    .store
                    .revoke_project_github_review("project", &root, 1)
                    .await
                    .unwrap();
                release.notify_one();
            }
        );
        assert_eq!(result.err().unwrap().0, StatusCode::CONFLICT);
    }
    #[tokio::test]
    async fn disconnect_committed_while_completed_snapshot_waits_for_owner_lock_fences_response() {
        use std::{future::Future, task::Poll};
        let _run = RUN.lock().await;
        for local in [false, true] {
            let (_dir, state, root) = fixture().await;
            grant(&state, &root).await;
            let (headers, _, _) = session(&state, u64::MAX).await;
            let scope = scope(&state, "project", &root).await.unwrap();
            let binding = state
                .store
                .project_github_review_binding("project", &root)
                .await
                .unwrap()
                .unwrap();
            let (server, _, release) = crate::github_review::tests::held_server(1).await;
            release.notify_one();
            let snapshot = server.review_client().snapshot(&binding, 7).await.unwrap();
            let owner = state.pairing.lock().await;
            let pending = finish_snapshot(&state, &scope, &binding, &headers, local, snapshot);
            tokio::pin!(pending);
            // Poll the real final response boundary once: it is now queued on
            // the lock held by the disconnect, with the old snapshot assembled.
            std::future::poll_fn(|cx| {
                assert!(pending.as_mut().poll(cx).is_pending());
                Poll::Ready(())
            })
            .await;
            state
                .store
                .revoke_project_github_review("project", &root, 1)
                .await
                .unwrap();
            drop(owner);
            assert_eq!(pending.await.err().unwrap().0, StatusCode::CONFLICT);
        }
    }
}
