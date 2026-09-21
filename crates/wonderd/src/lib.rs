//! Wonder's authenticated loopback API boundary.
pub mod asr;
mod diagnostics;
#[cfg(feature = "experimental-relay")]
pub mod relay;
#[cfg(test)]
use asr::{canonical_audio_mime, sniff_audio_mime};
mod automation_schedule;
#[cfg(test)]
mod automation_tests;
#[cfg(test)]
mod bot_management_tests;
mod pairing_web;
use automation_schedule::next_automation_run;
pub mod bot_management;
mod bot_onboarding;
mod tool_media;

mod history;
use history::*;
mod sync;
use sync::stream_events;

mod account_usage;
pub mod computer_sessions;
mod computer_tools;
mod connected_apps;
pub mod dispatch;
pub mod file_access;
mod filesystem;
mod group_attachments;
mod group_collaboration;
mod groups;
pub mod ingestion;
pub mod logging;
mod permission_modes;
#[cfg(test)]
mod phone_approval_tests;
mod pm_tools;
mod project_assignments;
pub mod push;
mod questions;
mod queue;
mod subagents;
mod teaching;

use std::{
    collections::HashMap,
    path::{Path as FsPath, PathBuf},
    sync::Arc,
};

use axum::{
    body::Body,
    extract::{ws::WebSocketUpgrade, DefaultBodyLimit, Extension, Path, Query, State},
    http::{header, HeaderMap, HeaderValue, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, patch, post},
    Json, Router,
};
use base64::Engine;
use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::RwLock;
use tokio::time::{timeout, Duration};
use wonder_api::{
    pairing::ActionTranscript,
    pairing_protocol::{
        csrf_token_hash, session_expiration_deadline, session_token_hash, DevicePublicKeyJwk,
        PairingError, PairingState, NEVER_EXPIRES_AT_MS,
    },
    ClientMessageReceipt, DeliveryState, HostEventEnvelope, ResyncReason, WonderEvent,
};
use wonder_app_server::{
    build_permission_override, require_named_profile_with_scope, AppServerClient, LaunchConfig,
};
use wonder_asr::MAX_RECORDING_BYTES;
use wonder_store::{
    avatar, ComputerControlLeaseCreate, ComputerLeaseAcquireResult, ComputerSessionCreate,
    ComputerSessionState, MessageInsert, NewChannelMessage, Store, StoredBot, StoredChannel,
    StoredChannelMember, StoredComputerControlLease, StoredComputerSession, StoredConversationFile,
    StoredConversationSummary, TeachingCaptureAppendResult, TeachingEventCreate,
};

const COMPUTER_USE_DYNAMIC_TOOLS_VERSION: &str = "wonder-computer-use-v2";

#[derive(Clone)]
pub struct AppState {
    pub ingestion: ingestion::Ingestion,
    pub store: Store,
    pub logger: Arc<logging::JsonlLogger>,
    pub loopback_capability: String,
    pub host_epoch: String,
    pub started_at: String,
    pub events: tokio::sync::broadcast::Sender<HostEventEnvelope>,
    pub revocations: tokio::sync::broadcast::Sender<String>,
    pub pairing: Arc<tokio::sync::Mutex<PairingState>>,
    pub public_origin: String,
    pub public_origin_file: Option<PathBuf>,
    pub host_installation_id: String,
    pub app_server: Arc<tokio::sync::Mutex<AppServerClient>>,
    pub launch_config: Arc<tokio::sync::Mutex<LaunchConfig>>,
    pub denied_roots: Vec<String>,
    /// Host folders whose files may be copied into a conversation after the
    /// owner explicitly clicks a local link. Bot workspaces are always
    /// readable and do not need to be listed here.
    pub linked_file_roots: Vec<PathBuf>,
    pub dispatch_lock: Arc<tokio::sync::Mutex<()>>,
    pub channel_worker_slots: Arc<tokio::sync::Semaphore>,
    pub approval_lock: Arc<tokio::sync::Mutex<()>>,
    pub bots_root: String,
    pub bot_home: String,
    pub permission_profile: String,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub runtime_catalog: Arc<RwLock<RuntimeCatalog>>,
    pub asr_service: Arc<asr::AsrService>,
    pub asr_slots: Arc<tokio::sync::Semaphore>,
    pub asr_rate_limits: Arc<tokio::sync::Mutex<HashMap<String, Vec<u64>>>>,
    pub computer_use_enabled: bool,
    pub computer_use_bin: Option<PathBuf>,
    pub computer_supervisor: Arc<computer_sessions::ComputerSessionSupervisor>,
}

#[derive(Clone, Debug, Default)]
pub struct RuntimeCatalog {
    pub models: Vec<ModelOption>,
    pub permission_profiles_by_cwd: HashMap<String, Vec<PermissionProfileOption>>,
    pub allowed_approval_policies: Vec<String>,
    pub allowed_approval_reviewers: Vec<String>,
    pub allowed_permission_profiles: HashMap<String, bool>,
    pub approval_policies_restricted: bool,
    pub approval_reviewers_restricted: bool,
    pub permission_profiles_restricted: bool,
    pub auto_review_required_on_models: Option<Vec<String>>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelOption {
    pub id: String,
    pub display_name: String,
    pub description: Option<String>,
    pub model_specialty: Option<String>,
    pub hidden: bool,
    pub reasoning_efforts: Vec<ChoiceOption>,
    pub default_reasoning_effort: Option<String>,
    pub service_tiers: Vec<ChoiceOption>,
    pub default_service_tier: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChoiceOption {
    pub id: String,
    pub label: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionProfileOption {
    pub id: String,
    pub description: Option<String>,
    pub allowed: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeAppSummary {
    id: String,
    name: String,
    description: Option<String>,
    category: Option<String>,
    enabled: bool,
    accessible: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeSkillSummary {
    name: String,
    description: String,
    enabled: bool,
    plugin_id: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeMcpServerSummary {
    name: String,
    plugin_id: Option<String>,
    auth_status: String,
    runtime_status: Option<String>,
    tool_count: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeCapabilitiesResponse {
    apps: Vec<RuntimeAppSummary>,
    skills: Vec<RuntimeSkillSummary>,
    mcp_servers: Vec<RuntimeMcpServerSummary>,
    warnings: Vec<String>,
    refreshed_at: String,
}

impl RuntimeCatalog {
    pub fn apply_models_page(&mut self, result: &serde_json::Value) {
        let Some(data) = result.get("data").and_then(serde_json::Value::as_array) else {
            return;
        };
        for model in data {
            let Some(id) = model
                .get("id")
                .or_else(|| model.get("model"))
                .and_then(serde_json::Value::as_str)
            else {
                continue;
            };
            let reasoning_efforts = model
                .get("supportedReasoningEfforts")
                .and_then(serde_json::Value::as_array)
                .map(|values| values.iter().filter_map(choice_option).collect())
                .unwrap_or_default();
            let mut service_tiers: Vec<ChoiceOption> = model
                .get("serviceTiers")
                .and_then(serde_json::Value::as_array)
                .map(|values| values.iter().filter_map(choice_option).collect())
                .unwrap_or_default();
            if !service_tiers
                .iter()
                .any(|option: &ChoiceOption| option.id == "default")
            {
                service_tiers.insert(
                    0,
                    ChoiceOption {
                        id: "default".into(),
                        label: "Standard".into(),
                        description: Some("Standard speed, standard usage".into()),
                    },
                );
            }
            let option = ModelOption {
                id: id.to_owned(),
                display_name: model
                    .get("displayName")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or(id)
                    .to_owned(),
                description: model
                    .get("description")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
                model_specialty: model
                    .get("modelSpecialty")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
                hidden: model
                    .get("hidden")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
                reasoning_efforts,
                default_reasoning_effort: model
                    .get("defaultReasoningEffort")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
                service_tiers,
                default_service_tier: model
                    .get("defaultServiceTier")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
            };
            self.models.retain(|existing| existing.id != option.id);
            self.models.push(option);
        }
    }

    pub fn apply_requirements(&mut self, result: &serde_json::Value) {
        let Some(requirements) = result.get("requirements") else {
            return;
        };
        let policies = requirements.get("allowedApprovalPolicies");
        self.approval_policies_restricted = policies.is_some_and(|value| !value.is_null());
        self.allowed_approval_policies = policies
            .and_then(serde_json::Value::as_array)
            .map(|values| values.iter().filter_map(approval_policy_name).collect())
            .unwrap_or_default();
        let reviewers = requirements.get("allowedApprovalsReviewers");
        self.approval_reviewers_restricted = reviewers.is_some_and(|value| !value.is_null());
        self.allowed_approval_reviewers = reviewers
            .and_then(serde_json::Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(serde_json::Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        let profiles = requirements.get("allowedPermissionProfiles");
        self.permission_profiles_restricted = profiles.is_some_and(|value| !value.is_null());
        self.allowed_permission_profiles = profiles
            .and_then(serde_json::Value::as_object)
            .map(|values| {
                values
                    .iter()
                    .filter_map(|(id, value)| value.as_bool().map(|allowed| (id.clone(), allowed)))
                    .collect()
            })
            .unwrap_or_default();
        self.auto_review_required_on_models = requirements
            .get("autoReview")
            .and_then(|value| value.as_object())
            .and_then(|value| value.get("requiredOnModels"))
            .and_then(|value| value.as_array())
            .map(|values| {
                values
                    .iter()
                    .filter_map(serde_json::Value::as_str)
                    .map(str::to_owned)
                    .collect()
            });
    }

    pub fn apply_permission_profiles(&mut self, cwd: &str, result: &serde_json::Value) {
        let profiles = result
            .get("data")
            .and_then(serde_json::Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(|profile| {
                        let id = profile
                            .get("id")
                            .or_else(|| profile.get("name"))
                            .and_then(serde_json::Value::as_str)?;
                        Some(PermissionProfileOption {
                            id: id.to_owned(),
                            description: profile
                                .get("description")
                                .and_then(serde_json::Value::as_str)
                                .map(str::to_owned),
                            allowed: profile
                                .get("allowed")
                                .and_then(serde_json::Value::as_bool)
                                .unwrap_or(false),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        self.permission_profiles_by_cwd
            .insert(cwd.to_owned(), profiles);
    }

    pub fn profiles_for(&self, cwd: &str) -> &[PermissionProfileOption] {
        self.permission_profiles_by_cwd
            .get(cwd)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }
}

fn choice_option(value: &serde_json::Value) -> Option<ChoiceOption> {
    if let Some(id) = value.as_str() {
        return Some(ChoiceOption {
            id: id.to_owned(),
            label: id.to_owned(),
            description: None,
        });
    }
    let id = value
        .get("id")
        .or_else(|| value.get("reasoningEffort"))
        .or_else(|| value.get("name"))
        .and_then(serde_json::Value::as_str)?;
    Some(ChoiceOption {
        id: id.to_owned(),
        label: value
            .get("name")
            .or_else(|| value.get("displayName"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or(id)
            .to_owned(),
        description: value
            .get("description")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
    })
}

fn approval_policy_name(value: &serde_json::Value) -> Option<String> {
    value.as_str().map(str::to_owned).or_else(|| {
        value
            .get("type")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
    })
}

const MAX_COMPUTER_USE_LINE_BYTES: usize = 16 * 1024 * 1024;
const MAX_ATTACHMENT_BYTES: usize = 8 * 1024 * 1024;
const MAX_ATTACHMENT_REQUEST_BYTES: usize = 12 * 1024 * 1024;
const MAX_WORKSPACE_ARTIFACT_BYTES: usize = MAX_ATTACHMENT_BYTES;
pub const CHANNEL_WORKER_CONCURRENCY: usize = 4;

#[derive(Clone, Debug)]
struct AuthenticatedDevice {
    device_id: String,
    session_binding: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignedActionFields {
    action_nonce: Option<String>,
    issued_at_ms: Option<u64>,
    signature: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResetWorkspaceRequest {
    keep_device_id: Option<String>,
    #[serde(flatten)]
    action: SignedActionFields,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ResetWorkspaceSummary {
    preserved_device_id: String,
    revoked_device_count: usize,
    deleted_bot_count: usize,
    deleted_workspace_count: usize,
}

fn action_body_sha256(value: &serde_json::Value) -> String {
    hex::encode(Sha256::digest(
        serde_json::to_string(value)
            .unwrap_or_else(|_| "null".into())
            .as_bytes(),
    ))
}

async fn verify_signed_action(
    state: &AppState,
    device: &AuthenticatedDevice,
    action: &str,
    target: &str,
    body_sha256: &str,
    fields: &SignedActionFields,
    expected_state: &str,
) -> Result<(), &'static str> {
    let Some(action_nonce) = fields
        .action_nonce
        .as_deref()
        .filter(|value| !value.is_empty())
    else {
        return Err("signed action fields are required");
    };
    let Some(issued_at_ms) = fields.issued_at_ms else {
        return Err("signed action fields are required");
    };
    let Some(signature) = fields
        .signature
        .as_deref()
        .filter(|value| !value.is_empty())
    else {
        return Err("signed action fields are required");
    };
    if issued_at_ms.abs_diff(now_ms()) > 60_000 {
        return Err("signed action is stale");
    }
    let transcript = ActionTranscript {
        action,
        target,
        body_sha256,
        action_nonce,
        session_binding: &device.session_binding,
        device_id: &device.device_id,
        host_installation_id: &state.host_installation_id,
        issued_at_ms,
        expected_state,
    };
    if state
        .pairing
        .lock()
        .await
        .verify_action_signature(&device.device_id, &transcript, signature)
        .is_err()
    {
        return Err("invalid action signature");
    }
    if !state
        .store
        .claim_action_nonce(action_nonce, &now_ms().to_string())
        .await
        .map_err(|_| "action replay state unavailable")?
    {
        return Err("signed action was already used");
    }
    Ok(())
}

#[derive(Clone, Copy, Debug)]
struct OwnerAuthority;

#[derive(Clone, Copy, Debug)]
struct LocalOwnerAuthority;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendMessageRequest {
    #[serde(default)]
    pub group_routing: Option<group_collaboration::ModelSettings>,
    pub device_id: String,
    pub client_message_id: String,
    pub body: String,
    #[serde(default)]
    pub attachment_ids: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ChannelRoute {
    Broadcast,
    Direct(String),
}

fn channel_handle_char(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-')
}

fn bot_handle(name: &str) -> String {
    let mut handle = String::new();
    let mut pending_separator = false;
    for character in name.chars() {
        if character.is_ascii_alphanumeric() {
            if pending_separator && !handle.is_empty() {
                handle.push('-');
            }
            handle.push(character.to_ascii_lowercase());
            pending_separator = false;
        } else if !handle.is_empty() {
            pending_separator = true;
        }
    }
    handle
}

fn resolve_channel_route(
    body: &str,
    members: &[StoredChannelMember],
) -> Result<ChannelRoute, String> {
    let bytes = body.as_bytes();
    let mut mentions = Vec::new();
    let mut index = 0;
    let mut in_fenced_code = false;
    let mut in_inline_code = false;
    while index < bytes.len() {
        if bytes[index..].starts_with(b"```") {
            in_fenced_code = !in_fenced_code;
            index += 3;
            continue;
        }
        if !in_fenced_code && bytes[index] == b'`' {
            in_inline_code = !in_inline_code;
            index += 1;
            continue;
        }
        if !in_fenced_code
            && !in_inline_code
            && bytes[index] == b'@'
            && (index == 0 || !channel_handle_char(bytes[index - 1]))
        {
            let start = index + 1;
            let mut end = start;
            while end < bytes.len() && channel_handle_char(bytes[end]) {
                end += 1;
            }
            if end > start {
                let mention = body[start..end].to_ascii_lowercase();
                if !mentions.contains(&mention) {
                    mentions.push(mention);
                }
            }
            index = end;
            continue;
        }
        index += 1;
    }

    if mentions.is_empty() {
        return Ok(ChannelRoute::Broadcast);
    }
    if mentions.len() > 1 {
        return Err("Address only one Bot at a time in a Group Chat.".into());
    }
    let mention = &mentions[0];
    let matching_members = members
        .iter()
        .filter(|member| bot_handle(&member.bot_name) == *mention)
        .collect::<Vec<_>>();
    match matching_members.as_slice() {
        [member] => Ok(ChannelRoute::Direct(member.bot_id.clone())),
        [] => Err(format!(
            "I couldn't find an active Group Chat Bot named @{mention}."
        )),
        _ => Err(format!(
            "The @{mention} Bot handle is ambiguous in this Group Chat."
        )),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SteerTurnRequest {
    pub device_id: String,
    pub client_message_id: String,
    pub body: String,
    pub expected_turn_id: String,
    #[serde(default)]
    pub attachment_ids: Vec<String>,
}

#[allow(dead_code)]
fn steer_turn_params(
    thread_id: &str,
    expected_turn_id: &str,
    client_message_id: &str,
    body: &str,
) -> serde_json::Value {
    serde_json::json!({
        "threadId": thread_id,
        "expectedTurnId": expected_turn_id,
        "clientUserMessageId": client_message_id,
        "input": [{ "type": "text", "text": body }],
    })
}

fn steer_turn_params_with_attachments(
    thread_id: &str,
    expected_turn_id: &str,
    client_message_id: &str,
    input: Vec<serde_json::Value>,
) -> serde_json::Value {
    serde_json::json!({
        "threadId": thread_id,
        "expectedTurnId": expected_turn_id,
        "clientUserMessageId": client_message_id,
        "input": input,
    })
}

fn turn_input(
    body: &str,
    workspace: &str,
    attachments: &[StoredConversationFile],
) -> Vec<serde_json::Value> {
    let mut input = vec![serde_json::json!({ "type": "text", "text": body })];
    for attachment in attachments {
        let Some(relative_path) = attachment.relative_path.as_deref() else {
            continue;
        };
        let path = FsPath::new(workspace).join(relative_path);
        let Some(path) = path.to_str() else {
            continue;
        };
        let mime_type = attachment.mime_type.as_deref().unwrap_or_default();
        if mime_type.starts_with("image/") {
            input.push(serde_json::json!({ "type": "localImage", "path": path }));
        } else if mime_type.starts_with("audio/") {
            input.push(serde_json::json!({ "type": "localAudio", "path": path }));
        } else {
            input.push(serde_json::json!({
                "type": "text",
                "text": format!("Attached file `{}` is available at `{}`.", attachment.name, path),
            }));
        }
    }
    input
}

fn valid_attachment_ids(attachment_ids: &[String]) -> bool {
    if attachment_ids.len() > 32
        || attachment_ids
            .iter()
            .any(|id| id.is_empty() || uuid::Uuid::parse_str(id).is_err())
    {
        return false;
    }
    let mut sorted = attachment_ids.to_vec();
    sorted.sort();
    sorted.windows(2).all(|pair| pair[0] != pair[1])
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostStatus {
    pub host_name: String,
    pub api_version: &'static str,
    pub host_epoch: String,
    pub host_installation_id: String,
    pub state: &'static str,
    pub codex_transport: &'static str,
    pub started_at: String,
    pub public_origin: Option<String>,
    pub execution: ingestion::Readiness,
}

async fn no_store_signaling(request: Request<Body>, next: Next) -> Response {
    let mut response = next.run(request).await;
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

pub fn router(state: AppState) -> Router {
    let signaling_routes = Router::new()
        .route(
            "/api/v1/computer/sessions/{id}/signaling",
            post(computer_sessions::signal_poll),
        )
        .route(
            "/api/v1/computer/sessions/{id}/signaling/answer",
            post(computer_sessions::signal_answer),
        )
        .route(
            "/api/v1/computer/sessions/{id}/signaling/candidate",
            post(computer_sessions::signal_candidate),
        )
        .route(
            "/api/v1/computer/sessions/{id}/signaling/close",
            post(computer_sessions::signal_close),
        )
        .layer(DefaultBodyLimit::max(96 * 1024))
        .layer(middleware::from_fn(no_store_signaling));

    Router::new()
        .route(
            "/api/v1/diagnostics/batches",
            post(diagnostics::ingest).layer(DefaultBodyLimit::max(diagnostics::MAX_BATCH)),
        )
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/api/v1/host/status", get(host_status))
        .route("/api/v1/push/config", get(push::config))
        .route("/api/v1/push/registration", post(push::register))
        .route("/api/v1/push/revoke", post(push::revoke))
        .route("/api/v1/push/presence", post(push::presence))
        .route("/api/v1/push/routes/{route}", get(push::route))
        .route("/api/v1/account/usage", get(account_usage::read))
        .route("/api/v1/runtime/capabilities", get(runtime_capabilities))
        .route("/api/v1/computer/sessions", post(computer_sessions::create))
        .route(
            "/api/v1/computer/sessions/{id}",
            get(computer_sessions::read).delete(computer_sessions::end),
        )
        .route(
            "/api/v1/computer/sessions/{id}/admission",
            post(computer_sessions::admit),
        )
        .merge(signaling_routes)
        .route(
            "/api/v1/computer/sessions/{id}/control/acquire",
            post(computer_sessions::acquire_control),
        )
        .route(
            "/api/v1/computer/sessions/{id}/control/heartbeat",
            post(computer_sessions::heartbeat_control),
        )
        .route(
            "/api/v1/computer/sessions/{id}/control/input",
            post(computer_sessions::input_control),
        )
        .route(
            "/api/v1/computer/sessions/{id}/control/release",
            post(computer_sessions::release_control),
        )
        .route(
            "/api/v1/computer/sessions/{id}/control/resume",
            post(computer_sessions::resume_control),
        )
        .route("/api/v1/connected-apps", get(connected_apps::list))
        .route("/api/v1/teaching/capability", get(teaching::capability))
        .route(
            "/api/v1/bots/{bot_id}/teaching/sessions",
            post(teaching::start),
        )
        .route(
            "/api/v1/bots/{bot_id}/teaching/sessions/{session_id}",
            get(teaching::read),
        )
        .route(
            "/api/v1/bots/{bot_id}/teaching/sessions/{session_id}/stop",
            post(teaching::stop),
        )
        .route(
            "/api/v1/bots/{bot_id}/teaching/sessions/{session_id}/cancel",
            post(teaching::cancel),
        )
        .route(
            "/api/v1/bots/{bot_id}/teaching/sessions/{session_id}/review",
            post(teaching::review),
        )
        .route(
            "/api/v1/bots/{bot_id}/teaching/sessions/{session_id}/save-version",
            post(teaching::save_version),
        )
        .route("/api/v1/bots/{bot_id}/skills", get(teaching::list_skills))
        .route(
            "/api/v1/bots/{bot_id}/skills/{skill_id}/versions/{version}/fixture-tests",
            post(teaching::run_fixture),
        )
        .route(
            "/api/v1/bots/{bot_id}/skills/{skill_id}/fixture-tests/{request_id}",
            get(teaching::read_fixture),
        )
        .route(
            "/api/v1/bots/{bot_id}/skills/{skill_id}",
            get(teaching::get_skill).delete(teaching::archive_skill),
        )
        .route(
            "/api/v1/bots/{bot_id}/skills/{skill_id}/activate",
            post(teaching::activate_skill_version),
        )
        .route(
            "/api/v1/bots",
            get(list_bots).post(bot_management::create_with_avatar),
        )
        .route("/api/v1/bots/new", post(bot_onboarding::create))
        .route(
            "/api/v1/group-chats/{id}/retry",
            post(group_collaboration::retry),
        )
        .route(
            "/api/v1/group-chats/{id}/stop",
            post(group_collaboration::stop),
        )
        .route(
            "/api/v1/group-chats/propose",
            post(group_collaboration::propose),
        )
        .route("/api/v1/group-chats/new", post(group_collaboration::create))
        .route(
            "/api/v1/group-chats/{id}/collaboration",
            get(group_collaboration::detail).put(group_collaboration::configure),
        )
        .route("/api/v1/bot-options", get(bot_management::options))
        .route("/api/v1/filesystem", get(filesystem::browse))
        .route(
            "/api/v1/conversations/{conversation_id}/workspace/roots",
            get(filesystem::workspace_roots),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/workspace/directory",
            get(filesystem::workspace_directory),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/workspace/file",
            get(filesystem::workspace_file),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/workspace/git/status",
            get(filesystem::workspace_git_status),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/workspace/git/diff",
            get(filesystem::workspace_git_diff),
        )
        .route(
            "/api/v1/bots/{bot_id}/file-access/requests",
            get(bot_management::file_requests).post(bot_management::request_files),
        )
        .route(
            "/api/v1/bots/{bot_id}/file-access/requests/{request_id}",
            post(bot_management::resolve_files),
        )
        .route(
            "/api/v1/bots/{bot_id}/file-access",
            get(file_access::get).put(file_access::update),
        )
        .route(
            "/api/v1/bots/{bot_id}",
            get(bot_get_endpoint)
                .patch(bot_update_endpoint)
                .delete(bot_delete_endpoint),
        )
        .route("/api/v1/bots/{bot_id}/archive", post(bot_archive_endpoint))
        .route(
            "/api/v1/bots/{bot_id}/unarchive",
            post(bot_unarchive_endpoint),
        )
        .route(
            "/api/v1/conversations",
            get(list_conversations).post(create_conversation),
        )
        .route("/api/v1/search", get(search_endpoint))
        .route(
            "/api/v1/conversations/{conversation_id}/subagents",
            get(subagents::list),
        )
        .route(
            "/api/v1/groups/{group_id}/assignment-projects",
            get(project_assignments::projects),
        )
        .route(
            "/api/v1/groups/{group_id}/assignments",
            get(project_assignments::list).post(project_assignments::create),
        )
        .route(
            "/api/v1/assignments/{id}",
            get(project_assignments::inspect),
        )
        .route(
            "/api/v1/assignments/{id}/review",
            post(project_assignments::review),
        )
        .route(
            "/api/v1/assignments/{id}/integrate",
            post(project_assignments::integrate),
        )
        .route(
            "/api/v1/assignments/{id}/cancel",
            post(project_assignments::cancel),
        )
        .route("/api/v1/channels", get(list_channels).post(create_channel))
        .route(
            "/api/v1/group-chats",
            get(list_channels).post(create_channel),
        )
        .route(
            "/api/v1/channels/{channel_id}",
            get(get_channel)
                .patch(update_channel)
                .delete(delete_channel),
        )
        .route(
            "/api/v1/group-chats/{channel_id}/read",
            post(acknowledge_group_read),
        )
        .route(
            "/api/v1/group-chats/{channel_id}",
            get(get_channel)
                .patch(update_channel)
                .delete(delete_channel),
        )
        .route(
            "/api/v1/channels/{channel_id}/members",
            get(list_channel_members).post(add_channel_member),
        )
        .route(
            "/api/v1/group-chats/{channel_id}/members",
            get(list_channel_members).post(add_channel_member),
        )
        .route(
            "/api/v1/channels/{channel_id}/members/{bot_id}",
            delete(remove_channel_member),
        )
        .route(
            "/api/v1/group-chats/{channel_id}/members/{bot_id}",
            delete(remove_channel_member),
        )
        .route(
            "/api/v1/channels/{channel_id}/messages",
            post(send_channel_message),
        )
        .route(
            "/api/v1/group-chats/{channel_id}/messages",
            post(send_channel_message),
        )
        .route(
            "/api/v1/automations",
            get(list_automations).post(create_automation),
        )
        .route("/api/v1/automations/preview", post(preview_automation))
        .route(
            "/api/v1/automations/{automation_id}",
            patch(update_automation).delete(delete_automation),
        )
        .route(
            "/api/v1/automations/{automation_id}/run",
            post(run_automation_now),
        )
        .route(
            "/api/v1/automations/{automation_id}/runs",
            get(list_automation_runs),
        )
        .route(
            "/api/v1/asr/transcriptions",
            post(asr::create_transcription).layer(DefaultBodyLimit::max(MAX_RECORDING_BYTES)),
        )
        .route(
            "/api/v1/asr/transcriptions/by-request/{request_id}",
            delete(asr::cancel_transcription_request),
        )
        .route(
            "/api/v1/asr/transcriptions/{transcription_id}",
            get(asr::get_transcription).delete(asr::cancel_transcription),
        )
        .route(
            "/api/v1/asr/transcriptions/{transcription_id}/retry",
            post(asr::retry_transcription),
        )
        .route("/api/v1/asr/models", get(asr::models))
        .route(
            "/api/v1/asr/models/{model_id}/download",
            post(asr::download_model).delete(asr::cancel_download),
        )
        .route(
            "/api/v1/asr/models/{model_id}/select",
            post(asr::select_model),
        )
        .route("/api/v1/asr/models/{model_id}", delete(asr::delete_model))
        .route("/api/v1/events", get(events_socket))
        .route("/api/v1/sync/checkpoint", get(sync::checkpoint))
        .route("/api/v1/events/challenge", get(event_challenge))
        .route("/api/v1/pairing/offers", post(create_pairing_offer))
        .route("/api/v1/pairing/pending", get(list_pending_enrollments))
        .route(
            "/api/v1/pairing/pending/{device_id}/confirm",
            post(confirm_enrollment),
        )
        .route(
            "/api/v1/pairing/pending/{device_id}/reject",
            post(reject_enrollment),
        )
        .route("/api/v1/pairing/code", post(claim_pairing_code))
        .route(
            "/api/v1/pairing/offers/{offer_id}/cancel",
            post(cancel_pairing_offer),
        )
        .route("/api/v1/pairing/claim", post(claim_pairing_offer))
        .route(
            "/api/v1/pairing/session/refresh-challenge",
            post(create_session_refresh_challenge),
        )
        .route("/api/v1/pairing/session", post(create_session))
        .route("/api/v1/devices", get(list_devices))
        .route("/api/v1/devices/{device_id}", patch(rename_device))
        .route("/api/v1/devices/{device_id}/revoke", post(revoke_device))
        .route("/api/v1/devices/{device_id}/forget", post(forget_device))
        .route("/api/v1/workspace/reset", post(reset_workspace))
        .route(
            "/api/v1/conversations/{conversation_id}/queue",
            get(queue::list).post(queue::reorder),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/queue/{message_id}",
            post(queue::edit),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/questions",
            get(questions::list),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/questions/{question_id}",
            post(questions::answer),
        )
        .route("/api/v1/approvals", get(list_approvals))
        .route(
            "/api/v1/approvals/{approval_id}/resolve",
            post(resolve_approval),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/messages",
            post(send_message),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/turns/{turn_id}/steer",
            post(steer_turn),
        )
        .route(
            "/api/v1/conversations/{conversation_id}",
            get(conversation_snapshot).patch(update_conversation),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/history",
            get(conversation_snapshot),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/history/refresh",
            get(history_refresh_status).post(refresh_history),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/composer-options",
            get(conversation_composer_options),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/settings",
            get(conversation_settings).patch(update_conversation_settings),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/files",
            get(conversation_files)
                .post(upload_conversation_file)
                .layer(DefaultBodyLimit::max(MAX_ATTACHMENT_REQUEST_BYTES)),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/files/resolve",
            post(resolve_conversation_file),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/files/{file_id}",
            get(conversation_file),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/turns/{turn_id}/interrupt",
            post(interrupt_turn),
        )
        .route("/api/v1/messages/{message_id}/retry", post(retry_message))
        // Only native pairing instructions remain on browser-facing routes.
        // API and WebSocket authentication stay in the shared middleware.
        .route("/", get(pairing_web::root))
        .route("/pair", get(pairing_web::page))
        .route("/pair/style.css", get(pairing_web::style))
        .route("/sw.js", get(pairing_web::retire_worker))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            require_loopback_capability,
        ))
        .with_state(state)
}

pub async fn publish_event(
    state: &AppState,
    event: WonderEvent,
) -> Result<HostEventEnvelope, sqlx::Error> {
    publish_event_with_context(state, event, EventContext::default()).await
}

#[derive(Default)]
struct EventContext {
    request_id: Option<String>,
    conversation_id: Option<String>,
    message_id: Option<String>,
    thread_id: Option<String>,
    turn_id: Option<String>,
    item_id: Option<String>,
    approval_id: Option<String>,
}

async fn publish_event_with_context(
    state: &AppState,
    event: WonderEvent,
    context: EventContext,
) -> Result<HostEventEnvelope, sqlx::Error> {
    let mut envelope = HostEventEnvelope {
        event_id: uuid::Uuid::new_v4().to_string(),
        host_epoch: state.host_epoch.clone(),
        sequence: 0,
        occurred_at: time::OffsetDateTime::now_utc()
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_else(|_| state.started_at.clone()),
        request_id: context.request_id,
        device_id: None,
        conversation_id: context.conversation_id,
        message_id: context.message_id,
        thread_id: context.thread_id,
        turn_id: context.turn_id,
        item_id: context.item_id,
        approval_id: context.approval_id,
        event,
    };
    state.store.commit_event(&mut envelope).await?;
    let _ = state.events.send(envelope.clone());
    Ok(envelope)
}

pub async fn publish_app_server_notification(state: &AppState, notification: serde_json::Value) {
    // App Server can emit notifications immediately after turn/start. Keep
    // projection behind the dispatch/lifecycle lock so the turn id is stored
    // before an assistant delta is associated with a Wonder message.
    let _notification_guard = state.dispatch_lock.lock().await;
    let params = notification.get("params").cloned().unwrap_or_default();
    let thread_id = notification_thread_id(&params);
    let turn_id = notification_turn_id(&params);
    let mapped = match (thread_id.as_deref(), turn_id.as_deref()) {
        (Some(thread_id), Some(turn_id)) => state
            .store
            .message_for_codex_thread_and_turn(thread_id, turn_id)
            .await
            .ok()
            .flatten(),
        (_, Some(turn_id)) => state
            .store
            .message_for_codex_turn(turn_id)
            .await
            .ok()
            .flatten(),
        (None, None) => None,
        (Some(_), None) => None,
    };
    let applied = process_app_server_notification(state, notification, true).await;
    if applied && mapped.is_some() {
        if let (Some(thread_id), Some(turn_id)) = (thread_id.as_deref(), turn_id.as_deref()) {
            drain_pending_app_server_notifications(state, thread_id, turn_id).await;
        }
    }
}

fn notification_thread_id(params: &serde_json::Value) -> Option<String> {
    let item = params.get("item");
    string_field(params, "threadId")
        .or_else(|| item.and_then(|item| string_field(item, "threadId")))
}

fn notification_turn_id(params: &serde_json::Value) -> Option<String> {
    let item = params.get("item");
    string_field(params, "turnId")
        .or_else(|| {
            params
                .get("turn")
                .and_then(|turn| turn.get("id"))
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned)
        })
        .or_else(|| item.and_then(|item| string_field(item, "turnId")))
}

#[allow(clippy::too_many_arguments)]
async fn enqueue_pending_app_server_notification(
    state: &AppState,
    method: &str,
    notification: &serde_json::Value,
    params: &serde_json::Value,
    thread_id: Option<&str>,
    turn_id: Option<&str>,
    item_id: Option<&str>,
    identity_key: Option<&str>,
) -> Result<bool, sqlx::Error> {
    let Ok(params_json) = serde_json::to_string(params) else {
        return Err(sqlx::Error::Protocol(
            "failed to serialize App Server notification parameters".into(),
        ));
    };
    state
        .store
        .enqueue_pending_app_server_notification(
            &uuid::Uuid::new_v4().to_string(),
            identity_key,
            method,
            thread_id,
            turn_id,
            item_id,
            &notification.to_string(),
            &params_json,
            &now_ms().to_string(),
        )
        .await
}

#[allow(clippy::too_many_arguments)]
async fn fail_app_server_notification(
    state: &AppState,
    method: &str,
    notification: &serde_json::Value,
    params: &serde_json::Value,
    thread_id: Option<&str>,
    turn_id: Option<&str>,
    item_id: Option<&str>,
    notification_key: Option<&str>,
    queue_for_retry: bool,
) -> bool {
    if queue_for_retry {
        // Preserve the complete envelope. If this enqueue itself fails, the
        // receipt is still released below so the App Server can retry.
        let _ = enqueue_pending_app_server_notification(
            state,
            method,
            notification,
            params,
            thread_id,
            turn_id,
            item_id,
            notification_key,
        )
        .await;
    }
    if let Some(notification_key) = notification_key {
        let _ = state
            .store
            .release_app_server_notification(notification_key)
            .await;
    }
    false
}

#[allow(clippy::collapsible_if)]
async fn process_app_server_notification(
    state: &AppState,
    notification: serde_json::Value,
    queue_failed_assistant: bool,
) -> bool {
    let Some(method) = notification
        .get("method")
        .and_then(serde_json::Value::as_str)
    else {
        return true;
    };
    let mut params = notification.get("params").cloned().unwrap_or_default();
    if let Some(runtime_id) = notification.get("_wonderRuntimeId") {
        if params.is_object() {
            params["_wonderRuntimeId"] = runtime_id.clone();
            if let Some(id) = notification
                .get("id")
                .or_else(|| notification.get("params").and_then(|p| p.get("requestId")))
            {
                params["_wonderRequestId"] = id.clone();
            }
        }
    }
    let item = params.get("item");
    let thread_id = notification_thread_id(&params);
    let turn_id = string_field(&params, "turnId")
        .or_else(|| {
            params
                .get("turn")
                .and_then(|turn| turn.get("id"))
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned)
        })
        .or_else(|| item.and_then(|item| string_field(item, "turnId")));
    let item_id = string_field(&params, "itemId").or_else(|| {
        params
            .get("item")
            .and_then(|item| item.get("id"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
    });
    let message = match (thread_id.as_deref(), turn_id.as_deref()) {
        (Some(thread_id), Some(turn_id)) => {
            state
                .store
                .message_for_codex_thread_and_turn(thread_id, turn_id)
                .await
        }
        (_, Some(turn_id)) => state.store.message_for_codex_turn(turn_id).await,
        (None, None) => Ok(None),
        (Some(_), None) => Ok(None),
    };
    let message = match message {
        Ok(message) => message,
        Err(_) => return false,
    };
    let mapped_child = match message.as_ref() {
        Some(message) => match state
            .store
            .subagent_ownership_for_conversation(&message.conversation_id)
            .await
        {
            Ok(child) => child.is_some(),
            Err(_) => return false,
        },
        None => false,
    };
    let has_child_seed = params.get("item").is_some_and(|item| {
        matches!(
            item.get("type").and_then(serde_json::Value::as_str),
            Some("subAgentActivity" | "collabAgentToolCall")
        ) && (item
            .get("agentThreadId")
            .and_then(serde_json::Value::as_str)
            .is_some()
            || item
                .get("receiverThreadIds")
                .and_then(serde_json::Value::as_array)
                .is_some_and(|ids| !ids.is_empty()))
    });
    // A receipt already proves the ordinary parent conversation. Runtime
    // thread discovery is needed only for a mapped child, a structured child
    // seed, or a child notification that arrived before its first receipt.
    let ownership = if message.is_some() && !mapped_child && !has_child_seed {
        None
    } else {
        match subagents::observe(state, &notification).await {
            Ok(ownership) => ownership,
            Err(_) => return false,
        }
    };
    let conversation_id = message
        .as_ref()
        .map(|message| message.conversation_id.clone())
        .or_else(|| {
            ownership
                .as_ref()
                .map(|ownership| ownership.conversation_id.clone())
        });
    if method == "item/tool/call"
        && matches!(
            params.get("tool").and_then(serde_json::Value::as_str),
            Some(
                bot_onboarding::TOOL
                    | bot_onboarding::QUESTION_TOOL
                    | bot_onboarding::WORKSPACE_TOOL
                    | "wonder_update_group"
                    | "wonder_group_handoff"
            )
        )
    {
        return bot_onboarding::handle(state, &notification, &params, message.as_ref()).await;
    }
    if method == "item/tool/call"
        && params
            .get("tool")
            .and_then(serde_json::Value::as_str)
            .is_some_and(pm_tools::registered)
    {
        return pm_tools::handle(state, &notification, &params, message.as_ref()).await;
    }
    if method == "item/tool/call"
        && params.get("tool").and_then(serde_json::Value::as_str) == Some(computer_tools::TOOL)
    {
        if let Some(handled) = computer_tools::route(state, &params).await {
            return handled;
        }
    }
    let is_message_bound_notification = method == "turn/completed"
        || method == "item/agentMessage/delta"
        || method == "item/completed"
        || method == "item/fileChange/patchUpdated";
    // A notification can race the dispatch response that stores the turn id.
    // Keep it durably until the turn is mapped to a Wonder conversation.
    if is_message_bound_notification && message.is_none() && ownership.is_none() {
        let identity_key = app_server_notification_key(method, &notification, &params);
        return enqueue_pending_app_server_notification(
            state,
            method,
            &notification,
            &params,
            thread_id.as_deref(),
            turn_id.as_deref(),
            item_id.as_deref(),
            identity_key.as_deref(),
        )
        .await
        .is_ok();
    }
    if method == "item/completed" {
        if let (Some(conversation), Some(turn), Some(item)) = (
            message
                .as_ref()
                .map(|message| message.conversation_id.as_str())
                .or_else(|| {
                    ownership
                        .as_ref()
                        .map(|ownership| ownership.conversation_id.as_str())
                }),
            turn_id.as_deref(),
            params.get("item"),
        ) {
            match tool_media::normalize(state, conversation, turn, item).await {
                Ok(item) => params["item"] = item,
                Err(_) => return false,
            }
        }
    }
    // Do not publish the internal startup prompt as a user-authored chat item.
    if params
        .get("item")
        .and_then(|item| item.get("type"))
        .and_then(serde_json::Value::as_str)
        == Some("userMessage")
    {
        if let Some(message) = message.as_ref() {
            match state
                .store
                .bot_initialization_messages(&message.conversation_id)
                .await
            {
                Ok(internal) if internal.iter().any(|m| m.id == message.id) => return true,
                Ok(_) => {}
                Err(_) => return false,
            }
        }
    }
    if params
        .pointer("/item/type")
        .and_then(serde_json::Value::as_str)
        == Some("userMessage")
    {
        if let Some(message) = message.as_ref() {
            match state
                .store
                .bot_workspace_followup_messages(&message.conversation_id)
                .await
            {
                Ok(followups) if followups.iter().any(|m| m.id == message.id) => return true,
                Ok(_) => {}
                Err(_) => return false,
            }
            match state
                .store
                .question_answer_messages(&message.conversation_id)
                .await
            {
                Ok(answers) if answers.iter().any(|m| m.id == message.id) => return true,
                Ok(_) => {}
                Err(_) => return false,
            }
        }
    }
    let server_request_id = request_id(&notification, &params);
    let mut event = project_app_server_notification(method, &params, server_request_id.as_deref());
    if method.starts_with("item/") {
        if let Some(message) = message.as_ref() {
            match state
                .store
                .bot_initialization_messages(&message.conversation_id)
                .await
            {
                Ok(internal) if internal.iter().any(|m| m.id == message.id) => event = None,
                Ok(_) => {}
                Err(_) => return false,
            }
        }
    }
    let is_approval_request = matches!(
        method,
        "item/commandExecution/requestApproval"
            | "item/fileChange/requestApproval"
            | "item/permissions/requestApproval"
            | "item/tool/requestUserInput"
            | "mcpServer/elicitation/request"
            | "item/tool/call"
    );
    let notification_key = app_server_notification_key(method, &notification, &params);
    if let Some(notification_key) = notification_key.as_deref() {
        match state
            .store
            .claim_app_server_notification(notification_key, &now_ms().to_string())
            .await
        {
            Ok(true) => {}
            Ok(false) => return true,
            Err(_) => return false,
        }
    }
    let assistant_delta_key = notification_key
        .clone()
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    if method == "turn/completed" {
        if let Some(message) = message.as_ref() {
            let completion = match (thread_id.as_deref(), turn_id.as_deref()) {
                (Some(thread_id), Some(turn_id)) => {
                    state
                        .store
                        .complete_messages_for_codex_thread_and_turn(thread_id, turn_id)
                        .await
                }
                (_, Some(turn_id)) => state.store.complete_messages_for_codex_turn(turn_id).await,
                (None, None) => state
                    .store
                    .complete_message_if_active(&message.id)
                    .await
                    .map(u64::from),
                (Some(_), None) => state
                    .store
                    .complete_message_if_active(&message.id)
                    .await
                    .map(u64::from),
            };
            match completion {
                Ok(_) => {}
                Err(_) => {
                    return fail_app_server_notification(
                        state,
                        method,
                        &notification,
                        &params,
                        thread_id.as_deref(),
                        turn_id.as_deref(),
                        item_id.as_deref(),
                        notification_key.as_deref(),
                        queue_failed_assistant,
                    )
                    .await;
                }
            }
            let run = match state.store.automation_run_for_message(&message.id).await {
                Ok(run) => run,
                Err(_) => {
                    return fail_app_server_notification(
                        state,
                        method,
                        &notification,
                        &params,
                        thread_id.as_deref(),
                        turn_id.as_deref(),
                        item_id.as_deref(),
                        notification_key.as_deref(),
                        queue_failed_assistant,
                    )
                    .await;
                }
            };
            if let Some(run) = run {
                let finished_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
                let failed = params
                    .get("turn")
                    .and_then(|turn| turn.get("status"))
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|status| matches!(status, "failed" | "interrupted"));
                if state
                    .store
                    .finish_automation_run(
                        &run.id,
                        if failed { "failed" } else { "completed" },
                        &finished_at,
                        failed.then_some(
                            "The run stopped before completing. Open its conversation for details.",
                        ),
                        Some(&message.id),
                    )
                    .await
                    .is_err()
                {
                    return fail_app_server_notification(
                        state,
                        method,
                        &notification,
                        &params,
                        thread_id.as_deref(),
                        turn_id.as_deref(),
                        item_id.as_deref(),
                        notification_key.as_deref(),
                        queue_failed_assistant,
                    )
                    .await;
                }
            }
        }
    }
    if method == "turn/completed" {
        if let Some(message) = message.as_ref().filter(|_| ownership.is_none()) {
            let artifacts = record_workspace_artifacts(state, message)
                .await
                .unwrap_or_default();
            for artifact in artifacts {
                if publish_event_with_context(
                    state,
                    WonderEvent::Activity {
                        category: "artifact".into(),
                        state: "available".into(),
                        detail: Some(artifact_event_detail(&artifact)),
                    },
                    EventContext {
                        request_id: request_id(&notification, &params),
                        conversation_id: Some(message.conversation_id.clone()),
                        message_id: Some(message.id.clone()),
                        thread_id: thread_id.clone(),
                        turn_id: turn_id.clone(),
                        item_id: item_id.clone(),
                        ..EventContext::default()
                    },
                )
                .await
                .is_err()
                {
                    return fail_app_server_notification(
                        state,
                        method,
                        &notification,
                        &params,
                        thread_id.as_deref(),
                        turn_id.as_deref(),
                        item_id.as_deref(),
                        notification_key.as_deref(),
                        queue_failed_assistant,
                    )
                    .await;
                }
            }
        }
        let completed_assistant_messages =
            if let (Some(thread_id), Some(turn_id)) = (thread_id.as_deref(), turn_id.as_deref()) {
                let completed_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
                match state
                    .store
                    .complete_assistant_messages_for_codex_thread_and_turn(
                        thread_id,
                        turn_id,
                        &completed_at,
                    )
                    .await
                {
                    Ok(messages) => messages,
                    Err(_) => {
                        return fail_app_server_notification(
                            state,
                            method,
                            &notification,
                            &params,
                            Some(thread_id),
                            Some(turn_id),
                            item_id.as_deref(),
                            notification_key.as_deref(),
                            queue_failed_assistant,
                        )
                        .await;
                    }
                }
            } else if let Some(turn_id) = turn_id.as_deref() {
                let completed_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
                match state
                    .store
                    .complete_assistant_messages_for_codex_turn(turn_id, &completed_at)
                    .await
                {
                    Ok(messages) => messages,
                    Err(_) => {
                        return fail_app_server_notification(
                            state,
                            method,
                            &notification,
                            &params,
                            thread_id.as_deref(),
                            Some(turn_id),
                            item_id.as_deref(),
                            notification_key.as_deref(),
                            queue_failed_assistant,
                        )
                        .await;
                    }
                }
            } else {
                Vec::new()
            };
        // Some App Server versions finish a turn without item/completed. The
        // stored assistant rows are the source of truth for the missing
        // terminal events in that case.
        for assistant_message in completed_assistant_messages {
            if publish_event_with_context(
                state,
                WonderEvent::AssistantCompleted {
                    text: assistant_message.text,
                },
                EventContext {
                    request_id: request_id(&notification, &params),
                    conversation_id: Some(assistant_message.conversation_id.clone()),
                    message_id: message.as_ref().map(|message| message.id.clone()),
                    thread_id: Some(assistant_message.codex_thread_id),
                    turn_id: Some(assistant_message.codex_turn_id),
                    item_id: Some(assistant_message.item_id),
                    ..EventContext::default()
                },
            )
            .await
            .is_err()
            {
                return fail_app_server_notification(
                    state,
                    method,
                    &notification,
                    &params,
                    thread_id.as_deref(),
                    turn_id.as_deref(),
                    item_id.as_deref(),
                    notification_key.as_deref(),
                    queue_failed_assistant,
                )
                .await;
            }
        }
    }
    if method == "serverRequest/resolved" {
        if let Some(server_request_id) = server_request_id.as_deref() {
            if state
                .store
                .resolve_approval_by_server_request_id(
                    server_request_id,
                    "app_server_resolved",
                    &now_ms().to_string(),
                )
                .await
                .is_err()
            {
                return fail_app_server_notification(
                    state,
                    method,
                    &notification,
                    &params,
                    thread_id.as_deref(),
                    turn_id.as_deref(),
                    item_id.as_deref(),
                    notification_key.as_deref(),
                    queue_failed_assistant,
                )
                .await;
            }
        }
    }
    if method == "item/fileChange/patchUpdated" {
        if let Some(conversation_id) = conversation_id.as_deref() {
            let artifacts = match record_file_changes(
                state,
                conversation_id,
                &params,
                item_id.as_deref(),
            )
            .await
            {
                Ok(artifacts) => artifacts,
                Err(_) => {
                    return fail_app_server_notification(
                        state,
                        method,
                        &notification,
                        &params,
                        thread_id.as_deref(),
                        turn_id.as_deref(),
                        item_id.as_deref(),
                        notification_key.as_deref(),
                        queue_failed_assistant,
                    )
                    .await;
                }
            };
            for artifact in artifacts {
                if publish_event_with_context(
                    state,
                    WonderEvent::Activity {
                        category: "artifact".into(),
                        state: "available".into(),
                        detail: Some(artifact_event_detail(&artifact)),
                    },
                    EventContext {
                        request_id: request_id(&notification, &params),
                        conversation_id: Some(conversation_id.to_owned()),
                        message_id: message.as_ref().map(|message| message.id.clone()),
                        thread_id: thread_id.clone(),
                        turn_id: turn_id.clone(),
                        item_id: item_id.clone(),
                        ..EventContext::default()
                    },
                )
                .await
                .is_err()
                {
                    return fail_app_server_notification(
                        state,
                        method,
                        &notification,
                        &params,
                        thread_id.as_deref(),
                        turn_id.as_deref(),
                        item_id.as_deref(),
                        notification_key.as_deref(),
                        queue_failed_assistant,
                    )
                    .await;
                }
            }
        }
    }
    let assistant_completed = method == "item/completed"
        && matches!(
            project_app_server_notification(method, &params, None),
            Some(WonderEvent::AssistantCompleted { .. })
        );
    if assistant_completed {
        if let Some(conversation_id) = conversation_id.as_deref() {
            let bot = match bot_for_conversation(state, conversation_id).await {
                Ok(Some(bot)) => bot,
                Ok(None) | Err(_) => {
                    return fail_app_server_notification(
                        state,
                        method,
                        &notification,
                        &params,
                        thread_id.as_deref(),
                        turn_id.as_deref(),
                        item_id.as_deref(),
                        notification_key.as_deref(),
                        queue_failed_assistant,
                    )
                    .await;
                }
            };
            if state
                .store
                .ensure_conversation_metadata(
                    conversation_id,
                    &bot.id,
                    &bot.name,
                    &state.started_at,
                )
                .await
                .is_err()
            {
                return fail_app_server_notification(
                    state,
                    method,
                    &notification,
                    &params,
                    thread_id.as_deref(),
                    turn_id.as_deref(),
                    item_id.as_deref(),
                    notification_key.as_deref(),
                    queue_failed_assistant,
                )
                .await;
            }
            if state
                .store
                .update_conversation(
                    conversation_id,
                    None,
                    None,
                    None,
                    Some(true),
                    &now_ms().to_string(),
                )
                .await
                .is_err()
            {
                return fail_app_server_notification(
                    state,
                    method,
                    &notification,
                    &params,
                    thread_id.as_deref(),
                    turn_id.as_deref(),
                    item_id.as_deref(),
                    notification_key.as_deref(),
                    queue_failed_assistant,
                )
                .await;
            }
        }
    }
    if let (Some(conversation_id), Some(thread_id), Some(turn_id), Some(item_id)) = (
        conversation_id.as_deref(),
        thread_id.as_deref(),
        turn_id.as_deref(),
        item_id.as_deref(),
    ) {
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        match method {
            "item/agentMessage/delta" => {
                if message.as_ref().is_some_and(|message| {
                    matches!(message.state.as_str(), "completed" | "interrupted")
                }) {
                    event = None;
                } else if let Some(delta) = params.get("delta").and_then(extract_text) {
                    let assistant = match state
                        .store
                        .upsert_assistant_delta(
                            conversation_id,
                            thread_id,
                            turn_id,
                            item_id,
                            &delta,
                            &assistant_delta_key,
                            &now,
                        )
                        .await
                    {
                        Ok(assistant) => assistant,
                        Err(_) => {
                            return fail_app_server_notification(
                                state,
                                method,
                                &notification,
                                &params,
                                Some(thread_id),
                                Some(turn_id),
                                Some(item_id),
                                notification_key.as_deref(),
                                queue_failed_assistant,
                            )
                            .await;
                        }
                    };
                    if assistant.state == "completed" {
                        event = None;
                    } else {
                        if let Some(message) = message.as_ref() {
                            if state
                                .store
                                .update_message_delivery(
                                    &message.id,
                                    "streaming",
                                    Some(thread_id),
                                    Some(turn_id),
                                )
                                .await
                                .is_err()
                            {
                                return fail_app_server_notification(
                                    state,
                                    method,
                                    &notification,
                                    &params,
                                    Some(thread_id),
                                    Some(turn_id),
                                    Some(item_id),
                                    notification_key.as_deref(),
                                    queue_failed_assistant,
                                )
                                .await;
                            }
                            if message.state != "streaming"
                                && publish_message_state_checked(
                                    state,
                                    message,
                                    DeliveryState::Streaming,
                                    Some(thread_id),
                                    Some(turn_id),
                                )
                                .await
                                .is_err()
                            {
                                return fail_app_server_notification(
                                    state,
                                    method,
                                    &notification,
                                    &params,
                                    Some(thread_id),
                                    Some(turn_id),
                                    Some(item_id),
                                    notification_key.as_deref(),
                                    queue_failed_assistant,
                                )
                                .await;
                            }
                        }
                    }
                }
            }
            "item/completed" if assistant_completed => {
                let text = params
                    .get("item")
                    .and_then(extract_text)
                    .unwrap_or_default();
                match state
                    .store
                    .complete_assistant_message(
                        conversation_id,
                        thread_id,
                        turn_id,
                        item_id,
                        &text,
                        &now,
                    )
                    .await
                {
                    Ok(Some(_)) => {}
                    Ok(None) => event = None,
                    Err(_) => {
                        return fail_app_server_notification(
                            state,
                            method,
                            &notification,
                            &params,
                            Some(thread_id),
                            Some(turn_id),
                            Some(item_id),
                            notification_key.as_deref(),
                            queue_failed_assistant,
                        )
                        .await;
                    }
                }
            }
            _ => {}
        }
    }
    if method == "item/completed" {
        if let (Some(conversation_id), Some(thread), Some(turn), Some(item)) = (
            conversation_id.as_deref(),
            thread_id.as_deref(),
            turn_id.as_deref(),
            params.get("item"),
        ) {
            if let (Some(id), Some(questions)) = (
                item.get("id").and_then(serde_json::Value::as_str),
                questions::async_questions(item),
            ) {
                if state
                    .store
                    .save_async_question(
                        conversation_id,
                        thread,
                        turn,
                        id,
                        &questions.to_string(),
                        now_ms().saturating_add(questions::OPTIONAL_QUESTION_TTL_MS) as i64,
                    )
                    .await
                    .is_err()
                {
                    if let Some(key) = notification_key.as_deref() {
                        let _ = state.store.release_app_server_notification(key).await;
                    }
                    return false;
                }
            }
        }
    }
    if let Some(server_request_id) = server_request_id.as_deref() {
        if is_approval_request {
            let mut stored_params = params.clone();
            if method == "item/tool/requestUserInput" {
                if let Some(deadline) = questions::optional_deadline(&params, now_ms()) {
                    stored_params["_wonderQuestionDeadlineMs"] = serde_json::json!(deadline);
                }
            }
            if state
                .store
                .insert_pending_approval(
                    server_request_id,
                    method,
                    &serde_json::to_string(&stored_params).unwrap_or_else(|_| "{}".into()),
                    &now_ms().to_string(),
                )
                .await
                .is_err()
            {
                return fail_app_server_notification(
                    state,
                    method,
                    &notification,
                    &params,
                    thread_id.as_deref(),
                    turn_id.as_deref(),
                    item_id.as_deref(),
                    notification_key.as_deref(),
                    queue_failed_assistant,
                )
                .await;
            }
        }
    }
    if method == "turn/completed" && computer_tools::retire_completed(state).await.is_err() {
        return false;
    }
    // Preserve the complete App Server item in the event stream as a
    // loss-minimized projection. Older clients still see a normal activity
    // event; newer clients consume its thread_item_upsert category.
    if let (Some(turn_id), Some(item)) = (
        turn_id.as_deref(),
        params.get("item").filter(|_| {
            matches!(
                method,
                "item/started"
                    | "item/completed"
                    | "item/commandExecution/started"
                    | "item/commandExecution/completed"
                    | "item/fileChange/started"
                    | "item/fileChange/completed"
            )
        }),
    ) {
        let workspace = match conversation_id.as_deref() {
            Some(conversation) => match state
                .store
                .conversation_execution_directory(conversation)
                .await
            {
                Ok(value) => value,
                Err(_) => return false,
            },
            None => None,
        };
        if let Some(detail) = thread_item_upsert_detail_with_authority(
            turn_id,
            item,
            app_server_item_lifecycle_state(method, item),
            2,
            workspace.as_deref(),
        ) {
            if publish_event_with_context(
                state,
                WonderEvent::Activity {
                    category: "thread_item_upsert".into(),
                    state: "updated".into(),
                    detail: Some(detail),
                },
                EventContext {
                    request_id: request_id(&notification, &params),
                    conversation_id: conversation_id.clone(),
                    message_id: message.as_ref().map(|message| message.id.clone()),
                    thread_id: thread_id.clone(),
                    turn_id: Some(turn_id.to_owned()),
                    item_id: item_id.clone(),
                    approval_id: server_request_id.clone(),
                },
            )
            .await
            .is_err()
            {
                return false;
            }
        }
    }
    if let Some(event) = event {
        if publish_event_with_context(
            state,
            event,
            EventContext {
                request_id: request_id(&notification, &params),
                conversation_id: conversation_id.clone(),
                message_id: message.as_ref().map(|message| message.id.clone()),
                thread_id: thread_id.clone(),
                turn_id: turn_id.clone(),
                item_id: item_id.clone(),
                approval_id: server_request_id,
            },
        )
        .await
        .is_err()
        {
            return fail_app_server_notification(
                state,
                method,
                &notification,
                &params,
                thread_id.as_deref(),
                turn_id.as_deref(),
                item_id.as_deref(),
                notification_key.as_deref(),
                queue_failed_assistant,
            )
            .await;
        }
    }
    true
}

async fn drain_pending_app_server_notifications(state: &AppState, thread_id: &str, turn_id: &str) {
    let pending = match state
        .store
        .pending_app_server_notifications_for_thread_and_turn(thread_id, turn_id)
        .await
    {
        Ok(pending) => pending,
        Err(_) => return,
    };
    for pending in pending {
        let Ok(notification) =
            serde_json::from_str::<serde_json::Value>(&pending.notification_json)
        else {
            continue;
        };
        if process_app_server_notification(state, notification, false).await {
            let _ = state
                .store
                .delete_pending_app_server_notification(&pending.id)
                .await;
        } else {
            break;
        }
    }
}

async fn record_file_changes(
    state: &AppState,
    conversation_id: &str,
    params: &serde_json::Value,
    item_id: Option<&str>,
) -> Result<Vec<WorkspaceArtifact>, sqlx::Error> {
    let bot = bot_for_conversation(state, conversation_id)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
    let Some(changes) = params.get("changes").and_then(serde_json::Value::as_array) else {
        return Ok(Vec::new());
    };
    let mut artifacts = Vec::new();
    for change in changes {
        let Some(path) = change.get("path").and_then(serde_json::Value::as_str) else {
            continue;
        };
        let Some(relative_path) = sanitized_relative_path(path, &bot.workspace_path) else {
            continue;
        };
        let Some(name) = FsPath::new(&relative_path)
            .file_name()
            .and_then(|name| name.to_str())
        else {
            continue;
        };
        let diff = change
            .get("diff")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default();
        let additions = diff
            .lines()
            .filter(|line| line.starts_with('+') && !line.starts_with("+++"))
            .count() as i64;
        let deletions = diff
            .lines()
            .filter(|line| line.starts_with('-') && !line.starts_with("---"))
            .count() as i64;
        let change_kind = change
            .get("kind")
            .and_then(|kind| kind.get("type"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("update");
        let file_id = hex::encode(Sha256::digest(
            format!("{conversation_id}:{relative_path}").as_bytes(),
        ));
        let artifact = if change_kind == "delete" {
            None
        } else {
            read_workspace_artifact(&bot.workspace_path, &relative_path, name, &file_id).await
        };
        let (file_kind, mime_type, byte_size, sha256, file_state) = match artifact.as_ref() {
            Some(artifact) => (
                "artifact",
                Some(artifact.mime_type),
                Some(artifact.byte_size as i64),
                Some(artifact.sha256.as_str()),
                "available",
            ),
            None => ("file_change", None, None, None, change_kind),
        };
        state
            .store
            .upsert_conversation_file(
                &file_id,
                conversation_id,
                file_kind,
                name,
                mime_type,
                byte_size,
                sha256,
                Some(&relative_path),
                file_state,
                Some(additions),
                Some(deletions),
                item_id,
                &now_ms().to_string(),
            )
            .await?;
        if let Some(artifact) = artifact {
            artifacts.push(artifact);
        }
    }
    Ok(artifacts)
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WorkspaceArtifact {
    id: String,
    name: String,
    mime_type: &'static str,
    byte_size: usize,
    sha256: String,
    relative_path: String,
}

async fn workspace_file_path(workspace: &str, relative_path: &str) -> Option<PathBuf> {
    let root = tokio::fs::canonicalize(workspace).await.ok()?;
    let candidate = root.join(relative_path);
    let metadata = tokio::fs::symlink_metadata(&candidate).await.ok()?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return None;
    }
    let canonical = tokio::fs::canonicalize(&candidate).await.ok()?;
    canonical.starts_with(&root).then_some(canonical)
}

fn artifact_mime_type(name: &str, bytes: &[u8]) -> Option<&'static str> {
    let extension = FsPath::new(name)
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase());
    match extension.as_deref() {
        Some("pdf")
            if bytes.starts_with(b"%PDF-") && bytes.windows(5).any(|window| window == b"%%EOF") =>
        {
            Some("application/pdf")
        }
        Some("md" | "markdown" | "mdx") if std::str::from_utf8(bytes).is_ok() => {
            Some("text/markdown")
        }
        Some("html" | "htm" | "xhtml") if std::str::from_utf8(bytes).is_ok() => Some("text/html"),
        Some("txt" | "log") if std::str::from_utf8(bytes).is_ok() => Some("text/plain"),
        Some("rs") if std::str::from_utf8(bytes).is_ok() => Some("text/x-rust"),
        Some("ts" | "tsx") if std::str::from_utf8(bytes).is_ok() => Some("text/typescript"),
        Some("js" | "jsx" | "mjs" | "cjs") if std::str::from_utf8(bytes).is_ok() => {
            Some("text/javascript")
        }
        Some("json" | "jsonc" | "json5") if std::str::from_utf8(bytes).is_ok() => {
            Some("application/json")
        }
        Some("py") if std::str::from_utf8(bytes).is_ok() => Some("text/x-python"),
        Some("css" | "scss" | "less") if std::str::from_utf8(bytes).is_ok() => Some("text/css"),
        Some("xml") if std::str::from_utf8(bytes).is_ok() => Some("application/xml"),
        Some("yaml" | "yml") if std::str::from_utf8(bytes).is_ok() => Some("application/yaml"),
        Some("toml" | "ini") if std::str::from_utf8(bytes).is_ok() => Some("text/plain"),
        Some("sh" | "bash") if std::str::from_utf8(bytes).is_ok() => Some("text/x-shellscript"),
        Some("sql") if std::str::from_utf8(bytes).is_ok() => Some("application/sql"),
        Some("png") if bytes.starts_with(b"\x89PNG\r\n\x1a\n") => Some("image/png"),
        Some("jpg" | "jpeg") if bytes.starts_with(b"\xff\xd8\xff") => Some("image/jpeg"),
        Some("gif") if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") => {
            Some("image/gif")
        }
        Some("webp")
            if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP".as_slice()) =>
        {
            Some("image/webp")
        }
        _ => None,
    }
}

async fn read_workspace_artifact(
    workspace: &str,
    relative_path: &str,
    name: &str,
    id: &str,
) -> Option<WorkspaceArtifact> {
    let path = workspace_file_path(workspace, relative_path).await?;
    let metadata = tokio::fs::metadata(&path).await.ok()?;
    if metadata.len() > MAX_WORKSPACE_ARTIFACT_BYTES as u64 {
        return None;
    }
    let bytes = tokio::fs::read(&path).await.ok()?;
    if bytes.len() > MAX_WORKSPACE_ARTIFACT_BYTES {
        return None;
    }
    let mime_type = artifact_mime_type(name, &bytes)?;
    let sha256 = hex::encode(Sha256::digest(&bytes));
    Some(WorkspaceArtifact {
        id: id.to_owned(),
        name: name.to_owned(),
        mime_type,
        byte_size: bytes.len(),
        sha256,
        relative_path: relative_path.to_owned(),
    })
}

async fn record_workspace_artifacts(
    state: &AppState,
    message: &wonder_store::StoredMessage,
) -> Result<Vec<WorkspaceArtifact>, sqlx::Error> {
    let bot = bot_for_conversation(state, &message.conversation_id)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
    let root = tokio::fs::canonicalize(&bot.workspace_path)
        .await
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let mut files = Vec::new();
    collect_workspace_files(&root, &root, 0, &mut files).await;
    let mut artifacts = Vec::new();
    for relative_path in files {
        let Some(name) = FsPath::new(&relative_path)
            .file_name()
            .and_then(|name| name.to_str())
        else {
            continue;
        };
        let file_id = hex::encode(Sha256::digest(
            format!("{}:{}", message.conversation_id, relative_path).as_bytes(),
        ));
        let Some(artifact) =
            read_workspace_artifact(&bot.workspace_path, &relative_path, name, &file_id).await
        else {
            continue;
        };
        state
            .store
            .upsert_conversation_file(
                &artifact.id,
                &message.conversation_id,
                "artifact",
                &artifact.name,
                Some(artifact.mime_type),
                Some(artifact.byte_size as i64),
                Some(&artifact.sha256),
                Some(&artifact.relative_path),
                "available",
                None,
                None,
                Some(&message.id),
                &now_ms().to_string(),
            )
            .await?;
        artifacts.push(artifact);
    }
    Ok(artifacts)
}

fn collect_workspace_files<'a>(
    root: &'a FsPath,
    directory: &'a FsPath,
    depth: usize,
    files: &'a mut Vec<String>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>> {
    Box::pin(async move {
        if depth > 3 || files.len() >= 64 {
            return;
        }
        let Ok(mut entries) = tokio::fs::read_dir(directory).await else {
            return;
        };
        while let Ok(Some(entry)) = entries.next_entry().await {
            if files.len() >= 64 {
                return;
            }
            let path = entry.path();
            let Ok(metadata) = tokio::fs::symlink_metadata(&path).await else {
                continue;
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                collect_workspace_files(root, &path, depth + 1, files).await;
                continue;
            }
            if !metadata.is_file() {
                continue;
            }
            let Some(relative) = path.strip_prefix(root).ok().and_then(|path| path.to_str()) else {
                continue;
            };
            if FsPath::new(relative)
                .extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| {
                    matches!(
                        extension.to_ascii_lowercase().as_str(),
                        "pdf" | "md" | "markdown" | "png"
                    )
                })
            {
                files.push(relative.to_owned());
            }
        }
    })
}

fn artifact_event_detail(artifact: &WorkspaceArtifact) -> String {
    serde_json::json!({
        "artifactId": artifact.id,
        "name": artifact.name,
        "mimeType": artifact.mime_type,
        "byteSize": artifact.byte_size,
        "sha256": artifact.sha256,
        "relativePath": artifact.relative_path,
    })
    .to_string()
}

fn sanitized_relative_path(path: &str, workspace: &str) -> Option<String> {
    let path = FsPath::new(path);
    let relative = if path.is_absolute() {
        path.strip_prefix(workspace).ok()?
    } else {
        path
    };
    let mut components = Vec::new();
    for component in relative.components() {
        let component = component.as_os_str().to_str()?;
        if component.is_empty() || component == "." || component == ".." {
            return None;
        }
        components.push(component);
    }
    (!components.is_empty()).then(|| components.join("/"))
}

async fn publish_message_state(
    state: &AppState,
    message: &wonder_store::StoredMessage,
    delivery_state: DeliveryState,
    thread_id: Option<&str>,
    turn_id: Option<&str>,
) {
    let _ = publish_event_with_context(
        state,
        WonderEvent::MessageState {
            state: delivery_state,
        },
        EventContext {
            conversation_id: Some(message.conversation_id.clone()),
            message_id: Some(message.id.clone()),
            thread_id: thread_id
                .map(str::to_owned)
                .or_else(|| message.codex_thread_id.clone()),
            turn_id: turn_id
                .map(str::to_owned)
                .or_else(|| message.codex_turn_id.clone()),
            ..EventContext::default()
        },
    )
    .await;
}

async fn publish_message_state_checked(
    state: &AppState,
    message: &wonder_store::StoredMessage,
    delivery_state: DeliveryState,
    thread_id: Option<&str>,
    turn_id: Option<&str>,
) -> Result<(), sqlx::Error> {
    publish_event_with_context(
        state,
        WonderEvent::MessageState {
            state: delivery_state,
        },
        EventContext {
            conversation_id: Some(message.conversation_id.clone()),
            message_id: Some(message.id.clone()),
            thread_id: thread_id
                .map(str::to_owned)
                .or_else(|| message.codex_thread_id.clone()),
            turn_id: turn_id
                .map(str::to_owned)
                .or_else(|| message.codex_turn_id.clone()),
            ..EventContext::default()
        },
    )
    .await
    .map(|_| ())
}

fn string_field(params: &serde_json::Value, name: &str) -> Option<String> {
    params
        .get(name)
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned)
}

fn steer_response_turn_id(response: &wonder_app_server::RpcResponse) -> Option<String> {
    response
        .result
        .as_ref()
        .and_then(|result| result.get("turnId"))
        .and_then(serde_json::Value::as_str)
        .filter(|turn_id| !turn_id.is_empty())
        .map(str::to_owned)
}

/// App Server item payloads have changed shape across compatible releases:
/// some expose `text`, while others put assistant output in a content/parts
/// array. Keep the protocol boundary tolerant and return only display text.
fn extract_text(value: &serde_json::Value) -> Option<String> {
    if let Some(text) = value.as_str() {
        return (!text.is_empty()).then(|| text.to_owned());
    }
    if let Some(text) = value.get("text").and_then(serde_json::Value::as_str) {
        return (!text.is_empty()).then(|| text.to_owned());
    }
    for key in ["content", "parts", "message", "output", "delta"] {
        if let Some(values) = value.get(key).and_then(serde_json::Value::as_array) {
            let text = values
                .iter()
                .filter_map(extract_text)
                .collect::<Vec<_>>()
                .join("");
            if !text.is_empty() {
                return Some(text);
            }
        } else if let Some(nested) = value.get(key).and_then(extract_text) {
            return Some(nested);
        }
    }
    None
}

fn request_id(notification: &serde_json::Value, params: &serde_json::Value) -> Option<String> {
    params
        .get("requestId")
        .and_then(value_id)
        .or_else(|| notification.get("id").and_then(value_id))
        .map(|id| {
            match notification
                .get("_wonderRuntimeId")
                .or_else(|| params.get("_wonderRuntimeId"))
                .and_then(serde_json::Value::as_str)
            {
                Some(runtime) => format!("{runtime}:{id}"),
                None => id,
            }
        })
}

fn app_server_notification_key(
    method: &str,
    notification: &serde_json::Value,
    params: &serde_json::Value,
) -> Option<String> {
    let explicit_id = ["eventId", "notificationId", "deltaId"]
        .iter()
        .find_map(|key| params.get(*key).and_then(value_id))
        .or_else(|| {
            ["eventId", "notificationId"]
                .iter()
                .find_map(|key| notification.get(*key).and_then(value_id))
        });
    let item_id = params.get("itemId").and_then(value_id).or_else(|| {
        params
            .get("item")
            .and_then(|item| item.get("id"))
            .and_then(value_id)
    });
    let sequence = ["sequence", "index", "deltaIndex", "offset"]
        .iter()
        .find_map(|key| params.get(*key).and_then(value_id));
    let identity = explicit_id
        .or_else(|| match method {
            "item/agentMessage/delta" => item_id
                .zip(sequence)
                .map(|(item, sequence)| format!("item:{item}:sequence:{sequence}")),
            "item/commandExecution/outputDelta" | "item/fileChange/outputDelta" => item_id
                .zip(sequence)
                .map(|(item, sequence)| format!("item:{item}:sequence:{sequence}")),
            "item/fileChange/patchUpdated" => item_id.map(|item| {
                let changes = params.get("changes").cloned().unwrap_or_default();
                let changes_hash = hex::encode(Sha256::digest(
                    serde_json::to_vec(&changes).unwrap_or_default(),
                ));
                format!("item:{item}:changes:{changes_hash}")
            }),
            "item/completed" => item_id.map(|item| format!("item:{item}:completed")),
            "thread/compacted" => params
                .get("turnId")
                .and_then(value_id)
                .map(|turn| format!("turn:{turn}:compacted")),
            "turn/completed" => params
                .get("turnId")
                .and_then(value_id)
                .or_else(|| {
                    params
                        .get("turn")
                        .and_then(|turn| turn.get("id"))
                        .and_then(value_id)
                })
                .map(|turn| format!("turn:{turn}:completed")),
            "serverRequest/resolved"
            | "item/commandExecution/requestApproval"
            | "item/fileChange/requestApproval"
            | "item/permissions/requestApproval"
            | "item/tool/requestUserInput"
            | "mcpServer/elicitation/request"
            | "item/tool/call" => {
                request_id(notification, params).map(|request| format!("request:{request}"))
            }
            _ => None,
        })
        .or_else(|| {
            notification
                .get("_wonderInboxId")
                .and_then(value_id)
                .map(|id| format!("inbox:{id}"))
        })?;
    let identity = serde_json::json!({ "method": method, "identity": identity, "thread": notification_thread_id(params), "turn": notification_turn_id(params) });
    Some(hex::encode(Sha256::digest(
        serde_json::to_vec(&identity).unwrap_or_default(),
    )))
}

fn value_id(value: &serde_json::Value) -> Option<String> {
    value
        .as_str()
        .map(str::to_owned)
        .or_else(|| value.as_u64().map(|id| id.to_string()))
}

fn project_app_server_notification(
    method: &str,
    params: &serde_json::Value,
    server_request_id: Option<&str>,
) -> Option<WonderEvent> {
    match method {
        "item/agentMessage/delta" => params
            .get("delta")
            .and_then(extract_text)
            .map(|text| WonderEvent::AssistantDelta { text }),
        "item/commandExecution/outputDelta" => Some(WonderEvent::Activity {
            category: "command".into(),
            state: "working".into(),
            detail: Some("Output updated".into()),
        }),
        "item/fileChange/outputDelta" => Some(WonderEvent::Activity {
            category: "file change".into(),
            state: "working".into(),
            detail: Some("Output updated".into()),
        }),
        "item/started" => params
            .get("item")
            .and_then(|item| project_typed_item_activity(item, "running")),
        "item/completed" => {
            let item = params.get("item")?;
            if item
                .get("type")
                .and_then(serde_json::Value::as_str)
                .is_none_or(|item_type| item_type == "agentMessage")
            {
                // A valid agent completion may have no visible text (for
                // example, a turn that only produced an artifact). Preserve
                // the terminal event so the client can leave streaming state.
                Some(WonderEvent::AssistantCompleted {
                    text: extract_text(item).unwrap_or_default(),
                })
            } else {
                project_typed_item_activity(item, "completed")
            }
        }
        "turn/completed" => Some(WonderEvent::MessageState {
            state: turn_completion_delivery_state(params),
        }),
        "thread/compacted" => Some(WonderEvent::Activity {
            category: "thread/compacted".into(),
            state: "completed".into(),
            detail: None,
        }),
        "item/commandExecution/started" => Some(WonderEvent::Activity {
            category: "command".into(),
            state: "started".into(),
            detail: None,
        }),
        "item/commandExecution/completed" => Some(WonderEvent::Activity {
            category: "command".into(),
            state: "completed".into(),
            detail: None,
        }),
        "item/fileChange/started" => Some(WonderEvent::Activity {
            category: "file change".into(),
            state: "started".into(),
            detail: None,
        }),
        "item/fileChange/completed" => Some(WonderEvent::Activity {
            category: "file change".into(),
            state: "completed".into(),
            detail: None,
        }),
        "item/mcpToolCall/progress" => Some(WonderEvent::Activity {
            category: "MCP tool".into(),
            state: "working".into(),
            detail: None,
        }),
        "item/plan/delta" | "turn/plan/updated" => Some(WonderEvent::Activity {
            category: "plan".into(),
            state: "updated".into(),
            detail: None,
        }),
        "item/reasoning/summaryPartAdded"
        | "item/reasoning/summaryTextDelta"
        | "item/reasoning/textDelta" => Some(WonderEvent::Activity {
            category: "reasoning".into(),
            state: "working".into(),
            detail: None,
        }),
        "model/rerouted" => Some(WonderEvent::Activity {
            category: "model".into(),
            state: "rerouted".into(),
            detail: None,
        }),
        "serverRequest/resolved" => {
            server_request_id.map(|request_id| WonderEvent::ApprovalResolved {
                request_id: request_id.into(),
                decision: "app_server_resolved".into(),
            })
        }
        "item/commandExecution/requestApproval"
        | "item/fileChange/requestApproval"
        | "item/permissions/requestApproval"
        | "item/tool/requestUserInput"
        | "mcpServer/elicitation/request"
        | "item/tool/call" => server_request_id.map(|request_id| WonderEvent::ApprovalOpened {
            request_id: request_id.into(),
        }),
        _ => Some(WonderEvent::Activity {
            category: "App Server".into(),
            state: "unhandled".into(),
            // Retain only the bounded method name. Never persist the raw
            // notification payload when a newer protocol method appears.
            detail: Some(method.chars().take(120).collect()),
        }),
    }
}

fn project_typed_item_activity(item: &serde_json::Value, state: &str) -> Option<WonderEvent> {
    let item_type = item.get("type").and_then(serde_json::Value::as_str)?;
    let (category, detail) = match item_type {
        "commandExecution" => (
            "command",
            item.get("command")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned),
        ),
        "fileChange" => (
            "file change",
            item.get("changes")
                .and_then(serde_json::Value::as_array)
                .map(|changes| {
                    changes
                        .iter()
                        .filter_map(|change| change.get("path").and_then(serde_json::Value::as_str))
                        .take(4)
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .filter(|detail| !detail.is_empty()),
        ),
        "mcpToolCall" | "dynamicToolCall" => (
            "MCP tool",
            item.get("tool")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned),
        ),
        "plan" => ("plan", item.get("text").and_then(extract_text)),
        "reasoning" => ("reasoning", None),
        _ => return None,
    };
    Some(WonderEvent::Activity {
        category: category.into(),
        state: state.into(),
        detail,
    })
}

fn thread_item_upsert_detail(
    turn_id: &str,
    item: &serde_json::Value,
    state: &str,
    workspace: Option<&str>,
) -> Option<String> {
    let authority = if item.get("status").is_some() || item.get("state").is_some() {
        1
    } else {
        0
    };
    thread_item_upsert_detail_with_authority(turn_id, item, state, authority, workspace)
}

fn app_server_item_lifecycle_state(method: &str, item: &serde_json::Value) -> &'static str {
    if !method.ends_with("completed") {
        return "started";
    }
    item.get("status")
        .or_else(|| item.get("state"))
        .and_then(|value| {
            value
                .as_str()
                .or_else(|| value.get("type").and_then(serde_json::Value::as_str))
        })
        .map(history::thread_item_state)
        .filter(|state| matches!(*state, "failed" | "interrupted"))
        .unwrap_or("completed")
}

fn thread_item_upsert_detail_with_authority(
    turn_id: &str,
    item: &serde_json::Value,
    state: &str,
    lifecycle_authority: u8,
    workspace: Option<&str>,
) -> Option<String> {
    let item_id = item.get("id").and_then(serde_json::Value::as_str)?;
    Some(
        serde_json::json!({
            "turnId": turn_id,
            "item": sanitize_typed_item(item, workspace),
            "state": thread_item_state(state),
            "lifecycleAuthority": lifecycle_authority,
            "itemId": item_id,
        })
        .to_string(),
    )
}

fn turn_completion_delivery_state(params: &serde_json::Value) -> DeliveryState {
    let status = params
        .get("turn")
        .and_then(|turn| turn.get("status"))
        .and_then(|status| {
            status
                .as_str()
                .or_else(|| status.get("type").and_then(serde_json::Value::as_str))
        })
        .or_else(|| params.get("status").and_then(serde_json::Value::as_str));
    match status {
        Some("failed" | "error") => DeliveryState::Failed,
        Some("interrupted" | "aborted" | "cancelled") => DeliveryState::Interrupted,
        _ => DeliveryState::Completed,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RouteAuth {
    Public,
    PublicPairing,
    ProtectedApi,
    NotFound,
}

fn route_auth(path: &str) -> RouteAuth {
    if matches!(path, "/healthz" | "/readyz") || is_pairing_web_path(path) {
        RouteAuth::Public
    } else if is_public_pairing_path(path) {
        RouteAuth::PublicPairing
    } else if path.starts_with("/api/") {
        RouteAuth::ProtectedApi
    } else {
        RouteAuth::NotFound
    }
}

fn is_pairing_web_path(path: &str) -> bool {
    matches!(path, "/" | "/pair" | "/pair/style.css" | "/sw.js")
}

async fn require_loopback_capability(
    State(state): State<AppState>,
    mut request: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let auth = route_auth(request.uri().path());
    if auth == RouteAuth::NotFound {
        let mut response = StatusCode::NOT_FOUND.into_response();
        apply_security_headers(&mut response);
        return response;
    }
    if auth == RouteAuth::Public {
        let mut response = next.run(request).await;
        apply_security_headers(&mut response);
        return response;
    }
    if auth == RouteAuth::PublicPairing {
        let Some(public_origin) = current_public_origin(&state).await else {
            return (StatusCode::SERVICE_UNAVAILABLE, "Wonder is still starting").into_response();
        };
        let origin = request
            .headers()
            .get(header::ORIGIN)
            .and_then(|value| value.to_str().ok());
        if origin != Some(public_origin.as_str()) {
            return (StatusCode::FORBIDDEN, "origin rejected").into_response();
        }
        let mut response = next.run(request).await;
        apply_security_headers(&mut response);
        return response;
    }
    let provided = request
        .headers()
        .get("x-wonder-loopback-capability")
        .and_then(|value| value.to_str().ok());
    if (request.uri().path().starts_with("/api/v1/pairing/offers")
        || request.uri().path().starts_with("/api/v1/pairing/pending"))
        && provided != Some(state.loopback_capability.as_str())
    {
        return (
            StatusCode::FORBIDDEN,
            "Confirm device connections on your Mac.",
        )
            .into_response();
    }
    if provided == Some(state.loopback_capability.as_str()) {
        request.extensions_mut().insert(LocalOwnerAuthority);
    } else {
        let Some(public_origin) = current_public_origin(&state).await else {
            return (StatusCode::SERVICE_UNAVAILABLE, "Wonder is still starting").into_response();
        };
        if !matches_public_origin(&request, &public_origin) {
            return (StatusCode::FORBIDDEN, "origin rejected").into_response();
        }
        let session = cookie_value(request.headers(), "__Host-wonder_session");
        let csrf = request
            .headers()
            .get("x-wonder-csrf")
            .and_then(|value| value.to_str().ok());
        let needs_csrf = request.method() != axum::http::Method::GET;
        if needs_csrf && csrf.is_none() {
            return (StatusCode::UNAUTHORIZED, "Wonder CSRF token required").into_response();
        }
        let Some(session) = session else {
            return (StatusCode::UNAUTHORIZED, "Wonder session required").into_response();
        };
        let authenticated_device = {
            let pairing = state.pairing.lock().await;
            match pairing.verify_session(&session, csrf, now_ms()) {
                Ok(device_id) => AuthenticatedDevice {
                    device_id,
                    session_binding: csrf.unwrap_or_default().to_owned(),
                },
                Err(_) => {
                    return (StatusCode::UNAUTHORIZED, "Wonder session required").into_response()
                }
            }
        };
        if state
            .store
            .touch_owner_device(&authenticated_device.device_id, &now_ms().to_string())
            .await
            .is_err()
        {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "device state unavailable",
            )
                .into_response();
        }
        request.extensions_mut().insert(authenticated_device);
    }
    let path = request.uri().path();
    if request.method() == axum::http::Method::POST
        && (path.ends_with("/messages")
            || path.ends_with("/retry")
            || path.ends_with("/steer")
            || (path.starts_with("/api/v1/automations/") && path.ends_with("/run")))
    {
        let readiness = state.ingestion.readiness(&state.store).await;
        if !readiness.ready {
            return (StatusCode::SERVICE_UNAVAILABLE, readiness.detail).into_response();
        }
    }
    request.extensions_mut().insert(OwnerAuthority);
    let mut response = next.run(request).await;
    apply_security_headers(&mut response);
    response
}

fn apply_security_headers(response: &mut Response) {
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("no-store"),
    );
    response.headers_mut().insert(
        header::REFERRER_POLICY,
        axum::http::HeaderValue::from_static("no-referrer"),
    );
    response.headers_mut().insert("content-security-policy", axum::http::HeaderValue::from_static("default-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; connect-src 'self'; img-src 'self' data: blob:"));
    response.headers_mut().insert(
        "x-frame-options",
        axum::http::HeaderValue::from_static("DENY"),
    );
}

fn cookie_value(headers: &axum::http::HeaderMap, name: &str) -> Option<String> {
    headers
        .get(header::COOKIE)
        .and_then(|value| value.to_str().ok())
        .and_then(|cookies| {
            cookies
                .split(';')
                .map(str::trim)
                .find_map(|cookie| cookie.strip_prefix(&format!("{name}=")))
        })
        .map(str::to_owned)
}

fn is_public_pairing_path(path: &str) -> bool {
    matches!(
        path,
        "/api/v1/pairing/claim"
            | "/api/v1/pairing/code"
            | "/api/v1/pairing/session"
            | "/api/v1/pairing/session/refresh-challenge"
    )
}

async fn current_public_origin(state: &AppState) -> Option<String> {
    if let Some(path) = state.public_origin_file.as_deref() {
        if let Ok(contents) = tokio::fs::read_to_string(path).await {
            return public_origin_from_status_log(&contents);
        }
        return None;
    }
    let origin = state.public_origin.trim();
    is_valid_public_origin(origin).then(|| origin.to_owned())
}

fn public_origin_from_status_log(contents: &str) -> Option<String> {
    let status = contents
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())?;
    if status.get("state").and_then(serde_json::Value::as_str) != Some("ready") {
        return None;
    }
    status
        .get("origin")
        .and_then(serde_json::Value::as_str)
        .filter(|origin| is_valid_public_origin(origin))
        .map(str::to_owned)
}

fn is_valid_public_origin(origin: &str) -> bool {
    let Some(host_port) = origin.strip_prefix("https://") else {
        return false;
    };
    if host_port.is_empty()
        || host_port.contains('/')
        || host_port.contains('@')
        || host_port.chars().any(char::is_whitespace)
    {
        return false;
    }
    let host = host_port
        .split(':')
        .next()
        .unwrap_or_default()
        .trim_matches(['[', ']']);
    !host.is_empty()
        && host != "localhost"
        && host != "127.0.0.1"
        && host != "::1"
        && host != "wonder.invalid"
}

fn matches_public_origin(request: &Request<axum::body::Body>, public_origin: &str) -> bool {
    let origin = request
        .headers()
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok());
    if origin == Some(public_origin) {
        return true;
    }
    if origin.is_some() || request.method() != axum::http::Method::GET {
        return false;
    }

    let public_host = public_origin
        .strip_prefix("https://")
        .or_else(|| public_origin.strip_prefix("http://"));
    let request_host = request
        .headers()
        .get(header::HOST)
        .and_then(|value| value.to_str().ok());
    public_host.is_some_and(|host| request_host == Some(host))
}

async fn readyz(State(state): State<AppState>) -> Response {
    let readiness = state.ingestion.readiness(&state.store).await;
    (
        if readiness.ready {
            StatusCode::OK
        } else {
            StatusCode::SERVICE_UNAVAILABLE
        },
        Json(readiness),
    )
        .into_response()
}

async fn healthz() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "status": "ok" }))
}

fn host_display_name() -> &'static str {
    static NAME: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    NAME.get_or_init(|| {
        #[cfg(target_os = "macos")]
        if let Ok(output) = std::process::Command::new("/usr/sbin/scutil")
            .args(["--get", "ComputerName"])
            .output()
        {
            if output.status.success() {
                let name = String::from_utf8_lossy(&output.stdout).trim().to_owned();
                if !name.is_empty() {
                    return name;
                }
            }
        }
        "Mac".to_owned()
    })
}

async fn host_status(State(state): State<AppState>) -> impl IntoResponse {
    let public_origin = current_public_origin(&state).await;
    let execution = state.ingestion.readiness(&state.store).await;
    (
        [(header::CACHE_CONTROL, "no-store")],
        Json(HostStatus {
            host_name: host_display_name().to_owned(),
            api_version: "v1",
            host_epoch: state.host_epoch.clone(),
            host_installation_id: state.host_installation_id.clone(),
            state: if execution.ready {
                host_readiness_state(public_origin.as_deref())
            } else {
                "degraded"
            },
            execution,
            codex_transport: "stdio-jsonl",
            started_at: state.started_at.clone(),
            public_origin,
        }),
    )
}

async fn runtime_capabilities(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
) -> Response {
    let app_server = state.app_server.lock().await.rpc();
    let mut warnings = Vec::new();

    let apps = match app_server
        .request("app/list", serde_json::json!({ "limit": 100 }))
        .await
    {
        Ok(response) if response.error.is_none() => response
            .result
            .as_ref()
            .and_then(|result| result.get("data"))
            .and_then(serde_json::Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(runtime_app_summary)
                    .filter(|app| app.accessible)
                    .collect()
            })
            .unwrap_or_default(),
        _ => {
            warnings.push("Available Apps could not be loaded.".to_owned());
            Vec::new()
        }
    };

    let skills = match app_server
        .request(
            "skills/list",
            serde_json::json!({
                "cwds": [state.bot_home.clone()],
                "forceReload": false
            }),
        )
        .await
    {
        Ok(response) if response.error.is_none() => response
            .result
            .as_ref()
            .and_then(|result| result.get("data"))
            .and_then(serde_json::Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .flat_map(|entry| {
                        entry
                            .get("skills")
                            .and_then(serde_json::Value::as_array)
                            .into_iter()
                            .flatten()
                    })
                    .filter_map(runtime_skill_summary)
                    .filter(|skill| skill.enabled)
                    .collect()
            })
            .unwrap_or_default(),
        _ => {
            warnings.push("Available Skills could not be loaded.".to_owned());
            Vec::new()
        }
    };

    let mcp_servers = match app_server
        .request(
            "mcpServerStatus/list",
            serde_json::json!({ "limit": 100, "detail": "toolsAndAuthOnly" }),
        )
        .await
    {
        Ok(response) if response.error.is_none() => response
            .result
            .as_ref()
            .and_then(|result| result.get("data"))
            .and_then(serde_json::Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(runtime_mcp_server_summary)
                    .collect()
            })
            .unwrap_or_default(),
        _ => {
            warnings.push("MCP connection status could not be loaded.".to_owned());
            Vec::new()
        }
    };

    Json(RuntimeCapabilitiesResponse {
        apps,
        skills,
        mcp_servers,
        warnings,
        refreshed_at: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
    })
    .into_response()
}

fn runtime_app_summary(value: &serde_json::Value) -> Option<RuntimeAppSummary> {
    Some(RuntimeAppSummary {
        id: value.get("id")?.as_str()?.to_owned(),
        name: value.get("name")?.as_str()?.to_owned(),
        description: value
            .get("description")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        category: value
            .get("distributionChannel")
            .or_else(|| value.get("category"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        enabled: value
            .get("isEnabled")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(true),
        accessible: value
            .get("isAccessible")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
    })
}

fn runtime_skill_summary(value: &serde_json::Value) -> Option<RuntimeSkillSummary> {
    Some(RuntimeSkillSummary {
        name: value.get("name")?.as_str()?.to_owned(),
        description: value
            .get("shortDescription")
            .or_else(|| value.get("description"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("Available Skill")
            .to_owned(),
        enabled: value
            .get("enabled")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
        plugin_id: value
            .get("pluginId")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
    })
}

fn runtime_mcp_server_summary(value: &serde_json::Value) -> Option<RuntimeMcpServerSummary> {
    Some(RuntimeMcpServerSummary {
        name: value.get("name")?.as_str()?.to_owned(),
        plugin_id: value
            .get("pluginId")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        auth_status: value
            .get("authStatus")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("unknown")
            .to_owned(),
        runtime_status: value
            .get("runtimeStatus")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        tool_count: value
            .get("tools")
            .and_then(serde_json::Value::as_object)
            .map(serde_json::Map::len)
            .unwrap_or(0),
    })
}

fn host_readiness_state(public_origin: Option<&str>) -> &'static str {
    if public_origin.is_some() {
        "ready"
    } else {
        "degraded"
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct BotSummary {
    permission_mode: Option<String>,
    approval_mode: Option<String>,
    id: String,
    name: String,
    role: String,
    system_prompt: String,
    workspace_path: String,
    working_directory: String,
    avatar_color: Option<String>,
    avatar_shape: Option<String>,
    avatar_palette: Option<String>,
    permission_profile: String,
    model: Option<String>,
    reasoning_effort: Option<String>,
    service_tier: Option<String>,
    #[serde(rename = "isArchived")]
    archived: bool,
    conversation_id: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ConversationSummary {
    conversation_id: String,
    bot_id: Option<String>,
    title: String,
    last_message_preview: Option<String>,
    last_message_at: Option<String>,
    message_count: u64,
    delivery_state: Option<DeliveryState>,
    has_unread: bool,
    is_archived: bool,
    is_pinned: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SearchQuery {
    q: String,
    limit: Option<u32>,
    cursor: Option<String>,
    conversation_id: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SearchResultSummary {
    kind: String,
    id: String,
    title: String,
    snippet: Option<String>,
    conversation_id: Option<String>,
    bot_id: Option<String>,
    updated_at: String,
    deep_link: String,
}

fn search_result_deep_link(result: &wonder_store::StoredSearchResult) -> String {
    match result.kind.as_str() {
        "channel" => format!("#/group-chats/{}", result.id),
        "message" | "assistant_message" | "file" => result
            .conversation_id
            .as_deref()
            .map(|conversation_id| {
                format!(
                    "#/chats/{}?focus={}&kind={}",
                    conversation_id, result.id, result.kind
                )
            })
            .unwrap_or_else(|| "#/chats".into()),
        "conversation" => result
            .conversation_id
            .as_deref()
            .map(|conversation_id| format!("#/chats/{conversation_id}"))
            .unwrap_or_else(|| "#/chats".into()),
        "bot" => result
            .bot_id
            .as_deref()
            .map(|bot_id| format!("#/bots/{bot_id}"))
            .unwrap_or_else(|| "#/chats".into()),
        _ => "#/chats".into(),
    }
}

fn valid_channel_member_count(count: usize) -> bool {
    (1..=17).contains(&count)
}

fn valid_channel_description(value: Option<&str>) -> bool {
    value.is_none_or(|value| value.chars().count() <= 500)
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct CreateChannelRequest {
    client_request_id: Option<String>,
    name: String,
    description: Option<String>,
    coordinator_bot_id: String,
    member_bot_ids: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateChannelRequest {
    coordinator_bot_id: Option<String>,
    name: Option<String>,
    description: Option<Option<String>>,
    is_archived: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChannelMemberRequest {
    bot_id: String,
    role: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChannelMemberSummary {
    bot_id: String,
    bot_name: String,
    role: String,
    position: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChannelSummary {
    attachments_supported: bool,
    id: String,
    conversation_id: String,
    name: String,
    description: Option<String>,
    coordinator_bot_id: String,
    is_archived: bool,
    created_at: String,
    updated_at: String,
    members: Vec<ChannelMemberSummary>,
    messages: Vec<ChannelMessageSummary>,
    has_unread: bool,
    host_epoch: Option<String>,
    last_sequence: Option<u64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChannelMessageSummary {
    attachment_ids: Vec<String>,
    message_id: String,
    client_message_id: String,
    body: String,
    state: Option<DeliveryState>,
    created_at: String,
    body_sha256: String,
    codex_thread_id: Option<String>,
    codex_turn_id: Option<String>,
    author_kind: String,
    author_bot_id: Option<String>,
    author_bot_name: Option<String>,
    phase: String,
    presentation_kind: String,
    outcome: Option<String>,
    retryable: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateConversationRequest {
    bot_id: String,
    title: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateConversationRequest {
    title: Option<String>,
    is_archived: Option<bool>,
    is_pinned: Option<bool>,
    mark_read: Option<bool>,
    host_epoch: Option<String>,
    read_through_sequence: Option<u64>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct CreateBotRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    permission_mode: Option<permission_modes::PermissionMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    approval_mode: Option<permission_modes::ApprovalMode>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    read_roots: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    write_roots: Vec<String>,
    client_request_id: Option<String>,
    avatar_color: Option<String>,
    working_directory: Option<String>,
    name: String,
    role: String,
    system_prompt: String,
    model: Option<String>,
    reasoning_effort: Option<String>,
    service_tier: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateBotRequest {
    permission_mode: Option<permission_modes::PermissionMode>,
    approval_mode: Option<permission_modes::ApprovalMode>,
    avatar_color: Option<String>,
    avatar_shape: Option<String>,
    avatar_palette: Option<String>,
    working_directory: Option<String>,
    name: Option<String>,
    role: Option<String>,
    system_prompt: Option<String>,
    model: Option<String>,
    reasoning_effort: Option<String>,
    service_tier: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ComposerOptionsResponse {
    models: Vec<ModelOption>,
    permission_profiles: Vec<PermissionProfileOption>,
    approval_modes: Vec<permission_modes::ApprovalModeOption>,
    timezone: String,
    allowed_approval_policies: Vec<String>,
    allowed_approval_reviewers: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ConversationSettingsResponse {
    effective: EffectiveConversationSettings,
    overrides: ConversationSettingsOverrides,
    bot_defaults: EffectiveConversationSettings,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct EffectiveConversationSettings {
    model: Option<String>,
    effort: Option<String>,
    service_tier: Option<String>,
    permission_profile: String,
    approval_mode: Option<String>,
    approval_policy: &'static str,
    approvals_reviewer: &'static str,
}

#[derive(Debug, Serialize, Default)]
#[serde(rename_all = "camelCase")]
struct ConversationSettingsOverrides {
    model: Option<String>,
    effort: Option<String>,
    service_tier: Option<String>,
    permission_profile: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConversationSettingsPatch {
    model: Option<Option<String>>,
    effort: Option<Option<String>>,
    service_tier: Option<Option<String>>,
    permission_profile: Option<Option<String>>,
    #[serde(flatten)]
    action: SignedActionFields,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ConversationFileSummary {
    id: String,
    kind: String,
    name: String,
    mime_type: Option<String>,
    byte_size: Option<i64>,
    sha256: Option<String>,
    relative_path: Option<String>,
    state: String,
    additions: Option<i64>,
    deletions: Option<i64>,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateConversationFileRequest {
    client_upload_id: Option<String>,
    name: String,
    mime_type: Option<String>,
    content_base64: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AutomationSummary {
    id: String,
    name: String,
    kind: String,
    bot_id: String,
    conversation_id: Option<String>,
    prompt: String,
    rrule: String,
    timezone: String,
    status: String,
    notification_policy: String,
    model_id: Option<String>,
    reasoning_effort: Option<String>,
    scope_type: String,
    scope_id: String,
    next_run_at: Option<String>,
    last_run_at: Option<String>,
    last_attempt_at: Option<String>,
    last_success_at: Option<String>,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AutomationRunSummary {
    id: String,
    automation_id: String,
    scheduled_for: String,
    status: String,
    started_at: String,
    finished_at: Option<String>,
    error: Option<String>,
    message_id: Option<String>,
    conversation_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateAutomationRequest {
    name: String,
    kind: String,
    bot_id: String,
    conversation_id: Option<String>,
    prompt: String,
    rrule: String,
    timezone: String,
    status: Option<String>,
    notification_policy: Option<String>,
    model_id: Option<String>,
    reasoning_effort: Option<String>,
    scope_type: Option<String>,
    scope_id: Option<String>,
    client_request_id: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct UpdateAutomationRequest {
    name: Option<String>,
    prompt: Option<String>,
    kind: Option<String>,
    conversation_id: Option<String>,
    rrule: Option<String>,
    timezone: Option<String>,
    status: Option<String>,
    notification_policy: Option<String>,
    model_id: Option<String>,
    reasoning_effort: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PreviewAutomationRequest {
    rrule: String,
    timezone: String,
}

async fn preview_automation(Json(request): Json<PreviewAutomationRequest>) -> Response {
    if request.rrule.len() > 512 || request.timezone.len() > 80 {
        return (StatusCode::BAD_REQUEST, "The schedule is too long.").into_response();
    }
    match next_automation_run(request.rrule.trim(), request.timezone.trim(), Utc::now()) {
        Ok(next) => Json(serde_json::json!({"nextRunAt":next,"timezone":request.timezone.trim()}))
            .into_response(),
        Err(error) => (StatusCode::BAD_REQUEST, error).into_response(),
    }
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct RunAutomationRequest {
    client_request_id: Option<String>,
}

fn automation_request_id(prefix: &str, client_id: Option<&str>) -> Result<String, &'static str> {
    match client_id {
        Some(value) if value.trim().is_empty() || value.len() > 160 => {
            Err("The request identifier is invalid.")
        }
        Some(value) => Ok(format!(
            "{prefix}:{}",
            hex::encode(Sha256::digest(value.as_bytes()))
        )),
        None => Ok(uuid::Uuid::new_v4().to_string()),
    }
}

async fn automation_target_available(
    state: &AppState,
    bot_id: &str,
    scope_type: &str,
    scope_id: &str,
    kind: &str,
    conversation_id: Option<&str>,
) -> Result<(), (StatusCode, &'static str)> {
    let bot = state
        .store
        .bot(bot_id)
        .await
        .map_err(|_| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Bot could not be loaded.",
            )
        })?
        .ok_or((StatusCode::BAD_REQUEST, "The automation Bot was not found."))?;
    if bot.is_archived {
        return Err((
            StatusCode::CONFLICT,
            "Restore this Bot before running or enabling its automations.",
        ));
    }
    if scope_type == "group_chat" {
        let group = state
            .store
            .channel(scope_id)
            .await
            .map_err(|_| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Group Chat could not be loaded.",
                )
            })?
            .ok_or((StatusCode::BAD_REQUEST, "The Group Chat was not found."))?;
        if group.is_archived {
            return Err((
                StatusCode::CONFLICT,
                "Restore the Group Chat before enabling its automations.",
            ));
        }
        if kind != "continuation"
            || conversation_id != Some(group.conversation_id.as_str())
            || bot_id != group.coordinator_bot_id
        {
            return Err((
                StatusCode::BAD_REQUEST,
                "Group automations must continue in their Group Chat using its lead Bot.",
            ));
        }
    } else if scope_type != "bot" || scope_id != bot_id {
        return Err((StatusCode::BAD_REQUEST, "Choose a valid automation scope."));
    } else if kind == "continuation" {
        let Some(id) = conversation_id.filter(|id| !id.trim().is_empty()) else {
            return Err((
                StatusCode::BAD_REQUEST,
                "Choose a conversation to continue.",
            ));
        };
        let conversation = state.store.conversation(id).await.map_err(|_| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Conversation could not be loaded.",
            )
        })?;
        if conversation
            .as_ref()
            .is_some_and(|value| value.bot_id != bot_id || value.is_archived)
            || (conversation.is_none()
                && id != bot_id
                && bot.conversation_id.as_deref() != Some(id))
        {
            return Err((
                StatusCode::BAD_REQUEST,
                "Choose an active conversation belonging to this Bot.",
            ));
        }
    }
    Ok(())
}

fn automation_summary(automation: wonder_store::StoredAutomation) -> AutomationSummary {
    AutomationSummary {
        id: automation.id,
        name: automation.name,
        kind: automation.kind,
        bot_id: automation.bot_id,
        conversation_id: automation.conversation_id,
        prompt: automation.prompt,
        rrule: automation.rrule,
        timezone: automation.timezone,
        status: automation.status,
        notification_policy: automation.notification_policy,
        model_id: automation.model_id,
        reasoning_effort: automation.reasoning_effort,
        scope_type: automation.scope_type,
        scope_id: automation.scope_id,
        next_run_at: automation.next_run_at,
        last_run_at: automation.last_run_at,
        last_attempt_at: automation.last_attempt_at,
        last_success_at: automation.last_success_at,
        created_at: automation.created_at,
        updated_at: automation.updated_at,
    }
}

fn automation_run_summary(run: wonder_store::StoredAutomationRun) -> AutomationRunSummary {
    AutomationRunSummary {
        id: run.id,
        automation_id: run.automation_id,
        scheduled_for: run.scheduled_for,
        status: run.status,
        started_at: run.started_at,
        finished_at: run.finished_at,
        error: run.error,
        message_id: run.message_id,
        conversation_id: run.conversation_id,
    }
}

fn automation_conversation_id(
    kind: &str,
    automation_id: &str,
    requested_conversation_id: Option<&str>,
) -> Option<String> {
    if kind == "standalone" {
        Some(format!("automation:{automation_id}"))
    } else {
        requested_conversation_id.map(str::to_owned)
    }
}

async fn list_automations(State(state): State<AppState>) -> Response {
    match state.store.list_automations().await {
        Ok(automations) => Json(
            automations
                .into_iter()
                .map(automation_summary)
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "automation listing failed",
        )
            .into_response(),
    }
}

async fn create_automation(
    State(state): State<AppState>,
    Json(request): Json<CreateAutomationRequest>,
) -> Response {
    let name = request.name.trim();
    let kind = request.kind.trim();
    let prompt = request.prompt.trim();
    let timezone = request.timezone.trim();
    let rrule = request.rrule.trim();
    let status = request.status.as_deref().unwrap_or("active");
    let notification_policy = request.notification_policy.as_deref().unwrap_or("all_runs");
    if name.is_empty()
        || name.len() > 120
        || prompt.is_empty()
        || prompt.len() > 8_000
        || !matches!(kind, "continuation" | "standalone")
        || timezone.is_empty()
        || timezone.len() > 80
        || rrule.is_empty()
        || rrule.len() > 512
        || !matches!(status, "active" | "paused")
        || !matches!(notification_policy, "all_runs" | "failed_runs_only")
        || (kind == "continuation" && request.conversation_id.is_none())
    {
        return (StatusCode::BAD_REQUEST, "invalid automation").into_response();
    }
    let now_utc = Utc::now();
    let preview = match next_automation_run(rrule, timezone, now_utc) {
        Ok(next) => next,
        Err(error) => return (StatusCode::BAD_REQUEST, error).into_response(),
    };
    let next_run_at = if status == "active" { preview } else { None };
    let scope_type = request.scope_type.as_deref().unwrap_or("bot").trim();
    let scope_id = request
        .scope_id
        .as_deref()
        .unwrap_or(&request.bot_id)
        .trim();
    if !matches!(scope_type, "bot" | "group_chat") || scope_id.is_empty() {
        return (StatusCode::BAD_REQUEST, "invalid automation scope").into_response();
    }
    if scope_type == "group_chat"
        && (request.model_id.is_some() || request.reasoning_effort.is_some())
    {
        return (
            StatusCode::BAD_REQUEST,
            "Group automations use each Bot's own model settings. Edit those in Bot settings.",
        )
            .into_response();
    }
    if let Err(error) = automation_target_available(
        &state,
        &request.bot_id,
        scope_type,
        scope_id,
        kind,
        request.conversation_id.as_deref(),
    )
    .await
    {
        return error.into_response();
    }
    {
        let catalog = state.runtime_catalog.read().await;
        if let Err(error) = validate_bot_runtime_settings(
            &catalog,
            request.model_id.as_deref(),
            request.reasoning_effort.as_deref(),
            None,
        ) {
            return (StatusCode::BAD_REQUEST, error).into_response();
        }
    }
    let id = match automation_request_id("automation", request.client_request_id.as_deref()) {
        Ok(id) => id,
        Err(error) => return (StatusCode::BAD_REQUEST, error).into_response(),
    };
    match state.store.automation_by_id(&id).await {
        Ok(Some(existing)) => return Json(automation_summary(existing)).into_response(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Automation could not be loaded.",
            )
                .into_response()
        }
        Ok(None) => {}
    }
    let conversation_id = automation_conversation_id(kind, &id, request.conversation_id.as_deref());
    let now = now_utc.to_rfc3339_opts(SecondsFormat::Millis, true);
    match state
        .store
        .insert_scoped_automation(
            &id,
            name,
            kind,
            scope_type,
            scope_id,
            &request.bot_id,
            conversation_id.as_deref(),
            prompt,
            rrule,
            timezone,
            status,
            notification_policy,
            request.model_id.as_deref(),
            request.reasoning_effort.as_deref(),
            next_run_at.as_deref(),
            &now,
        )
        .await
    {
        Ok(automation) => {
            (StatusCode::CREATED, Json(automation_summary(automation))).into_response()
        }
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "automation could not be saved",
        )
            .into_response(),
    }
}

async fn update_automation(
    State(state): State<AppState>,
    Path(automation_id): Path<String>,
    Json(request): Json<UpdateAutomationRequest>,
) -> Response {
    let mut value = match state.store.automation_by_id(&automation_id).await {
        Ok(Some(value)) => value,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Automation could not be loaded.",
            )
                .into_response()
        }
    };
    if value.scope_type == "group_chat"
        && (request
            .model_id
            .as_deref()
            .is_some_and(|v| !v.trim().is_empty())
            || request
                .reasoning_effort
                .as_deref()
                .is_some_and(|v| !v.trim().is_empty()))
    {
        return (
            StatusCode::BAD_REQUEST,
            "Group automations use each Bot's own model settings. Edit those in Bot settings.",
        )
            .into_response();
    }
    let reschedule =
        request.rrule.is_some() || request.timezone.is_some() || request.status.is_some();
    macro_rules! apply {
        ($field:ident) => {
            if let Some(new) = request.$field {
                value.$field = new.trim().to_owned();
            }
        };
    }
    apply!(name);
    apply!(prompt);
    apply!(kind);
    apply!(rrule);
    apply!(timezone);
    apply!(status);
    apply!(notification_policy);
    if let Some(id) = request.conversation_id {
        value.conversation_id = Some(id);
    }
    if let Some(id) = request.model_id {
        value.model_id = (!id.trim().is_empty()).then(|| id.trim().to_owned());
    }
    if let Some(effort) = request.reasoning_effort {
        value.reasoning_effort = (!effort.trim().is_empty()).then(|| effort.trim().to_owned());
    }
    if value.name.is_empty()
        || value.name.len() > 120
        || value.prompt.is_empty()
        || value.prompt.len() > 8000
        || value.rrule.len() > 512
        || value.timezone.len() > 80
        || !matches!(value.kind.as_str(), "continuation" | "standalone")
        || !matches!(value.status.as_str(), "active" | "paused")
        || !matches!(
            value.notification_policy.as_str(),
            "all_runs" | "failed_runs_only"
        )
    {
        return (
            StatusCode::BAD_REQUEST,
            "Check the automation name, task, and schedule.",
        )
            .into_response();
    }
    if value.kind == "standalone" {
        value.conversation_id = automation_conversation_id(&value.kind, &value.id, None);
    }
    if let Err(error) = automation_target_available(
        &state,
        &value.bot_id,
        &value.scope_type,
        &value.scope_id,
        &value.kind,
        value.conversation_id.as_deref(),
    )
    .await
    {
        // Pausing remains possible when the target was archived.
        if value.status != "paused" || error.0 != StatusCode::CONFLICT {
            return error.into_response();
        }
    }
    {
        let catalog = state.runtime_catalog.read().await;
        if let Err(error) = validate_bot_runtime_settings(
            &catalog,
            value.model_id.as_deref(),
            value.reasoning_effort.as_deref(),
            None,
        ) {
            return (StatusCode::BAD_REQUEST, error).into_response();
        }
    }
    let now = Utc::now();
    let preview = match next_automation_run(&value.rrule, &value.timezone, now) {
        Ok(next) => next,
        Err(error) => return (StatusCode::BAD_REQUEST, error).into_response(),
    };
    if value.status == "paused" {
        value.next_run_at = None;
    } else if reschedule {
        value.next_run_at = preview;
    }
    value.updated_at = now.to_rfc3339_opts(SecondsFormat::Millis, true);
    match state.store.update_automation(&value).await {
        Ok(true) => Json(automation_summary(value)).into_response(),
        Ok(false) => (
            StatusCode::CONFLICT,
            "The automation changed or its Bot was archived. Refresh before saving.",
        )
            .into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "Automation could not be saved.",
        )
            .into_response(),
    }
}

async fn list_automation_runs(
    State(state): State<AppState>,
    Path(automation_id): Path<String>,
) -> Response {
    match state.store.automation_by_id(&automation_id).await {
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "automation lookup failed",
        )
            .into_response(),
        Ok(Some(_)) => match state.store.list_automation_runs(&automation_id).await {
            Ok(runs) => Json(
                runs.into_iter()
                    .map(automation_run_summary)
                    .collect::<Vec<_>>(),
            )
            .into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "automation runs could not be loaded",
            )
                .into_response(),
        },
    }
}

async fn run_automation_now(
    State(state): State<AppState>,
    Path(automation_id): Path<String>,
    request: Option<Json<RunAutomationRequest>>,
) -> Response {
    let automation = match state.store.automation_by_id(&automation_id).await {
        Ok(Some(value)) => value,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Automation could not be loaded.",
            )
                .into_response()
        }
    };
    let request = request.map(|Json(value)| value).unwrap_or_default();
    let run_id = match automation_request_id(
        &format!("run:{automation_id}"),
        request.client_request_id.as_deref(),
    ) {
        Ok(id) => id,
        Err(error) => return (StatusCode::BAD_REQUEST, error).into_response(),
    };
    match state.store.automation_run_by_id(&run_id).await {
        Ok(Some(run)) => return Json(automation_run_summary(run)).into_response(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "The run could not be loaded.",
            )
                .into_response()
        }
        Ok(None) => {}
    }
    if let Err(error) = automation_target_available(
        &state,
        &automation.bot_id,
        &automation.scope_type,
        &automation.scope_id,
        &automation.kind,
        automation.conversation_id.as_deref(),
    )
    .await
    {
        return error.into_response();
    }
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    match state.store.claim_scheduled_automation(&run_id,&automation,&now,&now,None,false).await {
        Ok(true)=>{
            let response = state.store.automation_run_by_id(&run_id).await;
            tokio::spawn(run_automation(state,automation,now,run_id));
            match response {
                Ok(Some(run))=>(StatusCode::ACCEPTED,Json(automation_run_summary(run))).into_response(),
                _=>(StatusCode::INTERNAL_SERVER_ERROR,"The run was accepted but could not be loaded. Retry with the same request identifier.").into_response(),
            }
        }
        Ok(false)=>match state.store.automation_run_by_id(&run_id).await {
            Ok(Some(run))=>Json(automation_run_summary(run)).into_response(),
            _=>(StatusCode::CONFLICT,"An automation run is already in progress, or the automation changed. Refresh and try again.").into_response(),
        },
        Err(_)=>(StatusCode::INTERNAL_SERVER_ERROR,"The automation run could not be accepted.").into_response(),
    }
}

async fn delete_automation(
    State(state): State<AppState>,
    Path(automation_id): Path<String>,
) -> Response {
    let runs = match state.store.list_automation_runs(&automation_id).await {
        Ok(runs) => runs,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Automation runs could not be checked.",
            )
                .into_response()
        }
    };
    if runs.iter().any(|run| run.status == "running") {
        return (StatusCode::CONFLICT,"Wait for this automation to finish, or stop its run in the conversation before deleting it.").into_response();
    }
    match state.store.delete_automation(&automation_id).await {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => match state.store.automation_by_id(&automation_id).await {
            Ok(Some(_)) => (
                StatusCode::CONFLICT,
                "The automation started running. Wait for it to finish before deleting it.",
            )
                .into_response(),
            Ok(None) => StatusCode::NOT_FOUND.into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Automation could not be loaded.",
            )
                .into_response(),
        },
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "automation could not be deleted",
        )
            .into_response(),
    }
}

async fn list_bots(State(state): State<AppState>) -> Response {
    match state.store.list_bots().await {
        Ok(bots) => Json(bots.into_iter().map(bot_summary).collect::<Vec<_>>()).into_response(),
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "bot listing failed").into_response(),
    }
}

fn bot_summary(bot: StoredBot) -> BotSummary {
    let working_directory = bot.execution_directory().to_owned();
    let avatar_color = bot
        .avatar_palette
        .as_deref()
        .and_then(avatar::palette)
        .map(|palette| palette.body.to_owned())
        .or_else(|| bot.avatar_color.clone());
    BotSummary {
        permission_mode: bot.permission_mode.clone(),
        approval_mode: bot.approval_mode.clone(),
        permission_profile: bot.effective_permission_profile().to_owned(),
        id: bot.id,
        name: bot.name,
        role: bot.role,
        system_prompt: bot.system_prompt,
        working_directory,
        avatar_color,
        avatar_shape: bot.avatar_shape,
        avatar_palette: bot.avatar_palette,
        workspace_path: bot.workspace_path,
        model: bot.model,
        reasoning_effort: bot.reasoning_effort,
        service_tier: bot.service_tier,
        archived: bot.is_archived,
        conversation_id: bot.conversation_id,
    }
}

async fn bot_get_endpoint(State(state): State<AppState>, Path(bot_id): Path<String>) -> Response {
    match state.store.bot(&bot_id).await {
        Ok(Some(bot)) => Json(bot_summary(bot)).into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "Bot could not be loaded").into_response(),
    }
}

fn valid_bot_field(value: &str, max_len: usize) -> bool {
    let value = value.trim();
    !value.is_empty() && value.len() <= max_len
}

async fn bot_update_endpoint(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(bot_id): Path<String>,
    Json(request): Json<UpdateBotRequest>,
) -> Response {
    if request.permission_mode.is_none()
        && request.approval_mode.is_none()
        && request.avatar_color.is_none()
        && request.avatar_shape.is_none()
        && request.avatar_palette.is_none()
        && request.working_directory.is_none()
        && request.name.is_none()
        && request.role.is_none()
        && request.system_prompt.is_none()
        && request.model.is_none()
        && request.reasoning_effort.is_none()
        && request.service_tier.is_none()
    {
        return (StatusCode::BAD_REQUEST, "No Bot fields were provided").into_response();
    }
    if request
        .name
        .as_deref()
        .is_some_and(|value| !valid_bot_field(value, 80))
        || request
            .role
            .as_deref()
            .is_some_and(|value| !valid_bot_field(value, 160))
        || request
            .system_prompt
            .as_deref()
            .is_some_and(|value| !valid_bot_field(value, 8_000))
    {
        return (StatusCode::BAD_REQUEST, "invalid Bot profile").into_response();
    }
    let clear_overrides = [
        request.model.is_some(),
        request.model.is_some() || request.reasoning_effort.is_some(),
        request.service_tier.is_some(),
    ];
    let permissions_changed = request.permission_mode.is_some()
        || request.approval_mode.is_some()
        || request.working_directory.is_some();
    let _guard = state.dispatch_lock.lock().await;
    let Ok(Some(mut current)) = state.store.bot(&bot_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    // Appearance changes are safe during work. Existing clients also echo
    // unchanged profile fields when saving an avatar, so compare their values.
    let requires_idle = request
        .name
        .as_deref()
        .is_some_and(|value| value.trim() != current.name)
        || request
            .role
            .as_deref()
            .is_some_and(|value| value.trim() != current.role)
        || request
            .system_prompt
            .as_deref()
            .is_some_and(|value| value.trim() != current.system_prompt)
        || request.working_directory.is_some();
    let existing_avatar_color = current.avatar_color.clone();
    let explicit_avatar_palette = request.avatar_palette.is_some();
    if let Err(error) = permission_modes::apply_update(&mut current, &request) {
        return (StatusCode::BAD_REQUEST, error).into_response();
    }
    if let Err(error) = bot_management::validate_edit(
        &state,
        &current,
        request.avatar_shape.as_deref(),
        request.avatar_palette.as_deref(),
        request.avatar_color.as_deref(),
        request.working_directory.as_deref(),
        requires_idle,
    )
    .await
    {
        return error.into_response();
    }

    if let Some(value) = request.name {
        current.name = value.trim().to_owned();
    }
    if let Some(value) = request.role {
        current.role = value.trim().to_owned();
    }
    if let Some(value) = request.system_prompt {
        current.system_prompt = value.trim().to_owned();
    }
    if let Some(value) = request.model {
        current.model = (!value.trim().is_empty()).then(|| value.trim().to_owned());
    }
    if let Some(value) = request.reasoning_effort {
        current.reasoning_effort = (!value.trim().is_empty()).then(|| value.trim().to_owned());
    }
    if let Some(value) = request.service_tier {
        current.service_tier = (!value.trim().is_empty()).then(|| value.trim().to_owned());
    }
    if let Some(value) = request.avatar_shape {
        current.avatar_shape = Some(value);
    }
    if let Some(value) = request.avatar_palette {
        current.avatar_palette = Some(value.clone());
        if let Some(palette) = avatar::palette(&value) {
            current.avatar_color = Some(palette.body.to_owned());
        }
    }
    if let Some(value) = request.avatar_color {
        // Legacy clients submit the displayed compatibility color on every
        // profile save. Treat an unchanged color as omission so a future
        // shape/palette ID survives an unrelated edit from an older client.
        let unchanged_legacy_echo = !explicit_avatar_palette
            && existing_avatar_color
                .as_deref()
                .is_some_and(|existing| existing.eq_ignore_ascii_case(&value));
        if !unchanged_legacy_echo {
            current.avatar_legacy_color = Some(value.clone());
            if !explicit_avatar_palette {
                current.avatar_palette =
                    avatar::palette_for_legacy_color(&value).map(str::to_owned);
            }
        }
        if let Some(palette) = current.avatar_palette.as_deref().and_then(avatar::palette) {
            current.avatar_color = Some(palette.body.to_owned());
        }
    }
    if let Some(value) = request.working_directory {
        current.working_directory = Some(value);
    }
    {
        let catalog = state.runtime_catalog.read().await;
        if let Err(message) = validate_bot_runtime_settings(
            &catalog,
            current.model.as_deref(),
            current.reasoning_effort.as_deref(),
            current.service_tier.as_deref(),
        ) {
            return (StatusCode::BAD_REQUEST, message).into_response();
        }
    }
    if (current.permission_mode.is_some() || request.approval_mode.is_some()) && permissions_changed
    {
        let access = match state.store.bot_file_access(&bot_id).await {
            Ok(access) => access,
            Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
        };
        if let Err(error) = permission_modes::validate_roots(&current, &access, &state.denied_roots)
        {
            return (StatusCode::BAD_REQUEST, error).into_response();
        }
        if let Err(error) =
            permission_modes::verify(&state, &mut *state.app_server.lock().await, &current).await
        {
            return (StatusCode::BAD_REQUEST, error).into_response();
        }
    }
    if state
        .store
        .update_managed_bot(&current, clear_overrides)
        .await
        .is_err()
    {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Could not save Bot settings. Try again.",
        )
            .into_response();
    }
    Json(bot_summary(current)).into_response()
}

async fn bot_archive_endpoint(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(bot_id): Path<String>,
) -> Response {
    bot_archive_state(&state, &bot_id, true).await
}

async fn bot_unarchive_endpoint(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(bot_id): Path<String>,
) -> Response {
    bot_archive_state(&state, &bot_id, false).await
}

async fn bot_archive_state(state: &AppState, bot_id: &str, archived: bool) -> Response {
    bot_management::archive(state, bot_id, archived).await
}

async fn bot_delete_endpoint(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(bot_id): Path<String>,
) -> Response {
    bot_management::delete(&state, &bot_id).await
}

async fn list_conversations(State(state): State<AppState>) -> Response {
    match state.store.list_conversation_summaries().await {
        Ok(conversations) => Json(
            conversations
                .into_iter()
                .map(conversation_summary)
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "conversation listing failed",
        )
            .into_response(),
    }
}

#[cfg(any())]
fn channel_summary(channel: StoredChannel) -> ChannelSummary {
    ChannelSummary {
        attachments_supported: true,
        has_unread: channel.has_unread,
        host_epoch: channel.host_epoch,
        last_sequence: channel.last_sequence,
        id: channel.id,
        conversation_id: channel.conversation_id,
        name: channel.name,
        description: channel.description,
        coordinator_bot_id: channel.coordinator_bot_id,
        is_archived: channel.is_archived,
        created_at: channel.created_at,
        updated_at: channel.updated_at,
        members: channel
            .members
            .into_iter()
            .map(|member| ChannelMemberSummary {
                bot_id: member.bot_id,
                bot_name: member.bot_name,
                role: member.role,
                position: member.position,
            })
            .collect(),
        messages: channel
            .messages
            .into_iter()
            .map(|message| ChannelMessageSummary {
                attachment_ids: message.attachment_ids,
                message_id: message.message_id,
                client_message_id: message.client_message_id,
                body: message.body,
                state: delivery_state_from_name(&message.state),
                created_at: message.created_at,
                body_sha256: message.body_sha256,
                codex_thread_id: message.codex_thread_id,
                codex_turn_id: message.codex_turn_id,
                author_kind: message.author_kind,
                author_bot_id: message.author_bot_id,
                author_bot_name: message.author_bot_name,
                phase: message.phase,
                presentation_kind: message.presentation_kind,
                outcome: message.outcome,
                retryable: message.retryable,
            })
            .collect(),
        messages: channel
            .messages
            .into_iter()
            .map(|message| ChannelMessageSummary {
                attachment_ids: message.attachment_ids,
                message_id: message.message_id,
                client_message_id: message.client_message_id,
                body: message.body,
                state: delivery_state_from_name(&message.state),
                created_at: message.created_at,
                body_sha256: message.body_sha256,
                codex_thread_id: message.codex_thread_id,
                codex_turn_id: message.codex_turn_id,
                author_kind: message.author_kind,
                author_bot_id: message.author_bot_id,
                author_bot_name: message.author_bot_name,
                phase: message.phase,
                presentation_kind: message.presentation_kind,
                outcome: message.outcome,
                retryable: message.retryable,
            })
            .collect(),
    }
}

#[cfg(any())]
mod stale_channel_handler_variants {
    fn valid_channel_name(value: &str) -> bool {
        let value = value.trim();
        !value.is_empty() && value.len() <= 80
    }

    fn valid_channel_description(value: Option<&str>) -> bool {
        value.is_none_or(|value| value.len() <= 500)
    }

    #[cfg(any())]
    async fn list_channels(State(state): State<AppState>) -> Response {
        match state.store.list_channels().await {
            Ok(channels) => Json(
                channels
                    .into_iter()
                    .map(channel_summary)
                    .collect::<Vec<_>>(),
            )
            .into_response(),
            Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "channel listing failed").into_response(),
        }
    }

    #[cfg(any())]
    async fn create_channel(
        State(state): State<AppState>,
        Json(request): Json<CreateChannelRequest>,
    ) -> Response {
        let name = request.name.trim();
        let description = request.description.as_deref().map(str::trim);
        if !valid_channel_name(name) || !valid_channel_description(description) {
            return (
                StatusCode::BAD_REQUEST,
                "invalid channel name or description",
            )
                .into_response();
        }
        let Ok(Some(coordinator)) = state.store.bot(&request.coordinator_bot_id).await else {
            return (StatusCode::NOT_FOUND, "coordinator Bot not found").into_response();
        };
        if coordinator.is_archived {
            return (StatusCode::CONFLICT, "archived Bots cannot join channels").into_response();
        }
        let mut member_ids = request.member_bot_ids.unwrap_or_default();
        if !member_ids.iter().any(|id| id == &coordinator.id) {
            member_ids.insert(0, coordinator.id.clone());
        }
        member_ids.sort();
        member_ids.dedup();
        let bots = match state.store.list_bots().await {
            Ok(bots) => bots,
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Bots could not be loaded",
                )
                    .into_response()
            }
        };
        if member_ids
            .iter()
            .any(|id| !bots.iter().any(|bot| bot.id == *id && !bot.is_archived))
        {
            return (
                StatusCode::BAD_REQUEST,
                "every channel member must be an active Bot",
            )
                .into_response();
        }
        let id = uuid::Uuid::new_v4().to_string();
        let conversation_id = format!("channel:{id}");
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        let members = member_ids
            .iter()
            .map(|member_id| {
                (
                    member_id.as_str(),
                    if member_id == &coordinator.id {
                        "coordinator"
                    } else {
                        "worker"
                    },
                )
            })
            .collect::<Vec<_>>();
        match state
            .store
            .create_channel(
                &id,
                &conversation_id,
                name,
                description.filter(|value| !value.is_empty()),
                &coordinator.id,
                &members,
                &now,
            )
            .await
        {
            Ok(channel) => (StatusCode::CREATED, Json(channel_summary(channel))).into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be created",
            )
                .into_response(),
        }
    }

    #[cfg(any())]
    async fn get_channel(
        State(state): State<AppState>,
        Path(channel_id): Path<String>,
    ) -> Response {
        match state.store.channel(&channel_id).await {
            Ok(Some(channel)) => Json(channel_summary(channel)).into_response(),
            Ok(None) => StatusCode::NOT_FOUND.into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be loaded",
            )
                .into_response(),
        }
    }

    #[cfg(any())]
    async fn update_channel(
        State(state): State<AppState>,
        Path(channel_id): Path<String>,
        Json(request): Json<UpdateChannelRequest>,
    ) -> Response {
        if request.name.is_none() && request.description.is_none() && request.is_archived.is_none()
        {
            return (StatusCode::BAD_REQUEST, "no channel fields were provided").into_response();
        }
        let name = request.name.as_deref().map(str::trim);
        let description = request
            .description
            .as_ref()
            .map(|value| value.as_deref().map(str::trim));
        if name.is_some_and(|name| !valid_channel_name(name))
            || !valid_channel_description(description.flatten())
            || description.flatten().is_some_and(|value| value.is_empty())
        {
            return (
                StatusCode::BAD_REQUEST,
                "invalid channel name or description",
            )
                .into_response();
        }
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        match state
            .store
            .update_channel(&channel_id, name, description, request.is_archived, &now)
            .await
        {
            Ok(true) => match state.store.channel(&channel_id).await {
                Ok(Some(channel)) => Json(channel_summary(channel)).into_response(),
                _ => (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "channel could not be loaded",
                )
                    .into_response(),
            },
            Ok(false) => StatusCode::NOT_FOUND.into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be updated",
            )
                .into_response(),
        }
    }

    #[cfg(any())]
    async fn delete_channel(
        State(state): State<AppState>,
        Path(channel_id): Path<String>,
    ) -> Response {
        match state.store.delete_channel(&channel_id).await {
            Ok(true) => StatusCode::NO_CONTENT.into_response(),
            Ok(false) => StatusCode::NOT_FOUND.into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be deleted",
            )
                .into_response(),
        }
    }

    #[cfg(any())]
    async fn list_channel_members(
        State(state): State<AppState>,
        Path(channel_id): Path<String>,
    ) -> Response {
        if !matches!(state.store.channel(&channel_id).await, Ok(Some(_))) {
            return StatusCode::NOT_FOUND.into_response();
        }
        match state.store.channel_members(&channel_id).await {
            Ok(members) => Json(
                members
                    .into_iter()
                    .map(|member| ChannelMemberSummary {
                        bot_id: member.bot_id,
                        bot_name: member.bot_name,
                        role: member.role,
                        position: member.position,
                    })
                    .collect::<Vec<_>>(),
            )
            .into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel members could not be loaded",
            )
                .into_response(),
        }
    }

    #[cfg(any())]
    async fn add_channel_member(
        State(state): State<AppState>,
        Path(channel_id): Path<String>,
        Json(request): Json<ChannelMemberRequest>,
    ) -> Response {
        let Ok(Some(channel)) = state.store.channel(&channel_id).await else {
            return StatusCode::NOT_FOUND.into_response();
        };
        let role = request.role.as_deref().unwrap_or("worker");
        if role != "worker" {
            return (StatusCode::BAD_REQUEST, "only worker members may be added").into_response();
        }
        let Ok(Some(bot)) = state.store.bot(&request.bot_id).await else {
            return (StatusCode::NOT_FOUND, "Bot not found").into_response();
        };
        if bot.is_archived || bot.id == channel.coordinator_bot_id {
            return (StatusCode::CONFLICT, "Bot cannot be added to this channel").into_response();
        }
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        match state
            .store
            .add_channel_member(&channel_id, &bot.id, role, &now)
            .await
        {
            Ok(true) => match state.store.channel(&channel_id).await {
                Ok(Some(channel)) => {
                    (StatusCode::CREATED, Json(channel_summary(channel))).into_response()
                }
                _ => (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "channel could not be loaded",
                )
                    .into_response(),
            },
            Ok(false) => (StatusCode::CONFLICT, "Bot is already a channel member").into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel member could not be added",
            )
                .into_response(),
        }
    }

    #[cfg(any())]
    async fn remove_channel_member(
        State(state): State<AppState>,
        Path((channel_id, bot_id)): Path<(String, String)>,
    ) -> Response {
        if state
            .store
            .channel(&channel_id)
            .await
            .ok()
            .flatten()
            .is_none()
        {
            return StatusCode::NOT_FOUND.into_response();
        }
        match state
            .store
            .remove_channel_member(&channel_id, &bot_id)
            .await
        {
            Ok(true) => StatusCode::NO_CONTENT.into_response(),
            Ok(false) => (
                StatusCode::CONFLICT,
                "the coordinator cannot be removed or Bot is not a member",
            )
                .into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel member could not be removed",
            )
                .into_response(),
        }
    }

    async fn search_endpoint(
        State(state): State<AppState>,
        Query(query): Query<SearchQuery>,
    ) -> Response {
        let query_text = query.q.trim();
        if query_text.is_empty() || query_text.len() > 256 {
            return (StatusCode::BAD_REQUEST, "search query must be 1-256 bytes").into_response();
        }
        match state
            .store
            .search(query_text, query.limit.unwrap_or(30))
            .await
        {
            Ok(results) => Json(
                results
                    .into_iter()
                    .map(|result| {
                        let deep_link = search_result_deep_link(&result);
                        SearchResultSummary {
                            kind: result.kind,
                            id: result.id,
                            title: result.title,
                            snippet: result.snippet,
                            conversation_id: result.conversation_id,
                            bot_id: result.bot_id,
                            updated_at: result.updated_at,
                            deep_link,
                        }
                    })
                    .collect::<Vec<_>>(),
            )
            .into_response(),
            Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "search failed").into_response(),
        }
    }

    #[cfg(any())]
    mod duplicate_channel_handlers {
        #[cfg(any())]
        fn valid_channel_name(value: &str) -> bool {
            let value = value.trim();
            !value.is_empty() && value.len() <= 80
        }
    }

    fn channel_summary(channel: StoredChannel) -> ChannelSummary {
        ChannelSummary {
            attachments_supported: true,
            id: channel.id,
            conversation_id: channel.conversation_id,
            name: channel.name,
            description: channel.description,
            coordinator_bot_id: channel.coordinator_bot_id,
            is_archived: channel.is_archived,
            created_at: channel.created_at,
            updated_at: channel.updated_at,
            members: channel
                .members
                .into_iter()
                .map(|member| ChannelMemberSummary {
                    bot_id: member.bot_id,
                    bot_name: member.bot_name,
                    role: member.role,
                    position: member.position,
                })
                .collect(),
        }
    }

    async fn list_channels(State(state): State<AppState>) -> Response {
        match state.store.list_channels().await {
            Ok(channels) => Json(
                channels
                    .into_iter()
                    .map(channel_summary)
                    .collect::<Vec<_>>(),
            )
            .into_response(),
            Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "channel listing failed").into_response(),
        }
    }

    async fn create_channel(
        State(state): State<AppState>,
        Json(request): Json<CreateChannelRequest>,
    ) -> Response {
        let name = request.name.trim();
        if !valid_channel_name(name)
            || request
                .description
                .as_deref()
                .is_some_and(|description| description.len() > 500)
        {
            return (
                StatusCode::BAD_REQUEST,
                "invalid channel name or description",
            )
                .into_response();
        }
        let bots = match state.store.list_bots().await {
            Ok(bots) => bots,
            Err(_) => {
                return (StatusCode::INTERNAL_SERVER_ERROR, "Bot listing failed").into_response()
            }
        };
        let Some(coordinator) = bots
            .iter()
            .find(|bot| bot.id == request.coordinator_bot_id && !bot.is_archived)
        else {
            return (StatusCode::BAD_REQUEST, "coordinator Bot was not found").into_response();
        };
        let mut member_bot_ids = vec![(coordinator.id.as_str(), "coordinator")];
        let mut seen = std::collections::HashSet::from([coordinator.id.as_str()]);
        for bot_id in request.member_bot_ids.unwrap_or_default() {
            if !seen.insert(bot_id.as_str()) {
                continue;
            }
            let Some(bot) = bots.iter().find(|bot| bot.id == bot_id && !bot.is_archived) else {
                return (StatusCode::BAD_REQUEST, "channel member Bot was not found")
                    .into_response();
            };
            member_bot_ids.push((bot.id.as_str(), "worker"));
        }
        if member_bot_ids.len() > 17 {
            return (
                StatusCode::BAD_REQUEST,
                "a channel can have at most 16 worker Bots",
            )
                .into_response();
        }
        let id = uuid::Uuid::new_v4().to_string();
        let conversation_id = uuid::Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        let channel = match state
            .store
            .create_channel(
                &id,
                &conversation_id,
                name,
                request.description.as_deref().map(str::trim),
                &coordinator.id,
                &member_bot_ids,
                &now,
            )
            .await
        {
            Ok(channel) => channel,
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "channel could not be created",
                )
                    .into_response()
            }
        };
        (StatusCode::CREATED, Json(channel_summary(channel))).into_response()
    }

    async fn get_channel(
        State(state): State<AppState>,
        Path(channel_id): Path<String>,
    ) -> Response {
        match state.store.channel(&channel_id).await {
            Ok(Some(channel)) => Json(channel_summary(channel)).into_response(),
            Ok(None) => StatusCode::NOT_FOUND.into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be loaded",
            )
                .into_response(),
        }
    }

    async fn update_channel(
        State(state): State<AppState>,
        Path(channel_id): Path<String>,
        Json(request): Json<UpdateChannelRequest>,
    ) -> Response {
        if request.name.is_none() && request.description.is_none() && request.is_archived.is_none()
        {
            return (StatusCode::BAD_REQUEST, "no channel changes supplied").into_response();
        }
        if request
            .name
            .as_deref()
            .is_some_and(|name| !valid_channel_name(name))
            || request
                .description
                .as_ref()
                .and_then(|description| description.as_deref())
                .is_some_and(|description| description.len() > 500)
        {
            return (
                StatusCode::BAD_REQUEST,
                "invalid channel name or description",
            )
                .into_response();
        }
        let changed = match state
            .store
            .update_channel(
                &channel_id,
                request.name.as_deref().map(str::trim),
                request
                    .description
                    .as_ref()
                    .map(|description| description.as_deref().map(str::trim)),
                request.is_archived,
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            )
            .await
        {
            Ok(changed) => changed,
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "channel could not be updated",
                )
                    .into_response()
            }
        };
        if !changed {
            return StatusCode::NOT_FOUND.into_response();
        }
        match state.store.channel(&channel_id).await {
            Ok(Some(channel)) => Json(channel_summary(channel)).into_response(),
            Ok(None) => StatusCode::NOT_FOUND.into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be loaded",
            )
                .into_response(),
        }
    }

    async fn delete_channel(
        State(state): State<AppState>,
        Path(channel_id): Path<String>,
    ) -> Response {
        match state.store.delete_channel(&channel_id).await {
            Ok(true) => StatusCode::NO_CONTENT.into_response(),
            Ok(false) => StatusCode::NOT_FOUND.into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be deleted",
            )
                .into_response(),
        }
    }

    async fn list_channel_members(
        State(state): State<AppState>,
        Path(channel_id): Path<String>,
    ) -> Response {
        if !matches!(state.store.channel(&channel_id).await, Ok(Some(_))) {
            return StatusCode::NOT_FOUND.into_response();
        }
        match state.store.channel_members(&channel_id).await {
            Ok(members) => Json(
                members
                    .into_iter()
                    .map(|member| ChannelMemberSummary {
                        bot_id: member.bot_id,
                        bot_name: member.bot_name,
                        role: member.role,
                        position: member.position,
                    })
                    .collect::<Vec<_>>(),
            )
            .into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel members could not be loaded",
            )
                .into_response(),
        }
    }

    async fn add_channel_member(
        State(state): State<AppState>,
        Path(channel_id): Path<String>,
        Json(request): Json<ChannelMemberRequest>,
    ) -> Response {
        let Some(channel) = (match state.store.channel(&channel_id).await {
            Ok(channel) => channel,
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "channel could not be loaded",
                )
                    .into_response()
            }
        }) else {
            return StatusCode::NOT_FOUND.into_response();
        };
        if request.bot_id == channel.coordinator_bot_id {
            return (
                StatusCode::BAD_REQUEST,
                "the coordinator is already a channel member",
            )
                .into_response();
        }
        let role = request.role.as_deref().unwrap_or("worker");
        if role != "worker" {
            return (
                StatusCode::BAD_REQUEST,
                "channel members must have the worker role",
            )
                .into_response();
        }
        let Ok(Some(bot)) = state.store.bot(&request.bot_id).await else {
            return (StatusCode::BAD_REQUEST, "channel member Bot was not found").into_response();
        };
        if bot.is_archived {
            return (StatusCode::CONFLICT, "archived Bots cannot join a channel").into_response();
        }
        let added = match state
            .store
            .add_channel_member(
                &channel_id,
                &request.bot_id,
                role,
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            )
            .await
        {
            Ok(added) => added,
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "channel member could not be added",
                )
                    .into_response()
            }
        };
        if !added {
            return (StatusCode::CONFLICT, "Bot is already a channel member").into_response();
        }
        match state.store.channel(&channel_id).await {
            Ok(Some(channel)) => {
                (StatusCode::CREATED, Json(channel_summary(channel))).into_response()
            }
            Ok(None) => StatusCode::NOT_FOUND.into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be loaded",
            )
                .into_response(),
        }
    }

    async fn remove_channel_member(
        State(state): State<AppState>,
        Path((channel_id, bot_id)): Path<(String, String)>,
    ) -> Response {
        if !matches!(state.store.channel(&channel_id).await, Ok(Some(_))) {
            return StatusCode::NOT_FOUND.into_response();
        }
        match state
            .store
            .remove_channel_member(&channel_id, &bot_id)
            .await
        {
            Ok(true) => StatusCode::NO_CONTENT.into_response(),
            Ok(false) => (StatusCode::CONFLICT, "coordinators cannot be removed").into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel member could not be removed",
            )
                .into_response(),
        }
    }
}

async fn search_endpoint(
    State(state): State<AppState>,
    Extension(_): Extension<OwnerAuthority>,
    Query(query): Query<SearchQuery>,
) -> Response {
    let query_text = query.q.trim();
    let scope = query.conversation_id.as_deref();
    if query_text.is_empty()
        || query_text.len() > 256
        || query.limit.is_some_and(|n| n == 0 || n > 100)
        || scope.is_some_and(|s| s.is_empty() || s.len() > 256)
    {
        return (
            StatusCode::BAD_REQUEST,
            "Use a 1-256 byte query and page limit of 1-100.",
        )
            .into_response();
    }
    type Cursor = (
        u8,
        String,
        String,
        Option<String>,
        wonder_store::SearchCursor,
    );
    let before = match query.cursor.as_deref() {
        None => None,
        Some(cursor) => {
            let decoded = (cursor.len() <= 4096)
                .then(|| {
                    base64::engine::general_purpose::URL_SAFE_NO_PAD
                        .decode(cursor)
                        .ok()
                })
                .flatten()
                .and_then(|bytes| serde_json::from_slice::<Cursor>(&bytes).ok());
            match decoded {
                Some((1, epoch, q, conversation, before))
                    if epoch == state.host_epoch
                        && q == query_text
                        && conversation.as_deref() == scope =>
                {
                    Some(before)
                }
                _ => {
                    return (
                        StatusCode::BAD_REQUEST,
                        "Invalid search cursor. Search again.",
                    )
                        .into_response()
                }
            }
        }
    };
    match state
        .store
        .search_page(
            query_text,
            scope,
            before.as_ref(),
            query.limit.unwrap_or(30),
        )
        .await
    {
        Ok(page) => {
            let next_cursor = page.next_cursor.map(|cursor| {
                base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
                    serde_json::to_vec(&(1, &state.host_epoch, query_text, scope, cursor)).unwrap(),
                )
            });
            let results = page
                .results
                .into_iter()
                .map(|result| {
                    let deep_link = search_result_deep_link(&result);
                    SearchResultSummary {
                        kind: result.kind,
                        id: result.id,
                        title: result.title,
                        snippet: result.snippet,
                        conversation_id: result.conversation_id,
                        bot_id: result.bot_id,
                        updated_at: result.updated_at,
                        deep_link,
                    }
                })
                .collect::<Vec<_>>();
            Json(serde_json::json!({"results":results,"nextCursor":next_cursor})).into_response()
        }
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "Search failed. Try again.",
        )
            .into_response(),
    }
}

fn channel_summary(channel: StoredChannel) -> ChannelSummary {
    ChannelSummary {
        attachments_supported: true,
        has_unread: channel.has_unread,
        host_epoch: channel.host_epoch,
        last_sequence: channel.last_sequence,
        id: channel.id,
        conversation_id: channel.conversation_id,
        name: channel.name,
        description: channel.description,
        coordinator_bot_id: channel.coordinator_bot_id,
        is_archived: channel.is_archived,
        created_at: channel.created_at,
        updated_at: channel.updated_at,
        members: channel
            .members
            .into_iter()
            .map(|member| ChannelMemberSummary {
                bot_id: member.bot_id,
                bot_name: member.bot_name,
                role: member.role,
                position: member.position,
            })
            .collect(),
        messages: channel
            .messages
            .into_iter()
            .map(|message| ChannelMessageSummary {
                attachment_ids: message.attachment_ids,
                message_id: message.message_id,
                client_message_id: message.client_message_id,
                body: message.body,
                state: delivery_state_from_name(&message.state),
                created_at: message.created_at,
                body_sha256: message.body_sha256,
                codex_thread_id: message.codex_thread_id,
                codex_turn_id: message.codex_turn_id,
                author_kind: message.author_kind,
                author_bot_id: message.author_bot_id,
                author_bot_name: message.author_bot_name,
                phase: message.phase,
                presentation_kind: message.presentation_kind,
                outcome: message.outcome,
                retryable: message.retryable,
            })
            .collect(),
    }
}

async fn list_channels(State(state): State<AppState>) -> Response {
    match state.store.list_channels().await {
        Ok(channels) => {
            let mut values = Vec::new();
            for channel in channels {
                values.push(group_collaboration::summary(&state, channel).await);
            }
            Json(values).into_response()
        }
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}
async fn get_channel(State(state): State<AppState>, Path(channel_id): Path<String>) -> Response {
    match state.store.channel(&channel_id).await {
        Ok(Some(channel)) => {
            Json(group_collaboration::summary(&state, channel).await).into_response()
        }
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GroupReadAcknowledgement {
    host_epoch: String,
    read_through_sequence: u64,
}

async fn acknowledge_group_read(
    State(state): State<AppState>,
    Path(channel_id): Path<String>,
    Json(request): Json<GroupReadAcknowledgement>,
) -> Response {
    if request.host_epoch != state.host_epoch {
        return (
            StatusCode::BAD_REQUEST,
            "Reload the Group Chat before marking it read.",
        )
            .into_response();
    }
    let channel = match state.store.channel(&channel_id).await {
        Ok(Some(channel)) => channel,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Group Chat is unavailable.",
            )
                .into_response()
        }
    };
    if state
        .store
        .acknowledge_conversation_read(
            &channel.conversation_id,
            &request.host_epoch,
            request.read_through_sequence,
            &now_ms().to_string(),
        )
        .await
        .is_err()
    {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Couldn’t save read progress.",
        )
            .into_response();
    }
    get_channel(State(state), Path(channel_id)).await
}

async fn create_channel(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Json(request): Json<CreateChannelRequest>,
) -> Response {
    let _guard = state.dispatch_lock.lock().await;
    let id = request
        .client_request_id
        .clone()
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    if request.client_request_id.is_some() {
        if uuid::Uuid::parse_str(&id).is_err() {
            return (StatusCode::BAD_REQUEST, "Invalid Group creation request.").into_response();
        }
        let hash = hex::encode(Sha256::digest(
            serde_json::to_vec(&request).unwrap_or_default(),
        ));
        match state.store.reserve_group_creation(&id, &hash).await {
            Ok(true) => {}
            Ok(false) => {
                return (
                    StatusCode::CONFLICT,
                    "This request already has different Group settings.",
                )
                    .into_response()
            }
            Err(_) => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Could not save the Group creation request.",
                )
                    .into_response()
            }
        }
        if let Ok(Some(group)) = state.store.channel(&id).await {
            return Json(channel_summary(group)).into_response();
        }
    }
    let name = request.name.trim();
    if name.is_empty() || name.len() > 80 {
        return (StatusCode::BAD_REQUEST, "channel name must be 1-80 bytes").into_response();
    }
    let description = request.description.as_deref().map(str::trim);
    if !valid_channel_description(description) {
        return (
            StatusCode::BAD_REQUEST,
            "channel description must be at most 500 characters",
        )
            .into_response();
    }
    let coordinator_id = request.coordinator_bot_id.trim();
    let coordinator = match state.store.bot(coordinator_id).await {
        Ok(Some(bot)) if !bot.is_archived => bot,
        Ok(Some(_)) => {
            return (
                StatusCode::CONFLICT,
                "archived Bots cannot coordinate Group Chats",
            )
                .into_response()
        }
        Ok(None) => {
            return (StatusCode::NOT_FOUND, "coordinator Bot was not found").into_response()
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "coordinator Bot lookup failed",
            )
                .into_response()
        }
    };
    let mut member_ids = vec![coordinator.id.clone()];
    for member_id in request.member_bot_ids.unwrap_or_default() {
        let member_id = member_id.trim().to_owned();
        if !member_id.is_empty() && !member_ids.contains(&member_id) {
            member_ids.push(member_id);
        }
    }
    if member_ids.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            "a Group Chat requires at least one Bot",
        )
            .into_response();
    }
    if !valid_channel_member_count(member_ids.len()) {
        return (
            StatusCode::BAD_REQUEST,
            "a Group Chat supports one coordinator and up to sixteen additional Bots",
        )
            .into_response();
    }
    for member_id in &member_ids[1..] {
        match state.store.bot(member_id).await {
            Ok(Some(bot)) if !bot.is_archived => {}
            Ok(Some(_)) => {
                return (
                    StatusCode::CONFLICT,
                    "archived Bots cannot join a Group Chat",
                )
                    .into_response()
            }
            Ok(None) => {
                return (StatusCode::NOT_FOUND, "Group Chat member Bot was not found")
                    .into_response()
            }
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Group Chat member lookup failed",
                )
                    .into_response()
            }
        }
    }
    let member_roles = member_ids
        .iter()
        .enumerate()
        .map(|(index, id)| {
            (
                id.as_str(),
                if index == 0 { "coordinator" } else { "worker" },
            )
        })
        .collect::<Vec<_>>();
    let conversation_id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    match state
        .store
        .create_channel(
            &id,
            &conversation_id,
            name,
            description.filter(|value| !value.is_empty()),
            &coordinator.id,
            &member_roles,
            &now,
        )
        .await
    {
        Ok(channel) => (StatusCode::CREATED, Json(channel_summary(channel))).into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "channel could not be created",
        )
            .into_response(),
    }
}

async fn update_channel(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(channel_id): Path<String>,
    Json(request): Json<UpdateChannelRequest>,
) -> Response {
    if request
        .name
        .as_deref()
        .is_some_and(|name| name.trim().is_empty() || name.trim().len() > 80)
    {
        return (StatusCode::BAD_REQUEST, "channel name must be 1-80 bytes").into_response();
    }
    let description = request
        .description
        .as_ref()
        .map(|description| description.as_deref().map(str::trim));
    if !valid_channel_description(description.flatten())
        || description.flatten().is_some_and(|value| value.is_empty())
    {
        return (
            StatusCode::BAD_REQUEST,
            "channel description must be at most 500 characters",
        )
            .into_response();
    }
    let _guard = state.dispatch_lock.lock().await;
    if let Some(lead) = request.coordinator_bot_id.as_deref() {
        match state.store.change_group_lead(&channel_id, lead).await {
            Ok(true) => {}
            Ok(false) => {
                return (
                    StatusCode::CONFLICT,
                    "Choose an active Group member after current Group work finishes.",
                )
                    .into_response()
            }
            Err(_) => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Could not change the Group lead.",
                )
                    .into_response()
            }
        }
    }
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let changed = match state
        .store
        .update_channel(
            &channel_id,
            request.name.as_deref().map(str::trim),
            description,
            request.is_archived,
            &now,
        )
        .await
    {
        Ok(changed) => changed,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be updated",
            )
                .into_response()
        }
    };
    if !changed {
        return StatusCode::NOT_FOUND.into_response();
    }
    match state.store.channel(&channel_id).await {
        Ok(Some(channel)) => Json(channel_summary(channel)).into_response(),
        _ => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "channel could not be loaded",
        )
            .into_response(),
    }
}

async fn delete_channel(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(channel_id): Path<String>,
) -> Response {
    let _guard = state.dispatch_lock.lock().await;
    match state.store.delete_channel(&channel_id).await {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => match state.store.channel(&channel_id).await {
            Ok(Some(_)) => (
                StatusCode::CONFLICT,
                "Finish or stop this Group Chat's work and automations before deleting it.",
            )
                .into_response(),
            Ok(None) => StatusCode::NOT_FOUND.into_response(),
            Err(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Group Chat could not be loaded.",
            )
                .into_response(),
        },
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "channel could not be deleted",
        )
            .into_response(),
    }
}

async fn list_channel_members(
    State(state): State<AppState>,
    Path(channel_id): Path<String>,
) -> Response {
    match state.store.channel(&channel_id).await {
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be loaded",
            )
                .into_response()
        }
        Ok(Some(_)) => {}
    }
    match state.store.channel_members(&channel_id).await {
        Ok(members) => Json(
            members
                .into_iter()
                .map(|member| ChannelMemberSummary {
                    bot_id: member.bot_id,
                    bot_name: member.bot_name,
                    role: member.role,
                    position: member.position,
                })
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "channel members could not be loaded",
        )
            .into_response(),
    }
}

async fn add_channel_member(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(channel_id): Path<String>,
    Json(request): Json<ChannelMemberRequest>,
) -> Response {
    let role = request.role.as_deref().unwrap_or("worker");
    if role != "worker" {
        return (StatusCode::BAD_REQUEST, "only worker members can be added").into_response();
    }
    let Some(channel) = state.store.channel(&channel_id).await.ok().flatten() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if !valid_channel_member_count(channel.members.len() + 1) {
        return (StatusCode::CONFLICT, "channel member limit reached").into_response();
    }
    match state.store.bot(request.bot_id.trim()).await {
        Ok(Some(bot)) if bot.is_archived => {
            return (StatusCode::CONFLICT, "archived Bots cannot join a channel").into_response()
        }
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, "Bot lookup failed").into_response(),
        Ok(Some(_)) => {}
    }
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    match state
        .store
        .add_channel_member(&channel_id, request.bot_id.trim(), role, &now)
        .await
    {
        Ok(true) => match state.store.channel(&channel_id).await {
            Ok(Some(channel)) => Json(channel_summary(channel)).into_response(),
            _ => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be loaded",
            )
                .into_response(),
        },
        Ok(false) => (StatusCode::CONFLICT, "Bot is already a channel member").into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "channel member could not be added",
        )
            .into_response(),
    }
}

async fn remove_channel_member(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path((channel_id, bot_id)): Path<(String, String)>,
) -> Response {
    if group_collaboration::enabled(&state, &channel_id).await {
        return match state
            .store
            .remove_collaboration_member(&channel_id, &bot_id)
            .await
        {
            Ok(true) => StatusCode::NO_CONTENT.into_response(),
            Ok(false) => {
                (StatusCode::CONFLICT, "Keep at least one Bot in this group.").into_response()
            }
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        };
    }
    match state
        .store
        .remove_channel_member(&channel_id, &bot_id)
        .await
    {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => (StatusCode::CONFLICT, "the coordinator cannot be removed").into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "channel member could not be removed",
        )
            .into_response(),
    }
}

async fn send_channel_message(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(channel_id): Path<String>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
    local_authority: Option<Extension<LocalOwnerAuthority>>,
    Json(request): Json<SendMessageRequest>,
) -> Response {
    if request.device_id == "wonder-desktop" {
        if local_authority.is_none() {
            return StatusCode::FORBIDDEN.into_response();
        }
        if state
            .store
            .ensure_local_desktop(&now_ms().to_string())
            .await
            .is_err()
        {
            return StatusCode::SERVICE_UNAVAILABLE.into_response();
        }
    }
    // Serialize Group acceptance with deletion through its attribution commit.
    let _guard = state.dispatch_lock.lock().await;
    let channel = match state.store.channel(&channel_id).await {
        Ok(Some(channel)) => channel,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel could not be loaded",
            )
                .into_response()
        }
    };
    if channel.is_archived {
        return (
            StatusCode::CONFLICT,
            "archived channels cannot receive messages",
        )
            .into_response();
    }
    if let Some(settings) = &request.group_routing {
        if let Err(e) = group_collaboration::accept_settings(
            &state,
            &channel.id,
            &request.device_id,
            &request.client_message_id,
            settings,
        )
        .await
        {
            return (StatusCode::BAD_REQUEST, e).into_response();
        }
    }
    let direct_target = if group_collaboration::enabled(&state, &channel.id).await {
        None
    } else {
        match resolve_channel_route(&request.body, &channel.members) {
            Ok(ChannelRoute::Broadcast) => None,
            Ok(ChannelRoute::Direct(bot_id)) => Some(bot_id),
            Err(error) => return (StatusCode::BAD_REQUEST, error).into_response(),
        }
    };
    // The channel attribution transaction creates the durable run. The
    // dispatcher consumes it independently of this HTTP request.
    let _ = direct_target;
    let response = send_message_inner(
        State(state.clone()),
        Path(channel.conversation_id),
        authenticated_device,
        Json(request),
        Some(&channel.id),
    )
    .await;
    if response.status().is_success() && group_collaboration::enabled(&state, &channel.id).await {
        let _ = state
            .store
            .dismiss_group_initialization_questions(&channel.id)
            .await;
    }
    response
}

async fn orchestrate_channel_message(
    state: AppState,
    channel: wonder_store::StoredChannel,
    parent_message: wonder_store::StoredMessage,
    body: String,
    direct_target: Option<String>,
) -> Option<String> {
    let channel_id = channel.id.clone();
    if direct_target.as_deref().is_some_and(|target_bot_id| {
        channel
            .members
            .iter()
            .find(|member| member.bot_id == target_bot_id)
            .is_some_and(|member| member.role == "coordinator")
    }) {
        let target_bot_id = direct_target.as_deref().unwrap_or_default();
        state
            .store
            .plan_group_node(
                &parent_message,
                &parent_message.client_message_id,
                target_bot_id,
                "direct",
            )
            .await
            .ok()?;
        dispatch_to_codex_inner(
            state.clone(),
            parent_message.clone(),
            Some(target_bot_id.to_owned()),
            None,
        )
        .await;
        let terminal_state = wait_for_message_terminal(&state, &parent_message.id).await;
        if terminal_state.as_deref() != Some("completed") {
            return None;
        }
        let parent_turn_id = state
            .store
            .message_by_id(&parent_message.id)
            .await
            .ok()
            .flatten()
            .and_then(|message| message.codex_turn_id);
        let output = state
            .store
            .assistant_messages_for_conversation(&channel.conversation_id)
            .await
            .ok()
            .and_then(|messages| {
                messages.into_iter().rev().find(|message| {
                    message.state == "completed"
                        && parent_turn_id.as_deref() == Some(message.codex_turn_id.as_str())
                })
            })
            .map(|message| message.text)
            .filter(|text| !text.trim().is_empty())?;
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        let output_id = deterministic_uuid(&format!(
            "wonder-channel-direct-output:{}:{}",
            parent_message.id, target_bot_id
        ));
        let output_sha256 = hex::encode(Sha256::digest(output.as_bytes()));
        let Ok(MessageInsert::Inserted(output_message) | MessageInsert::Existing(output_message)) =
            state
                .store
                .insert_message(
                    &parent_message.device_id,
                    &output_id,
                    &output,
                    &output_sha256,
                    &channel.conversation_id,
                    &now,
                )
                .await
        else {
            return None;
        };
        if state
            .store
            .add_channel_message(NewChannelMessage {
                channel_id: &channel_id,
                message_id: &output_message.id,
                author_kind: "coordinator",
                author_bot_id: Some(target_bot_id),
                phase: "direct",
                created_at: &now,
                presentation_kind: "message",
                outcome: Some("completed"),
                retryable: false,
            })
            .await
            .is_err()
        {
            return None;
        }
        let _ = publish_event_with_context(
            &state,
            WonderEvent::Activity {
                category: "channel".into(),
                state: "completed".into(),
                detail: Some("Group Chat updated".into()),
            },
            EventContext {
                conversation_id: Some(channel.conversation_id),
                ..EventContext::default()
            },
        )
        .await;
        return Some(output_message.id);
    }
    let workers = channel
        .members
        .iter()
        .filter(|member| {
            member.role == "worker"
                && direct_target
                    .as_deref()
                    .is_none_or(|target| target == member.bot_id)
        })
        .cloned()
        .collect::<Vec<_>>();
    let history = channel
        .messages
        .iter()
        .map(|message| {
            let author = message.author_bot_name.as_deref().unwrap_or("User");
            format!("{author}: {}", message.body)
        })
        .collect::<Vec<_>>()
        .join("\n\n");
    let context = if history.is_empty() {
        String::new()
    } else {
        format!(
            "Recent Group Chat messages (conversation context):\n{history}\n\nCurrent message:\n"
        )
    };
    let channel_name = channel.name.clone();
    let mut worker_jobs = tokio::task::JoinSet::new();
    let mut direct_output_id = None;
    for worker in workers {
        let state = state.clone();
        let channel_id = channel_id.clone();
        let parent_message = parent_message.clone();
        let body = body.clone();
        let channel_name = channel_name.clone();
        let context = context.clone();
        let worker_bot_id = worker.bot_id.clone();
        let worker_bot_name = worker.bot_name.clone();
        worker_jobs.spawn(async move {
            let result = async {
            let conversation_id = format!(
                "channel:{channel_id}:worker:{worker_bot_id}:message:{}",
                parent_message.id
            );
            let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
            if state
                .store
                .conversation(&conversation_id)
                .await
                .map_err(|error| error.to_string())?
                .is_none()
            {
                state
                    .store
                    .create_conversation(
                        &conversation_id,
                        &worker_bot_id,
                        &format!("{} · {}", channel_name, worker_bot_name),
                        &now,
                    )
                    .await
                    .map_err(|error| error.to_string())?;
            }
            let client_message_id = deterministic_uuid(&format!(
                "wonder-channel-worker:{}:{}",
                parent_message.id, worker_bot_id
            ));
            state.store.plan_group_node(&parent_message, &client_message_id, &worker_bot_id, "worker").await.map_err(|e| e.to_string())?;
            let worker_body = format!(
                "You are {role} in the Group Chat {channel}. Reply directly to the user in your own voice. Keep your answer concise and do not describe internal coordination.\n\n{context}{body}",
                role = worker_bot_name,
                channel = channel_name,
            );
            let body_sha256 = hex::encode(Sha256::digest(worker_body.as_bytes()));
            let worker_message = match state
                .store
                .insert_message(
                    &parent_message.device_id,
                    &client_message_id,
                    &worker_body,
                    &body_sha256,
                    &conversation_id,
                    &now,
                )
                .await
                .map_err(|error| error.to_string())?
            {
                MessageInsert::Inserted(message) | MessageInsert::Existing(message) => message,
                MessageInsert::Conflict => return Err("worker message idempotency conflict".into()),
            };
            let _slot = state.channel_worker_slots.clone().acquire_owned().await.map_err(|e| e.to_string())?;
            dispatch_to_codex_inner(
                state.clone(),
                worker_message.clone(),
                Some(worker_bot_id.clone()),
                None,
            )
            .await;
            let _ = wait_for_message_terminal(&state, &worker_message.id).await;
            Ok::<(String, String), String>((conversation_id, worker_message.id))
            }
            .await;
            match result {
                Ok((conversation_id, message_id)) => {
                    Ok((conversation_id, message_id, worker_bot_id, worker_bot_name))
                }
                Err(error) => Err((worker_bot_id, worker_bot_name, error)),
            }
        });
    }
    let mut reports = Vec::new();
    while let Some(result) = worker_jobs.join_next().await {
        match result {
            Ok(Ok((conversation_id, message_id, bot_id, bot_name))) => {
                let terminal_state = wait_for_message_terminal(&state, &message_id).await;
                if !matches!(
                    terminal_state.as_deref(),
                    Some("completed" | "failed" | "safe_to_retry" | "interrupted")
                ) {
                    return None;
                }
                let outcome = match terminal_state.as_deref() {
                    Some("completed") => Some("completed"),
                    Some("interrupted") => Some("interrupted"),
                    Some("timeout") | Some("timed_out") | None => Some("timed_out"),
                    Some(_) => Some("failed"),
                };
                let failed = outcome != Some("completed");
                let worker_turn = state
                    .store
                    .message_by_id(&message_id)
                    .await
                    .ok()
                    .flatten()
                    .and_then(|message| message.codex_turn_id);
                let report = if failed {
                    format!("{bot_name} couldn't finish this reply.")
                } else {
                    state
                        .store
                        .assistant_messages_for_conversation(&conversation_id)
                        .await
                        .ok()
                        .and_then(|messages| {
                            messages.into_iter().rev().find(|message| {
                                message.state == "completed"
                                    && worker_turn.as_deref()
                                        == Some(message.codex_turn_id.as_str())
                            })
                        })
                        .map(|message| message.text)
                        .filter(|text| !text.trim().is_empty())?
                };
                let report_id = if group_collaboration::enabled(&state, &channel_id).await {
                    deterministic_uuid(&format!(
                        "wonder-group-result:{message_id}:{}",
                        worker_turn.as_deref().unwrap_or("failed")
                    ))
                } else {
                    deterministic_uuid(&format!("wonder-channel-worker-report:{message_id}"))
                };
                let report_sha256 = hex::encode(Sha256::digest(report.as_bytes()));
                if let Ok(
                    MessageInsert::Inserted(report_message)
                    | MessageInsert::Existing(report_message),
                ) = state
                    .store
                    .insert_message(
                        &parent_message.device_id,
                        &report_id,
                        &report,
                        &report_sha256,
                        &channel.conversation_id,
                        &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                    )
                    .await
                {
                    let _ = state
                        .store
                        .add_channel_message(NewChannelMessage {
                            channel_id: &channel_id,
                            message_id: &report_message.id,
                            author_kind: "member",
                            author_bot_id: Some(&bot_id),
                            phase: if direct_target.is_some() {
                                "direct"
                            } else {
                                "worker"
                            },
                            created_at: &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                            presentation_kind: if failed { "status" } else { "message" },
                            outcome,
                            retryable: failed,
                        })
                        .await;
                    if direct_target.as_deref() == Some(bot_id.as_str()) {
                        direct_output_id = Some(report_message.id.clone());
                    }
                }
                reports.push((bot_name, report));
            }
            Ok(Err((bot_id, bot_name, error))) => {
                eprintln!("Group member {bot_id} could not reply: {error}");
                let report = format!("{bot_name} couldn't start this reply.");
                let report_id = deterministic_uuid(&format!(
                    "wonder-channel-worker-pre-dispatch-error:{}:{}",
                    parent_message.id, bot_id
                ));
                let report_sha256 = hex::encode(Sha256::digest(report.as_bytes()));
                if let Ok(
                    MessageInsert::Inserted(report_message)
                    | MessageInsert::Existing(report_message),
                ) = state
                    .store
                    .insert_message(
                        &parent_message.device_id,
                        &report_id,
                        &report,
                        &report_sha256,
                        &channel.conversation_id,
                        &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                    )
                    .await
                {
                    let _ = state
                        .store
                        .add_channel_message(NewChannelMessage {
                            channel_id: &channel_id,
                            message_id: &report_message.id,
                            author_kind: "member",
                            author_bot_id: Some(&bot_id),
                            phase: if direct_target.is_some() {
                                "direct"
                            } else {
                                "worker"
                            },
                            created_at: &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                            presentation_kind: "status",
                            outcome: Some("failed"),
                            retryable: true,
                        })
                        .await;
                    if direct_target.as_deref() == Some(bot_id.as_str()) {
                        direct_output_id = Some(report_message.id.clone());
                    }
                }
                reports.push((bot_name, report));
            }
            Err(error) => reports.push(("worker".into(), format!("Worker task failed: {error}"))),
        }
    }
    if direct_target.is_some() {
        if direct_output_id.is_some() {
            let _ = publish_event_with_context(
                &state,
                WonderEvent::Activity {
                    category: "channel".into(),
                    state: "completed".into(),
                    detail: Some("Group Chat updated".into()),
                },
                EventContext {
                    conversation_id: Some(channel.conversation_id),
                    ..EventContext::default()
                },
            )
            .await;
        }
        return direct_output_id;
    }
    // Completion order must not change the immutable synthesis request body.
    reports.sort();
    let synthesis_body = format!(
        "You are the coordinator Bot for channel {}. Synthesize the worker reports below into one clear answer to the user's request.\n\nUser request:\n{}\n\nWorker reports:\n{}",
        channel.name,
        body,
        reports
            .iter()
            .map(|(bot_name, report)| format!("Worker Bot {bot_name}:\n{report}"))
            .collect::<Vec<_>>()
            .join("\n\n")
    );
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let synthesis_client_message_id =
        deterministic_uuid(&format!("wonder-channel-synthesis:{}", parent_message.id));
    let synthesis_sha256 = hex::encode(Sha256::digest(synthesis_body.as_bytes()));
    state
        .store
        .plan_group_node(
            &parent_message,
            &synthesis_client_message_id,
            &channel.coordinator_bot_id,
            "synthesis",
        )
        .await
        .ok()?;
    let Ok(MessageInsert::Inserted(synthesis_message) | MessageInsert::Existing(synthesis_message)) =
        state
            .store
            .insert_message(
                &parent_message.device_id,
                &synthesis_client_message_id,
                &synthesis_body,
                &synthesis_sha256,
                &channel.conversation_id,
                &now,
            )
            .await
    else {
        return None;
    };
    dispatch_to_codex_inner(
        state.clone(),
        synthesis_message.clone(),
        Some(channel.coordinator_bot_id.clone()),
        None,
    )
    .await;
    if wait_for_message_terminal(&state, &synthesis_message.id)
        .await
        .as_deref()
        != Some("completed")
    {
        return None;
    }
    let synthesis_turn = state
        .store
        .message_by_id(&synthesis_message.id)
        .await
        .ok()
        .flatten()?
        .codex_turn_id;

    let mut output_id = None;
    if let Ok(messages) = state
        .store
        .assistant_messages_for_conversation(&channel.conversation_id)
        .await
    {
        if let Some(message) = messages.into_iter().rev().find(|message| {
            message.state == "completed"
                && synthesis_turn.as_deref() == Some(message.codex_turn_id.as_str())
        }) {
            if !message.text.trim().is_empty() {
                let projected_output_id =
                    deterministic_uuid(&format!("wonder-channel-output:{}", synthesis_message.id));
                let output_sha256 = hex::encode(Sha256::digest(message.text.as_bytes()));
                if let Ok(MessageInsert::Inserted(output) | MessageInsert::Existing(output)) = state
                    .store
                    .insert_message(
                        &parent_message.device_id,
                        &projected_output_id,
                        &message.text,
                        &output_sha256,
                        &channel.conversation_id,
                        &now,
                    )
                    .await
                {
                    if state
                        .store
                        .add_channel_message(NewChannelMessage {
                            channel_id: &channel_id,
                            message_id: &output.id,
                            author_kind: "coordinator",
                            author_bot_id: Some(&channel.coordinator_bot_id),
                            phase: "synthesis",
                            created_at: &now,
                            presentation_kind: "message",
                            outcome: Some("completed"),
                            retryable: false,
                        })
                        .await
                        .is_ok()
                    {
                        output_id = Some(output.id.clone());
                        // The channel projection is written after the
                        // coordinator turn completes. Emit a final update
                        // marker so connected clients refresh after that write,
                        // instead of stopping at an earlier worker event.
                        let _ = publish_event_with_context(
                            &state,
                            WonderEvent::Activity {
                                category: "channel".into(),
                                state: "completed".into(),
                                detail: Some("Group Chat updated".into()),
                            },
                            EventContext {
                                conversation_id: Some(channel.conversation_id.clone()),
                                ..EventContext::default()
                            },
                        )
                        .await;
                    }
                }
            }
        }
    }
    output_id
}

fn deterministic_uuid(seed: &str) -> String {
    let digest = Sha256::digest(seed.as_bytes());
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    uuid::Uuid::from_bytes(bytes).to_string()
}

async fn wait_for_message_terminal(state: &AppState, message_id: &str) -> Option<String> {
    for _ in 0..300 {
        let message = state.store.message_by_id(message_id).await.ok().flatten()?;
        if matches!(
            message.state.as_str(),
            "completed" | "failed" | "uncertain" | "safe_to_retry" | "interrupted"
        ) {
            return Some(message.state);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    None
}

async fn create_conversation(
    State(state): State<AppState>,
    Json(request): Json<CreateConversationRequest>,
) -> Response {
    let Ok(Some(bot)) = bot_for_conversation(&state, &request.bot_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if bot.is_archived {
        return (
            StatusCode::CONFLICT,
            "Archived Bots cannot start new conversations",
        )
            .into_response();
    }
    let title = request
        .title
        .as_deref()
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .unwrap_or(&bot.name);
    if title.len() > 160 {
        return (StatusCode::BAD_REQUEST, "conversation title is too long").into_response();
    }
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    if state
        .store
        .ensure_bot_workspace(&bot.id, title, &now)
        .await
        .is_err()
    {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "conversation could not be created",
        )
            .into_response();
    }
    let Ok(Some(id)) = state.store.bot_workspace(&bot.id).await else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "Bot workspace could not be loaded",
        )
            .into_response();
    };
    Json(ConversationSummary {
        conversation_id: id,
        bot_id: Some(bot.id),
        title: title.to_owned(),
        last_message_preview: None,
        last_message_at: None,
        message_count: 0,
        delivery_state: None,
        has_unread: false,
        is_archived: false,
        is_pinned: false,
    })
    .into_response()
}

async fn update_conversation(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
    Json(request): Json<UpdateConversationRequest>,
) -> Response {
    // Read acknowledgements remain available in the transcript sheet.
    if request.title.is_some() || request.is_archived.is_some() || request.is_pinned.is_some() {
        if let Some(response) = subagents::reject_user_mutation(&state, &conversation_id).await {
            return response;
        }
    }
    let Ok(Some(bot)) = bot_for_conversation(&state, &conversation_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if request.mark_read == Some(true)
        && (request.host_epoch.as_deref() != Some(state.host_epoch.as_str())
            || request.read_through_sequence.is_none())
    {
        return (
            StatusCode::BAD_REQUEST,
            "Reload the conversation before marking it read.",
        )
            .into_response();
    }
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    if state
        .store
        .ensure_conversation_metadata(&conversation_id, &bot.id, &bot.name, &now)
        .await
        .is_err()
    {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "conversation metadata could not be initialized",
        )
            .into_response();
    }
    if request
        .title
        .as_deref()
        .is_some_and(|title| title.trim().is_empty() || title.trim().len() > 160)
    {
        return (StatusCode::BAD_REQUEST, "invalid conversation title").into_response();
    }
    if (request.title.is_some() || request.is_archived.is_some() || request.is_pinned.is_some())
        && state
            .store
            .update_conversation(
                &conversation_id,
                request.title.as_deref().map(str::trim),
                request.is_archived,
                request.is_pinned,
                None,
                &now,
            )
            .await
            .is_err()
    {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "conversation could not be updated",
        )
            .into_response();
    }
    if request.mark_read == Some(true)
        && state
            .store
            .acknowledge_conversation_read(
                &conversation_id,
                &state.host_epoch,
                request.read_through_sequence.unwrap(),
                &now,
            )
            .await
            .is_err()
    {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Read status could not be saved.",
        )
            .into_response();
    }
    match state.store.list_conversation_summaries().await {
        Ok(conversations) => conversations
            .into_iter()
            .find(|summary| summary.conversation_id == conversation_id)
            .map(conversation_summary)
            .map(Json)
            .map(IntoResponse::into_response)
            .unwrap_or_else(|| StatusCode::NOT_FOUND.into_response()),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "conversation could not be loaded",
        )
            .into_response(),
    }
}

fn conversation_summary(summary: StoredConversationSummary) -> ConversationSummary {
    ConversationSummary {
        conversation_id: summary.conversation_id,
        bot_id: summary.bot_id,
        title: summary.title,
        last_message_preview: summary.last_message_preview,
        last_message_at: summary.last_message_at,
        message_count: summary.message_count,
        delivery_state: summary
            .delivery_state
            .as_deref()
            .and_then(delivery_state_from_name),
        has_unread: summary.has_unread,
        is_archived: summary.is_archived,
        is_pinned: summary.is_pinned,
    }
}

fn delivery_state_from_name(value: &str) -> Option<DeliveryState> {
    Some(match value {
        "draft_on_device" => DeliveryState::DraftOnDevice,
        "submitting" => DeliveryState::Submitting,
        "accepted_by_wonder" => DeliveryState::AcceptedByWonder,
        "dispatching_to_codex" => DeliveryState::DispatchingToCodex,
        "accepted_by_codex" => DeliveryState::AcceptedByCodex,
        "streaming" => DeliveryState::Streaming,
        "completed" => DeliveryState::Completed,
        "interrupted" => DeliveryState::Interrupted,
        "failed" => DeliveryState::Failed,
        "uncertain" => DeliveryState::Uncertain,
        "safe_to_retry" => DeliveryState::SafeToRetry,
        _ => return None,
    })
}

fn message_receipt(message: wonder_store::StoredMessage) -> Option<ClientMessageReceipt> {
    Some(ClientMessageReceipt {
        client_message_id: message.client_message_id,
        wonder_message_id: message.id,
        body_sha256: message.body_sha256,
        conversation_id: message.conversation_id,
        delivery_state: delivery_state_from_name(&message.state)?,
        codex_thread_id: message.codex_thread_id,
        codex_turn_id: message.codex_turn_id,
    })
}

async fn bot_for_conversation(
    state: &AppState,
    conversation_id: &str,
) -> Result<Option<StoredBot>, sqlx::Error> {
    let bots = state.store.list_bots().await?;
    // A durable conversation owns its Bot mapping. Legacy Bot ids continue to
    // work as conversation ids when no metadata row exists.
    if let Some(conversation) = state.store.conversation(conversation_id).await? {
        return Ok(bots.into_iter().find(|bot| bot.id == conversation.bot_id));
    }
    if let Some(bot) = bots.iter().find(|bot| {
        bot.id == conversation_id
            || (conversation_id == "default" && bot.id == "default")
            || conversation_id.strip_prefix("automation:") == Some(bot.id.as_str())
    }) {
        return Ok(Some(bot.clone()));
    }
    Ok(None)
}

fn model_option<'a>(
    catalog: &'a RuntimeCatalog,
    model_id: Option<&str>,
) -> Option<&'a ModelOption> {
    model_id
        .and_then(|id| catalog.models.iter().find(|model| model.id == id))
        .or_else(|| catalog.models.iter().find(|model| !model.hidden))
}

fn effective_settings(
    catalog: &RuntimeCatalog,
    bot: &StoredBot,
    settings: Option<&wonder_store::StoredConversationSettings>,
) -> (EffectiveConversationSettings, ConversationSettingsOverrides) {
    let model = settings
        .and_then(|settings| settings.model.clone())
        .or_else(|| bot.model.clone())
        .or_else(|| model_option(catalog, None).map(|model| model.id.clone()));
    let model_definition = model_option(catalog, model.as_deref());
    let effort = settings
        .and_then(|settings| settings.reasoning_effort.clone())
        .or_else(|| bot.reasoning_effort.clone())
        .or_else(|| model_definition.and_then(|model| model.default_reasoning_effort.clone()));
    let service_tier = settings
        .and_then(|settings| settings.service_tier.clone())
        .or_else(|| bot.service_tier.clone())
        .or_else(|| model_definition.and_then(|model| model.default_service_tier.clone()));
    let resolved_permissions = permission_modes::resolve(bot);
    let permission_profile = if bot.permission_mode.is_some() {
        resolved_permissions.permission_profile.clone()
    } else {
        settings
            .and_then(|settings| settings.permission_profile.clone())
            .unwrap_or_else(|| bot.permission_profile.clone())
    };
    (
        EffectiveConversationSettings {
            model,
            effort,
            service_tier,
            permission_profile,
            approval_mode: bot.approval_mode.clone(),
            approval_policy: resolved_permissions.approval_policy,
            approvals_reviewer: resolved_permissions.approvals_reviewer,
        },
        ConversationSettingsOverrides {
            model: settings.and_then(|settings| settings.model.clone()),
            effort: settings.and_then(|settings| settings.reasoning_effort.clone()),
            service_tier: settings.and_then(|settings| settings.service_tier.clone()),
            permission_profile: settings.and_then(|settings| settings.permission_profile.clone()),
        },
    )
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComposerOptionsQuery {
    queued_message_id: Option<String>,
}

async fn conversation_composer_options(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
    Query(query): Query<ComposerOptionsQuery>,
) -> Response {
    match state
        .store
        .subagent_ownership_for_conversation(&conversation_id)
        .await
    {
        Ok(Some(_)) => {
            return (
                StatusCode::CONFLICT,
                "Subagent settings are inherited from its runtime and cannot be changed here.",
            )
                .into_response()
        }
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        Ok(None) => {}
    }
    let Ok(Some(mut bot)) = bot_for_conversation(&state, &conversation_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if let Some(id) = query.queued_message_id {
        let Ok(queue) = state.store.pending_queue(&conversation_id).await else {
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        };
        if !queue.iter().any(|item| item.id == id) {
            return StatusCode::NOT_FOUND.into_response();
        }
        bot = match state.store.message_execution_bot(&id, bot).await {
            Ok((snapshot, _)) => snapshot,
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        };
    }
    let catalog = state.runtime_catalog.read().await;
    if catalog.models.is_empty() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "runtime options are not ready",
        )
            .into_response();
    }
    let permission_profiles = catalog
        .profiles_for(bot.execution_directory())
        .iter()
        .filter(|profile| {
            profile.allowed
                && catalog
                    .allowed_permission_profiles
                    .get(&profile.id)
                    .copied()
                    .unwrap_or(true)
        })
        .cloned()
        .collect();
    let timezone = std::fs::read_link("/etc/localtime")
        .ok()
        .and_then(|p| {
            p.to_str()
                .and_then(|s| s.split("zoneinfo/").nth(1))
                .map(str::to_owned)
        })
        .unwrap_or_else(|| "UTC".into());
    Json(ComposerOptionsResponse {
        models: catalog
            .models
            .iter()
            .filter(|model| !model.hidden)
            .cloned()
            .collect(),
        permission_profiles,
        approval_modes: permission_modes::approval_options_for_bot(&catalog, &bot),
        timezone,
        allowed_approval_policies: if !catalog.approval_policies_restricted {
            vec!["on-request".into(), "never".into()]
        } else {
            catalog.allowed_approval_policies.clone()
        },
        allowed_approval_reviewers: if !catalog.approval_reviewers_restricted {
            vec!["user".into(), "auto_review".into()]
        } else {
            catalog.allowed_approval_reviewers.clone()
        },
    })
    .into_response()
}

async fn conversation_settings(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
) -> Response {
    match state
        .store
        .subagent_ownership_for_conversation(&conversation_id)
        .await
    {
        Ok(Some(_)) => {
            return (
                StatusCode::CONFLICT,
                "Subagent settings are inherited from its runtime and cannot be changed here.",
            )
                .into_response()
        }
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        Ok(None) => {}
    }
    let Ok(Some(bot)) = bot_for_conversation(&state, &conversation_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let settings = match state.store.conversation_settings(&conversation_id).await {
        Ok(settings) => settings,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "settings could not be loaded",
            )
                .into_response()
        }
    };
    let catalog = state.runtime_catalog.read().await;
    let (effective, overrides) = effective_settings(&catalog, &bot, settings.as_ref());
    let default_profile = bot.effective_permission_profile().to_owned();
    let default_permissions = permission_modes::resolve(&bot);
    let default_approval = default_permissions.approval_policy;
    Json(ConversationSettingsResponse {
        bot_defaults: EffectiveConversationSettings {
            model: bot
                .model
                .or_else(|| model_option(&catalog, None).map(|model| model.id.clone())),
            effort: bot.reasoning_effort,
            service_tier: bot.service_tier,
            permission_profile: default_profile,
            approval_mode: bot.approval_mode.clone(),
            approval_policy: default_approval,
            approvals_reviewer: default_permissions.approvals_reviewer,
        },
        effective,
        overrides,
    })
    .into_response()
}

fn validate_setting_value(
    catalog: &RuntimeCatalog,
    bot: &StoredBot,
    model: Option<&str>,
    effort: Option<&str>,
    service_tier: Option<&str>,
    permission_profile: Option<&str>,
) -> Result<(), &'static str> {
    // Conversation/automation overrides may select a different model than the
    // Bot default. Managed reviewer requirements apply to that effective model.
    let mut execution_bot = bot.clone();
    execution_bot.model = model.map(str::to_owned);
    if (bot.approval_mode.is_some() || bot.permission_mode.is_some())
        && !permission_modes::approval_allowed(catalog, &execution_bot)
    {
        return Err("approval reviewer is unavailable");
    }
    let selected_model = model_option(catalog, model).ok_or("selected model is unavailable")?;
    if let Some(model) = model {
        if selected_model.id != model || selected_model.hidden {
            return Err("selected model is unavailable");
        }
    }
    if let Some(effort) = effort {
        if !selected_model
            .reasoning_efforts
            .iter()
            .any(|option| option.id == effort)
        {
            return Err("selected effort is unavailable for this model");
        }
    }
    if let Some(service_tier) = service_tier {
        if !selected_model
            .service_tiers
            .iter()
            .any(|option| option.id == service_tier)
            && selected_model.default_service_tier.as_deref() != Some(service_tier)
        {
            return Err("selected speed is unavailable for this model");
        }
    }
    if let Some(permission_profile) = permission_profile {
        if bot.permission_mode.is_some() && permission_profile != bot.effective_permission_profile()
        {
            return Err("Change access in Bot settings. Conversation access cannot override this Bot's mode.");
        }
        let allowed = catalog
            .profiles_for(bot.execution_directory())
            .iter()
            .any(|profile| {
                profile.id == permission_profile
                    && profile.allowed
                    && catalog
                        .allowed_permission_profiles
                        .get(permission_profile)
                        .copied()
                        .unwrap_or(!catalog.permission_profiles_restricted)
            });
        if !allowed {
            return Err("selected access profile is unavailable");
        }
    }
    Ok(())
}

/// Permission profiles are cwd-scoped. Populate a missing execution cwd from
/// the runtime before the synchronous dispatch validation reads the catalog;
/// an explicitly cached empty list remains a managed deny-all result.
pub(crate) async fn ensure_execution_permission_cache(
    state: &AppState,
    bot: &StoredBot,
) -> Result<(), String> {
    let needs_cache = {
        let catalog = state.runtime_catalog.read().await;
        !catalog
            .permission_profiles_by_cwd
            .contains_key(bot.execution_directory())
    };
    if !needs_cache {
        return Ok(());
    }
    let mut app_server = state.app_server.lock().await;
    permission_modes::verify(state, &mut app_server, bot).await
}

fn validate_bot_runtime_settings(
    catalog: &RuntimeCatalog,
    model: Option<&str>,
    effort: Option<&str>,
    service_tier: Option<&str>,
) -> Result<(), &'static str> {
    let Some(selected_model) = model_option(catalog, model) else {
        return if model.is_some() || effort.is_some() || service_tier.is_some() {
            Err("selected Bot runtime setting is unavailable")
        } else {
            Ok(())
        };
    };
    if model.is_some_and(|model| selected_model.id != model || selected_model.hidden) {
        return Err("selected model is unavailable");
    }
    if effort.is_some_and(|effort| {
        !selected_model
            .reasoning_efforts
            .iter()
            .any(|option| option.id == effort)
    }) {
        return Err("selected effort is unavailable for this model");
    }
    if service_tier.is_some_and(|service_tier| {
        !selected_model
            .service_tiers
            .iter()
            .any(|option| option.id == service_tier)
            && selected_model.default_service_tier.as_deref() != Some(service_tier)
    }) {
        return Err("selected speed is unavailable for this model");
    }
    Ok(())
}

async fn rollback_bot_artifacts(
    store: &Store,
    launch_config: &Arc<tokio::sync::Mutex<LaunchConfig>>,
    bot_id: &str,
    home: &FsPath,
    override_value: Option<&str>,
) {
    let _ = store.delete_bot(bot_id).await;
    let _ = tokio::fs::remove_dir_all(home).await;
    if let Some(override_value) = override_value {
        let mut config = launch_config.lock().await;
        config
            .permission_overrides
            .retain(|value| value != override_value);
    }
}

async fn rollback_new_bot(
    state: &AppState,
    bot_id: &str,
    home: &FsPath,
    override_value: Option<&str>,
) {
    rollback_bot_artifacts(
        &state.store,
        &state.launch_config,
        bot_id,
        home,
        override_value,
    )
    .await;
}

async fn update_conversation_settings(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(conversation_id): Path<String>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
    local_authority: Option<Extension<LocalOwnerAuthority>>,
    Json(patch): Json<ConversationSettingsPatch>,
) -> Response {
    if let Some(response) = subagents::reject_user_mutation(&state, &conversation_id).await {
        return response;
    }
    match state
        .store
        .subagent_ownership_for_conversation(&conversation_id)
        .await
    {
        Ok(Some(_)) => {
            return (
                StatusCode::CONFLICT,
                "Subagent settings are inherited from its runtime and cannot be changed here.",
            )
                .into_response()
        }
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        Ok(None) => {}
    }
    if authenticated_device.is_none() && local_authority.is_none() {
        return (StatusCode::UNAUTHORIZED, "paired device required").into_response();
    }
    let semantic_body = serde_json::json!([
        patch.model.as_ref().and_then(Clone::clone),
        patch.effort.as_ref().and_then(Clone::clone),
        patch.service_tier.as_ref().and_then(Clone::clone),
        patch.permission_profile.as_ref().and_then(Clone::clone),
    ]);
    if let Some(Extension(device)) = authenticated_device {
        let target = format!("/api/v1/conversations/{conversation_id}/settings");
        if let Err(message) = verify_signed_action(
            &state,
            &device,
            "conversation.settings.update",
            &target,
            &action_body_sha256(&semantic_body),
            &patch.action,
            "active",
        )
        .await
        {
            return (StatusCode::UNAUTHORIZED, message).into_response();
        }
    }
    let Ok(Some(bot)) = bot_for_conversation(&state, &conversation_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let current = match state.store.conversation_settings(&conversation_id).await {
        Ok(settings) => settings,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "settings could not be loaded",
            )
                .into_response()
        }
    };
    let mut model = current.as_ref().and_then(|settings| settings.model.clone());
    let mut effort = current
        .as_ref()
        .and_then(|settings| settings.reasoning_effort.clone());
    let mut service_tier = current
        .as_ref()
        .and_then(|settings| settings.service_tier.clone());
    let mut permission_profile = current
        .as_ref()
        .and_then(|settings| settings.permission_profile.clone());
    let model_patch = patch.model;
    let effort_patch = patch.effort;
    let service_tier_patch = patch.service_tier;
    let permission_profile_patch = patch.permission_profile;
    if bot.permission_mode.is_some() {
        if permission_profile_patch
            .as_ref()
            .and_then(|value| value.as_deref())
            .is_some_and(|profile| profile != bot.effective_permission_profile())
        {
            return (StatusCode::BAD_REQUEST, "Change access in Bot settings.").into_response();
        }
        permission_profile = None;
    }
    let model_was_patched = model_patch.is_some();
    let effort_was_patched = effort_patch.is_some();
    let service_tier_was_patched = service_tier_patch.is_some();
    if let Some(value) = model_patch {
        model = value;
    }
    if let Some(value) = effort_patch {
        effort = value;
    }
    if let Some(value) = service_tier_patch {
        service_tier = value;
    }
    if let Some(value) = permission_profile_patch {
        permission_profile = value;
    }
    let catalog = state.runtime_catalog.read().await;
    if model_was_patched && !effort_was_patched && model.is_some() {
        if let Some(model_definition) = model_option(&catalog, model.as_deref()) {
            if effort.as_deref().is_some_and(|value| {
                !model_definition
                    .reasoning_efforts
                    .iter()
                    .any(|option| option.id == value)
            }) {
                effort = model_definition.default_reasoning_effort.clone();
            }
        }
    }
    if !effort_was_patched {
        let effective_model = model
            .as_deref()
            .or(bot.model.as_deref())
            .or_else(|| model_option(&catalog, None).map(|model| model.id.as_str()));
        if let Some(model_definition) = model_option(&catalog, effective_model) {
            if effort.as_deref().is_some_and(|value| {
                !model_definition
                    .reasoning_efforts
                    .iter()
                    .any(|option| option.id == value)
            }) {
                effort = model_definition.default_reasoning_effort.clone();
            }
        }
    }
    if !service_tier_was_patched {
        let effective_model = model
            .as_deref()
            .or(bot.model.as_deref())
            .or_else(|| model_option(&catalog, None).map(|model| model.id.as_str()));
        if let Some(model_definition) = model_option(&catalog, effective_model) {
            if service_tier.as_deref().is_some_and(|value| {
                !model_definition
                    .service_tiers
                    .iter()
                    .any(|option| option.id == value)
            }) {
                service_tier = model_definition.default_service_tier.clone();
            }
        }
    }
    if let Err(message) = validate_setting_value(
        &catalog,
        &bot,
        model.as_deref().or(bot.model.as_deref()),
        effort.as_deref().or(bot.reasoning_effort.as_deref()),
        service_tier.as_deref().or(bot.service_tier.as_deref()),
        permission_profile
            .as_deref()
            .or(Some(bot.effective_permission_profile())),
    ) {
        return (StatusCode::BAD_REQUEST, message).into_response();
    }
    drop(catalog);
    let candidate_settings = wonder_store::StoredConversationSettings {
        conversation_id: conversation_id.clone(),
        model: model.clone(),
        reasoning_effort: effort.clone(),
        service_tier: service_tier.clone(),
        permission_profile: permission_profile.clone(),
        updated_at: now_ms().to_string(),
    };
    if state
        .store
        .upsert_conversation_settings(
            &conversation_id,
            model.as_deref(),
            effort.as_deref(),
            service_tier.as_deref(),
            permission_profile.as_deref(),
            &candidate_settings.updated_at,
        )
        .await
        .is_err()
    {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "settings could not be saved",
        )
            .into_response();
    }
    conversation_settings(State(state), Path(conversation_id)).await
}

fn conversation_file_summary(file: StoredConversationFile) -> ConversationFileSummary {
    ConversationFileSummary {
        id: file.id,
        kind: file.kind,
        name: file.name,
        mime_type: file.mime_type,
        byte_size: file.byte_size,
        sha256: file.sha256,
        relative_path: file.relative_path,
        state: file.state,
        additions: file.additions,
        deletions: file.deletions,
        created_at: file.created_at,
        updated_at: file.updated_at,
    }
}

fn valid_attachment_name(name: &str) -> bool {
    let trimmed = name.trim();
    name == trimmed
        && !trimmed.is_empty()
        && trimmed.len() <= 255
        && !trimmed.chars().any(char::is_control)
        && !trimmed.contains(['/', '\\'])
        && trimmed != "."
        && trimmed != ".."
        && !FsPath::new(trimmed).is_absolute()
}

fn valid_attachment_mime_type(mime_type: &str) -> bool {
    let mut parts = mime_type.split('/');
    let Some(major) = parts.next() else {
        return false;
    };
    let Some(subtype) = parts.next() else {
        return false;
    };
    parts.next().is_none()
        && !major.is_empty()
        && !subtype.is_empty()
        && mime_type.len() <= 255
        && mime_type.chars().all(|character| {
            character.is_ascii_alphanumeric()
                || matches!(
                    character,
                    '/' | '!' | '#' | '$' | '&' | '^' | '_' | '.' | '+' | '-'
                )
        })
}

fn attachment_relative_path(file_id: &str) -> String {
    format!(".wonder/attachments/{file_id}")
}

fn decode_local_href(href: &str) -> Option<String> {
    let mut decoded = Vec::with_capacity(href.len());
    let bytes = href.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return None;
            }
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok()?;
            decoded.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else if bytes[index] == b'\\' && bytes.get(index + 1) == Some(&b' ') {
            decoded.push(b' ');
            index += 2;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

#[derive(Debug, Deserialize)]
struct ResolveConversationFileRequest {
    href: String,
}

/// Resolve a local file reference produced by a Bot into durable file
/// metadata. The endpoint intentionally accepts only paths, never URLs that
/// could trigger network access, and canonicalizes before checking roots.
async fn resolve_conversation_file(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
    Json(request): Json<ResolveConversationFileRequest>,
) -> Response {
    let Ok(Some(bot)) = bot_for_conversation(&state, &conversation_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let href = request.href.trim();
    if href.is_empty() || href.len() > 4096 {
        return (StatusCode::NOT_FOUND, "file reference not found").into_response();
    }
    let requested = if let Some(path) = href.strip_prefix("file://") {
        // Only local file URLs are accepted. A host component (file://host/x)
        // is rejected rather than being interpreted as a local path.
        let path = if let Some(path) = path.strip_prefix("localhost/") {
            format!("/{path}")
        } else if path.starts_with('/') {
            path.to_owned()
        } else {
            return (
                StatusCode::FORBIDDEN,
                "file reference is outside the Bot workspace",
            )
                .into_response();
        };
        let Some(path) = decode_local_href(&path) else {
            return (StatusCode::NOT_FOUND, "file reference not found").into_response();
        };
        FsPath::new(&path).to_path_buf()
    } else if href.contains("://") {
        return (
            StatusCode::FORBIDDEN,
            "remote file references are not allowed",
        )
            .into_response();
    } else {
        let Some(decoded) = decode_local_href(href) else {
            return (StatusCode::NOT_FOUND, "file reference not found").into_response();
        };
        let path = FsPath::new(&decoded);
        if path.is_absolute() {
            path.to_path_buf()
        } else {
            FsPath::new(&bot.workspace_path).join(path)
        }
    };
    let workspace = match tokio::fs::canonicalize(&bot.workspace_path).await {
        Ok(path) => path,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let canonical = match tokio::fs::canonicalize(&requested).await {
        Ok(path) => path,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let inside_workspace = canonical.starts_with(&workspace);
    let inside_linked_root = if inside_workspace {
        false
    } else {
        let mut allowed = false;
        for configured_root in &state.linked_file_roots {
            if let Ok(root) = tokio::fs::canonicalize(configured_root).await {
                if root.is_dir() && canonical.starts_with(root) {
                    allowed = true;
                    break;
                }
            }
        }
        allowed
    };
    if !inside_workspace && !inside_linked_root {
        return (
            StatusCode::FORBIDDEN,
            "file reference is outside the folders Wonder may preview",
        )
            .into_response();
    }
    let metadata = match tokio::fs::symlink_metadata(&canonical).await {
        Ok(metadata) if metadata.file_type().is_file() && !metadata.file_type().is_symlink() => {
            metadata
        }
        Ok(_) | Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    if metadata.len() > MAX_WORKSPACE_ARTIFACT_BYTES as u64 {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            "file is too large to resolve",
        )
            .into_response();
    }
    let bytes = match tokio::fs::read(&canonical).await {
        Ok(bytes) => bytes,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    if bytes.len() > MAX_WORKSPACE_ARTIFACT_BYTES {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            "file is too large to resolve",
        )
            .into_response();
    }
    let name = match canonical.file_name().and_then(|name| name.to_str()) {
        Some(name) if valid_attachment_name(name) => name,
        _ => {
            return (
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "file name is not supported",
            )
                .into_response()
        }
    };
    let Some(mime_type) = artifact_mime_type(name, &bytes) else {
        return (
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "file type is not supported",
        )
            .into_response();
    };
    let sha256 = hex::encode(Sha256::digest(&bytes));
    let workspace_relative = canonical
        .strip_prefix(&workspace)
        .ok()
        .and_then(|path| path.to_str())
        .map(|path| path.replace(std::path::MAIN_SEPARATOR, "/"));
    let file_id = if inside_workspace {
        let Some(relative_path) = workspace_relative.as_deref() else {
            return StatusCode::FORBIDDEN.into_response();
        };
        hex::encode(Sha256::digest(
            format!("{}:{}", conversation_id, relative_path).as_bytes(),
        ))
    } else {
        hex::encode(Sha256::digest(
            format!("{}:{}", conversation_id, canonical.display()).as_bytes(),
        ))
    };
    let relative_path = if inside_workspace {
        let Some(relative_path) = workspace_relative
            .filter(|path| sanitized_relative_path(path, &workspace.to_string_lossy()).is_some())
        else {
            return (
                StatusCode::FORBIDDEN,
                "file reference is outside the Bot workspace",
            )
                .into_response();
        };
        relative_path
    } else {
        let linked_root = workspace.join(".wonder").join("linked-files");
        if tokio::fs::create_dir_all(&linked_root).await.is_err() {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "preview file could not be imported",
            )
                .into_response();
        }
        let linked_root = match tokio::fs::canonicalize(&linked_root).await {
            Ok(path) if path.is_dir() && path.starts_with(&workspace) => path,
            _ => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "preview file could not be imported",
                )
                    .into_response()
            }
        };
        let destination = linked_root.join(&file_id);
        if tokio::fs::symlink_metadata(&destination)
            .await
            .is_ok_and(|metadata| metadata.file_type().is_symlink())
        {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "preview file could not be imported",
            )
                .into_response();
        }
        let temporary = linked_root.join(format!(".import-{}", uuid::Uuid::new_v4()));
        if tokio::fs::write(&temporary, &bytes).await.is_err()
            || tokio::fs::rename(&temporary, &destination).await.is_err()
        {
            let _ = tokio::fs::remove_file(&temporary).await;
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "preview file could not be imported",
            )
                .into_response();
        }
        format!(".wonder/linked-files/{file_id}")
    };
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    if state
        .store
        .upsert_conversation_file(
            &file_id,
            &conversation_id,
            "artifact",
            name,
            Some(mime_type),
            Some(bytes.len() as i64),
            Some(&sha256),
            Some(&relative_path),
            "available",
            None,
            None,
            None,
            &now,
        )
        .await
        .is_err()
    {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "file metadata could not be saved",
        )
            .into_response();
    }
    match state.store.list_conversation_files(&conversation_id).await {
        Ok(files) => files
            .into_iter()
            .find(|file| file.id == file_id)
            .map(|file| Json(conversation_file_summary(file)).into_response())
            .unwrap_or_else(|| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "file could not be loaded",
        )
            .into_response(),
    }
}

async fn attachment_path(workspace: &str, file_id: &str, create_root: bool) -> Option<PathBuf> {
    let uuid = uuid::Uuid::parse_str(file_id).ok()?;
    let root = tokio::fs::canonicalize(workspace).await.ok()?;
    let attachments = root.join(".wonder").join("attachments");
    if create_root {
        tokio::fs::create_dir_all(&attachments).await.ok()?;
    }
    let canonical_attachments = tokio::fs::canonicalize(&attachments).await.ok()?;
    if !canonical_attachments.starts_with(&root) || !canonical_attachments.is_dir() {
        return None;
    }
    let candidate = canonical_attachments.join(uuid.to_string());
    if let Ok(metadata) = tokio::fs::symlink_metadata(&candidate).await {
        if metadata.file_type().is_symlink() {
            return None;
        }
        if !tokio::fs::canonicalize(&candidate)
            .await
            .ok()?
            .starts_with(&canonical_attachments)
        {
            return None;
        }
    }
    Some(candidate)
}

async fn upload_conversation_file(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
    Json(request): Json<CreateConversationFileRequest>,
) -> Response {
    if let Some(response) = subagents::reject_user_mutation(&state, &conversation_id).await {
        return response;
    }
    let Ok(Some(bot)) = bot_for_conversation(&state, &conversation_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let workspace = match group_attachments::storage_workspace(
        &state,
        &conversation_id,
        &bot.workspace_path,
        true,
    )
    .await
    {
        Ok(workspace) => workspace,
        Err(error) => return (StatusCode::SERVICE_UNAVAILABLE, error).into_response(),
    };
    let name = request.name.trim();
    if !valid_attachment_name(&request.name) {
        return (StatusCode::BAD_REQUEST, "invalid attachment name").into_response();
    }
    let bytes = match base64::engine::general_purpose::STANDARD.decode(request.content_base64) {
        Ok(bytes) if !bytes.is_empty() && bytes.len() <= MAX_ATTACHMENT_BYTES => bytes,
        Ok(bytes) if bytes.is_empty() => {
            return (StatusCode::BAD_REQUEST, "attachment is empty").into_response()
        }
        Ok(_) => return (StatusCode::PAYLOAD_TOO_LARGE, "attachment is too large").into_response(),
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                "attachment content is not valid base64",
            )
                .into_response()
        }
    };
    let mime_type = request
        .mime_type
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("application/octet-stream");
    if !valid_attachment_mime_type(mime_type) {
        return (StatusCode::BAD_REQUEST, "invalid attachment MIME type").into_response();
    }
    let sha256 = hex::encode(Sha256::digest(&bytes));
    let file_id = match request.client_upload_id {
        Some(id) => {
            if uuid::Uuid::parse_str(&id).is_err() {
                return (StatusCode::BAD_REQUEST, "invalid upload identity").into_response();
            }
            deterministic_uuid(&format!("native-upload:{conversation_id}:{id}"))
        }
        None => uuid::Uuid::new_v4().to_string(),
    };
    match state.store.list_conversation_files(&conversation_id).await {
        Ok(files) => {
            if let Some(existing) = files.into_iter().find(|file| file.id == file_id) {
                if existing.sha256.as_deref() != Some(&sha256)
                    || existing.name != name
                    || existing.mime_type.as_deref() != Some(mime_type)
                {
                    return (
                        StatusCode::CONFLICT,
                        "upload identity already has different content",
                    )
                        .into_response();
                }
                let Some(path) = attachment_path(&workspace, &existing.id, false).await else {
                    return (
                        StatusCode::CONFLICT,
                        "The saved upload is unavailable. Attach the file again.",
                    )
                        .into_response();
                };
                if let Err(error) = group_attachments::verified_bytes(&path, &existing).await {
                    return (StatusCode::CONFLICT, error).into_response();
                }
                return Json(conversation_file_summary(existing)).into_response();
            }
        }
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
    let relative_path = attachment_relative_path(&file_id);
    let Some(file_path) = attachment_path(&workspace, &file_id, true).await else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "attachment path is outside the Bot workspace",
        )
            .into_response();
    };
    if let Err(error) = group_attachments::write_immutable(&file_path, &bytes).await {
        return (StatusCode::CONFLICT, error).into_response();
    }
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    if state
        .store
        .upsert_conversation_file(
            &file_id,
            &conversation_id,
            "attachment",
            name,
            Some(mime_type),
            Some(bytes.len() as i64),
            Some(&sha256),
            Some(&relative_path),
            "available",
            None,
            None,
            None,
            &now,
        )
        .await
        .is_err()
    {
        // Retain complete immutable bytes so this upload identity can recover
        // after a metadata failure; a concurrent retry may already reference it.
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "attachment metadata could not be saved",
        )
            .into_response();
    }
    match state.store.list_conversation_files(&conversation_id).await {
        Ok(files) => files
            .into_iter()
            .find(|file| file.id == file_id)
            .map(|file| Json(conversation_file_summary(file)).into_response())
            .unwrap_or_else(|| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "attachment could not be loaded",
        )
            .into_response(),
    }
}

async fn conversation_files(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
) -> Response {
    if !matches!(
        bot_for_conversation(&state, &conversation_id).await,
        Ok(Some(_))
    ) {
        return StatusCode::NOT_FOUND.into_response();
    }
    match state.store.list_conversation_files(&conversation_id).await {
        Ok(files) => Json(
            files
                .into_iter()
                .map(conversation_file_summary)
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "files could not be loaded",
        )
            .into_response(),
    }
}

async fn conversation_file(
    State(state): State<AppState>,
    Path((conversation_id, file_id)): Path<(String, String)>,
) -> Response {
    let Ok(Some(bot)) = bot_for_conversation(&state, &conversation_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let file = match state.store.list_conversation_files(&conversation_id).await {
        Ok(files) => files.into_iter().find(|file| file.id == file_id),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "file could not be loaded",
            )
                .into_response()
        }
    };
    let Some(file) = file else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if !matches!(file.kind.as_str(), "attachment" | "artifact") || file.state != "available" {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Some(relative_path) = file.relative_path.as_deref() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let path = if file.kind == "attachment" {
        if relative_path != attachment_relative_path(&file.id) {
            return StatusCode::NOT_FOUND.into_response();
        }
        let Ok(workspace) = group_attachments::storage_workspace(
            &state,
            &conversation_id,
            &bot.workspace_path,
            false,
        )
        .await
        else {
            return StatusCode::NOT_FOUND.into_response();
        };
        let Some(path) = attachment_path(&workspace, &file.id, false).await else {
            return StatusCode::FORBIDDEN.into_response();
        };
        path
    } else {
        if sanitized_relative_path(relative_path, &bot.workspace_path).as_deref()
            != Some(relative_path)
        {
            return StatusCode::NOT_FOUND.into_response();
        }
        let Some(path) = workspace_file_path(&bot.workspace_path, relative_path).await else {
            return StatusCode::NOT_FOUND.into_response();
        };
        path
    };
    let Ok(bytes) = tokio::fs::read(path).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if let Some(expected_byte_size) = file.byte_size {
        if expected_byte_size != bytes.len() as i64 {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "file integrity check failed",
            )
                .into_response();
        }
    }
    if let Some(expected_sha256) = file.sha256.as_deref() {
        let actual_sha256 = hex::encode(Sha256::digest(&bytes));
        if actual_sha256 != expected_sha256 {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "file integrity check failed",
            )
                .into_response();
        }
    }
    let content_type = file
        .mime_type
        .as_deref()
        .unwrap_or("application/octet-stream");
    let safe_name = file.name.replace(['"', '\\', '\r', '\n'], "_");
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(content_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream")),
    );
    headers.insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_str(&format!("attachment; filename=\"{safe_name}\""))
            .unwrap_or_else(|_| HeaderValue::from_static("attachment")),
    );
    (headers, Body::from(bytes)).into_response()
}

async fn create_bot(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Json(mut request): Json<CreateBotRequest>,
) -> Response {
    let uses_default_permissions =
        request.permission_mode.is_none() && request.approval_mode.is_none();
    if let Err(message) = permission_modes::normalize_create_request(&mut request) {
        return (StatusCode::BAD_REQUEST, message).into_response();
    }
    if let Err(message) =
        file_access::normalize_roots(&mut request.read_roots, &mut request.write_roots)
    {
        return (StatusCode::BAD_REQUEST, message).into_response();
    }
    let name = request.name.trim();
    let role = request.role.trim();
    let system_prompt = request.system_prompt.trim();
    if name.is_empty()
        || name.len() > 80
        || role.is_empty()
        || role.len() > 160
        || system_prompt.is_empty()
        || system_prompt.len() > 8_000
    {
        return (StatusCode::BAD_REQUEST, "invalid Bot profile").into_response();
    }

    {
        let catalog = state.runtime_catalog.read().await;
        if let Err(message) = validate_bot_runtime_settings(
            &catalog,
            request.model.as_deref().map(str::trim),
            request.reasoning_effort.as_deref().map(str::trim),
            request.service_tier.as_deref().map(str::trim),
        ) {
            return (StatusCode::BAD_REQUEST, message).into_response();
        }
    }

    // Legacy permission overrides restart App Server and must wait for idle.
    // Built-in profiles only verify the new workspace; keep active turns running.
    let _lifecycle_guard = state.dispatch_lock.lock().await;
    match state.store.has_unsettled_execution().await {
        Ok(true) if uses_default_permissions => {
            return (
                StatusCode::CONFLICT,
                "Cannot create a Bot while an App Server turn is active",
            )
                .into_response()
        }
        Ok(_) => {}
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Wonder could not verify active App Server turns",
            )
                .into_response()
        }
    }

    let id = request
        .client_request_id
        .clone()
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let profile = format!("wonder_bot_{}", id.replace('-', ""));
    let home = FsPath::new(&state.bots_root).join(&id);
    if let Err(message) = bot_management::prepare_private_home(&state.bots_root, &home, &id).await {
        return (StatusCode::CONFLICT, message).into_response();
    }
    let home_string = tokio::fs::canonicalize(&home)
        .await
        .unwrap_or_else(|_| home.clone())
        .to_string_lossy()
        .into_owned();
    if state
        .store
        .upsert_bot_with_service_tier(
            &id,
            name,
            role,
            system_prompt,
            &home_string,
            &profile,
            request.model.as_deref(),
            request.reasoning_effort.as_deref(),
            request.service_tier.as_deref(),
            &now_ms().to_string(),
        )
        .await
        .is_err()
    {
        let _ = tokio::fs::remove_dir_all(&home).await;
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "Bot profile could not be saved",
        )
            .into_response();
    }

    let denied_roots = state
        .denied_roots
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>();
    let Some(bot) = state.store.bot(&id).await.ok().flatten() else {
        rollback_new_bot(&state, &id, &home, None).await;
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    if request.permission_mode.is_some() || request.approval_mode.is_some() {
        return match permission_modes::create_native(&state, bot, &request).await {
            Ok(summary) => Json(summary).into_response(),
            Err(error) => {
                rollback_new_bot(&state, &id, &home, None).await;
                error.into_response()
            }
        };
    }
    let access = wonder_store::BotFileAccess {
        read_roots: request.read_roots,
        write_roots: request.write_roots,
        ..Default::default()
    };
    let override_value = match file_access::configured_override(&bot, &access, &denied_roots) {
        Ok(value) => value,
        Err(_) => {
            rollback_new_bot(&state, &id, &home, None).await;
            return (
                StatusCode::BAD_REQUEST,
                "That location cannot be granted. Choose a project file or folder.",
            )
                .into_response();
        }
    };
    if (!access.read_roots.is_empty() || !access.write_roots.is_empty())
        && !matches!(
            state
                .store
                .save_bot_file_access(&id, 0, &access.read_roots, &access.write_roots)
                .await,
            Ok(true)
        )
    {
        rollback_new_bot(&state, &id, &home, None).await;
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Could not save file access. Try creating the Bot again.",
        )
            .into_response();
    }
    let launch_config = {
        let mut config = state.launch_config.lock().await;
        if !config
            .permission_overrides
            .iter()
            .any(|value| value == &override_value)
        {
            config.permission_overrides.push(override_value.clone());
        }
        config.clone()
    };
    let mut app_server = state.app_server.lock().await;
    if app_server.restart(launch_config).await.is_err() {
        drop(app_server);
        rollback_new_bot(&state, &id, &home, Some(&override_value)).await;
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Wonder could not activate this Bot yet",
        )
            .into_response();
    }
    let profile_check = app_server
        .request(
            "permissionProfile/list",
            serde_json::json!({ "cwd": home_string }),
        )
        .await;
    let profile_ok = profile_check
        .ok()
        .and_then(|response| response.result)
        .is_some_and(|result| {
            require_named_profile_with_scope(
                &result,
                &profile,
                &home_string,
                &state
                    .denied_roots
                    .iter()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
            )
            .is_ok()
        });
    let access_ok = profile_ok
        && file_access::verify(&state, &mut app_server, &bot)
            .await
            .is_ok();
    drop(app_server);
    if !access_ok {
        rollback_new_bot(&state, &id, &home, Some(&override_value)).await;
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Wonder could not verify this Bot yet",
        )
            .into_response();
    }
    if let Some(directory) = request
        .working_directory
        .as_deref()
        .filter(|p| !p.trim().is_empty())
    {
        if let Err((status, message)) =
            bot_management::validate_directory(&state, &bot, directory).await
        {
            rollback_new_bot(&state, &id, &home, Some(&override_value)).await;
            return (status, message).into_response();
        }
        if state
            .store
            .save_bot_presentation(
                &id,
                None,
                None,
                request.avatar_color.as_deref(),
                Some(directory),
            )
            .await
            .is_err()
        {
            rollback_new_bot(&state, &id, &home, Some(&override_value)).await;
            return StatusCode::SERVICE_UNAVAILABLE.into_response();
        }
    }
    // The runtime catalog was discovered before this Bot existed. Keep the
    // newly verified generated profile available to dispatch/settings
    // validation without requiring another daemon restart.
    state
        .runtime_catalog
        .write()
        .await
        .permission_profiles_by_cwd
        .insert(
            home_string.clone(),
            vec![PermissionProfileOption {
                id: profile.clone(),
                description: None,
                allowed: true,
            }],
        );

    let conversation_id = match state
        .store
        .ensure_bot_workspace(&id, name, &now_ms().to_string())
        .await
    {
        Ok(conversation_id) => conversation_id,
        Err(_) => {
            rollback_new_bot(&state, &id, &home, Some(&override_value)).await;
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Wonder could not create this Bot workspace",
            )
                .into_response();
        }
    };

    Json(BotSummary {
        permission_mode: None,
        approval_mode: None,
        id,
        name: name.to_owned(),
        role: role.to_owned(),
        system_prompt: system_prompt.to_owned(),
        working_directory: request
            .working_directory
            .filter(|p| !p.trim().is_empty())
            .unwrap_or_else(|| home_string.clone()),
        avatar_color: request.avatar_color,
        avatar_shape: None,
        avatar_palette: None,
        workspace_path: home_string,
        permission_profile: profile,
        model: request.model,
        reasoning_effort: request.reasoning_effort,
        service_tier: request.service_tier,
        archived: false,
        conversation_id: Some(conversation_id),
    })
    .into_response()
}

pub fn computer_use_tool_spec() -> serde_json::Value {
    serde_json::json!({
        "type": "function",
        "name": "wonder_computer_use",
        "description": "Request one narrow, unlocked Mac computer-use action. Full Access turns execute directly; other turns pause for owner approval of the exact action in Wonder. Use screenshot to inspect the screen before click, type, key, or focusApp. macOS Screen Recording and Accessibility permissions are still required.",
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["status", "screenshot", "click", "type", "key", "focusApp"]
                },
                "x": { "type": "number", "description": "Visible-screen x coordinate for click." },
                "y": { "type": "number", "description": "Visible-screen y coordinate for click." },
                "text": { "type": "string", "description": "Text to type, limited by Wonder." },
                "keyCode": { "type": "integer", "minimum": 0, "maximum": 65535 },
                "modifiers": { "type": "integer", "minimum": 0 },
                "bundleId": { "type": "string", "description": "Running application bundle identifier to focus." }
            },
            "required": ["action"]
        }
    })
}

async fn start_bot_thread(
    state: &AppState,
    app_server: &mut AppServerClient,
    conversation_id: &str,
    bot: &StoredBot,
    resolved: &EffectiveConversationSettings,
) -> Result<String, String> {
    file_access::dispatch_check(state, bot, &resolved.permission_profile).await?;
    let onboarding = bot_onboarding::enabled(state, conversation_id, bot).await?;
    let mut params = serde_json::json!({
        "cwd": bot.execution_directory(),
        "permissions": resolved.permission_profile,
        "runtimeWorkspaceRoots": permission_modes::runtime_roots(state, bot).await?,
        "approvalPolicy": resolved.approval_policy,
        "approvalsReviewer": resolved.approvals_reviewer,
        "serviceName": "wonder",
        "model": resolved.model,
        "serviceTier": resolved.service_tier,
        "developerInstructions": bot_onboarding::instructions(bot, onboarding),
    });
    let computer = state.computer_use_enabled
        && state.computer_use_bin.is_some()
        && group_collaboration::allows_computer(state, conversation_id, &bot.id).await?;
    let pm = pm_tools::enabled(state, conversation_id, &bot.id).await?;
    let mut tools = if pm { pm_tools::specs() } else { Vec::new() };
    if onboarding {
        tools.push(bot_onboarding::spec());
        tools.push(bot_onboarding::question_spec());
        tools.push(bot_onboarding::workspace_spec());
    }
    if state
        .store
        .collaboration_owner(conversation_id)
        .await
        .map_err(|e| e.to_string())?
        .is_some()
    {
        tools.extend(group_collaboration::specs());
    }
    if computer {
        tools.push(computer_use_tool_spec());
    }
    if !tools.is_empty() {
        params["dynamicTools"] = serde_json::json!(tools);
    }
    let response = app_server
        .request("thread/start", params)
        .await
        .map_err(|error| error.to_string())?;
    if let Some(error) = response.error {
        return Err(format!("App Server thread/start rejected: {error:?}"));
    }
    let thread = response
        .result
        .as_ref()
        .and_then(|result| result.get("thread"))
        .ok_or_else(|| "thread/start returned no thread".to_owned())?;
    let thread_id = thread
        .get("id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "thread/start returned no thread id".to_owned())?
        .to_owned();
    let session_id = thread.get("sessionId").and_then(serde_json::Value::as_str);
    state
        .store
        .set_conversation_thread(conversation_id, &thread_id, session_id, &state.started_at)
        .await
        .map_err(|error| error.to_string())?;
    state
        .store
        .mark_conversation_dynamic_tools(
            conversation_id,
            &format!(
                "{}{}",
                pm_tools::version(computer, pm),
                if onboarding {
                    "+wonder-bot-profile-v3"
                } else {
                    ""
                }
            ),
        )
        .await
        .map_err(|error| error.to_string())?;
    Ok(thread_id)
}

async fn conversation_needs_tool_migration(
    state: &AppState,
    conversation_id: &str,
    existing_thread_id: Option<&str>,
) -> Result<bool, String> {
    if existing_thread_id.is_none() {
        return Ok(false);
    }
    let computer = state.computer_use_enabled && state.computer_use_bin.is_some();
    let pm = if let Some(bot) = bot_for_conversation(state, conversation_id)
        .await
        .map_err(|error| error.to_string())?
    {
        pm_tools::enabled(state, conversation_id, &bot.id).await?
    } else {
        false
    };
    let onboarding = if let Some(bot) = bot_for_conversation(state, conversation_id)
        .await
        .map_err(|e| e.to_string())?
    {
        bot_onboarding::enabled(state, conversation_id, &bot).await?
    } else {
        false
    };
    let saved = state
        .store
        .conversation_dynamic_tools_version(conversation_id)
        .await
        .map_err(|error| error.to_string())?;
    if !computer && !pm && !onboarding && saved.is_none() {
        return Ok(false);
    }
    Ok(saved.as_deref()
        != Some(
            format!(
                "{}{}",
                pm_tools::version(computer, pm),
                if onboarding {
                    "+wonder-bot-profile-v3"
                } else {
                    ""
                }
            )
            .as_str(),
        ))
}

async fn run_computer_use(
    binary: &FsPath,
    params: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    let arguments = computer_tools::arguments(params)?;
    let action = arguments["action"].as_str().unwrap().to_owned();
    let handshake = uuid::Uuid::new_v4().to_string();
    let mut child = Command::new(binary)
        .arg("--stdio")
        .env("WONDER_COMPUTER_USE_HANDSHAKE", &handshake)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|error| format!("computer-use service unavailable: {error}"))?;
    let result = async {
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| "computer-use service stdin unavailable".to_owned())?;
        let mut request_arguments = arguments;
        request_arguments["handshake"] = serde_json::Value::String(handshake);
        let request = serde_json::json!({ "id": 1, "method": action, "params": request_arguments });
        let encoded = serde_json::to_string(&request).map_err(|error| error.to_string())?;
        stdin
            .write_all(encoded.as_bytes())
            .await
            .map_err(|error| error.to_string())?;
        stdin
            .write_all(b"\n")
            .await
            .map_err(|error| error.to_string())?;
        stdin
            .write_all(b"{\"id\":2,\"method\":\"stop\"}\n")
            .await
            .map_err(|error| error.to_string())?;
        drop(stdin);
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "computer-use service stdout unavailable".to_owned())?;
        let mut lines = BufReader::new(stdout).lines();
        let line = lines
            .next_line()
            .await
            .map_err(|error| error.to_string())?
            .ok_or_else(|| "computer-use service returned no response".to_owned())?;
        if line.len() > MAX_COMPUTER_USE_LINE_BYTES {
            return Err("computer-use response exceeded the size limit".into());
        }
        let status = child.wait().await.map_err(|error| error.to_string())?;
        if !status.success() {
            return Err("computer-use service failed".into());
        }
        let response =
            serde_json::from_str::<serde_json::Value>(&line).map_err(|error| error.to_string())?;
        if let Some(error) = response.get("error") {
            return Err(match error.as_str() {
                Some("screen_recording_required") => "Allow Wonder screen recording in macOS System Settings, then request the screenshot again.",
                Some("accessibility_required") => "Allow Wonder accessibility access in macOS System Settings, then request the action again.",
                Some("app_not_found") => "The requested Mac app could not be found.",
                Some("invalid_input") => "The computer action contains invalid input.",
                Some("screenshot_failed") => "The Mac could not capture a screenshot. Request another screenshot.",
                _ => "The computer-use service rejected the request.",
            }.into());
        }
        response
            .get("result")
            .cloned()
            .ok_or_else(|| "computer-use service returned no result".into())
    };
    match timeout(Duration::from_secs(30), result).await {
        Ok(Ok(response)) => Ok(response),
        Ok(Err(error)) => {
            kill_and_reap(&mut child).await;
            Err(error)
        }
        Err(_) => {
            kill_and_reap(&mut child).await;
            Err("computer-use service timed out".into())
        }
    }
}

fn dynamic_tool_response(result: Result<serde_json::Value, String>) -> serde_json::Value {
    let result = match result {
        Ok(result) => result,
        Err(error) => {
            return serde_json::json!({"success":false,"contentItems":[{"type":"inputText","text":error}]})
        }
    };
    if result
        .get("error")
        .and_then(serde_json::Value::as_str)
        .is_some()
    {
        return serde_json::json!({ "success": false, "contentItems": [] });
    }
    if let (Some(mime_type), Some(image)) = (
        result.get("mimeType").and_then(serde_json::Value::as_str),
        result
            .get("imageBase64")
            .and_then(serde_json::Value::as_str),
    ) {
        if mime_type == "image/png" && image.len() <= MAX_COMPUTER_USE_LINE_BYTES {
            let mut content_items = vec![serde_json::json!({
                "type": "inputImage",
                "imageUrl": format!("data:{mime_type};base64,{image}"),
            })];
            if let Some(observation) = result.get("observation") {
                let observation_text = serde_json::to_string(&serde_json::json!({
                    "action": result.get("action"),
                    "computerUseObservation": observation,
                }))
                .unwrap_or_else(|_| "computer-use observation unavailable".into());
                content_items.push(serde_json::json!({
                    "type": "inputText",
                    "text": observation_text,
                }));
            }
            return serde_json::json!({
                "success": true,
                "contentItems": content_items,
            });
        }
        return serde_json::json!({ "success": false, "contentItems": [] });
    }
    let text = serde_json::to_string(&result).unwrap_or_else(|_| "computer-use completed".into());
    serde_json::json!({
        "success": true,
        "contentItems": [{ "type": "inputText", "text": text }]
    })
}

fn computer_use_screenshot_url(response: &serde_json::Value) -> Option<String> {
    let image_url = response
        .get("contentItems")
        .and_then(serde_json::Value::as_array)
        .and_then(|items| items.first())
        .and_then(|item| item.get("imageUrl"))
        .and_then(serde_json::Value::as_str)
        .filter(|value| value.starts_with("data:image/png;base64,"))
        .filter(|value| value.len() <= MAX_COMPUTER_USE_LINE_BYTES)?;
    Some(image_url.to_owned())
}

async fn kill_and_reap(child: &mut tokio::process::Child) {
    let _ = child.kill().await;
    let _ = child.wait().await;
}

async fn send_message(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
    local_authority: Option<Extension<LocalOwnerAuthority>>,
    Json(request): Json<SendMessageRequest>,
) -> Response {
    if request.device_id == "wonder-desktop" {
        if local_authority.is_none() {
            return StatusCode::FORBIDDEN.into_response();
        }
        if state
            .store
            .ensure_local_desktop(&now_ms().to_string())
            .await
            .is_err()
        {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Desktop identity could not be saved",
            )
                .into_response();
        }
    }
    send_message_inner(
        State(state),
        Path(conversation_id),
        authenticated_device,
        Json(request),
        None,
    )
    .await
}

async fn send_message_inner(
    State(state): State<AppState>,
    Path(conversation_id): Path<String>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
    Json(request): Json<SendMessageRequest>,
    channel_id: Option<&str>,
) -> Response {
    if let Some(response) = subagents::reject_user_mutation(&state, &conversation_id).await {
        return response;
    }
    if (request.body.trim().is_empty() && request.attachment_ids.is_empty())
        || request.body.len() > 64 * 1024
    {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            "message body must be between 1 and 65536 bytes",
        )
            .into_response();
    }
    if !valid_attachment_ids(&request.attachment_ids) {
        return (StatusCode::BAD_REQUEST, "invalid attachmentIds").into_response();
    }
    if uuid::Uuid::parse_str(&request.client_message_id).is_err() {
        return (StatusCode::BAD_REQUEST, "clientMessageId must be a UUID").into_response();
    }
    if let Some(Extension(AuthenticatedDevice { device_id, .. })) = authenticated_device {
        if request.device_id != device_id {
            return (StatusCode::FORBIDDEN, "device identity mismatch").into_response();
        }
    }
    let child = match subagents::runtime_for_conversation(&state, &conversation_id).await {
        Ok(child) => child,
        Err(_) => {
            return (
                StatusCode::CONFLICT,
                "This subagent is unavailable. Reopen its parent conversation.",
            )
                .into_response()
        }
    };
    let conversation_id = if channel_id.is_some() || child.is_some() {
        // Groups and verified children own their exact durable conversation.
        // Legacy Bot-ID normalization must not redirect a child to its parent.
        conversation_id
    } else {
        match bot_for_conversation(&state, &conversation_id).await {
            Ok(Some(bot)) => {
                // Older clients addressed a Bot by its raw id. Converge that
                // route on the durable workspace conversation before
                // persisting the message so retries and streamed events share
                // one identity.
                if bot.conversation_id.is_none()
                    || bot.conversation_id.as_deref() == Some(&conversation_id)
                {
                    conversation_id
                } else {
                    bot.conversation_id.unwrap_or(conversation_id)
                }
            }
            Ok(None) => return StatusCode::NOT_FOUND.into_response(),
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "conversation lookup failed",
                )
                    .into_response()
            }
        }
    };
    match state
        .store
        .bot_initialization(&conversation_id, now_ms() as i64)
        .await
    {
        Ok(Some(initialization)) if initialization.question_id.is_none() => {
            return (
                StatusCode::CONFLICT,
                "Your Bot is getting ready. Wait for its first question before sending.",
            )
                .into_response();
        }
        Ok(_) => {}
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
    let body_sha256 = hex::encode(Sha256::digest(request.body.as_bytes()));
    let created_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let insert = match state
        .store
        .insert_dispatch_message(
            &request.device_id,
            &request.client_message_id,
            &request.body,
            &body_sha256,
            &conversation_id,
            &request.attachment_ids,
            &created_at,
            channel_id.is_none(),
        )
        .await
    {
        Ok(insert) => insert,
        Err(error) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, error.to_string()).into_response()
        }
    };
    let stored = match insert {
        MessageInsert::Inserted(message) | MessageInsert::Existing(message) => message,
        MessageInsert::Conflict => {
            return (
                StatusCode::CONFLICT,
                [(header::CACHE_CONTROL, "no-store")],
                Json(serde_json::json!({ "error": "idempotency_conflict" })),
            )
                .into_response()
        }
    };
    if state
        .store
        .dismiss_initialization_question(&conversation_id)
        .await
        .is_err()
    {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Message saved; retry to finish sending.",
        )
            .into_response();
    }
    if let Some(channel_id) = channel_id {
        if state
            .store
            .add_channel_message(NewChannelMessage {
                channel_id,
                message_id: &stored.id,
                author_kind: "user",
                author_bot_id: None,
                phase: "user",
                created_at: &created_at,
                presentation_kind: "message",
                outcome: Some("completed"),
                retryable: false,
            })
            .await
            .is_err()
        {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "channel message attribution could not be saved",
            )
                .into_response();
        }
    }
    let Some(receipt) = message_receipt(stored.clone()) else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "stored message has an unknown delivery state",
        )
            .into_response();
    };
    (
        StatusCode::ACCEPTED,
        [(header::CACHE_CONTROL, "no-store")],
        Json(receipt),
    )
        .into_response()
}

async fn steer_turn(
    State(state): State<AppState>,
    Path((conversation_id, turn_id)): Path<(String, String)>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
    Json(request): Json<SteerTurnRequest>,
) -> Response {
    if let Some(response) = subagents::reject_user_mutation(&state, &conversation_id).await {
        return response;
    }
    if (request.body.trim().is_empty() && request.attachment_ids.is_empty())
        || request.body.len() > 65536
        || !valid_attachment_ids(&request.attachment_ids)
        || uuid::Uuid::parse_str(&request.client_message_id).is_err()
        || request.expected_turn_id != turn_id
    {
        return StatusCode::BAD_REQUEST.into_response();
    }
    if authenticated_device.is_some_and(|Extension(device)| device.device_id != request.device_id) {
        return StatusCode::FORBIDDEN.into_response();
    }
    // Group Guide has no safe orchestration target yet.
    match state.store.list_channels().await {
        Ok(groups) if groups.iter().any(|g| g.conversation_id == conversation_id) => {
            return (StatusCode::CONFLICT, "Guide is unavailable for Group Chats").into_response()
        }
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        _ => {}
    }
    let child = match subagents::runtime_for_conversation(&state, &conversation_id).await {
        Ok(child) => child,
        Err(_) => {
            return (
                StatusCode::CONFLICT,
                "This subagent is unavailable. Reopen its parent conversation.",
            )
                .into_response()
        }
    };
    if state
        .store
        .message_by_device_and_client_message_id(&request.device_id, &request.client_message_id)
        .await
        .ok()
        .flatten()
        .is_none()
    {
        let active = if let Some(child) = child.as_ref() {
            child_turn_is_active(child, &turn_id, true)
                .await
                .unwrap_or(false)
        } else {
            matches!(state.store.message_for_codex_turn(&turn_id).await,
                Ok(Some(m)) if m.conversation_id == conversation_id
                    && matches!(m.state.as_str(), "accepted_by_codex" | "streaming"))
        };
        if !active {
            return (StatusCode::PRECONDITION_FAILED,
                "This work is no longer active or cannot accept Guide. Your Guide has not been sent.").into_response();
        }
    }
    let hash = hex::encode(Sha256::digest(request.body.as_bytes()));
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    match state
        .store
        .insert_guide_message(
            &request.device_id,
            &request.client_message_id,
            &request.body,
            &hash,
            &conversation_id,
            &request.attachment_ids,
            &now,
            &turn_id,
        )
        .await
    {
        Ok(MessageInsert::Inserted(message) | MessageInsert::Existing(message)) => {
            match message_receipt(message) {
                Some(receipt) => (StatusCode::ACCEPTED, Json(receipt)).into_response(),
                None => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
            }
        }
        Ok(MessageInsert::Conflict) => StatusCode::CONFLICT.into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn dispatch_guide(
    state: AppState,
    steered_message: wonder_store::StoredMessage,
    turn_id: String,
) -> Response {
    let conversation_id = steered_message.conversation_id.clone();
    let _dispatch_guard = state.dispatch_lock.lock().await;
    let target = async {
        if state
            .store
            .subagent_ownership_for_conversation(&conversation_id)
            .await
            .map_err(|e| e.to_string())?
            .is_some()
        {
            return Err(
                "Agent tasks are read-only. Continue in the parent conversation.".to_owned(),
            );
        }
        if let Some(child) = subagents::runtime_for_conversation(&state, &conversation_id).await? {
            if !child_turn_is_active(&child, &turn_id, true).await? {
                return Err("This subagent cannot accept Guide for that turn".into());
            }
            return Ok((child.ownership.thread_id, child.rpc));
        }
        let active_message = match state.store.message_for_codex_turn(&turn_id).await {
            Ok(Some(m))
                if m.conversation_id == conversation_id
                    && matches!(m.state.as_str(), "accepted_by_codex" | "streaming") =>
            {
                m
            }
            _ => return Err("This work is no longer active".to_owned()),
        };
        let thread_id = active_message
            .codex_thread_id
            .ok_or("This work has no runtime thread")?;
        Ok::<_, String>((thread_id, state.app_server.lock().await.rpc()))
    }
    .await;
    let (active_thread_id, runtime) = match target {
        Ok(target) => target,
        Err(_) => {
            let _ = state
                .store
                .update_message_delivery(&steered_message.id, "failed", None, None)
                .await;
            publish_message_state(&state, &steered_message, DeliveryState::Failed, None, None)
                .await;
            return StatusCode::CONFLICT.into_response();
        }
    };
    let attachments = match state
        .store
        .attachments_for_message(&steered_message.id)
        .await
    {
        Ok(attachments) => attachments,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "message attachments could not be loaded",
            )
                .into_response()
        }
    };
    let workspace = match bot_for_conversation(&state, &conversation_id).await {
        Ok(Some(bot)) => bot.workspace_path,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "conversation lookup failed",
            )
                .into_response()
        }
    };
    let input = turn_input(&steered_message.body, &workspace, &attachments);
    if !state
        .store
        .claim_guide(&steered_message.id, &active_thread_id)
        .await
        .unwrap_or(false)
    {
        return StatusCode::CONFLICT.into_response();
    }
    let response = runtime
        .request(
            "turn/steer",
            steer_turn_params_with_attachments(
                &active_thread_id,
                &turn_id,
                &steered_message.client_message_id,
                input,
            ),
        )
        .await;
    let response = match response {
        Ok(response) if response.error.is_none() => response,
        Ok(_) => {
            let _ = state
                .store
                .update_message_delivery(&steered_message.id, "uncertain", None, None)
                .await;
            return (StatusCode::BAD_GATEWAY, "App Server rejected steer").into_response();
        }
        Err(_) => {
            let _ = state
                .store
                .update_message_delivery(&steered_message.id, "uncertain", None, None)
                .await;
            drop(_dispatch_guard);
            match restart_and_reconcile(&state, &steered_message).await {
                Some(ReconcileResult::Accepted { thread_id, turn_id }) => {
                    let _ = state
                        .store
                        .update_message_delivery(
                            &steered_message.id,
                            "accepted_by_codex",
                            Some(&thread_id),
                            Some(&turn_id),
                        )
                        .await;
                    publish_message_state(
                        &state,
                        &steered_message,
                        DeliveryState::AcceptedByCodex,
                        Some(&thread_id),
                        Some(&turn_id),
                    )
                    .await;
                    return (
                        StatusCode::ACCEPTED,
                        [(header::CACHE_CONTROL, "no-store")],
                        Json(ClientMessageReceipt {
                            client_message_id: steered_message.client_message_id,
                            wonder_message_id: steered_message.id,
                            body_sha256: steered_message.body_sha256,
                            conversation_id: steered_message.conversation_id,
                            delivery_state: DeliveryState::AcceptedByCodex,
                            codex_thread_id: Some(thread_id),
                            codex_turn_id: Some(turn_id),
                        }),
                    )
                        .into_response();
                }
                None => {
                    return (
                        StatusCode::SERVICE_UNAVAILABLE,
                        "App Server steer remains uncertain",
                    )
                        .into_response();
                }
            }
        }
    };
    let Some(next_turn_id) = steer_response_turn_id(&response) else {
        let _ = state
            .store
            .update_message_delivery(&steered_message.id, "uncertain", None, None)
            .await;
        return (
            StatusCode::BAD_GATEWAY,
            "App Server steer returned no turn id",
        )
            .into_response();
    };
    let thread_id = Some(active_thread_id);
    let _ = state
        .store
        .update_message_delivery(
            &steered_message.id,
            "accepted_by_codex",
            thread_id.as_deref(),
            Some(&next_turn_id),
        )
        .await;
    publish_message_state(
        &state,
        &steered_message,
        DeliveryState::AcceptedByCodex,
        thread_id.as_deref(),
        Some(&next_turn_id),
    )
    .await;
    (
        StatusCode::ACCEPTED,
        [(header::CACHE_CONTROL, "no-store")],
        Json(ClientMessageReceipt {
            client_message_id: steered_message.client_message_id,
            wonder_message_id: steered_message.id,
            body_sha256: steered_message.body_sha256,
            conversation_id: steered_message.conversation_id,
            delivery_state: DeliveryState::AcceptedByCodex,
            codex_thread_id: thread_id,
            codex_turn_id: Some(next_turn_id),
        }),
    )
        .into_response()
}

async fn interrupt_turn(
    State(state): State<AppState>,
    Path((conversation_id, turn_id)): Path<(String, String)>,
) -> Response {
    if let Some(response) = subagents::reject_user_mutation(&state, &conversation_id).await {
        return response;
    }
    match subagents::runtime_for_conversation(&state, &conversation_id).await {
        Ok(Some(child)) => {
            match child_turn_status(&child, &turn_id).await {
                Ok(Some(status)) if status == "interrupted" => {
                    return StatusCode::NO_CONTENT.into_response()
                }
                Ok(Some(status))
                    if status == "inProgress"
                        && child
                            .thread
                            .pointer("/status/type")
                            .and_then(serde_json::Value::as_str)
                            == Some("active") => {}
                _ => {
                    return (
                        StatusCode::CONFLICT,
                        "This subagent's turn is no longer active",
                    )
                        .into_response()
                }
            }
            let response = child
                .rpc
                .request(
                    "turn/interrupt",
                    serde_json::json!({
                        "threadId": child.ownership.thread_id, "turnId": turn_id
                    }),
                )
                .await;
            match response {
                Ok(response) if response.error.is_none() => {}
                _ => {
                    return (
                        StatusCode::SERVICE_UNAVAILABLE,
                        "The subagent could not be stopped. Refresh its conversation.",
                    )
                        .into_response()
                }
            }
            // There may be no user receipt: spawned work belongs to the child
            // through verified runtime metadata, not a fabricated user message.
            if let Ok(Some(message)) = state.store.message_for_codex_turn(&turn_id).await {
                if message.conversation_id == conversation_id
                    && message.codex_thread_id.as_deref()
                        == Some(child.ownership.thread_id.as_str())
                    && state
                        .store
                        .interrupt_message_if_active(&message.id)
                        .await
                        .unwrap_or(false)
                {
                    publish_message_state(
                        &state,
                        &message,
                        DeliveryState::Interrupted,
                        Some(&child.ownership.thread_id),
                        Some(&turn_id),
                    )
                    .await;
                }
            }
            return StatusCode::NO_CONTENT.into_response();
        }
        Ok(None) => {}
        Err(_) => {
            return (
                StatusCode::CONFLICT,
                "This subagent is unavailable. Reopen its parent conversation.",
            )
                .into_response()
        }
    }
    let message = match state.store.message_for_codex_turn(&turn_id).await {
        Ok(Some(message)) if message.conversation_id == conversation_id => message,
        Ok(Some(_)) => return StatusCode::NOT_FOUND.into_response(),
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, "turn lookup failed").into_response(),
    };
    let Some(thread_id) = message.codex_thread_id.as_deref() else {
        return (StatusCode::CONFLICT, "turn has no Codex thread").into_response();
    };
    if message.state == "interrupted" {
        return StatusCode::NO_CONTENT.into_response();
    }
    if !matches!(message.state.as_str(), "accepted_by_codex" | "streaming") {
        return (StatusCode::CONFLICT, "turn is no longer active").into_response();
    }
    let runtime = state.app_server.lock().await.rpc();
    let response = runtime
        .request(
            "turn/interrupt",
            serde_json::json!({ "threadId": thread_id, "turnId": turn_id }),
        )
        .await;
    let Ok(response) = response else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "App Server interrupt failed",
        )
            .into_response();
    };
    if response.error.is_some() {
        return (StatusCode::BAD_GATEWAY, "App Server rejected interrupt").into_response();
    }
    match state.store.interrupt_message_if_active(&message.id).await {
        Ok(true) => {}
        Ok(false) => {
            return (
                StatusCode::CONFLICT,
                "turn completed before Stop was recorded",
            )
                .into_response()
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "turn state update failed",
            )
                .into_response()
        }
    }
    publish_message_state(
        &state,
        &message,
        DeliveryState::Interrupted,
        Some(thread_id),
        Some(&turn_id),
    )
    .await;
    StatusCode::NO_CONTENT.into_response()
}

async fn retry_message(
    State(state): State<AppState>,
    Path(message_id): Path<String>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
) -> Response {
    let Some(Extension(AuthenticatedDevice { device_id, .. })) = authenticated_device else {
        return (StatusCode::UNAUTHORIZED, "paired device required").into_response();
    };
    let message = match state.store.message_by_id(&message_id).await {
        Ok(Some(message)) => message,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, "message lookup failed").into_response()
        }
    };
    if let Some(response) = subagents::reject_user_mutation(&state, &message.conversation_id).await
    {
        return response;
    }
    if message.device_id != device_id {
        return (StatusCode::FORBIDDEN, "device identity mismatch").into_response();
    }
    if !matches!(message.state.as_str(), "safe_to_retry" | "failed") {
        return (
            StatusCode::CONFLICT,
            Json(
                serde_json::json!({ "error": "message_not_safe_to_retry", "state": message.state }),
            ),
        )
            .into_response();
    }
    if !state
        .store
        .is_durable_dispatch(&message.id)
        .await
        .unwrap_or(false)
    {
        return (
            StatusCode::CONFLICT,
            "Send a new message for this kind of work",
        )
            .into_response();
    }
    match state.store.requeue_message_for_retry(&message.id).await {
        Ok(true) => {
            publish_message_state(
                &state,
                &message,
                DeliveryState::AcceptedByWonder,
                None,
                None,
            )
            .await;
            (
                StatusCode::ACCEPTED,
                [(header::CACHE_CONTROL, "no-store")],
                Json(ClientMessageReceipt {
                    client_message_id: message.client_message_id,
                    wonder_message_id: message.id,
                    body_sha256: message.body_sha256,
                    conversation_id: message.conversation_id,
                    delivery_state: DeliveryState::AcceptedByWonder,
                    codex_thread_id: message.codex_thread_id,
                    codex_turn_id: message.codex_turn_id,
                }),
            )
                .into_response()
        }
        Ok(false) => (
            StatusCode::CONFLICT,
            Json(serde_json::json!({ "error": "message_not_safe_to_retry" })),
        )
            .into_response(),
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "message retry failed").into_response(),
    }
}

pub fn spawn_automation_scheduler(state: AppState) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        let mut recovered = false;
        loop {
            interval.tick().await;
            if !state.ingestion.readiness(&state.store).await.ready {
                continue;
            }
            let now = Utc::now();
            let now_string = now.to_rfc3339_opts(SecondsFormat::Millis, true);
            if state
                .store
                .reconcile_automation_runs(&now_string)
                .await
                .is_err()
            {
                continue;
            }
            if !recovered {
                let Ok(runs) = state.store.recoverable_automation_runs().await else {
                    continue;
                };
                recovered = true;
                for (run, automation) in runs {
                    tokio::spawn(run_automation(
                        state.clone(),
                        automation,
                        run.scheduled_for,
                        run.id,
                    ));
                }
            }
            let Ok(due) = state.store.list_due_automations(&now_string).await else {
                continue;
            };
            for automation in due {
                let Some(scheduled_for) = automation.next_run_at.clone() else {
                    continue;
                };
                if automation_target_available(
                    &state,
                    &automation.bot_id,
                    &automation.scope_type,
                    &automation.scope_id,
                    &automation.kind,
                    automation.conversation_id.as_deref(),
                )
                .await
                .is_err()
                {
                    continue;
                }
                // One catch-up at most. While a run is active its due timestamp
                // stays pending; after completion advance directly beyond now.
                let Ok(next) = next_automation_run(&automation.rrule, &automation.timezone, now)
                else {
                    continue;
                };
                let run_id = uuid::Uuid::new_v4().to_string();
                if !matches!(
                    state
                        .store
                        .claim_scheduled_automation(
                            &run_id,
                            &automation,
                            &scheduled_for,
                            &now_string,
                            next.as_deref(),
                            true
                        )
                        .await,
                    Ok(true)
                ) {
                    continue;
                }
                tokio::spawn(run_automation(
                    state.clone(),
                    automation,
                    scheduled_for,
                    run_id,
                ));
            }
        }
    })
}

async fn run_automation(
    state: AppState,
    automation: wonder_store::StoredAutomation,
    scheduled_for: String,
    run_id: String,
) {
    if let Err((_, error)) = automation_target_available(
        &state,
        &automation.bot_id,
        &automation.scope_type,
        &automation.scope_id,
        &automation.kind,
        automation.conversation_id.as_deref(),
    )
    .await
    {
        let _ = state
            .store
            .finish_automation_run(
                &run_id,
                "failed",
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                Some(error),
                None,
            )
            .await;
        return;
    }
    if automation.scope_type == "group_chat" {
        run_group_chat_automation(state, automation, scheduled_for, run_id).await;
        return;
    }
    let conversation_id = automation_conversation_id(
        &automation.kind,
        &automation.id,
        automation.conversation_id.as_deref(),
    )
    .unwrap_or_else(|| automation.bot_id.clone());
    let Some(device_id) = state
        .store
        .automation_message_device_id()
        .await
        .ok()
        .flatten()
    else {
        let _ = state
            .store
            .finish_automation_run(
                &run_id,
                "failed",
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                Some("Wonder needs an active paired owner device to run this automation."),
                None,
            )
            .await;
        return;
    };
    // The message, durable queue entry and run link commit together. A crash
    // can only leave accepted work or no materialized work, never an orphan.
    let message = match state
        .store
        .materialize_automation_message(
            &run_id,
            &device_id,
            &automation,
            &conversation_id,
            &scheduled_for,
        )
        .await
    {
        Ok(message) => message,
        Err(_) => return, // The durable accepted run is recoverable on restart.
    };
    dispatch_to_codex_inner(state, message, Some(automation.bot_id), Some(run_id)).await;
}

async fn run_group_chat_automation(
    state: AppState,
    automation: wonder_store::StoredAutomation,
    scheduled_for: String,
    run_id: String,
) {
    let Some(channel) = state
        .store
        .channel(&automation.scope_id)
        .await
        .ok()
        .flatten()
    else {
        let _ = state
            .store
            .finish_automation_run(
                &run_id,
                "failed",
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                Some("The automation Group Chat no longer exists."),
                None,
            )
            .await;
        return;
    };
    if channel.is_archived {
        let _ = state
            .store
            .finish_automation_run(
                &run_id,
                "failed",
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                Some("The automation Group Chat is archived."),
                None,
            )
            .await;
        return;
    }
    let Some(message_device_id) = state
        .store
        .automation_message_device_id()
        .await
        .ok()
        .flatten()
    else {
        let _ = state
            .store
            .finish_automation_run(
                &run_id,
                "failed",
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                Some("Wonder has no active paired owner device for this automation."),
                None,
            )
            .await;
        return;
    };
    let message = match state
        .store
        .materialize_automation_message(
            &run_id,
            &message_device_id,
            &automation,
            &channel.conversation_id,
            &scheduled_for,
        )
        .await
    {
        Ok(message) => message,
        Err(_) => return,
    };
    if state
        .store
        .add_channel_message(NewChannelMessage {
            channel_id: &channel.id,
            message_id: &message.id,
            author_kind: "automation",
            author_bot_id: None,
            phase: "user",
            created_at: &scheduled_for,
            presentation_kind: "message",
            outcome: Some("completed"),
            retryable: false,
        })
        .await
        .is_err()
    {
        let _ = state
            .store
            .finish_automation_run(
                &run_id,
                "failed",
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                Some("Wonder could not claim the Group Chat automation run."),
                Some(&message.id),
            )
            .await;
    }
}

async fn dispatch_to_codex(state: AppState, message: wonder_store::StoredMessage) {
    let run = match state.store.automation_run_for_message(&message.id).await {
        Ok(run) => run,
        Err(_) => return,
    };
    if let Some(run) = run {
        match state.store.automation_snapshot_for_run(&run.id).await {
            Ok(Some(automation)) => {
                dispatch_to_codex_inner(state, message, Some(automation.bot_id), Some(run.id)).await
            }
            Ok(None) => dispatch_to_codex_inner(state, message, None, Some(run.id)).await,
            Err(_) => {}
        }
    } else {
        dispatch_to_codex_inner(state, message, None, None).await;
    }
}

async fn dispatch_to_codex_inner(
    state: AppState,
    message: wonder_store::StoredMessage,
    bot_id_override: Option<String>,
    automation_run_id: Option<String>,
) {
    // Admission and the initial turn/start must be serialized with Bot
    // creation, which may restart the App Server to add a permission profile.
    // Release the guard once the turn id is durable; the turn itself can run
    // concurrently with other work.
    let _dispatch_guard = state.dispatch_lock.lock().await;
    let claimed = match state.store.claim_message_for_dispatch(&message.id).await {
        Ok(claimed) => claimed,
        Err(_) => return,
    };
    if !claimed {
        return;
    }
    // A queue edit may have committed after the dispatcher listed candidates.
    // Once claimed, edits fail; reload the exact body now owned by this attempt.
    let message = match state.store.message_by_id(&message.id).await {
        Ok(Some(message)) => message,
        _ => return,
    };
    let mut submitting = false;
    let result = async {
        if state.store.subagent_ownership_for_conversation(&message.conversation_id).await.map_err(|e| e.to_string())?.is_some() {
            return Err("Agent tasks are read-only. Continue in the parent conversation.".to_owned());
        }
        if let Some(child) = subagents::runtime_for_conversation(&state, &message.conversation_id).await? {
            return dispatch_subagent_message(&state, &message, child, &mut submitting).await;
        }
        let bot = if let Some(bot_id) = bot_id_override.as_deref() {
            state
                .store
                .list_bots()
                .await
                .map_err(|error| error.to_string())?
                .into_iter()
                .find(|bot| bot.id == bot_id)
        } else {
            bot_for_conversation(&state, &message.conversation_id)
                .await
                .map_err(|error| error.to_string())?
        }
        .ok_or_else(|| "conversation Bot was not found".to_owned())?;
        let (bot, has_message_settings) = state.store.message_execution_bot(&message.id, bot).await.map_err(|e| e.to_string())?;
        // Revalidate the frozen cwd and grant at the dispatch boundary before
        // project or Group attenuation can replace the execution scope.
        if has_message_settings {
            file_access::dispatch_check(&state, &bot, bot.effective_permission_profile()).await?;
        }
        let bot = project_assignments::execution_bot(&state, &message.conversation_id, bot).await?;
        // Acceptance-time settings are frozen, but group scope is a final
        // security boundary applied once after that snapshot.
        let bot = group_collaboration::execution_bot(&state, &message, bot).await?;
        if bot.is_archived { return Err("Restore this Bot before starting new work.".to_owned()); }
        ensure_execution_permission_cache(&state, &bot).await?;
        let automation_settings = if let Some(run_id) = automation_run_id.as_deref() {
            state.store.automation_snapshot_for_run(run_id).await.map_err(|error|error.to_string())?
        } else {None};
        state
            .store
            .ensure_conversation_metadata(
                &message.conversation_id,
                &bot.id,
                &bot.name,
                &state.started_at,
            )
            .await
            .map_err(|error| error.to_string())?;
        let conversation_settings = state
            .store
            .conversation_settings(&message.conversation_id)
            .await
            .map_err(|error| error.to_string())?;
        let resolved = {
            let catalog = state.runtime_catalog.read().await;
            let (mut resolved, _) = effective_settings(&catalog, &bot, if has_message_settings { None } else { conversation_settings.as_ref() });
            if let Some(automation) = automation_settings.as_ref() {
                if automation.model_id.is_some() { resolved.model = automation.model_id.clone(); }
                if automation.reasoning_effort.is_some() { resolved.effort = automation.reasoning_effort.clone(); }
            }
            validate_setting_value(
                &catalog,
                &bot,
                resolved.model.as_deref(),
                resolved.effort.as_deref(),
                resolved.service_tier.as_deref(),
                Some(resolved.permission_profile.as_str()),
            )
            .map_err(str::to_owned)?;
            resolved
        };
        let onboarding = bot_onboarding::enabled(&state, &message.conversation_id, &bot).await?;
        file_access::dispatch_check(&state, &bot, &resolved.permission_profile).await?;
        let mut app_server = state.app_server.lock().await;
        let existing_thread_id = state
            .store
            .conversation_thread(&message.conversation_id)
            .await
            .map_err(|error| error.to_string())?;
        let thread_id = if conversation_needs_tool_migration(
            &state,
            &message.conversation_id,
            existing_thread_id.as_deref(),
        )
        .await?
        {
            // Codex 0.152 registers dynamic tools only on thread/start. An
            // older persisted Bot thread therefore gets one fresh thread on
            // its first post-upgrade turn; Wonder's own transcript remains
            // intact and the new thread is durable from this point forward.
            start_bot_thread(
                &state,
                &mut app_server,
                &message.conversation_id,
                &bot,
                &resolved,
            )
            .await?
        } else if let Some(thread_id) = existing_thread_id {
            // The App Server process is recreated whenever the daemon
            // restarts. Re-register persisted conversations with that new
            // process before starting the next turn; otherwise turn/start
            // rejects a perfectly valid thread id as unknown.
            let resume_params = serde_json::json!({
                "threadId": thread_id,
                "cwd": bot.execution_directory(),
                "permissions": resolved.permission_profile,
                "runtimeWorkspaceRoots": permission_modes::runtime_roots(&state, &bot).await?,
                "approvalPolicy": resolved.approval_policy,
                "approvalsReviewer": resolved.approvals_reviewer,
                "model": resolved.model,
                "serviceTier": resolved.service_tier,
                "developerInstructions": bot_onboarding::instructions(&bot, onboarding),
            });
            let response = app_server
                .request("thread/resume", resume_params)
                .await
                .map_err(|error| error.to_string())?;
            if let Some(error) = response.error {
                return Err(format!("App Server thread/resume rejected: {error:?}"));
            }
            thread_id
        } else {
            start_bot_thread(
                &state,
                &mut app_server,
                &message.conversation_id,
                &bot,
                &resolved,
            )
            .await?
        };
        let attachments = group_attachments::for_dispatch(&state, &message, &bot).await?;
        let input = turn_input(&message.body, &bot.workspace_path, &attachments);
        let file_access = state.store.bot_file_access(&bot.id).await.map_err(|e|e.to_string())?;
        let context = serde_json::json!({
            "schemaVersion":1,
            "instructions": bot_onboarding::snapshot(&bot, onboarding),
            "additionalContext": bot_onboarding::context(&bot, onboarding),
            "wonderVersion":env!("CARGO_PKG_VERSION"),
            "runtimeVersionConstraint":wonder_app_server::COMPATIBLE_CODEX_VERSIONS.join(" or "),
            "requestedModel":resolved.model,"requestedEffort":resolved.effort,"requestedServiceTier":resolved.service_tier,
            "permissionProfile":resolved.permission_profile,"fileAccess":file_access,
            "workingDirectory":bot.execution_directory(),"runtimeWorkspaceRoots":permission_modes::runtime_roots(&state, &bot).await?,
            "computerToolConfigured":state.computer_use_bin.is_some(),
            "inputSha256":hex::encode(Sha256::digest(serde_json::to_vec(&input).map_err(|e|e.to_string())?)),
            "unrecorded":["runtime default model resolution","runtime and workspace instructions","connected app account and tool snapshot"]
        }).to_string();
        state
            .store
            .begin_dispatch_submission_with_context(&message.id, &thread_id, Some(&context))
            .await
            .map_err(|error| error.to_string())?;
        submitting = true;
        let response = app_server
            .request(
                "turn/start",
                serde_json::json!({
                    "threadId": thread_id,
                    "clientUserMessageId": message.client_message_id,
                    "input": input,
                    "additionalContext": bot_onboarding::context(&bot, onboarding),
                    "permissions": resolved.permission_profile,
                    "approvalPolicy": resolved.approval_policy,
                    "approvalsReviewer": resolved.approvals_reviewer,
                    "runtimeWorkspaceRoots": permission_modes::runtime_roots(&state, &bot).await?,
                    "model": resolved.model,
                    "effort": resolved.effort,
                    "serviceTier": resolved.service_tier,
                }),
            )
            .await
            .map_err(|error| error.to_string())?;
        if let Some(error) = response.error {
            return Err(format!("App Server turn/start rejected: {error:?}"));
        }
        let turn_id = response
            .result
            .as_ref()
            .and_then(|result| {
                result
                    .get("turn")
                    .and_then(|turn| turn.get("id"))
                    .and_then(serde_json::Value::as_str)
                    .or_else(|| result.get("turnId").and_then(serde_json::Value::as_str))
            })
            .ok_or_else(|| "turn/start returned no turn id".to_owned())?
            .to_owned();
        Ok::<Option<(String, String)>, String>(Some((thread_id, turn_id)))
    }
    .await;

    match result {
        Ok(Some((thread_id, turn_id))) => {
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
            drain_pending_app_server_notifications(&state, &thread_id, &turn_id).await;
            publish_message_state(
                &state,
                &message,
                DeliveryState::AcceptedByCodex,
                Some(&thread_id),
                Some(&turn_id),
            )
            .await;
            drop(_dispatch_guard);
        }
        Ok(None) => {
            // A child can be running without any direct Wonder user receipt.
            // Keep queued intent durable until that runtime turn ends.
            if state
                .store
                .update_message_delivery(&message.id, "accepted_by_wonder", None, None)
                .await
                .is_ok()
            {
                publish_message_state(
                    &state,
                    &message,
                    DeliveryState::AcceptedByWonder,
                    None,
                    None,
                )
                .await;
            }
        }
        Err(error) => {
            let delivery = if submitting {
                DeliveryState::Uncertain
            } else {
                DeliveryState::SafeToRetry
            };
            let status = if submitting {
                "uncertain"
            } else {
                "safe_to_retry"
            };
            if state
                .store
                .update_message_delivery(&message.id, status, None, None)
                .await
                .is_ok()
            {
                publish_message_state(&state, &message, delivery, None, None).await;
            }
            finish_automation_dispatch_failure(
                &state,
                automation_run_id.as_deref(),
                "Wonder could not confirm the scheduled run.",
            )
            .await;
            let _ = state.logger.record(
                "error",
                "message_dispatch_failed",
                serde_json::json!({"messageId": message.id, "error": error}),
            );
        }
    }
}

fn inherited_child_resume_params(thread_id: &str) -> serde_json::Value {
    // Omission is intentional: parent Bot instructions, model and permissions
    // must never replace the configuration of an existing child thread.
    serde_json::json!({"threadId": thread_id, "excludeTurns": true})
}

pub(crate) async fn child_turn_is_active(
    child: &subagents::ChildRuntime,
    turn_id: &str,
    require_direct_input: bool,
) -> Result<bool, String> {
    if child
        .thread
        .pointer("/status/type")
        .and_then(serde_json::Value::as_str)
        != Some("active")
    {
        return Ok(false);
    }
    if require_direct_input
        && child
            .thread
            .get("canAcceptDirectInput")
            .and_then(serde_json::Value::as_bool)
            != Some(true)
    {
        return Ok(false);
    }
    Ok(child_turn_status(child, turn_id).await?.as_deref() == Some("inProgress"))
}

async fn child_turn_status(
    child: &subagents::ChildRuntime,
    turn_id: &str,
) -> Result<Option<String>, String> {
    let response = child
        .rpc
        .request(
            "thread/turns/list",
            serde_json::json!({
                "threadId": child.ownership.thread_id, "limit": 100,
                "sortDirection": "desc", "itemsView": "notLoaded"
            }),
        )
        .await
        .map_err(|error| error.to_string())?;
    if response.error.is_some() {
        return Err("The subagent's active work could not be checked".into());
    }
    Ok(response
        .result
        .as_ref()
        .and_then(|value| value.get("data"))
        .and_then(serde_json::Value::as_array)
        .and_then(|turns| {
            turns
                .iter()
                .find(|turn| turn.get("id").and_then(serde_json::Value::as_str) == Some(turn_id))
        })
        .and_then(|turn| turn.get("status").and_then(serde_json::Value::as_str))
        .map(str::to_owned))
}

async fn resume_child(child: &subagents::ChildRuntime) -> Result<serde_json::Value, String> {
    if child.ownership.is_archived {
        let response = child
            .rpc
            .request(
                "thread/unarchive",
                serde_json::json!({
                    "threadId": child.ownership.thread_id
                }),
            )
            .await
            .map_err(|error| error.to_string())?;
        if response.error.is_some() {
            return Err(
                "This subagent could not be reopened. Refresh its parent conversation.".into(),
            );
        }
    }
    let response = child
        .rpc
        .request(
            "thread/resume",
            inherited_child_resume_params(&child.ownership.thread_id),
        )
        .await
        .map_err(|error| error.to_string())?;
    if response.error.is_some() {
        return Err("This subagent could not be reopened. Refresh its parent conversation.".into());
    }
    let result = response
        .result
        .ok_or("The subagent runtime returned no conversation")?;
    if result
        .pointer("/thread/id")
        .and_then(serde_json::Value::as_str)
        != Some(child.ownership.thread_id.as_str())
    {
        return Err("The subagent runtime returned a different conversation".into());
    }
    Ok(result)
}

async fn dispatch_subagent_message(
    state: &AppState,
    message: &wonder_store::StoredMessage,
    child: subagents::ChildRuntime,
    submitting: &mut bool,
) -> Result<Option<(String, String)>, String> {
    if child
        .thread
        .pointer("/status/type")
        .and_then(serde_json::Value::as_str)
        == Some("active")
    {
        return Ok(None);
    }
    let bot = bot_for_conversation(state, &message.conversation_id)
        .await
        .map_err(|error| error.to_string())?
        .ok_or("The subagent's Bot is unavailable")?;
    if bot.is_archived {
        return Err("Restore this Bot before starting new work.".into());
    }
    let resumed = resume_child(&child).await?;
    match resumed
        .pointer("/thread/status/type")
        .and_then(serde_json::Value::as_str)
    {
        Some("active") => return Ok(None),
        Some("idle") => {}
        _ => {
            return Err("The subagent's work status is unavailable. Refresh and try again.".into())
        }
    }
    if resumed
        .pointer("/thread/canAcceptDirectInput")
        .and_then(serde_json::Value::as_bool)
        != Some(true)
    {
        return Err(
            "Direct messages are unavailable for this subagent on the current runtime.".into(),
        );
    }
    let attachments = group_attachments::for_dispatch(state, message, &bot).await?;
    let input = turn_input(&message.body, &bot.workspace_path, &attachments);
    let context = serde_json::json!({
        "schemaVersion": 1, "settings": "inheritedFromSubagent",
        "threadId": child.ownership.thread_id,
        "parentThreadId": child.ownership.parent_thread_id,
        "workingDirectory": resumed.get("cwd").or_else(|| resumed.pointer("/thread/cwd")),
        "model": resumed.get("model"), "approvalPolicy": resumed.get("approvalPolicy"),
        "approvalsReviewer": resumed.get("approvalsReviewer"),
        "activePermissionProfile": resumed.get("activePermissionProfile"),
        "inputSha256": hex::encode(Sha256::digest(serde_json::to_vec(&input).map_err(|error| error.to_string())?))
    }).to_string();
    state
        .store
        .begin_dispatch_submission_with_context(
            &message.id,
            &child.ownership.thread_id,
            Some(&context),
        )
        .await
        .map_err(|error| error.to_string())?;
    *submitting = true;
    let response = child
        .rpc
        .request(
            "turn/start",
            serde_json::json!({
                "threadId": child.ownership.thread_id,
                "clientUserMessageId": message.client_message_id,
                "input": input
            }),
        )
        .await
        .map_err(|error| error.to_string())?;
    if response.error.is_some() {
        return Err(
            "The subagent did not accept the message. Check its conversation before retrying."
                .into(),
        );
    }
    let turn_id = response
        .result
        .as_ref()
        .and_then(|result| result.pointer("/turn/id").or_else(|| result.get("turnId")))
        .and_then(serde_json::Value::as_str)
        .ok_or("The subagent returned no message receipt")?
        .to_owned();
    Ok(Some((child.ownership.thread_id, turn_id)))
}

async fn finish_automation_dispatch_failure(state: &AppState, run_id: Option<&str>, error: &str) {
    if let Some(run_id) = run_id {
        let _ = state
            .store
            .finish_automation_run(
                run_id,
                "failed",
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                Some(error),
                None,
            )
            .await;
    }
}

enum ReconcileResult {
    Accepted { thread_id: String, turn_id: String },
}

async fn restart_and_reconcile(
    state: &AppState,
    message: &wonder_store::StoredMessage,
) -> Option<ReconcileResult> {
    if state
        .store
        .subagent_ownership_for_conversation(&message.conversation_id)
        .await
        .ok()?
        .is_some()
    {
        let thread_id = message.codex_thread_id.clone()?;
        let turn_id = dispatch::find_accepted_turn(state, message).await.ok()??;
        return Some(ReconcileResult::Accepted { thread_id, turn_id });
    }
    let thread_id = state
        .store
        .conversation_thread(&message.conversation_id)
        .await
        .ok()??;
    let bot = bot_for_conversation(state, &message.conversation_id)
        .await
        .ok()??;
    let conversation_settings = state
        .store
        .conversation_settings(&message.conversation_id)
        .await
        .ok()?;
    let resolved = {
        let catalog = state.runtime_catalog.read().await;
        let (resolved, _) = effective_settings(&catalog, &bot, conversation_settings.as_ref());
        validate_setting_value(
            &catalog,
            &bot,
            resolved.model.as_deref(),
            resolved.effort.as_deref(),
            resolved.service_tier.as_deref(),
            Some(resolved.permission_profile.as_str()),
        )
        .ok()?;
        resolved
    };
    let mut app_server = state.app_server.lock().await;
    if app_server
        .restart(state.launch_config.lock().await.clone())
        .await
        .is_err()
    {
        return None;
    }
    if rediscover_runtime(state, &mut app_server).await.is_err() {
        return None;
    }
    let rpc = app_server.rpc();
    drop(app_server);
    let app_server = rpc;
    let resume = app_server
        .request(
            "thread/resume",
            serde_json::json!({
                "threadId": thread_id,
                "excludeTurns": true,
                "cwd": bot.execution_directory(),
                "permissions": resolved.permission_profile,
                "runtimeWorkspaceRoots": permission_modes::runtime_roots(state, &bot).await.ok()?,
                "approvalPolicy": resolved.approval_policy,
                "approvalsReviewer": resolved.approvals_reviewer,
                "model": resolved.model,
                "developerInstructions": bot_onboarding::instructions(&bot, bot_onboarding::enabled(state, &message.conversation_id, &bot).await.ok()?),
            }),
        )
        .await
        .ok()?
        .result?;
    let thread_idle = resume
        .get("thread")
        .and_then(|thread| thread.get("status"))
        .and_then(|status| status.get("type"))
        .and_then(serde_json::Value::as_str)
        == Some("idle");

    let mut turns_cursor = None;
    let mut seen_turns = std::collections::HashSet::new();
    let mut turns_complete = false;
    for _ in 0..10_000 {
        let mut params = serde_json::json!({
            "threadId": thread_id,
            "limit": 100,
            "itemsView": "notLoaded",
        });
        if let Some(cursor) = turns_cursor.take() {
            params["cursor"] = serde_json::Value::String(cursor);
        }
        let result = app_server
            .request("thread/turns/list", params)
            .await
            .ok()?
            .result?;
        turns_cursor = result
            .get("nextCursor")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned);
        if turns_cursor
            .as_ref()
            .is_some_and(|value| !seen_turns.insert(value.clone()))
        {
            return None;
        }
        if turns_cursor.is_none() {
            turns_complete = true;
            break;
        }
    }
    if !turns_complete {
        return None;
    }

    let mut items_cursor = None;
    let mut seen_items = std::collections::HashSet::new();
    let mut items_complete = false;
    for _ in 0..10_000 {
        let mut params = serde_json::json!({ "threadId": thread_id, "limit": 100 });
        if let Some(cursor) = items_cursor.take() {
            params["cursor"] = serde_json::Value::String(cursor);
        }
        let result = app_server
            .request("thread/items/list", params)
            .await
            .ok()?
            .result?;
        if let Some(turn_id) = find_client_message(&result, &message.client_message_id) {
            return Some(ReconcileResult::Accepted {
                thread_id: thread_id.clone(),
                turn_id,
            });
        }
        items_cursor = result
            .get("nextCursor")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned);
        if items_cursor
            .as_ref()
            .is_some_and(|value| !seen_items.insert(value.clone()))
        {
            return None;
        }
        if items_cursor.is_none() {
            items_complete = true;
            break;
        }
    }
    let _ = (items_complete, thread_idle);
    None
}

async fn rediscover_runtime(
    state: &AppState,
    app_server: &mut AppServerClient,
) -> Result<(), String> {
    for method in ["account/read", "account/rateLimits/read"] {
        let response = app_server
            .request(method, serde_json::json!({}))
            .await
            .map_err(|e| e.to_string())?;
        if response.error.is_some() || response.result.is_none() {
            return Err(format!("{method} is unavailable"));
        }
    }
    let mut catalog = RuntimeCatalog::default();
    let mut cursor = None;
    let mut seen = std::collections::HashSet::new();
    loop {
        let mut params = serde_json::json!({"limit": 100});
        if let Some(value) = cursor.as_deref() {
            params["cursor"] = serde_json::json!(value);
        }
        let response = app_server
            .request("model/list", params)
            .await
            .map_err(|e| e.to_string())?;
        if response.error.is_some() {
            return Err("Model discovery failed".into());
        }
        let result = response.result.ok_or("model/list returned no result")?;
        catalog.apply_models_page(&result);
        cursor = result
            .get("nextCursor")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned);
        let Some(value) = cursor.as_ref() else {
            break;
        };
        if !seen.insert(value.clone()) {
            return Err("Repeated model cursor".into());
        }
    }
    // Validate the bootstrap scope when configured, as well as each Bot below.
    let has_bootstrap = state
        .launch_config
        .lock()
        .await
        .permission_overrides
        .iter()
        .any(|value| value.contains("permissions.wonder_runtime_bootstrap="));
    if has_bootstrap {
        let workspace = std::path::Path::new(&state.bot_home)
            .parent()
            .ok_or("Missing data root")?
            .join("runtime-bootstrap");
        let response = app_server
            .request(
                "permissionProfile/list",
                serde_json::json!({"cwd": workspace}),
            )
            .await
            .map_err(|e| e.to_string())?;
        if response.error.is_some() {
            return Err("Bootstrap profile discovery failed".into());
        }
        let result = response.result.ok_or("Missing bootstrap profile")?;
        require_named_profile_with_scope(
            &result,
            "wonder_runtime_bootstrap",
            workspace.to_str().ok_or("Invalid workspace path")?,
            &state
                .denied_roots
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
        )
        .map_err(str::to_owned)?;
        catalog.apply_permission_profiles(&workspace.to_string_lossy(), &result);
    }
    let requirements = app_server
        .request("configRequirements/read", serde_json::json!({}))
        .await
        .map_err(|error| error.to_string())?;
    if let Some(error) = requirements.error {
        return Err(format!(
            "App Server configRequirements/read rejected: {error:?}"
        ));
    }
    let result = requirements
        .result
        .ok_or("configRequirements/read returned no result")?;
    catalog.apply_requirements(&result);

    // Profiles are resolved relative to cwd. Checking every Bot against a
    // fixed profile listing silently breaks multi-Bot restarts, so each
    // workspace gets its own post-restart verification and catalog entry.
    let bots = state
        .store
        .list_bots()
        .await
        .map_err(|error| error.to_string())?;
    for bot in bots {
        let response = app_server
            .request(
                "permissionProfile/list",
                serde_json::json!({ "cwd": bot.execution_directory() }),
            )
            .await
            .map_err(|error| error.to_string())?;
        if let Some(error) = response.error {
            return Err(format!(
                "App Server permissionProfile/list rejected: {error:?}"
            ));
        }
        let result = response
            .result
            .ok_or_else(|| "permissionProfile/list returned no result".to_owned())?;
        if bot.permission_mode.is_none() {
            require_named_profile_with_scope(
                &result,
                &bot.permission_profile,
                &bot.workspace_path,
                &state
                    .denied_roots
                    .iter()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
            )
            .map_err(str::to_owned)?;
        }
        file_access::verify(state, app_server, &bot).await?;
        catalog.apply_permission_profiles(&bot.workspace_path, &result);
    }
    *state.runtime_catalog.write().await = catalog;
    Ok(())
}

fn find_client_message(value: &serde_json::Value, client_message_id: &str) -> Option<String> {
    let entries = value.get("data")?.as_array()?;
    entries.iter().find_map(|entry| {
        let item = entry.get("item")?;
        if item.get("type").and_then(serde_json::Value::as_str) != Some("userMessage")
            || item.get("clientId").and_then(serde_json::Value::as_str) != Some(client_message_id)
        {
            return None;
        }
        entry
            .get("turnId")
            .and_then(serde_json::Value::as_str)
            .or_else(|| item.get("turnId").and_then(serde_json::Value::as_str))
            .map(str::to_owned)
    })
}

async fn events_socket(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let local_capability = headers
        .get("x-wonder-loopback-capability")
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value == state.loopback_capability);
    let session = cookie_value(&headers, "__Host-wonder_session");
    ws.on_upgrade(move |socket| stream_events(socket, state, session, local_capability))
}

async fn event_challenge(
    State(state): State<AppState>,
    Extension(AuthenticatedDevice { device_id, .. }): Extension<AuthenticatedDevice>,
) -> Response {
    let Some(origin) = current_public_origin(&state).await else {
        return (StatusCode::SERVICE_UNAVAILABLE, "Wonder is still starting").into_response();
    };
    match state.pairing.lock().await.issue_fresh_challenge(
        &device_id,
        &origin,
        &state.host_installation_id,
        now_ms(),
    ) {
        Ok(challenge) => Json(challenge).into_response(),
        Err(_) => (StatusCode::UNAUTHORIZED, "paired device required").into_response(),
    }
}

pub fn capability_from_environment() -> Result<String, String> {
    std::env::var("WONDER_LOOPBACK_CAPABILITY")
        .map_err(|_| "WONDER_LOOPBACK_CAPABILITY is required".into())
}

async fn list_pending_enrollments(
    State(state): State<AppState>,
    Extension(_local): Extension<LocalOwnerAuthority>,
) -> Response {
    Json(state.pairing.lock().await.pending_enrollments(now_ms())).into_response()
}

async fn confirm_enrollment(
    State(state): State<AppState>,
    Extension(_local): Extension<LocalOwnerAuthority>,
    Path(device_id): Path<String>,
) -> Response {
    // Keep confirmation, persistence and session issuance serialized.
    let mut pairing = state.pairing.lock().await;
    let confirmed_at_ms = now_ms();
    let pending = match pairing.pending_enrollment(&device_id, confirmed_at_ms) {
        Ok(pending) => pending,
        Err(error) => return pairing_error_response(error),
    };
    let key = match serde_json::to_string(&pending.public_key) {
        Ok(key) => key,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    if state
        .store
        .upsert_owner_device_with_expiration(
            &device_id,
            &pending.label,
            &key,
            pending.session_expires_at_ms,
            &now_ms().to_string(),
        )
        .await
        .is_err()
    {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "Could not save this phone. Try confirming again.",
        )
            .into_response();
    }
    // The owner made the decision before expiry, while holding the pairing lock.
    match pairing.confirm_enrollment(&device_id, confirmed_at_ms) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(error) => pairing_error_response(error),
    }
}

async fn reject_enrollment(
    State(state): State<AppState>,
    Extension(_local): Extension<LocalOwnerAuthority>,
    Path(device_id): Path<String>,
) -> Response {
    let mut pairing = state.pairing.lock().await;
    if let Err(error) = pairing.pending_enrollment(&device_id, now_ms()) {
        return pairing_error_response(error);
    }
    pairing.revoke_device(&device_id);
    StatusCode::NO_CONTENT.into_response()
}

async fn create_pairing_offer(
    State(state): State<AppState>,
    Extension(_local): Extension<LocalOwnerAuthority>,
) -> impl IntoResponse {
    let public_origin = current_public_origin(&state).await;
    let mut pairing = state.pairing.lock().await;
    pairing_offer_response(public_origin, &state.host_installation_id, &mut pairing)
}

fn pairing_offer_response(
    public_origin: Option<String>,
    host_installation_id: &str,
    pairing: &mut PairingState,
) -> Response {
    let Some(public_origin) = public_origin else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Wonder Funnel is still starting",
        )
            .into_response();
    };
    let offer = pairing.create_offer(&public_origin, host_installation_id, now_ms());
    (
        StatusCode::CREATED,
        [(header::CACHE_CONTROL, "no-store")],
        Json(offer),
    )
        .into_response()
}

async fn cancel_pairing_offer(
    State(state): State<AppState>,
    Extension(_local): Extension<LocalOwnerAuthority>,
    Path(offer_id): Path<String>,
) -> impl IntoResponse {
    if state.pairing.lock().await.cancel_offer(&offer_id) {
        StatusCode::NO_CONTENT
    } else {
        StatusCode::NOT_FOUND
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaimRequest {
    offer_id: String,
    secret: String,
    public_key: DevicePublicKeyJwk,
    label: String,
    #[serde(default = "default_session_expiration")]
    session_expiration: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairingCodeRequest {
    human_code: String,
    public_key: DevicePublicKeyJwk,
    label: String,
    #[serde(default = "default_session_expiration")]
    session_expiration: String,
}

fn default_session_expiration() -> String {
    "1d".into()
}

async fn claim_pairing_offer(
    State(state): State<AppState>,
    Json(request): Json<ClaimRequest>,
) -> Response {
    if !valid_device_label(&request.label) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let session_expires_at_ms =
        match session_expiration_deadline(&request.session_expiration, now_ms()) {
            Ok(deadline) => deadline,
            Err(error) => return pairing_error_response(error),
        };
    let result = state
        .pairing
        .lock()
        .await
        .claim_offer_with_session_expiration(
            &request.offer_id,
            &request.secret,
            request.public_key,
            &request.label,
            session_expires_at_ms,
            now_ms(),
        );
    match result {
        Ok(claimed) => (
            StatusCode::OK,
            [(header::CACHE_CONTROL, "no-store")],
            Json(claimed),
        )
            .into_response(),
        Err(error) => pairing_error_response(error),
    }
}

async fn claim_pairing_code(
    State(state): State<AppState>,
    Json(request): Json<PairingCodeRequest>,
) -> Response {
    if !valid_device_label(&request.label) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    if !state
        .pairing
        .lock()
        .await
        .allow_human_code_attempt(now_ms())
    {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            [(header::RETRY_AFTER, "60")],
            "too many pairing code attempts",
        )
            .into_response();
    }
    let session_expires_at_ms =
        match session_expiration_deadline(&request.session_expiration, now_ms()) {
            Ok(deadline) => deadline,
            Err(error) => return pairing_error_response(error),
        };
    let result = state.pairing.lock().await.claim_offer_by_human_code(
        &request.human_code,
        request.public_key,
        &request.label,
        session_expires_at_ms,
        now_ms(),
    );
    match result {
        Ok(claimed) => (
            StatusCode::OK,
            [(header::CACHE_CONTROL, "no-store")],
            Json(claimed),
        )
            .into_response(),
        Err(error) => pairing_error_response(error),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionRefreshChallengeRequest {
    device_id: String,
}

async fn create_session_refresh_challenge(
    State(state): State<AppState>,
    Json(request): Json<SessionRefreshChallengeRequest>,
) -> Response {
    let Some(origin) = current_public_origin(&state).await else {
        return (StatusCode::SERVICE_UNAVAILABLE, "Wonder is still starting").into_response();
    };
    match state.pairing.lock().await.issue_fresh_challenge(
        &request.device_id,
        &origin,
        &state.host_installation_id,
        now_ms(),
    ) {
        Ok(challenge) => (
            StatusCode::OK,
            [(header::CACHE_CONTROL, "no-store")],
            Json(challenge),
        )
            .into_response(),
        Err(error) => pairing_error_response(error),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionRequest {
    challenge_id: String,
    signature: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionResponse {
    session_token: String,
    device_id: String,
    csrf_token: String,
    host_installation_id: String,
    expires_at_ms: Option<u64>,
}

async fn create_session(
    State(state): State<AppState>,
    Json(request): Json<SessionRequest>,
) -> Response {
    let mut pairing = state.pairing.lock().await;
    let result = pairing.verify_challenge(&request.challenge_id, &request.signature, now_ms());
    match result {
        Ok(session) => {
            if state
                .store
                .insert_session(
                    &session_token_hash(&session.session_token),
                    &session.device_id,
                    &csrf_token_hash(&session.csrf_token),
                    session.expires_at_ms,
                    &now_ms().to_string(),
                )
                .await
                .is_err()
            {
                pairing.rollback_session(&request.challenge_id, &session);
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "session persistence failed",
                )
                    .into_response();
            }
            let cookie = if session.expires_at_ms == NEVER_EXPIRES_AT_MS {
                format!(
                    "__Host-wonder_session={}; Path=/; Max-Age=2147483647; Secure; HttpOnly; SameSite=Strict",
                    session.session_token
                )
            } else {
                let max_age = session
                    .expires_at_ms
                    .saturating_sub(now_ms())
                    .saturating_div(1000);
                format!(
                    "__Host-wonder_session={}; Path=/; Max-Age={}; Secure; HttpOnly; SameSite=Strict",
                    session.session_token, max_age
                )
            };
            (
                StatusCode::OK,
                [
                    (header::SET_COOKIE, cookie),
                    (header::CACHE_CONTROL, "no-store".into()),
                ],
                Json(SessionResponse {
                    session_token: session.session_token,
                    device_id: session.device_id,
                    csrf_token: session.csrf_token,
                    host_installation_id: session.host_installation_id,
                    expires_at_ms: (session.expires_at_ms != NEVER_EXPIRES_AT_MS)
                        .then_some(session.expires_at_ms),
                }),
            )
                .into_response()
        }
        Err(error) => pairing_error_response(error),
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceSummary {
    id: String,
    created_at: String,
    label: String,
    role: &'static str,
    last_seen_at: Option<String>,
    revoked_at: Option<String>,
    session_expires_at_ms: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RenameDeviceRequest {
    label: String,
    #[serde(flatten)]
    action: SignedActionFields,
}

fn valid_device_label(label: &str) -> bool {
    let trimmed = label.trim();
    !trimmed.is_empty() && trimmed.chars().count() <= 160 && !trimmed.chars().any(char::is_control)
}

async fn list_devices(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
) -> Response {
    match state.store.list_owner_devices().await {
        Ok(devices) => Json(
            devices
                .into_iter()
                .map(|device| DeviceSummary {
                    created_at: device.created_at,
                    id: device.id,
                    label: device.label,
                    role: "owner",
                    last_seen_at: device.last_seen_at,
                    revoked_at: device.revoked_at,
                    session_expires_at_ms: device.session_expires_at_ms,
                })
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "device listing failed").into_response(),
    }
}

async fn rename_device(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(device_id): Path<String>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
    local_authority: Option<Extension<LocalOwnerAuthority>>,
    Json(request): Json<RenameDeviceRequest>,
) -> Response {
    if authenticated_device.is_none() && local_authority.is_none() {
        return (StatusCode::UNAUTHORIZED, "paired device required").into_response();
    }
    let label = request.label.trim();
    if !valid_device_label(label) {
        return (
            StatusCode::BAD_REQUEST,
            "device label must be 1-160 characters and contain no control characters",
        )
            .into_response();
    }
    if let Some(Extension(device)) = authenticated_device {
        let target = format!("/api/v1/devices/{device_id}");
        let body_sha256 = action_body_sha256(&serde_json::json!([label]));
        if let Err(message) = verify_signed_action(
            &state,
            &device,
            "device.rename",
            &target,
            &body_sha256,
            &request.action,
            "active",
        )
        .await
        {
            return (StatusCode::UNAUTHORIZED, message).into_response();
        }
    }
    match state.store.rename_owner_device(&device_id, label).await {
        Ok(true) => match state.store.list_owner_devices().await {
            Ok(devices) => devices
                .into_iter()
                .find(|device| device.id == device_id)
                .map(|device| {
                    Json(DeviceSummary {
                        created_at: device.created_at,
                        id: device.id,
                        label: device.label,
                        role: "owner",
                        last_seen_at: device.last_seen_at,
                        revoked_at: device.revoked_at,
                        session_expires_at_ms: device.session_expires_at_ms,
                    })
                    .into_response()
                })
                .unwrap_or_else(|| StatusCode::NOT_FOUND.into_response()),
            Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "device listing failed").into_response(),
        },
        Ok(false) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "device rename failed").into_response(),
    }
}

async fn forget_device(
    State(state): State<AppState>,
    local_authority: Option<Extension<LocalOwnerAuthority>>,
    Path(device_id): Path<String>,
) -> Response {
    if local_authority.is_none() {
        return (StatusCode::FORBIDDEN, "local owner required").into_response();
    }
    match state.store.forget_revoked_device(&device_id).await {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => (StatusCode::NOT_FOUND, "revoked device not found").into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "device history could not be removed",
        )
            .into_response(),
    }
}

async fn revoke_device(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(device_id): Path<String>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
    local_authority: Option<Extension<LocalOwnerAuthority>>,
    Json(request): Json<Option<SignedActionFields>>,
) -> Response {
    if authenticated_device.is_none() && local_authority.is_none() {
        return (StatusCode::UNAUTHORIZED, "paired device required").into_response();
    }
    if let Some(Extension(device)) = authenticated_device {
        let Some(request) = request.as_ref() else {
            return (
                StatusCode::UNAUTHORIZED,
                "signed action fields are required",
            )
                .into_response();
        };
        let target = format!("/api/v1/devices/{device_id}/revoke");
        if let Err(message) = verify_signed_action(
            &state,
            &device,
            "device.revoke",
            &target,
            &action_body_sha256(&serde_json::json!([])),
            request,
            "active",
        )
        .await
        {
            return (StatusCode::UNAUTHORIZED, message).into_response();
        }
    }
    let mut pairing = state.pairing.lock().await;
    let revoked = match state
        .store
        .revoke_owner_device(&device_id, &now_ms().to_string())
        .await
    {
        Ok(revoked) => revoked,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "device revocation failed",
            )
                .into_response()
        }
    };
    if revoked {
        pairing.revoke_device(&device_id);
        let _ = state.revocations.send(device_id);
        StatusCode::NO_CONTENT.into_response()
    } else {
        StatusCode::NOT_FOUND.into_response()
    }
}

async fn reset_workspace(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
    local_authority: Option<Extension<LocalOwnerAuthority>>,
    Json(request): Json<ResetWorkspaceRequest>,
) -> Response {
    if authenticated_device.is_none() && local_authority.is_none() {
        return (StatusCode::UNAUTHORIZED, "paired device required").into_response();
    }

    let keep_device_id = if let Some(Extension(device)) = authenticated_device {
        if let Some(requested) = request.keep_device_id.as_deref() {
            if requested != device.device_id {
                return (
                    StatusCode::BAD_REQUEST,
                    "a paired session can preserve only its own device",
                )
                    .into_response();
            }
        }
        let target = "/api/v1/workspace/reset";
        if let Err(message) = verify_signed_action(
            &state,
            &device,
            "workspace.reset",
            target,
            &action_body_sha256(&serde_json::json!([device.device_id.clone()])),
            &request.action,
            "active",
        )
        .await
        {
            return (StatusCode::UNAUTHORIZED, message).into_response();
        }
        device.device_id
    } else {
        let Some(keep_device_id) = request.keep_device_id.as_deref() else {
            return (
                StatusCode::BAD_REQUEST,
                "keepDeviceId is required for local reset",
            )
                .into_response();
        };
        keep_device_id.to_owned()
    };

    let reset = match state
        .store
        .reset_workspace(&keep_device_id, &now_ms().to_string())
        .await
    {
        Ok(reset) => reset,
        Err(sqlx::Error::RowNotFound) => {
            return (StatusCode::NOT_FOUND, "preserved device was not found").into_response()
        }
        Err(_) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, "workspace reset failed").into_response()
        }
    };

    for device_id in &reset.revoked_device_ids {
        state.pairing.lock().await.revoke_device(device_id);
        let _ = state.revocations.send(device_id.clone());
    }

    let root = match tokio::fs::canonicalize(&state.bots_root).await {
        Ok(root) => root,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "workspace reset completed but bot homes could not be verified",
            )
                .into_response()
        }
    };
    for workspace in &reset.workspace_paths {
        let Ok(path) = tokio::fs::canonicalize(workspace).await else {
            continue;
        };
        if path == root || !path.starts_with(&root) {
            continue;
        }
        let _ = tokio::fs::remove_dir_all(path).await;
    }

    Json(ResetWorkspaceSummary {
        preserved_device_id: keep_device_id,
        revoked_device_count: reset.revoked_device_ids.len(),
        deleted_bot_count: reset.workspace_paths.len(),
        deleted_workspace_count: reset.workspace_paths.len(),
    })
    .into_response()
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ApprovalSummary {
    approval_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    conversation_id: Option<String>,
    method: String,
    params: serde_json::Value,
    action_nonce: String,
    resolution_idempotency_key: Option<String>,
}

async fn list_approvals(State(state): State<AppState>) -> Response {
    if computer_tools::retire_completed(&state).await.is_err() {
        return (StatusCode::INTERNAL_SERVER_ERROR, "approval cleanup failed").into_response();
    }
    let approvals = match state.store.list_pending_approvals().await {
        Ok(approvals) => approvals,
        Err(_) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, "approval listing failed").into_response()
        }
    };
    let mut summaries = Vec::with_capacity(approvals.len());
    for approval in approvals {
        let params =
            serde_json::from_str::<serde_json::Value>(&approval.params_json).unwrap_or_default();
        if params
            .get("_wonderAutomatic")
            .and_then(serde_json::Value::as_bool)
            == Some(true)
        {
            continue;
        }
        let conversation_id = match state
            .store
            .approval_conversation_id(&approval.thread_id, &approval.turn_id)
            .await
        {
            Ok(conversation_id) => conversation_id,
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "approval routing could not be loaded",
                )
                    .into_response()
            }
        };
        summaries.push(ApprovalSummary {
            approval_id: approval.approval_id,
            conversation_id,
            method: approval.method.clone(),
            params: redact_approval_params(
                &approval.method,
                &serde_json::from_str(&approval.params_json)
                    .unwrap_or_else(|_| serde_json::json!({})),
            ),
            action_nonce: approval.action_nonce,
            resolution_idempotency_key: approval.resolution_idempotency_key,
        });
    }
    Json(summaries).into_response()
}

fn redact_approval_params(method: &str, params: &serde_json::Value) -> serde_json::Value {
    let mut summary = serde_json::Map::new();
    if method == "item/tool/call" {
        if let Ok(arguments) = computer_tools::arguments(params) {
            summary.insert("arguments".into(), arguments);
        }
    }
    for key in [
        "command",
        "cwd",
        "filePath",
        "grantRoot",
        "url",
        "reason",
        "itemId",
        "threadId",
        "turnId",
        "serverName",
        "callId",
        "tool",
        "namespace",
        "kind",
        "isBlocking",
    ] {
        if let Some(value) = params.get(key).filter(|value| value.is_string()) {
            summary.insert(key.into(), value.clone());
        } else if let Some(value) = params.get(key).filter(|value| value.is_boolean()) {
            summary.insert(key.into(), value.clone());
        }
    }
    if let Some(deadline) = params
        .get("_wonderQuestionDeadlineMs")
        .and_then(serde_json::Value::as_u64)
    {
        summary.insert("expiresAtMs".into(), deadline.into());
    }
    if let Some(decisions) = params
        .get("availableDecisions")
        .and_then(|value| value.as_array())
    {
        summary.insert("availableDecisions".into(), decisions.clone().into());
    }
    if let Some(changes) = params.get("changes").and_then(|value| value.as_array()) {
        let safe_changes = changes
            .iter()
            .filter_map(|change| {
                let object = change.as_object()?;
                let mut safe = serde_json::Map::new();
                for key in ["path", "kind"] {
                    if let Some(value) = object
                        .get(key)
                        .filter(|value| value.is_string() || value.is_boolean())
                    {
                        safe.insert(key.into(), value.clone());
                    }
                }
                (!safe.is_empty()).then_some(serde_json::Value::Object(safe))
            })
            .collect::<Vec<_>>();
        summary.insert("changes".into(), safe_changes.into());
    }
    if let Some(questions) = params.get("questions").and_then(|value| value.as_array()) {
        let safe_questions = questions
            .iter()
            .filter_map(|question| {
                let object = question.as_object()?;
                let mut safe = serde_json::Map::new();
                for key in ["id", "header", "question", "isSecret", "isOther"] {
                    if let Some(value) = object
                        .get(key)
                        .filter(|value| value.is_string() || value.is_boolean())
                    {
                        safe.insert(key.into(), value.clone());
                    }
                }
                if let Some(options) = object.get("options").and_then(|value| value.as_array()) {
                    let safe_options = options
                        .iter()
                        .filter_map(|option| {
                            let object = option.as_object()?;
                            let mut safe = serde_json::Map::new();
                            for key in ["label", "description"] {
                                if let Some(value) =
                                    object.get(key).filter(|value| value.is_string())
                                {
                                    safe.insert(key.into(), value.clone());
                                }
                            }
                            (!safe.is_empty()).then_some(serde_json::Value::Object(safe))
                        })
                        .collect::<Vec<_>>();
                    safe.insert("options".into(), safe_options.into());
                }
                (!safe.is_empty()).then_some(serde_json::Value::Object(safe))
            })
            .collect::<Vec<_>>();
        summary.insert("questions".into(), safe_questions.into());
    }
    if let Some(value) = params.get("permissions") {
        if let Some(value) = redact_permission_profile(value) {
            summary.insert("permissions".into(), value);
        }
    }
    if let Some(value) = params
        .get("additionalPermissions")
        .and_then(redact_permission_profile)
    {
        summary.insert("additionalPermissions".into(), value);
    }
    if let Some(context) = params
        .get("networkApprovalContext")
        .and_then(serde_json::Value::as_object)
    {
        let safe: serde_json::Map<String, serde_json::Value> = ["host", "protocol"]
            .into_iter()
            .filter_map(|key| {
                context
                    .get(key)
                    .filter(|value| value.is_string())
                    .map(|value| (key.into(), value.clone()))
            })
            .collect();
        summary.insert("networkApprovalContext".into(), safe.into());
    }
    if let Some(value) = params.get("scope").filter(|value| value.is_string()) {
        summary.insert("scope".into(), value.clone());
    }
    if let Some(value) = params
        .get("requestedSchema")
        .and_then(redact_elicitation_schema)
    {
        summary.insert("requestedSchema".into(), value);
    }
    if let Some(message) = params.get("message").filter(|value| value.is_string()) {
        summary.insert("message".into(), message.clone());
    }
    if let Some(mode) = params.get("mode").filter(|value| value.is_string()) {
        summary.insert("mode".into(), mode.clone());
    }
    summary.insert(
        "requestType".into(),
        serde_json::Value::String(method.into()),
    );
    serde_json::Value::Object(summary)
}

fn redact_permission_profile(value: &serde_json::Value) -> Option<serde_json::Value> {
    validate_permission_profile(value).ok()?;
    let object = value.as_object()?;
    let mut safe = serde_json::Map::new();
    for key in ["fileSystem", "network"] {
        if let Some(value) = object.get(key) {
            safe.insert(key.into(), redact_permission_branch(key, value));
        }
    }
    Some(serde_json::Value::Object(safe))
}

fn redact_permission_branch(kind: &str, value: &serde_json::Value) -> serde_json::Value {
    if value.is_null() {
        return serde_json::Value::Null;
    }
    let Some(object) = value.as_object() else {
        return serde_json::Value::Null;
    };
    let mut safe = serde_json::Map::new();
    if kind == "network" {
        if let Some(value) = object.get("enabled") {
            safe.insert("enabled".into(), value.clone());
        }
    } else {
        for key in ["entries", "globScanMaxDepth", "read", "write"] {
            if let Some(value) = object.get(key) {
                safe.insert(key.into(), value.clone());
            }
        }
    }
    serde_json::Value::Object(safe)
}

fn redact_elicitation_schema(value: &serde_json::Value) -> Option<serde_json::Value> {
    // A form's constraints are part of the consent request. Dropping fields or
    // validators changes what the phone is approving. Keep the bounded schema
    // intact; the phone declines schema shapes it cannot faithfully represent.
    (value.is_object() && value.to_string().len() <= 64 * 1024).then(|| value.clone())
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ApprovalResolution {
    decision: serde_json::Value,
    action_nonce: String,
    expected_state: String,
    idempotency_key: String,
    issued_at_ms: u64,
    signature: String,
    #[serde(default)]
    response_json: Option<String>,
}

async fn resolve_approval(
    State(state): State<AppState>,
    Path(approval_id): Path<String>,
    authenticated_device: Option<Extension<AuthenticatedDevice>>,
    Json(request): Json<ApprovalResolution>,
) -> Response {
    let Some(Extension(device)) = authenticated_device else {
        return (StatusCode::UNAUTHORIZED, "paired device required").into_response();
    };
    let device_id = device.device_id.clone();
    if computer_tools::retire_completed(&state).await.is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let _approval_guard = state.approval_lock.lock().await;
    let Some(approval) = (match state.store.begin_approval_resolution(&approval_id).await {
        Ok(Some(approval)) => Some(approval),
        Ok(None) => state
            .store
            .resume_approval_resolution(&approval_id)
            .await
            .unwrap_or(None),
        Err(_) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, "approval lookup failed").into_response()
        }
    }) else {
        return (
            StatusCode::CONFLICT,
            Json(serde_json::json!({ "error": "already_resolved" })),
        )
            .into_response();
    };
    let recovering_resolution = approval.state == "resolving" && approval.resolution_json.is_some();
    if approval.method == "item/tool/requestUserInput" && !recovering_resolution {
        let params: serde_json::Value =
            serde_json::from_str(&approval.params_json).unwrap_or_default();
        if params
            .get("isBlocking")
            .and_then(serde_json::Value::as_bool)
            == Some(false)
            && params
                .get("_wonderQuestionDeadlineMs")
                .and_then(serde_json::Value::as_u64)
                .is_some_and(|deadline| now_ms() >= deadline)
        {
            let _ = state.store.reset_approval_resolution(&approval_id).await;
            return (
                StatusCode::CONFLICT,
                "This optional question expired without an answer.",
            )
                .into_response();
        }
    }

    if validate_stored_approval_correlation(&approval).is_err() {
        let _ = state.store.reset_approval_resolution(&approval_id).await;
        return (
            StatusCode::BAD_REQUEST,
            "approval correlation is incomplete",
        )
            .into_response();
    }
    if approval.action_nonce.is_empty()
        || request.action_nonce != approval.action_nonce
        || request.expected_state != "pending"
        || request.idempotency_key.is_empty()
        || request.issued_at_ms.abs_diff(now_ms()) > 60_000
    {
        let _ = state.store.reset_approval_resolution(&approval_id).await;
        return (
            StatusCode::PRECONDITION_FAILED,
            "stale approval precondition",
        )
            .into_response();
    }
    let canonical_body = canonical_approval_body(&request);
    let body_sha256 = hex::encode(Sha256::digest(canonical_body.as_bytes()));
    if recovering_resolution
        && (approval.resolution_idempotency_key.as_deref()
            != Some(request.idempotency_key.as_str())
            || approval.resolution_body_sha256.as_deref() != Some(body_sha256.as_str()))
    {
        return (
            StatusCode::CONFLICT,
            "approval resolution is already in progress",
        )
            .into_response();
    }
    let advertised = serde_json::from_str::<serde_json::Value>(&approval.params_json)
        .ok()
        .and_then(|params| params.get("availableDecisions").cloned());
    let advertised = advertised.and_then(|decisions| decisions.as_array().cloned());
    if matches!(
        approval.method.as_str(),
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval"
    ) && validate_command_decision(&request.decision, advertised.as_deref()).is_err()
    {
        let _ = state.store.reset_approval_resolution(&approval_id).await;
        return (StatusCode::BAD_REQUEST, "decision was not advertised").into_response();
    }
    let approval_params: serde_json::Value =
        serde_json::from_str(&approval.params_json).unwrap_or_default();
    let approval_client = if approval_params.get("_wonderRuntimeId").is_some() {
        let Some(client) = state.ingestion.approval_client(&approval_params) else {
            let _ = state.store.reset_approval_resolution(&approval_id).await;
            return (
                StatusCode::CONFLICT,
                "This approval expired when the Bot restarted. Refresh the chat.",
            )
                .into_response();
        };
        client
    } else {
        state.app_server.clone()
    };
    let approval_runtime = approval_client.lock().await.rpc();
    if approval_params
        .get("_wonderRuntimeId")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|id| id != approval_runtime.health().id())
        || !approval_runtime.health().is_alive()
    {
        let _ = state.store.reset_approval_resolution(&approval_id).await;
        return (
            StatusCode::CONFLICT,
            "This approval expired when the Bot restarted. Refresh the chat.",
        )
            .into_response();
    }
    let dynamic_tool_requested = match dynamic_tool_execution_requested(
        &approval.method,
        &request.decision,
        request.response_json.as_deref(),
        state.computer_use_enabled,
    ) {
        Ok(execute) => execute,
        Err(message) => {
            let _ = state.store.reset_approval_resolution(&approval_id).await;
            return (StatusCode::BAD_REQUEST, message).into_response();
        }
    };
    let dynamic_tool_execute =
        should_execute_dynamic_tool(recovering_resolution, dynamic_tool_requested);
    let response = match if recovering_resolution {
        serde_json::from_str::<serde_json::Value>(
            approval.resolution_json.as_deref().unwrap_or("{}"),
        )
        .map_err(|_| "stored approval response is invalid")
    } else if dynamic_tool_execute {
        if state.computer_use_bin.is_some() {
            serde_json::from_str::<serde_json::Value>(&approval.params_json)
                .map(|_| serde_json::Value::Null)
                .map_err(|_| "dynamic tool params are invalid")
        } else {
            Err("computer-use service is unavailable")
        }
    } else {
        build_approval_response(&approval.method, &approval.params_json, &request)
    } {
        Ok(response) => response,
        Err(message) => {
            let _ = state.store.reset_approval_resolution(&approval_id).await;
            return (StatusCode::BAD_REQUEST, message).into_response();
        }
    };
    let action_path = format!("/api/v1/approvals/{approval_id}/resolve");
    let transcript = ActionTranscript {
        action: "approval.resolve",
        target: &action_path,
        body_sha256: &body_sha256,
        action_nonce: &approval.action_nonce,
        session_binding: &device.session_binding,
        device_id: &device_id,
        host_installation_id: &state.host_installation_id,
        issued_at_ms: request.issued_at_ms,
        expected_state: &request.expected_state,
    };
    if state
        .pairing
        .lock()
        .await
        .verify_action_signature(&device_id, &transcript, &request.signature)
        .is_err()
    {
        let _ = state.store.reset_approval_resolution(&approval_id).await;
        return (StatusCode::UNAUTHORIZED, "invalid action signature").into_response();
    }
    let response = if dynamic_tool_execute {
        let params = match serde_json::from_str::<serde_json::Value>(&approval.params_json) {
            Ok(params) => params,
            Err(_) => {
                let _ = state.store.reset_approval_resolution(&approval_id).await;
                return (StatusCode::BAD_REQUEST, "dynamic tool params are invalid")
                    .into_response();
            }
        };
        let Some(_binary) = state.computer_use_bin.as_deref() else {
            let _ = state.store.reset_approval_resolution(&approval_id).await;
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "computer-use service is unavailable",
            )
                .into_response();
        };
        if let Err(error) = computer_tools::scope(&state, &params).await {
            let _ = state.store.reset_approval_resolution(&approval_id).await;
            return (StatusCode::CONFLICT, error).into_response();
        }
        let interrupted = dynamic_tool_response(Err("This computer action was interrupted. Inspect the screen before requesting another action.".into()));
        if !state
            .store
            .persist_approval_resolution_intent(
                &approval_id,
                &request.idempotency_key,
                &body_sha256,
                &interrupted.to_string(),
            )
            .await
            .unwrap_or(false)
        {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "approval persistence failed",
            )
                .into_response();
        }
        computer_tools::execute_once(&state, &params, &approval_id).await
    } else {
        response
    };
    let response_json = serde_json::to_string(&response).unwrap_or_else(|_| "null".into());
    let persisted = state
        .store
        .persist_approval_resolution_intent(
            &approval_id,
            &request.idempotency_key,
            &body_sha256,
            &response_json,
        )
        .await
        .unwrap_or(false);
    if !persisted {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "approval persistence failed",
        )
            .into_response();
    }
    let screenshot_url = if dynamic_tool_execute {
        computer_use_screenshot_url(&response)
    } else {
        None
    };
    let server_id = approval_params
        .get("_wonderRequestId")
        .cloned()
        .unwrap_or_else(|| {
            approval
                .server_request_id
                .parse::<u64>()
                .map(serde_json::Value::from)
                .unwrap_or_else(|_| serde_json::Value::String(approval.server_request_id.clone()))
        });
    let response = approval_runtime
        .respond_value(server_id, Some(response), None)
        .await;
    drop(approval_runtime);
    if response.is_err() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "App Server response failed",
        )
            .into_response();
    }
    if state
        .store
        .finish_approval_resolution(
            &approval_id,
            &decision_label(&request.decision),
            &now_ms().to_string(),
        )
        .await
        .is_err()
    {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "approval persistence failed",
        )
            .into_response();
    }
    if let Some(image_url) = screenshot_url {
        let message = state
            .store
            .message_for_codex_turn(&approval.turn_id)
            .await
            .ok()
            .flatten();
        let _ = publish_event_with_context(
            &state,
            WonderEvent::ComputerUseScreenshot { image_url },
            EventContext {
                conversation_id: message.as_ref().map(|item| item.conversation_id.clone()),
                message_id: message.as_ref().map(|item| item.id.clone()),
                thread_id: Some(approval.thread_id.clone()),
                turn_id: Some(approval.turn_id.clone()),
                item_id: Some(approval.item_id.clone()),
                approval_id: Some(approval_id.clone()),
                ..EventContext::default()
            },
        )
        .await;
    }
    let _ = publish_event_with_context(
        &state,
        WonderEvent::ApprovalResolved {
            request_id: approval_id.clone(),
            decision: decision_label(&request.decision),
        },
        EventContext {
            request_id: Some(approval_id.clone()),
            approval_id: Some(approval_id),
            ..EventContext::default()
        },
    )
    .await;
    StatusCode::NO_CONTENT.into_response()
}

fn validate_stored_approval_correlation(
    approval: &wonder_store::StoredApproval,
) -> Result<(), &'static str> {
    let requires_thread_turn = matches!(
        approval.method.as_str(),
        "item/commandExecution/requestApproval"
            | "item/fileChange/requestApproval"
            | "item/permissions/requestApproval"
            | "item/tool/requestUserInput"
            | "item/tool/call"
    );
    if requires_thread_turn && (approval.thread_id.is_empty() || approval.turn_id.is_empty()) {
        return Err("approval requires threadId and turnId");
    }
    if approval.method == "mcpServer/elicitation/request" && approval.thread_id.is_empty() {
        return Err("MCP elicitation requires threadId");
    }
    Ok(())
}

/// The detached action signature covers this stable unsigned body projection,
/// rather than serializer-dependent JSON key order or signature bytes.
fn canonical_approval_body(request: &ApprovalResolution) -> String {
    serde_json::to_string(&serde_json::json!([
        request.decision,
        request.action_nonce,
        request.expected_state,
        request.idempotency_key,
        request.response_json.as_deref().unwrap_or_default(),
    ]))
    .expect("canonical approval body is serializable")
}

fn decision_label(decision: &serde_json::Value) -> String {
    decision
        .as_str()
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| serde_json::to_string(decision).unwrap_or_else(|_| "invalid".into()))
}

fn validate_command_decision(
    decision: &serde_json::Value,
    advertised: Option<&[serde_json::Value]>,
) -> Result<(), &'static str> {
    let valid = match decision {
        serde_json::Value::String(value) => matches!(
            value.as_str(),
            "accept" | "acceptForSession" | "decline" | "cancel"
        ),
        serde_json::Value::Object(object) if object.len() == 1 => {
            if let Some(amendment) = object.get("acceptWithExecpolicyAmendment") {
                amendment
                    .get("execpolicy_amendment")
                    .and_then(serde_json::Value::as_array)
                    .is_some_and(|items| items.iter().all(serde_json::Value::is_string))
            } else if let Some(amendment) = object.get("applyNetworkPolicyAmendment") {
                amendment
                    .get("network_policy_amendment")
                    .is_some_and(|value| value.is_object())
            } else {
                false
            }
        }
        _ => false,
    };
    if !valid {
        return Err("decision has an invalid App Server approval shape");
    }
    if advertised.is_some_and(|values| !values.iter().any(|value| value == decision)) {
        return Err("decision was not advertised");
    }
    Ok(())
}

fn build_approval_response(
    method: &str,
    params_json: &str,
    request: &ApprovalResolution,
) -> Result<serde_json::Value, &'static str> {
    let response_json = request.response_json.as_deref();
    match method {
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
            if let Some(response_json) = response_json {
                let response: serde_json::Value = serde_json::from_str(response_json)
                    .map_err(|_| "responseJson must be valid JSON")?;
                let response_decision = response
                    .get("decision")
                    .ok_or("approval response must contain a decision")?;
                if response_decision != &request.decision {
                    return Err("approval response decision does not match decision");
                }
                Ok(response)
            } else {
                Ok(serde_json::json!({ "decision": request.decision }))
            }
        }
        "item/permissions/requestApproval" => {
            let response_json =
                response_json.ok_or("permissions approval requires responseJson")?;
            let response: serde_json::Value = serde_json::from_str(response_json)
                .map_err(|_| "responseJson must be valid JSON")?;
            match request.decision.as_str() {
                Some("accept" | "acceptForSession") => {
                    validate_permissions_response(params_json, &response)?
                }
                Some("decline" | "cancel") => {
                    if response != serde_json::json!({"permissions": {}, "scope": "turn"}) {
                        return Err("declined permission requests cannot grant access");
                    }
                }
                _ => return Err("invalid permission decision"),
            }
            Ok(response)
        }
        "item/tool/requestUserInput" => {
            let response_json = response_json.ok_or("user-input approval requires responseJson")?;
            let response: serde_json::Value = serde_json::from_str(response_json)
                .map_err(|_| "responseJson must be valid JSON")?;
            validate_user_input_response(params_json, &response)?;
            Ok(response)
        }
        "mcpServer/elicitation/request" => {
            let response_json = response_json.ok_or("MCP elicitation requires responseJson")?;
            let response: serde_json::Value = serde_json::from_str(response_json)
                .map_err(|_| "responseJson must be valid JSON")?;
            validate_mcp_response(
                params_json,
                request
                    .decision
                    .as_str()
                    .ok_or("MCP decision must be a string")?,
                &response,
            )?;
            Ok(response)
        }
        "item/tool/call" => {
            if request.decision.as_str() != Some("respond") {
                return Err("dynamic tool response requires the respond decision");
            }
            let response_json =
                response_json.ok_or("dynamic tool response requires responseJson")?;
            let response: serde_json::Value = serde_json::from_str(response_json)
                .map_err(|_| "responseJson must be valid JSON")?;
            validate_dynamic_tool_response(&response)?;
            Ok(response)
        }
        _ => Err("unsupported App Server approval request type"),
    }
}

fn validate_permissions_response(
    params_json: &str,
    response: &serde_json::Value,
) -> Result<(), &'static str> {
    let requested = serde_json::from_str::<serde_json::Value>(params_json)
        .ok()
        .and_then(|params| params.get("permissions").cloned())
        .ok_or("permission request did not contain a permission profile")?;
    validate_permission_profile(&requested)?;
    let permissions = response
        .get("permissions")
        .ok_or("permissions response must contain permissions")?;
    if response.as_object().is_none_or(|object| {
        object
            .keys()
            .any(|key| !matches!(key.as_str(), "permissions" | "scope" | "strictAutoReview"))
    }) {
        return Err("permissions response contains an unknown field");
    }
    validate_permission_profile(permissions)?;
    if !permission_profile_subset(permissions, &requested) {
        return Err("granted permissions exceed the requested profile");
    }
    if response
        .get("scope")
        .and_then(serde_json::Value::as_str)
        .is_none_or(|scope| !matches!(scope, "turn" | "session"))
    {
        return Err("permission scope must be turn or session");
    }
    if response
        .get("strictAutoReview")
        .is_some_and(|value| !value.is_boolean() && !value.is_null())
    {
        return Err("strictAutoReview must be boolean or null");
    }
    Ok(())
}

fn validate_permission_profile(value: &serde_json::Value) -> Result<(), &'static str> {
    let object = value
        .as_object()
        .ok_or("permission profile must be an object")?;
    if object
        .keys()
        .any(|key| !matches!(key.as_str(), "fileSystem" | "network"))
    {
        return Err("permission profile contains an unknown field");
    }
    validate_filesystem_permissions(object.get("fileSystem").unwrap_or(&serde_json::Value::Null))?;
    validate_network_permissions(object.get("network").unwrap_or(&serde_json::Value::Null))
}

fn validate_filesystem_permissions(value: &serde_json::Value) -> Result<(), &'static str> {
    let Some(object) = value.as_object() else {
        return if value.is_null() {
            Ok(())
        } else {
            Err("fileSystem permissions must be an object or null")
        };
    };
    if object.keys().any(|key| {
        !matches!(
            key.as_str(),
            "entries" | "globScanMaxDepth" | "read" | "write"
        )
    }) {
        return Err("fileSystem permissions contain an unknown field");
    }
    if let Some(value) = object.get("globScanMaxDepth") {
        if !value.is_null() && value.as_i64().is_none_or(|depth| depth < 1) {
            return Err("globScanMaxDepth must be a positive integer or null");
        }
    }
    for key in ["read", "write"] {
        if let Some(value) = object.get(key) {
            if !value.is_null()
                && !value
                    .as_array()
                    .is_some_and(|items| items.iter().all(serde_json::Value::is_string))
            {
                return Err("filesystem legacy permissions must be string arrays or null");
            }
        }
    }
    if let Some(value) = object.get("entries") {
        if !value.is_null()
            && !value
                .as_array()
                .is_some_and(|items| items.iter().all(validate_filesystem_entry))
        {
            return Err("filesystem entries are malformed");
        }
    }
    Ok(())
}

fn validate_network_permissions(value: &serde_json::Value) -> Result<(), &'static str> {
    let Some(object) = value.as_object() else {
        return if value.is_null() {
            Ok(())
        } else {
            Err("network permissions must be an object or null")
        };
    };
    if object.keys().any(|key| key != "enabled")
        || object
            .get("enabled")
            .is_some_and(|value| !value.is_null() && !value.is_boolean())
    {
        return Err("network permissions are malformed");
    }
    Ok(())
}

fn validate_filesystem_entry(value: &serde_json::Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    matches!(
        object.get("access").and_then(serde_json::Value::as_str),
        Some("read" | "write" | "deny")
    ) && validate_filesystem_path(object.get("path").unwrap_or(&serde_json::Value::Null))
}

fn validate_filesystem_path(value: &serde_json::Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    match object.get("type").and_then(serde_json::Value::as_str) {
        Some("path") => object.get("path").is_some_and(serde_json::Value::is_string),
        Some("glob_pattern") => object
            .get("pattern")
            .is_some_and(serde_json::Value::is_string),
        Some("special") => object
            .get("value")
            .is_some_and(validate_filesystem_special_path),
        _ => false,
    }
}

fn validate_filesystem_special_path(value: &serde_json::Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    let Some(kind) = object.get("kind").and_then(serde_json::Value::as_str) else {
        return false;
    };
    match kind {
        "root" | "minimal" | "tmpdir" | "slash_tmp" => object.len() == 1,
        "project_roots" => {
            object
                .keys()
                .all(|key| matches!(key.as_str(), "kind" | "subpath"))
                && object
                    .get("subpath")
                    .is_none_or(|value| value.is_null() || value.is_string())
        }
        "unknown" => {
            object
                .keys()
                .all(|key| matches!(key.as_str(), "kind" | "path" | "subpath"))
                && object.get("path").is_some_and(serde_json::Value::is_string)
                && object
                    .get("subpath")
                    .is_none_or(|value| value.is_null() || value.is_string())
        }
        _ => false,
    }
}

fn permission_profile_subset(granted: &serde_json::Value, requested: &serde_json::Value) -> bool {
    let (Some(granted), Some(requested)) = (granted.as_object(), requested.as_object()) else {
        return false;
    };
    filesystem_subset(
        granted
            .get("fileSystem")
            .unwrap_or(&serde_json::Value::Null),
        requested
            .get("fileSystem")
            .unwrap_or(&serde_json::Value::Null),
    ) && network_subset(
        granted.get("network").unwrap_or(&serde_json::Value::Null),
        requested.get("network").unwrap_or(&serde_json::Value::Null),
    )
}

fn filesystem_subset(granted: &serde_json::Value, requested: &serde_json::Value) -> bool {
    if granted.is_null() {
        return true;
    }
    let (Some(granted), Some(requested)) = (granted.as_object(), requested.as_object()) else {
        return false;
    };
    for key in ["read", "write", "entries"] {
        let Some(granted_values) = granted.get(key).filter(|value| !value.is_null()) else {
            continue;
        };
        let Some(requested_values) = requested.get(key).and_then(serde_json::Value::as_array)
        else {
            return false;
        };
        if !granted_values.as_array().is_some_and(|items| {
            items
                .iter()
                .all(|item| requested_values.iter().any(|allowed| allowed == item))
        }) {
            return false;
        }
    }
    match (
        granted.get("globScanMaxDepth"),
        requested.get("globScanMaxDepth"),
    ) {
        (Some(value), Some(allowed)) if !value.is_null() => value
            .as_i64()
            .zip(allowed.as_i64())
            .is_some_and(|(value, allowed)| value <= allowed),
        (Some(value), None) if !value.is_null() => false,
        _ => true,
    }
}

fn network_subset(granted: &serde_json::Value, requested: &serde_json::Value) -> bool {
    if granted.is_null()
        || granted.get("enabled").and_then(serde_json::Value::as_bool) != Some(true)
    {
        return true;
    }
    requested
        .get("enabled")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
}

fn validate_user_input_response(
    params_json: &str,
    response: &serde_json::Value,
) -> Result<(), &'static str> {
    let questions = serde_json::from_str::<serde_json::Value>(params_json)
        .ok()
        .and_then(|params| params.get("questions").cloned())
        .and_then(|questions| questions.as_array().cloned())
        .ok_or("user-input request did not contain questions")?;
    let answers = response
        .get("answers")
        .and_then(serde_json::Value::as_object)
        .ok_or("user-input response must contain an answers object")?;
    if answers.keys().any(|id| {
        !questions
            .iter()
            .any(|question| question.get("id").and_then(serde_json::Value::as_str) == Some(id))
    }) {
        return Err("user-input response contains an unknown question id");
    }
    if answers.values().any(|answer| {
        answer
            .get("answers")
            .and_then(serde_json::Value::as_array)
            .is_none_or(|values| values.iter().any(|value| !value.is_string()))
    }) {
        return Err("each user-input answer must contain string values");
    }
    Ok(())
}

fn validate_mcp_response(
    params_json: &str,
    decision: &str,
    response: &serde_json::Value,
) -> Result<(), &'static str> {
    let action = response
        .get("action")
        .and_then(serde_json::Value::as_str)
        .ok_or("MCP response must contain an action")?;
    if !matches!(action, "accept" | "decline" | "cancel") || action != decision {
        return Err("MCP response action does not match decision");
    }
    if action != "accept" {
        if response
            .get("content")
            .is_some_and(|value| !value.is_null())
        {
            return Err("declined service requests cannot include form answers");
        }
        return Ok(());
    }
    let params: serde_json::Value =
        serde_json::from_str(params_json).map_err(|_| "invalid service request")?;
    match params.get("mode").and_then(serde_json::Value::as_str) {
        Some("url") => {
            if response
                .get("content")
                .is_some_and(|value| !value.is_null())
            {
                return Err("browser confirmations cannot include form answers");
            }
        }
        Some("form" | "openai/form" | "openaiForm") => {
            validate_elicitation_content(&params, response)?;
        }
        None if params.get("requestedSchema").is_some() => {
            validate_elicitation_content(&params, response)?;
        }
        None => {} // Legacy confirmation requests have no form schema.
        Some(_) => return Err("this service request can only be declined or cancelled"),
    }
    Ok(())
}

fn validate_elicitation_content(
    params: &serde_json::Value,
    response: &serde_json::Value,
) -> Result<(), &'static str> {
    let schema = params
        .get("requestedSchema")
        .and_then(redact_elicitation_schema)
        .ok_or("service form schema is missing or too large")?;
    // Never let a service-supplied schema read a file or make a network request.
    // Standard MCP forms are inline. Future reference-based forms remain declineable.
    fn contains_reference(value: &serde_json::Value) -> bool {
        match value {
            serde_json::Value::Object(object) => object.iter().any(|(key, value)| {
                matches!(key.as_str(), "$ref" | "$dynamicRef" | "$recursiveRef")
                    || contains_reference(value)
            }),
            serde_json::Value::Array(values) => values.iter().any(contains_reference),
            _ => false,
        }
    }
    if contains_reference(&schema) {
        return Err("referenced service schemas are unsupported");
    }
    let validator = jsonschema::options()
        .offline()
        .should_validate_formats(true)
        .build(&schema)
        .map_err(|_| "service form schema is invalid")?;
    let content = response
        .get("content")
        .ok_or("accepted service forms require answers")?;
    if !validator.is_valid(content) {
        return Err("service answers do not match the requested form");
    }
    Ok(())
}

fn validate_dynamic_tool_response(response: &serde_json::Value) -> Result<(), &'static str> {
    if response.get("success").and_then(serde_json::Value::as_bool) != Some(false) {
        return Err("Wonder can only decline unregistered dynamic tool calls");
    }
    if !response
        .get("contentItems")
        .and_then(serde_json::Value::as_array)
        .is_some_and(Vec::is_empty)
    {
        return Err("declined dynamic tool calls must have empty contentItems");
    }
    Ok(())
}

fn dynamic_tool_execution_requested(
    method: &str,
    decision: &serde_json::Value,
    response_json: Option<&str>,
    computer_use_enabled: bool,
) -> Result<bool, &'static str> {
    if method != "item/tool/call" || decision.as_str() != Some("respond") || !computer_use_enabled {
        return Ok(false);
    }
    let response_json = response_json.ok_or("dynamic tool response requires responseJson")?;
    let response = serde_json::from_str::<serde_json::Value>(response_json)
        .map_err(|_| "responseJson must be valid JSON")?;
    Ok(response.get("success").and_then(serde_json::Value::as_bool) == Some(true))
}

fn should_execute_dynamic_tool(recovering_resolution: bool, requested: bool) -> bool {
    requested && !recovering_resolution
}

fn pairing_error_response(error: PairingError) -> Response {
    if error == PairingError::ConfirmationRequired {
        return (
            StatusCode::CONFLICT,
            Json(serde_json::json!({"error": "confirmation_required"})),
        )
            .into_response();
    }
    let status = match error {
        PairingError::BindingMismatch | PairingError::SessionExpired => StatusCode::UNAUTHORIZED,
        PairingError::NotFound
        | PairingError::ChallengeNotFound
        | PairingError::SessionNotFound => StatusCode::NOT_FOUND,
        PairingError::Expired
        | PairingError::ChallengeExpired
        | PairingError::AlreadyConsumed
        | PairingError::ChallengeReplayed => StatusCode::GONE,
        _ => StatusCode::BAD_REQUEST,
    };
    (
        status,
        [(header::CACHE_CONTROL, "no-store")],
        Json(serde_json::json!({ "error": "pairing_failed" })),
    )
        .into_response()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_millis() as u64)
}

#[cfg(test)]
mod approval_routing_tests;
#[cfg(test)]
mod search_tests;

#[cfg(test)]
mod tests {
    use super::{
        app_server_notification_key, artifact_event_detail, artifact_mime_type, attachment_path,
        attachment_relative_path, automation_conversation_id, bot_handle, build_approval_response,
        canonical_approval_body, canonical_audio_mime, computer_use_screenshot_url,
        conversation_thread_projection, conversation_thread_projection_with_items,
        decode_local_href, default_session_expiration, drain_pending_app_server_notifications,
        dynamic_tool_response, extract_text, find_client_message, host_readiness_state,
        inherited_child_resume_params, is_valid_public_origin, matches_public_origin,
        next_automation_run, now_ms, pairing_offer_response, project_app_server_notification,
        public_origin_from_status_log, publish_app_server_notification, read_workspace_artifact,
        resolve_channel_route, rollback_bot_artifacts, route_auth, router, run_computer_use,
        runtime_app_summary, runtime_mcp_server_summary, runtime_skill_summary,
        sanitize_ansi_and_secrets, sanitize_typed_item, sanitized_relative_path,
        search_result_deep_link, should_execute_dynamic_tool, sniff_audio_mime,
        steer_response_turn_id, steer_turn_params, turn_input, valid_attachment_ids,
        valid_attachment_mime_type, valid_attachment_name, valid_channel_description,
        valid_channel_member_count, valid_device_label, validate_bot_runtime_settings,
        workspace_file_path, AppServerThreadItem, AppState, ApprovalResolution, ChannelRoute,
        ChoiceOption, HostEventEnvelope, ModelOption, PermissionProfileOption, RouteAuth,
        RuntimeCatalog, StoredChannelMember, WonderEvent, CHANNEL_WORKER_CONCURRENCY,
        MAX_ATTACHMENT_BYTES, MAX_WORKSPACE_ARTIFACT_BYTES,
    };
    use base64::Engine as _;
    use sha2::{Digest, Sha256};
    use std::sync::Arc;
    use wonder_store::{StoredAssistantMessage, StoredMessage};

    pub(super) fn validate_http_contract(definition: &str, value: &serde_json::Value) {
        let authority: serde_json::Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/schemas/wonder-http-v1.json"
        ))
        .expect("HTTP schema JSON");
        let schema = serde_json::json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$ref": format!("#/$defs/{definition}"),
            "$defs": authority["$defs"]
        });
        let validator = jsonschema::validator_for(&schema).expect("valid HTTP schema");
        let errors: Vec<_> = validator
            .iter_errors(value)
            .map(|error| error.to_string())
            .collect();
        assert!(errors.is_empty(), "{definition}: {errors:?}");
    }

    #[test]
    fn computer_signaling_contract_requires_peer_revision_for_mutations() {
        let authority: serde_json::Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/schemas/wonder-http-v1.json"
        ))
        .expect("HTTP schema JSON");
        let validator = |definition: &str| {
            jsonschema::validator_for(&serde_json::json!({
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "$ref": format!("#/$defs/{definition}"),
                "$defs": authority["$defs"]
            }))
            .expect("valid signaling schema")
        };
        let binding = serde_json::json!({
            "generation": 1,
            "conversationId": "conversation",
            "hostInstallationId": "host"
        });
        let mut poll = binding.clone();
        poll["cursor"] = serde_json::json!(0);
        validate_http_contract("computerSignalingPollRequest", &poll);

        let mut answer = binding.clone();
        answer["peerRevision"] = serde_json::json!("peer");
        answer["type"] = serde_json::json!("answer");
        answer["sdp"] = serde_json::json!("v=0\na=x");
        assert!(validator("computerSignalingAnswerRequest").is_valid(&answer));
        answer.as_object_mut().unwrap().remove("peerRevision");
        assert!(!validator("computerSignalingAnswerRequest").is_valid(&answer));

        poll["unexpected"] = serde_json::json!(true);
        assert!(!validator("computerSignalingPollRequest").is_valid(&poll));
    }

    #[test]
    fn child_resume_never_overrides_inherited_execution_settings() {
        let params = inherited_child_resume_params("child-thread");
        assert_eq!(
            params,
            serde_json::json!({
                "threadId": "child-thread",
                "excludeTurns": true
            })
        );
        for forbidden in [
            "cwd",
            "permissions",
            "runtimeWorkspaceRoots",
            "approvalPolicy",
            "approvalsReviewer",
            "model",
            "developerInstructions",
        ] {
            assert!(
                params.get(forbidden).is_none(),
                "must not override {forbidden}"
            );
        }
    }

    #[tokio::test]
    async fn child_user_mutations_and_saved_intent_are_read_only() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        state
            .store
            .ensure_conversation_metadata("bot", "bot", "Bot", "now")
            .await
            .unwrap();
        state
            .store
            .set_conversation_thread("bot", "thread", Some("session"), "now")
            .await
            .unwrap();
        std::fs::write(dir.path().join("child-fixture"), "").unwrap();
        let _ingestion = crate::ingestion::spawn(state.clone()).await;
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while state.ingestion.runtime_routes().is_empty() {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("runtime registration");

        let response = crate::subagents::list(
            axum::extract::State(state.clone()),
            axum::extract::Path("bot".to_owned()),
        )
        .await;
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), 65_536)
            .await
            .unwrap();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["subagents"].as_array().unwrap().len(), 1);
        let child = value["subagents"][0]["conversationId"]
            .as_str()
            .unwrap()
            .to_owned();

        assert_eq!(value["subagents"][0]["canAcceptDirectInput"], false);
        assert!(crate::subagents::reject_user_mutation(&state, "bot")
            .await
            .is_none());
        let sent = super::send_message_inner(
            axum::extract::State(state.clone()),
            axum::extract::Path(child.clone()),
            None,
            axum::Json(super::SendMessageRequest {
                device_id: "owner".into(),
                client_message_id: uuid::Uuid::new_v4().to_string(),
                body: "keep this unsent".into(),
                attachment_ids: vec![],
                group_routing: None,
            }),
            None,
        )
        .await;
        assert_eq!(sent.status(), axum::http::StatusCode::FORBIDDEN);
        let guided = super::steer_turn(
            axum::extract::State(state.clone()),
            axum::extract::Path((child.clone(), "turn".into())),
            None,
            axum::Json(super::SteerTurnRequest {
                device_id: "owner".into(),
                client_message_id: uuid::Uuid::new_v4().to_string(),
                body: "keep this guide".into(),
                attachment_ids: vec![],
                expected_turn_id: "turn".into(),
            }),
        )
        .await;
        assert_eq!(guided.status(), axum::http::StatusCode::FORBIDDEN);
        let stopped = super::interrupt_turn(
            axum::extract::State(state.clone()),
            axum::extract::Path((child.clone(), "turn".into())),
        )
        .await;
        assert_eq!(stopped.status(), axum::http::StatusCode::FORBIDDEN);
        let upload = super::upload_conversation_file(
            axum::extract::State(state.clone()),
            axum::extract::Path(child.clone()),
            axum::Json(super::CreateConversationFileRequest {
                client_upload_id: None,
                name: "file.txt".into(),
                mime_type: None,
                content_base64: "aGVsbG8=".into(),
            }),
        )
        .await;
        assert_eq!(upload.status(), axum::http::StatusCode::FORBIDDEN);

        // An older client may have persisted a send before upgrading the host.
        let message = match state
            .store
            .insert_dispatch_message(
                "owner",
                "00000000-0000-4000-8000-000000000061",
                "preserved child draft",
                "hash",
                &child,
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        {
            wonder_store::MessageInsert::Inserted(message) => message,
            _ => panic!("new legacy child message"),
        };
        super::dispatch_to_codex(state.clone(), message.clone()).await;
        let retained = state
            .store
            .message_by_id(&message.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(retained.body, "preserved child draft");
        assert!(retained.codex_turn_id.is_none());
        assert!(matches!(
            retained.state.as_str(),
            "failed" | "safe_to_retry"
        ));
        let guide = match state
            .store
            .insert_guide_message(
                "owner",
                "00000000-0000-4000-8000-000000000062",
                "preserved child guide",
                "hash",
                &child,
                &[],
                "now",
                "turn",
            )
            .await
            .unwrap()
        {
            wonder_store::MessageInsert::Inserted(message) => message,
            _ => panic!("new legacy guide"),
        };
        let guided = super::dispatch_guide(state.clone(), guide, "turn".into()).await;
        assert_eq!(guided.status(), axum::http::StatusCode::CONFLICT);

        let requests = std::fs::read_to_string(dir.path().join("requests-jsonl")).unwrap();
        for line in requests.lines() {
            let request: serde_json::Value = serde_json::from_str(line).unwrap();
            assert!(
                ![
                    "thread/resume",
                    "turn/start",
                    "turn/steer",
                    "turn/interrupt"
                ]
                .contains(&request["method"].as_str().unwrap_or("")),
                "unexpected runtime mutation: {}",
                request["method"]
            );
        }
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[test]
    fn saved_native_response_fixtures_validate() {
        for (definition, raw) in [
            (
                "conversationSnapshot",
                include_str!("../../../tests/contracts/native/conversation-snapshot.json"),
            ),
            (
                "messageReceipt",
                include_str!("../../../tests/contracts/native/message-receipt.json"),
            ),
        ] {
            validate_http_contract(definition, &serde_json::from_str(raw).unwrap());
        }
    }

    #[test]
    fn create_channel_request_contract_supports_idempotent_retries_and_legacy_payloads() {
        let authority: serde_json::Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/schemas/wonder-http-v1.json"
        ))
        .expect("HTTP schema JSON");
        let schema = serde_json::json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$ref": "#/$defs/createChannelRequest",
            "$defs": authority["$defs"]
        });
        let validator = jsonschema::options()
            .should_validate_formats(true)
            .build(&schema)
            .expect("valid create channel schema");
        let request = serde_json::json!({
            "clientRequestId": "11111111-1111-4111-8111-111111111111",
            "name": "Team",
            "coordinatorBotId": "coordinator",
            "memberBotIds": []
        });

        assert!(
            validator.is_valid(&request),
            "stable UUID with no additional members must validate"
        );

        let mut legacy = request.clone();
        legacy.as_object_mut().unwrap().remove("clientRequestId");
        assert!(
            validator.is_valid(&legacy),
            "legacy omission must remain valid"
        );

        let mut malformed = request;
        malformed["clientRequestId"] = serde_json::json!("not-a-uuid");
        assert!(
            !validator.is_valid(&malformed),
            "malformed client request IDs must be rejected"
        );
    }

    #[test]
    fn thread_projection_groups_visible_and_operational_items_by_turn() {
        let messages = vec![StoredMessage {
            id: "message-1".into(),
            device_id: "device-1".into(),
            client_message_id: "client-1".into(),
            body: "Make a launch plan".into(),
            body_sha256: "hash".into(),
            conversation_id: "conversation-1".into(),
            state: "completed".into(),
            created_at: "2026-09-02T10:00:00Z".into(),
            codex_thread_id: Some("thread-1".into()),
            codex_turn_id: Some("turn-1".into()),
        }];
        let assistant_messages = vec![StoredAssistantMessage {
            id: "assistant-1".into(),
            conversation_id: "conversation-1".into(),
            codex_thread_id: "thread-1".into(),
            codex_turn_id: "turn-1".into(),
            item_id: "item-1".into(),
            text: "## Launch plan".into(),
            state: "completed".into(),
            created_at: "2026-09-02T10:00:01Z".into(),
            updated_at: "2026-09-02T10:00:02Z".into(),
        }];
        let events = vec![
            HostEventEnvelope {
                event_id: "event-1".into(),
                host_epoch: "epoch-1".into(),
                sequence: 1,
                occurred_at: "2026-09-02T10:00:01Z".into(),
                request_id: None,
                device_id: None,
                conversation_id: Some("conversation-1".into()),
                message_id: None,
                thread_id: Some("thread-1".into()),
                turn_id: Some("turn-1".into()),
                item_id: Some("command-1".into()),
                approval_id: None,
                event: WonderEvent::Activity {
                    category: "command".into(),
                    state: "completed".into(),
                    detail: Some("cargo test".into()),
                },
            },
            HostEventEnvelope {
                event_id: "event-1-replayed".into(),
                host_epoch: "epoch-1".into(),
                sequence: 2,
                occurred_at: "2026-09-02T10:00:02Z".into(),
                request_id: None,
                device_id: None,
                conversation_id: Some("conversation-1".into()),
                message_id: None,
                thread_id: Some("thread-1".into()),
                turn_id: Some("turn-1".into()),
                item_id: Some("command-1".into()),
                approval_id: None,
                event: WonderEvent::Activity {
                    category: "command".into(),
                    state: "started".into(),
                    detail: None,
                },
            },
        ];
        let projection = conversation_thread_projection(
            Some("thread-1".into()),
            &messages,
            &assistant_messages,
            &events,
        );
        assert_eq!(projection.turns.len(), 1);
        // Completed message/item receipts do not replace a turn lifecycle event.
        assert_eq!(projection.turns[0].status, "unknown");
        assert_eq!(
            projection.turns[0]
                .items
                .iter()
                .filter(|item| item.item_type == "userMessage")
                .count(),
            1
        );
        assert_eq!(
            projection.turns[0]
                .items
                .iter()
                .filter(|item| item.item_type == "agentMessage")
                .count(),
            1
        );
        assert_eq!(
            projection.turns[0]
                .items
                .iter()
                .filter(|item| item.item_type == "commandExecution")
                .count(),
            1
        );
        let command = projection.turns[0]
            .items
            .iter()
            .find(|item| item.item_type == "commandExecution")
            .unwrap();
        assert_eq!(command.state, "completed");
        assert_eq!(command.text.as_deref(), Some("cargo test"));
    }

    #[test]
    fn typed_thread_items_cover_new_protocol_variants_and_win_over_fallbacks() {
        let typed = vec![
            AppServerThreadItem {
                turn_id: "turn-typed".into(),
                item: serde_json::json!({
                    "type": "dynamicToolCall", "id": "item-typed", "tool": "demo",
                    "status": "started", "arguments": {"token": "sk-secret"}
                }),
            },
            AppServerThreadItem {
                turn_id: "turn-typed".into(),
                item: serde_json::json!({
                    "type": "enteredReviewMode", "id": "review-1", "review": "code"
                }),
            },
            AppServerThreadItem {
                turn_id: "turn-typed".into(),
                item: serde_json::json!({"type": "futureItem", "id": "future-1"}),
            },
        ];
        let events = vec![
            HostEventEnvelope {
                event_id: "event-fallback".into(),
                host_epoch: "epoch".into(),
                sequence: 1,
                occurred_at: "2026-09-02T10:00:00Z".into(),
                request_id: None,
                device_id: None,
                conversation_id: Some("conversation".into()),
                message_id: None,
                thread_id: Some("thread".into()),
                turn_id: Some("turn-typed".into()),
                item_id: Some("item-typed".into()),
                approval_id: None,
                event: WonderEvent::Activity {
                    category: "command".into(),
                    state: "started".into(),
                    detail: Some("fallback".into()),
                },
            },
            HostEventEnvelope {
                event_id: "event-late-terminal".into(),
                host_epoch: "epoch".into(),
                sequence: 2,
                occurred_at: "2026-09-02T10:00:02Z".into(),
                request_id: None,
                device_id: None,
                conversation_id: Some("conversation".into()),
                message_id: None,
                thread_id: Some("thread".into()),
                turn_id: Some("turn-typed".into()),
                item_id: Some("item-typed".into()),
                approval_id: None,
                event: WonderEvent::Activity {
                    category: "command".into(),
                    state: "failed".into(),
                    detail: Some("late contradictory terminal".into()),
                },
            },
        ];
        let projection = conversation_thread_projection_with_items(
            Some("thread".into()),
            &[],
            &[StoredAssistantMessage {
                id: "assistant-typed".into(),
                conversation_id: "conversation".into(),
                codex_thread_id: "thread".into(),
                codex_turn_id: "turn-typed".into(),
                item_id: "item-typed".into(),
                text: "durable terminal fallback".into(),
                state: "completed".into(),
                created_at: "2026-09-02T10:00:00Z".into(),
                updated_at: "2026-09-02T10:00:01Z".into(),
            }],
            &events,
            &typed,
            None,
        );
        let items = &projection.turns[0].items;
        assert!(items.iter().any(|item| item.item_type == "dynamicToolCall"));
        assert!(items
            .iter()
            .any(|item| item.item_type == "enteredReviewMode"));
        assert!(items.iter().any(|item| item.item_type == "unknown"));
        let dynamic = items.iter().find(|item| item.id == "item-typed").unwrap();
        assert_eq!(dynamic.item_type, "dynamicToolCall");
        assert_eq!(dynamic.state, "completed");
        assert!(!dynamic.payload.to_string().contains("sk-secret"));
    }

    #[test]
    fn durable_messages_without_codex_turns_remain_visible() {
        let messages = vec![StoredMessage {
            id: "message-local".into(),
            device_id: "device-1".into(),
            client_message_id: "client-local".into(),
            body: "Queued while offline".into(),
            body_sha256: "hash".into(),
            conversation_id: "conversation-1".into(),
            state: "pending".into(),
            created_at: "2026-09-02T10:00:00Z".into(),
            codex_thread_id: None,
            codex_turn_id: None,
        }];
        let projection = conversation_thread_projection(None, &messages, &[], &[]);
        assert_eq!(projection.turns.len(), 1);
        assert_eq!(projection.turns[0].id, "local:message-local");
        assert_eq!(
            projection.turns[0].items[0].text.as_deref(),
            Some("Queued while offline")
        );
    }

    #[test]
    fn typed_and_durable_user_messages_dedupe_by_client_id() {
        let messages = vec![StoredMessage {
            id: "database-message-id".into(),
            device_id: "device-1".into(),
            client_message_id: "shared-client-id".into(),
            body: "Hydrate this once".into(),
            body_sha256: "hash".into(),
            conversation_id: "conversation-1".into(),
            state: "completed".into(),
            created_at: "2026-09-02T10:00:00Z".into(),
            codex_thread_id: Some("thread-1".into()),
            codex_turn_id: Some("turn-1".into()),
        }];
        let typed = vec![AppServerThreadItem {
            turn_id: "turn-1".into(),
            item: serde_json::json!({
                "type": "userMessage",
                "id": "codex-item-id",
                "clientId": "shared-client-id",
                "content": [{"type": "input_text", "text": "Hydrate this once"}]
            }),
        }];
        let projection = conversation_thread_projection_with_items(
            Some("thread-1".into()),
            &messages,
            &[],
            &[],
            &typed,
            Some("/workspace"),
        );
        let user_items = projection.turns[0]
            .items
            .iter()
            .filter(|item| item.item_type == "userMessage")
            .collect::<Vec<_>>();
        assert_eq!(user_items.len(), 1);
        assert_eq!(user_items[0].id, "codex-item-id");
        assert_eq!(user_items[0].payload["clientId"], "shared-client-id");
        assert_eq!(user_items[0].payload["deliveryState"], "completed");
    }

    #[test]
    fn typed_commentary_and_mixed_output_preserve_phase_and_order() {
        let typed = vec![
            AppServerThreadItem {
                turn_id: "turn".into(),
                item: serde_json::json!({"type":"agentMessage","id":"z-commentary","phase":"commentary","text":"Checking the files."}),
            },
            AppServerThreadItem {
                turn_id: "turn".into(),
                item: serde_json::json!({"type":"dynamicToolCall","id":"m-tool","tool":"inspect","status":"completed","success":true,"arguments":{},"contentItems":[{"type":"inputText","text":"Found a chart."},{"type":"inputImage","imageUrl":"data:image/png;base64,synthetic"}]}),
            },
            AppServerThreadItem {
                turn_id: "turn".into(),
                item: serde_json::json!({"type":"agentMessage","id":"a-final","phase":"final_answer","text":"The check passed."}),
            },
        ];
        let projection = conversation_thread_projection_with_items(
            Some("thread".into()),
            &[],
            &[],
            &[],
            &typed,
            Some("/workspace"),
        );
        let items = &projection.turns[0].items;
        assert_eq!(
            items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            vec!["z-commentary", "m-tool", "a-final"]
        );
        assert_eq!(items[0].payload["phase"], "commentary");
        assert_eq!(items[0].text.as_deref(), Some("Checking the files."));
        assert_eq!(
            items[1].payload["contentItems"][0]["text"],
            "Found a chart."
        );
        assert_eq!(items[2].payload["phase"], "final_answer");
    }

    #[test]
    fn typed_only_streaming_items_do_not_establish_turn_status() {
        let typed = vec![AppServerThreadItem {
            turn_id: "turn-active".into(),
            item: serde_json::json!({
                "type": "commandExecution",
                "id": "command-active",
                "status": "running",
                "command": "cargo test"
            }),
        }];
        let projection = conversation_thread_projection_with_items(
            Some("thread-1".into()),
            &[],
            &[],
            &[],
            &typed,
            Some("/workspace"),
        );
        assert_eq!(projection.turns[0].status, "unknown");
        assert_eq!(projection.turns[0].items[0].state, "streaming");
    }

    #[test]
    fn terminal_projection_strips_ansi_redacts_secrets_and_bounds_output() {
        let value = format!(
            "\u{1b}[31mBearer secret-token\u{1b}[0m {}",
            "x".repeat(70_000)
        );
        let clean = sanitize_ansi_and_secrets(&value, 64 * 1024);
        assert!(!clean.contains('\u{1b}'));
        assert!(!clean.contains("secret-token"));
        assert!(clean.len() <= 64 * 1024);
    }

    #[test]
    fn typed_projection_keeps_only_safe_bounded_command_detail() {
        let safe = sanitize_typed_item(
            &serde_json::json!({
                "type": "commandExecution",
                "id": "command-1",
                "command": "curl -H 'Authorization: Bearer secret-token' https://example.invalid",
                "cwd": "/workspace",
                "environment": {"API_KEY": "secret"},
                "headers": {"cookie": "secret"},
                "aggregatedOutput": format!("\u{1b}[31mtoken=secret\u{1b}[0m {}", "x".repeat(70_000)),
                "commandActions": [{"type": "read", "path": "/etc/passwd"}],
                "savedPath": "/workspace/output/report.pdf",
                "agentPath": "/Users/private/agent.json",
                "nested": {"filePath": "/workspace/src/main.rs"},
                "paths": ["/workspace/a.txt", "/private/b.txt"],
                "processId": 42
            }),
            Some("/workspace"),
        );
        let encoded = safe.to_string();
        assert_eq!(safe["cwd"], ".");
        assert!(safe.get("environment").is_none());
        assert!(safe.get("headers").is_none());
        assert!(safe.get("commandActions").is_none());
        assert!(safe.get("processId").is_none());
        assert_eq!(safe["savedPath"], "output/report.pdf");
        assert_eq!(safe["agentPath"], "[path outside workspace]");
        assert_eq!(safe["nested"]["filePath"], "src/main.rs");
        assert_eq!(safe["paths"][0], "a.txt");
        assert_eq!(safe["paths"][1], "[path outside workspace]");
        assert!(!encoded.contains("secret-token"));
        assert!(!encoded.contains("token=secret"));
        assert!(safe["output"]
            .as_str()
            .is_some_and(|value| value.len() <= 64 * 1024));
    }

    #[test]
    fn local_file_references_decode_percent_and_escaped_spaces() {
        assert_eq!(
            decode_local_href("/workspace/My%20File\\ name.md"),
            Some("/workspace/My File name.md".into())
        );
        assert_eq!(decode_local_href("/workspace/bad%2"), None);
        assert_eq!(decode_local_href("/workspace/%FF"), None);
    }

    #[test]
    fn same_host_get_without_origin_is_allowed_for_native_api() {
        let request = axum::http::Request::builder()
            .method("GET")
            .header("host", "wonder.example")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(matches_public_origin(&request, "https://wonder.example"));

        let wrong_host = axum::http::Request::builder()
            .method("GET")
            .header("host", "127.0.0.1:3777")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(!matches_public_origin(
            &wrong_host,
            "https://wonder.example"
        ));

        let post = axum::http::Request::builder()
            .method("POST")
            .header("host", "wonder.example")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(!matches_public_origin(&post, "https://wonder.example"));
    }

    #[test]
    fn api_route_auth_policy_keeps_pairing_public_and_everything_else_protected() {
        assert_eq!(route_auth("/healthz"), RouteAuth::Public);
        assert_eq!(route_auth("/"), RouteAuth::Public);
        assert_eq!(route_auth("/pair"), RouteAuth::Public);
        assert_eq!(route_auth("/assets/index.js"), RouteAuth::NotFound);
        assert_eq!(route_auth("/manifest.webmanifest"), RouteAuth::NotFound);
        assert_eq!(
            route_auth("/api/v1/pairing/claim"),
            RouteAuth::PublicPairing
        );
        assert_eq!(route_auth("/api/v1/pairing/code"), RouteAuth::PublicPairing);
        assert_eq!(
            route_auth("/api/v1/pairing/session"),
            RouteAuth::PublicPairing
        );
        assert_eq!(
            route_auth("/api/v1/pairing/session/refresh-challenge"),
            RouteAuth::PublicPairing
        );
        assert_eq!(
            route_auth("/api/v1/conversations/default/messages"),
            RouteAuth::ProtectedApi
        );
        assert_eq!(
            route_auth("/api/v1/conversations/default/turns/turn-1/steer"),
            RouteAuth::ProtectedApi
        );
        assert_eq!(
            route_auth("/api/v1/search?q=launch"),
            RouteAuth::ProtectedApi
        );
        assert_eq!(route_auth("/api/v1/channels"), RouteAuth::ProtectedApi);
        assert_eq!(
            route_auth("/api/v1/channels/channel-1/messages"),
            RouteAuth::ProtectedApi
        );
        assert_eq!(route_auth("/api/v1/devices"), RouteAuth::ProtectedApi);
        assert_eq!(
            route_auth("/api/v1/devices/device-1"),
            RouteAuth::ProtectedApi
        );
    }

    #[test]
    fn public_origin_must_be_https_and_non_loopback() {
        assert!(is_valid_public_origin("https://wonder.example.ts.net"));
        assert!(!is_valid_public_origin("http://wonder.example.ts.net"));
        assert!(!is_valid_public_origin("https://127.0.0.1:3777"));
        assert!(!is_valid_public_origin("https://wonder.invalid"));
        assert!(!is_valid_public_origin("https://wonder.example/path"));
    }

    #[test]
    fn host_readiness_is_degraded_until_public_tunnel_is_available() {
        assert_eq!(host_readiness_state(None), "degraded");
        assert_eq!(
            host_readiness_state(Some("https://wonder.example.ts.net")),
            "ready"
        );
    }

    #[test]
    fn public_origin_status_log_requires_the_newest_status_to_be_ready() {
        assert_eq!(
            public_origin_from_status_log(
                r#"{"state":"ready","origin":"https://wonder.example.ts.net"}
{"state":"stopped"}"#
            ),
            None
        );
        assert_eq!(
            public_origin_from_status_log(
                r#"{"state":"ready","origin":"https://wonder.example.ts.net"}
{"state":"error","error":"funnel unavailable"}
{"state":"ready","origin":"https://wonder.example.ts.net"}"#
            ),
            Some("https://wonder.example.ts.net".into())
        );
    }

    #[tokio::test]
    async fn pairing_offer_response_requires_a_ready_public_origin() {
        let mut pairing = wonder_api::pairing_protocol::PairingState::default();
        let response = pairing_offer_response(None, "test-installation", &mut pairing);
        assert_eq!(
            response.status(),
            axum::http::StatusCode::SERVICE_UNAVAILABLE
        );
        let body = axum::body::to_bytes(response.into_body(), 64 * 1024)
            .await
            .expect("pairing readiness body");
        assert_eq!(&body[..], b"Wonder Funnel is still starting");

        let response = pairing_offer_response(
            Some("https://wonder.example.ts.net".into()),
            "test-installation",
            &mut pairing,
        );
        assert_eq!(response.status(), axum::http::StatusCode::CREATED);
        assert_eq!(
            response
                .headers()
                .get(axum::http::header::CACHE_CONTROL)
                .and_then(|value| value.to_str().ok()),
            Some("no-store")
        );
        let body = axum::body::to_bytes(response.into_body(), 64 * 1024)
            .await
            .expect("pairing offer body");
        let offer: serde_json::Value = serde_json::from_slice(&body).expect("pairing offer JSON");
        assert!(offer["url"]
            .as_str()
            .is_some_and(|url| url.starts_with("https://wonder.example.ts.net/pair#")));
    }

    #[test]
    fn pairing_defaults_to_a_bounded_session() {
        assert_eq!(default_session_expiration(), "1d");
    }

    #[test]
    fn device_labels_are_bounded_and_human_readable() {
        assert!(valid_device_label("Phone"));
        assert!(valid_device_label("  My iPhone  "));
        assert!(!valid_device_label(""));
        assert!(!valid_device_label("\n"));
        assert!(!valid_device_label(&"x".repeat(161)));
    }

    #[test]
    fn channel_descriptions_are_bounded_at_runtime() {
        assert!(valid_channel_description(None));
        assert!(valid_channel_description(Some(&"x".repeat(500))));
        assert!(!valid_channel_description(Some(&"x".repeat(501))));
    }

    #[test]
    fn group_chat_mentions_route_only_to_active_roster_members() {
        let members = vec![
            StoredChannelMember {
                bot_id: "coordinator".into(),
                bot_name: "Product Manager".into(),
                role: "coordinator".into(),
                position: 0,
            },
            StoredChannelMember {
                bot_id: "scout".into(),
                bot_name: "Scout".into(),
                role: "worker".into(),
                position: 1,
            },
        ];
        assert_eq!(bot_handle("Product Manager"), "product-manager");
        assert_eq!(
            resolve_channel_route("Please check this, @Scout!", &members),
            Ok(ChannelRoute::Direct("scout".into()))
        );
        assert_eq!(
            resolve_channel_route("An email like user@example.com is not a mention.", &members),
            Ok(ChannelRoute::Broadcast)
        );
        assert_eq!(
            resolve_channel_route("`@Scout` is example syntax.", &members),
            Ok(ChannelRoute::Broadcast)
        );
        assert!(resolve_channel_route("@Scout @Product-Manager", &members).is_err());
        assert!(resolve_channel_route("@Unknown please help", &members).is_err());

        let ambiguous = [
            members[1].clone(),
            StoredChannelMember {
                bot_id: "scout-2".into(),
                bot_name: "Scout".into(),
                role: "worker".into(),
                position: 2,
            },
        ];
        assert!(resolve_channel_route("@scout", &ambiguous).is_err());
    }

    #[test]
    fn bot_runtime_settings_must_match_catalog() {
        let catalog = RuntimeCatalog {
            models: vec![ModelOption {
                id: "model-a".into(),
                display_name: "Model A".into(),
                description: None,
                model_specialty: None,
                hidden: false,
                reasoning_efforts: vec![ChoiceOption {
                    id: "low".into(),
                    label: "Low".into(),
                    description: None,
                }],
                default_reasoning_effort: Some("low".into()),
                service_tiers: vec![ChoiceOption {
                    id: "fast".into(),
                    label: "Fast".into(),
                    description: None,
                }],
                default_service_tier: Some("fast".into()),
            }],
            ..RuntimeCatalog::default()
        };
        assert!(validate_bot_runtime_settings(
            &catalog,
            Some("model-a"),
            Some("low"),
            Some("fast")
        )
        .is_ok());
        assert!(validate_bot_runtime_settings(
            &catalog,
            Some("model-a"),
            Some("high"),
            Some("fast")
        )
        .is_err());
        assert!(validate_bot_runtime_settings(&catalog, Some("missing"), None, None).is_err());
    }

    #[test]
    fn group_chat_members_require_one_or_more_bots() {
        assert!(!valid_channel_member_count(0));
        assert!(valid_channel_member_count(1));
        assert!(valid_channel_member_count(2));
        assert!(valid_channel_member_count(17));
        assert!(!valid_channel_member_count(18));
    }

    #[test]
    fn app_server_projection_preserves_deltas_and_nested_completion_text() {
        assert_eq!(
            project_app_server_notification(
                "item/agentMessage/delta",
                &serde_json::json!({"delta": {"text": "partial"}}),
                None,
            ),
            Some(wonder_api::WonderEvent::AssistantDelta {
                text: "partial".into()
            })
        );
        assert_eq!(
            project_app_server_notification(
                "item/commandExecution/outputDelta",
                &serde_json::json!({"itemId": "command-1", "delta": "secret output"}),
                None,
            ),
            Some(wonder_api::WonderEvent::Activity {
                category: "command".into(),
                state: "working".into(),
                detail: Some("Output updated".into()),
            })
        );
        assert_eq!(
            project_app_server_notification(
                "item/completed",
                &serde_json::json!({"item": {"content": [{"text": "done"}]}}),
                None,
            ),
            Some(wonder_api::WonderEvent::AssistantCompleted {
                text: "done".into()
            })
        );
        assert_eq!(
            project_app_server_notification(
                "item/completed",
                &serde_json::json!({"item": {"type": "agentMessage", "content": []}}),
                None,
            ),
            Some(wonder_api::WonderEvent::AssistantCompleted {
                text: String::new()
            })
        );
        assert_eq!(
            project_app_server_notification(
                "item/started",
                &serde_json::json!({
                    "item": {"type": "commandExecution", "id": "command-1", "command": "rg hello"}
                }),
                None,
            ),
            Some(wonder_api::WonderEvent::Activity {
                category: "command".into(),
                state: "running".into(),
                detail: Some("rg hello".into()),
            })
        );
        assert_eq!(
            project_app_server_notification(
                "item/completed",
                &serde_json::json!({
                    "item": {"type": "fileChange", "id": "file-1", "changes": [{"path": "src/lib.rs"}]}
                }),
                None,
            ),
            Some(wonder_api::WonderEvent::Activity {
                category: "file change".into(),
                state: "completed".into(),
                detail: Some("src/lib.rs".into()),
            })
        );
        assert_eq!(
            project_app_server_notification(
                "item/commandExecution/outputDelta",
                &serde_json::json!({"delta": "secret output should not be persisted"}),
                None,
            ),
            Some(wonder_api::WonderEvent::Activity {
                category: "command".into(),
                state: "working".into(),
                detail: Some("Output updated".into()),
            })
        );
        assert_eq!(
            project_app_server_notification(
                "item/fileChange/outputDelta",
                &serde_json::json!({"delta": "file tool output"}),
                None,
            ),
            Some(wonder_api::WonderEvent::Activity {
                category: "file change".into(),
                state: "working".into(),
                detail: Some("Output updated".into()),
            })
        );
        assert_eq!(
            project_app_server_notification("turn/completed", &serde_json::json!({}), None,),
            Some(wonder_api::WonderEvent::MessageState {
                state: wonder_api::DeliveryState::Completed,
            })
        );
        assert_eq!(
            project_app_server_notification(
                "future/notification",
                &serde_json::json!({"secret": "redact-me"}),
                None,
            ),
            Some(wonder_api::WonderEvent::Activity {
                category: "App Server".into(),
                state: "unhandled".into(),
                detail: Some("future/notification".into()),
            })
        );
        assert_eq!(
            project_app_server_notification(
                "item/mcpToolCall/progress",
                &serde_json::json!({}),
                None,
            ),
            Some(wonder_api::WonderEvent::Activity {
                category: "MCP tool".into(),
                state: "working".into(),
                detail: None,
            })
        );
    }

    #[test]
    fn item_completion_keeps_explicit_failed_and_interrupted_lifecycle() {
        for (item_type, raw_state, expected) in [
            ("commandExecution", "failed", "failed"),
            ("mcpToolCall", "interrupted", "interrupted"),
        ] {
            let item = serde_json::json!({
                "id": format!("{item_type}-1"),
                "type": item_type,
                "status": raw_state,
            });
            let detail = super::thread_item_upsert_detail_with_authority(
                "turn",
                &item,
                super::app_server_item_lifecycle_state("item/completed", &item),
                2,
                None,
            )
            .expect("item identity");
            let detail: serde_json::Value = serde_json::from_str(&detail).expect("detail JSON");
            assert_eq!(detail["state"], expected);
        }
    }

    #[test]
    fn search_result_deep_links_preserve_kind_and_stable_focus() {
        let message = wonder_store::StoredSearchResult {
            kind: "message".into(),
            id: "message-1".into(),
            title: "Chat".into(),
            snippet: Some("hello".into()),
            conversation_id: Some("conversation-1".into()),
            bot_id: Some("bot-1".into()),
            updated_at: "now".into(),
        };
        assert_eq!(
            search_result_deep_link(&message),
            "#/chats/conversation-1?focus=message-1&kind=message"
        );
        let channel = wonder_store::StoredSearchResult {
            kind: "channel".into(),
            id: "channel-1".into(),
            title: "Team".into(),
            snippet: None,
            conversation_id: Some("conversation-1".into()),
            bot_id: Some("bot-1".into()),
            updated_at: "now".into(),
        };
        assert_eq!(search_result_deep_link(&channel), "#/group-chats/channel-1");
    }

    #[test]
    fn delta_identity_uses_only_authoritative_app_server_sequence() {
        let without_sequence = serde_json::json!({
            "method": "item/agentMessage/delta",
            "params": {"itemId": "item-1", "delta": {"text": "chunk"}}
        });
        assert!(app_server_notification_key(
            "item/agentMessage/delta",
            &without_sequence,
            without_sequence.get("params").expect("params")
        )
        .is_none());

        let with_sequence = serde_json::json!({
            "method": "item/agentMessage/delta",
            "params": {"itemId": "item-1", "sequence": 2, "delta": {"text": "chunk"}}
        });
        assert!(app_server_notification_key(
            "item/agentMessage/delta",
            &with_sequence,
            with_sequence.get("params").expect("params")
        )
        .is_some());

        let patch_updated = serde_json::json!({
            "method": "item/fileChange/patchUpdated",
            "params": {
                "itemId": "file-item-1",
                "changes": [{"path": "report.md", "kind": {"type": "add"}, "diff": "+# report"}]
            }
        });
        let patch_params = patch_updated.get("params").expect("params");
        let patch_key = app_server_notification_key(
            "item/fileChange/patchUpdated",
            &patch_updated,
            patch_params,
        )
        .expect("patch update key");
        let different_patch = serde_json::json!({
            "method": "item/fileChange/patchUpdated",
            "params": {
                "itemId": "file-item-1",
                "changes": [{"path": "report.md", "kind": {"type": "add"}, "diff": "+different"}]
            }
        });
        let different_key = app_server_notification_key(
            "item/fileChange/patchUpdated",
            &different_patch,
            different_patch.get("params").expect("params"),
        )
        .expect("different patch update key");
        assert_ne!(patch_key, different_key);
    }

    #[test]
    fn approval_body_canonicalization_is_ordered_and_json_independent() {
        let request = ApprovalResolution {
            decision: "accept".into(),
            action_nonce: "nonce-1".into(),
            expected_state: "pending".into(),
            idempotency_key: "request-1".into(),
            issued_at_ms: now_ms(),
            signature: "ignored".into(),
            response_json: None,
        };
        assert_eq!(
            canonical_approval_body(&request),
            "[\"accept\",\"nonce-1\",\"pending\",\"request-1\",\"\"]"
        );
    }

    fn resolution(decision: &str, response_json: &str) -> ApprovalResolution {
        ApprovalResolution {
            decision: decision.into(),
            action_nonce: "nonce-1".into(),
            expected_state: "pending".into(),
            idempotency_key: "request-1".into(),
            issued_at_ms: now_ms(),
            signature: "ignored".into(),
            response_json: Some(response_json.into()),
        }
    }

    #[test]
    fn typed_approval_responses_are_validated_before_forwarding() {
        let structured = ApprovalResolution {
            decision: serde_json::json!({"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["*.md"]}}),
            action_nonce: "nonce-1".into(),
            expected_state: "pending".into(),
            idempotency_key: "request-1".into(),
            issued_at_ms: now_ms(),
            signature: "ignored".into(),
            response_json: Some(r#"{"decision":{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["*.md"]}}}"#.into()),
        };
        assert!(build_approval_response(
            "item/commandExecution/requestApproval",
            r#"{"availableDecisions":[{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["*.md"]}}],"threadId":"thread-1","turnId":"turn-1"}"#,
            &structured,
        ).is_ok());

        let permissions = resolution(
            "accept",
            r#"{"permissions":{"fileSystem":{"read":["/tmp/approved"]}},"scope":"turn"}"#,
        );
        assert!(build_approval_response(
            "item/permissions/requestApproval",
            r#"{"permissions":{"fileSystem":{"read":["/tmp/approved"],"write":["/tmp/approved"]}}}"#,
            &permissions,
        )
        .is_ok());

        let overbroad = resolution(
            "accept",
            r#"{"permissions":{"fileSystem":{"write":["/tmp/not-requested"]}},"scope":"turn"}"#,
        );
        assert!(build_approval_response(
            "item/permissions/requestApproval",
            r#"{"permissions":{"fileSystem":{"write":["/tmp/approved"]}}}"#,
            &overbroad,
        )
        .is_err());

        let answers = resolution(
            "submit",
            r#"{"answers":{"question-1":{"answers":["yes"]}}}"#,
        );
        assert!(build_approval_response(
            "item/tool/requestUserInput",
            r#"{"questions":[{"id":"question-1","header":"Confirm","question":"Proceed?"}]}"#,
            &answers,
        )
        .is_ok());

        let elicitation = resolution("accept", r#"{"action":"accept","content":{"ok":true}}"#);
        assert!(build_approval_response(
            "mcpServer/elicitation/request",
            r#"{"serverName":"recorded","threadId":"thread-1"}"#,
            &elicitation,
        )
        .is_ok());
        let mismatched_elicitation = resolution("decline", r#"{"action":"accept"}"#);
        assert!(build_approval_response(
            "mcpServer/elicitation/request",
            r#"{"serverName":"recorded","threadId":"thread-1"}"#,
            &mismatched_elicitation,
        )
        .is_err());
    }

    #[test]
    fn unregistered_dynamic_tools_can_only_be_declined() {
        let response = resolution("respond", r#"{"success":false,"contentItems":[]}"#);
        assert!(build_approval_response(
            "item/tool/call",
            r#"{"tool":"unregistered","callId":"call-1","threadId":"thread-1","turnId":"turn-1"}"#,
            &response,
        )
        .is_ok());
        let success = resolution("respond", r#"{"success":true,"contentItems":[]}"#);
        assert!(build_approval_response(
            "item/tool/call",
            r#"{"tool":"unregistered","callId":"call-1","threadId":"thread-1","turnId":"turn-1"}"#,
            &success,
        )
        .is_err());
        let wrong_decision = resolution("accept", r#"{"success":false,"contentItems":[]}"#);
        assert!(build_approval_response(
            "item/tool/call",
            r#"{"tool":"unregistered","callId":"call-1","threadId":"thread-1","turnId":"turn-1"}"#,
            &wrong_decision,
        )
        .is_err());
    }

    #[test]
    fn recovered_dynamic_tool_resolution_never_reexecutes_the_side_effect() {
        assert!(should_execute_dynamic_tool(false, true));
        assert!(!should_execute_dynamic_tool(true, true));
        assert!(!should_execute_dynamic_tool(true, false));
    }

    #[test]
    fn computer_use_screenshot_event_accepts_only_bounded_png_data_urls() {
        let response = dynamic_tool_response(Ok(serde_json::json!({
            "mimeType": "image/png",
            "imageBase64": "iVBORw0KGgo=",
            "action": "screenshot",
            "observation": {
                "available": true,
                "frontmostApp": "Safari",
                "focusedElement": { "role": "AXButton", "title": "Continue" }
            }
        })));
        assert_eq!(
            computer_use_screenshot_url(&response).as_deref(),
            Some("data:image/png;base64,iVBORw0KGgo=")
        );
        assert_eq!(response["contentItems"].as_array().map(Vec::len), Some(2));
        assert!(response["contentItems"][1]["text"]
            .as_str()
            .is_some_and(|text| text.contains("focusedElement") && text.contains("screenshot")));
        assert!(computer_use_screenshot_url(&serde_json::json!({
            "contentItems": [{"imageUrl": "data:image/jpeg;base64,abc"}]
        }))
        .is_none());
        assert!(computer_use_screenshot_url(&serde_json::json!({
            "contentItems": [{"imageUrl": "https://example.test/screenshot.png"}]
        }))
        .is_none());
    }

    #[tokio::test]
    async fn computer_use_helper_receives_daemon_handshake_and_returns_screenshot() {
        use std::{fs, os::unix::fs::PermissionsExt};

        let directory = tempfile::tempdir().expect("temporary computer-use directory");
        let helper = directory.path().join("fake-computer-use");
        fs::write(
            &helper,
            "#!/bin/sh\nIFS= read -r request\ncase \"$request\" in *handshake*) echo '{\"id\":1,\"result\":{\"mimeType\":\"image/png\",\"imageBase64\":\"iVBORw0KGgo=\"}}' ;; *) echo '{\"id\":1,\"error\":{\"code\":\"missing_handshake\"}}' ;; esac\nIFS= read -r stop\n",
        )
        .expect("fake computer-use helper");
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o755))
            .expect("fake helper permissions");
        let response = run_computer_use(
            &helper,
            &serde_json::json!({
                "tool": "wonder_computer_use",
                "arguments": { "action": "screenshot" }
            }),
        )
        .await
        .expect("computer-use response");
        assert_eq!(response["mimeType"], "image/png");
        assert_eq!(response["imageBase64"], "iVBORw0KGgo=");
    }

    #[tokio::test]
    async fn bot_creation_rollback_removes_durable_profile_home_and_override() {
        let directory = tempfile::tempdir().expect("temporary rollback directory");
        let database_url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("wonder.sqlite3").display()
        );
        let store = wonder_store::Store::connect(&database_url)
            .await
            .expect("store");
        let home = directory.path().join("bot-home");
        tokio::fs::create_dir_all(&home).await.expect("home");
        store
            .upsert_bot(
                "rollback-bot",
                "Rollback Bot",
                "worker",
                "test",
                home.to_str().expect("home path"),
                "wonder_bot_rollback",
                None,
                None,
                "now",
            )
            .await
            .expect("bot");
        let launch_config = Arc::new(tokio::sync::Mutex::new(wonder_app_server::LaunchConfig {
            runtime_home: None,
            codex_bin: directory.path().join("codex"),
            wonder_version: "test".into(),
            permission_overrides: vec!["override".into()],
        }));
        rollback_bot_artifacts(
            &store,
            &launch_config,
            "rollback-bot",
            &home,
            Some("override"),
        )
        .await;
        assert!(store
            .bot("rollback-bot")
            .await
            .expect("bot lookup")
            .is_none());
        assert!(!home.exists());
        assert!(launch_config.lock().await.permission_overrides.is_empty());
    }

    #[test]
    fn reconciliation_matches_only_the_exact_user_client_id() {
        let items = serde_json::json!({
            "data": [
                { "turnId": "turn-other", "item": { "type": "userMessage", "id": "item-1", "clientId": "other" } },
                { "turnId": "turn-target", "item": { "type": "userMessage", "id": "item-2", "clientId": "target" } },
                { "turnId": "turn-agent", "item": { "type": "agentMessage", "id": "item-3", "clientId": "target" } }
            ]
        });
        assert_eq!(
            find_client_message(&items, "target"),
            Some("turn-target".to_owned())
        );
        assert_eq!(find_client_message(&items, "missing"), None);
    }

    #[test]
    fn extracts_assistant_text_from_supported_item_shapes() {
        assert_eq!(
            extract_text(&serde_json::json!({"text": "direct"})),
            Some("direct".into())
        );
        assert_eq!(
            extract_text(&serde_json::json!({
                "content": [
                    {"type": "output_text", "text": "first"},
                    {"type": "output_text", "text": " second"}
                ]
            })),
            Some("first second".into())
        );
        assert_eq!(
            extract_text(&serde_json::json!({"message": {"output": [{"text": "nested"}]}})),
            Some("nested".into())
        );
        assert_eq!(extract_text(&serde_json::json!({"text": ""})), None);
    }

    #[tokio::test]
    async fn workspace_artifacts_require_supported_bytes_and_remain_in_workspace() {
        let directory = tempfile::tempdir().expect("workspace directory");
        let workspace = directory.path().join("bot");
        tokio::fs::create_dir_all(&workspace)
            .await
            .expect("workspace");
        let pdf = b"%PDF-1.7\n%%EOF\n";
        let markdown = b"# A report\n";
        let png = b"\x89PNG\r\n\x1a\nminimal";
        tokio::fs::write(workspace.join("report.pdf"), pdf)
            .await
            .expect("pdf");
        tokio::fs::write(workspace.join("report.md"), markdown)
            .await
            .expect("markdown");
        tokio::fs::write(workspace.join("preview.png"), png)
            .await
            .expect("png");
        tokio::fs::write(workspace.join("not-a-pdf.pdf"), b"plain text")
            .await
            .expect("invalid pdf");

        assert_eq!(
            artifact_mime_type("report.pdf", pdf),
            Some("application/pdf")
        );
        assert_eq!(
            artifact_mime_type("report.md", markdown),
            Some("text/markdown")
        );
        assert_eq!(artifact_mime_type("preview.png", png), Some("image/png"));
        assert_eq!(artifact_mime_type("not-a-pdf.pdf", b"plain text"), None);
        assert_eq!(artifact_mime_type("broken.md", &[0xff]), None);

        let artifact = read_workspace_artifact(
            workspace.to_str().expect("workspace path"),
            "report.md",
            "report.md",
            "artifact-1",
        )
        .await
        .expect("markdown artifact");
        assert_eq!(artifact.id, "artifact-1");
        assert_eq!(artifact.byte_size, markdown.len());
        assert_eq!(artifact.sha256, hex::encode(Sha256::digest(markdown)));
        assert_eq!(artifact.relative_path, "report.md");
        let detail: serde_json::Value =
            serde_json::from_str(&artifact_event_detail(&artifact)).expect("event detail JSON");
        assert_eq!(detail["artifactId"], "artifact-1");
        assert_eq!(detail["mimeType"], "text/markdown");
        assert_eq!(detail["sha256"], hex::encode(Sha256::digest(markdown)));
        let canonical_workspace = tokio::fs::canonicalize(&workspace)
            .await
            .expect("canonical workspace");
        assert!(
            workspace_file_path(workspace.to_str().expect("workspace path"), "report.md")
                .await
                .expect("safe workspace file")
                .starts_with(canonical_workspace)
        );
        assert!(workspace_file_path(
            workspace.to_str().expect("workspace path"),
            "../not-in-workspace.md"
        )
        .await
        .is_none());
    }

    #[tokio::test]
    async fn local_http_send_dispatches_through_fake_app_server_and_reloads_assistant_projection() {
        use axum::{
            body::{to_bytes, Body},
            http::{Method, Request},
        };
        use sha2::Digest;
        use std::{collections::HashMap, fs, os::unix::fs::PermissionsExt, sync::Arc};
        use tokio::{sync::RwLock, time::Duration};
        use tower::ServiceExt;

        let directory = tempfile::tempdir().expect("temporary contract directory");
        let workspace = directory.path().join("bot");
        fs::create_dir_all(&workspace).expect("bot workspace");
        let workspace = fs::canonicalize(workspace).expect("resolved bot workspace");
        let database_url = format!(
            "sqlite://{}?mode=rwc",
            directory.path().join("wonder.sqlite3").display()
        );
        let store = wonder_store::Store::connect(&database_url)
            .await
            .expect("store");
        store
            .upsert_bot(
                "default",
                "Default Bot",
                "General assistant",
                "Help the owner.",
                workspace.to_str().expect("workspace path"),
                "wonder_bot_default",
                Some("fake-model"),
                Some("low"),
                "2026-09-01T10:00:00Z",
            )
            .await
            .expect("bot");
        let custom_workspace = directory.path().join("custom-workspace");
        fs::create_dir_all(&custom_workspace).unwrap();
        let custom_workspace =
            fs::canonicalize(custom_workspace).expect("resolved custom workspace");
        store
            .upsert_bot(
                "custom",
                "Custom Bot",
                "Research",
                "Research carefully.",
                custom_workspace.to_str().expect("workspace path"),
                "wonder_bot_custom",
                None,
                None,
                "2026-09-01T10:01:00Z",
            )
            .await
            .expect("custom bot");
        store
            .upsert_owner_device("device-contract", "contract", "{}", "2026-09-01T10:00:00Z")
            .await
            .expect("device");

        let stable_schema = format!(
            "{}/../../research/codex-app-server/0.155.0-alpha.9/stable/codex_app_server_protocol.v2.schemas.json",
            env!("CARGO_MANIFEST_DIR")
        );
        let experimental_schema = format!(
            "{}/../../research/codex-app-server/0.155.0-alpha.9/experimental/codex_app_server_protocol.v2.schemas.json",
            env!("CARGO_MANIFEST_DIR")
        );
        let server_file = directory.path().join("fake-app-server.py");
        let request_log = directory.path().join("app-server-requests.log");
        let fake_server_source = r#"import json, sys
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialized":
        continue
    if method == "initialize":
        result = {"userAgent": "wonder-contract", "capabilities": {"experimentalApi": True}}
    elif method == "configRequirements/read":
        result = {"requirements": {}}
    elif method == "permissionProfile/list":
        result = {"data": [{"name": "wonder_bot_default", "allowed": True}]}
    elif method == "model/list":
        result = {"data": [{"id": "fake-model", "supportedReasoningEfforts": ["low", "high"]}], "nextCursor": None}
    elif method == "thread/turns/list":
        result = {"data": [], "nextCursor": None}
    elif method == "thread/items/list":
        result = {"data": [], "nextCursor": None}
    elif method == "thread/settings/update":
        with open("__REQUEST_LOG__", "a", encoding="utf-8") as log:
            log.write(method + "\n")
        result = {}
    elif method == "thread/resume":
        with open("__REQUEST_LOG__", "a", encoding="utf-8") as log:
            log.write(method + "\n")
            log.write("resume_developer=" + request.get("params", {}).get("developerInstructions", "") + "\n")
        result = {"thread": {"id": "thread-contract", "sessionId": "session-contract", "status": {"type": "idle"}}}
    elif method == "thread/start":
        result = {"thread": {"id": "thread-contract", "sessionId": "session-contract"}}
    elif method == "turn/start":
        with open("__REQUEST_LOG__", "a", encoding="utf-8") as log:
            params = request.get("params", {})
            log.write(method + "\n")
            log.write("turn_model=" + str(params.get("model")) + "\n")
            log.write("turn_effort=" + str(params.get("effort")) + "\n")
            log.write("turn_service_tier=" + str(params.get("serviceTier")) + "\n")
        result = {"turn": {"id": "turn-contract"}}
        print(json.dumps({"id": request_id, "result": result}), flush=True)
        print(json.dumps({"method": "item/completed", "params": {"threadId": "thread-contract", "turnId": "turn-contract", "item": {"id": "user-contract", "type": "userMessage", "content": [{"text": "say hello"}]}}}), flush=True)
        print(json.dumps({"method": "item/agentMessage/delta", "params": {"threadId": "thread-contract", "turnId": "turn-contract", "item": {"id": "item-contract"}, "sequence": 1, "delta": {"text": "hello "}}}), flush=True)
        print(json.dumps({"method": "item/agentMessage/delta", "params": {"threadId": "thread-contract", "turnId": "turn-contract", "item": {"id": "item-contract"}, "sequence": 2, "delta": {"text": "hello "}}}), flush=True)
        print(json.dumps({"method": "item/agentMessage/delta", "params": {"threadId": "thread-contract", "turnId": "turn-contract", "item": {"id": "item-contract"}, "sequence": 3, "delta": {"text": "world"}}}), flush=True)
        print(json.dumps({"method": "turn/completed", "params": {"threadId": "thread-contract", "turnId": "turn-contract"}}), flush=True)
        print(json.dumps({"method": "item/agentMessage/delta", "params": {"threadId": "thread-contract", "turnId": "turn-contract", "item": {"id": "item-contract"}, "sequence": 4, "delta": {"text": "late delta"}}}), flush=True)
        print(json.dumps({"method": "item/completed", "params": {"threadId": "thread-contract", "turnId": "turn-contract", "item": {"id": "item-contract", "content": [{"text": "late completion must not overwrite"}]}}}), flush=True)
        continue
    else:
        result = {}
    if request_id is not None:
        print(json.dumps({"id": request_id, "result": result}), flush=True)
"#
        .replace("__REQUEST_LOG__", &request_log.to_string_lossy());
        fs::write(&server_file, fake_server_source).expect("fake App Server source");
        // This fake server does not invoke code mode, but models its launch check.
        let helper = directory.path().join("codex-code-mode-host");
        fs::write(
            &helper,
            include_str!("../../../tests/fixtures/code-mode-host.py"),
        )
        .unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();
        let fake_bin = directory.path().join("fake-codex");
        let script = format!(
            "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'codex-cli 0.155.0-alpha.9'; exit 0; fi\nif [ \"$1\" = \"app-server\" ] && [ \"$2\" = \"generate-json-schema\" ]; then last=\"\"; for arg in \"$@\"; do last=\"$arg\"; done; if [ \"$3\" = \"--experimental\" ]; then cp '{}' \"$last/codex_app_server_protocol.v2.schemas.json\"; else cp '{}' \"$last/codex_app_server_protocol.v2.schemas.json\"; fi; exit 0; fi\nif [ \"$1\" = \"app-server\" ]; then exec python3 '{}'; fi\nexit 1\n",
            experimental_schema, stable_schema, server_file.display()
        );
        fs::write(&fake_bin, script).expect("fake Codex executable");
        fs::set_permissions(&fake_bin, fs::Permissions::from_mode(0o755))
            .expect("fake Codex permissions");
        let app_server = wonder_app_server::AppServerClient::spawn_with_notification_sink(
            wonder_app_server::LaunchConfig {
                runtime_home: None,
                codex_bin: fake_bin,
                wonder_version: env!("CARGO_PKG_VERSION").into(),
                permission_overrides: vec![],
            },
            crate::ingestion::notification_sink(store.clone()),
        )
        .await
        .expect("fake App Server");
        let (events, _) = tokio::sync::broadcast::channel(256);
        let (revocations, _) = tokio::sync::broadcast::channel(16);
        let mut permission_profiles = HashMap::new();
        permission_profiles.insert(
            workspace.to_string_lossy().into_owned(),
            vec![PermissionProfileOption {
                id: "wonder_bot_default".into(),
                description: None,
                allowed: true,
            }],
        );
        let logger = Arc::new(
            crate::logging::JsonlLogger::new(directory.path().join("logs"), "wonderd.jsonl")
                .expect("test logger"),
        );
        let tunnel_status_file = directory.path().join("tunnel-status.jsonl");
        fs::write(&tunnel_status_file, r#"{"state":"starting"}"#).expect("starting tunnel status");
        store
            .start_event_epoch("contract-epoch")
            .await
            .expect("sync epoch");
        let state = AppState {
            ingestion: crate::ingestion::Ingestion::default(),
            store,
            logger,
            loopback_capability: "contract-capability".into(),
            host_epoch: "contract-epoch".into(),
            started_at: "2026-09-01T10:00:00Z".into(),
            events,
            revocations,
            pairing: Arc::new(tokio::sync::Mutex::new(
                wonder_api::pairing_protocol::PairingState::default(),
            )),
            public_origin: "https://wonder.test".into(),
            public_origin_file: Some(tunnel_status_file.clone()),
            host_installation_id: "contract-installation".into(),
            app_server: Arc::new(tokio::sync::Mutex::new(app_server)),
            launch_config: Arc::new(tokio::sync::Mutex::new(wonder_app_server::LaunchConfig {
                runtime_home: None,
                codex_bin: directory.path().join("fake-codex"),
                wonder_version: env!("CARGO_PKG_VERSION").into(),
                permission_overrides: vec![],
            })),
            denied_roots: vec![],
            linked_file_roots: vec![directory.path().join("previewable")],
            dispatch_lock: Arc::new(tokio::sync::Mutex::new(())),
            channel_worker_slots: Arc::new(tokio::sync::Semaphore::new(CHANNEL_WORKER_CONCURRENCY)),
            approval_lock: Arc::new(tokio::sync::Mutex::new(())),
            bots_root: directory.path().display().to_string(),
            bot_home: workspace.display().to_string(),
            permission_profile: "wonder_bot_default".into(),
            model: None,
            reasoning_effort: None,
            runtime_catalog: Arc::new(RwLock::new(RuntimeCatalog {
                models: vec![ModelOption {
                    id: "fake-model".into(),
                    display_name: "Fake model".into(),
                    description: None,
                    model_specialty: None,
                    hidden: false,
                    reasoning_efforts: vec![
                        ChoiceOption {
                            id: "low".into(),
                            label: "Low".into(),
                            description: None,
                        },
                        ChoiceOption {
                            id: "high".into(),
                            label: "High".into(),
                            description: None,
                        },
                    ],
                    default_reasoning_effort: Some("low".into()),
                    service_tiers: vec![
                        ChoiceOption {
                            id: "default".into(),
                            label: "Standard".into(),
                            description: None,
                        },
                        ChoiceOption {
                            id: "priority".into(),
                            label: "Fast".into(),
                            description: None,
                        },
                    ],
                    default_service_tier: Some("default".into()),
                }],
                permission_profiles_by_cwd: permission_profiles,
                allowed_approval_policies: vec![],
                allowed_approval_reviewers: vec![],
                allowed_permission_profiles: HashMap::new(),
                approval_policies_restricted: false,
                approval_reviewers_restricted: false,
                permission_profiles_restricted: false,
                auto_review_required_on_models: None,
            })),
            asr_service: Arc::new(crate::asr::AsrService::default()),
            asr_slots: Arc::new(tokio::sync::Semaphore::new(1)),
            asr_rate_limits: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            computer_use_enabled: false,
            computer_use_bin: None,
            computer_supervisor: Arc::new(
                crate::computer_sessions::ComputerSessionSupervisor::default(),
            ),
        };

        let pairing_offer_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/pairing/offers")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("pre-tunnel pairing offer request"),
            )
            .await
            .expect("pre-tunnel pairing offer response");
        assert_eq!(
            pairing_offer_response.status(),
            axum::http::StatusCode::SERVICE_UNAVAILABLE
        );
        let pairing_offer_body = to_bytes(pairing_offer_response.into_body(), 64 * 1024)
            .await
            .expect("pre-tunnel pairing offer body");
        assert_eq!(&pairing_offer_body[..], b"Wonder Funnel is still starting");
        fs::write(
            &tunnel_status_file,
            r#"{"state":"ready","origin":"https://wonder.test"}"#,
        )
        .expect("ready tunnel status");

        let unauthorized_device_list_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/api/v1/devices")
                    .header("origin", "https://wonder.test")
                    .body(Body::empty())
                    .expect("unauthorized device list request"),
            )
            .await
            .expect("unauthorized device list response");
        assert_eq!(
            unauthorized_device_list_response.status(),
            axum::http::StatusCode::UNAUTHORIZED
        );

        let device_list_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/api/v1/devices")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("device list request"),
            )
            .await
            .expect("device list response");
        assert_eq!(device_list_response.status(), axum::http::StatusCode::OK);
        let device_list_body = to_bytes(device_list_response.into_body(), 1_000_000)
            .await
            .expect("device list body");
        let device_list: serde_json::Value =
            serde_json::from_slice(&device_list_body).expect("device list JSON");
        assert!(device_list[0]["createdAt"]
            .as_str()
            .is_some_and(|date| !date.is_empty()));
        assert_eq!(device_list[0]["role"], "owner");
        assert_eq!(device_list[0]["label"], "contract");

        let rename_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::PATCH)
                    .uri("/api/v1/devices/device-contract")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"label":"Phone"}"#))
                    .expect("device rename request"),
            )
            .await
            .expect("device rename response");
        assert_eq!(rename_response.status(), axum::http::StatusCode::OK);
        let rename_body = to_bytes(rename_response.into_body(), 1_000_000)
            .await
            .expect("device rename body");
        let renamed: serde_json::Value =
            serde_json::from_slice(&rename_body).expect("device rename JSON");
        assert_eq!(renamed["label"], "Phone");

        let invalid_rename_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::PATCH)
                    .uri("/api/v1/devices/device-contract")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"label":"\n"}"#))
                    .expect("invalid device rename request"),
            )
            .await
            .expect("invalid device rename response");
        assert_eq!(
            invalid_rename_response.status(),
            axum::http::StatusCode::BAD_REQUEST
        );

        let list_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/api/v1/bots")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("bot list request"),
            )
            .await
            .expect("bot list response");
        assert_eq!(list_response.status(), axum::http::StatusCode::OK);
        let list_body = to_bytes(list_response.into_body(), 1_000_000)
            .await
            .expect("bot list body");
        let listed: serde_json::Value = serde_json::from_slice(&list_body).expect("bot list JSON");
        assert_eq!(listed.as_array().expect("bot list array").len(), 2);

        let get_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/api/v1/bots/custom")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("bot get request"),
            )
            .await
            .expect("bot get response");
        assert_eq!(get_response.status(), axum::http::StatusCode::OK);
        let get_body = to_bytes(get_response.into_body(), 1_000_000)
            .await
            .expect("bot get body");
        let fetched: serde_json::Value = serde_json::from_slice(&get_body).expect("bot get JSON");
        assert_eq!(fetched["name"], "Custom Bot");

        let legacy_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/bots/default/archive")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("legacy bot request"),
            )
            .await
            .expect("legacy bot response");
        assert_eq!(legacy_response.status(), axum::http::StatusCode::OK);
        state
            .store
            .archive_bot_safely("default", false)
            .await
            .unwrap();

        let update_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::PATCH)
                    .uri("/api/v1/bots/custom")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        r#"{"name":"Updated Bot","role":"Writer","systemPrompt":"Write clearly."}"#,
                    ))
                    .expect("bot update request"),
            )
            .await
            .expect("bot update response");
        assert_eq!(update_response.status(), axum::http::StatusCode::OK);

        let archive_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/bots/custom/archive")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("bot archive request"),
            )
            .await
            .expect("bot archive response");
        assert_eq!(archive_response.status(), axum::http::StatusCode::OK);
        let archive_body = to_bytes(archive_response.into_body(), 1_000_000)
            .await
            .expect("bot archive body");
        let archived: serde_json::Value =
            serde_json::from_slice(&archive_body).expect("archive JSON");
        assert_eq!(archived["isArchived"], true);

        let unarchive_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/bots/custom/unarchive")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("bot unarchive request"),
            )
            .await
            .expect("bot unarchive response");
        assert_eq!(unarchive_response.status(), axum::http::StatusCode::OK);

        let delete_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::DELETE)
                    .uri("/api/v1/bots/custom")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("bot delete request"),
            )
            .await
            .expect("bot delete response");
        assert_eq!(delete_response.status(), axum::http::StatusCode::CONFLICT);
        assert_eq!(
            crate::bot_management::archive(&state, "custom", true)
                .await
                .status(),
            axum::http::StatusCode::OK
        );
        let deleted = crate::bot_management::delete(&state, "custom").await;
        let status = deleted.status();
        let detail = to_bytes(deleted.into_body(), 10000).await.unwrap();
        assert_eq!(
            status,
            axum::http::StatusCode::NO_CONTENT,
            "{}",
            String::from_utf8_lossy(&detail)
        );

        let guard_message = match state
            .store
            .insert_message(
                "device-contract",
                "00000000-0000-4000-8000-000000000099",
                "active turn",
                &hex::encode(sha2::Sha256::digest(b"active turn")),
                "default",
                "2026-09-01T10:02:00Z",
            )
            .await
            .expect("guard message")
        {
            wonder_store::MessageInsert::Inserted(message) => message,
            _ => panic!("expected guard message to be inserted"),
        };
        state
            .store
            .update_message_delivery(
                &guard_message.id,
                "accepted_by_codex",
                Some("thread-contract"),
                Some("turn-guard"),
            )
            .await
            .expect("active guard turn");
        let blocked_bot_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/bots")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "name": "Blocked Bot",
                            "role": "Writer",
                            "systemPrompt": "Write clearly."
                        })
                        .to_string(),
                    ))
                    .expect("blocked bot request"),
            )
            .await
            .expect("blocked bot response");
        assert_eq!(
            blocked_bot_response.status(),
            axum::http::StatusCode::CONFLICT
        );
        assert_eq!(state.store.list_bots().await.expect("bots").len(), 1);
        state
            .store
            .update_message_delivery(&guard_message.id, "completed", None, None)
            .await
            .expect("complete guard turn");

        state
            .store
            .create_conversation(
                "pending-conversation",
                "default",
                "Pending conversation",
                "2026-09-01T10:02:30Z",
            )
            .await
            .expect("pending conversation");
        let pending_message = match state
            .store
            .insert_message(
                "device-contract",
                "00000000-0000-4000-8000-000000000098",
                "pending body",
                &hex::encode(sha2::Sha256::digest(b"pending body")),
                "pending-conversation",
                "2026-09-01T10:02:31Z",
            )
            .await
            .expect("pending message")
        {
            wonder_store::MessageInsert::Inserted(message) => message,
            _ => panic!("expected pending message to be inserted"),
        };
        publish_app_server_notification(
            &state,
            serde_json::json!({
                "method": "item/agentMessage/delta",
                "params": {
                    "threadId": "thread-contract",
                    "turnId": "turn-pending",
                    "item": { "id": "item-pending" },
                    "delta": { "text": "early" }
                }
            }),
        )
        .await;
        assert_eq!(
            state
                .store
                .pending_app_server_notifications_for_turn("turn-pending")
                .await
                .expect("pending notifications")
                .len(),
            1
        );
        state
            .store
            .update_message_delivery(
                &pending_message.id,
                "accepted_by_codex",
                Some("thread-contract"),
                Some("turn-pending"),
            )
            .await
            .expect("map pending turn");
        drain_pending_app_server_notifications(&state, "thread-contract", "turn-pending").await;
        assert_eq!(
            state
                .store
                .assistant_messages_for_conversation("pending-conversation")
                .await
                .expect("drained assistant")
                .first()
                .expect("drained message")
                .text,
            "early"
        );
        assert!(state
            .store
            .pending_app_server_notifications_for_turn("turn-pending")
            .await
            .expect("drained notifications")
            .is_empty());

        let mut emitted_events = state.events.subscribe();
        let notification_service = crate::ingestion::spawn(state.clone()).await;
        let dispatcher = crate::dispatch::spawn(state.clone()).await.unwrap();
        for _ in 0..100 {
            if state.ingestion.readiness(&state.store).await.ready {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let client_message_id = "00000000-0000-4000-8000-000000000001";
        let starts_before_send = fs::read_to_string(&request_log)
            .unwrap_or_default()
            .lines()
            .filter(|method| *method == "turn/start")
            .count();
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/conversations/default/messages")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "deviceId": "device-contract",
                            "clientMessageId": client_message_id,
                            "body": "say hello"
                        })
                        .to_string(),
                    ))
                    .expect("send request"),
            )
            .await
            .expect("send response");
        if response.status() != axum::http::StatusCode::ACCEPTED {
            let status = response.status();
            let body = to_bytes(response.into_body(), 1_000_000)
                .await
                .expect("error body");
            panic!("send failed: {status}: {}", String::from_utf8_lossy(&body));
        }
        // Native response-loss recovery and double taps reuse the exact request.
        // Discard the first receipt, then race two duplicates with dispatch.
        drop(response);
        for _ in 0..2 {
            let duplicate = router(state.clone())
                .oneshot(
                    Request::builder()
                        .method(Method::POST)
                        .uri("/api/v1/conversations/default/messages")
                        .header("x-wonder-loopback-capability", "contract-capability")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            serde_json::json!({
                                "deviceId": "device-contract",
                                "clientMessageId": client_message_id,
                                "body": "say hello",
                                "attachmentIds": []
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(duplicate.status(), axum::http::StatusCode::ACCEPTED);
            let bytes = to_bytes(duplicate.into_body(), 1_000_000).await.unwrap();
            let receipt: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            let stored = state
                .store
                .message_by_device_and_client_message_id("device-contract", client_message_id)
                .await
                .unwrap()
                .unwrap();
            assert_eq!(receipt["wonderMessageId"], stored.id);
            assert_eq!(receipt["clientMessageId"], client_message_id);
        }
        for _ in 0..300 {
            if state
                .store
                .assistant_messages_for_conversation("default")
                .await
                .expect("assistant lookup")
                .iter()
                .any(|message| message.state == "completed")
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let mut assistant_deltas = Vec::new();
        let mut assistant_completions = Vec::new();
        let assistant_completion_context = loop {
            let event = tokio::time::timeout(Duration::from_secs(2), emitted_events.recv())
                .await
                .expect("completion broadcast")
                .expect("event");
            match &event.event {
                wonder_api::WonderEvent::AssistantDelta { text } => {
                    assistant_deltas.push(text.clone())
                }
                wonder_api::WonderEvent::AssistantCompleted { text } => {
                    assistant_completions.push(text.clone());
                    break event;
                }
                _ => {}
            }
        };
        assert_eq!(assistant_deltas, vec!["hello ", "hello ", "world"]);
        assert_eq!(assistant_completions, vec!["hello hello world"]);
        assert_eq!(
            fs::read_to_string(&request_log)
                .unwrap()
                .lines()
                .filter(|method| *method == "turn/start")
                .count(),
            starts_before_send + 1,
            "duplicate native sends must dispatch exactly once"
        );
        assert_eq!(
            assistant_completion_context.conversation_id.as_deref(),
            Some("default")
        );
        assert_eq!(
            assistant_completion_context.thread_id.as_deref(),
            Some("thread-contract")
        );
        assert_eq!(
            assistant_completion_context.turn_id.as_deref(),
            Some("turn-contract")
        );
        assert_eq!(
            assistant_completion_context.item_id.as_deref(),
            Some("item-contract")
        );
        let sent_message = state
            .store
            .message_by_device_and_client_message_id("device-contract", client_message_id)
            .await
            .expect("sent message lookup")
            .expect("sent message");
        assert_eq!(
            assistant_completion_context.message_id.as_deref(),
            Some(sent_message.id.as_str())
        );
        state
            .store
            .create_conversation(
                "resumed-conversation",
                "default",
                "Resumed conversation",
                "2026-09-01T10:02:45Z",
            )
            .await
            .expect("resumed conversation");
        state
            .store
            .set_conversation_thread(
                "resumed-conversation",
                "thread-contract",
                Some("session-contract"),
                "2026-09-01T10:02:45Z",
            )
            .await
            .expect("persisted thread");
        let settings_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::PATCH)
                    .uri("/api/v1/conversations/resumed-conversation/settings")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "model": "fake-model",
                            "effort": "high",
                            "serviceTier": "priority"
                        })
                        .to_string(),
                    ))
                    .expect("settings request"),
            )
            .await
            .expect("settings response");
        assert_eq!(settings_response.status(), axum::http::StatusCode::OK);
        let settings_body = to_bytes(settings_response.into_body(), 1_000_000)
            .await
            .expect("settings response body");
        let settings_json: serde_json::Value =
            serde_json::from_slice(&settings_body).expect("settings response json");
        assert_eq!(settings_json["effective"]["model"], "fake-model");
        assert_eq!(settings_json["effective"]["effort"], "high");
        assert_eq!(settings_json["effective"]["serviceTier"], "priority");
        let saved_settings = state
            .store
            .conversation_settings("resumed-conversation")
            .await
            .expect("saved resumed settings")
            .expect("resumed settings row");
        assert_eq!(saved_settings.reasoning_effort.as_deref(), Some("high"));
        assert_eq!(saved_settings.service_tier.as_deref(), Some("priority"));
        assert!(
            !fs::read_to_string(&request_log)
                .unwrap_or_default()
                .lines()
                .any(|method| method == "thread/settings/update"),
            "saving composer settings must not mutate the current App Server thread"
        );
        let resumed_client_message_id = "00000000-0000-4000-8000-000000000003";
        let resumed_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/conversations/resumed-conversation/messages")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "deviceId": "device-contract",
                            "clientMessageId": resumed_client_message_id,
                            "body": "resume hello"
                        })
                        .to_string(),
                    ))
                    .expect("resumed send request"),
            )
            .await
            .expect("resumed send response");
        let resumed_status = resumed_response.status();
        let resumed_body = to_bytes(resumed_response.into_body(), 1_000_000)
            .await
            .unwrap();
        assert_eq!(
            resumed_status,
            axum::http::StatusCode::ACCEPTED,
            "{}",
            String::from_utf8_lossy(&resumed_body)
        );
        let resumed_message = state
            .store
            .message_by_device_and_client_message_id("device-contract", resumed_client_message_id)
            .await
            .expect("resumed message lookup")
            .expect("resumed message");
        let current_bot = state.store.bot("default").await.unwrap().unwrap();
        let (accepted_bot, has_accepted_settings) = state
            .store
            .message_execution_bot(&resumed_message.id, current_bot)
            .await
            .expect("accepted settings snapshot");
        assert!(has_accepted_settings);
        assert_eq!(accepted_bot.reasoning_effort.as_deref(), Some("high"));
        assert_eq!(accepted_bot.service_tier.as_deref(), Some("priority"));
        for _ in 0..300 {
            if state
                .store
                .assistant_messages_for_conversation("resumed-conversation")
                .await
                .expect("resumed assistant lookup")
                .iter()
                .any(|message| message.state == "completed")
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let resumed_after_dispatch = state
            .store
            .message_by_id(&resumed_message.id)
            .await
            .expect("resumed message after dispatch lookup")
            .expect("resumed message after dispatch");
        assert_eq!(
            resumed_after_dispatch.state,
            "accepted_by_codex",
            "request log:\n{}\ndaemon log:\n{}",
            fs::read_to_string(&request_log).unwrap_or_default(),
            fs::read_to_string(directory.path().join("logs/wonderd.jsonl")).unwrap_or_default()
        );
        assert!(fs::read_to_string(&request_log)
            .expect("App Server request log")
            .lines()
            .any(|method| method == "thread/resume"));
        assert!(fs::read_to_string(&request_log)
            .expect("App Server request log")
            .lines()
            .any(|line| line.starts_with("resume_developer=Wonder conversation policy:")));
        assert!(fs::read_to_string(&request_log)
            .unwrap()
            .contains("Help the owner."));
        let app_server_requests =
            fs::read_to_string(&request_log).expect("App Server request log after resumed send");
        assert!(app_server_requests
            .lines()
            .any(|line| line == "turn_model=fake-model"));
        assert!(
            app_server_requests
                .lines()
                .any(|line| line == "turn_effort=high"),
            "{app_server_requests}"
        );
        assert!(app_server_requests
            .lines()
            .any(|line| line == "turn_service_tier=priority"));
        state
            .store
            .create_conversation(
                "other-conversation",
                "default",
                "Other conversation",
                "2026-09-01T10:03:00Z",
            )
            .await
            .expect("other conversation");
        let wrong_send_route = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/conversations/other-conversation/messages")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "deviceId": "device-contract",
                            "clientMessageId": client_message_id,
                            "body": "say hello"
                        })
                        .to_string(),
                    ))
                    .expect("wrong send route request"),
            )
            .await
            .expect("wrong send route response");
        assert_eq!(wrong_send_route.status(), axum::http::StatusCode::CONFLICT);
        let wrong_steer_route = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/conversations/other-conversation/turns/turn-contract/steer")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "deviceId": "device-contract",
                            "clientMessageId": client_message_id,
                            "expectedTurnId": "turn-contract",
                            "body": "say hello"
                        })
                        .to_string(),
                    ))
                    .expect("wrong steer route request"),
            )
            .await
            .expect("wrong steer route response");
        assert_eq!(wrong_steer_route.status(), axum::http::StatusCode::CONFLICT);
        let steered_client_message_id = "00000000-0000-4000-8000-000000000002";
        let steered_body = "continue after completion";
        let steered_hash = hex::encode(sha2::Sha256::digest(steered_body.as_bytes()));
        let steered_message = match state
            .store
            .insert_guide_message(
                "device-contract",
                steered_client_message_id,
                steered_body,
                &steered_hash,
                "default",
                &[],
                "2026-09-01T10:01:00Z",
                "turn-contract",
            )
            .await
            .expect("steered message")
        {
            wonder_store::MessageInsert::Inserted(message) => message,
            _ => panic!("expected steered message to be inserted"),
        };
        state
            .store
            .update_message_delivery(
                &steered_message.id,
                "completed",
                Some("thread-contract"),
                Some("turn-contract"),
            )
            .await
            .expect("complete steered message");
        let replay_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/conversations/default/turns/turn-contract/steer")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "deviceId": "device-contract",
                            "clientMessageId": steered_client_message_id,
                            "expectedTurnId": "turn-contract",
                            "body": steered_body
                        })
                        .to_string(),
                    ))
                    .expect("replay request"),
            )
            .await
            .expect("replay response");
        assert_eq!(replay_response.status(), axum::http::StatusCode::ACCEPTED);
        let replay_body = to_bytes(replay_response.into_body(), 1_000_000)
            .await
            .expect("replay body");
        let replay: serde_json::Value = serde_json::from_slice(&replay_body).expect("replay JSON");
        validate_http_contract("messageReceipt", &replay);
        assert_eq!(replay["deliveryState"], "completed");
        assert_eq!(replay["codexTurnId"], "turn-contract");
        let snapshot_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/api/v1/conversations/default")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("snapshot request"),
            )
            .await
            .expect("snapshot response");
        let unsupported_write = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::PUT)
                    .uri("/api/v1/conversations/default")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            unsupported_write.status(),
            axum::http::StatusCode::METHOD_NOT_ALLOWED
        );
        assert_eq!(snapshot_response.status(), axum::http::StatusCode::OK);
        let snapshot_body = to_bytes(snapshot_response.into_body(), 1_000_000)
            .await
            .expect("snapshot body");
        let snapshot: serde_json::Value =
            serde_json::from_slice(&snapshot_body).expect("snapshot JSON");
        validate_http_contract("conversationSnapshot", &snapshot);
        let websocket_schema: serde_json::Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/schemas/wonder-websocket-v1.json"
        ))
        .expect("WebSocket schema JSON");
        let validator = jsonschema::validator_for(&websocket_schema).expect("WebSocket schema");
        // Snapshot events contain canonical typed activities, not replay deltas.
        for event in snapshot["events"].as_array().expect("snapshot events") {
            assert!(
                validator.is_valid(event),
                "invalid WebSocket event: {event}"
            );
        }
        let mut missing_thread = snapshot.clone();
        missing_thread.as_object_mut().unwrap().remove("thread");
        let authority: serde_json::Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/schemas/wonder-http-v1.json"
        ))
        .unwrap();
        let validator = jsonschema::validator_for(&serde_json::json!({
            "$ref": "#/$defs/conversationSnapshot", "$defs": authority["$defs"]
        }))
        .unwrap();
        assert!(!validator.is_valid(&missing_thread));
        if let Ok(output) = std::env::var("WONDER_CONTRACT_FIXTURE_DIR") {
            let output = std::path::Path::new(&output);
            fs::create_dir_all(output).expect("fixture directory");
            for (name, value) in [
                ("conversation-snapshot", &snapshot),
                ("message-receipt", &replay),
            ] {
                fs::write(
                    output.join(format!("{name}.json")),
                    serde_json::to_vec_pretty(value).unwrap(),
                )
                .expect("write synthetic response fixture");
            }
        }
        assert_eq!(
            snapshot["assistantMessages"][0]["text"],
            "hello hello world"
        );
        assert_eq!(snapshot["assistantMessages"][0]["state"], "completed");
        assert_eq!(
            snapshot["assistantMessages"]
                .as_array()
                .expect("assistant messages")
                .len(),
            1
        );

        let upload_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/conversations/default/files")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "name": "notes.txt",
                            "mimeType": "text/plain",
                            "contentBase64": base64::engine::general_purpose::STANDARD.encode(b"hello")
                        })
                        .to_string(),
                    ))
                    .expect("attachment upload request"),
            )
            .await
            .expect("attachment upload response");
        assert_eq!(upload_response.status(), axum::http::StatusCode::OK);
        let upload_body = to_bytes(upload_response.into_body(), 1_000_000)
            .await
            .expect("attachment metadata body");
        let uploaded: serde_json::Value =
            serde_json::from_slice(&upload_body).expect("attachment metadata JSON");
        let uploaded_id = uploaded["id"].as_str().expect("attachment UUID");
        assert!(uuid::Uuid::parse_str(uploaded_id).is_ok());
        assert_eq!(
            uploaded["relativePath"],
            format!(".wonder/attachments/{uploaded_id}")
        );
        assert_eq!(uploaded["byteSize"], 5);
        assert_eq!(uploaded["sha256"], hex::encode(Sha256::digest(b"hello")));
        let workspace_root = tokio::fs::canonicalize(&workspace)
            .await
            .expect("canonical workspace");
        assert_eq!(
            tokio::fs::read(workspace_root.join(".wonder/attachments").join(uploaded_id))
                .await
                .expect("stored attachment"),
            b"hello"
        );

        let download_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri(format!("/api/v1/conversations/default/files/{uploaded_id}"))
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("attachment download request"),
            )
            .await
            .expect("attachment download response");
        assert_eq!(download_response.status(), axum::http::StatusCode::OK);
        assert_eq!(
            download_response
                .headers()
                .get("content-type")
                .and_then(|value| value.to_str().ok()),
            Some("text/plain")
        );
        assert_eq!(
            to_bytes(download_response.into_body(), 1_000_000)
                .await
                .expect("download body"),
            b"hello".as_slice()
        );

        let artifact_path = workspace.join("report.md");
        fs::write(&artifact_path, b"# Bot report\n").expect("workspace artifact");

        // Exercise the authenticated resolver through the real HTTP router,
        // including every path form accepted by clients and the important
        // containment, type, and size failures.
        let spaced_pdf_path = workspace.join("Report Final.pdf");
        fs::write(&spaced_pdf_path, b"%PDF-1.7\n%%EOF\n").expect("workspace PDF");
        let previewable_root = directory.path().join("previewable");
        fs::create_dir_all(&previewable_root).expect("previewable root");
        let linked_resume_path = previewable_root.join("Saimun Resume.pdf");
        fs::write(&linked_resume_path, b"%PDF-1.7\nlinked resume\n%%EOF\n")
            .expect("linked resume PDF");
        let outside_path = directory.path().join("outside.md");
        fs::write(&outside_path, b"# outside\n").expect("outside file");
        let unsupported_path = workspace.join("archive.bin");
        fs::write(&unsupported_path, b"unsupported").expect("unsupported file");
        let oversized_path = workspace.join("oversized.pdf");
        fs::File::create(&oversized_path)
            .expect("oversized file")
            .set_len((MAX_WORKSPACE_ARTIFACT_BYTES + 1) as u64)
            .expect("oversized length");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside_path, workspace.join("escape.md"))
            .expect("outside symlink");

        let encoded_absolute = spaced_pdf_path.to_string_lossy().replace(' ', "%20");
        let allowed_references = vec![
            "report.md".to_owned(),
            "Report\\ Final.pdf".to_owned(),
            "Report%20Final.pdf".to_owned(),
            encoded_absolute.clone(),
            format!("file://localhost{encoded_absolute}"),
        ];
        for href in allowed_references {
            let response = router(state.clone())
                .oneshot(
                    Request::builder()
                        .method(Method::POST)
                        .uri("/api/v1/conversations/resumed-conversation/files/resolve")
                        .header("x-wonder-loopback-capability", "contract-capability")
                        .header("content-type", "application/json")
                        .body(Body::from(serde_json::json!({ "href": href }).to_string()))
                        .expect("file resolve request"),
                )
                .await
                .expect("file resolve response");
            assert_eq!(response.status(), axum::http::StatusCode::OK);
            let body = to_bytes(response.into_body(), 1_000_000)
                .await
                .expect("file resolve body");
            let resolved: serde_json::Value =
                serde_json::from_slice(&body).expect("file resolve JSON");
            assert_eq!(resolved["state"], "available");
            assert!(resolved["relativePath"].as_str().is_some());
        }

        let linked_resume_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/conversations/resumed-conversation/files/resolve")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "href": linked_resume_path.to_string_lossy().replace(' ', "%20")
                        })
                        .to_string(),
                    ))
                    .expect("linked resume resolve request"),
            )
            .await
            .expect("linked resume resolve response");
        assert_eq!(linked_resume_response.status(), axum::http::StatusCode::OK);
        let linked_resume_body = to_bytes(linked_resume_response.into_body(), 1_000_000)
            .await
            .expect("linked resume body");
        let linked_resume: serde_json::Value =
            serde_json::from_slice(&linked_resume_body).expect("linked resume JSON");
        assert_eq!(linked_resume["name"], "Saimun Resume.pdf");
        let linked_relative_path = linked_resume["relativePath"]
            .as_str()
            .expect("linked resume relative path");
        assert!(linked_relative_path.starts_with(".wonder/linked-files/"));
        assert_eq!(
            tokio::fs::read(workspace.join(linked_relative_path))
                .await
                .expect("imported linked resume"),
            b"%PDF-1.7\nlinked resume\n%%EOF\n"
        );

        let denied_references = vec![
            ("missing.pdf".to_owned(), axum::http::StatusCode::NOT_FOUND),
            (
                outside_path.to_string_lossy().into_owned(),
                axum::http::StatusCode::FORBIDDEN,
            ),
            (
                "https://example.test/report.pdf".to_owned(),
                axum::http::StatusCode::FORBIDDEN,
            ),
            (
                "archive.bin".to_owned(),
                axum::http::StatusCode::UNSUPPORTED_MEDIA_TYPE,
            ),
            (
                "oversized.pdf".to_owned(),
                axum::http::StatusCode::PAYLOAD_TOO_LARGE,
            ),
            #[cfg(unix)]
            ("escape.md".to_owned(), axum::http::StatusCode::FORBIDDEN),
        ];
        for (href, expected) in denied_references {
            let response = router(state.clone())
                .oneshot(
                    Request::builder()
                        .method(Method::POST)
                        .uri("/api/v1/conversations/resumed-conversation/files/resolve")
                        .header("x-wonder-loopback-capability", "contract-capability")
                        .header("content-type", "application/json")
                        .body(Body::from(serde_json::json!({ "href": href }).to_string()))
                        .expect("denied file resolve request"),
                )
                .await
                .expect("denied file resolve response");
            assert_eq!(response.status(), expected);
        }

        let unauthenticated_resolve = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/conversations/resumed-conversation/files/resolve")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"href":"report.md"}"#))
                    .expect("unauthenticated resolve request"),
            )
            .await
            .expect("unauthenticated resolve response");
        assert_eq!(
            unauthenticated_resolve.status(),
            axum::http::StatusCode::FORBIDDEN
        );

        let artifact_message = match state
            .store
            .insert_message(
                "device-contract",
                "00000000-0000-4000-8000-000000000004",
                "artifact turn",
                &hex::encode(Sha256::digest(b"artifact turn")),
                "default",
                "2026-09-01T10:03:30Z",
            )
            .await
            .expect("artifact message")
        {
            wonder_store::MessageInsert::Inserted(message) => message,
            _ => panic!("expected artifact message to be inserted"),
        };
        state
            .store
            .update_message_delivery(
                &artifact_message.id,
                "accepted_by_codex",
                Some("thread-contract"),
                Some("turn-artifact"),
            )
            .await
            .expect("artifact turn mapping");
        publish_app_server_notification(
            &state,
            serde_json::json!({
                "method": "item/fileChange/patchUpdated",
                "params": {
                    "threadId": "thread-contract",
                    "turnId": "turn-artifact",
                    "itemId": "item-artifact",
                    "changes": [{
                        "path": artifact_path.to_string_lossy(),
                        "kind": {"type": "add"},
                        "diff": "+# Bot report"
                    }]
                }
            }),
        )
        .await;
        let artifact_list_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/api/v1/conversations/default/files")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("artifact list request"),
            )
            .await
            .expect("artifact list response");
        assert_eq!(artifact_list_response.status(), axum::http::StatusCode::OK);
        let artifact_list_body = to_bytes(artifact_list_response.into_body(), 1_000_000)
            .await
            .expect("artifact list body");
        let artifact_list: serde_json::Value =
            serde_json::from_slice(&artifact_list_body).expect("artifact list JSON");
        let artifact = artifact_list
            .as_array()
            .expect("artifact list array")
            .iter()
            .find(|file| file["kind"] == "artifact")
            .expect("artifact metadata");
        let artifact_id = artifact["id"].as_str().expect("artifact id");
        assert_eq!(artifact["name"], "report.md");
        assert_eq!(artifact["mimeType"], "text/markdown");
        assert_eq!(artifact["byteSize"], 13);
        assert_eq!(
            artifact["sha256"],
            hex::encode(Sha256::digest(b"# Bot report\n"))
        );
        let artifact_download = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri(format!("/api/v1/conversations/default/files/{artifact_id}"))
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("artifact download request"),
            )
            .await
            .expect("artifact download response");
        assert_eq!(artifact_download.status(), axum::http::StatusCode::OK);
        assert_eq!(
            to_bytes(artifact_download.into_body(), 1_000_000)
                .await
                .expect("artifact download body"),
            b"# Bot report\n".as_slice()
        );
        fs::write(&artifact_path, b"tampered\n").expect("tamper artifact");
        let tampered_download = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri(format!("/api/v1/conversations/default/files/{artifact_id}"))
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("tampered artifact request"),
            )
            .await
            .expect("tampered artifact response");
        assert_eq!(
            tampered_download.status(),
            axum::http::StatusCode::INTERNAL_SERVER_ERROR
        );
        let artifact_event = loop {
            match emitted_events.try_recv() {
                Ok(event)
                    if matches!(
                        &event.event,
                        wonder_api::WonderEvent::Activity { category, .. } if category == "artifact"
                    ) =>
                {
                    break event
                }
                Ok(_) => continue,
                Err(error) => panic!("artifact event: {error:?}"),
            }
        };
        let artifact_event_detail = match artifact_event.event {
            wonder_api::WonderEvent::Activity { detail, .. } => detail.expect("detail"),
            _ => unreachable!(),
        };
        let artifact_event_detail: serde_json::Value =
            serde_json::from_str(&artifact_event_detail).expect("artifact event detail");
        assert_eq!(artifact_event_detail["artifactId"], artifact_id);
        assert_eq!(artifact_event_detail["relativePath"], "report.md");

        let wrong_conversation_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri(format!("/api/v1/conversations/custom/files/{uploaded_id}"))
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .body(Body::empty())
                    .expect("wrong conversation download request"),
            )
            .await
            .expect("wrong conversation response");
        assert_eq!(
            wrong_conversation_response.status(),
            axum::http::StatusCode::NOT_FOUND
        );

        // A phone may lose an upload receipt. Reusing its identity must return
        // the same file, while changed bytes or metadata must never overwrite it.
        let mut upload_id = None;
        for name in ["retry.txt", "retry.txt", "changed.txt"] {
            let response = router(state.clone()).oneshot(
                Request::builder().method(Method::POST)
                    .uri("/api/v1/conversations/default/files")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::json!({
                        "clientUploadId":"00000000-0000-4000-8000-000000000099",
                        "name":name,"mimeType":"text/plain",
                        "contentBase64":base64::engine::general_purpose::STANDARD.encode(b"retained bytes")
                    }).to_string())).unwrap()
            ).await.unwrap();
            if name == "changed.txt" {
                assert_eq!(response.status(), axum::http::StatusCode::CONFLICT);
            } else {
                assert!(response.status().is_success());
                let data = to_bytes(response.into_body(), 65536).await.unwrap();
                let value: serde_json::Value = serde_json::from_slice(&data).unwrap();
                if let Some(ref id) = upload_id {
                    assert_eq!(id, &value["id"]);
                }
                upload_id = Some(value["id"].clone());
            }
        }

        for (name, mime_type) in [
            ("../secret.txt", "text/plain"),
            ("notes.txt", "text/plain; charset=utf-8"),
        ] {
            let rejected = router(state.clone())
                .oneshot(
                    Request::builder()
                        .method(Method::POST)
                        .uri("/api/v1/conversations/default/files")
                        .header("x-wonder-loopback-capability", "contract-capability")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            serde_json::json!({
                                "name": name,
                                "mimeType": mime_type,
                                "contentBase64": base64::engine::general_purpose::STANDARD.encode(b"hello")
                            })
                            .to_string(),
                        ))
                        .expect("rejected attachment request"),
                )
                .await
                .expect("rejected attachment response");
            assert_eq!(rejected.status(), axum::http::StatusCode::BAD_REQUEST);
        }

        let oversized = vec![0u8; MAX_ATTACHMENT_BYTES + 1];
        let oversized_response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/v1/conversations/default/files")
                    .header("x-wonder-loopback-capability", "contract-capability")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "name": "large.bin",
                            "mimeType": "application/octet-stream",
                            "contentBase64": base64::engine::general_purpose::STANDARD.encode(oversized)
                        })
                        .to_string(),
                    ))
                    .expect("oversized attachment request"),
            )
            .await
            .expect("oversized attachment response");
        assert_eq!(
            oversized_response.status(),
            axum::http::StatusCode::PAYLOAD_TOO_LARGE
        );

        dispatcher.abort();
        let _ = dispatcher.await;
        drop(notification_service);
        state
            .app_server
            .lock()
            .await
            .shutdown()
            .await
            .expect("shutdown");
    }

    #[test]
    fn steer_params_preserve_the_protocol_contract() {
        assert_eq!(
            steer_turn_params(
                "thread-1",
                "turn-1",
                "00000000-0000-4000-8000-000000000001",
                "continue with the file"
            )
            .to_string(),
            serde_json::json!({
                "threadId": "thread-1",
                "expectedTurnId": "turn-1",
                "clientUserMessageId": "00000000-0000-4000-8000-000000000001",
                "input": [{ "type": "text", "text": "continue with the file" }]
            })
            .to_string()
        );
    }

    #[test]
    fn steer_response_requires_the_app_server_turn_id() {
        let missing = wonder_app_server::RpcResponse {
            id: 1,
            result: Some(serde_json::json!({})),
            error: None,
        };
        assert_eq!(steer_response_turn_id(&missing), None);

        let route_only = wonder_app_server::RpcResponse {
            id: 1,
            result: Some(serde_json::json!({ "turnId": "" })),
            error: None,
        };
        assert_eq!(steer_response_turn_id(&route_only), None);

        let accepted = wonder_app_server::RpcResponse {
            id: 1,
            result: Some(serde_json::json!({ "turnId": "turn-from-app-server" })),
            error: None,
        };
        assert_eq!(
            steer_response_turn_id(&accepted),
            Some("turn-from-app-server".to_owned())
        );
    }

    #[test]
    fn audio_boundary_canonicalizes_parameters_and_sniffs_containers() {
        assert_eq!(
            canonical_audio_mime("audio/webm;codecs=opus"),
            Some("audio/webm")
        );
        assert_eq!(canonical_audio_mime("audio/x-wav"), Some("audio/wav"));
        assert_eq!(canonical_audio_mime("audio/flac"), None);
        assert_eq!(
            sniff_audio_mime(&[0x1a, 0x45, 0xdf, 0xa3]),
            Some("audio/webm")
        );
        assert_eq!(sniff_audio_mime(b"OggS\0\0\0\0"), Some("audio/ogg"));
        assert_eq!(sniff_audio_mime(b"RIFF0000WAVEfmt "), Some("audio/wav"));
        assert_eq!(sniff_audio_mime(b"xxxxftypisom"), Some("audio/mp4"));
        assert_eq!(sniff_audio_mime(b"not audio"), None);
    }

    #[test]
    fn automation_schedule_calculates_daily_and_weekly_local_times() {
        let after = chrono::DateTime::parse_from_rfc3339("2026-01-15T14:30:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        assert_eq!(
            next_automation_run("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", "America/New_York", after)
                .unwrap(),
            Some("2026-01-16T14:00:00.000Z".into())
        );
        assert_eq!(
            next_automation_run(
                "FREQ=WEEKLY;BYDAY=FR;BYHOUR=9;BYMINUTE=0",
                "America/New_York",
                after,
            )
            .unwrap(),
            Some("2026-01-16T14:00:00.000Z".into())
        );
        assert_eq!(
            next_automation_run(
                "FREQ=MINUTELY;INTERVAL=5",
                "UTC",
                chrono::DateTime::parse_from_rfc3339("2026-01-15T14:32:14Z")
                    .unwrap()
                    .with_timezone(&chrono::Utc),
            )
            .unwrap(),
            Some("2026-01-15T14:35:00.000Z".into())
        );
    }

    #[test]
    fn automation_schedule_rejects_unknown_timezone_or_rule() {
        let after = chrono::DateTime::parse_from_rfc3339("2026-01-15T14:30:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        assert!(next_automation_run("FREQ=YEARLY", "UTC", after).is_err());
        assert!(next_automation_run("FREQ=DAILY;INTERVAL=5", "UTC", after).is_err());
        assert!(next_automation_run("FREQ=MINUTELY;INTERVAL=1441", "UTC", after).is_err());
        assert!(next_automation_run("FREQ=DAILY;BYHOUR=9", "Not/AZone", after).is_err());
    }

    #[test]
    fn standalone_automations_get_a_canonical_linked_task_conversation() {
        assert_eq!(
            automation_conversation_id("standalone", "automation-1", None),
            Some("automation:automation-1".into())
        );
        assert_eq!(
            automation_conversation_id("continuation", "automation-2", Some("conversation-2")),
            Some("conversation-2".into())
        );
    }

    #[test]
    fn runtime_catalog_uses_model_specific_effort_and_speed_options() {
        let mut catalog = RuntimeCatalog::default();
        catalog.apply_models_page(&serde_json::json!({
            "data": [{
                "id": "model-a",
                "displayName": "Model A",
                "description": "A useful model",
                "modelSpecialty": "Planning",
                "supportedReasoningEfforts": [{"reasoningEffort":"high","description":"Deep"}],
                "defaultReasoningEffort": "high",
                "serviceTiers": [{"id":"fast","name":"Fast"}]
            }]
        }));
        assert_eq!(catalog.models.len(), 1);
        assert_eq!(catalog.models[0].reasoning_efforts[0].id, "high");
        assert_eq!(
            catalog.models[0].model_specialty.as_deref(),
            Some("Planning")
        );
        assert_eq!(
            catalog.models[0].description.as_deref(),
            Some("A useful model")
        );
        assert_eq!(catalog.models[0].service_tiers[0].id, "default");
        assert_eq!(catalog.models[0].service_tiers[0].label, "Standard");
        assert_eq!(catalog.models[0].service_tiers[1].id, "fast");
        assert_eq!(
            catalog.models[0].default_reasoning_effort.as_deref(),
            Some("high")
        );
    }

    #[test]
    fn runtime_catalog_and_path_projection_are_restricted() {
        let mut catalog = RuntimeCatalog::default();
        catalog.apply_requirements(&serde_json::json!({
            "requirements": {
                "allowedApprovalPolicies": ["never"],
                "allowedApprovalsReviewers": ["user"],
                "allowedPermissionProfiles": {"wonder_bot_default": true, "danger": false}
            }
        }));
        assert_eq!(catalog.allowed_approval_policies, vec!["never"]);
        assert!(catalog.approval_policies_restricted);
        assert!(catalog.approval_reviewers_restricted);
        assert!(catalog.permission_profiles_restricted);
        assert_eq!(
            catalog.allowed_permission_profiles.get("danger"),
            Some(&false)
        );
        catalog.apply_requirements(&serde_json::json!({
            "requirements": {
                "allowedApprovalPolicies": [],
                "allowedApprovalsReviewers": [],
                "allowedPermissionProfiles": {}
            }
        }));
        assert!(catalog.approval_policies_restricted);
        assert!(catalog.approval_reviewers_restricted);
        assert!(catalog.permission_profiles_restricted);
        assert!(catalog.allowed_approval_policies.is_empty());
        assert!(catalog.allowed_permission_profiles.is_empty());
        catalog.apply_requirements(&serde_json::json!({
            "requirements": {
                "allowedApprovalPolicies": null,
                "allowedApprovalsReviewers": null,
                "allowedPermissionProfiles": null
            }
        }));
        assert!(!catalog.approval_policies_restricted);
        assert!(!catalog.approval_reviewers_restricted);
        assert!(!catalog.permission_profiles_restricted);
        assert_eq!(
            sanitized_relative_path("/workspace/src/main.rs", "/workspace"),
            Some("src/main.rs".into())
        );
        assert_eq!(
            sanitized_relative_path("/Users/example/.ssh/id_rsa", "/workspace"),
            None
        );
        assert_eq!(sanitized_relative_path("../secret.txt", "/workspace"), None);
    }

    #[test]
    fn runtime_capability_projection_excludes_install_urls_and_filesystem_paths() {
        let app = runtime_app_summary(&serde_json::json!({
            "id": "calendar",
            "name": "Calendar",
            "description": "Schedule context",
            "installUrl": "https://secret.example/install",
            "isEnabled": true,
            "isAccessible": true
        }))
        .expect("valid App summary");
        let skill = runtime_skill_summary(&serde_json::json!({
            "name": "launch-brief",
            "description": "Prepare a launch brief",
            "path": "/Users/example/.codex/skills/launch-brief/SKILL.md",
            "enabled": true
        }))
        .expect("valid Skill summary");
        let server = runtime_mcp_server_summary(&serde_json::json!({
            "name": "local-tools",
            "authStatus": "unsupported",
            "runtimeStatus": "connected",
            "tools": {"read": {}, "write": {}},
            "token": "must-not-be-returned"
        }))
        .expect("valid MCP summary");
        let serialized = serde_json::to_string(&(app, skill, server)).unwrap();
        assert!(!serialized.contains("installUrl"));
        assert!(!serialized.contains("SKILL.md"));
        assert!(!serialized.contains("must-not-be-returned"));
        assert!(serialized.contains("toolCount"));
    }

    #[test]
    fn attachment_ids_are_bounded_and_turn_input_preserves_media_types() {
        let first = "550e8400-e29b-41d4-a716-446655440000".to_owned();
        let second = "550e8400-e29b-41d4-a716-446655440001".to_owned();
        assert!(valid_attachment_ids(&[first.clone(), second.clone()]));
        assert!(!valid_attachment_ids(&[first.clone(), first.clone()]));
        assert!(!valid_attachment_ids(&["not-a-uuid".to_owned()]));
        let input = turn_input(
            "Look at these",
            "/tmp/bot",
            &[
                wonder_store::StoredConversationFile {
                    id: first,
                    conversation_id: "conversation".into(),
                    kind: "attachment".into(),
                    name: "photo.png".into(),
                    mime_type: Some("image/png".into()),
                    byte_size: Some(1),
                    sha256: None,
                    relative_path: Some(".wonder/attachments/photo".into()),
                    state: "available".into(),
                    additions: None,
                    deletions: None,
                    source_id: None,
                    created_at: "now".into(),
                    updated_at: "now".into(),
                },
                wonder_store::StoredConversationFile {
                    id: second,
                    conversation_id: "conversation".into(),
                    kind: "attachment".into(),
                    name: "notes.txt".into(),
                    mime_type: Some("text/plain".into()),
                    byte_size: Some(1),
                    sha256: None,
                    relative_path: Some(".wonder/attachments/notes".into()),
                    state: "available".into(),
                    additions: None,
                    deletions: None,
                    source_id: None,
                    created_at: "now".into(),
                    updated_at: "now".into(),
                },
            ],
        );
        assert_eq!(input[0]["text"], "Look at these");
        assert_eq!(input[1]["type"], "localImage");
        assert_eq!(input[2]["type"], "text");
        assert!(input[2]["text"].as_str().unwrap().contains("notes.txt"));
    }

    #[tokio::test]
    async fn attachment_boundary_and_metadata_are_durable() {
        let directory = tempfile::tempdir().expect("workspace directory");
        assert!(valid_attachment_name("notes.txt"));
        assert!(!valid_attachment_name("../notes.txt"));
        assert!(!valid_attachment_name("nested/notes.txt"));
        assert!(!valid_attachment_name(" notes.txt"));
        assert!(!valid_attachment_name("notes.txt\n"));
        assert!(valid_attachment_mime_type("text/plain"));
        assert!(valid_attachment_mime_type("application/vnd.example+json"));
        assert!(!valid_attachment_mime_type("text/plain; charset=utf-8"));
        assert!(!valid_attachment_mime_type("text"));
        assert!(!valid_attachment_mime_type("text/plain\r\n"));
        let empty = Vec::<u8>::new();
        assert!(empty.is_empty());
        let small = [0u8; 1];
        assert!(small.len() <= MAX_ATTACHMENT_BYTES);
        let oversized = vec![0u8; MAX_ATTACHMENT_BYTES + 1];
        assert!(oversized.len() > MAX_ATTACHMENT_BYTES);

        let file_id = "00000000-0000-4000-8000-000000000001";
        let relative = attachment_relative_path(file_id);
        let root = tokio::fs::canonicalize(directory.path())
            .await
            .expect("workspace root");
        let candidate = root.join(&relative);
        let contained = attachment_path(
            directory.path().to_str().expect("workspace path"),
            file_id,
            true,
        )
        .await
        .expect("contained attachment");
        assert_eq!(contained, candidate);
        assert!(attachment_path(
            directory.path().to_str().expect("workspace path"),
            "../outside.txt",
            false,
        )
        .await
        .is_none());

        let content = b"hello";
        let sha256 = hex::encode(Sha256::digest(content));
        let store = wonder_store::Store::connect("sqlite::memory:?cache=shared")
            .await
            .expect("store");
        store
            .upsert_bot(
                "default",
                "Default",
                "General",
                "Help",
                directory.path().to_str().expect("workspace path"),
                "wonder_bot_default",
                None,
                None,
                "2026-09-01T00:00:00Z",
            )
            .await
            .expect("bot");
        store
            .upsert_conversation_file(
                "file-1",
                "conversation-1",
                "attachment",
                "notes.txt",
                Some("text/plain"),
                Some(content.len() as i64),
                Some(&sha256),
                Some(&relative),
                "available",
                None,
                None,
                None,
                "2026-09-01T00:00:00Z",
            )
            .await
            .expect("metadata");
        let files = store
            .list_conversation_files("conversation-1")
            .await
            .expect("files");
        assert_eq!(files[0].byte_size, Some(5));
        assert_eq!(files[0].sha256.as_deref(), Some(sha256.as_str()));
        assert!(store
            .list_conversation_files("other-conversation")
            .await
            .expect("other conversation files")
            .is_empty());
    }
}

#[cfg(test)]
mod enrollment_tests;
