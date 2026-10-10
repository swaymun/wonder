//! Keep provider runtimes current with what is installed on the Mac, and let
//! Settings → Providers reconnect one.
//!
//! ChatGPT replaces its bundled Codex in place (Sparkle swaps the app). A
//! running app-server keeps executing the replaced binary until it exits, and
//! a runtime rejected as unsupported is only re-verified when something asks
//! for it, so an update was never picked up without restarting Wonder. The
//! watcher notices the replaced install, re-locates it and restarts each
//! Codex runtime once it is idle; startup verification then accepts or
//! rejects the new version. Claude's SDK updates are staged by the sidecar
//! and activate between requests on their own; a reconnect restarts the
//! sidecar, which also activates a staged version immediately.

use crate::{AppState, LocalOwnerAuthority, OwnerAuthority};
use axum::{
    extract::{Extension, Path as RoutePath, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::OnceLock,
    time::{Duration, Instant},
};
use wonder_store::AgentFamily;

const WATCH_INTERVAL: Duration = Duration::from_secs(60);
const RECONNECT_TIMEOUT: Duration = Duration::from_secs(30);
/// Installed-provider checks spawn the provider's CLI; a paired device sees a
/// cached answer this fresh unless it asks again.
const INSTALLED_MAX_AGE: Duration = Duration::from_secs(30);
const INSTALLED_TIMEOUT: Duration = Duration::from_secs(20);

/// The Codex launcher ChatGPT ships, or `WONDER_CODEX_BIN`.
pub fn locate_codex() -> PathBuf {
    if let Some(path) = std::env::var_os("WONDER_CODEX_BIN") {
        return PathBuf::from(path);
    }
    let resources = Path::new("/Applications/ChatGPT.app/Contents/Resources");
    // The supported launcher preserves adjacency with codex-code-mode-host.
    // Do not select the nested Mach-O directly; its helper lives elsewhere.
    let current = resources.join("codex-cli/bin/codex");
    if current.is_file() {
        current
    } else {
        resources.join("codex")
    }
}

/// Identity of an installed Codex: a replaced app bundle gives the launcher
/// and the binary it starts new inodes and modification times.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Fingerprint(Vec<(PathBuf, u64, u64, i64)>);

fn fingerprint(launcher: &Path) -> Option<Fingerprint> {
    use std::os::unix::fs::MetadataExt;
    let launcher = std::fs::canonicalize(launcher).ok()?;
    let nested = launcher
        .parent()
        .map(|bin| bin.join("../CodexCLI.app/Contents/MacOS/codex"))
        .and_then(|path| std::fs::canonicalize(path).ok());
    let mut files = Vec::new();
    for path in std::iter::once(launcher).chain(nested) {
        let metadata = std::fs::metadata(&path).ok()?;
        files.push((path, metadata.ino(), metadata.len(), metadata.mtime()));
    }
    Some(Fingerprint(files))
}

pub fn spawn_update_watcher(state: AppState) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut installed = fingerprint(&locate_codex());
        loop {
            tokio::time::sleep(WATCH_INTERVAL).await;
            let path = locate_codex();
            let current = fingerprint(&path);
            if current.is_some() && current != installed {
                installed = current;
                use_codex_install(&state, path).await;
                state.ingestion.set_update_pending(AgentFamily::Codex, true);
                let _ = state
                    .logger
                    .record("info", "codex_runtime_update_detected", json!({}));
            }
            if state
                .ingestion
                .provider_runtime_state(AgentFamily::Codex)
                .update_pending
                && replace_stale_codex(&state).await
            {
                state
                    .ingestion
                    .set_update_pending(AgentFamily::Codex, false);
                let _ = state.logger.record(
                    "info",
                    "codex_runtime_update_applied",
                    json!({"incompatible": state.ingestion.provider_runtime_state(AgentFamily::Codex).incompatible}),
                );
            }
        }
    })
}

async fn use_codex_install(state: &AppState, path: PathBuf) {
    state.launch_config.lock().await.codex_bin = path.clone();
    state.projects.set_codex_bin(path);
}

/// Whether a Wonder message is running on `family` (Bots, Groups or
/// Projects). Fails closed.
async fn provider_busy(state: &AppState, family: AgentFamily, projects: Option<bool>) -> bool {
    let Ok(messages) = state.store.active_runtime_messages().await else {
        return true;
    };
    for message in messages.iter().filter(|m| m.state != "uncertain") {
        if let Some(projects) = projects {
            if crate::projects::is_project(state, &message.conversation_id).await != projects {
                continue;
            }
        }
        match crate::claude::conversation_family(state, &message.conversation_id).await {
            Ok(found) if found != family => {}
            _ => return true,
        }
    }
    false
}

/// Restart every idle Codex runtime that runs a replaced binary. Returns
/// whether none is left running the old one.
async fn replace_stale_codex(state: &AppState) -> bool {
    let mut replaced = true;
    if state.projects.codex_alive().await {
        if crate::projects::release_codex_runtime_when_idle(state, true).await {
            // Start the new install now so readiness reflects it.
            let _ = crate::projects::codex_rpc(state).await;
        } else {
            replaced = false;
        }
    } else if state
        .ingestion
        .provider_runtime_state(AgentFamily::Codex)
        .incompatible
    {
        // An earlier version was rejected; verify the new one.
        let _ = crate::projects::codex_rpc(state).await;
    }
    if !stop_idle_bot_codex(state).await {
        replaced = false;
    }
    replaced
}

/// Stop the Bot Codex runtime when no Bot turn uses it; the recovery loop
/// starts the installed version. Returns whether it is no longer running.
async fn stop_idle_bot_codex(state: &AppState) -> bool {
    let Some(_admission) = state.update_admission.claim_guard().await else {
        return false;
    };
    let _dispatch = state.dispatch_lock.lock().await;
    let mut client = state.app_server.lock().await;
    if !client.health().is_alive() {
        return true;
    }
    if client.has_rpc_handles() || provider_busy(state, AgentFamily::Codex, Some(false)).await {
        return false;
    }
    let _ = client.shutdown().await;
    drop(client);
    state.ingestion.request_reconcile(AgentFamily::Codex);
    true
}

fn family(id: &str) -> Option<AgentFamily> {
    match id {
        "codex" => Some(AgentFamily::Codex),
        "claude" => Some(AgentFamily::Claude),
        _ => None,
    }
}

fn report(state: &AppState, family: AgentFamily) -> serde_json::Value {
    let runtime = state.ingestion.provider_runtime_state(family);
    let installed = family == AgentFamily::Codex || state.claude.is_some();
    let detail = if runtime.incompatible {
        Some(crate::ingestion::CODEX_UNSUPPORTED_DETAIL)
    } else if !installed {
        Some("Wonder’s Claude runtime is missing. Reinstall Wonder to restore it.")
    } else {
        None
    };
    json!({
        "id": if family == AgentFamily::Codex { "codex" } else { "claude" },
        "running": runtime.alive,
        "incompatible": runtime.incompatible,
        "updatePending": runtime.update_pending,
        "detail": detail,
    })
}

/// `GET /api/v1/host/providers`: each provider's runtime in this daemon.
pub(crate) async fn status(
    State(state): State<AppState>,
    local: Option<Extension<LocalOwnerAuthority>>,
) -> Response {
    if local.is_none() {
        return StatusCode::FORBIDDEN.into_response();
    }
    Json(json!({"providers": [
        report(&state, AgentFamily::Codex),
        report(&state, AgentFamily::Claude),
    ]}))
    .into_response()
}

/// `POST /api/v1/host/providers/{id}/reconnect`: re-locate and re-verify the
/// provider, restart its runtime and report the result.
pub(crate) async fn reconnect(
    State(state): State<AppState>,
    local: Option<Extension<LocalOwnerAuthority>>,
    RoutePath(id): RoutePath<String>,
) -> Response {
    if local.is_none() {
        return StatusCode::FORBIDDEN.into_response();
    }
    let Some(family) = family(&id) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match reconnect_family(&state, family).await {
        Ok(()) => Json(report(&state, family)).into_response(),
        Err(response) => response,
    }
}

async fn reconnect_family(state: &AppState, family: AgentFamily) -> Result<(), Response> {
    let failure = |status: StatusCode, detail: &str| {
        (status, Json(json!({"detail": detail}))).into_response()
    };
    if provider_busy(state, family, None).await {
        return Err(failure(
            StatusCode::CONFLICT,
            "An agent is still working. Reconnect after it finishes.",
        ));
    }
    // One reconnect at a time, whichever device asked: a second would restart
    // the runtime the first is still verifying. The guard is released even if
    // the request is dropped.
    let Ok(_reconnecting) = state.provider_reconnect.try_lock() else {
        return Err(failure(
            StatusCode::CONFLICT,
            "A reconnect is already running. Try again when it finishes.",
        ));
    };
    let outcome = match family {
        AgentFamily::Codex => reconnect_codex(state).await,
        AgentFamily::Claude => reconnect_claude(state).await,
    };
    forget_installed(family).await;
    let _ = state.logger.record(
        if outcome.is_ok() { "info" } else { "warn" },
        "provider_reconnect",
        json!({"agentFamily": family, "ok": outcome.is_ok()}),
    );
    outcome.map_err(|detail| failure(StatusCode::SERVICE_UNAVAILABLE, &detail))
}

// ---------------------------------------------------------------------------
// Paired devices: what is installed and signed in, and Reconnect.
// ---------------------------------------------------------------------------

/// The installed provider as Settings → Providers on the Mac reads it:
/// `manage-runtime.sh status` / `claude-status`, which read the stored login
/// without starting model work and never print credentials.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Installed {
    /// signedIn, signedOut, needsSubscription, unsupported, notInstalled or unavailable.
    state: &'static str,
    version: String,
    /// "ChatGPT account", "API key", "Claude Max"...; empty when unknown.
    account: String,
}

impl Installed {
    fn from_output(code: Option<i32>, stdout: &str, family: AgentFamily) -> Self {
        let state = match code {
            Some(0) => "signedIn",
            Some(42) => "signedOut",
            Some(43) => "unsupported",
            Some(44) => "notInstalled",
            Some(45) => "needsSubscription",
            _ => "unavailable",
        };
        let line = stdout.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("");
        let mut fields = line.splitn(2, '\t');
        let mut version = fields.next().unwrap_or("").trim().to_owned();
        if family == AgentFamily::Codex {
            version = version.trim_start_matches("codex-cli ").to_owned();
        }
        let account = fields.next().unwrap_or("").trim();
        Self {
            state,
            version: version.chars().take(40).collect(),
            account: account.chars().take(60).collect(),
        }
    }
}

fn manage_runtime_script() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("WONDER_MANAGE_RUNTIME") {
        return Some(PathBuf::from(path));
    }
    let resources = std::env::current_exe()
        .ok()?
        .parent()?
        .parent()?
        .join("Resources");
    Some(resources.join("manage-runtime.sh")).filter(|p| p.is_file())
}

type InstalledCache = tokio::sync::Mutex<HashMap<&'static str, (Instant, Installed)>>;
fn installed_cache() -> &'static InstalledCache {
    static CACHE: OnceLock<InstalledCache> = OnceLock::new();
    CACHE.get_or_init(Default::default)
}

async fn forget_installed(family: AgentFamily) {
    installed_cache().lock().await.remove(id(family));
}

fn id(family: AgentFamily) -> &'static str {
    if family == AgentFamily::Codex {
        "codex"
    } else {
        "claude"
    }
}

async fn installed(family: AgentFamily, refresh: bool) -> Installed {
    // Held across the check so concurrent requests share one run.
    let mut cache = installed_cache().lock().await;
    if let Some((at, value)) = cache.get(id(family)) {
        if !refresh && at.elapsed() < INSTALLED_MAX_AGE {
            return value.clone();
        }
    }
    let value = run_status(family).await;
    cache.insert(id(family), (Instant::now(), value.clone()));
    value
}

async fn run_status(family: AgentFamily) -> Installed {
    let unavailable = Installed {
        state: "unavailable",
        version: String::new(),
        account: String::new(),
    };
    let Some(script) = manage_runtime_script() else {
        return unavailable;
    };
    let action = if family == AgentFamily::Codex {
        "status"
    } else {
        "claude-status"
    };
    let child = tokio::process::Command::new(&script)
        .arg(action)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(INSTALLED_TIMEOUT, child).await {
        Ok(Ok(output)) => Installed::from_output(
            output.status.code(),
            &String::from_utf8_lossy(&output.stdout),
            family,
        ),
        _ => unavailable,
    }
}

async fn provider_entry(state: &AppState, family: AgentFamily, refresh: bool) -> serde_json::Value {
    let installed = installed(family, refresh).await;
    let mut entry = report(state, family);
    entry["state"] = json!(installed.state);
    entry["version"] = json!(installed.version);
    entry["account"] = json!(installed.account);
    entry["working"] = json!(provider_busy(state, family, None).await);
    entry
}

#[derive(serde::Deserialize)]
pub(crate) struct ProvidersQuery {
    #[serde(default)]
    refresh: bool,
}

/// `GET /api/v1/providers`: Codex and Claude for a paired device, as the
/// Mac's Settings → Providers shows them. `refresh=true` checks again.
pub(crate) async fn owner_status(
    State(state): State<AppState>,
    Extension(_owner): Extension<OwnerAuthority>,
    Query(query): Query<ProvidersQuery>,
) -> Response {
    let (codex, claude) = tokio::join!(
        provider_entry(&state, AgentFamily::Codex, query.refresh),
        provider_entry(&state, AgentFamily::Claude, query.refresh),
    );
    Json(json!({"providers": [codex, claude]})).into_response()
}

/// `POST /api/v1/providers/{id}/reconnect`: the Mac's Reconnect, from a
/// paired device. Refused while an agent of that provider is working.
pub(crate) async fn owner_reconnect(
    State(state): State<AppState>,
    Extension(_owner): Extension<OwnerAuthority>,
    RoutePath(provider): RoutePath<String>,
) -> Response {
    let Some(family) = family(&provider) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match reconnect_family(&state, family).await {
        Ok(()) => Json(provider_entry(&state, family, true).await).into_response(),
        Err(response) => response,
    }
}

async fn reconnect_codex(state: &AppState) -> Result<(), String> {
    use_codex_install(state, locate_codex()).await;
    state.projects.stop_codex().await;
    {
        let _dispatch = state.dispatch_lock.lock().await;
        let _ = state.app_server.lock().await.shutdown().await;
    }
    state.ingestion.request_reconcile(AgentFamily::Codex);
    // Starting the Projects runtime verifies the installed Codex and records
    // whether it is supported. Bot runtimes follow through recovery.
    crate::projects::codex_rpc(state).await?;
    state
        .ingestion
        .set_update_pending(AgentFamily::Codex, false);
    Ok(())
}

async fn reconnect_claude(state: &AppState) -> Result<(), String> {
    let runtime = state
        .claude
        .as_ref()
        .ok_or("Wonder’s Claude runtime is missing. Reinstall Wonder to restore it.")?;
    let _ = runtime.client.lock().await.shutdown().await;
    state.ingestion.request_reconcile(AgentFamily::Claude);
    let deadline = tokio::time::Instant::now() + RECONNECT_TIMEOUT;
    loop {
        let current = state.ingestion.provider_runtime_state(AgentFamily::Claude);
        if current.alive && !current.recovering {
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            return Err("Claude didn’t restart. Check that it’s signed in, then try again.".into());
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;

    async fn call(
        state: &AppState,
        method: &str,
        path: &str,
        local: bool,
    ) -> (StatusCode, serde_json::Value) {
        let mut request = Request::builder().method(method).uri(path);
        if local {
            request = request.header("x-wonder-loopback-capability", &state.loopback_capability);
        }
        let response = crate::router(state.clone())
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), 65536)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null),
        )
    }

    async fn project_runtime_id(state: &AppState) -> String {
        crate::projects::codex_rpc(state)
            .await
            .unwrap()
            .health()
            .id()
            .to_owned()
    }

    // Contract: a replaced Codex install reaches every idle runtime without a
    // Wonder restart, and never interrupts a running turn.
    #[tokio::test]
    async fn stale_codex_runtimes_restart_once_idle() {
        let (_dir, state, message) = crate::projects::tests::handoff_fixture().await;
        let before = project_runtime_id(&state).await;
        state
            .store
            .update_message_delivery(
                &message.id,
                "accepted_by_codex",
                Some("thread"),
                Some("turn"),
            )
            .await
            .unwrap();
        assert!(state.app_server.lock().await.health().is_alive());
        assert!(
            !replace_stale_codex(&state).await,
            "A running Project turn keeps its runtime"
        );
        assert_eq!(project_runtime_id(&state).await, before);
        assert!(
            !state.app_server.lock().await.health().is_alive(),
            "The idle Bot runtime restarts through recovery"
        );
        state
            .store
            .update_message_delivery(&message.id, "completed", Some("thread"), Some("turn"))
            .await
            .unwrap();
        assert!(replace_stale_codex(&state).await);
        let after = crate::projects::live_rpc_for(&state, AgentFamily::Codex)
            .await
            .expect("running")
            .health();
        assert!(after.is_alive(), "The installed version starts again");
        assert_ne!(after.id(), before);
        state.projects.shutdown().await;
    }

    #[tokio::test]
    async fn providers_report_runtime_state_and_reconnect_locally() {
        let (_dir, state, message) = crate::projects::tests::handoff_fixture().await;
        let (status, _) = call(&state, "GET", "/api/v1/host/providers", false).await;
        assert_ne!(
            status,
            StatusCode::OK,
            "Only the Mac may read runtime state"
        );
        state
            .ingestion
            .set_runtime_incompatible(AgentFamily::Codex, true);
        let (status, body) = call(&state, "GET", "/api/v1/host/providers", true).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["providers"][0]["id"], "codex");
        assert_eq!(body["providers"][0]["incompatible"], true);
        assert_eq!(
            body["providers"][0]["detail"],
            crate::ingestion::CODEX_UNSUPPORTED_DETAIL
        );
        assert_eq!(body["providers"][1]["id"], "claude");

        state
            .store
            .update_message_delivery(
                &message.id,
                "accepted_by_codex",
                Some("thread"),
                Some("turn"),
            )
            .await
            .unwrap();
        let path = "/api/v1/host/providers/codex/reconnect";
        let (status, body) = call(&state, "POST", path, true).await;
        assert_eq!(status, StatusCode::CONFLICT, "{body}");
        state
            .store
            .update_message_delivery(&message.id, "completed", Some("thread"), Some("turn"))
            .await
            .unwrap();
        let (status, body) = call(&state, "POST", path, true).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body["running"], true);
        assert_eq!(
            body["incompatible"], false,
            "Reconnecting re-verifies Codex"
        );
        let (status, _) = call(
            &state,
            "POST",
            "/api/v1/host/providers/other/reconnect",
            true,
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        let (status, body) = call(
            &state,
            "POST",
            "/api/v1/host/providers/claude/reconnect",
            true,
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert!(body["detail"]
            .as_str()
            .unwrap()
            .contains("Reinstall Wonder"));
        state.projects.shutdown().await;
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    // Contract: the Mac's status script's exit codes and "version<TAB>account"
    // line become the states the phone words; nothing else is read.
    #[test]
    fn installed_status_follows_the_status_script() {
        let codex = Installed::from_output(
            Some(0),
            "noise\ncodex-cli 0.162.0\tChatGPT account\n",
            AgentFamily::Codex,
        );
        assert_eq!(
            (codex.state, codex.version.as_str(), codex.account.as_str()),
            ("signedIn", "0.162.0", "ChatGPT account")
        );
        let claude = Installed::from_output(Some(45), "2.1.0\tClaude Free\n", AgentFamily::Claude);
        assert_eq!(
            (claude.state, claude.account.as_str()),
            ("needsSubscription", "Claude Free")
        );
        for (code, expected) in [
            (Some(42), "signedOut"),
            (Some(43), "unsupported"),
            (Some(44), "notInstalled"),
            (Some(1), "unavailable"),
            (None, "unavailable"),
        ] {
            assert_eq!(
                Installed::from_output(code, "", AgentFamily::Codex).state,
                expected
            );
        }
    }

    // Contract: a paired device reads what is installed and signed in plus what
    // wonderd runs, and drives the Mac's Reconnect, which is refused while an
    // agent works. Sign-out is not offered here.
    #[tokio::test]
    async fn paired_devices_read_providers_and_reconnect() {
        let (dir, state, message) = crate::projects::tests::handoff_fixture().await;
        let script = dir.path().join("manage-runtime.sh");
        std::fs::write(
            &script,
            "#!/bin/sh\ncase \"$1\" in\n  status) printf 'codex-cli 9.9.9\\tChatGPT account\\n'; exit 0;;\n  claude-status) printf '2.0.0\\t\\n'; exit 42;;\nesac\nexit 1\n",
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::env::set_var("WONDER_MANAGE_RUNTIME", &script);
        let (status, _) = call(&state, "GET", "/api/v1/providers", false).await;
        assert_ne!(status, StatusCode::OK, "Only an owner may read providers");
        let (status, body) = call(&state, "GET", "/api/v1/providers?refresh=true", true).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        crate::tests::validate_http_contract("providersResponse", &body);
        let codex = &body["providers"][0];
        assert_eq!(codex["id"], "codex");
        assert_eq!(codex["state"], "signedIn");
        assert_eq!(codex["version"], "9.9.9");
        assert_eq!(codex["account"], "ChatGPT account");
        assert_eq!(
            codex["working"], true,
            "The fixture's message is still queued"
        );
        assert_eq!(body["providers"][1]["state"], "signedOut");

        state
            .store
            .update_message_delivery(
                &message.id,
                "accepted_by_codex",
                Some("thread"),
                Some("turn"),
            )
            .await
            .unwrap();
        let (_, body) = call(&state, "GET", "/api/v1/providers", true).await;
        assert_eq!(body["providers"][0]["working"], true);
        let path = "/api/v1/providers/codex/reconnect";
        let (status, body) = call(&state, "POST", path, true).await;
        assert_eq!(status, StatusCode::CONFLICT, "{body}");
        assert!(body["detail"].as_str().unwrap().contains("still working"));
        state
            .store
            .update_message_delivery(&message.id, "completed", Some("thread"), Some("turn"))
            .await
            .unwrap();
        let (status, body) = call(&state, "POST", path, true).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body["running"], true);
        assert_eq!(body["state"], "signedIn");
        assert_eq!(body["working"], false);
        crate::tests::validate_http_contract("providerStatus", &body);
        let (status, _) = call(&state, "POST", "/api/v1/providers/other/reconnect", true).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        let (status, _) = call(&state, "POST", "/api/v1/providers/codex/sign-out", true).await;
        assert!(status == StatusCode::NOT_FOUND || status == StatusCode::METHOD_NOT_ALLOWED);
        std::env::remove_var("WONDER_MANAGE_RUNTIME");
        state.projects.shutdown().await;
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[test]
    fn a_replaced_install_has_a_new_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        let launcher = dir.path().join("codex");
        std::fs::write(&launcher, "one").unwrap();
        let first = fingerprint(&launcher).unwrap();
        assert_eq!(fingerprint(&launcher), Some(first.clone()));
        // Sparkle swaps the bundle: a new file takes the old path.
        std::fs::remove_file(&launcher).unwrap();
        std::fs::write(&launcher, "two!").unwrap();
        assert_ne!(fingerprint(&launcher), Some(first));
        assert_eq!(fingerprint(&dir.path().join("missing")), None);
    }
}
