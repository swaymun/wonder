//! One verified model and durable, device-scoped transcription jobs.
use super::*;
use tokio::sync::{watch, Mutex, OnceCell, OwnedSemaphorePermit};
use wonder_asr::*;
use wonder_store::{AsrJob, NewAsrJob};

const WORKER_TIMEOUT: Duration = Duration::from_secs(60);
const DECODER_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_WORKER_OUTPUT: usize = 256 * 1024;
const MODEL_URL: &str = "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/resolve/541d1f99c6b0c3cd0b11a95167540bb8edefd82b/parakeet-tdt-0.6b-v3.q8_0.gguf";

#[derive(Default)]
struct ModelState {
    verified: bool,
    selected: bool,
    download: Option<watch::Sender<bool>>,
    download_state: &'static str,
    error: Option<&'static str>,
}

pub struct AsrService {
    root: PathBuf,
    model_path: PathBuf,
    runtime: PathBuf,
    worker: Option<std::ffi::OsString>,
    decoder: std::ffi::OsString,
    initialized: OnceCell<()>,
    admission: Mutex<()>,
    model: Mutex<ModelState>,
    active: Mutex<HashMap<String, watch::Sender<bool>>>,
}
impl Default for AsrService {
    fn default() -> Self {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_default();
        let data = std::env::var_os("WONDER_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("Library/Application Support/Wonder"));
        let root = data.join("NeMoSpeech");
        let models = std::env::var_os("WONDER_MODEL_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| root.join("models"));
        Self {
            model_path: models.join(MODEL_ARTIFACT),
            runtime: std::env::var_os("WONDER_NEMO_SPEECH_BIN")
                .map(PathBuf::from)
                .unwrap_or_else(|| root.join("bin/nemo-speech")),
            root,
            worker: std::env::var_os("WONDER_ASR_BIN"),
            decoder: std::env::var_os("WONDER_ASR_DECODER_BIN").unwrap_or_else(|| "ffmpeg".into()),
            initialized: OnceCell::new(),
            admission: Mutex::new(()),
            model: Mutex::new(ModelState::default()),
            active: Mutex::new(HashMap::new()),
        }
    }
}

impl AsrService {
    pub async fn initialize(self: &Arc<Self>, store: &Store) -> Result<(), StatusCode> {
        self.initialized
            .get_or_try_init(|| async {
                store
                    .recover_asr_jobs(now_ms())
                    .await
                    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
                // Only this service owns this directory; interrupted subprocess WAVs must not remain.
                let jobs = self.root.join("jobs");
                match tokio::fs::remove_dir_all(&jobs).await {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(_) => return Err(StatusCode::INTERNAL_SERVER_ERROR),
                }
                let _ = tokio::fs::remove_file(self.model_path.with_extension("gguf.part")).await;
                let verified = verify_model(self.model_path.clone()).await;
                let selected = tokio::fs::read(self.root.join("asr-selection.json"))
                    .await
                    .ok()
                    .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
                    .map(|value| value.get("modelId").and_then(|v| v.as_str()) == Some(MODEL_ID))
                    .unwrap_or(true);
                let mut model = self.model.lock().await;
                model.verified = verified;
                model.selected = selected;
                model.download_state = "idle";
                let weak = Arc::downgrade(self);
                let store = store.clone();
                tokio::spawn(async move {
                    loop {
                        tokio::time::sleep(Duration::from_secs(1)).await;
                        if weak.upgrade().is_none() {
                            break;
                        }
                        let _ = store.expire_asr_audio(now_ms()).await;
                    }
                });
                Ok(())
            })
            .await
            .map(|_| ())
    }
    fn ready(&self, model: &ModelState) -> bool {
        model.verified
            && model.selected
            && executable_available(self.runtime.as_os_str())
            && executable_available(&self.decoder)
            && self
                .worker
                .as_ref()
                .is_some_and(|p| executable_available(p))
    }
}

fn executable_available(program: &std::ffi::OsStr) -> bool {
    fn usable(path: &FsPath) -> bool {
        #[cfg(unix)]
        use std::os::unix::fs::PermissionsExt;
        path.metadata().is_ok_and(|m| {
            #[cfg(unix)]
            {
                m.is_file() && m.permissions().mode() & 0o111 != 0
            }
            #[cfg(not(unix))]
            {
                m.is_file()
            }
        })
    }
    let path = FsPath::new(program);
    if path.components().count() > 1 {
        return usable(path);
    }
    std::env::var_os("PATH")
        .is_some_and(|value| std::env::split_paths(&value).any(|root| usable(&root.join(path))))
}

async fn verify_model(path: PathBuf) -> bool {
    tokio::task::spawn_blocking(move || {
        use std::io::Read;
        let Ok(mut file) = std::fs::File::open(path) else {
            return false;
        };
        if file.metadata().ok().is_none_or(|m| m.len() != MODEL_BYTES) {
            return false;
        }
        let mut digest = Sha256::new();
        let mut buffer = [0u8; 64 * 1024];
        loop {
            match file.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => digest.update(&buffer[..n]),
                Err(_) => return false,
            }
        }
        hex::encode(digest.finalize()) == MODEL_SHA256
    })
    .await
    .unwrap_or(false)
}

fn source_device(
    auth: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
) -> Result<String, StatusCode> {
    match (auth, local) {
        (Some(Extension(device)), _) => Ok(device.device_id),
        (_, Some(_)) => Ok("local-loopback".into()),
        _ => Err(StatusCode::UNAUTHORIZED),
    }
}
fn error(category: AsrErrorCategory, status: StatusCode) -> Response {
    (
        status,
        Json(serde_json::json!({"errorCategory":category,"error":category})),
    )
        .into_response()
}
fn header_text<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name).and_then(|v| v.to_str().ok())
}
fn json_job(job: AsrJob) -> serde_json::Value {
    let r = job.transcription;
    serde_json::json!({"id":r.id,"state":r.state,"sourceDeviceId":r.source_device_id,"durationMs":r.duration_ms,"modelId":job.model_id,"language":job.language,"processingSource":"paired_mac","transcriptText":r.transcript_text,"wordTimestamps":r.word_timestamps_json.and_then(|v|serde_json::from_str::<serde_json::Value>(&v).ok()),"confidence":r.confidence,"retryExpiresAtMs":r.retry_expires_at_ms,"errorCategory":r.error_category})
}
async fn job_response(state: &AppState, id: &str, device: &str, status: StatusCode) -> Response {
    match state.store.asr_job_for_device(id, device).await {
        Ok(Some(job)) => (status, Json(json_job(job))).into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

pub(super) async fn create_transcription(
    State(state): State<AppState>,
    auth: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let device = match source_device(auth, local) {
        Ok(v) => v,
        Err(s) => return s.into_response(),
    };
    if let Err(s) = state.asr_service.initialize(&state.store).await {
        return s.into_response();
    }
    let Some(request_id) = header_text(&headers, "x-wonder-request-id")
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .map(|id| id.to_string())
    else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let Some(mime) = header_text(&headers, "content-type").and_then(canonical_audio_mime) else {
        return error(
            AsrErrorCategory::UnsupportedRecordingFormat,
            StatusCode::BAD_REQUEST,
        );
    };
    let duration = header_text(&headers, "x-wonder-duration-ms")
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    if let Err(e) = validate_upload(AudioUploadMetadata {
        mime_type: mime,
        byte_length: body.len(),
        duration_ms: duration,
    }) {
        return error(e, StatusCode::BAD_REQUEST);
    }
    if sniff_audio_mime(&body) != Some(mime) {
        return error(
            AsrErrorCategory::UnsupportedRecordingFormat,
            StatusCode::BAD_REQUEST,
        );
    }
    let model_id = header_text(&headers, "x-wonder-model-id").unwrap_or(MODEL_ID);
    let language = header_text(&headers, "x-wonder-language").unwrap_or("auto");
    if model_id != MODEL_ID {
        return error(AsrErrorCategory::ModelUnavailable, StatusCode::BAD_REQUEST);
    }
    if language != "auto" {
        return error(
            AsrErrorCategory::UnsupportedLanguage,
            StatusCode::BAD_REQUEST,
        );
    }
    let mut digest = Sha256::new();
    for value in [
        mime.as_bytes(),
        &duration.to_le_bytes(),
        model_id.as_bytes(),
        language.as_bytes(),
        &body,
    ] {
        digest.update(value);
    }
    let hash = hex::encode(digest.finalize());
    let _admission = state.asr_service.admission.lock().await;
    match state
        .store
        .asr_request_cancelled(&device, &request_id)
        .await
    {
        Ok(true) => return error(AsrErrorCategory::Cancelled, StatusCode::CONFLICT),
        Ok(false) => {}
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
    match state.store.asr_job_by_request(&device, &request_id).await {
        Ok(Some(job)) => {
            return if job.request_sha256.as_deref() == Some(&hash) {
                (StatusCode::OK, Json(json_job(job))).into_response()
            } else {
                StatusCode::CONFLICT.into_response()
            }
        }
        Ok(None) => {}
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
    let Ok(slot) = state.asr_slots.clone().try_acquire_owned() else {
        return error(AsrErrorCategory::Busy, StatusCode::TOO_MANY_REQUESTS);
    };
    if !state
        .asr_service
        .ready(&*state.asr_service.model.lock().await)
    {
        return error(
            AsrErrorCategory::ModelUnavailable,
            StatusCode::SERVICE_UNAVAILABLE,
        );
    }
    match state.store.retained_asr_audio_bytes().await {
        Ok(bytes)
            if bytes.saturating_add(body.len() as i64) <= (4 * MAX_RECORDING_BYTES) as i64 => {}
        Ok(_) => return error(AsrErrorCategory::Busy, StatusCode::TOO_MANY_REQUESTS),
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
    let now = now_ms();
    {
        let mut limits = state.asr_rate_limits.lock().await;
        let entries = limits.entry(device.clone()).or_default();
        entries.retain(|t| now.saturating_sub(*t) < 60000);
        if entries.len() >= 4 {
            return error(AsrErrorCategory::RateLimited, StatusCode::TOO_MANY_REQUESTS);
        }
        entries.push(now);
    }
    let id = uuid::Uuid::new_v4().to_string();
    if !matches!(
        state
            .store
            .create_asr_job(NewAsrJob {
                id: &id,
                device_id: &device,
                request_id: &request_id,
                request_sha256: &hash,
                model_id,
                language,
                duration_ms: duration,
                audio_mime: mime,
                audio: &body,
                now_ms: now
            })
            .await,
        Ok(true)
    ) {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    launch_job(state.clone(), id.clone(), device.clone(), slot).await;
    job_response(&state, &id, &device, StatusCode::ACCEPTED).await
}

pub(super) async fn get_transcription(
    State(state): State<AppState>,
    auth: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path(id): Path<String>,
) -> Response {
    let device = match source_device(auth, local) {
        Ok(v) => v,
        Err(s) => return s.into_response(),
    };
    if let Err(s) = state.asr_service.initialize(&state.store).await {
        return s.into_response();
    }
    let _ = state.store.expire_asr_audio(now_ms()).await;
    job_response(&state, &id, &device, StatusCode::OK).await
}
pub(super) async fn cancel_transcription(
    State(state): State<AppState>,
    auth: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path(id): Path<String>,
) -> Response {
    let device = match source_device(auth, local) {
        Ok(v) => v,
        Err(s) => return s.into_response(),
    };
    if let Err(s) = state.asr_service.initialize(&state.store).await {
        return s.into_response();
    }
    // Persist cancellation before signalling: a late result cannot undo it.
    match state.store.cancel_asr_job(&id, &device, now_ms()).await {
        Ok(true) => {
            if let Some(cancel) = state.asr_service.active.lock().await.get(&id) {
                let _ = cancel.send(true);
            }
        }
        Ok(false) => {}
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
    job_response(&state, &id, &device, StatusCode::OK).await
}
pub(super) async fn cancel_transcription_request(
    State(state): State<AppState>,
    auth: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path(request_id): Path<String>,
) -> Response {
    let device = match source_device(auth, local) {
        Ok(device) => device,
        Err(status) => return status.into_response(),
    };
    let request = match uuid::Uuid::parse_str(&request_id) {
        Ok(request) => request.to_string(),
        Err(_) => return StatusCode::BAD_REQUEST.into_response(),
    };
    if let Err(status) = state.asr_service.initialize(&state.store).await {
        return status.into_response();
    }
    // Admission spans acceptance and worker registration, preventing the cancel
    // from falling between the durable insert and the active worker signal.
    let _admission = state.asr_service.admission.lock().await;
    match state
        .store
        .cancel_asr_request(&device, &request, now_ms())
        .await
    {
        Ok(Some(id)) => {
            if let Some(cancel) = state.asr_service.active.lock().await.get(&id) {
                let _ = cancel.send(true);
            }
        }
        Ok(None) => {}
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
    StatusCode::NO_CONTENT.into_response()
}

pub(super) async fn retry_transcription(
    State(state): State<AppState>,
    auth: Option<Extension<AuthenticatedDevice>>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Path(id): Path<String>,
) -> Response {
    let device = match source_device(auth, local) {
        Ok(v) => v,
        Err(s) => return s.into_response(),
    };
    if let Err(s) = state.asr_service.initialize(&state.store).await {
        return s.into_response();
    }
    let _admission = state.asr_service.admission.lock().await;
    let job = match state.store.asr_job_for_device(&id, &device).await {
        Ok(Some(j)) => j,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    if job.transcription.state != "failed" {
        return (StatusCode::OK, Json(json_job(job))).into_response();
    }
    let Ok(slot) = state.asr_slots.clone().try_acquire_owned() else {
        return error(AsrErrorCategory::Busy, StatusCode::TOO_MANY_REQUESTS);
    };
    if !state
        .asr_service
        .ready(&*state.asr_service.model.lock().await)
    {
        return error(
            AsrErrorCategory::ModelUnavailable,
            StatusCode::SERVICE_UNAVAILABLE,
        );
    }
    match state.store.retry_asr_job(&id, &device, now_ms()).await {
        Ok(true) => {}
        Ok(false) => return StatusCode::GONE.into_response(),
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
    launch_job(state.clone(), id.clone(), device.clone(), slot).await;
    job_response(&state, &id, &device, StatusCode::ACCEPTED).await
}

async fn launch_job(state: AppState, id: String, device: String, slot: OwnedSemaphorePermit) {
    let (cancel, receiver) = watch::channel(false);
    state
        .asr_service
        .active
        .lock()
        .await
        .insert(id.clone(), cancel);
    tokio::spawn(async move {
        let _slot = slot;
        if !matches!(state.store.claim_asr_job(&id, now_ms()).await, Ok(true)) {
            state.asr_service.active.lock().await.remove(&id);
            return;
        }
        let mut duration = 0;
        let result = async {
            let job = state
                .store
                .asr_job_for_device(&id, &device)
                .await
                .map_err(|_| AsrErrorCategory::Transcription)?
                .ok_or(AsrErrorCategory::Transcription)?;
            duration = job.transcription.duration_ms;
            let audio = state
                .store
                .asr_job_audio(&id)
                .await
                .map_err(|_| AsrErrorCategory::Transcription)?
                .ok_or(AsrErrorCategory::Cancelled)?;
            let pcm = normalize_audio(
                &state.asr_service,
                job.audio_mime.as_deref().ok_or(AsrErrorCategory::Decoder)?,
                audio,
                receiver.clone(),
            )
            .await?;
            duration = normalized_duration_ms(&pcm);
            run_local_asr(&state.asr_service, &id, duration, pcm, receiver).await
        }
        .await;
        match result {
            Ok(value) => {
                let words = value
                    .word_timestamps
                    .as_ref()
                    .and_then(|v| serde_json::to_string(v).ok());
                let _ = state
                    .store
                    .finish_asr_job(
                        &id,
                        value.transcript_text.as_deref(),
                        words.as_deref(),
                        None,
                        None,
                        duration,
                        now_ms(),
                    )
                    .await;
            }
            Err(e) => {
                let category = serde_json::to_value(e)
                    .ok()
                    .and_then(|v| v.as_str().map(str::to_owned))
                    .unwrap_or_else(|| "transcription".into());
                let _ = state
                    .store
                    .finish_asr_job(&id, None, None, None, Some(&category), duration, now_ms())
                    .await;
            }
        }
        let _ = tokio::fs::remove_dir_all(state.asr_service.root.join("jobs").join(&id)).await;
        state.asr_service.active.lock().await.remove(&id);
    });
}

pub(super) async fn models(State(state): State<AppState>) -> Response {
    if let Err(s) = state.asr_service.initialize(&state.store).await {
        return s.into_response();
    }
    model_response(&state).await
}
async fn model_response(state: &AppState) -> Response {
    let m = state.asr_service.model.lock().await;
    let runtime_available = executable_available(state.asr_service.runtime.as_os_str());
    let decoder_available = executable_available(&state.asr_service.decoder);
    let downloaded_bytes = if m.verified {
        MODEL_BYTES
    } else {
        tokio::fs::metadata(state.asr_service.model_path.with_extension("gguf.part"))
            .await
            .map(|m| m.len().min(MODEL_BYTES))
            .unwrap_or(0)
    };
    Json(serde_json::json!({"selectedModelId":if m.selected{Some(MODEL_ID)}else{None},"ready":state.asr_service.ready(&m),"decoderAvailable":decoder_available,"maxRecordingDurationMs":MAX_RECORDING_DURATION_MS,"languages":["auto"],"models":[{"id":MODEL_ID,"name":"Parakeet","runtimeId":"nemo-speech-0.1.0","revision":MODEL_REVISION,"artifactUrl":MODEL_URL,"sha256":MODEL_SHA256,"bytes":MODEL_BYTES,"license":"CC-BY-4.0","supportedPlatforms":["macos-arm64"],"supportedLanguages":["bg","hr","cs","da","nl","en","et","fi","fr","de","el","hu","it","lv","lt","mt","pl","pt","ro","sk","sl","es","sv","ru","uk"],"testedLanguages":["en","es"],"downloadedBytes":downloaded_bytes,"canDelete":m.verified && state.asr_slots.available_permits()>0,"installed":m.verified,"runtimeAvailable":runtime_available,"downloadState":m.download_state,"errorCategory":m.error,"inUse":state.asr_slots.available_permits()==0,"resourceNote":"Measured on an M5 Pro with 64 GB: about 5 seconds and 1 GB resident memory for a repeated five-minute speech fixture. Other Macs are unverified."}]})).into_response()
}
fn local_model(
    id: &str,
    authority: Option<Extension<LocalOwnerAuthority>>,
) -> Result<(), StatusCode> {
    if authority.is_none() {
        Err(StatusCode::FORBIDDEN)
    } else if id != MODEL_ID {
        Err(StatusCode::NOT_FOUND)
    } else {
        Ok(())
    }
}
async fn persist_selection(service: &AsrService, selected: bool) -> Result<(), StatusCode> {
    tokio::fs::create_dir_all(&service.root)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let partial = service.root.join("asr-selection.json.part");
    let data =
        serde_json::to_vec(&serde_json::json!({"modelId":if selected{Some(MODEL_ID)}else{None}}))
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    tokio::fs::write(&partial, data)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    tokio::fs::rename(partial, service.root.join("asr-selection.json"))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}
pub(super) async fn select_model(
    State(state): State<AppState>,
    authority: Option<Extension<LocalOwnerAuthority>>,
    Path(id): Path<String>,
) -> Response {
    if let Err(s) = local_model(&id, authority) {
        return s.into_response();
    }
    if let Err(s) = state.asr_service.initialize(&state.store).await {
        return s.into_response();
    }
    let _admission = state.asr_service.admission.lock().await;
    let Ok(_slot) = state.asr_slots.clone().try_acquire_owned() else {
        return error(AsrErrorCategory::Busy, StatusCode::CONFLICT);
    };
    let mut m = state.asr_service.model.lock().await;
    if !m.verified {
        return error(AsrErrorCategory::ModelUnavailable, StatusCode::CONFLICT);
    }
    if let Err(s) = persist_selection(&state.asr_service, true).await {
        return s.into_response();
    }
    m.selected = true;
    drop(m);
    drop(_slot);
    model_response(&state).await
}
pub(super) async fn delete_model(
    State(state): State<AppState>,
    authority: Option<Extension<LocalOwnerAuthority>>,
    Path(id): Path<String>,
) -> Response {
    if let Err(s) = local_model(&id, authority) {
        return s.into_response();
    }
    if let Err(s) = state.asr_service.initialize(&state.store).await {
        return s.into_response();
    }
    let _admission = state.asr_service.admission.lock().await;
    let Ok(_slot) = state.asr_slots.clone().try_acquire_owned() else {
        return error(AsrErrorCategory::Busy, StatusCode::CONFLICT);
    };
    match tokio::fs::remove_file(&state.asr_service.model_path).await {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
    let mut m = state.asr_service.model.lock().await;
    m.verified = false;
    // A failed settings write still reports the actual missing artifact.
    if let Err(s) = persist_selection(&state.asr_service, false).await {
        return s.into_response();
    }
    m.selected = false;
    drop(m);
    drop(_slot);
    model_response(&state).await
}
pub(super) async fn download_model(
    State(state): State<AppState>,
    authority: Option<Extension<LocalOwnerAuthority>>,
    Path(id): Path<String>,
) -> Response {
    if let Err(s) = local_model(&id, authority) {
        return s.into_response();
    }
    if let Err(s) = state.asr_service.initialize(&state.store).await {
        return s.into_response();
    }
    let _admission = state.asr_service.admission.lock().await;
    let Ok(slot) = state.asr_slots.clone().try_acquire_owned() else {
        return error(AsrErrorCategory::Busy, StatusCode::CONFLICT);
    };
    let mut m = state.asr_service.model.lock().await;
    if m.verified {
        drop(m);
        drop(slot);
        return model_response(&state).await;
    }
    let Some(worker) = state.asr_service.worker.as_ref().map(PathBuf::from) else {
        return error(
            AsrErrorCategory::ModelUnavailable,
            StatusCode::SERVICE_UNAVAILABLE,
        );
    };
    let Some(parent) = worker.parent() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let installer = parent.join("install-parakeet-model.sh");
    if !installer.is_file() {
        return error(
            AsrErrorCategory::ModelUnavailable,
            StatusCode::SERVICE_UNAVAILABLE,
        );
    }
    let (cancel, receiver) = watch::channel(false);
    m.download = Some(cancel);
    m.download_state = "downloading";
    m.error = None;
    drop(m);
    let cloned = state.clone();
    tokio::spawn(async move {
        let _slot = slot;
        let mut command = Command::new(installer);
        command.env(
            "WONDER_MODEL_DIR",
            cloned.asr_service.model_path.parent().unwrap(),
        );
        let result = bounded_process(
            command,
            Vec::new(),
            64 * 1024,
            Duration::from_secs(600),
            receiver,
        )
        .await;
        // kill prevents script traps, so the daemon also removes partial downloads.
        let _ =
            tokio::fs::remove_file(cloned.asr_service.model_path.with_extension("gguf.part")).await;
        let verified = verify_model(cloned.asr_service.model_path.clone()).await;
        let mut m = cloned.asr_service.model.lock().await;
        m.verified = verified;
        m.download = None;
        match result {
            Ok(_) => {
                m.download_state = if verified { "idle" } else { "failed" };
                m.error = if verified { None } else { Some("integrity") }
            }
            Err(AsrErrorCategory::Cancelled) => {
                m.download_state = "cancelled";
                m.error = None
            }
            Err(_) => {
                m.download_state = "failed";
                m.error = Some("download")
            }
        }
    });
    (
        StatusCode::ACCEPTED,
        Json(serde_json::json!({"modelId":MODEL_ID,"downloadState":"downloading"})),
    )
        .into_response()
}
pub(super) async fn cancel_download(
    State(state): State<AppState>,
    authority: Option<Extension<LocalOwnerAuthority>>,
    Path(id): Path<String>,
) -> Response {
    if let Err(s) = local_model(&id, authority) {
        return s.into_response();
    }
    let mut m = state.asr_service.model.lock().await;
    if let Some(cancel) = &m.download {
        let _ = cancel.send(true);
        m.download_state = "cancelling";
    }
    drop(m);
    model_response(&state).await
}

pub(super) fn canonical_audio_mime(value: &str) -> Option<&'static str> {
    match value.split(';').next().map(str::trim) {
        Some("audio/webm") => Some("audio/webm"),
        Some("audio/ogg") => Some("audio/ogg"),
        Some("audio/mp4") => Some("audio/mp4"),
        Some("audio/wav" | "audio/x-wav") => Some("audio/wav"),
        _ => None,
    }
}
pub(super) fn sniff_audio_mime(audio: &[u8]) -> Option<&'static str> {
    if audio.starts_with(&[0x1a, 0x45, 0xdf, 0xa3]) {
        Some("audio/webm")
    } else if audio.starts_with(b"OggS") {
        Some("audio/ogg")
    } else if audio.len() >= 12 && &audio[..4] == b"RIFF" && &audio[8..12] == b"WAVE" {
        Some("audio/wav")
    } else if audio.len() >= 12 && &audio[4..8] == b"ftyp" {
        Some("audio/mp4")
    } else {
        None
    }
}
fn normalized_duration_ms(pcm: &[u8]) -> u64 {
    pcm.len() as u64 * 1000
        / (PCM_SAMPLE_RATE_HZ as u64 * PCM_CHANNELS as u64 * PCM_BYTES_PER_SAMPLE as u64)
}

/// Every command has its own process group. Dropping an interrupted future kills descendants too.
struct ProcessGroup {
    pid: Option<u32>,
}
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(pid) = self.pid {
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
    }
}
async fn bounded_process(
    mut command: Command,
    input: Vec<u8>,
    output_limit: usize,
    deadline: Duration,
    mut cancel: watch::Receiver<bool>,
) -> Result<Vec<u8>, AsrErrorCategory> {
    if *cancel.borrow() {
        return Err(AsrErrorCategory::Cancelled);
    }
    #[cfg(unix)]
    command.process_group(0);
    command.env("WONDER_ASR_PARENT_PID", std::process::id().to_string());
    command
        .kill_on_drop(true)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    let mut child = command
        .spawn()
        .map_err(|_| AsrErrorCategory::ModelUnavailable)?;
    let mut group = ProcessGroup { pid: child.id() };
    let result = async {
        let mut stdin = child.stdin.take().ok_or(AsrErrorCategory::Decoder)?;
        let stdout = child.stdout.take().ok_or(AsrErrorCategory::Decoder)?;
        let writer = async {
            stdin
                .write_all(&input)
                .await
                .map_err(|_| AsrErrorCategory::Upload)?;
            drop(stdin);
            Ok::<(), AsrErrorCategory>(())
        };
        let reader = async {
            let mut out = Vec::new();
            stdout
                .take(output_limit as u64 + 1)
                .read_to_end(&mut out)
                .await
                .map_err(|_| AsrErrorCategory::Decoder)?;
            if out.len() > output_limit {
                return Err(AsrErrorCategory::Decoder);
            }
            Ok(out)
        };
        let (_, out) = tokio::try_join!(writer, reader)?;
        if !child
            .wait()
            .await
            .map_err(|_| AsrErrorCategory::Transcription)?
            .success()
        {
            return Err(AsrErrorCategory::Transcription);
        }
        Ok(out)
    };
    let output = tokio::select! {result=timeout(deadline,result)=>result.unwrap_or(Err(AsrErrorCategory::Timeout)),_=cancel.changed()=>Err(AsrErrorCategory::Cancelled)};
    if output.is_ok() {
        group.pid = None;
    }
    // Failed/cancelled processes are terminated together with their descendants.
    if let Some(pid) = group.pid.take() {
        #[cfg(unix)]
        unsafe {
            libc::kill(-(pid as i32), libc::SIGKILL);
        }
    }
    let _ = child.kill().await;
    let _ = child.wait().await;
    output
}
// A seekable upload is necessary for native M4A files whose moov atom follows mdat.
// This guard also removes the input when normalization is cancelled or its future is dropped.
struct DecoderInput {
    directory: PathBuf,
    path: PathBuf,
}
impl Drop for DecoderInput {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
impl DecoderInput {
    fn create(root: PathBuf, audio: Vec<u8>) -> Result<Self, AsrErrorCategory> {
        use std::io::Write;
        let mut directories = std::fs::DirBuilder::new();
        directories.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            directories.mode(0o700);
        }
        let jobs = root.join("jobs");
        directories
            .create(&jobs)
            .map_err(|_| AsrErrorCategory::Decoder)?;
        let directory = jobs.join(format!("decoder-{}", uuid::Uuid::new_v4()));
        // Create the unique directory atomically and never reuse another job's input.
        directories.recursive(false);
        directories
            .create(&directory)
            .map_err(|_| AsrErrorCategory::Decoder)?;
        let input = Self {
            path: directory.join("recording"),
            directory,
        };
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&input.path)
            .map_err(|_| AsrErrorCategory::Decoder)?;
        file.write_all(&audio)
            .map_err(|_| AsrErrorCategory::Decoder)?;
        Ok(input)
    }
}
async fn normalize_audio(
    service: &AsrService,
    mime: &str,
    audio: Vec<u8>,
    cancel: watch::Receiver<bool>,
) -> Result<Vec<u8>, AsrErrorCategory> {
    let format = match mime {
        "audio/wav" => "wav",
        "audio/mp4" => "mp4",
        "audio/webm" => "webm",
        "audio/ogg" => "ogg",
        _ => return Err(AsrErrorCategory::Decoder),
    };
    if audio.len() > MAX_RECORDING_BYTES {
        return Err(AsrErrorCategory::Upload);
    }
    if *cancel.borrow() {
        return Err(AsrErrorCategory::Cancelled);
    }
    let root = service.root.clone();
    // A blocking task owns the guard during the write, so dropping this future cannot
    // race an unfinished filesystem write and leave a new file behind.
    let input = tokio::task::spawn_blocking(move || DecoderInput::create(root, audio))
        .await
        .map_err(|_| AsrErrorCategory::Decoder)??;
    let mut command = Command::new(&service.decoder);
    command
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-xerror",
            "-protocol_whitelist",
            "file,pipe",
            "-f",
            format,
            "-i",
        ])
        .arg(&input.path)
        .args(["-ac", "1", "-ar", "16000", "-f", "s16le", "pipe:1"]);
    let pcm = bounded_process(command, Vec::new(), MAX_PCM_BYTES, DECODER_TIMEOUT, cancel).await?;
    if pcm.is_empty() {
        return Err(AsrErrorCategory::NoAudio);
    }
    if pcm.len() % 2 != 0 {
        return Err(AsrErrorCategory::Decoder);
    }
    if normalized_duration_ms(&pcm) < MIN_RECORDING_DURATION_MS {
        return Err(AsrErrorCategory::TooShort);
    }
    Ok(pcm)
}
async fn run_local_asr(
    service: &AsrService,
    id: &str,
    duration: u64,
    pcm: Vec<u8>,
    cancel: watch::Receiver<bool>,
) -> Result<WorkerResponse, AsrErrorCategory> {
    let directory = service.root.join("jobs").join(id);
    tokio::fs::create_dir_all(&directory)
        .await
        .map_err(|_| AsrErrorCategory::Decoder)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
            .await
            .map_err(|_| AsrErrorCategory::Decoder)?;
    }
    let request = WorkerRequest {
        transcription_id: id.into(),
        audio_format: "pcm_s16le".into(),
        sample_rate_hz: PCM_SAMPLE_RATE_HZ,
        channels: PCM_CHANNELS,
        duration_ms: duration,
        audio_base64: base64::engine::general_purpose::STANDARD.encode(pcm),
    };
    let mut input = serde_json::to_vec(&request).map_err(|_| AsrErrorCategory::Decoder)?;
    input.push(b'\n');
    let mut command = Command::new(
        service
            .worker
            .as_ref()
            .ok_or(AsrErrorCategory::ModelUnavailable)?,
    );
    command
        .arg("--stdio")
        .env("WONDER_NEMO_SPEECH_BIN", &service.runtime)
        .env("WONDER_ASR_MODEL", &service.model_path)
        .env("TMPDIR", &directory)
        .env("WONDER_ASR_PARENT_PID", std::process::id().to_string());
    let output = bounded_process(command, input, MAX_WORKER_OUTPUT, WORKER_TIMEOUT, cancel).await?;
    let response: WorkerResponse =
        serde_json::from_slice(&output).map_err(|_| AsrErrorCategory::Decoder)?;
    if response.transcription_id != id {
        return Err(AsrErrorCategory::Transcription);
    }
    if let Some(error) = response.error_category.clone() {
        return Err(error);
    }
    if response
        .transcript_text
        .as_deref()
        .is_none_or(|s| s.trim().is_empty())
    {
        return Err(AsrErrorCategory::NoAudio);
    }
    if response
        .transcript_text
        .as_ref()
        .is_some_and(|s| s.len() > 64 * 1024)
        || response.word_timestamps.as_ref().is_some_and(|words| {
            words
                .iter()
                .any(|w| w.start_ms >= w.end_ms || w.end_ms > duration)
        })
    {
        return Err(AsrErrorCategory::Transcription);
    }
    Ok(response)
}

#[cfg(test)]
#[path = "asr_tests.rs"]
mod tests;
