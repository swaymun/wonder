//! Authenticated, Bot-scoped teaching sessions and private skill lifecycle.
//!
//! Authenticated remote-control teaching capture. The daemon records only the
//! sanitized input actions it has already delivered to the paired Mac.

use crate::{bot_for_conversation, AppState, AuthenticatedDevice, LocalOwnerAuthority};
use axum::{
    extract::{Extension, Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use chrono::{Duration as ChronoDuration, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Component, Path as FsPath, PathBuf},
};
use wonder_store::{
    NewSkillFixtureRun, StoredBotSkill, StoredBotSkillVersion, StoredComputerControlLease,
    StoredComputerSession, StoredSkillFixtureRun, StoredTeachingEvent, StoredTeachingSession,
    TeachingReview, TeachingSessionCreate, TEACHING_MAX_EVENTS, TEACHING_MAX_EVIDENCE_BYTES,
    TEACHING_UNAVAILABLE,
};

const CAPTURE_PROVIDER: &str = "authenticated-remote-control-v1";
const CAPTURE_SCOPE: &str = "authenticated-remote-control";
const CAPTURE_ACTION: &str = "update-host";
const CAPTURE_AVAILABLE_REASON: &str =
    "Teaching records accepted computer actions from this paired Mac.";
const MAX_TEXT: usize = 2_000;
const MAX_MARKDOWN: usize = 24 * 1024;
const MAX_INPUT_SCHEMA: usize = 16 * 1024;
const MAX_SLUG: usize = 64;
const MAX_FIXTURE_INPUT_BYTES: usize = 8 * 1024;
const MAX_FIXTURE_ARTIFACT_BYTES: usize = 64 * 1024;
const FIXTURE_PROVIDER: &str = "deterministic-local";
const FIXTURE_EXECUTION_KIND: &str = "deterministicFixture";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TeachingCapability {
    pub available: bool,
    pub action: &'static str,
    pub reason: &'static str,
    pub provider: &'static str,
    pub max_duration_seconds: u64,
    pub max_events: u64,
    pub max_evidence_bytes: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StartRequest {
    client_request_id: String,
    conversation_id: String,
    computer_session_id: String,
    control_lease_id: String,
    capture_scope: String,
    outcome: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RevisionRequest {
    expected_revision: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ActivateVersionRequest {
    version: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ReviewRequest {
    expected_revision: u64,
    name: String,
    description: String,
    goal: String,
    input_schema: Value,
    prerequisites: String,
    steps: String,
    result_checks: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SaveVersionRequest {
    client_request_id: String,
    expected_revision: u64,
    slug: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct FixtureRunRequest {
    client_request_id: String,
    content_hash: String,
    input_schema: Value,
    inputs: Value,
    working_directory: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TeachingSessionResponse {
    id: String,
    client_request_id: String,
    owner_device_id: String,
    host_installation_id: String,
    bot_id: String,
    conversation_id: String,
    computer_session_id: Option<String>,
    control_lease_id: Option<String>,
    state: String,
    capture_scope: String,
    capture_provider: String,
    outcome: String,
    name: Option<String>,
    description: Option<String>,
    goal: Option<String>,
    input_schema: Option<Value>,
    prerequisites: Option<String>,
    steps: Option<String>,
    result_checks: Option<String>,
    failure_reason: Option<String>,
    revision: u64,
    event_count: u64,
    evidence_bytes: u64,
    content_hash: Option<String>,
    created_at: String,
    updated_at: String,
    started_at: Option<String>,
    ended_at: Option<String>,
    expires_at: Option<String>,
    events: Vec<TeachingEventResponse>,
    capability: TeachingCapability,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TeachingEventResponse {
    sequence: u64,
    action_index: u64,
    kind: String,
    payload: Value,
    created_at: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SkillSummary {
    id: String,
    bot_id: String,
    slug: String,
    name: String,
    description: String,
    state: String,
    active_version: Option<u64>,
    discoverability: &'static str,
    versions: Option<Vec<SkillVersionSummary>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SkillVersionSummary {
    id: String,
    version: u64,
    source_session_id: String,
    content_hash: String,
    input_schema: Value,
    verification_state: String,
    created_at: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SkillListResponse {
    capability: TeachingCapability,
    skills: Vec<SkillSummary>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SaveVersionResponse {
    skill: SkillSummary,
    version: SkillVersionSummary,
    teaching_session: TeachingSessionResponse,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FixtureRunReceipt {
    id: String,
    client_request_id: String,
    owner_device_id: String,
    bot_id: String,
    skill_id: String,
    version: u64,
    content_hash: String,
    input_schema_hash: String,
    input_schema: Value,
    inputs: Value,
    working_directory: String,
    provider: String,
    execution_kind: String,
    status: String,
    verification_state: String,
    artifact_path: Option<String>,
    artifact_hash: Option<String>,
    artifact_bytes: u64,
    evidence: Value,
    failure_reason: Option<String>,
    created_at: String,
    completed_at: String,
}

fn capability_value(state: &AppState) -> TeachingCapability {
    let available = crate::computer_sessions::provider_available(state);
    TeachingCapability {
        available,
        action: if available { "none" } else { CAPTURE_ACTION },
        reason: if available {
            CAPTURE_AVAILABLE_REASON
        } else {
            TEACHING_UNAVAILABLE
        },
        provider: if available { CAPTURE_PROVIDER } else { "none" },
        max_duration_seconds: 600,
        max_events: TEACHING_MAX_EVENTS,
        max_evidence_bytes: TEACHING_MAX_EVIDENCE_BYTES,
    }
}

pub(crate) async fn capability(
    State(state): State<AppState>,
    Extension(_authority): Extension<crate::OwnerAuthority>,
) -> Json<TeachingCapability> {
    Json(capability_value(&state))
}

fn text(value: &str, limit: usize) -> bool {
    let trimmed = value.trim();
    !trimmed.is_empty()
        && trimmed.chars().count() <= limit
        && !trimmed.chars().any(char::is_control)
}

fn valid_markdown(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= MAX_MARKDOWN && !value.contains('\0')
}

fn capture_scope(value: &str) -> bool {
    value == CAPTURE_SCOPE
}

fn valid_slug(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_SLUG
        && value
            .chars()
            .all(|value| value.is_ascii_lowercase() || value.is_ascii_digit() || value == '-')
        && !value.starts_with('-')
        && !value.ends_with('-')
        && !value.contains("--")
}

fn slug_for_name(name: &str) -> Option<String> {
    let mut slug = String::new();
    let mut separator = false;
    for character in name.chars() {
        if character.is_ascii_alphanumeric() {
            if separator && !slug.is_empty() {
                slug.push('-');
            }
            slug.push(character.to_ascii_lowercase());
            separator = false;
        } else if !slug.is_empty() {
            separator = true;
        }
    }
    if slug.len() > MAX_SLUG {
        slug.truncate(MAX_SLUG);
        while slug.ends_with('-') {
            slug.pop();
        }
    }
    valid_slug(&slug).then_some(slug)
}

#[allow(clippy::result_large_err)]
fn owner_device(
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
) -> Result<String, Response> {
    if let Some(Extension(device)) = authenticated {
        return Ok(device.device_id);
    }
    if local.is_some() {
        return Ok("wonder-desktop".to_owned());
    }
    Err((StatusCode::UNAUTHORIZED, "paired device required").into_response())
}

#[allow(clippy::result_large_err)]
async fn owned_bot(
    state: &AppState,
    bot_id: &str,
    conversation_id: Option<&str>,
) -> Result<wonder_store::StoredBot, Response> {
    let bot = state
        .store
        .bot(bot_id)
        .await
        .map_err(|_| (StatusCode::SERVICE_UNAVAILABLE, "Bot is unavailable").into_response())?
        .ok_or_else(|| StatusCode::NOT_FOUND.into_response())?;
    if bot.is_archived {
        return Err((StatusCode::CONFLICT, "This Bot is archived.").into_response());
    }
    if let Some(conversation_id) = conversation_id {
        let mapped = bot_for_conversation(state, conversation_id)
            .await
            .map_err(|_| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Conversation is unavailable",
                )
                    .into_response()
            })?;
        if mapped.as_ref().map(|mapped| mapped.id.as_str()) != Some(bot_id) {
            return Err(StatusCode::NOT_FOUND.into_response());
        }
    }
    Ok(bot)
}

fn event_response(event: StoredTeachingEvent) -> TeachingEventResponse {
    let payload = serde_json::from_str::<Value>(&event.event_json)
        .unwrap_or_else(|_| Value::Object(Default::default()));
    let kind = payload
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or("action")
        .to_owned();
    TeachingEventResponse {
        sequence: event.control_sequence,
        action_index: event.action_index,
        kind,
        payload,
        created_at: event.created_at,
    }
}

async fn response(state: &AppState, session: StoredTeachingSession) -> TeachingSessionResponse {
    let events = state
        .store
        .teaching_events(&session.id, 512)
        .await
        .unwrap_or_default()
        .into_iter()
        .map(event_response)
        .collect();
    TeachingSessionResponse {
        id: session.id,
        client_request_id: session.client_request_id,
        owner_device_id: session.owner_device_id,
        host_installation_id: session.host_installation_id,
        bot_id: session.bot_id,
        conversation_id: session.conversation_id,
        computer_session_id: session.computer_session_id,
        control_lease_id: session.control_lease_id,
        state: session.state,
        capture_scope: session.capture_scope,
        capture_provider: session.capture_provider,
        outcome: session.outcome,
        name: session.name,
        description: session.description,
        goal: session.goal,
        input_schema: session
            .input_schema_json
            .as_deref()
            .and_then(|value| serde_json::from_str(value).ok()),
        prerequisites: session.prerequisites,
        steps: session.steps,
        result_checks: session.result_checks,
        failure_reason: session.failure_reason,
        revision: session.revision,
        event_count: session.event_count,
        evidence_bytes: session.evidence_bytes,
        content_hash: session.content_hash,
        created_at: session.created_at,
        updated_at: session.updated_at,
        started_at: session.started_at,
        ended_at: session.ended_at,
        expires_at: session.expires_at,
        events,
        capability: capability_value(state),
    }
}

fn version_response(version: StoredBotSkillVersion) -> SkillVersionSummary {
    SkillVersionSummary {
        id: version.id,
        version: version.version,
        source_session_id: version.source_session_id,
        content_hash: version.content_hash,
        input_schema: serde_json::from_str(&version.input_schema_json)
            .unwrap_or(Value::Object(Default::default())),
        verification_state: version.verification_state,
        created_at: version.created_at,
    }
}

fn skill_response(
    skill: StoredBotSkill,
    versions: Option<Vec<StoredBotSkillVersion>>,
) -> SkillSummary {
    SkillSummary {
        id: skill.id,
        bot_id: skill.bot_id,
        slug: skill.slug,
        name: skill.name,
        description: skill.description,
        state: skill.state,
        active_version: skill.active_version,
        discoverability: "bot-private",
        versions: versions.map(|versions| versions.into_iter().map(version_response).collect()),
    }
}

fn fixture_receipt(run: StoredSkillFixtureRun) -> FixtureRunReceipt {
    FixtureRunReceipt {
        id: run.id,
        client_request_id: run.client_request_id,
        owner_device_id: run.owner_device_id,
        bot_id: run.bot_id,
        skill_id: run.skill_id,
        version: run.version,
        content_hash: run.content_hash,
        input_schema_hash: run.input_schema_hash,
        input_schema: serde_json::from_str(&run.input_schema_json)
            .unwrap_or(Value::Object(Default::default())),
        inputs: serde_json::from_str(&run.inputs_json).unwrap_or(Value::Object(Default::default())),
        working_directory: run.working_directory,
        provider: run.provider,
        execution_kind: run.execution_kind,
        status: run.status,
        verification_state: run.verification_state,
        artifact_path: run.artifact_path,
        artifact_hash: run.artifact_hash,
        artifact_bytes: run.artifact_bytes,
        evidence: serde_json::from_str(&run.evidence_json)
            .unwrap_or(Value::Object(Default::default())),
        failure_reason: run.failure_reason,
        created_at: run.created_at,
        completed_at: run.completed_at,
    }
}

fn canonical_json(value: &Value) -> Result<String, String> {
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {
            serde_json::to_string(value).map_err(|_| "JSON value is not supported.".into())
        }
        Value::Array(values) => values
            .iter()
            .map(canonical_json)
            .collect::<Result<Vec<_>, _>>()
            .map(|values| format!("[{}]", values.join(","))),
        Value::Object(values) => {
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_unstable();
            let mut fields = Vec::with_capacity(keys.len());
            for key in keys {
                fields.push(format!(
                    "{}:{}",
                    serde_json::to_string(key).map_err(|_| "JSON key is not supported.")?,
                    canonical_json(&values[key])?
                ));
            }
            Ok(format!("{{{}}}", fields.join(",")))
        }
    }
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn validate_fixture_schema(schema: &Value) -> Result<(), String> {
    let Some(fields) = schema.as_object() else {
        return Err("The deterministic fixture requires an object input schema.".into());
    };
    if fields.len() != 2 || !fields.contains_key("title") || !fields.contains_key("date") {
        return Err("The deterministic fixture supports exactly title and date inputs.".into());
    }
    for (name, definition) in fields {
        let Some(definition) = definition.as_object() else {
            return Err(format!("Input schema field {name} is invalid."));
        };
        if definition.get("type").and_then(Value::as_str) != Some("string") {
            return Err(format!("Input schema field {name} must be a string."));
        }
        if name == "date"
            && definition
                .get("format")
                .and_then(Value::as_str)
                .is_some_and(|format| format != "date")
        {
            return Err("The date input must use the date format.".into());
        }
        if definition
            .keys()
            .any(|key| key != "type" && key != "format" && key != "description")
        {
            return Err(format!(
                "Input schema field {name} contains an unsupported option."
            ));
        }
    }
    Ok(())
}

fn validate_fixture_inputs(schema: &Value, inputs: &Value) -> Result<(String, String), String> {
    validate_fixture_schema(schema)?;
    let Some(inputs) = inputs.as_object() else {
        return Err("Fixture inputs must be an object.".into());
    };
    if inputs.len() != 2 || !inputs.contains_key("title") || !inputs.contains_key("date") {
        return Err("Fixture inputs must contain only title and date.".into());
    }
    let title = inputs
        .get("title")
        .and_then(Value::as_str)
        .ok_or_else(|| "Fixture title must be a string.".to_owned())?;
    let date = inputs
        .get("date")
        .and_then(Value::as_str)
        .ok_or_else(|| "Fixture date must be a string.".to_owned())?;
    if !text(title, 200) {
        return Err("Fixture title must contain 1–200 characters.".into());
    }
    if date.len() != 10
        || chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d").is_err()
        || date.as_bytes()[4] != b'-'
        || date.as_bytes()[7] != b'-'
    {
        return Err("Fixture date must be a valid YYYY-MM-DD date.".into());
    }
    let encoded = serde_json::to_vec(inputs).map_err(|_| "Fixture inputs are invalid.")?;
    if encoded.len() > MAX_FIXTURE_INPUT_BYTES {
        return Err("Fixture inputs are too large.".into());
    }
    Ok((title.to_owned(), date.to_owned()))
}

fn safe_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn safe_fixture_working_directory(
    root: &str,
    configured: &str,
    requested: Option<&str>,
) -> Result<String, String> {
    let root = fs::canonicalize(root).map_err(|_| "The Bot workspace could not be checked.")?;
    if !root.is_dir() {
        return Err("The Bot workspace is not a directory.".into());
    }
    let candidate = if let Some(requested) = requested {
        if requested.is_empty()
            || requested.chars().count() > 512
            || requested.chars().any(char::is_control)
        {
            return Err("The fixture working directory is invalid.".into());
        }
        let requested = FsPath::new(requested);
        if requested
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::CurDir))
        {
            return Err("The fixture working directory is invalid.".into());
        }
        if requested.is_absolute() {
            requested.to_path_buf()
        } else {
            root.join(requested)
        }
    } else {
        let configured = FsPath::new(configured);
        if !configured.is_absolute() {
            root.join(configured)
        } else {
            configured.to_path_buf()
        }
    };
    let canonical = fs::canonicalize(&candidate)
        .map_err(|_| "The fixture working directory is unavailable.")?;
    if canonical != candidate || !canonical.is_dir() {
        return Err("Choose an existing fixture folder using its resolved path.".into());
    }
    Ok(canonical.to_string_lossy().into_owned())
}

fn write_fixture_artifact(
    root: &str,
    bot_id: &str,
    request_id: &str,
    artifact: &Value,
    expected_title: &str,
    expected_date: &str,
) -> Result<(String, String, u64), String> {
    if !safe_component(bot_id) || !safe_component(request_id) {
        return Err("The fixture artifact identity is invalid.".into());
    }
    let root = fs::canonicalize(root).map_err(|_| "The Bot workspace could not be checked.")?;
    let wonder = checked_directory(&root, ".wonder")?;
    let runs = checked_directory(&wonder, "fixture-runs")?;
    let bot = checked_directory(&runs, bot_id)?;
    let request = checked_directory(&bot, request_id)?;
    let contents = serde_json::to_string_pretty(artifact)
        .map_err(|_| "The fixture artifact could not be encoded.")?;
    if contents.len() > MAX_FIXTURE_ARTIFACT_BYTES {
        return Err("The fixture artifact is too large.".into());
    }
    write_atomic(&request, "preview.json", &contents)?;
    let path = request.join("preview.json");
    let metadata =
        fs::symlink_metadata(&path).map_err(|_| "The fixture artifact could not be checked.")?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err("The fixture artifact is not safe.".into());
    }
    let actual =
        fs::read_to_string(&path).map_err(|_| "The fixture artifact could not be read back.")?;
    let actual_json: Value =
        serde_json::from_str(&actual).map_err(|_| "The fixture artifact could not be verified.")?;
    if actual_json
        .get("preview")
        .and_then(|value| value.get("title"))
        != Some(&Value::String(expected_title.to_owned()))
        || actual_json
            .get("preview")
            .and_then(|value| value.get("date"))
            != Some(&Value::String(expected_date.to_owned()))
        || actual_json.get("expected") != actual_json.get("actual")
    {
        return Err("The fixture artifact did not match its expected fields.".into());
    }
    let relative = path
        .strip_prefix(&root)
        .map_err(|_| "The fixture artifact escaped the Bot workspace.")?
        .to_string_lossy()
        .into_owned();
    Ok((relative, hash(&actual), actual.len() as u64))
}

fn error_from_store(error: sqlx::Error) -> Response {
    match error {
        sqlx::Error::Protocol(message) if message.contains("revision mismatch") => (
            StatusCode::CONFLICT,
            "This teaching session changed. Refresh it before retrying.",
        )
            .into_response(),
        sqlx::Error::Protocol(message) if message.contains("not ready") => (
            StatusCode::CONFLICT,
            "This teaching session has no captured demonstration to review.",
        )
            .into_response(),
        sqlx::Error::Protocol(message) if message.contains("approved") => (
            StatusCode::CONFLICT,
            "This teaching session already has an approved version.",
        )
            .into_response(),
        _ => (
            StatusCode::SERVICE_UNAVAILABLE,
            "The teaching session could not be updated.",
        )
            .into_response(),
    }
}

fn lease_matches_current_session(
    computer_session: &StoredComputerSession,
    lease: &StoredComputerControlLease,
    owner: &str,
    host_installation_id: &str,
    conversation_id: &str,
    control_lease_id: &str,
    now: &str,
) -> bool {
    computer_session.owner_device_id == owner
        && computer_session.host_installation_id == host_installation_id
        && computer_session.conversation_id == conversation_id
        && computer_session.state == "live"
        && lease.id == control_lease_id
        && lease.session_id == computer_session.id
        && lease.owner_device_id == owner
        && lease.host_installation_id == host_installation_id
        && lease.conversation_id == computer_session.conversation_id
        && lease.session_generation == computer_session.generation
        && lease.source_id == computer_session.source_id
        && lease.geometry_revision == computer_session.geometry_revision
        && lease.status == "active"
        && lease.expires_at.as_str() > now
}

fn start_matches_existing_session(
    existing: &StoredTeachingSession,
    bot_id: &str,
    request: &StartRequest,
) -> bool {
    existing.bot_id == bot_id
        && existing.conversation_id == request.conversation_id
        && existing.computer_session_id.as_deref() == Some(request.computer_session_id.as_str())
        && existing.control_lease_id.as_deref() == Some(request.control_lease_id.as_str())
        && existing.capture_scope == request.capture_scope
        && existing.outcome == request.outcome
}

pub(crate) async fn start(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path(bot_id): Path<String>,
    Json(request): Json<StartRequest>,
) -> Response {
    let owner = match owner_device(authenticated, local) {
        Ok(owner) => owner,
        Err(response) => return response,
    };
    if !text(&bot_id, 160)
        || uuid::Uuid::parse_str(&request.client_request_id).is_err()
        || !text(&request.conversation_id, 160)
        || !text(&request.computer_session_id, 160)
        || !text(&request.control_lease_id, 160)
        || !capture_scope(&request.capture_scope)
        || !text(&request.outcome, MAX_TEXT)
    {
        return (StatusCode::BAD_REQUEST, "teaching request is invalid").into_response();
    }
    if let Err(response) = owned_bot(&state, &bot_id, Some(&request.conversation_id)).await {
        return response;
    }
    match state
        .store
        .teaching_session_by_request(&owner, &request.client_request_id)
        .await
    {
        Ok(Some(existing)) => {
            if !start_matches_existing_session(&existing, &bot_id, &request) {
                return (
                    StatusCode::CONFLICT,
                    "client request is already bound to another teaching session",
                )
                    .into_response();
            }
            return Json(response(&state, existing).await).into_response();
        }
        Ok(None) => {}
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "teaching sessions are unavailable",
            )
                .into_response()
        }
    }
    if !crate::computer_sessions::provider_available(&state) {
        return (StatusCode::SERVICE_UNAVAILABLE, TEACHING_UNAVAILABLE).into_response();
    }
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let computer_session = match state
        .store
        .computer_session(&request.computer_session_id)
        .await
    {
        Ok(Some(session)) => session,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Computer view is unavailable.",
            )
                .into_response()
        }
    };
    let lease = match state
        .store
        .computer_control_lease(&request.control_lease_id)
        .await
    {
        Ok(Some(lease)) => lease,
        Ok(None) => {
            return (
                StatusCode::CONFLICT,
                "Take control before starting teaching.",
            )
                .into_response()
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Computer control is unavailable.",
            )
                .into_response()
        }
    };
    let lease_matches = lease_matches_current_session(
        &computer_session,
        &lease,
        &owner,
        &state.host_installation_id,
        &request.conversation_id,
        &request.control_lease_id,
        &now,
    );
    if !lease_matches {
        return (
            StatusCode::CONFLICT,
            "Take control before starting teaching, then try again while this computer view is live.",
        )
            .into_response();
    }
    let session = TeachingSessionCreate {
        id: uuid::Uuid::new_v4().to_string(),
        client_request_id: request.client_request_id.clone(),
        owner_device_id: owner,
        host_installation_id: state.host_installation_id.clone(),
        bot_id: bot_id.clone(),
        conversation_id: request.conversation_id.clone(),
        computer_session_id: Some(computer_session.id),
        control_lease_id: Some(lease.id),
        state: "recording".into(),
        capture_scope: request.capture_scope.clone(),
        capture_provider: CAPTURE_PROVIDER.into(),
        outcome: request.outcome.clone(),
        failure_reason: None,
        now,
        expires_at: Some(
            (Utc::now() + ChronoDuration::minutes(10)).to_rfc3339_opts(SecondsFormat::Millis, true),
        ),
    };
    match state.store.insert_teaching_session(&session).await {
        Ok(stored) => (StatusCode::CREATED, Json(response(&state, stored).await)).into_response(),
        Err(sqlx::Error::Database(error)) if error.is_unique_violation() => {
            match state
                .store
                .teaching_session_by_request(&session.owner_device_id, &session.client_request_id)
                .await
            {
                Ok(Some(stored)) if start_matches_existing_session(&stored, &bot_id, &request) => {
                    Json(response(&state, stored).await).into_response()
                }
                _ => (
                    StatusCode::CONFLICT,
                    "client request is already bound to another teaching session",
                )
                    .into_response(),
            }
        }
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "teaching session could not be saved",
        )
            .into_response(),
    }
}

#[allow(clippy::result_large_err)]
async fn owned_session(
    state: &AppState,
    bot_id: &str,
    session_id: &str,
    owner: &str,
) -> Result<StoredTeachingSession, Response> {
    let session = state
        .store
        .teaching_session(session_id)
        .await
        .map_err(|_| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                "teaching session is unavailable",
            )
                .into_response()
        })?
        .ok_or_else(|| StatusCode::NOT_FOUND.into_response())?;
    if session.owner_device_id != owner || session.bot_id != bot_id {
        return Err(StatusCode::NOT_FOUND.into_response());
    }
    Ok(session)
}

pub(crate) async fn read(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path((bot_id, session_id)): Path<(String, String)>,
) -> Response {
    let owner = match owner_device(authenticated, local) {
        Ok(owner) => owner,
        Err(response) => return response,
    };
    match owned_bot(&state, &bot_id, None).await.map(|_| ()) {
        Ok(()) => {}
        Err(response) => return response,
    }
    match owned_session(&state, &bot_id, &session_id, &owner).await {
        Ok(session) => Json(response(&state, session).await).into_response(),
        Err(response) => response,
    }
}

pub(crate) async fn cancel(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path((bot_id, session_id)): Path<(String, String)>,
    body: Option<Json<RevisionRequest>>,
) -> Response {
    let owner = match owner_device(authenticated, local) {
        Ok(owner) => owner,
        Err(response) => return response,
    };
    if let Err(response) = owned_bot(&state, &bot_id, None).await {
        return response;
    }
    let current = match owned_session(&state, &bot_id, &session_id, &owner).await {
        Ok(value) => value,
        Err(response) => return response,
    };
    match state
        .store
        .cancel_teaching_session(
            &current.id,
            &owner,
            body.and_then(|body| body.expected_revision),
            &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        )
        .await
    {
        Ok(Some(session)) => Json(response(&state, session).await).into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(error) => error_from_store(error),
    }
}

pub(crate) async fn stop(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path((bot_id, session_id)): Path<(String, String)>,
    Json(request): Json<RevisionRequest>,
) -> Response {
    let owner = match owner_device(authenticated, local) {
        Ok(owner) => owner,
        Err(response) => return response,
    };
    if let Err(response) = owned_bot(&state, &bot_id, None).await {
        return response;
    }
    let Some(expected_revision) = request.expected_revision else {
        return (StatusCode::BAD_REQUEST, "expectedRevision is required").into_response();
    };
    match owned_session(&state, &bot_id, &session_id, &owner).await {
        Ok(current) => match state
            .store
            .stop_teaching_session(
                &current.id,
                &owner,
                expected_revision,
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            )
            .await
        {
            Ok(Some(session)) => Json(response(&state, session).await).into_response(),
            Ok(None) => StatusCode::NOT_FOUND.into_response(),
            Err(error) => error_from_store(error),
        },
        Err(response) => response,
    }
}

pub(crate) async fn review(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path((bot_id, session_id)): Path<(String, String)>,
    Json(request): Json<ReviewRequest>,
) -> Response {
    let owner = match owner_device(authenticated, local) {
        Ok(owner) => owner,
        Err(response) => return response,
    };
    if let Err(response) = owned_bot(&state, &bot_id, None).await {
        return response;
    }
    if !text(&request.name, 120)
        || !text(&request.description, MAX_TEXT)
        || !text(&request.goal, MAX_TEXT)
        || !valid_markdown(&request.prerequisites)
        || !valid_markdown(&request.steps)
        || !valid_markdown(&request.result_checks)
    {
        return (StatusCode::BAD_REQUEST, "skill review is invalid").into_response();
    }
    let input_schema_json = match serde_json::to_string(&request.input_schema) {
        Ok(value) if request.input_schema.is_object() && value.len() <= MAX_INPUT_SCHEMA => value,
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                "inputSchema must be a bounded JSON object",
            )
                .into_response()
        }
    };
    let skill_markdown = render_markdown(&request, &input_schema_json);
    let review = TeachingReview {
        expected_revision: request.expected_revision,
        name: request.name,
        description: request.description,
        goal: request.goal,
        input_schema_json,
        prerequisites: request.prerequisites,
        steps: request.steps,
        result_checks: request.result_checks,
        content_hash: hash(&skill_markdown),
        now: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
    };
    if !valid_markdown(&skill_markdown) {
        return (StatusCode::BAD_REQUEST, "skill draft is too large").into_response();
    }
    match owned_session(&state, &bot_id, &session_id, &owner).await {
        Ok(_) => match state
            .store
            .review_teaching_session(&session_id, &owner, &review)
            .await
        {
            Ok(Some(session)) => Json(response(&state, session).await).into_response(),
            Ok(None) => StatusCode::NOT_FOUND.into_response(),
            Err(error) => error_from_store(error),
        },
        Err(response) => response,
    }
}

fn render_markdown(request: &ReviewRequest, input_schema_json: &str) -> String {
    format!(
        "---\nname: {}\ndescription: {}\n---\n\n# {}\n\n## Goal\n{}\n\n## Inputs\n```json\n{}\n```\n\n## Prerequisites\n{}\n\n## Steps\n{}\n\n## Result checks\n{}\n",
        request.name, request.description, request.name, request.goal, input_schema_json, request.prerequisites, request.steps, request.result_checks
    )
}

fn hash(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}

fn checked_directory(parent: &FsPath, name: &str) -> Result<PathBuf, String> {
    let path = parent.join(name);
    match fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            return Err("Skill storage cannot contain symlinks.".into())
        }
        Ok(metadata) if !metadata.is_dir() => {
            return Err("Skill storage is not a directory.".into())
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir(&path).map_err(|_| "Private skill storage could not be created.")?;
        }
        Err(_) => return Err("Private skill storage could not be checked.".into()),
    }
    Ok(path)
}

fn write_atomic(directory: &FsPath, target_name: &str, contents: &str) -> Result<(), String> {
    let target = directory.join(target_name);
    if let Ok(metadata) = fs::symlink_metadata(&target) {
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err("The private skill file is not safe.".into());
        }
    }
    let temporary = directory.join(format!(".{target_name}.{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|_| "Private skill storage could not be opened.".to_owned())?;
        file.write_all(contents.as_bytes())
            .map_err(|_| "Private skill could not be written.".to_owned())?;
        file.sync_all()
            .map_err(|_| "Private skill could not be saved.".to_owned())?;
        drop(file);
        fs::rename(&temporary, &target)
            .map_err(|_| "Private skill could not be published.".to_owned())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn publish_skill_files(
    root: &str,
    skill_id: &str,
    version_key: &str,
    slug: &str,
    contents: &str,
) -> Result<(), String> {
    if uuid::Uuid::parse_str(skill_id).is_err()
        || uuid::Uuid::parse_str(version_key).is_err()
        || !valid_slug(slug)
    {
        return Err("Private skill identity is invalid.".into());
    }
    let root = fs::canonicalize(root).map_err(|_| "The Bot workspace could not be checked.")?;
    if !root.is_dir() {
        return Err("The Bot workspace is not a directory.".into());
    }
    let agents = checked_directory(&root, ".agents")?;
    let skills = checked_directory(&agents, "skills")?;
    let versions = checked_directory(&skills, ".wonder-versions")?;
    let skill_versions = checked_directory(&versions, skill_id)?;
    let version_directory = checked_directory(&skill_versions, version_key)?;
    let version_file = version_directory.join("SKILL.md");
    match fs::symlink_metadata(&version_file) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            return Err("The private skill version is not safe.".into())
        }
        Ok(_) => {
            let mut existing = String::new();
            fs::File::open(&version_file)
                .and_then(|mut file| file.read_to_string(&mut existing))
                .map_err(|_| "The private skill version could not be checked.")?;
            if hash(&existing) != hash(contents) {
                return Err("The private skill version changed unexpectedly.".into());
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&version_file)
                .map_err(|_| "Private skill storage could not be opened.")?;
            file.write_all(contents.as_bytes())
                .map_err(|_| "Private skill could not be written.")?;
            file.sync_all()
                .map_err(|_| "Private skill could not be saved.")?;
        }
        Err(_) => return Err("The private skill version could not be checked.".into()),
    }
    let active = checked_directory(&skills, slug)?;
    write_atomic(&active, "SKILL.md", contents)
}

fn activate_skill_file(
    root: &str,
    skill_id: &str,
    version_key: &str,
    slug: &str,
) -> Result<(), String> {
    let root = fs::canonicalize(root).map_err(|_| "The Bot workspace could not be checked.")?;
    let source = root
        .join(".agents/skills/.wonder-versions")
        .join(skill_id)
        .join(version_key)
        .join("SKILL.md");
    let mut contents = String::new();
    fs::File::open(source)
        .and_then(|mut file| file.read_to_string(&mut contents))
        .map_err(|_| "The selected private skill version is missing.")?;
    let active = root.join(".agents/skills").join(slug);
    let active =
        fs::canonicalize(active).map_err(|_| "The private skill location is unavailable.")?;
    if !active.starts_with(&root) {
        return Err("Skill path escaped the Bot workspace.".into());
    }
    write_atomic(&active, "SKILL.md", &contents)
}

fn archive_skill_file(root: &str, slug: &str) -> Result<(), String> {
    let root = fs::canonicalize(root).map_err(|_| "The Bot workspace could not be checked.")?;
    let active = root.join(".agents/skills").join(slug);
    match fs::symlink_metadata(&active) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            Err("The private skill location is not safe.".into())
        }
        Ok(_) => fs::remove_dir_all(active)
            .map_err(|_| "The private skill could not be archived.".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err("The private skill location could not be checked.".into()),
    }
}

pub(crate) async fn save_version(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path((bot_id, session_id)): Path<(String, String)>,
    Json(request): Json<SaveVersionRequest>,
) -> Response {
    let owner = match owner_device(authenticated, local) {
        Ok(owner) => owner,
        Err(response) => return response,
    };
    let bot = match owned_bot(&state, &bot_id, None).await {
        Ok(bot) => bot,
        Err(response) => return response,
    };
    if uuid::Uuid::parse_str(&request.client_request_id).is_err() {
        return (StatusCode::BAD_REQUEST, "clientRequestId must be a UUID").into_response();
    }
    let session = match owned_session(&state, &bot_id, &session_id, &owner).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    if !matches!(session.state.as_str(), "skillDraft" | "approvedVersion") {
        return (
            StatusCode::CONFLICT,
            "Review a captured teaching session before saving a skill.",
        )
            .into_response();
    }
    let name = session.name.as_deref().unwrap_or_default();
    let slug = request
        .slug
        .or_else(|| slug_for_name(name))
        .filter(|value| valid_slug(value));
    let Some(slug) = slug else {
        return (
            StatusCode::BAD_REQUEST,
            "Choose a safe lowercase skill name.",
        )
            .into_response();
    };
    let input_schema_json = session.input_schema_json.as_deref().unwrap_or("{}");
    let review = ReviewRequest {
        expected_revision: session.revision,
        name: name.to_owned(),
        description: session.description.clone().unwrap_or_default(),
        goal: session.goal.clone().unwrap_or_default(),
        input_schema: serde_json::from_str(input_schema_json)
            .unwrap_or(Value::Object(Default::default())),
        prerequisites: session.prerequisites.clone().unwrap_or_default(),
        steps: session.steps.clone().unwrap_or_default(),
        result_checks: session.result_checks.clone().unwrap_or_default(),
    };
    let markdown = render_markdown(&review, input_schema_json);
    if session.content_hash.as_deref() != Some(hash(&markdown).as_str()) {
        return (
            StatusCode::CONFLICT,
            "The reviewed skill draft changed. Review it again before saving.",
        )
            .into_response();
    }
    let existing_version = match state
        .store
        .bot_skill_version_by_request(&bot_id, &request.client_request_id)
        .await
    {
        Ok(value) => value,
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Private skill versions are unavailable.",
            )
                .into_response()
        }
    };
    if session.state == "skillDraft" && session.revision != request.expected_revision {
        return (
            StatusCode::CONFLICT,
            "This teaching session changed. Refresh it before retrying.",
        )
            .into_response();
    }
    let skill_id = if let Some(existing) = &existing_version {
        if existing.source_session_id != session.id
            || existing.content_hash != session.content_hash.as_deref().unwrap_or_default()
        {
            return (
                StatusCode::CONFLICT,
                "client request is already bound to another skill version",
            )
                .into_response();
        }
        existing.skill_id.clone()
    } else {
        match state.store.list_bot_skills(&bot_id).await {
            Ok(skills) => skills
                .into_iter()
                .find(|skill| skill.slug == slug)
                .map(|skill| skill.id)
                .unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
            Err(_) => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Private skills are unavailable.",
                )
                    .into_response()
            }
        }
    };
    let active_path = format!(".agents/skills/{slug}/SKILL.md");
    let version_path = format!(
        ".agents/skills/.wonder-versions/{skill_id}/{}/SKILL.md",
        request.client_request_id
    );
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let reservation = match state
        .store
        .reserve_bot_skill_version(
            &bot_id,
            &session,
            &skill_id,
            &slug,
            &active_path,
            &version_path,
            &request.client_request_id,
            &now,
        )
        .await
    {
        Ok(value) => value,
        Err(error) => return error_from_store(error),
    };
    let workspace = bot.workspace_path.clone();
    let file_skill_id = skill_id.clone();
    let version_key = request.client_request_id.clone();
    let file_slug = slug.clone();
    let markdown_for_write = markdown.clone();
    let publication = tokio::task::spawn_blocking(move || {
        publish_skill_files(
            &workspace,
            &file_skill_id,
            &version_key,
            &file_slug,
            &markdown_for_write,
        )
    })
    .await;
    if !matches!(publication, Ok(Ok(()))) {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "The private skill could not be saved inside the Bot workspace.",
        )
            .into_response();
    }
    let skill = if session.state == "approvedVersion" {
        match state.store.bot_skill(&bot_id, &skill_id).await {
            Ok(Some(skill)) if skill.active_version == Some(reservation.version.version) => skill,
            _ => {
                return (
                    StatusCode::CONFLICT,
                    "The saved skill version is no longer active.",
                )
                    .into_response()
            }
        }
    } else {
        match state
            .store
            .activate_bot_skill_version(
                &bot_id,
                &skill_id,
                reservation.version.version,
                &session.id,
                &owner,
                request.expected_revision,
                &now,
            )
            .await
        {
            Ok(skill) => skill,
            Err(error) => return error_from_store(error),
        }
    };
    let teaching = match state.store.teaching_session(&session.id).await {
        Ok(Some(session)) => session,
        _ => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "The saved teaching session could not be loaded.",
            )
                .into_response()
        }
    };
    let status = if reservation.created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    (
        status,
        Json(SaveVersionResponse {
            skill: skill_response(skill, None),
            version: version_response(reservation.version),
            teaching_session: response(&state, teaching).await,
        }),
    )
        .into_response()
}

pub(crate) async fn list_skills(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path(bot_id): Path<String>,
) -> Response {
    if let Err(response) = owner_device(authenticated, local) {
        return response;
    }
    if let Err(response) = owned_bot(&state, &bot_id, None).await {
        return response;
    }
    match state.store.list_bot_skills(&bot_id).await {
        Ok(skills) => Json(SkillListResponse {
            capability: capability_value(&state),
            skills: skills
                .into_iter()
                .map(|skill| skill_response(skill, None))
                .collect(),
        })
        .into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "Private skills are unavailable.",
        )
            .into_response(),
    }
}

#[allow(clippy::result_large_err)]
async fn persist_fixture_failure(
    state: &AppState,
    request: NewSkillFixtureRun,
) -> Result<StoredSkillFixtureRun, Response> {
    state
        .store
        .insert_skill_fixture_run(&request)
        .await
        .map(|reservation| reservation.run)
        .map_err(|error| match error {
            sqlx::Error::Protocol(message) if message.contains("payload mismatch") => (
                StatusCode::CONFLICT,
                "client request is already bound to another fixture test",
            )
                .into_response(),
            _ => (
                StatusCode::SERVICE_UNAVAILABLE,
                "The fixture test receipt could not be saved.",
            )
                .into_response(),
        })
}

pub(crate) async fn run_fixture(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path((bot_id, skill_id, version)): Path<(String, String, u64)>,
    Json(request): Json<FixtureRunRequest>,
) -> Response {
    let owner = match owner_device(authenticated, local) {
        Ok(owner) => owner,
        Err(response) => return response,
    };
    let bot = match owned_bot(&state, &bot_id, None).await {
        Ok(bot) => bot,
        Err(response) => return response,
    };
    if !text(&bot_id, 160) || !text(&skill_id, 160) || version == 0 {
        return (StatusCode::BAD_REQUEST, "skill version is invalid").into_response();
    }
    match state.store.bot_skill(&bot_id, &skill_id).await {
        Ok(Some(skill)) if skill.state != "archived" => {}
        Ok(Some(_)) => {
            return (
                StatusCode::CONFLICT,
                "Restore this private skill before testing it.",
            )
                .into_response()
        }
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Private skills are unavailable.",
            )
                .into_response()
        }
    }
    if uuid::Uuid::parse_str(&request.client_request_id).is_err() {
        return (StatusCode::BAD_REQUEST, "clientRequestId must be a UUID").into_response();
    }
    if !valid_sha256(&request.content_hash) {
        return (
            StatusCode::BAD_REQUEST,
            "contentHash must be a SHA-256 hash",
        )
            .into_response();
    }
    let input_schema_json = match canonical_json(&request.input_schema) {
        Ok(value) if value.len() <= MAX_INPUT_SCHEMA => value,
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                "inputSchema is invalid or too large",
            )
                .into_response()
        }
    };
    let inputs_json = match canonical_json(&request.inputs) {
        Ok(value) if value.len() <= MAX_FIXTURE_INPUT_BYTES => value,
        _ => return (StatusCode::BAD_REQUEST, "inputs are invalid or too large").into_response(),
    };
    let working_directory = match safe_fixture_working_directory(
        &bot.workspace_path,
        bot.execution_directory(),
        request.working_directory.as_deref(),
    ) {
        Ok(value) => value,
        Err(message) => return (StatusCode::UNPROCESSABLE_ENTITY, message).into_response(),
    };
    if let Err((status, message)) =
        crate::bot_management::validate_directory(&state, &bot, &working_directory).await
    {
        return (status, message).into_response();
    }
    let version_record = match state
        .store
        .bot_skill_version(&bot_id, &skill_id, version)
        .await
    {
        Ok(Some(version_record)) => version_record,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Private skill versions are unavailable.",
            )
                .into_response()
        }
    };
    if request.content_hash != version_record.content_hash {
        return (
            StatusCode::CONFLICT,
            "contentHash does not match the selected skill version.",
        )
            .into_response();
    }
    let stored_schema = match serde_json::from_str::<Value>(&version_record.input_schema_json) {
        Ok(value) => value,
        Err(_) => {
            return (
                StatusCode::CONFLICT,
                "The selected input schema is invalid.",
            )
                .into_response()
        }
    };
    let stored_schema_json = match canonical_json(&stored_schema) {
        Ok(value) => value,
        Err(_) => {
            return (
                StatusCode::CONFLICT,
                "The selected input schema is invalid.",
            )
                .into_response()
        }
    };
    if stored_schema_json != input_schema_json {
        return (
            StatusCode::CONFLICT,
            "inputSchema does not match the selected skill version.",
        )
            .into_response();
    }
    let input_schema_hash = hash(&input_schema_json);
    let existing = match state
        .store
        .skill_fixture_run_by_request(&request.client_request_id)
        .await
    {
        Ok(value) => value,
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Fixture test receipts are unavailable.",
            )
                .into_response()
        }
    };
    if let Some(existing) = existing {
        let same_payload = existing.owner_device_id == owner
            && existing.bot_id == bot_id
            && existing.skill_id == skill_id
            && existing.version == version
            && existing.content_hash == request.content_hash
            && existing.input_schema_hash == input_schema_hash
            && existing.input_schema_json == input_schema_json
            && existing.inputs_json == inputs_json
            && existing.working_directory == working_directory
            && existing.provider == FIXTURE_PROVIDER
            && existing.execution_kind == FIXTURE_EXECUTION_KIND;
        if !same_payload {
            return (
                StatusCode::CONFLICT,
                "client request is already bound to another fixture test",
            )
                .into_response();
        }
        return (StatusCode::OK, Json(fixture_receipt(existing))).into_response();
    }

    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let (title, date) = match validate_fixture_inputs(&request.input_schema, &request.inputs) {
        Ok(value) => value,
        Err(reason) => {
            let receipt = match persist_fixture_failure(
                &state,
                NewSkillFixtureRun {
                    id: uuid::Uuid::new_v4().to_string(),
                    client_request_id: request.client_request_id,
                    owner_device_id: owner,
                    bot_id,
                    skill_id,
                    version,
                    content_hash: request.content_hash,
                    input_schema_hash,
                    input_schema_json,
                    inputs_json,
                    working_directory,
                    provider: FIXTURE_PROVIDER.into(),
                    execution_kind: FIXTURE_EXECUTION_KIND.into(),
                    status: "failed".into(),
                    verification_state: "testFailed".into(),
                    artifact_path: None,
                    artifact_hash: None,
                    artifact_bytes: 0,
                    evidence_json: serde_json::json!({"kind":"deterministicFixture","verified":false,"checks":[]}).to_string(),
                    failure_reason: Some(reason),
                    created_at: now.clone(),
                    completed_at: now,
                },
            )
            .await
            {
                Ok(receipt) => receipt,
                Err(response) => return response,
            };
            return (StatusCode::CREATED, Json(fixture_receipt(receipt))).into_response();
        }
    };
    let expected = serde_json::json!({"title": title, "date": date});
    let artifact = serde_json::json!({
        "format": "wonder.deterministic-preview.v1",
        "fixture": "preview-file",
        "skillId": skill_id,
        "version": version,
        "contentHash": request.content_hash,
        "workingDirectory": working_directory,
        "expected": expected,
        "actual": expected,
        "preview": {"title": title, "date": date}
    });
    let workspace = bot.workspace_path.clone();
    let artifact_bot_id = bot_id.clone();
    let artifact_request_id = request.client_request_id.clone();
    let artifact_title = title.clone();
    let artifact_date = date.clone();
    let artifact_result = tokio::task::spawn_blocking(move || {
        write_fixture_artifact(
            &workspace,
            &artifact_bot_id,
            &artifact_request_id,
            &artifact,
            &artifact_title,
            &artifact_date,
        )
    })
    .await;
    let (artifact_path, artifact_hash, artifact_bytes) = match artifact_result {
        Ok(Ok(value)) => value,
        _ => {
            let receipt = match persist_fixture_failure(
                &state,
                NewSkillFixtureRun {
                    id: uuid::Uuid::new_v4().to_string(),
                    client_request_id: request.client_request_id,
                    owner_device_id: owner,
                    bot_id,
                    skill_id,
                    version,
                    content_hash: request.content_hash,
                    input_schema_hash,
                    input_schema_json,
                    inputs_json,
                    working_directory,
                    provider: FIXTURE_PROVIDER.into(),
                    execution_kind: FIXTURE_EXECUTION_KIND.into(),
                    status: "failed".into(),
                    verification_state: "testFailed".into(),
                    artifact_path: None,
                    artifact_hash: None,
                    artifact_bytes: 0,
                    evidence_json: serde_json::json!({"kind":"deterministicFixture","verified":false,"checks":["artifact contents"]}).to_string(),
                    failure_reason: Some("The preview artifact could not be created or verified.".into()),
                    created_at: now.clone(),
                    completed_at: now,
                },
            )
            .await
            {
                Ok(receipt) => receipt,
                Err(response) => return response,
            };
            return (StatusCode::CREATED, Json(fixture_receipt(receipt))).into_response();
        }
    };
    let receipt = match state
        .store
        .insert_skill_fixture_run(&NewSkillFixtureRun {
            id: uuid::Uuid::new_v4().to_string(),
            client_request_id: request.client_request_id,
            owner_device_id: owner,
            bot_id,
            skill_id,
            version,
            content_hash: request.content_hash,
            input_schema_hash,
            input_schema_json,
            inputs_json,
            working_directory,
            provider: FIXTURE_PROVIDER.into(),
            execution_kind: FIXTURE_EXECUTION_KIND.into(),
            status: "succeeded".into(),
            verification_state: "fixtureVerified".into(),
            artifact_path: Some(artifact_path),
            artifact_hash: Some(artifact_hash),
            artifact_bytes,
            evidence_json: serde_json::json!({"kind":"deterministicFixture","verified":true,"checks":["title","date","artifact contents"]}).to_string(),
            failure_reason: None,
            created_at: now.clone(),
            completed_at: now,
        })
        .await
    {
        Ok(reservation) => reservation,
        Err(sqlx::Error::Protocol(message)) if message.contains("payload mismatch") => {
            return (
                StatusCode::CONFLICT,
                "client request is already bound to another fixture test",
            )
                .into_response()
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "The fixture test receipt could not be saved.",
            )
                .into_response()
        }
    };
    (
        if receipt.created {
            StatusCode::CREATED
        } else {
            StatusCode::OK
        },
        Json(fixture_receipt(receipt.run)),
    )
        .into_response()
}

pub(crate) async fn read_fixture(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path((bot_id, skill_id, request_id)): Path<(String, String, String)>,
) -> Response {
    let owner = match owner_device(authenticated, local) {
        Ok(owner) => owner,
        Err(response) => return response,
    };
    if uuid::Uuid::parse_str(&request_id).is_err() {
        return (StatusCode::BAD_REQUEST, "requestId must be a UUID").into_response();
    }
    if let Err(response) = owned_bot(&state, &bot_id, None).await {
        return response;
    }
    match state.store.skill_fixture_run_by_request(&request_id).await {
        Ok(Some(run))
            if run.owner_device_id == owner && run.bot_id == bot_id && run.skill_id == skill_id =>
        {
            Json(fixture_receipt(run)).into_response()
        }
        Ok(Some(_)) => StatusCode::NOT_FOUND.into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "Fixture test receipts are unavailable.",
        )
            .into_response(),
    }
}

pub(crate) async fn get_skill(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path((bot_id, skill_id)): Path<(String, String)>,
) -> Response {
    if let Err(response) = owner_device(authenticated, local) {
        return response;
    }
    if let Err(response) = owned_bot(&state, &bot_id, None).await {
        return response;
    }
    match state.store.bot_skill(&bot_id, &skill_id).await {
        Ok(Some(skill)) => match state.store.bot_skill_versions(&bot_id, &skill_id).await {
            Ok(versions) => Json(skill_response(skill, Some(versions))).into_response(),
            Err(_) => (
                StatusCode::SERVICE_UNAVAILABLE,
                "Private skill versions are unavailable.",
            )
                .into_response(),
        },
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "Private skill is unavailable.",
        )
            .into_response(),
    }
}

pub(crate) async fn activate_skill_version(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path((bot_id, skill_id)): Path<(String, String)>,
    Json(request): Json<ActivateVersionRequest>,
) -> Response {
    if let Err(response) = owner_device(authenticated, local) {
        return response;
    }
    let bot = match owned_bot(&state, &bot_id, None).await {
        Ok(bot) => bot,
        Err(response) => return response,
    };
    let skill = match state.store.bot_skill(&bot_id, &skill_id).await {
        Ok(Some(skill)) if skill.state != "archived" => skill,
        Ok(_) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Private skill is unavailable.",
            )
                .into_response()
        }
    };
    let version = match state.store.bot_skill_versions(&bot_id, &skill_id).await {
        Ok(versions) => versions
            .into_iter()
            .find(|version| version.version == request.version),
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Private skill versions are unavailable.",
            )
                .into_response()
        }
    };
    let Some(version) = version else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let workspace = bot.workspace_path.clone();
    let file_skill_id = skill.id.clone();
    let version_key = version.save_request_id.clone();
    let slug = skill.slug.clone();
    let publication = tokio::task::spawn_blocking(move || {
        activate_skill_file(&workspace, &file_skill_id, &version_key, &slug)
    })
    .await;
    if !matches!(publication, Ok(Ok(()))) {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "The selected private skill version could not be published.",
        )
            .into_response();
    }
    match state
        .store
        .set_active_bot_skill_version(
            &bot_id,
            &skill_id,
            request.version,
            &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        )
        .await
    {
        Ok(Some(skill)) => Json(skill_response(skill, None)).into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "The selected private skill version could not be activated.",
        )
            .into_response(),
    }
}

pub(crate) async fn archive_skill(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path((bot_id, skill_id)): Path<(String, String)>,
) -> Response {
    if let Err(response) = owner_device(authenticated, local) {
        return response;
    }
    let bot = match owned_bot(&state, &bot_id, None).await {
        Ok(bot) => bot,
        Err(response) => return response,
    };
    let skill = match state.store.bot_skill(&bot_id, &skill_id).await {
        Ok(Some(skill)) => skill,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Private skill is unavailable.",
            )
                .into_response()
        }
    };
    let workspace = bot.workspace_path.clone();
    let slug = skill.slug.clone();
    let archived = tokio::task::spawn_blocking(move || archive_skill_file(&workspace, &slug)).await;
    if !matches!(archived, Ok(Ok(()))) {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "The private skill could not be removed from discovery.",
        )
            .into_response();
    }
    match state
        .store
        .archive_bot_skill(
            &bot_id,
            &skill_id,
            &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        )
        .await
    {
        Ok(Some(_)) => StatusCode::NO_CONTENT.into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "The private skill could not be archived.",
        )
            .into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_control_lease_binding_is_rejected() {
        let computer_session = StoredComputerSession {
            id: "computer-session".into(),
            client_request_id: "session-request".into(),
            owner_device_id: "phone".into(),
            host_installation_id: "host".into(),
            conversation_id: "conversation".into(),
            generation: 7,
            state: "live".into(),
            source_id: Some("source-7".into()),
            source_name: Some("Mac display".into()),
            source_kind: Some("screen".into()),
            source_width: Some(1920),
            source_height: Some(1080),
            source_scale: Some(2.0),
            crop_json: None,
            geometry_revision: 11,
            failure_reason: None,
            created_at: "2026-09-14T12:00:00.000Z".into(),
            updated_at: "2026-09-14T12:00:00.000Z".into(),
            last_state_at: "2026-09-14T12:00:00.000Z".into(),
            ended_at: None,
        };
        let lease = StoredComputerControlLease {
            id: "lease".into(),
            client_request_id: "lease-request".into(),
            session_id: "computer-session".into(),
            owner_device_id: "phone".into(),
            host_installation_id: "host".into(),
            conversation_id: "conversation".into(),
            session_generation: 7,
            source_id: Some("source-7".into()),
            geometry_revision: 11,
            status: "active".into(),
            last_sequence: 3,
            acquired_at: "2026-09-14T12:00:00.000Z".into(),
            updated_at: "2026-09-14T12:00:00.000Z".into(),
            expires_at: "2026-09-14T12:10:00.000Z".into(),
            released_at: None,
        };
        let matches = |lease: &StoredComputerControlLease| {
            lease_matches_current_session(
                &computer_session,
                lease,
                "phone",
                "host",
                "conversation",
                "lease",
                "2026-09-14T12:01:00.000Z",
            )
        };

        assert!(matches(&lease));

        let mut stale_generation = lease.clone();
        stale_generation.session_generation = 6;
        assert!(!matches(&stale_generation));

        let mut stale_source = lease.clone();
        stale_source.source_id = Some("source-6".into());
        assert!(!matches(&stale_source));

        let mut stale_geometry = lease;
        stale_geometry.geometry_revision = 10;
        assert!(!matches(&stale_geometry));
    }

    #[test]
    fn idempotent_start_requires_an_exact_authenticated_binding() {
        let existing = StoredTeachingSession {
            id: "teaching-session".into(),
            client_request_id: "request".into(),
            owner_device_id: "phone".into(),
            host_installation_id: "host".into(),
            bot_id: "bot".into(),
            conversation_id: "conversation".into(),
            computer_session_id: Some("computer-session".into()),
            control_lease_id: Some("lease".into()),
            state: "expired".into(),
            capture_scope: CAPTURE_SCOPE.into(),
            capture_provider: CAPTURE_PROVIDER.into(),
            outcome: "Create a preview".into(),
            name: None,
            description: None,
            goal: None,
            input_schema_json: None,
            prerequisites: None,
            steps: None,
            result_checks: None,
            failure_reason: Some(wonder_store::TEACHING_EXPIRED_REASON.into()),
            revision: 2,
            event_count: 0,
            evidence_bytes: 0,
            content_hash: None,
            created_at: "created".into(),
            updated_at: "updated".into(),
            started_at: Some("started".into()),
            ended_at: Some("ended".into()),
            expires_at: Some("expired".into()),
        };
        let request = StartRequest {
            client_request_id: "request".into(),
            conversation_id: "conversation".into(),
            computer_session_id: "computer-session".into(),
            control_lease_id: "lease".into(),
            capture_scope: CAPTURE_SCOPE.into(),
            outcome: "Create a preview".into(),
        };
        assert!(start_matches_existing_session(&existing, "bot", &request));

        let mut conflicting = request;
        conflicting.control_lease_id = "different-lease".into();
        assert!(!start_matches_existing_session(
            &existing,
            "bot",
            &conflicting
        ));
    }

    #[test]
    fn capture_scope_accepts_only_authenticated_remote_control() {
        assert!(capture_scope(CAPTURE_SCOPE));
        assert!(!capture_scope("authenticated-remote-control-v1"));
        assert!(!capture_scope("foreground-window"));
        assert!(!capture_scope("authenticated_remote_control"));
    }

    #[test]
    fn slug_rejects_traversal_and_normalizes_names() {
        assert_eq!(
            slug_for_name("Preview file / title"),
            Some("preview-file-title".into())
        );
        assert!(!valid_slug("../outside"));
        assert!(!valid_slug("skill--name"));
    }

    #[test]
    fn rendered_skill_hash_is_stable_and_does_not_claim_replay() {
        let request = ReviewRequest {
            expected_revision: 1,
            name: "Preview file".into(),
            description: "Create a preview".into(),
            goal: "Save it".into(),
            input_schema: serde_json::json!({"title":{"type":"string"}}),
            prerequisites: "Preview app".into(),
            steps: "Open the app.".into(),
            result_checks: "The file exists.".into(),
        };
        let input = serde_json::to_string(&request.input_schema).unwrap();
        let markdown = render_markdown(&request, &input);
        assert_eq!(hash(&markdown).len(), 64);
        assert!(!markdown.contains("Replay verified"));
    }

    #[test]
    fn private_skill_publication_is_versioned_idempotent_and_archivable() {
        let workspace = tempfile::tempdir().unwrap();
        let skill_id = uuid::Uuid::new_v4().to_string();
        let version_key = uuid::Uuid::new_v4().to_string();
        let markdown = "---\nname: Preview\ndescription: Create a preview\n---\n\n# Preview\n";
        publish_skill_files(
            workspace.path().to_str().unwrap(),
            &skill_id,
            &version_key,
            "preview-file",
            markdown,
        )
        .unwrap();
        publish_skill_files(
            workspace.path().to_str().unwrap(),
            &skill_id,
            &version_key,
            "preview-file",
            markdown,
        )
        .unwrap();
        let active = workspace
            .path()
            .join(".agents/skills/preview-file/SKILL.md");
        let immutable = workspace
            .path()
            .join(".agents/skills/.wonder-versions")
            .join(&skill_id)
            .join(&version_key)
            .join("SKILL.md");
        assert_eq!(fs::read_to_string(&active).unwrap(), markdown);
        assert_eq!(fs::read_to_string(&immutable).unwrap(), markdown);
        fs::write(&active, "stale").unwrap();
        activate_skill_file(
            workspace.path().to_str().unwrap(),
            &skill_id,
            &version_key,
            "preview-file",
        )
        .unwrap();
        assert_eq!(fs::read_to_string(&active).unwrap(), markdown);
        archive_skill_file(workspace.path().to_str().unwrap(), "preview-file").unwrap();
        archive_skill_file(workspace.path().to_str().unwrap(), "preview-file").unwrap();
        assert!(!active.exists());
        assert!(immutable.exists());
    }

    #[cfg(unix)]
    #[test]
    fn private_skill_publication_rejects_symlinked_storage() {
        use std::os::unix::fs::symlink;
        let workspace = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        symlink(outside.path(), workspace.path().join(".agents")).unwrap();
        assert!(publish_skill_files(
            workspace.path().to_str().unwrap(),
            &uuid::Uuid::new_v4().to_string(),
            &uuid::Uuid::new_v4().to_string(),
            "preview-file",
            "safe",
        )
        .is_err());
        assert!(fs::read_dir(outside.path()).unwrap().next().is_none());
    }

    #[test]
    fn fixture_inputs_are_typed_and_changed_values_verify_artifact_contents() {
        let schema = serde_json::json!({
            "title": {"type": "string"},
            "date": {"type": "string", "format": "date"}
        });
        let first = serde_json::json!({"title":"First preview","date":"2026-09-12"});
        let second = serde_json::json!({"title":"Changed preview","date":"2026-09-13"});
        assert_eq!(
            validate_fixture_inputs(&schema, &first).unwrap(),
            ("First preview".to_owned(), "2026-09-12".to_owned())
        );
        assert_eq!(
            validate_fixture_inputs(&schema, &second).unwrap(),
            ("Changed preview".to_owned(), "2026-09-13".to_owned())
        );
        assert!(validate_fixture_inputs(&schema, &serde_json::json!({"title":"x"})).is_err());
        assert!(validate_fixture_inputs(
            &schema,
            &serde_json::json!({"title":"x","date":"2026-02-30"})
        )
        .is_err());
        assert_ne!(
            canonical_json(&first).unwrap(),
            canonical_json(&second).unwrap()
        );
    }

    #[test]
    fn fixture_cwd_rejects_traversal_and_symlinks() {
        let workspace = tempfile::tempdir().unwrap();
        fs::create_dir(workspace.path().join("changed-cwd")).unwrap();
        assert_eq!(
            safe_fixture_working_directory(
                workspace.path().to_str().unwrap(),
                workspace.path().to_str().unwrap(),
                Some("changed-cwd")
            )
            .unwrap(),
            fs::canonicalize(workspace.path().join("changed-cwd"))
                .unwrap()
                .to_string_lossy()
                .into_owned()
        );
        let external = tempfile::tempdir().unwrap();
        let external = fs::canonicalize(external.path()).unwrap();
        assert_eq!(
            safe_fixture_working_directory(
                workspace.path().to_str().unwrap(),
                external.to_str().unwrap(),
                None
            )
            .unwrap(),
            external.to_string_lossy().into_owned()
        );
        assert!(safe_fixture_working_directory(
            workspace.path().to_str().unwrap(),
            workspace.path().to_str().unwrap(),
            Some("../outside")
        )
        .is_err());
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(workspace.path(), workspace.path().join("linked-cwd"))
                .unwrap();
            assert!(safe_fixture_working_directory(
                workspace.path().to_str().unwrap(),
                workspace.path().to_str().unwrap(),
                Some("linked-cwd")
            )
            .is_err());
        }
    }

    #[test]
    fn fixture_artifact_is_private_and_never_claims_replay() {
        let workspace = tempfile::tempdir().unwrap();
        let artifact = serde_json::json!({
            "format": "wonder.deterministic-preview.v1",
            "fixture": "preview-file",
            "skillId": "skill",
            "version": 1,
            "contentHash": "hash",
            "workingDirectory": "changed-cwd",
            "expected": {"title":"Changed","date":"2026-09-13"},
            "actual": {"title":"Changed","date":"2026-09-13"},
            "preview": {"title":"Changed","date":"2026-09-13"}
        });
        let (path, artifact_hash, bytes) = write_fixture_artifact(
            workspace.path().to_str().unwrap(),
            "bot",
            "11111111-1111-4111-8111-111111111111",
            &artifact,
            "Changed",
            "2026-09-13",
        )
        .unwrap();
        assert!(path.starts_with(".wonder/fixture-runs/bot/"));
        assert_eq!(artifact_hash.len(), 64);
        assert!(bytes < MAX_FIXTURE_ARTIFACT_BYTES as u64);
        let contents = fs::read_to_string(workspace.path().join(path)).unwrap();
        assert!(!contents.contains("replayVerified"));
    }
}
