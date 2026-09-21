use super::*;
use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};

const UNAVAILABLE_REASON: &str = "Live computer viewing is unavailable on this Mac. Update Wonder when a configured media provider is available.";
const UNAVAILABLE_ACTION: &str = "update-host";
const CONTROL_UNAVAILABLE_REASON: &str =
    "Take control is unavailable until a verified computer provider is configured on this Mac.";
const CONTROL_AVAILABLE_REASON: &str =
    "Take control starts when paired-device control is enabled in Wonder Settings on your Mac.";
const CONTROL_DISABLED_REASON: &str =
    "Control is disabled in Wonder Settings. Turn on Allow control from paired devices on your Mac, then try again.";
const CONTROL_HEARTBEAT_SECONDS: u64 = 3;
const CONTROL_EXPIRY_SECONDS: i64 = 10;
const CONTROL_CONSENT_TIMEOUT_SECONDS: u64 = 120;
const CONTROL_CONSENT_RESERVATION_SECONDS: i64 =
    CONTROL_CONSENT_TIMEOUT_SECONDS as i64 + CONTROL_EXPIRY_SECONDS;
const CAPTURE_AVAILABLE_REASON: &str = "Live computer viewing is available on this Mac.";
const MAX_INPUT_ACTIONS: usize = 32;
const MAX_INPUT_TEXT: usize = 4_096;
const MAX_CLIPBOARD_TEXT: usize = 8_192;
const MAX_INPUT_BATCH_BYTES: usize = 16 * 1024;
const MAX_SIGNALING_SDP_BYTES: usize = 64 * 1024;
const MAX_SIGNALING_CANDIDATE_BYTES: usize = 4 * 1024;
const MAX_SIGNALING_CANDIDATES: usize = 128;
const MAX_SIGNALING_CANDIDATE_BATCH: usize = 32;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StartRequest {
    client_request_id: String,
    conversation_id: String,
    host_installation_id: String,
    #[serde(default)]
    generation: Option<u64>,
    #[serde(default)]
    source: Option<SourceRequest>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SourceRequest {
    id: Option<String>,
    name: Option<String>,
    kind: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    scale: Option<f64>,
    crop: Option<CropRequest>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct CropRequest {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GenerationQuery {
    generation: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AdmissionRequest {
    generation: u64,
    role: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignalingBinding {
    generation: u64,
    conversation_id: String,
    host_installation_id: String,
    #[serde(default)]
    peer_revision: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SignalingPollRequest {
    #[serde(flatten)]
    binding: SignalingBinding,
    #[serde(default)]
    cursor: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SignalingAnswerRequest {
    #[serde(flatten)]
    binding: SignalingBinding,
    #[serde(rename = "type")]
    kind: String,
    sdp: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SignalingCandidateRequest {
    #[serde(flatten)]
    binding: SignalingBinding,
    sequence: u64,
    candidate: String,
    sdp_mid: Option<String>,
    sdp_m_line_index: u32,
    username_fragment: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SignalingCloseRequest {
    #[serde(flatten)]
    binding: SignalingBinding,
    #[serde(default)]
    reason: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct SignalingDescription {
    #[serde(rename = "type")]
    kind: String,
    sdp: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct SignalingCandidate {
    sequence: u64,
    candidate: String,
    sdp_mid: Option<String>,
    sdp_m_line_index: u32,
    username_fragment: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct SignalingIceServer {
    urls: Vec<String>,
    username: Option<String>,
    credential: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SignalingResponse {
    session_id: String,
    generation: u64,
    peer_revision: Option<String>,
    state: String,
    capture_state: String,
    peer_state: String,
    offer: Option<SignalingDescription>,
    candidates: Vec<SignalingCandidate>,
    cursor: u64,
    next_cursor: u64,
    failure_reason: Option<String>,
    ice_servers: Vec<SignalingIceServer>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AcquireControlRequest {
    client_request_id: String,
    generation: u64,
    geometry_revision: u64,
    source_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LeaseBindingRequest {
    lease_id: String,
    generation: u64,
    geometry_revision: u64,
    source_id: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct InputBatchRequest {
    lease_id: String,
    generation: u64,
    geometry_revision: u64,
    source_id: Option<String>,
    sequence: u64,
    actions: Vec<InputAction>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum InputAction {
    Pointer {
        x: f64,
        y: f64,
        phase: String,
        button: Option<String>,
    },
    Scroll {
        delta_x: f64,
        delta_y: f64,
    },
    Key {
        key: String,
        phase: String,
        modifiers: u32,
    },
    Text {
        text: String,
    },
    Clipboard {
        operation: String,
        text: Option<String>,
    },
    ReleaseAll,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Capability {
    available: bool,
    action: &'static str,
    reason: &'static str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ControlCapability {
    available: bool,
    action: &'static str,
    reason: &'static str,
    heartbeat_interval_seconds: u64,
    lease_expiry_seconds: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Source {
    id: Option<String>,
    name: Option<String>,
    kind: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    scale: Option<f64>,
    crop: Option<CropRequest>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionResponse {
    id: String,
    client_request_id: String,
    owner_device_id: String,
    host_installation_id: String,
    conversation_id: String,
    generation: u64,
    state: String,
    source: Source,
    geometry_revision: u64,
    failure_reason: Option<String>,
    created_at: String,
    updated_at: String,
    last_state_at: String,
    ended_at: Option<String>,
    capability: Capability,
    control: ControlCapability,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AdmissionResponse {
    session: SessionResponse,
    role: String,
    granted: bool,
    admission: Option<serde_json::Value>,
    capability: Capability,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LeaseResponse {
    id: String,
    session_id: String,
    owner_device_id: String,
    host_installation_id: String,
    conversation_id: String,
    generation: u64,
    source_id: Option<String>,
    geometry_revision: u64,
    status: String,
    last_sequence: u64,
    acquired_at: String,
    updated_at: String,
    expires_at: String,
    released_at: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ControlActionResponse {
    granted: bool,
    acknowledged: bool,
    status: String,
    reason: String,
    lease: Option<LeaseResponse>,
    control: ControlCapability,
    #[serde(skip_serializing_if = "Option::is_none")]
    clipboard_text: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
struct AcceptedInputRecovery {
    acknowledged: bool,
    status: &'static str,
    reason: String,
}

fn accepted_input_recovery() -> AcceptedInputRecovery {
    AcceptedInputRecovery {
        acknowledged: true,
        status: "stale",
        reason: "The input reached the Mac, but control ended because Wonder could not save its receipt. Do not retry this action.".into(),
    }
}

const ACCEPTED_INPUT_TEACHING_FAILURE_REASON: &str =
    "Teaching stopped because the input reached the Mac, but Wonder could not save its durable receipt. The action must not be retried; teaching evidence was not confirmed saved.";

pub(crate) fn provider_available(state: &AppState) -> bool {
    state.computer_use_enabled
        && state.computer_use_bin.as_ref().is_some_and(|path| {
            std::fs::metadata(path)
                .map(|metadata| metadata.is_file() && is_executable(&metadata))
                .unwrap_or(false)
        })
}

#[cfg(unix)]
fn is_executable(metadata: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(metadata: &std::fs::Metadata) -> bool {
    metadata.is_file()
}

fn capability(state: &AppState) -> Capability {
    if provider_available(state) {
        Capability {
            available: true,
            action: "retry",
            reason: CAPTURE_AVAILABLE_REASON,
        }
    } else {
        Capability {
            available: false,
            action: UNAVAILABLE_ACTION,
            reason: UNAVAILABLE_REASON,
        }
    }
}

fn control_capability_for(available: bool) -> ControlCapability {
    ControlCapability {
        available,
        action: if available {
            "none"
        } else {
            UNAVAILABLE_ACTION
        },
        reason: if available {
            CONTROL_AVAILABLE_REASON
        } else {
            CONTROL_UNAVAILABLE_REASON
        },
        heartbeat_interval_seconds: CONTROL_HEARTBEAT_SECONDS,
        lease_expiry_seconds: CONTROL_EXPIRY_SECONDS as u64,
    }
}

fn control_capability(state: &AppState) -> ControlCapability {
    control_capability_for(state.computer_supervisor.control_capable())
}

fn lease_response(lease: StoredComputerControlLease) -> LeaseResponse {
    LeaseResponse {
        id: lease.id,
        session_id: lease.session_id,
        owner_device_id: lease.owner_device_id,
        host_installation_id: lease.host_installation_id,
        conversation_id: lease.conversation_id,
        generation: lease.session_generation,
        source_id: lease.source_id,
        geometry_revision: lease.geometry_revision,
        status: lease.status,
        last_sequence: lease.last_sequence,
        acquired_at: lease.acquired_at,
        updated_at: lease.updated_at,
        expires_at: lease.expires_at,
        released_at: lease.released_at,
    }
}

fn control_response(
    state: &AppState,
    granted: bool,
    acknowledged: bool,
    status: impl Into<String>,
    reason: impl Into<String>,
    lease: Option<StoredComputerControlLease>,
    clipboard_text: Option<String>,
) -> ControlActionResponse {
    ControlActionResponse {
        granted,
        acknowledged,
        status: status.into(),
        reason: reason.into(),
        lease: lease.map(lease_response),
        control: control_capability(state),
        clipboard_text,
    }
}

fn response(state: &AppState, session: StoredComputerSession) -> SessionResponse {
    SessionResponse {
        id: session.id,
        client_request_id: session.client_request_id,
        owner_device_id: session.owner_device_id,
        host_installation_id: session.host_installation_id,
        conversation_id: session.conversation_id,
        generation: session.generation,
        state: session.state,
        source: Source {
            id: session.source_id,
            name: session.source_name,
            kind: session.source_kind,
            width: session.source_width,
            height: session.source_height,
            scale: session.source_scale,
            crop: session
                .crop_json
                .and_then(|value| serde_json::from_str(&value).ok()),
        },
        geometry_revision: session.geometry_revision,
        failure_reason: session.failure_reason,
        created_at: session.created_at,
        updated_at: session.updated_at,
        last_state_at: session.last_state_at,
        ended_at: session.ended_at,
        capability: capability(state),
        control: control_capability(state),
    }
}

fn validate_text(value: &str, max: usize) -> bool {
    !value.trim().is_empty() && value.chars().count() <= max && !value.chars().any(char::is_control)
}

fn validate_input_action(action: &InputAction) -> bool {
    match action {
        InputAction::Pointer {
            x,
            y,
            phase,
            button,
        } => {
            x.is_finite()
                && y.is_finite()
                && (0.0..=1.0).contains(x)
                && (0.0..=1.0).contains(y)
                && matches!(phase.as_str(), "move" | "down" | "up")
                && button
                    .as_deref()
                    .is_none_or(|value| matches!(value, "left" | "right" | "middle"))
                && (phase == "move" || button.is_some())
        }
        InputAction::Scroll { delta_x, delta_y } => {
            delta_x.is_finite()
                && delta_y.is_finite()
                && delta_x.abs() <= 4_096.0
                && delta_y.abs() <= 4_096.0
        }
        InputAction::Key {
            key,
            phase,
            modifiers,
        } => {
            validate_text(key, 32)
                && matches!(phase.as_str(), "down" | "up" | "press")
                && (*modifiers & !0b1_1111) == 0
        }
        InputAction::Text { text } => {
            !text.is_empty()
                && text.chars().count() <= MAX_INPUT_TEXT
                && text
                    .chars()
                    .all(|character| !character.is_control() || matches!(character, '\n' | '\t'))
        }
        InputAction::Clipboard { operation, text } => {
            matches!(operation.as_str(), "copyToPhone" | "pasteFromPhone")
                && text.as_ref().is_none_or(|value| {
                    value.chars().count() <= MAX_CLIPBOARD_TEXT
                        && value
                            .chars()
                            .all(|ch| !ch.is_control() || matches!(ch, '\n' | '\t'))
                })
                && ((operation == "copyToPhone" && text.is_none())
                    || (operation == "pasteFromPhone" && text.is_some()))
        }
        InputAction::ReleaseAll => true,
    }
}

fn validate_input_batch(request: &InputBatchRequest) -> Result<(), &'static str> {
    if request.lease_id.trim().is_empty()
        || request.lease_id.chars().count() > 128
        || request.generation == 0
        || request.sequence == 0
        || request
            .source_id
            .as_deref()
            .is_some_and(|value| !validate_text(value, 160))
        || request.actions.is_empty()
        || request.actions.len() > MAX_INPUT_ACTIONS
        || (request.actions.len() != 1
            && request.actions.iter().any(|action| {
                matches!(
                    action,
                    InputAction::Clipboard { operation, .. } if operation == "pasteFromPhone"
                )
            }))
        || request
            .actions
            .iter()
            .any(|action| !validate_input_action(action))
        || serde_json::to_vec(request)
            .map(|bytes| bytes.len() > MAX_INPUT_BATCH_BYTES)
            .unwrap_or(true)
    {
        return Err("input batch is invalid");
    }
    Ok(())
}

fn sanitized_teaching_events(
    actions: &[InputAction],
    sequence: u64,
    now: &str,
) -> Vec<TeachingEventCreate> {
    actions
        .iter()
        .enumerate()
        .filter_map(|(action_index, action)| {
            let payload = match action {
                InputAction::Pointer {
                    x,
                    y,
                    phase,
                    button,
                } => serde_json::json!({
                    "kind": "pointer",
                    "x": (x * 10_000.0).round() / 10_000.0,
                    "y": (y * 10_000.0).round() / 10_000.0,
                    "phase": phase,
                    "button": button,
                }),
                InputAction::Scroll { delta_x, delta_y } => serde_json::json!({
                    "kind": "scroll",
                    "deltaX": delta_x,
                    "deltaY": delta_y,
                }),
                InputAction::Key {
                    key,
                    phase,
                    modifiers,
                } => {
                    let named = matches!(
                        key.as_str(),
                        "return"
                            | "tab"
                            | "escape"
                            | "backspace"
                            | "delete"
                            | "left"
                            | "right"
                            | "up"
                            | "down"
                            | "home"
                            | "end"
                            | "pageup"
                            | "pagedown"
                    );
                    serde_json::json!({
                        "kind": "key",
                        "key": if named { serde_json::json!(key) } else { serde_json::json!("redacted") },
                        "phase": phase,
                        "modifiers": modifiers,
                        "redacted": !named,
                    })
                }
                InputAction::Text { text } => serde_json::json!({
                    "kind": "text",
                    "characterCount": text.chars().count(),
                    "redacted": true,
                }),
                InputAction::Clipboard { operation, text } => serde_json::json!({
                    "kind": "clipboard",
                    "operation": operation,
                    "characterCount": text.as_deref().map(|value| value.chars().count()).unwrap_or(0),
                    "redacted": true,
                }),
                InputAction::ReleaseAll => return None,
            };
            let event_json = serde_json::to_string(&payload).ok()?;
            Some(TeachingEventCreate {
                control_sequence: sequence,
                action_index: action_index as u64,
                payload_bytes: event_json.len() as u64,
                event_json,
                created_at: now.to_owned(),
            })
        })
        .collect()
}

fn validate_binding_request(request: &LeaseBindingRequest) -> bool {
    validate_text(&request.lease_id, 128)
        && request.generation > 0
        && request
            .source_id
            .as_deref()
            .is_none_or(|value| validate_text(value, 160))
}

fn session_binding_matches(
    session: &StoredComputerSession,
    generation: u64,
    geometry_revision: u64,
    source_id: Option<&str>,
) -> bool {
    session.generation == generation
        && session.geometry_revision == geometry_revision
        && session.source_id.as_deref() == source_id
}

fn lease_matches_request(
    lease: &StoredComputerControlLease,
    state: &AppState,
    session: &StoredComputerSession,
    request: &AcquireControlRequest,
) -> bool {
    lease.owner_device_id == session.owner_device_id
        && lease.host_installation_id == state.host_installation_id
        && lease.session_id == session.id
        && lease.conversation_id == session.conversation_id
        && lease.session_generation == request.generation
        && lease.geometry_revision == request.geometry_revision
        && lease.source_id.as_deref() == request.source_id.as_deref()
        && lease.client_request_id == request.client_request_id
}

fn control_identity_params(
    session: &StoredComputerSession,
    lease: &StoredComputerControlLease,
) -> serde_json::Value {
    serde_json::json!({
        "sessionID": session.id,
        "generation": lease.session_generation,
        "leaseID": lease.id,
        "requestID": lease.client_request_id,
        "geometryRevision": lease.geometry_revision,
        "sourceID": lease.source_id,
    })
}

fn control_unavailable(state: &AppState, session: StoredComputerSession) -> Response {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(control_response(
            state,
            false,
            false,
            "unavailable",
            session
                .failure_reason
                .unwrap_or_else(|| CONTROL_UNAVAILABLE_REASON.into()),
            None,
            None,
        )),
    )
        .into_response()
}

#[allow(clippy::type_complexity)]
fn source_fields(
    source: Option<SourceRequest>,
) -> Result<
    (
        Option<String>,
        Option<String>,
        Option<String>,
        Option<u32>,
        Option<u32>,
        Option<f64>,
        Option<String>,
    ),
    &'static str,
> {
    let Some(source) = source else {
        return Ok((None, None, None, None, None, None, None));
    };
    for value in [&source.id, &source.name, &source.kind]
        .into_iter()
        .flatten()
    {
        if !validate_text(value, 160) {
            return Err("source metadata is invalid");
        }
    }
    if source
        .width
        .is_some_and(|value| !(1..=16_384).contains(&value))
        || source
            .height
            .is_some_and(|value| !(1..=16_384).contains(&value))
        || source
            .scale
            .is_some_and(|value| !value.is_finite() || !(0.1..=8.0).contains(&value))
    {
        return Err("source geometry is invalid");
    }
    let crop_json = source
        .crop
        .map(|value| {
            if [value.x, value.y, value.width, value.height]
                .into_iter()
                .any(|coordinate| {
                    !coordinate.is_finite() || !(0.0..=16_384.0).contains(&coordinate)
                })
                || value.width <= 0.0
                || value.height <= 0.0
            {
                return Err("source crop is invalid");
            }
            serde_json::to_string(&value).map_err(|_| "source crop is invalid")
        })
        .transpose()?;
    if crop_json.as_ref().is_some_and(|value| value.len() > 2048) {
        return Err("source crop is too large");
    }
    Ok((
        source.id,
        source.name,
        source.kind,
        source.width,
        source.height,
        source.scale,
        crop_json,
    ))
}

#[allow(clippy::result_large_err)]
async fn owner_device(
    authenticated: Option<Extension<AuthenticatedDevice>>,
) -> Result<AuthenticatedDevice, Response> {
    authenticated
        .map(|Extension(device)| device)
        .ok_or_else(|| (StatusCode::UNAUTHORIZED, "paired device required").into_response())
}

#[allow(clippy::result_large_err)]
async fn owned_session(
    state: &AppState,
    id: &str,
    device_id: &str,
) -> Result<StoredComputerSession, Response> {
    let session = state
        .store
        .computer_session(id)
        .await
        .map_err(|_| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "computer session unavailable",
            )
                .into_response()
        })?
        .ok_or_else(|| StatusCode::NOT_FOUND.into_response())?;
    if session.owner_device_id != device_id
        || session.host_installation_id != state.host_installation_id
    {
        return Err(StatusCode::NOT_FOUND.into_response());
    }
    Ok(session)
}

fn valid_signaling_text(value: &str, max: usize) -> bool {
    !value.is_empty() && value.len() <= max && !value.chars().any(char::is_control)
}

fn valid_sdp(value: &str) -> bool {
    value.len() <= MAX_SIGNALING_SDP_BYTES
        && !value.is_empty()
        && value.starts_with("v=0")
        && value.contains("\na=")
        && value
            .chars()
            .all(|character| !character.is_control() || matches!(character, '\r' | '\n' | '\t'))
}

fn valid_ice_candidate(request: &SignalingCandidateRequest) -> bool {
    request.sequence > 0
        && request.sequence <= MAX_SIGNALING_CANDIDATES as u64
        && request.sdp_m_line_index <= i32::MAX as u32
        && request.candidate.len() <= MAX_SIGNALING_CANDIDATE_BYTES
        && request.candidate.starts_with("candidate:")
        && !request.candidate.chars().any(char::is_control)
        && request
            .sdp_mid
            .as_deref()
            .is_none_or(|value| valid_signaling_text(value, 128))
        && request
            .username_fragment
            .as_deref()
            .is_none_or(|value| valid_signaling_text(value, 256))
}

fn signal_binding_error(
    session: &StoredComputerSession,
    binding: &SignalingBinding,
) -> Option<Response> {
    if binding.host_installation_id != session.host_installation_id
        || binding.conversation_id != session.conversation_id
    {
        return Some(StatusCode::NOT_FOUND.into_response());
    }
    if binding.generation != session.generation {
        return Some(
            (StatusCode::CONFLICT, "computer session generation mismatch").into_response(),
        );
    }
    if matches!(session.state.as_str(), "ended" | "failed" | "unavailable") {
        return Some(StatusCode::NOT_FOUND.into_response());
    }
    None
}

#[allow(clippy::result_large_err)]
async fn signaling_handle(
    state: &AppState,
    session: &StoredComputerSession,
    device_id: &str,
) -> Result<SignalingHandle, Response> {
    state
        .computer_supervisor
        .signaling_handle(&session.id, device_id)
        .await
        .ok_or_else(|| StatusCode::NOT_FOUND.into_response())
}

fn signaling_snapshot(
    session_id: &str,
    generation: u64,
    signaling: &SignalingState,
    cursor: u64,
) -> SignalingResponse {
    let candidates: Vec<_> = signaling
        .local_candidates
        .iter()
        .filter(|candidate| candidate.sequence > cursor)
        .take(MAX_SIGNALING_CANDIDATE_BATCH)
        .cloned()
        .collect();
    let next_cursor = cursor.max(
        candidates
            .last()
            .map(|candidate| candidate.sequence)
            .unwrap_or(cursor),
    );
    SignalingResponse {
        session_id: session_id.to_owned(),
        generation,
        peer_revision: signaling.peer_revision.clone(),
        state: signaling.public_state(),
        capture_state: signaling.capture_state.clone(),
        peer_state: signaling.peer_state.clone(),
        offer: signaling.offer.clone(),
        candidates,
        cursor,
        next_cursor,
        failure_reason: signaling.failure_reason.clone(),
        ice_servers: Vec::new(),
    }
}

pub(crate) async fn signal_poll(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<SignalingPollRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    let session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    if let Some(response) = signal_binding_error(&session, &request.binding) {
        return response;
    }
    let handle = match signaling_handle(&state, &session, &device.device_id).await {
        Ok(handle) => handle,
        Err(response) => return response,
    };
    handle.mark_viewer_active();
    let signaling = handle.signaling.lock().await;
    Json(signaling_snapshot(
        &session.id,
        session.generation,
        &signaling,
        request.cursor,
    ))
    .into_response()
}

pub(crate) async fn signal_answer(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<SignalingAnswerRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    if request.kind != "answer" || !valid_sdp(&request.sdp) {
        return (StatusCode::BAD_REQUEST, "computer answer is invalid").into_response();
    }
    let session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    if let Some(response) = signal_binding_error(&session, &request.binding) {
        return response;
    }
    let handle = match signaling_handle(&state, &session, &device.device_id).await {
        Ok(handle) => handle,
        Err(response) => return response,
    };
    let peer_revision = request.binding.peer_revision.clone();
    let duplicate = {
        let mut signaling = handle.signaling.lock().await;
        let Some(peer_revision) = request
            .binding
            .peer_revision
            .as_deref()
            .filter(|revision| valid_signaling_text(revision, 128))
        else {
            return (StatusCode::BAD_REQUEST, "computer peer revision is invalid").into_response();
        };
        if signaling.peer_revision.as_deref() != Some(peer_revision) {
            return (StatusCode::CONFLICT, "computer peer revision mismatch").into_response();
        }
        match signaling.reserve_answer(&request.sdp) {
            Ok(true) => false,
            Ok(false) => true,
            Err(reason) => return (StatusCode::CONFLICT, reason).into_response(),
        }
    };
    handle.mark_viewer_active();
    if duplicate {
        return Json(serde_json::json!({"accepted": true, "duplicate": true})).into_response();
    }
    let (delivered_tx, delivered_rx) = tokio::sync::oneshot::channel();
    if handle
        .commands
        .try_send(HelperCommand::RemoteAnswer {
            peer_revision: peer_revision.unwrap_or_default(),
            sdp: request.sdp.clone(),
            delivered: delivered_tx,
        })
        .is_err()
    {
        handle.signaling.lock().await.rollback_answer(&request.sdp);
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "computer publisher is unavailable",
        )
            .into_response();
    }
    if !matches!(
        timeout(HELPER_COMMAND_DELIVERY_TIMEOUT, delivered_rx).await,
        Ok(Ok(true))
    ) {
        handle.signaling.lock().await.rollback_answer(&request.sdp);
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "computer publisher is unavailable",
        )
            .into_response();
    }
    Json(serde_json::json!({"accepted": true})).into_response()
}

pub(crate) async fn signal_candidate(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<SignalingCandidateRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    if !valid_ice_candidate(&request) {
        return (StatusCode::BAD_REQUEST, "computer ICE candidate is invalid").into_response();
    }
    let session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    if let Some(response) = signal_binding_error(&session, &request.binding) {
        return response;
    }
    let handle = match signaling_handle(&state, &session, &device.device_id).await {
        Ok(handle) => handle,
        Err(response) => return response,
    };
    let peer_revision = request.binding.peer_revision.clone();
    let candidate = SignalingCandidate {
        sequence: request.sequence,
        candidate: request.candidate.clone(),
        sdp_mid: request.sdp_mid.clone(),
        sdp_m_line_index: request.sdp_m_line_index,
        username_fragment: request.username_fragment.clone(),
    };
    let duplicate = {
        let mut signaling = handle.signaling.lock().await;
        let Some(peer_revision) = request
            .binding
            .peer_revision
            .as_deref()
            .filter(|revision| valid_signaling_text(revision, 128))
        else {
            return (StatusCode::BAD_REQUEST, "computer peer revision is invalid").into_response();
        };
        if signaling.peer_revision.as_deref() != Some(peer_revision) {
            return (StatusCode::CONFLICT, "computer peer revision mismatch").into_response();
        }
        match signaling.reserve_candidate(candidate) {
            Ok(true) => false,
            Ok(false) => true,
            Err("computer ICE candidate limit reached") => {
                return (
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "computer ICE candidate limit reached",
                )
                    .into_response();
            }
            Err(reason) => return (StatusCode::CONFLICT, reason).into_response(),
        }
    };
    handle.mark_viewer_active();
    if duplicate {
        return Json(serde_json::json!({"accepted": true, "duplicate": true})).into_response();
    }
    let (delivered_tx, delivered_rx) = tokio::sync::oneshot::channel();
    if handle
        .commands
        .try_send(HelperCommand::RemoteCandidate {
            peer_revision: peer_revision.unwrap_or_default(),
            sequence: request.sequence,
            candidate: request.candidate,
            sdp_mid: request.sdp_mid,
            sdp_m_line_index: request.sdp_m_line_index,
            username_fragment: request.username_fragment,
            delivered: delivered_tx,
        })
        .is_err()
    {
        handle
            .signaling
            .lock()
            .await
            .rollback_candidate(request.sequence);
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "computer publisher is unavailable",
        )
            .into_response();
    }
    if !matches!(
        timeout(HELPER_COMMAND_DELIVERY_TIMEOUT, delivered_rx).await,
        Ok(Ok(true))
    ) {
        handle
            .signaling
            .lock()
            .await
            .rollback_candidate(request.sequence);
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "computer publisher is unavailable",
        )
            .into_response();
    }
    Json(serde_json::json!({"accepted": true, "duplicate": false})).into_response()
}

pub(crate) async fn signal_close(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<SignalingCloseRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    let session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    if let Some(response) = signal_binding_error(&session, &request.binding) {
        return response;
    }
    let handle = match signaling_handle(&state, &session, &device.device_id).await {
        Ok(handle) => handle,
        Err(response) => return response,
    };
    let peer_revision = request.binding.peer_revision.clone();
    let reason = request.reason.as_deref().unwrap_or("closed_by_viewer");
    if !valid_signaling_text(reason, 128) {
        return (StatusCode::BAD_REQUEST, "computer close reason is invalid").into_response();
    }
    {
        let signaling = handle.signaling.lock().await;
        let Some(peer_revision) = request
            .binding
            .peer_revision
            .as_deref()
            .filter(|revision| valid_signaling_text(revision, 128))
        else {
            return (StatusCode::BAD_REQUEST, "computer peer revision is invalid").into_response();
        };
        if signaling.peer_revision.as_deref() != Some(peer_revision) {
            return (StatusCode::CONFLICT, "computer peer revision mismatch").into_response();
        }
    }
    handle.mark_viewer_active();
    let (delivered_tx, delivered_rx) = tokio::sync::oneshot::channel();
    if handle
        .commands
        .try_send(HelperCommand::CloseSignal {
            peer_revision: peer_revision.unwrap_or_default(),
            reason: reason.to_owned(),
            delivered: delivered_tx,
        })
        .is_err()
    {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "computer publisher is unavailable",
        )
            .into_response();
    }
    if !matches!(
        timeout(HELPER_COMMAND_DELIVERY_TIMEOUT, delivered_rx).await,
        Ok(Ok(true))
    ) {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "computer publisher is unavailable",
        )
            .into_response();
    }
    reconcile_media_state(&state, &session, &handle.signaling)
        .await
        .ok();
    Json(serde_json::json!({
        "accepted": true,
        "closed": true,
        "sessionId": session.id,
        "generation": session.generation
    }))
    .into_response()
}

pub(crate) async fn create(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Json(request): Json<StartRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    if !validate_text(&request.client_request_id, 160)
        || !validate_text(&request.conversation_id, 160)
        || request.host_installation_id != state.host_installation_id
        || request.generation.unwrap_or(1) != 1
    {
        return (
            StatusCode::BAD_REQUEST,
            "computer session request is invalid",
        )
            .into_response();
    }
    let source = match source_fields(request.source) {
        Ok(source) => source,
        Err(message) => return (StatusCode::BAD_REQUEST, message).into_response(),
    };
    if !state
        .store
        .computer_conversation_allowed(&request.conversation_id)
        .await
        .unwrap_or(false)
    {
        return (StatusCode::NOT_FOUND, "conversation is unavailable").into_response();
    }
    match state
        .store
        .computer_session_by_request(&device.device_id, &request.client_request_id)
        .await
    {
        Ok(Some(existing)) => {
            if existing.conversation_id != request.conversation_id
                || existing.host_installation_id != state.host_installation_id
            {
                return (
                    StatusCode::CONFLICT,
                    "client request is already bound to another session",
                )
                    .into_response();
            }
            if provider_available(&state)
                && matches!(
                    existing.state.as_str(),
                    "preparing" | "awaitingSource" | "paused" | "stale" | "live"
                )
            {
                let _ = state
                    .computer_supervisor
                    .start(state.clone(), existing.clone())
                    .await;
            }
            return Json(response(&state, existing)).into_response();
        }
        Ok(None) => {}
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "computer session unavailable",
            )
                .into_response()
        }
    }
    if provider_available(&state) {
        match state
            .store
            .active_computer_session_for_host(&state.host_installation_id)
            .await
        {
            Ok(Some(_)) => {
                return (
                    StatusCode::CONFLICT,
                    "another computer session is already preparing on this Mac",
                )
                    .into_response();
            }
            Ok(None) => {}
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "computer session availability could not be verified",
                )
                    .into_response();
            }
        }
    }
    let capture_available = provider_available(&state);
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let session = ComputerSessionCreate {
        id: uuid::Uuid::new_v4().to_string(),
        client_request_id: request.client_request_id.clone(),
        owner_device_id: device.device_id.clone(),
        host_installation_id: state.host_installation_id.clone(),
        conversation_id: request.conversation_id.clone(),
        generation: 1,
        state: if capture_available {
            ComputerSessionState::Preparing
        } else {
            ComputerSessionState::Unavailable
        },
        source_id: source.0,
        source_name: source.1,
        source_kind: source.2,
        source_width: source.3,
        source_height: source.4,
        source_scale: source.5,
        crop_json: source.6,
        geometry_revision: 0,
        failure_reason: (!capture_available).then(|| UNAVAILABLE_REASON.into()),
        now: now.clone(),
    };
    let stored = match state.store.insert_computer_session(&session).await {
        Ok(stored) => stored,
        Err(sqlx::Error::Database(error)) if error.is_unique_violation() => match state
            .store
            .computer_session_by_request(&device.device_id, &request.client_request_id)
            .await
        {
            Ok(Some(existing))
                if existing.conversation_id == request.conversation_id
                    && existing.host_installation_id == state.host_installation_id =>
            {
                existing
            }
            _ => {
                return (
                    StatusCode::CONFLICT,
                    "client request is already bound to another session",
                )
                    .into_response()
            }
        },
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "computer session could not be saved",
            )
                .into_response()
        }
    };
    if capture_available {
        if let Err(error) = state
            .computer_supervisor
            .start(state.clone(), stored.clone())
            .await
        {
            if error == SupervisorStartError::Conflict {
                let _ = state
                    .store
                    .end_computer_session(
                        &stored.id,
                        &device.device_id,
                        Some(stored.generation),
                        &now,
                    )
                    .await;
                return (
                    StatusCode::CONFLICT,
                    "another computer session is already preparing on this Mac",
                )
                    .into_response();
            }
            let _ = state
                .store
                .transition_computer_session(
                    &stored.id,
                    stored.generation,
                    ComputerSessionState::Failed,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    stored.geometry_revision,
                    Some(error.reason()),
                    &now,
                )
                .await;
        }
    }
    let stored = state
        .store
        .computer_session(&stored.id)
        .await
        .ok()
        .flatten()
        .unwrap_or(stored);
    let _ = publish_event_with_context(
        &state,
        WonderEvent::ComputerSessionChanged {
            session_id: stored.id.clone(),
            generation: stored.generation,
            state: stored.state.clone(),
        },
        EventContext {
            request_id: Some(stored.client_request_id.clone()),
            conversation_id: Some(stored.conversation_id.clone()),
            ..EventContext::default()
        },
    )
    .await;
    (StatusCode::CREATED, Json(response(&state, stored))).into_response()
}

pub(crate) async fn read(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Query(query): Query<GenerationQuery>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    let session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    if query
        .generation
        .is_some_and(|generation| generation != session.generation)
    {
        return (StatusCode::CONFLICT, "computer session generation mismatch").into_response();
    }
    Json(response(&state, session)).into_response()
}

pub(crate) async fn admit(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<AdmissionRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    if !matches!(request.role.as_str(), "viewer" | "publisher") {
        return (StatusCode::BAD_REQUEST, "computer session role is invalid").into_response();
    }
    let session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    if request.generation != session.generation {
        return (StatusCode::CONFLICT, "computer session generation mismatch").into_response();
    }
    let session_response = response(&state, session);
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(AdmissionResponse {
            session: session_response,
            role: request.role,
            granted: false,
            admission: None,
            capability: capability(&state),
        }),
    )
        .into_response()
}

pub(crate) async fn acquire_control(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<AcquireControlRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    if !validate_text(&request.client_request_id, 160)
        || request
            .source_id
            .as_deref()
            .is_some_and(|value| !validate_text(value, 160))
    {
        return (StatusCode::BAD_REQUEST, "control lease request is invalid").into_response();
    }
    let session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    if !session_binding_matches(
        &session,
        request.generation,
        request.geometry_revision,
        request.source_id.as_deref(),
    ) {
        return (
            StatusCode::CONFLICT,
            Json(control_response(
                &state,
                false,
                false,
                "stale",
                "The computer view changed. Refresh before taking control.",
                None,
                None,
            )),
        )
            .into_response();
    }
    // Serialize the consent/activation window with itself. The durable
    // single-owner index remains authoritative for other devices.
    let _acquire_guard = state.computer_supervisor.control_acquire.lock().await;
    let mut existing = match state
        .store
        .computer_control_lease_by_request(&device.device_id, &request.client_request_id)
        .await
    {
        Ok(existing) => existing,
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "control lease is unavailable",
            )
                .into_response()
        }
    };
    let checked_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    if existing
        .as_ref()
        .is_some_and(|lease| lease.status == "active" && lease.expires_at <= checked_at)
    {
        let expiry_probe = ComputerControlLeaseCreate {
            id: uuid::Uuid::new_v4().to_string(),
            client_request_id: request.client_request_id.clone(),
            session_id: session.id.clone(),
            owner_device_id: device.device_id.clone(),
            host_installation_id: state.host_installation_id.clone(),
            conversation_id: session.conversation_id.clone(),
            session_generation: request.generation,
            source_id: request.source_id.clone(),
            geometry_revision: request.geometry_revision,
            now: checked_at.clone(),
            expires_at: checked_at.clone(),
        };
        existing = match state
            .store
            .acquire_computer_control_lease(&expiry_probe)
            .await
        {
            Ok(ComputerLeaseAcquireResult::Existing(lease)) => Some(lease),
            Ok(_) | Err(_) => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "control lease could not be reconciled",
                )
                    .into_response()
            }
        };
    }
    if let Some(existing) = existing.as_ref() {
        if !lease_matches_request(existing, &state, &session, &request) {
            return (
                StatusCode::CONFLICT,
                "client request is already bound to another control lease",
            )
                .into_response();
        }
        if existing.status != "active" {
            return (
                StatusCode::CONFLICT,
                Json(control_response(
                    &state,
                    false,
                    false,
                    if existing.status == "expired" {
                        "expired"
                    } else {
                        "released"
                    },
                    "This control request has already ended. Start a new control request.",
                    Some(existing.clone()),
                    None,
                )),
            )
                .into_response();
        }
    }
    if session.state != ComputerSessionState::Live.as_str()
        || !state.computer_supervisor.control_capable()
    {
        return control_unavailable(&state, session);
    }
    let handle = match state
        .computer_supervisor
        .signaling_handle(&session.id, &device.device_id)
        .await
    {
        Some(handle) => handle,
        None => return control_unavailable(&state, session),
    };

    let was_existing = existing.is_some();
    let mut lease = if let Some(existing) = existing {
        existing
    } else {
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        // Reserve the single-owner slot for the full local-consent window.
        // Once consent returns, the lease is reduced to the normal heartbeat
        // lifetime before the helper is allowed to activate control.
        let expires_at = (Utc::now()
            + chrono::Duration::seconds(CONTROL_CONSENT_RESERVATION_SECONDS))
        .to_rfc3339_opts(SecondsFormat::Millis, true);
        let lease_request = ComputerControlLeaseCreate {
            id: uuid::Uuid::new_v4().to_string(),
            client_request_id: request.client_request_id.clone(),
            session_id: session.id.clone(),
            owner_device_id: device.device_id.clone(),
            host_installation_id: state.host_installation_id.clone(),
            conversation_id: session.conversation_id.clone(),
            session_generation: request.generation,
            source_id: request.source_id.clone(),
            geometry_revision: request.geometry_revision,
            now,
            expires_at,
        };
        match state
            .store
            .acquire_computer_control_lease(&lease_request)
            .await
        {
            Ok(ComputerLeaseAcquireResult::Granted(lease)) => lease,
            Ok(ComputerLeaseAcquireResult::Existing(lease)) if lease.status == "active" => lease,
            Ok(ComputerLeaseAcquireResult::Existing(lease)) => {
                return (
                    StatusCode::CONFLICT,
                    Json(control_response(
                        &state,
                        false,
                        false,
                        if lease.status == "expired" {
                            "expired"
                        } else {
                            "released"
                        },
                        "This control request has already ended. Start a new control request.",
                        Some(lease),
                        None,
                    )),
                )
                    .into_response()
            }
            Ok(ComputerLeaseAcquireResult::Busy(_)) => {
                return (
                    StatusCode::CONFLICT,
                    Json(control_response(
                        &state,
                        false,
                        false,
                        "busy",
                        "Another device is controlling the Mac.",
                        None,
                        None,
                    )),
                )
                    .into_response()
            }
            Ok(ComputerLeaseAcquireResult::Conflict) => {
                return (
                    StatusCode::CONFLICT,
                    Json(control_response(
                        &state,
                        false,
                        false,
                        "rejected",
                        "This control request is already bound to another computer view.",
                        None,
                        None,
                    )),
                )
                    .into_response()
            }
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "control lease could not be saved",
                )
                    .into_response()
            }
        }
    };
    let consent_identity_params = control_identity_params(&session, &lease);
    let mut control_disabled = false;
    let consent_granted = if was_existing {
        true
    } else {
        match handle
            .request("control.consent", consent_identity_params.clone())
            .await
        {
            Ok(value) => {
                control_disabled = value.get("reason").and_then(serde_json::Value::as_str)
                    == Some("control_disabled");
                value.get("granted").and_then(serde_json::Value::as_bool) == Some(true)
            }
            _ => false,
        }
    };
    let activated = if consent_granted {
        let activated_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        let expires_at = (Utc::now() + chrono::Duration::seconds(CONTROL_EXPIRY_SECONDS))
            .to_rfc3339_opts(SecondsFormat::Millis, true);
        match state
            .store
            .heartbeat_computer_control_lease(
                &lease.id,
                &device.device_id,
                &state.host_installation_id,
                &session.id,
                &session.conversation_id,
                request.generation,
                request.source_id.as_deref(),
                request.geometry_revision,
                &activated_at,
                &expires_at,
            )
            .await
        {
            Ok(Some(refreshed)) => {
                lease = refreshed;
                let activation = handle
                    .request(
                        "control.activate",
                        control_identity_params(&session, &lease),
                    )
                    .await;
                if let Ok(value) = &activation {
                    control_disabled |= value.get("reason").and_then(serde_json::Value::as_str)
                        == Some("control_disabled");
                }
                activation
                    .ok()
                    .and_then(|value| value.get("activated").and_then(serde_json::Value::as_bool))
                    == Some(true)
            }
            Ok(None) | Err(_) => false,
        }
    } else {
        false
    };
    if activated {
        return Json(control_response(
            &state,
            true,
            true,
            "active",
            if was_existing {
                "Control already granted."
            } else {
                "Control granted."
            },
            Some(lease),
            None,
        ))
        .into_response();
    }
    // Consent, activation, and helper loss all roll back the durable
    // reservation. The released request ID is terminal and cannot reprompt.
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let _ = state
        .store
        .release_computer_control_lease(&lease.id, &device.device_id, &now)
        .await;
    let _ = handle
        .request("control.release", control_identity_params(&session, &lease))
        .await;
    (
        StatusCode::CONFLICT,
        Json(control_response(
            &state,
            false,
            true,
            "rejected",
            if control_disabled {
                CONTROL_DISABLED_REASON
            } else {
                "Control was not allowed or is no longer available on the Mac."
            },
            state
                .store
                .computer_control_lease(&lease.id)
                .await
                .ok()
                .flatten(),
            None,
        )),
    )
        .into_response()
}

pub(crate) async fn heartbeat_control(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<LeaseBindingRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    if !validate_binding_request(&request) {
        return (StatusCode::BAD_REQUEST, "control lease request is invalid").into_response();
    }
    let session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    if !session_binding_matches(
        &session,
        request.generation,
        request.geometry_revision,
        request.source_id.as_deref(),
    ) {
        return (
            StatusCode::CONFLICT,
            Json(control_response(
                &state,
                false,
                false,
                "stale",
                "The computer view changed. Control was not renewed.",
                None,
                None,
            )),
        )
            .into_response();
    }
    if !state.computer_supervisor.control_capable()
        || session.state != ComputerSessionState::Live.as_str()
    {
        return control_unavailable(&state, session);
    }
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let expires_at = (Utc::now() + chrono::Duration::seconds(CONTROL_EXPIRY_SECONDS))
        .to_rfc3339_opts(SecondsFormat::Millis, true);
    match state
        .store
        .heartbeat_computer_control_lease(
            &request.lease_id,
            &device.device_id,
            &state.host_installation_id,
            &session.id,
            &session.conversation_id,
            request.generation,
            request.source_id.as_deref(),
            request.geometry_revision,
            &now,
            &expires_at,
        )
        .await
    {
        Ok(Some(lease)) => {
            let Some(handle) = state
                .computer_supervisor
                .signaling_handle(&session.id, &device.device_id)
                .await
            else {
                let _ = state
                    .store
                    .release_computer_control_lease(&lease.id, &device.device_id, &now)
                    .await;
                return control_unavailable(&state, session);
            };
            let helper_response = handle
                .request(
                    "control.heartbeat",
                    control_identity_params(&session, &lease),
                )
                .await
                .ok();
            let helper_disabled = helper_response
                .as_ref()
                .and_then(|value| value.get("reason"))
                .and_then(serde_json::Value::as_str)
                == Some("control_disabled");
            let helper_ok = helper_response
                .as_ref()
                .and_then(|value| value.get("renewed").and_then(serde_json::Value::as_bool))
                == Some(true);
            if !helper_ok {
                let _ = state
                    .store
                    .release_computer_control_lease(&lease.id, &device.device_id, &now)
                    .await;
                return (
                    StatusCode::CONFLICT,
                    Json(control_response(
                        &state,
                        false,
                        false,
                        "expired",
                        if helper_disabled {
                            CONTROL_DISABLED_REASON
                        } else {
                            "Control expired or is no longer available on the Mac."
                        },
                        state
                            .store
                            .computer_control_lease(&lease.id)
                            .await
                            .ok()
                            .flatten(),
                        None,
                    )),
                )
                    .into_response();
            }
            Json(control_response(
                &state,
                false,
                true,
                "active",
                "Control renewed.",
                Some(lease),
                None,
            ))
            .into_response()
        }
        Ok(None) => {
            let _ = state
                .store
                .interrupt_teaching_for_lease(
                    &request.lease_id,
                    "Teaching stopped because control expired or no longer matched this computer view.",
                    &now,
                )
                .await;
            (
                StatusCode::CONFLICT,
                Json(control_response(
                    &state,
                    false,
                    false,
                    "expired",
                    "Control expired or no longer matches this computer view.",
                    None,
                    None,
                )),
            )
                .into_response()
        }
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "control lease unavailable",
        )
            .into_response(),
    }
}

pub(crate) async fn input_control(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<InputBatchRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    if let Err(message) = validate_input_batch(&request) {
        return (StatusCode::BAD_REQUEST, message).into_response();
    }
    let session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    if !session_binding_matches(
        &session,
        request.generation,
        request.geometry_revision,
        request.source_id.as_deref(),
    ) {
        return (
            StatusCode::CONFLICT,
            Json(control_response(
                &state,
                false,
                false,
                "stale",
                "The computer view changed. Input was discarded.",
                None,
                None,
            )),
        )
            .into_response();
    }
    if request
        .actions
        .iter()
        .any(|action| matches!(action, InputAction::ReleaseAll))
    {
        // Release-all is deliberately a separate authenticated release path. It
        // never waits behind or replays an uncertain input batch.
        return (
            StatusCode::BAD_REQUEST,
            "release-all must use the release endpoint",
        )
            .into_response();
    }
    if !state.computer_supervisor.control_capable()
        || session.state != ComputerSessionState::Live.as_str()
    {
        return control_unavailable(&state, session);
    }
    let Some(handle) = state
        .computer_supervisor
        .signaling_handle(&session.id, &device.device_id)
        .await
    else {
        return control_unavailable(&state, session);
    };
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let lease = match state
        .store
        .prepare_computer_input_batch(
            &request.lease_id,
            &device.device_id,
            &state.host_installation_id,
            &session.id,
            &session.conversation_id,
            request.generation,
            request.source_id.as_deref(),
            request.geometry_revision,
            request.sequence,
            &now,
        )
        .await
    {
        Ok(lease) => lease,
        Err(reason) => {
            return (
                StatusCode::CONFLICT,
                Json(control_response(
                    &state, false, false, "rejected", reason, None, None,
                )),
            )
                .into_response()
        }
    };
    let mut params = control_identity_params(&session, &lease);
    if let Some(object) = params.as_object_mut() {
        object.insert("sequence".into(), serde_json::json!(request.sequence));
        object.insert(
            "actions".into(),
            serde_json::to_value(&request.actions).unwrap_or(serde_json::Value::Null),
        );
    }
    let helper_result = match handle.request("control.input", params).await {
        Ok(value) => value,
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(control_response(
                    &state,
                    false,
                    false,
                    "unavailable",
                    "The Mac could not receive this input.",
                    None,
                    None,
                )),
            )
                .into_response()
        }
    };
    if helper_result
        .get("accepted")
        .and_then(serde_json::Value::as_bool)
        != Some(true)
    {
        return (
            StatusCode::CONFLICT,
            Json(control_response(
                &state,
                false,
                false,
                "rejected",
                match helper_result
                    .get("reason")
                    .and_then(serde_json::Value::as_str)
                {
                    Some("control_disabled") => CONTROL_DISABLED_REASON,
                    Some(reason) => reason,
                    None => "The Mac rejected this input.",
                },
                None,
                None,
            )),
        )
            .into_response();
    }
    let completed_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let refreshed_lease = match state
        .store
        .advance_computer_input_batch(
            &request.lease_id,
            &device.device_id,
            &state.host_installation_id,
            &session.id,
            &session.conversation_id,
            request.generation,
            request.source_id.as_deref(),
            request.geometry_revision,
            request.sequence,
            &completed_at,
        )
        .await
    {
        Ok(lease) => lease,
        Err(_reason) => {
            let recovery = accepted_input_recovery();
            let _ = state
                .store
                .interrupt_teaching_for_lease(
                    &request.lease_id,
                    ACCEPTED_INPUT_TEACHING_FAILURE_REASON,
                    &completed_at,
                )
                .await;
            let _ = state
                .store
                .release_computer_control_lease(&lease.id, &device.device_id, &completed_at)
                .await;
            let _ = handle
                .request("control.release", control_identity_params(&session, &lease))
                .await;
            return (
                StatusCode::OK,
                Json(control_response(
                    &state,
                    false,
                    recovery.acknowledged,
                    recovery.status,
                    recovery.reason,
                    None,
                    None,
                )),
            )
                .into_response();
        }
    };
    let teaching = state
        .store
        .active_teaching_session_for_binding(
            &device.device_id,
            &state.host_installation_id,
            &session.id,
            &request.lease_id,
        )
        .await;
    let teaching_outcome = match teaching {
        Ok(Some(teaching_session)) => {
            let events =
                sanitized_teaching_events(&request.actions, request.sequence, &completed_at);
            match state
                .store
                .append_teaching_events(
                    &teaching_session.id,
                    &device.device_id,
                    &state.host_installation_id,
                    &session.id,
                    &request.lease_id,
                    &events,
                    &completed_at,
                )
                .await
            {
                Ok(
                    TeachingCaptureAppendResult::Interrupted | TeachingCaptureAppendResult::Expired,
                ) => true,
                Ok(
                    TeachingCaptureAppendResult::Appended(_)
                    | TeachingCaptureAppendResult::Duplicate
                    | TeachingCaptureAppendResult::NotRecording,
                ) => false,
                Err(_) => {
                    let _ = state
                        .store
                        .interrupt_teaching_for_lease(
                            &request.lease_id,
                            "Teaching capture was interrupted because its accepted action could not be saved.",
                            &completed_at,
                        )
                        .await;
                    true
                }
            }
        }
        Ok(None) => {
            let _ = state
                .store
                .interrupt_teaching_for_lease(
                    &request.lease_id,
                    "Teaching stopped because the control lease ended before capture could be saved.",
                    &completed_at,
                )
                .await;
            false
        }
        Err(_) => {
            let _ = state
                .store
                .interrupt_teaching_for_lease(
                    &request.lease_id,
                    "Teaching capture was interrupted because its accepted action could not be recorded.",
                    &completed_at,
                )
                .await;
            true
        }
    };
    Json(control_response(
        &state,
        false,
        true,
        "active",
        if teaching_outcome {
            "Input accepted. Teaching capture was interrupted; no retry is needed."
        } else {
            "Input accepted."
        },
        Some(refreshed_lease),
        helper_result
            .get("clipboardText")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
    ))
    .into_response()
}

pub(crate) async fn release_control(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<LeaseBindingRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    if !validate_binding_request(&request) {
        return (
            StatusCode::BAD_REQUEST,
            "control release request is invalid",
        )
            .into_response();
    }
    let session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    let lease = match state.store.computer_control_lease(&request.lease_id).await {
        Ok(Some(lease))
            if lease.owner_device_id == device.device_id
                && lease.host_installation_id == state.host_installation_id
                && lease.session_id == session.id
                && lease.conversation_id == session.conversation_id
                && lease.session_generation == request.generation
                && lease.geometry_revision == request.geometry_revision
                && lease.source_id.as_deref() == request.source_id.as_deref() =>
        {
            lease
        }
        Ok(Some(_)) | Ok(None) => return StatusCode::NO_CONTENT.into_response(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "control release unavailable",
            )
                .into_response()
        }
    };
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    if state.computer_supervisor.control_capable() {
        if let Some(handle) = state
            .computer_supervisor
            .signaling_handle(&session.id, &device.device_id)
            .await
        {
            let _ = handle
                .request("control.release", control_identity_params(&session, &lease))
                .await;
        }
    }
    match state
        .store
        .release_computer_control_lease(&request.lease_id, &device.device_id, &now)
        .await
    {
        Ok(Some(released)) => Json(control_response(
            &state,
            false,
            true,
            "released",
            "Control released. The Mac is ready for the Bot when it reports a fresh state.",
            Some(released),
            None,
        ))
        .into_response(),
        Ok(None) => StatusCode::NO_CONTENT.into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "control release unavailable",
        )
            .into_response(),
    }
}

pub(crate) async fn resume_control(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Json(request): Json<LeaseBindingRequest>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    if !validate_binding_request(&request) {
        return (StatusCode::BAD_REQUEST, "control resume request is invalid").into_response();
    }
    let _session = match owned_session(&state, &id, &device.device_id).await {
        Ok(session) => session,
        Err(response) => return response,
    };
    (
        StatusCode::CONFLICT,
        Json(control_response(
            &state,
            false,
            false,
            "unsupported",
            "Bot pause/resume is not acknowledged by this runtime, so handback cannot claim success.",
            None,
            None,
        )),
    )
        .into_response()
}

pub(crate) async fn end(
    State(state): State<AppState>,
    authenticated: Option<Extension<AuthenticatedDevice>>,
    Path(id): Path<String>,
    Query(query): Query<GenerationQuery>,
) -> Response {
    let device = match owner_device(authenticated).await {
        Ok(device) => device,
        Err(response) => return response,
    };
    let current = match state.store.computer_session(&id).await {
        Ok(current) => current,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "computer session unavailable",
            )
                .into_response()
        }
    };
    let Some(current) = current else {
        return StatusCode::NO_CONTENT.into_response();
    };
    if current.owner_device_id != device.device_id
        || current.host_installation_id != state.host_installation_id
    {
        return StatusCode::NO_CONTENT.into_response();
    }
    if current.state == ComputerSessionState::Ended.as_str() {
        let _ = state
            .store
            .release_computer_control_lease_for_session(
                &current.id,
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            )
            .await;
        return StatusCode::NO_CONTENT.into_response();
    }
    if query
        .generation
        .is_some_and(|generation| generation != current.generation)
    {
        return (StatusCode::CONFLICT, "computer session generation mismatch").into_response();
    }
    let ended = match state
        .store
        .end_computer_session(
            &id,
            &device.device_id,
            query.generation,
            &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        )
        .await
    {
        Ok(Some(session)) => session,
        Ok(None) => return StatusCode::NO_CONTENT.into_response(),
        Err(_) => {
            return (StatusCode::CONFLICT, "computer session generation mismatch").into_response()
        }
    };
    let _ = state
        .store
        .release_computer_control_lease_for_session(
            &ended.id,
            &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        )
        .await;
    state
        .computer_supervisor
        .stop(&state, &ended.id, "session_deleted")
        .await;
    if current.state != ComputerSessionState::Ended.as_str() {
        let _ = publish_event_with_context(
            &state,
            WonderEvent::ComputerSessionChanged {
                session_id: ended.id.clone(),
                generation: ended.generation,
                state: ended.state.clone(),
            },
            EventContext {
                conversation_id: Some(ended.conversation_id.clone()),
                ..EventContext::default()
            },
        )
        .await;
    }
    StatusCode::NO_CONTENT.into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_crop_is_bounded_and_requires_a_positive_rectangle() {
        let valid = SourceRequest {
            id: Some("display-1".into()),
            name: Some("Mac display".into()),
            kind: Some("display".into()),
            width: Some(1280),
            height: Some(720),
            scale: Some(2.0),
            crop: Some(CropRequest {
                x: 0.0,
                y: 0.0,
                width: 1280.0,
                height: 720.0,
            }),
        };
        assert!(source_fields(Some(valid)).is_ok());

        let invalid = SourceRequest {
            id: None,
            name: None,
            kind: None,
            width: None,
            height: None,
            scale: None,
            crop: Some(CropRequest {
                x: 0.0,
                y: 0.0,
                width: 0.0,
                height: 720.0,
            }),
        };
        assert_eq!(source_fields(Some(invalid)), Err("source crop is invalid"));
    }

    #[test]
    fn capability_is_explicitly_unavailable_until_a_provider_exists() {
        let value = serde_json::to_value(serde_json::json!({
            "available": false,
            "action": UNAVAILABLE_ACTION,
            "reason": UNAVAILABLE_REASON,
        }))
        .unwrap();
        assert_eq!(value["available"], false);
        assert_eq!(value["action"], "update-host");
        assert!(value["reason"].as_str().unwrap().contains("media provider"));
    }

    #[test]
    fn control_contract_rejects_unbounded_actions_and_reserves_release_all() {
        let valid = InputBatchRequest {
            lease_id: "lease-1".into(),
            generation: 1,
            geometry_revision: 2,
            source_id: Some("display-1".into()),
            sequence: 1,
            actions: vec![InputAction::Text {
                text: "hello".into(),
            }],
        };
        assert!(validate_input_batch(&valid).is_ok());

        let invalid = InputBatchRequest {
            actions: vec![InputAction::Pointer {
                x: 2.0,
                y: 0.5,
                phase: "move".into(),
                button: None,
            }],
            ..valid
        };
        assert_eq!(
            validate_input_batch(&invalid),
            Err("input batch is invalid")
        );

        let release_all = InputBatchRequest {
            actions: vec![InputAction::ReleaseAll],
            ..invalid
        };
        assert!(validate_input_batch(&release_all).is_ok());

        assert!(validate_input_action(&InputAction::Key {
            key: "escape".into(),
            phase: "up".into(),
            modifiers: 0,
        }));
        assert!(!validate_input_action(&InputAction::Key {
            key: "escape".into(),
            phase: "press".into(),
            modifiers: 1 << 5,
        }));
        assert!(validate_input_action(&InputAction::Clipboard {
            operation: "copyToPhone".into(),
            text: None,
        }));
        assert!(!validate_input_action(&InputAction::Clipboard {
            operation: "pasteFromPhone".into(),
            text: None,
        }));
        assert!(!validate_input_action(&InputAction::Pointer {
            x: 0.5,
            y: 0.5,
            phase: "up".into(),
            button: None,
        }));

        let paste_with_another_action = InputBatchRequest {
            actions: vec![
                InputAction::Clipboard {
                    operation: "pasteFromPhone".into(),
                    text: Some("hello".into()),
                },
                InputAction::Key {
                    key: "return".into(),
                    phase: "press".into(),
                    modifiers: 0,
                },
            ],
            ..release_all
        };
        assert_eq!(
            validate_input_batch(&paste_with_another_action),
            Err("input batch is invalid")
        );

        let schema: serde_json::Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/schemas/wonder-http-v1.json"
        ))
        .unwrap();
        let wrapper = serde_json::json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$ref": "#/$defs/computerInputBatchRequest",
            "$defs": schema["$defs"].clone(),
        });
        let validator = jsonschema::validator_for(&wrapper).unwrap();
        let single_paste = serde_json::json!({
            "leaseId": "lease-1",
            "generation": 1,
            "geometryRevision": 2,
            "sourceId": "display-1",
            "sequence": 1,
            "actions": [{ "type": "clipboard", "operation": "pasteFromPhone", "text": "hello" }],
        });
        assert!(validator.is_valid(&single_paste));
        let mixed_paste = serde_json::json!({
            "leaseId": "lease-1",
            "generation": 1,
            "geometryRevision": 2,
            "sourceId": "display-1",
            "sequence": 1,
            "actions": [
                { "type": "clipboard", "operation": "pasteFromPhone", "text": "hello" },
                { "type": "key", "key": "return", "phase": "press", "modifiers": 0 }
            ],
        });
        assert!(!validator.is_valid(&mixed_paste));
    }

    #[test]
    fn phone_paste_accepts_multiline_unicode_but_rejects_unsafe_controls_and_oversize() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/fixtures/computer-clipboard-v1.json"
        ))
        .unwrap();
        for text in fixture["valid"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap())
        {
            assert!(validate_input_action(&InputAction::Clipboard {
                operation: "pasteFromPhone".into(),
                text: Some(text.into()),
            }));
        }
        let mut invalid: Vec<String> = fixture["invalid"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_owned())
            .collect();
        invalid.push("x".repeat(MAX_CLIPBOARD_TEXT + 1));
        invalid.push("e\u{301}".repeat(MAX_CLIPBOARD_TEXT / 2 + 1));
        for text in invalid {
            assert!(!validate_input_action(&InputAction::Clipboard {
                operation: "pasteFromPhone".into(),
                text: Some(text),
            }));
        }
    }

    #[test]
    fn teaching_capture_redacts_text_clipboard_and_printable_keys() {
        let events = sanitized_teaching_events(
            &[
                InputAction::Pointer {
                    x: 0.123456,
                    y: 0.987654,
                    phase: "down".into(),
                    button: Some("left".into()),
                },
                InputAction::Text {
                    text: "secret text".into(),
                },
                InputAction::Clipboard {
                    operation: "pasteFromPhone".into(),
                    text: Some("private clipboard".into()),
                },
                InputAction::Key {
                    key: "a".into(),
                    phase: "press".into(),
                    modifiers: 0,
                },
                InputAction::Key {
                    key: "return".into(),
                    phase: "press".into(),
                    modifiers: 1,
                },
                InputAction::ReleaseAll,
            ],
            4,
            "now",
        );
        assert_eq!(events.len(), 5);
        let encoded = events
            .iter()
            .map(|event| event.event_json.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(!encoded.contains("secret text"));
        assert!(!encoded.contains("private clipboard"));
        assert!(encoded.contains(r#""characterCount":11"#));
        assert!(encoded.contains(r#""key":"redacted""#));
        assert!(encoded.contains(r#""key":"return""#));
        assert!(encoded.contains(r#""x":0.1235"#));
    }

    #[test]
    fn accepted_input_recovery_cannot_be_reported_as_retryable() {
        let recovery = accepted_input_recovery();

        assert!(recovery.acknowledged);
        assert_eq!(recovery.status, "stale");
        assert!(recovery.reason.contains("reached the Mac"));
        assert!(recovery.reason.contains("Do not retry"));
    }

    #[test]
    fn control_capability_never_claims_control_without_a_provider() {
        let value = serde_json::to_value(control_capability_for(false)).unwrap();
        assert_eq!(value["available"], false);
        assert_eq!(value["heartbeatIntervalSeconds"], 3);
        assert_eq!(value["leaseExpirySeconds"], 10);
        assert!(value["reason"].as_str().unwrap().contains("unavailable"));
    }
}

const MAX_HELPER_LINE_BYTES: usize = 128 * 1024;
const HELPER_STARTUP_TIMEOUT: Duration = Duration::from_secs(5);
const HELPER_COMMAND_DELIVERY_TIMEOUT: Duration = Duration::from_secs(2);
const HELPER_CONSENT_TIMEOUT: Duration = Duration::from_secs(CONTROL_CONSENT_TIMEOUT_SECONDS);
const VIEWER_ACTIVITY_LEASE: Duration = Duration::from_secs(30);

struct ViewerActivityLease {
    timer: std::pin::Pin<Box<tokio::time::Sleep>>,
    duration: Duration,
}

impl ViewerActivityLease {
    fn with_duration(duration: Duration) -> Self {
        Self {
            timer: Box::pin(tokio::time::sleep(duration)),
            duration,
        }
    }

    fn reset(&mut self) {
        self.timer
            .as_mut()
            .reset(tokio::time::Instant::now() + self.duration);
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SupervisorStartError {
    Conflict,
    Unavailable,
    Spawn,
}

impl SupervisorStartError {
    fn reason(self) -> &'static str {
        match self {
            Self::Conflict => "computer_provider_conflict",
            Self::Unavailable => UNAVAILABLE_REASON,
            Self::Spawn => "computer_provider_failed_to_start",
        }
    }
}

struct StopCommand {
    reason: String,
    end_session: bool,
}

#[derive(Clone)]
struct SignalingHandle {
    signaling: Arc<tokio::sync::Mutex<SignalingState>>,
    commands: tokio::sync::mpsc::Sender<HelperCommand>,
    viewer_activity: tokio::sync::mpsc::Sender<()>,
}

impl SignalingHandle {
    fn mark_viewer_active(&self) {
        // The channel is deliberately coalescing: one pending wakeup is
        // enough to move the lease forward after a burst of valid requests.
        let _ = self.viewer_activity.try_send(());
    }

    async fn request(
        &self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        let (response_tx, response_rx) = tokio::sync::oneshot::channel();
        self.commands
            .send(HelperCommand::Control {
                method: method.to_owned(),
                params,
                response: response_tx,
            })
            .await
            .map_err(|_| "computer helper is unavailable".to_owned())?;
        let response_timeout = if method == "control.consent" {
            HELPER_CONSENT_TIMEOUT
        } else {
            HELPER_COMMAND_DELIVERY_TIMEOUT
        };
        match timeout(response_timeout, response_rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("computer helper is unavailable".to_owned()),
            Err(_) => Err("computer helper did not acknowledge the request".to_owned()),
        }
    }
}

enum HelperCommand {
    RemoteAnswer {
        peer_revision: String,
        sdp: String,
        delivered: tokio::sync::oneshot::Sender<bool>,
    },
    RemoteCandidate {
        peer_revision: String,
        sequence: u64,
        candidate: String,
        sdp_mid: Option<String>,
        sdp_m_line_index: u32,
        username_fragment: Option<String>,
        delivered: tokio::sync::oneshot::Sender<bool>,
    },
    CloseSignal {
        peer_revision: String,
        reason: String,
        delivered: tokio::sync::oneshot::Sender<bool>,
    },
    Control {
        method: String,
        params: serde_json::Value,
        response: tokio::sync::oneshot::Sender<Result<serde_json::Value, String>>,
    },
}

struct SignalingState {
    peer_revision: Option<String>,
    offer: Option<SignalingDescription>,
    answer: Option<String>,
    answer_pending: Option<String>,
    local_candidates: VecDeque<SignalingCandidate>,
    remote_candidates: BTreeMap<u64, SignalingCandidate>,
    remote_candidates_pending: BTreeMap<u64, SignalingCandidate>,
    peer_state: String,
    capture_state: String,
    first_frame_observed: bool,
    failure_reason: Option<String>,
    closed: bool,
}

impl Default for SignalingState {
    fn default() -> Self {
        Self {
            peer_revision: None,
            offer: None,
            answer: None,
            answer_pending: None,
            local_candidates: VecDeque::new(),
            remote_candidates: BTreeMap::new(),
            remote_candidates_pending: BTreeMap::new(),
            peer_state: "new".into(),
            capture_state: "preparing".into(),
            first_frame_observed: false,
            failure_reason: None,
            closed: false,
        }
    }
}

impl SignalingState {
    fn public_state(&self) -> String {
        if self.closed {
            return "closed".into();
        }
        if self.failure_reason.is_some()
            || matches!(
                self.peer_state.as_str(),
                "failed" | "disconnected" | "closed"
            )
            || matches!(
                self.capture_state.as_str(),
                "permissionDenied" | "sourceRemoved" | "failed" | "stopped" | "helperRestarted"
            )
        {
            return "failed".into();
        }
        if self.capture_state == "capturing"
            && self.first_frame_observed
            && matches!(self.peer_state.as_str(), "connected" | "completed")
        {
            return "live".into();
        }
        if self.answer.is_some() {
            return "connecting".into();
        }
        if self.offer.is_some() {
            return "offerReady".into();
        }
        if self.capture_state == "awaitingSource" {
            return "awaitingSource".into();
        }
        "preparing".into()
    }

    fn clear_ephemeral(&mut self, reason: Option<String>) {
        self.peer_revision = None;
        self.offer = None;
        self.answer = None;
        self.answer_pending = None;
        self.local_candidates.clear();
        self.remote_candidates.clear();
        self.remote_candidates_pending.clear();
        self.first_frame_observed = false;
        self.failure_reason = reason;
    }

    /// Returns `true` when a new command must be sent and `false` for an
    /// identical already-pending/applied command.
    fn reserve_answer(&mut self, sdp: &str) -> Result<bool, &'static str> {
        if self.offer.is_none() {
            return Err("computer offer is not ready");
        }
        if self.answer.as_deref() == Some(sdp) {
            return Ok(false);
        }
        if self.answer_pending.as_deref() == Some(sdp) {
            return Err("computer answer is still being applied");
        }
        if self.answer.is_some() || self.answer_pending.is_some() {
            return Err("computer answer is already bound");
        }
        self.answer_pending = Some(sdp.to_owned());
        Ok(true)
    }

    fn commit_answer(&mut self, sdp: &str) {
        if self.answer_pending.as_deref() == Some(sdp) {
            self.answer = self.answer_pending.take();
        }
    }

    fn rollback_answer(&mut self, sdp: &str) {
        if self.answer_pending.as_deref() == Some(sdp) {
            self.answer_pending = None;
        }
    }

    fn reserve_candidate(&mut self, candidate: SignalingCandidate) -> Result<bool, &'static str> {
        let sequence = candidate.sequence;
        if let Some(existing) = self.remote_candidates.get(&sequence) {
            if existing == &candidate {
                return Ok(false);
            }
            return Err("computer ICE sequence is already bound");
        }
        if let Some(existing) = self.remote_candidates_pending.get(&sequence) {
            if existing == &candidate {
                return Err("computer ICE candidate is still being applied");
            }
            return Err("computer ICE sequence is already bound");
        }
        if self.remote_candidates.len() + self.remote_candidates_pending.len()
            >= MAX_SIGNALING_CANDIDATES
        {
            return Err("computer ICE candidate limit reached");
        }
        self.remote_candidates_pending.insert(sequence, candidate);
        Ok(true)
    }

    fn commit_candidate(&mut self, sequence: u64) {
        if let Some(candidate) = self.remote_candidates_pending.remove(&sequence) {
            self.remote_candidates.insert(sequence, candidate);
        }
    }

    fn rollback_candidate(&mut self, sequence: u64) {
        self.remote_candidates_pending.remove(&sequence);
    }
}

struct ManagedHelper {
    session_id: String,
    owner_device_id: String,
    stop: Option<tokio::sync::oneshot::Sender<StopCommand>>,
    join: tokio::task::JoinHandle<()>,
    signaling: Arc<tokio::sync::Mutex<SignalingState>>,
    commands: tokio::sync::mpsc::Sender<HelperCommand>,
    viewer_activity: tokio::sync::mpsc::Sender<()>,
}

pub struct ComputerSessionSupervisor {
    active: tokio::sync::Mutex<Option<ManagedHelper>>,
    pub(crate) control_acquire: tokio::sync::Mutex<()>,
    control_capable: AtomicBool,
}

impl Default for ComputerSessionSupervisor {
    fn default() -> Self {
        Self {
            active: tokio::sync::Mutex::new(None),
            control_acquire: tokio::sync::Mutex::new(()),
            control_capable: AtomicBool::new(false),
        }
    }
}

impl ComputerSessionSupervisor {
    fn control_capable(&self) -> bool {
        self.control_capable.load(Ordering::Acquire)
    }

    fn set_control_capable(&self, value: bool) {
        self.control_capable.store(value, Ordering::Release);
    }

    pub async fn start(
        self: &Arc<Self>,
        state: AppState,
        session: StoredComputerSession,
    ) -> Result<(), SupervisorStartError> {
        self.start_with_viewer_activity_lease(state, session, VIEWER_ACTIVITY_LEASE)
            .await
    }

    async fn start_with_viewer_activity_lease(
        self: &Arc<Self>,
        state: AppState,
        session: StoredComputerSession,
        viewer_activity_lease: Duration,
    ) -> Result<(), SupervisorStartError> {
        if !provider_available(&state) {
            return Err(SupervisorStartError::Unavailable);
        }

        if let Some(active) = state
            .store
            .active_computer_session_for_host(&state.host_installation_id)
            .await
            .map_err(|_| SupervisorStartError::Conflict)?
        {
            if active.id != session.id {
                return Err(SupervisorStartError::Conflict);
            }
        }

        {
            let active = self.active.lock().await;
            if let Some(active) = active.as_ref() {
                if active.session_id == session.id
                    && active.owner_device_id == session.owner_device_id
                {
                    return Ok(());
                }
                return Err(SupervisorStartError::Conflict);
            }
        }

        let binary = state
            .computer_use_bin
            .clone()
            .ok_or(SupervisorStartError::Unavailable)?;
        self.set_control_capable(false);
        let handshake = uuid::Uuid::new_v4().to_string();
        let mut command = Command::new(binary);
        command
            .env("WONDER_COMPUTER_USE_HANDSHAKE", &handshake)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);
        let mut child = command.spawn().map_err(|_| SupervisorStartError::Spawn)?;
        let Some(stdin) = child.stdin.take() else {
            let _ = child.kill().await;
            let _ = child.wait().await;
            return Err(SupervisorStartError::Spawn);
        };
        let Some(stdout) = child.stdout.take() else {
            let _ = child.kill().await;
            let _ = child.wait().await;
            return Err(SupervisorStartError::Spawn);
        };
        let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
        let (command_tx, command_rx) = tokio::sync::mpsc::channel(64);
        let (viewer_activity_tx, viewer_activity_rx) = tokio::sync::mpsc::channel(1);
        let signaling = Arc::new(tokio::sync::Mutex::new(SignalingState::default()));
        let supervisor = Arc::clone(self);
        let session_id = session.id.clone();
        let owner_device_id = session.owner_device_id.clone();
        let revocations = state.revocations.subscribe();
        let join = tokio::spawn(supervise_helper(
            supervisor,
            state,
            session,
            handshake,
            child,
            stdin,
            stdout,
            stop_rx,
            revocations,
            command_rx,
            viewer_activity_rx,
            viewer_activity_lease,
            Arc::clone(&signaling),
        ));
        let mut active = self.active.lock().await;
        if active.is_some() {
            let _ = stop_tx.send(StopCommand {
                reason: "provider_conflict".into(),
                end_session: false,
            });
            reap_join(join, Duration::from_secs(1)).await;
            return Err(SupervisorStartError::Conflict);
        }
        *active = Some(ManagedHelper {
            session_id,
            owner_device_id,
            stop: Some(stop_tx),
            join,
            signaling,
            commands: command_tx,
            viewer_activity: viewer_activity_tx,
        });
        Ok(())
    }

    pub async fn stop(&self, state: &AppState, session_id: &str, reason: &str) {
        let managed = {
            let mut active = self.active.lock().await;
            if active
                .as_ref()
                .is_some_and(|value| value.session_id == session_id)
            {
                active.take()
            } else {
                None
            }
        };
        if let Some(mut managed) = managed {
            if let Some(stop) = managed.stop.take() {
                let _ = stop.send(StopCommand {
                    reason: reason.into(),
                    end_session: false,
                });
            }
            reap_join(managed.join, Duration::from_secs(3)).await;
        }
        self.set_control_capable(false);
        let _ = state
            .store
            .release_computer_control_lease_for_session(
                session_id,
                &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            )
            .await;
    }

    pub async fn shutdown(&self, state: &AppState) {
        let managed = self.active.lock().await.take();
        let Some(mut managed) = managed else {
            self.set_control_capable(false);
            return;
        };
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        if let Ok(Some(session)) = state.store.computer_session(&managed.session_id).await {
            if session.state != ComputerSessionState::Ended.as_str() {
                if let Ok(Some(ended)) = state
                    .store
                    .end_computer_session(
                        &session.id,
                        &session.owner_device_id,
                        Some(session.generation),
                        &now,
                    )
                    .await
                {
                    let _ = state
                        .store
                        .release_computer_control_lease_for_session(&ended.id, &now)
                        .await;
                    publish_session_event(state, &ended).await;
                }
            }
        }
        if let Some(stop) = managed.stop.take() {
            let _ = stop.send(StopCommand {
                reason: "daemon_shutdown".into(),
                end_session: false,
            });
        }
        reap_join(managed.join, Duration::from_secs(3)).await;
        self.set_control_capable(false);
    }

    pub async fn retire_durable_sessions(&self, state: &AppState) {
        let Ok(sessions) = state
            .store
            .active_computer_sessions_for_host(&state.host_installation_id)
            .await
        else {
            return;
        };
        for session in sessions {
            let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
            if let Ok(Some(ended)) = state
                .store
                .end_computer_session(
                    &session.id,
                    &session.owner_device_id,
                    Some(session.generation),
                    &now,
                )
                .await
            {
                let _ = state
                    .store
                    .release_computer_control_lease_for_session(&ended.id, &now)
                    .await;
                publish_session_event(state, &ended).await;
            }
        }
    }

    async fn clear_if(&self, session_id: &str) {
        let mut active = self.active.lock().await;
        if active
            .as_ref()
            .is_some_and(|value| value.session_id == session_id)
        {
            active.take();
            self.set_control_capable(false);
        }
    }

    async fn signaling_handle(
        &self,
        session_id: &str,
        owner_device_id: &str,
    ) -> Option<SignalingHandle> {
        let active = self.active.lock().await;
        let managed = active.as_ref().filter(|value| {
            value.session_id == session_id && value.owner_device_id == owner_device_id
        })?;
        Some(SignalingHandle {
            signaling: Arc::clone(&managed.signaling),
            commands: managed.commands.clone(),
            viewer_activity: managed.viewer_activity.clone(),
        })
    }
}

async fn reap_join(mut join: tokio::task::JoinHandle<()>, wait: Duration) {
    if timeout(wait, &mut join).await.is_err() {
        join.abort();
        let _ = join.await;
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HelperStatus {
    state: String,
    #[serde(rename = "sessionID", alias = "sessionId")]
    session_id: Option<String>,
    generation: Option<u64>,
    #[serde(rename = "sourceID", alias = "sourceId")]
    source_id: Option<String>,
    #[serde(rename = "geometryRevision", alias = "geometry_revision")]
    geometry_revision: Option<u64>,
    reason: Option<String>,
    message: Option<String>,
    last_frame: Option<HelperFrameMetadata>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HelperControlCapability {
    available: bool,
    provider: String,
    requires_accessibility: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HelperCapabilities {
    protocol_version: u64,
    control: HelperControlCapability,
}

fn verified_helper_control_capability(value: &serde_json::Value) -> bool {
    serde_json::from_value::<HelperCapabilities>(
        value
            .get("result")
            .cloned()
            .unwrap_or(serde_json::Value::Null),
    )
    .map(|capability| {
        capability.protocol_version == 1
            && capability.control.available
            && capability.control.provider == "core-graphics-v1"
            && capability.control.requires_accessibility
    })
    .unwrap_or(false)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HelperSource {
    id: Option<String>,
    title: Option<String>,
    kind: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    scale: Option<f64>,
    content_rect: Option<HelperRect>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct HelperRect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HelperFrameMetadata {
    #[serde(rename = "sessionID", alias = "sessionId")]
    session_id: Option<String>,
    generation: Option<u64>,
    source_width: Option<u32>,
    source_height: Option<u32>,
    scale: Option<f64>,
}

fn command_line(id: u64, method: &str, params: serde_json::Value) -> Vec<u8> {
    let mut request = serde_json::json!({
        "id": id,
        "method": method,
        "params": params,
    })
    .to_string()
    .into_bytes();
    request.push(b'\n');
    request
}

async fn write_helper_request(
    stdin: &mut tokio::process::ChildStdin,
    id: u64,
    method: &str,
    params: serde_json::Value,
) -> std::io::Result<()> {
    let line = command_line(id, method, params);
    if line.len() > MAX_HELPER_LINE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "helper request is too large",
        ));
    }
    stdin.write_all(&line).await?;
    stdin.flush().await
}

async fn read_bounded_line<R>(
    reader: &mut R,
    buffer: &mut Vec<u8>,
) -> std::io::Result<Option<Vec<u8>>>
where
    R: tokio::io::AsyncBufRead + Unpin,
{
    buffer.clear();
    loop {
        let chunk = reader.fill_buf().await?;
        if chunk.is_empty() {
            return if buffer.is_empty() {
                Ok(None)
            } else {
                Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "helper emitted an unterminated line",
                ))
            };
        }
        let newline = chunk.iter().position(|byte| *byte == b'\n');
        let take = newline.map_or(chunk.len(), |index| index + 1);
        if buffer.len() + take > MAX_HELPER_LINE_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "helper line is too large",
            ));
        }
        buffer.extend_from_slice(&chunk[..take]);
        reader.consume(take);
        if newline.is_some() {
            if buffer.last() == Some(&b'\n') {
                buffer.pop();
            }
            if buffer.last() == Some(&b'\r') {
                buffer.pop();
            }
            return Ok(Some(std::mem::take(buffer)));
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn supervise_helper(
    supervisor: Arc<ComputerSessionSupervisor>,
    state: AppState,
    session: StoredComputerSession,
    handshake: String,
    mut child: tokio::process::Child,
    mut stdin: tokio::process::ChildStdin,
    stdout: tokio::process::ChildStdout,
    mut stop_rx: tokio::sync::oneshot::Receiver<StopCommand>,
    mut revocations: tokio::sync::broadcast::Receiver<String>,
    mut command_rx: tokio::sync::mpsc::Receiver<HelperCommand>,
    mut viewer_activity_rx: tokio::sync::mpsc::Receiver<()>,
    viewer_activity_lease_duration: Duration,
    signaling: Arc<tokio::sync::Mutex<SignalingState>>,
) {
    let common = serde_json::json!({
        "sessionID": session.id,
        "generation": session.generation,
        "handshake": handshake,
    });
    let prepare_params = common
        .clone()
        .as_object()
        .cloned()
        .map(|mut params| {
            params.insert("viewerCount".into(), serde_json::json!(1));
            serde_json::Value::Object(params)
        })
        .unwrap_or_default();
    let pick_params = common.clone();
    let pick_params = if let Some(source_id) = session.source_id.as_deref() {
        pick_params
            .as_object()
            .cloned()
            .map(|mut params| {
                params.insert("sourceID".into(), serde_json::json!(source_id));
                serde_json::Value::Object(params)
            })
            .unwrap_or_default()
    } else {
        pick_params
    };
    let mut startup_pending = std::collections::BTreeSet::from(["2".to_owned(), "3".to_owned()]);
    let mut pending_control: BTreeMap<
        u64,
        tokio::sync::oneshot::Sender<Result<serde_json::Value, String>>,
    > = BTreeMap::new();
    let mut reader = BufReader::new(stdout);
    let mut line = Vec::with_capacity(4096);
    let mut next_command_id = 4_u64;
    let startup_timer = tokio::time::sleep(HELPER_STARTUP_TIMEOUT);
    tokio::pin!(startup_timer);
    let mut viewer_activity_lease =
        ViewerActivityLease::with_duration(viewer_activity_lease_duration);
    let mut viewer_activity_open = true;
    let mut intentional_stop = None;

    if write_helper_request(
        &mut stdin,
        1,
        "capabilities",
        serde_json::json!({ "handshake": handshake }),
    )
    .await
    .is_err()
        || write_helper_request(&mut stdin, 2, "capture.prepare", prepare_params)
            .await
            .is_err()
        || write_helper_request(&mut stdin, 3, "capture.pick", pick_params)
            .await
            .is_err()
    {
        fail_session(&state, &session, "helper_write_failed").await;
        stop_child(&mut child, &mut stdin, &handshake).await;
        supervisor.clear_if(&session.id).await;
        return;
    }

    loop {
        tokio::select! {
            line_result = read_bounded_line(&mut reader, &mut line) => {
                match line_result {
                    Ok(None) => break,
                    Ok(Some(raw)) => {
                        match serde_json::from_slice::<serde_json::Value>(&raw) {
                            Ok(value) => {
                                if value.get("id").and_then(serde_json::Value::as_u64) == Some(1) {
                                    supervisor.set_control_capable(verified_helper_control_capability(&value));
                                    // Older helpers do not know capability
                                    // negotiation; that response is optional
                                    // so view-only startup remains compatible.
                                    if value.get("error").is_some() {
                                        continue;
                                    }
                                }
                                if let Some(id) = value.get("id").and_then(helper_id) {
                                    startup_pending.remove(&id);
                                }
                                if let Some(id) = value.get("id").and_then(serde_json::Value::as_u64) {
                                    if let Some(response) = pending_control.remove(&id) {
                                        let result = if let Some(error) = value
                                            .get("error")
                                            .and_then(|error| error.get("code"))
                                            .and_then(serde_json::Value::as_str)
                                        {
                                            Err(error.to_owned())
                                        } else {
                                            value
                                                .get("result")
                                                .cloned()
                                                .ok_or_else(|| "helper response was invalid".to_owned())
                                        };
                                        let _ = response.send(result);
                                        continue;
                                    }
                                }
                                match apply_helper_value_with_signaling(&state, &session, &value, &signaling).await {
                                    Ok(HelperValueAction::ControlRevoked {
                                        lease_id,
                                        request_id,
                                        generation,
                                        geometry_revision,
                                        source_id,
                                        reason: _,
                                    }) => {
                                        if let Ok(Some(lease)) = state.store.computer_control_lease(&lease_id).await {
                                            if lease.client_request_id == request_id
                                                && lease.session_id == session.id
                                                && lease.owner_device_id == session.owner_device_id
                                                && lease.host_installation_id == session.host_installation_id
                                                && lease.conversation_id == session.conversation_id
                                                && lease.session_generation == generation
                                                && lease.geometry_revision == geometry_revision
                                                && lease.source_id == source_id
                                            {
                                                let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
                                                let _ = state
                                                    .store
                                                    .release_computer_control_lease(&lease_id, &session.owner_device_id, &now)
                                                    .await;
                                            }
                                        }
                                    }
                                    Ok(HelperValueAction::StartCapture) => {
                                        let start_params = common.clone();
                                        let _ = write_helper_request(&mut stdin, next_command_id, "capture.start", start_params).await;
                                        next_command_id = next_command_id.saturating_add(1);
                                    }
                                    Ok(HelperValueAction::StopCapture { reason }) => {
                                        let mut stop_params = common.clone();
                                        if let Some(object) = stop_params.as_object_mut() {
                                            object.insert("reason".into(), serde_json::Value::String(reason.clone()));
                                        }
                                        let _ = write_helper_request(&mut stdin, next_command_id, "capture.stop", stop_params).await;
                                        intentional_stop = Some(StopCommand { reason, end_session: false });
                                        break;
                                    }
                                    Ok(HelperValueAction::None) => {}
                                    Ok(HelperValueAction::ProtocolError) => {
                                        fail_session(&state, &session, "helper_protocol_error").await;
                                        intentional_stop = Some(StopCommand { reason: "helper_protocol_error".into(), end_session: false });
                                        break;
                                    }
                                    Err(_) => {
                                        fail_session(&state, &session, "helper_state_update_failed").await;
                                        intentional_stop = Some(StopCommand { reason: "helper_state_update_failed".into(), end_session: false });
                                        break;
                                    }
                                }
                            }
                            Err(_) => {
                                fail_session(&state, &session, "helper_invalid_json").await;
                                intentional_stop = Some(StopCommand { reason: "helper_invalid_json".into(), end_session: false });
                                break;
                            }
                        }
                    }
                    Err(error) => {
                        let reason = if error.kind() == std::io::ErrorKind::InvalidData {
                            "helper_line_too_large"
                        } else {
                            "helper_read_failed"
                        };
                        fail_session(&state, &session, reason).await;
                        intentional_stop = Some(StopCommand { reason: reason.into(), end_session: false });
                        break;
                    }
                }
            }
            stop = &mut stop_rx => {
                intentional_stop = Some(stop.unwrap_or(StopCommand { reason: "supervisor_dropped".into(), end_session: true }));
                break;
            }
            command = command_rx.recv() => {
                let Some(command) = command else {
                    intentional_stop = Some(StopCommand { reason: "signaling_channel_closed".into(), end_session: true });
                    break;
                };
                if let HelperCommand::Control { method, params, response } = command {
                    let mut full_params = common.clone();
                    if let (Some(full), Some(extra)) = (full_params.as_object_mut(), params.as_object()) {
                        full.extend(extra.clone());
                    }
                    let command_id = next_command_id;
                    pending_control.insert(command_id, response);
                    if write_helper_request(&mut stdin, command_id, &method, full_params).await.is_err() {
                        if let Some(response) = pending_control.remove(&command_id) {
                            let _ = response.send(Err("helper_write_failed".into()));
                        }
                        fail_session(&state, &session, "helper_write_failed").await;
                        intentional_stop = Some(StopCommand { reason: "helper_write_failed".into(), end_session: false });
                        break;
                    }
                    next_command_id = next_command_id.saturating_add(1);
                    continue;
                }
                let (method, params, delivered) = match command {
                    HelperCommand::RemoteAnswer { peer_revision, sdp, delivered } => {
                        let mut params = common.clone();
                        if let Some(object) = params.as_object_mut() {
                            object.insert("peerRevision".into(), serde_json::Value::String(peer_revision));
                            object.insert("sdp".into(), serde_json::Value::String(sdp));
                        }
                        ("signal.answer", params, delivered)
                    }
                    HelperCommand::RemoteCandidate { peer_revision, sequence, candidate, sdp_mid, sdp_m_line_index, username_fragment, delivered } => {
                        let mut params = common.clone();
                        if let Some(object) = params.as_object_mut() {
                            object.insert("peerRevision".into(), serde_json::Value::String(peer_revision));
                            object.insert("sequence".into(), serde_json::json!(sequence));
                            object.insert("candidate".into(), serde_json::Value::String(candidate));
                            object.insert("sdpMid".into(), sdp_mid.map_or(serde_json::Value::Null, serde_json::Value::String));
                            object.insert("sdpMLineIndex".into(), serde_json::json!(sdp_m_line_index));
                            object.insert("usernameFragment".into(), username_fragment.map_or(serde_json::Value::Null, serde_json::Value::String));
                        }
                        ("signal.candidate", params, delivered)
                    }
                    HelperCommand::CloseSignal { peer_revision, reason, delivered } => {
                        let mut params = common.clone();
                        if let Some(object) = params.as_object_mut() {
                            object.insert("peerRevision".into(), serde_json::Value::String(peer_revision));
                            object.insert("reason".into(), serde_json::Value::String(reason));
                        }
                        ("signal.close", params, delivered)
                    }
                    HelperCommand::Control { .. } => unreachable!(),
                };
                let was_delivered = write_helper_request(&mut stdin, next_command_id, method, params.clone()).await.is_ok();
                {
                    let mut current = signaling.lock().await;
                    match method {
                        "signal.answer" => {
                            if let Some(sdp) = params.get("sdp").and_then(serde_json::Value::as_str) {
                                if was_delivered { current.commit_answer(sdp); } else { current.rollback_answer(sdp); }
                            }
                        }
                        "signal.candidate" => {
                            if let Some(sequence) = params.get("sequence").and_then(serde_json::Value::as_u64) {
                                if was_delivered { current.commit_candidate(sequence); } else { current.rollback_candidate(sequence); }
                            }
                        }
                        "signal.close" if was_delivered => {
                            current.closed = true;
                            current.peer_state = "closed".into();
                            let reason = params.get("reason").and_then(serde_json::Value::as_str).unwrap_or("closed_by_viewer");
                            current.clear_ephemeral(Some(reason.to_owned()));
                        }
                        _ => {}
                    }
                }
                let _ = delivered.send(was_delivered);
                if !was_delivered {
                    fail_session(&state, &session, "helper_write_failed").await;
                    intentional_stop = Some(StopCommand { reason: "helper_write_failed".into(), end_session: false });
                    break;
                }
                next_command_id = next_command_id.saturating_add(1);
            }
            activity = viewer_activity_rx.recv(), if viewer_activity_open => {
                if activity.is_some() {
                    viewer_activity_lease.reset();
                } else {
                    viewer_activity_open = false;
                }
            }
            revoked = revocations.recv() => {
                match revoked {
                    Ok(device_id) if device_id == session.owner_device_id => {
                        intentional_stop = Some(StopCommand { reason: "owner_revoked".into(), end_session: true });
                        break;
                    }
                    Ok(_) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_))
                    | Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        intentional_stop = Some(StopCommand { reason: "revocation_channel_unavailable".into(), end_session: true });
                        break;
                    }
                }
            }
            _ = &mut startup_timer, if !startup_pending.is_empty() => {
                fail_session(&state, &session, "helper_startup_timeout").await;
                intentional_stop = Some(StopCommand { reason: "helper_startup_timeout".into(), end_session: false });
                break;
            }
            _ = viewer_activity_lease.timer.as_mut() => {
                // A valid request can race the deadline after coalescing into
                // the one-slot channel. Honor that activity before failing
                // closed instead of expiring a viewer that is still polling.
                if viewer_activity_rx.try_recv().is_ok() {
                    viewer_activity_lease.reset();
                    continue;
                }
                intentional_stop = Some(StopCommand { reason: "viewer_timeout".into(), end_session: true });
                break;
            }
        }
    }

    for (_, response) in pending_control {
        let _ = response.send(Err("computer helper stopped".into()));
    }

    if let Some(stop) = intentional_stop {
        stop_child(&mut child, &mut stdin, &handshake).await;
        if stop.end_session {
            end_session_for_owner(&state, &session, &stop.reason).await;
        }
    } else {
        let _ = child.wait().await;
        fail_session(&state, &session, "helper_exited").await;
    }
    supervisor.clear_if(&session.id).await;
}

fn helper_id(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(value) if !value.is_empty() => Some(value.clone()),
        serde_json::Value::Number(value) => Some(value.to_string()),
        _ => None,
    }
}

#[derive(Debug, PartialEq, Eq)]
enum HelperValueAction {
    None,
    ControlRevoked {
        lease_id: String,
        request_id: String,
        generation: u64,
        geometry_revision: u64,
        source_id: Option<String>,
        reason: String,
    },
    StartCapture,
    StopCapture {
        reason: String,
    },
    ProtocolError,
}

#[cfg(test)]
async fn apply_helper_value(
    state: &AppState,
    session: &StoredComputerSession,
    value: &serde_json::Value,
) -> Result<bool, sqlx::Error> {
    let signaling = Arc::new(tokio::sync::Mutex::new(SignalingState::default()));
    Ok(!matches!(
        apply_helper_value_with_signaling(state, session, value, &signaling).await?,
        HelperValueAction::ProtocolError
    ))
}

async fn apply_helper_value_with_signaling(
    state: &AppState,
    session: &StoredComputerSession,
    value: &serde_json::Value,
    signaling: &Arc<tokio::sync::Mutex<SignalingState>>,
) -> Result<HelperValueAction, sqlx::Error> {
    if value.get("error").is_some() {
        return Ok(HelperValueAction::ProtocolError);
    }

    if let Some(event) = value.get("event").and_then(serde_json::Value::as_str) {
        let event_session = value.get("sessionID").and_then(serde_json::Value::as_str);
        let event_generation = value.get("generation").and_then(serde_json::Value::as_u64);
        let event_peer_revision = value
            .get("peerRevision")
            .and_then(serde_json::Value::as_str);
        if event.starts_with("signal.")
            && (event_session.is_none()
                || event_generation.is_none()
                || event_peer_revision.is_none()
                || !event_peer_revision.is_some_and(|revision| valid_signaling_text(revision, 128)))
        {
            return Ok(HelperValueAction::ProtocolError);
        }
        if (event_session.is_some() || event_generation.is_some())
            && (event_session != Some(session.id.as_str())
                || event_generation != Some(session.generation))
        {
            return Ok(HelperValueAction::None);
        }
        if event.starts_with("signal.") && event != "signal.peerReady" {
            let current = signaling.lock().await;
            if current.peer_revision.is_some()
                && current.peer_revision.as_deref() != event_peer_revision
            {
                return Ok(HelperValueAction::None);
            }
        }
        match event {
            "control.revoked" => {
                if event_session != Some(session.id.as_str())
                    || event_generation != Some(session.generation)
                {
                    return Ok(HelperValueAction::ProtocolError);
                }
                let Some(reason) = value
                    .get("reason")
                    .and_then(serde_json::Value::as_str)
                    .filter(|reason| valid_signaling_text(reason, 128))
                else {
                    return Ok(HelperValueAction::ProtocolError);
                };
                let Some(lease_id) = value
                    .get("leaseID")
                    .and_then(serde_json::Value::as_str)
                    .filter(|lease_id| valid_signaling_text(lease_id, 128))
                else {
                    return Ok(HelperValueAction::ProtocolError);
                };
                if lease_id.is_empty() {
                    return Ok(HelperValueAction::ProtocolError);
                }
                let Some(request_id) = value
                    .get("requestID")
                    .and_then(serde_json::Value::as_str)
                    .filter(|request_id| valid_signaling_text(request_id, 160))
                else {
                    return Ok(HelperValueAction::ProtocolError);
                };
                let Some(geometry_revision) = value
                    .get("geometryRevision")
                    .and_then(serde_json::Value::as_u64)
                else {
                    return Ok(HelperValueAction::ProtocolError);
                };
                let source_id = match value.get("sourceID") {
                    None | Some(serde_json::Value::Null) => None,
                    Some(serde_json::Value::String(source_id))
                        if valid_signaling_text(source_id, 160) =>
                    {
                        Some(source_id.clone())
                    }
                    _ => return Ok(HelperValueAction::ProtocolError),
                };
                return Ok(HelperValueAction::ControlRevoked {
                    lease_id: lease_id.to_owned(),
                    request_id: request_id.to_owned(),
                    generation: session.generation,
                    geometry_revision,
                    source_id,
                    reason: reason.to_owned(),
                });
            }
            "signal.peerReady" => {
                let mut current = signaling.lock().await;
                if current.peer_revision.is_none() {
                    current.peer_revision = event_peer_revision.map(str::to_owned);
                    current.closed = false;
                    current.peer_state = "new".into();
                    current.first_frame_observed = false;
                }
                return Ok(HelperValueAction::None);
            }
            "signal.offer" => {
                let Some(sdp) = value.get("sdp").and_then(serde_json::Value::as_str) else {
                    return Ok(HelperValueAction::ProtocolError);
                };
                if value.get("type").and_then(serde_json::Value::as_str) != Some("offer")
                    || !valid_sdp(sdp)
                {
                    return Ok(HelperValueAction::ProtocolError);
                }
                let mut current = signaling.lock().await;
                if current.closed {
                    return Ok(HelperValueAction::None);
                }
                if current.peer_revision.is_none() {
                    current.peer_revision = event_peer_revision.map(str::to_owned);
                }
                let offer = SignalingDescription {
                    kind: "offer".into(),
                    sdp: sdp.to_owned(),
                };
                if let Some(existing) = current.offer.as_ref() {
                    if existing != &offer {
                        return Ok(HelperValueAction::ProtocolError);
                    }
                    return Ok(HelperValueAction::None);
                }
                current.offer = Some(offer);
                return Ok(HelperValueAction::None);
            }
            "signal.candidate" => {
                let Some(candidate) = value.get("candidate").and_then(serde_json::Value::as_str)
                else {
                    return Ok(HelperValueAction::ProtocolError);
                };
                let sdp_m_line_index = value
                    .get("sdpMLineIndex")
                    .and_then(serde_json::Value::as_u64)
                    .and_then(|value| u32::try_from(value).ok());
                let Some(sdp_m_line_index) = sdp_m_line_index else {
                    return Ok(HelperValueAction::ProtocolError);
                };
                if sdp_m_line_index > i32::MAX as u32 {
                    return Ok(HelperValueAction::ProtocolError);
                }
                if candidate.len() > MAX_SIGNALING_CANDIDATE_BYTES
                    || !candidate.starts_with("candidate:")
                    || candidate.chars().any(char::is_control)
                {
                    return Ok(HelperValueAction::ProtocolError);
                }
                let sdp_mid = value
                    .get("sdpMid")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned);
                if sdp_mid
                    .as_deref()
                    .is_some_and(|value| !valid_signaling_text(value, 128))
                {
                    return Ok(HelperValueAction::ProtocolError);
                }
                let username_fragment = value
                    .get("usernameFragment")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned);
                if username_fragment
                    .as_deref()
                    .is_some_and(|value| !valid_signaling_text(value, 256))
                {
                    return Ok(HelperValueAction::ProtocolError);
                }
                let mut current = signaling.lock().await;
                if current.local_candidates.iter().any(|existing| {
                    existing.candidate == candidate
                        && existing.sdp_mid == sdp_mid
                        && existing.sdp_m_line_index == sdp_m_line_index
                        && existing.username_fragment == username_fragment
                }) {
                    return Ok(HelperValueAction::None);
                }
                if current.local_candidates.len() >= MAX_SIGNALING_CANDIDATES {
                    return Ok(HelperValueAction::ProtocolError);
                }
                let sequence = current
                    .local_candidates
                    .back()
                    .map_or(1, |candidate| candidate.sequence.saturating_add(1));
                current.local_candidates.push_back(SignalingCandidate {
                    sequence,
                    candidate: candidate.to_owned(),
                    sdp_mid,
                    sdp_m_line_index,
                    username_fragment,
                });
                return Ok(HelperValueAction::None);
            }
            "signal.peerState" => {
                let Some(peer_state) = value.get("state").and_then(serde_json::Value::as_str)
                else {
                    return Ok(HelperValueAction::ProtocolError);
                };
                if !matches!(
                    peer_state,
                    "new"
                        | "checking"
                        | "connected"
                        | "completed"
                        | "failed"
                        | "disconnected"
                        | "closed"
                        | "unknown"
                ) {
                    return Ok(HelperValueAction::ProtocolError);
                }
                let terminal = matches!(peer_state, "failed" | "disconnected" | "closed");
                {
                    let mut current = signaling.lock().await;
                    current.peer_state = peer_state.to_owned();
                    if terminal {
                        current.failure_reason = Some(match peer_state {
                            "disconnected" => "peer_connection_disconnected".into(),
                            "closed" => "peer_connection_closed".into(),
                            _ => "peer_connection_failed".into(),
                        });
                    }
                }
                reconcile_media_state(state, session, signaling).await?;
                if terminal {
                    return Ok(HelperValueAction::StopCapture {
                        reason: "peer_connection_terminal".into(),
                    });
                }
                return Ok(HelperValueAction::None);
            }
            "signal.failed" => {
                let Some(reason) = value
                    .get("reason")
                    .and_then(serde_json::Value::as_str)
                    .filter(|reason| valid_signaling_text(reason, 128))
                else {
                    return Ok(HelperValueAction::ProtocolError);
                };
                signaling.lock().await.failure_reason = Some(reason.to_owned());
                reconcile_media_state(state, session, signaling).await?;
                return Ok(HelperValueAction::StopCapture {
                    reason: "peer_connection_failed".into(),
                });
            }
            "signal.closed" => {
                let Some(reason) = value
                    .get("reason")
                    .and_then(serde_json::Value::as_str)
                    .filter(|reason| valid_signaling_text(reason, 128))
                else {
                    return Ok(HelperValueAction::ProtocolError);
                };
                let mut current = signaling.lock().await;
                current.closed = true;
                current.peer_state = "closed".into();
                current.clear_ephemeral(Some(reason.to_owned()));
                drop(current);
                reconcile_media_state(state, session, signaling).await?;
                return Ok(HelperValueAction::StopCapture {
                    reason: "publisher_closed".into(),
                });
            }
            "signal.answerApplied" => return Ok(HelperValueAction::None),
            _ if event.starts_with("signal.") => return Ok(HelperValueAction::ProtocolError),
            _ => {}
        }
    }
    let status_value = value
        .get("result")
        .and_then(|result| result.get("status"))
        .or_else(|| value.get("status"));
    let Some(status_value) = status_value else {
        return Ok(
            if value.get("id").is_some() || value.get("event").is_some() {
                HelperValueAction::None
            } else {
                HelperValueAction::ProtocolError
            },
        );
    };
    let Ok(status) = serde_json::from_value::<HelperStatus>(status_value.clone()) else {
        return Ok(HelperValueAction::ProtocolError);
    };
    // A late event from a previous helper/session is ignored, never applied to
    // the current durable row.
    if status.session_id.as_deref() != Some(session.id.as_str())
        || status.generation != Some(session.generation)
    {
        return Ok(HelperValueAction::None);
    }
    if !matches!(
        status.state.as_str(),
        "awaitingSource"
            | "ready"
            | "starting"
            | "capturing"
            | "paused"
            | "suspended"
            | "idle"
            | "permissionDenied"
            | "sourceRemoved"
            | "failed"
            | "stopped"
            | "helperRestarted"
    ) {
        return Ok(HelperValueAction::ProtocolError);
    }
    let frame_metadata =
        value.get("event").and_then(serde_json::Value::as_str) == Some("capture.frameMetadata");
    let identity_valid_frame_metadata =
        frame_metadata && frame_metadata_matches_session(status.last_frame.as_ref(), session);
    let capture_prepared =
        value.get("event").and_then(serde_json::Value::as_str) == Some("capture.prepared");
    let capture_changed = {
        let mut current = signaling.lock().await;
        let changed = capture_prepared
            || current.capture_state != status.state
            || (identity_valid_frame_metadata && !current.first_frame_observed);
        if capture_prepared {
            current.clear_ephemeral(None);
            current.closed = false;
            current.peer_state = "new".into();
        }
        if identity_valid_frame_metadata {
            current.first_frame_observed = true;
        }
        current.capture_state = status.state.clone();
        if matches!(
            status.state.as_str(),
            "permissionDenied" | "sourceRemoved" | "failed" | "stopped" | "helperRestarted"
        ) {
            current.failure_reason = Some(
                status
                    .reason
                    .as_deref()
                    .or(status.message.as_deref())
                    .unwrap_or("helper_capture_failed")
                    .to_owned(),
            );
        }
        changed
    };
    if frame_metadata && !capture_changed {
        return Ok(HelperValueAction::None);
    }
    let (state_value, failure_reason) = {
        let current = signaling.lock().await;
        desired_media_state(&current)
    };
    let source = value
        .get("source")
        .and_then(|value| serde_json::from_value::<HelperSource>(value.clone()).ok());
    let frame = identity_valid_frame_metadata
        .then_some(status.last_frame.as_ref())
        .flatten();
    let content_rect_json = source
        .as_ref()
        .and_then(|value| value.content_rect.as_ref())
        .and_then(|value| serde_json::to_string(value).ok());
    let updated = state
        .store
        .transition_computer_session(
            &session.id,
            session.generation,
            state_value,
            status
                .source_id
                .as_deref()
                .or_else(|| source.as_ref().and_then(|value| value.id.as_deref())),
            source.as_ref().and_then(|value| value.title.as_deref()),
            source.as_ref().and_then(|value| value.kind.as_deref()),
            frame
                .and_then(|value| value.source_width)
                .or_else(|| source.as_ref().and_then(|value| value.width)),
            frame
                .and_then(|value| value.source_height)
                .or_else(|| source.as_ref().and_then(|value| value.height)),
            frame
                .and_then(|value| value.scale)
                .or_else(|| source.as_ref().and_then(|value| value.scale)),
            content_rect_json.as_deref(),
            status.geometry_revision.unwrap_or(0),
            failure_reason.as_deref(),
            &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        )
        .await?;
    let Some(updated) = updated else {
        return Ok(HelperValueAction::None);
    };
    publish_session_event(state, &updated).await;
    if event_is_source_selected(value, &status) {
        Ok(HelperValueAction::StartCapture)
    } else {
        Ok(HelperValueAction::None)
    }
}

fn event_is_source_selected(value: &serde_json::Value, status: &HelperStatus) -> bool {
    value.get("event").and_then(serde_json::Value::as_str) == Some("capture.sourceSelected")
        && status.state == "ready"
}

fn frame_metadata_matches_session(
    frame: Option<&HelperFrameMetadata>,
    session: &StoredComputerSession,
) -> bool {
    frame.is_some_and(|frame| {
        frame.session_id.as_deref() == Some(session.id.as_str())
            && frame.generation == Some(session.generation)
    })
}

fn desired_media_state(signaling: &SignalingState) -> (ComputerSessionState, Option<String>) {
    if signaling.failure_reason.is_some()
        || matches!(
            signaling.peer_state.as_str(),
            "failed" | "disconnected" | "closed"
        )
        || matches!(
            signaling.capture_state.as_str(),
            "permissionDenied" | "sourceRemoved" | "failed" | "stopped" | "helperRestarted"
        )
    {
        return (
            ComputerSessionState::Failed,
            signaling
                .failure_reason
                .clone()
                .or_else(|| Some("computer_media_unavailable".into())),
        );
    }
    if signaling.capture_state == "awaitingSource" {
        return (ComputerSessionState::AwaitingSource, None);
    }
    if signaling.capture_state == "capturing"
        && signaling.first_frame_observed
        && matches!(signaling.peer_state.as_str(), "connected" | "completed")
    {
        return (ComputerSessionState::Live, None);
    }
    (ComputerSessionState::Preparing, None)
}

async fn reconcile_media_state(
    state: &AppState,
    session: &StoredComputerSession,
    signaling: &Arc<tokio::sync::Mutex<SignalingState>>,
) -> Result<(), sqlx::Error> {
    let (desired, failure_reason) = {
        let current = signaling.lock().await;
        desired_media_state(&current)
    };
    let Some(current) = state.store.computer_session(&session.id).await? else {
        return Ok(());
    };
    if current.state == ComputerSessionState::Ended.as_str()
        || (current.state == ComputerSessionState::Failed.as_str()
            && desired != ComputerSessionState::Failed)
    {
        return Ok(());
    }
    if current.state == desired.as_str() && current.failure_reason == failure_reason {
        return Ok(());
    }
    if let Ok(Some(updated)) = state
        .store
        .transition_computer_session(
            &session.id,
            session.generation,
            desired,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            current.geometry_revision,
            failure_reason.as_deref(),
            &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        )
        .await
    {
        if desired == ComputerSessionState::Failed {
            let _ = state
                .store
                .release_computer_control_lease_for_session(&session.id, &updated.updated_at)
                .await;
        }
        publish_session_event(state, &updated).await;
    }
    Ok(())
}

async fn fail_session(state: &AppState, session: &StoredComputerSession, reason: &str) {
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    if let Ok(Some(updated)) = state
        .store
        .transition_computer_session(
            &session.id,
            session.generation,
            ComputerSessionState::Failed,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            session.geometry_revision,
            Some(reason),
            &now,
        )
        .await
    {
        let _ = state
            .store
            .release_computer_control_lease_for_session(&session.id, &now)
            .await;
        publish_session_event(state, &updated).await;
    }
}

async fn end_session_for_owner(state: &AppState, session: &StoredComputerSession, reason: &str) {
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    if reason == "viewer_timeout" {
        if let Ok(Some(current)) = state.store.computer_session(&session.id).await {
            if let Ok(state_value) = ComputerSessionState::try_from(current.state.as_str()) {
                let _ = state
                    .store
                    .transition_computer_session(
                        &current.id,
                        current.generation,
                        state_value,
                        None,
                        None,
                        None,
                        None,
                        None,
                        None,
                        None,
                        current.geometry_revision,
                        Some(reason),
                        &now,
                    )
                    .await;
            }
        }
    }
    if let Ok(Some(ended)) = state
        .store
        .end_computer_session(
            &session.id,
            &session.owner_device_id,
            Some(session.generation),
            &now,
        )
        .await
    {
        publish_session_event(state, &ended).await;
    }
    let _ = state
        .store
        .release_computer_control_lease_for_session(&session.id, &now)
        .await;
}

async fn publish_session_event(state: &AppState, session: &StoredComputerSession) {
    let _ = publish_event_with_context(
        state,
        WonderEvent::ComputerSessionChanged {
            session_id: session.id.clone(),
            generation: session.generation,
            state: session.state.clone(),
        },
        EventContext {
            conversation_id: Some(session.conversation_id.clone()),
            ..EventContext::default()
        },
    )
    .await;
}

async fn stop_child(
    child: &mut tokio::process::Child,
    stdin: &mut tokio::process::ChildStdin,
    handshake: &str,
) {
    // Release held native input before asking the helper to exit. The helper
    // repeats this in its stop handler for crash/timeout races.
    let _ = write_helper_request(
        stdin,
        98,
        "control.releaseAll",
        serde_json::json!({ "handshake": handshake }),
    )
    .await;
    let _ = write_helper_request(
        stdin,
        99,
        "stop",
        serde_json::json!({ "handshake": handshake }),
    )
    .await;
    if timeout(Duration::from_millis(750), child.wait())
        .await
        .is_err()
    {
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
}

#[cfg(test)]
mod supervisor_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn session() -> ComputerSessionCreate {
        ComputerSessionCreate {
            id: "fake-session".into(),
            client_request_id: "fake-request".into(),
            owner_device_id: "fake-phone".into(),
            host_installation_id: "test".into(),
            conversation_id: "fake-chat".into(),
            generation: 1,
            state: ComputerSessionState::Preparing,
            source_id: None,
            source_name: None,
            source_kind: None,
            source_width: None,
            source_height: None,
            source_scale: None,
            crop_json: None,
            geometry_revision: 0,
            failure_reason: None,
            now: "now".into(),
        }
    }

    fn stored_session() -> StoredComputerSession {
        StoredComputerSession {
            id: "session".into(),
            client_request_id: "request".into(),
            owner_device_id: "owner".into(),
            host_installation_id: "host".into(),
            conversation_id: "conversation".into(),
            generation: 3,
            state: ComputerSessionState::Preparing.as_str().into(),
            source_id: None,
            source_name: None,
            source_kind: None,
            source_width: None,
            source_height: None,
            source_scale: None,
            crop_json: None,
            geometry_revision: 0,
            failure_reason: None,
            created_at: "now".into(),
            updated_at: "now".into(),
            last_state_at: "now".into(),
            ended_at: None,
        }
    }

    #[test]
    fn signaling_binding_hides_wrong_host_or_conversation_and_conflicts_stale_generation() {
        let session = stored_session();
        let wrong_host = SignalingBinding {
            generation: 3,
            conversation_id: "conversation".into(),
            host_installation_id: "other-host".into(),
            peer_revision: None,
        };
        assert_eq!(
            signal_binding_error(&session, &wrong_host)
                .unwrap()
                .status(),
            StatusCode::NOT_FOUND
        );
        let wrong_conversation = SignalingBinding {
            generation: 3,
            conversation_id: "other-conversation".into(),
            host_installation_id: "host".into(),
            peer_revision: None,
        };
        assert_eq!(
            signal_binding_error(&session, &wrong_conversation)
                .unwrap()
                .status(),
            StatusCode::NOT_FOUND
        );
        let stale = SignalingBinding {
            generation: 2,
            conversation_id: "conversation".into(),
            host_installation_id: "host".into(),
            peer_revision: None,
        };
        assert_eq!(
            signal_binding_error(&session, &stale).unwrap().status(),
            StatusCode::CONFLICT
        );
        let current = SignalingBinding {
            generation: 3,
            conversation_id: "conversation".into(),
            host_installation_id: "host".into(),
            peer_revision: None,
        };
        assert!(signal_binding_error(&session, &current).is_none());
    }

    #[test]
    fn signaling_bounds_reject_oversized_or_wrong_m_line_values() {
        let binding = SignalingBinding {
            generation: 1,
            conversation_id: "conversation".into(),
            host_installation_id: "host".into(),
            peer_revision: None,
        };
        let base = SignalingCandidateRequest {
            binding,
            sequence: 1,
            candidate: "candidate:host".into(),
            sdp_mid: Some("0".into()),
            sdp_m_line_index: 0,
            username_fragment: Some("ufrag".into()),
        };
        assert!(valid_ice_candidate(&base));
        assert!(!valid_ice_candidate(&SignalingCandidateRequest {
            candidate: "candidate:host".into(),
            sdp_m_line_index: i32::MAX as u32 + 1,
            ..base
        }));
        let oversized = format!("v=0\na={} ", "x".repeat(MAX_SIGNALING_SDP_BYTES));
        assert!(!valid_sdp(&oversized));
        assert!(!valid_signaling_text(&"x".repeat(129), 128));
        assert!(!valid_signaling_text("bad\ntext", 128));
    }

    #[test]
    #[allow(clippy::field_reassign_with_default)]
    fn signaling_answer_and_candidate_idempotency_is_reusable_after_rollback() {
        let mut signaling = SignalingState::default();
        signaling.offer = Some(SignalingDescription {
            kind: "offer".into(),
            sdp: "v=0\na=x".into(),
        });
        assert_eq!(signaling.reserve_answer("v=0\na=answer"), Ok(true));
        assert_eq!(
            signaling.reserve_answer("v=0\na=answer"),
            Err("computer answer is still being applied")
        );
        assert!(signaling.reserve_answer("v=0\na=other").is_err());
        signaling.rollback_answer("v=0\na=answer");
        assert_eq!(signaling.reserve_answer("v=0\na=other"), Ok(true));
        signaling.commit_answer("v=0\na=other");
        assert_eq!(signaling.reserve_answer("v=0\na=other"), Ok(false));

        let candidate = SignalingCandidate {
            sequence: 1,
            candidate: "candidate:host".into(),
            sdp_mid: Some("0".into()),
            sdp_m_line_index: 0,
            username_fragment: Some("ufrag".into()),
        };
        assert_eq!(signaling.reserve_candidate(candidate.clone()), Ok(true));
        assert_eq!(
            signaling.reserve_candidate(candidate.clone()),
            Err("computer ICE candidate is still being applied")
        );
        signaling.rollback_candidate(1);
        assert_eq!(signaling.reserve_candidate(candidate.clone()), Ok(true));
        signaling.commit_candidate(1);
        assert_eq!(signaling.remote_candidates.len(), 1);
        assert_eq!(signaling.reserve_candidate(candidate), Ok(false));
    }

    #[test]
    #[allow(clippy::field_reassign_with_default)]
    fn signaling_state_requires_capture_and_encrypted_peer_for_live() {
        let mut signaling = SignalingState::default();
        signaling.capture_state = "ready".into();
        assert_eq!(signaling.public_state(), "preparing");
        signaling.capture_state = "capturing".into();
        assert_eq!(
            desired_media_state(&signaling).0,
            ComputerSessionState::Preparing
        );
        signaling.peer_state = "connected".into();
        assert_eq!(signaling.public_state(), "preparing");
        assert_eq!(
            desired_media_state(&signaling).0,
            ComputerSessionState::Preparing
        );
        signaling.first_frame_observed = true;
        assert_eq!(signaling.public_state(), "live");
        assert_eq!(
            desired_media_state(&signaling).0,
            ComputerSessionState::Live
        );
        signaling.peer_state = "disconnected".into();
        signaling.failure_reason = Some("peer_connection_disconnected".into());
        assert_eq!(
            desired_media_state(&signaling).0,
            ComputerSessionState::Failed
        );
        signaling.clear_ephemeral(Some("closed".into()));
        assert!(signaling.offer.is_none());
        assert!(signaling.local_candidates.is_empty());
        assert!(signaling.remote_candidates.is_empty());
        assert!(signaling.remote_candidates_pending.is_empty());
        assert!(!signaling.first_frame_observed);
    }

    #[test]
    fn identity_valid_frame_metadata_is_required_to_observe_the_first_frame() {
        let session = stored_session();
        let wrong = HelperFrameMetadata {
            session_id: Some("other-session".into()),
            generation: Some(session.generation),
            source_width: Some(3024),
            source_height: Some(1964),
            scale: Some(2.0),
        };
        assert!(!frame_metadata_matches_session(Some(&wrong), &session));

        let valid = HelperFrameMetadata {
            session_id: Some(session.id.clone()),
            generation: Some(session.generation),
            source_width: Some(3024),
            source_height: Some(1964),
            scale: Some(2.0),
        };
        assert!(frame_metadata_matches_session(Some(&valid), &session));
    }

    #[tokio::test]
    async fn unbound_preparing_viewer_activity_lease_expires() {
        let (_activity_tx, mut activity_rx) = tokio::sync::mpsc::channel::<()>(1);
        let mut lease = ViewerActivityLease::with_duration(Duration::from_millis(50));
        let lease_task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = lease.timer.as_mut() => break "viewer_timeout",
                    activity = activity_rx.recv() => {
                        if activity.is_none() {
                            break "viewer_timeout";
                        }
                        lease.reset();
                    }
                }
            }
        });
        tokio::task::yield_now().await;
        tokio::time::sleep(Duration::from_millis(75)).await;
        tokio::task::yield_now().await;
        assert_eq!(lease_task.await.unwrap(), "viewer_timeout");
    }

    #[tokio::test]
    async fn signaling_handle_refreshes_only_after_endpoint_validation() {
        let supervisor = Arc::new(ComputerSessionSupervisor::default());
        let (activity_tx, mut activity_rx) = tokio::sync::mpsc::channel(1);
        let (stop_tx, _stop_rx) = tokio::sync::oneshot::channel();
        let (commands_tx, _commands_rx) = tokio::sync::mpsc::channel(1);
        *supervisor.active.lock().await = Some(ManagedHelper {
            session_id: "session".into(),
            owner_device_id: "owner".into(),
            stop: Some(stop_tx),
            join: tokio::spawn(async {}),
            signaling: Arc::new(tokio::sync::Mutex::new(SignalingState::default())),
            commands: commands_tx,
            viewer_activity: activity_tx,
        });

        assert!(supervisor
            .signaling_handle("session", "other-owner")
            .await
            .is_none());
        let handle = supervisor
            .signaling_handle("session", "owner")
            .await
            .expect("the authenticated owner should resolve its active helper");
        assert!(activity_rx.try_recv().is_err());
        handle.mark_viewer_active();
        assert_eq!(activity_rx.recv().await, Some(()));

        supervisor.active.lock().await.take();
    }

    #[tokio::test]
    async fn validated_owner_scoped_signaling_activity_keeps_viewer_lease_alive() {
        let supervisor = Arc::new(ComputerSessionSupervisor::default());
        let (activity_tx, mut activity_rx) = tokio::sync::mpsc::channel(1);
        let (_stop_tx, _stop_rx) = tokio::sync::oneshot::channel();
        let (commands_tx, _commands_rx) = tokio::sync::mpsc::channel(1);
        let join = tokio::spawn(async {});
        *supervisor.active.lock().await = Some(ManagedHelper {
            session_id: "session".into(),
            owner_device_id: "owner".into(),
            stop: Some(_stop_tx),
            join,
            signaling: Arc::new(tokio::sync::Mutex::new(SignalingState::default())),
            commands: commands_tx,
            viewer_activity: activity_tx,
        });

        let mut lease = ViewerActivityLease::with_duration(Duration::from_millis(100));
        let lease_task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = lease.timer.as_mut() => break "viewer_timeout",
                    activity = activity_rx.recv() => {
                        if activity.is_none() {
                            break "viewer_timeout";
                        }
                        lease.reset();
                    }
                }
            }
        });
        tokio::task::yield_now().await;

        for _ in 0..2 {
            tokio::time::sleep(Duration::from_millis(60)).await;
            let handle = supervisor
                .signaling_handle("session", "owner")
                .await
                .expect("the authenticated owner should resolve its active helper");
            handle.mark_viewer_active();
            tokio::task::yield_now().await;
        }

        tokio::time::sleep(Duration::from_millis(60)).await;
        tokio::task::yield_now().await;
        assert!(!lease_task.is_finished());
        tokio::time::sleep(Duration::from_millis(60)).await;
        tokio::task::yield_now().await;
        assert_eq!(lease_task.await.unwrap(), "viewer_timeout");

        supervisor.active.lock().await.take();
    }

    #[tokio::test]
    async fn mismatched_frame_metadata_preserves_prior_geometry_when_status_changes() {
        let (_directory, state) = crate::ingestion::tests::fixture().await;
        let mut create = session();
        create.source_id = Some("display:1".into());
        create.source_width = Some(1920);
        create.source_height = Some(1080);
        create.source_scale = Some(1.0);
        let stored = state.store.insert_computer_session(&create).await.unwrap();
        let signaling = Arc::new(tokio::sync::Mutex::new(SignalingState::default()));
        let value = serde_json::json!({
            "event": "capture.frameMetadata",
            "status": {
                "state": "capturing",
                "sessionID": stored.id,
                "generation": stored.generation,
                "sourceID": "display:1",
                "geometryRevision": 1,
                "lastFrame": {
                    "sessionID": "stale-session",
                    "generation": stored.generation + 1,
                    "sourceWidth": 3024,
                    "sourceHeight": 1964,
                    "scale": 2.0
                }
            }
        });

        assert_eq!(
            apply_helper_value_with_signaling(&state, &stored, &value, &signaling)
                .await
                .unwrap(),
            HelperValueAction::None
        );
        let current = state
            .store
            .computer_session(&stored.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(current.state, ComputerSessionState::Preparing.as_str());
        assert_eq!(current.source_width, Some(1920));
        assert_eq!(current.source_height, Some(1080));
        assert_eq!(current.source_scale, Some(1.0));
        assert_eq!(current.geometry_revision, 1);
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[test]
    fn signaling_poll_cursor_is_stateless_and_retries_lost_responses() {
        let mut signaling = SignalingState::default();
        signaling.local_candidates.push_back(SignalingCandidate {
            sequence: 1,
            candidate: "candidate:one".into(),
            sdp_mid: None,
            sdp_m_line_index: 0,
            username_fragment: None,
        });
        let first = signaling_snapshot("session", 1, &signaling, 0);
        assert_eq!(first.next_cursor, 1);
        let retry = signaling_snapshot("session", 1, &signaling, 0);
        assert_eq!(retry.cursor, 0);
        assert_eq!(retry.next_cursor, 1);
        assert_eq!(retry.candidates, first.candidates);
        let ahead = signaling_snapshot("session", 1, &signaling, 9);
        assert_eq!(ahead.cursor, 9);
        assert_eq!(ahead.next_cursor, 9);
        assert!(ahead.candidates.is_empty());
    }

    #[tokio::test]
    async fn fake_jsonl_helper_is_handshaken_idempotent_and_reaped() {
        let (directory, mut state) = crate::ingestion::tests::fixture().await;
        let helper_log = directory.path().join("computer-helper.jsonl");
        let stopped = directory.path().join("computer-helper.stopped");
        let capabilities = serde_json::json!({
            "id": 1,
            "result": {
                "protocolVersion": 1,
                "control": {
                    "available": true,
                    "provider": "core-graphics-v1",
                    "requiresAccessibility": true
                }
            }
        });
        let response = serde_json::json!({
            "id": 2,
            "result": {"status": {
                "state": "awaitingSource",
                "sessionID": "fake-session",
                "generation": 1,
                "sourceID": null,
                "geometryRevision": 0
            }}
        });
        let response_two = serde_json::json!({
            "id": 3,
            "result": {"status": {
                "state": "awaitingSource",
                "sessionID": "fake-session",
                "generation": 1,
                "sourceID": null,
                "geometryRevision": 0
            }}
        });
        let helper = directory.path().join("fake-computer-helper.sh");
        let script = format!(
            "#!/bin/sh\nread first\nprintf '%s\\n' \"$first\" > '{}'\nprintf '%s\\n' '{}'\nread second\nprintf '%s\\n' \"$second\" >> '{}'\nprintf '%s\\n' '{}'\nread third\nprintf '%s\\n' \"$third\" >> '{}'\nprintf '%s\\n' '{}'\nwhile IFS= read -r line; do case \"$line\" in *stop*) touch '{}' ; exit 0;; esac; done\n",
            helper_log.display(),
            capabilities,
            helper_log.display(),
            response,
            helper_log.display(),
            response_two,
            stopped.display(),
        );
        std::fs::write(&helper, script).unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        state.computer_use_enabled = true;
        state.computer_use_bin = Some(helper.clone());

        let stored = state
            .store
            .insert_computer_session(&session())
            .await
            .unwrap();
        let supervisor = Arc::clone(&state.computer_supervisor);
        supervisor
            .start(state.clone(), stored.clone())
            .await
            .unwrap();
        // A retry for the same owner/session is a no-op and cannot spawn a
        // second worker.
        supervisor
            .start(state.clone(), stored.clone())
            .await
            .unwrap();

        tokio::time::timeout(Duration::from_secs(8), async {
            loop {
                if state
                    .store
                    .computer_session("fake-session")
                    .await
                    .unwrap()
                    .unwrap()
                    .state
                    == ComputerSessionState::AwaitingSource.as_str()
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();

        tokio::time::timeout(Duration::from_secs(1), async {
            while !helper_log.exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let requests = std::fs::read_to_string(&helper_log)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(requests.len(), 3);
        assert_eq!(requests[0]["method"], "capabilities");
        assert_eq!(requests[1]["method"], "capture.prepare");
        assert_eq!(requests[2]["method"], "capture.pick");
        assert!(requests.iter().all(|request| !request["method"]
            .as_str()
            .unwrap_or_default()
            .starts_with("control.")));
        assert_eq!(requests[1]["params"]["sessionID"], "fake-session");
        assert_eq!(requests[1]["params"]["generation"], 1);
        assert!(requests[1]["params"]["handshake"]
            .as_str()
            .is_some_and(|value| !value.is_empty()));
        assert!(supervisor.control_capable());

        let stale = serde_json::json!({
            "event": "capture.sourceSelected",
            "status": {
                "state": "ready",
                "sessionID": "other-session",
                "generation": 1,
                "sourceID": "display:stale",
                "geometryRevision": 99
            }
        });
        assert!(apply_helper_value(&state, &stored, &stale).await.unwrap());
        let current = state
            .store
            .computer_session("fake-session")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(current.state, ComputerSessionState::AwaitingSource.as_str());
        assert_eq!(current.geometry_revision, 0);

        supervisor.stop(&state, &stored.id, "test_cleanup").await;
        assert!(stopped.exists());
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn unviewed_helper_timeout_stops_and_ends_durable_session() {
        let (directory, mut state) = crate::ingestion::tests::fixture().await;
        let capabilities = serde_json::json!({
            "id": 1,
            "result": {
                "protocolVersion": 1,
                "control": {
                    "available": false,
                    "provider": "core-graphics-v1",
                    "requiresAccessibility": true
                }
            }
        });
        let response = serde_json::json!({
            "id": 2,
            "result": {"status": {
                "state": "awaitingSource",
                "sessionID": "fake-session",
                "generation": 1,
                "sourceID": null,
                "geometryRevision": 0
            }}
        });
        let response_two = serde_json::json!({
            "id": 3,
            "result": {"status": {
                "state": "awaitingSource",
                "sessionID": "fake-session",
                "generation": 1,
                "sourceID": null,
                "geometryRevision": 0
            }}
        });
        let helper = directory.path().join("fake-computer-helper-timeout.sh");
        let script = format!(
            "#!/bin/sh\nread first\nprintf '%s\\n' '{}'\nread second\nprintf '%s\\n' '{}'\nread third\nprintf '%s\\n' '{}'\nwhile IFS= read -r line; do case \"$line\" in *stop*) exit 0;; esac; done\n",
            capabilities,
            response,
            response_two,
        );
        std::fs::write(&helper, script).unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        state.computer_use_enabled = true;
        state.computer_use_bin = Some(helper);
        let stored = state
            .store
            .insert_computer_session(&session())
            .await
            .unwrap();
        let supervisor = Arc::clone(&state.computer_supervisor);
        supervisor
            .start_with_viewer_activity_lease(
                state.clone(),
                stored.clone(),
                Duration::from_millis(500),
            )
            .await
            .unwrap();

        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let ended = state
                    .store
                    .computer_session(&stored.id)
                    .await
                    .unwrap()
                    .unwrap()
                    .state
                    == ComputerSessionState::Ended.as_str();
                let reaped = supervisor.active.lock().await.is_none();
                if ended && reaped {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();

        let current = state
            .store
            .computer_session(&stored.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(current.state, ComputerSessionState::Ended.as_str());
        assert_eq!(current.failure_reason.as_deref(), Some("viewer_timeout"));
        assert!(current.ended_at.is_some());
        assert!(supervisor.active.lock().await.is_none());
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn provider_availability_requires_enabled_executable() {
        let (directory, mut state) = crate::ingestion::tests::fixture().await;
        let helper = directory.path().join("provider");
        std::fs::write(&helper, "#!/bin/sh\n").unwrap();
        state.computer_use_bin = Some(helper.clone());
        state.computer_use_enabled = true;
        assert!(!provider_available(&state));
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(provider_available(&state));
        state.computer_use_enabled = false;
        assert!(!provider_available(&state));
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[test]
    fn helper_control_capability_requires_the_exact_protocol_and_provider() {
        let valid = serde_json::json!({
            "result": {
                "protocolVersion": 1,
                "control": {
                    "available": true,
                    "provider": "core-graphics-v1",
                    "requiresAccessibility": true
                }
            }
        });
        assert!(verified_helper_control_capability(&valid));

        let wrong_provider = serde_json::json!({
            "result": {
                "protocolVersion": 1,
                "control": {
                    "available": true,
                    "provider": "unknown",
                    "requiresAccessibility": true
                }
            }
        });
        assert!(!verified_helper_control_capability(&wrong_provider));

        let no_accessibility = serde_json::json!({
            "result": {
                "protocolVersion": 1,
                "control": {
                    "available": true,
                    "provider": "core-graphics-v1",
                    "requiresAccessibility": false
                }
            }
        });
        assert!(!verified_helper_control_capability(&no_accessibility));
    }

    #[tokio::test]
    async fn helper_output_framing_delivers_without_eof_and_rejects_oversize() {
        let (mut writer, reader) = tokio::io::duplex(256);
        let mut reader = BufReader::new(reader);
        let write = tokio::spawn(async move {
            writer.write_all(b"first\nsecond\n").await.unwrap();
            tokio::time::sleep(Duration::from_secs(1)).await;
        });
        let mut buffer = Vec::new();
        let first = timeout(
            Duration::from_millis(250),
            read_bounded_line(&mut reader, &mut buffer),
        )
        .await
        .expect("a complete helper line must not wait for EOF")
        .unwrap();
        assert_eq!(first, Some(b"first".to_vec()));
        assert_eq!(
            read_bounded_line(&mut reader, &mut buffer).await.unwrap(),
            Some(b"second".to_vec())
        );
        write.abort();

        let oversized = vec![b'x'; MAX_HELPER_LINE_BYTES + 1];
        let mut oversized_reader = BufReader::new(oversized.as_slice());
        let error = read_bounded_line(&mut oversized_reader, &mut buffer)
            .await
            .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    }

    #[tokio::test]
    async fn helper_signaling_events_reject_malformed_or_unknown_and_ignore_stale_peers() {
        let (_directory, state) = crate::ingestion::tests::fixture().await;
        let session = stored_session();
        let signaling = Arc::new(tokio::sync::Mutex::new(SignalingState::default()));
        signaling.lock().await.peer_revision = Some("current-peer".into());

        let missing_revision = serde_json::json!({
            "event": "signal.offer",
            "sessionID": session.id,
            "generation": session.generation,
            "type": "offer",
            "sdp": "v=0\na=sendonly"
        });
        assert_eq!(
            apply_helper_value_with_signaling(&state, &session, &missing_revision, &signaling)
                .await
                .unwrap(),
            HelperValueAction::ProtocolError
        );

        let unknown = serde_json::json!({
            "event": "signal.unrecognized",
            "sessionID": session.id,
            "generation": session.generation,
            "peerRevision": "current-peer"
        });
        assert_eq!(
            apply_helper_value_with_signaling(&state, &session, &unknown, &signaling)
                .await
                .unwrap(),
            HelperValueAction::ProtocolError
        );

        let stale = serde_json::json!({
            "event": "signal.offer",
            "sessionID": session.id,
            "generation": session.generation,
            "peerRevision": "stale-peer",
            "type": "offer",
            "sdp": "v=0\na=sendonly"
        });
        assert_eq!(
            apply_helper_value_with_signaling(&state, &session, &stale, &signaling)
                .await
                .unwrap(),
            HelperValueAction::None
        );
        assert!(signaling.lock().await.offer.is_none());
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn helper_control_revocation_requires_the_complete_session_bound_identity() {
        let (_directory, state) = crate::ingestion::tests::fixture().await;
        let session = stored_session();
        let signaling = Arc::new(tokio::sync::Mutex::new(SignalingState::default()));
        let event = serde_json::json!({
            "event": "control.revoked",
            "sessionID": session.id,
            "generation": session.generation,
            "leaseID": "lease",
            "requestID": "request",
            "geometryRevision": 7,
            "sourceID": "display:1",
            "reason": "local_stop"
        });
        assert_eq!(
            apply_helper_value_with_signaling(&state, &session, &event, &signaling)
                .await
                .unwrap(),
            HelperValueAction::ControlRevoked {
                lease_id: "lease".into(),
                request_id: "request".into(),
                generation: session.generation,
                geometry_revision: 7,
                source_id: Some("display:1".into()),
                reason: "local_stop".into(),
            }
        );

        let mut malformed = event;
        malformed.as_object_mut().unwrap().remove("requestID");
        assert_eq!(
            apply_helper_value_with_signaling(&state, &session, &malformed, &signaling)
                .await
                .unwrap(),
            HelperValueAction::ProtocolError
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
