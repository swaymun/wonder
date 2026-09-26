mod data_home;
mod runtime_home;
use std::sync::Arc;
use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
};

use sha2::{Digest, Sha256};
use tokio::sync::RwLock;
use wonder_api::{
    pairing_protocol::{DevicePublicKeyJwk, PairingState},
    HostEventEnvelope,
};
use wonder_app_server::{build_permission_override, AppServerClient, LaunchConfig};
use wonder_store::Store;
use wonderd::{
    capability_from_environment, logging::JsonlLogger, router, AppState, RuntimeCatalog,
    CHANNEL_WORKER_CONCURRENCY,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args().nth(1).as_deref() == Some("--locate-runtime") {
        println!("{}", resolve_codex().await?.display());
        return Ok(());
    }
    if std::env::args().nth(1).as_deref() == Some("--verify-runtime") {
        let path = std::env::args_os().nth(2).ok_or("runtime path required")?;
        wonder_app_server::verify_runtime(Path::new(&path)).await?;
        println!("Runtime version and protocol verified");
        return Ok(());
    }
    if std::env::args().nth(1).as_deref() == Some("--prepare-data-dir") {
        println!("{}", data_directory()?.display());
        return Ok(());
    }
    let startup_started = std::time::Instant::now();
    let data_dir = data_directory()?;
    tokio::fs::create_dir_all(&data_dir).await?;
    let host_installation_id = persistent_host_installation_id(&data_dir)?;
    let log_dir = log_directory()?;
    let logger = Arc::new(JsonlLogger::new(&log_dir, "wonderd.jsonl")?);
    logger.record(
        "info",
        "daemon_starting",
        serde_json::json!({
            "dataDirectory": data_dir,
            "logDirectory": log_dir,
            "modelUsage": "none_until_live_opt_in",
        }),
    )?;
    let database_url = format!(
        "sqlite://{}?mode=rwc",
        data_dir.join("wonder.sqlite3").display()
    );
    let store = Store::connect(&database_url).await?;
    logger.record(
        "info",
        "startup_stage",
        serde_json::json!({ "stage": "store_ready", "elapsedMs": startup_started.elapsed().as_millis() }),
    )?;
    let capability = capability_from_environment()?;
    let started_at = unix_timestamp_ms().to_string();
    let host_epoch = hex::encode(Sha256::digest(
        format!("{started_at}:{}", uuid::Uuid::new_v4()).as_bytes(),
    ));

    store.start_event_epoch(&host_epoch).await?;

    let codex_bin = resolve_codex().await?;
    let codex_state = effective_codex_home()?;
    let private_runtime = data_dir.join("runtime");
    runtime_home::prepare(&private_runtime, &codex_state)?;
    let sensitive_root_paths = sensitive_roots(&codex_state)?;
    let sensitive_roots = sensitive_root_paths
        .iter()
        .map(|path| path.to_str().ok_or("non-UTF-8 sensitive path"))
        .collect::<Result<Vec<_>, _>>()?;
    let bootstrap_home = data_dir.join("runtime-bootstrap");
    let bot_home = data_dir.join("bots");
    tokio::fs::create_dir_all(&bootstrap_home).await?;
    tokio::fs::create_dir_all(&bot_home).await?;
    let data_root = data_dir.to_str().ok_or("non-UTF-8 data path")?;
    let log_root = log_dir.to_str().ok_or("non-UTF-8 log path")?;
    let legacy_root = std::env::var("HOME")
        .ok()
        .map(|home| PathBuf::from(home).join("Library/Application Support/Wonder"));
    let legacy_alias = legacy_root.filter(|path| {
        path.is_symlink() && path.canonicalize().ok() == data_dir.canonicalize().ok()
    });
    let mut denied_root_refs = vec![data_root, log_root];
    if let Some(path) = legacy_alias.as_ref().and_then(|path| path.to_str()) {
        denied_root_refs.push(path);
    }
    denied_root_refs.extend(sensitive_roots.iter().copied());
    let bootstrap_profile = build_permission_override(
        "wonder_runtime_bootstrap",
        bootstrap_home.to_str().ok_or("non-UTF-8 bootstrap path")?,
        &[],
        &[],
        &denied_root_refs,
    )?;
    let bots = store.list_bots().await?;
    let mut permission_overrides = vec![bootstrap_profile];
    for bot in &bots {
        if bot.permission_mode.is_some() || bot.agent_family == wonder_store::AgentFamily::Claude {
            continue;
        }
        let access = store.bot_file_access(&bot.id).await?;
        // A missing saved location must not hide the local settings/recovery API.
        let value = wonderd::file_access::configured_override(bot, &access, &denied_root_refs)
            .or_else(|_| {
                build_permission_override(
                    &bot.permission_profile,
                    &bot.workspace_path,
                    &[],
                    &[],
                    &denied_root_refs,
                )
                .map_err(|e| e.to_string())
            })?;
        permission_overrides.push(value);
    }
    let launch_config = LaunchConfig {
        runtime_home: Some(private_runtime),
        codex_bin,
        wonder_version: env!("CARGO_PKG_VERSION").into(),
        permission_overrides,
    };
    // Bind local storage immediately. The recovery service verifies and starts
    // execution asynchronously; installation failure never hides saved chats.
    let app_server = AppServerClient::unavailable(
        env!("CARGO_PKG_VERSION").into(),
        wonderd::ingestion::notification_sink(store.clone()),
    );
    let runtime_catalog = RuntimeCatalog::default();

    let (events, _) = tokio::sync::broadcast::channel::<HostEventEnvelope>(256);
    let (revocations, _) = tokio::sync::broadcast::channel::<String>(64);
    let mut pairing_state = PairingState::default();
    for device in store.list_owner_devices().await? {
        let public_key: DevicePublicKeyJwk = serde_json::from_str(&device.public_key_jwk)?;
        pairing_state.restore_device(
            device.id,
            public_key,
            device.revoked_at.is_some(),
            device.session_expires_at_ms,
        );
    }
    for session in store
        .list_active_sessions(unix_timestamp_ms() as u64)
        .await?
    {
        let csrf_hash: [u8; 32] = hex::decode(session.csrf_hash)
            .map_err(|_| "stored CSRF hash is not hexadecimal")?
            .try_into()
            .map_err(|_| "stored CSRF hash has invalid length")?;
        pairing_state.restore_session(
            session.token_hash,
            session.device_id,
            csrf_hash,
            session.expires_at_ms,
        );
    }
    let pairing = Arc::new(tokio::sync::Mutex::new(pairing_state));
    let app_server = Arc::new(tokio::sync::Mutex::new(app_server));
    let public_origin =
        std::env::var("WONDER_PUBLIC_ORIGIN").unwrap_or_else(|_| "https://wonder.invalid".into());
    let public_origin_file = std::env::var_os("WONDER_PUBLIC_ORIGIN_FILE").map(PathBuf::from);
    let linked_file_roots = std::env::var_os("WONDER_LINKED_FILE_ROOTS")
        .map(|paths| std::env::split_paths(&paths).collect())
        .unwrap_or_default();
    let claude = wonderd::claude::Runtime::configured(&data_dir, &store);
    let state = AppState {
        claude,
        ingestion: wonderd::ingestion::Ingestion::default(),
        store,
        logger: Arc::clone(&logger),
        loopback_capability: capability,
        host_epoch,
        started_at,
        events,
        revocations,
        pairing,
        public_origin,
        public_origin_file,
        host_installation_id,
        app_server: Arc::clone(&app_server),
        launch_config: Arc::new(tokio::sync::Mutex::new(launch_config)),
        denied_roots: denied_root_refs
            .iter()
            .map(|path| (*path).to_owned())
            .collect(),
        linked_file_roots,
        dispatch_lock: Arc::new(tokio::sync::Mutex::new(())),
        update_admission: Arc::new(Default::default()),
        channel_worker_slots: Arc::new(tokio::sync::Semaphore::new(CHANNEL_WORKER_CONCURRENCY)),
        approval_lock: Arc::new(tokio::sync::Mutex::new(())),
        bots_root: data_dir.join("bots").to_string_lossy().into_owned(),
        bot_home: bot_home.to_string_lossy().into_owned(),
        permission_profile: "wonder_bot_default".into(),
        model: None,
        reasoning_effort: None,
        runtime_catalog: Arc::new(RwLock::new(runtime_catalog)),
        asr_service: Arc::new(wonderd::asr::AsrService::default()),
        asr_slots: Arc::new(tokio::sync::Semaphore::new(1)),
        asr_rate_limits: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        computer_use_enabled: std::env::var("WONDER_COMPUTER_USE_ENABLED").as_deref() == Ok("1"),
        computer_use_bin: std::env::var_os("WONDER_COMPUTER_USE_BIN").map(PathBuf::from),
        computer_supervisor: Arc::new(
            wonderd::computer_sessions::ComputerSessionSupervisor::default(),
        ),
    };
    state
        .computer_supervisor
        .retire_durable_sessions(&state)
        .await;
    state
        .asr_service
        .initialize(&state.store)
        .await
        .map_err(|_| "ASR recovery failed")?;
    wonderd::bot_management::recover_deletions(&state).await;
    let notification_service = wonderd::ingestion::spawn(state.clone()).await;
    let scheduler_task = wonderd::spawn_automation_scheduler(state.clone());
    let listen_addr =
        std::env::var("WONDER_LISTEN_ADDR").unwrap_or_else(|_| "127.0.0.1:3777".into());
    let listen_addr: SocketAddr = listen_addr.parse()?;
    if !listen_addr.ip().is_loopback() {
        return Err("WONDER_LISTEN_ADDR must be a loopback address".into());
    }
    let listener = match tokio::net::TcpListener::bind(listen_addr).await {
        Ok(listener) => listener,
        Err(error) => {
            logger.record(
                "error",
                "startup_failed",
                serde_json::json!({
                    "stage": "daemon_bind",
                    "error": error.to_string(),
                    "elapsedMs": startup_started.elapsed().as_millis(),
                }),
            )?;
            return Err(error.into());
        }
    };
    let dispatcher_task = wonderd::dispatch::spawn(state.clone()).await?;
    let push_task = wonderd::push::spawn(state.clone());
    logger.record(
        "info",
        "daemon_listening",
        serde_json::json!({ "listenAddress": listen_addr, "elapsedMs": startup_started.elapsed().as_millis() }),
    )?;
    let deferred_readiness_task = {
        let app_server = Arc::clone(&app_server);
        let log_dir = log_dir.clone();
        let skills_cwd = bootstrap_home.to_string_lossy().into_owned();
        tokio::spawn(async move {
            let Ok(logger) = JsonlLogger::new(&log_dir, "wonderd.jsonl") else {
                return;
            };
            for (method, params) in [
                ("app/list", serde_json::json!({ "limit": 1 })),
                (
                    "skills/list",
                    serde_json::json!({
                        "cwds": [skills_cwd],
                        "forceReload": false
                    }),
                ),
                (
                    "mcpServerStatus/list",
                    serde_json::json!({ "limit": 1, "detail": "toolsAndAuthOnly" }),
                ),
            ] {
                let probe_started = std::time::Instant::now();
                let outcome = match app_server.lock().await.request(method, params).await {
                    Ok(response) if response.error.is_none() && response.result.is_some() => "ok",
                    Ok(response) => {
                        let error = response
                            .error
                            .map(|error| error.message)
                            .unwrap_or_else(|| "response contained no result".into());
                        let _ = logger.record(
                            "warn",
                            "app_server_readiness_probe",
                            serde_json::json!({
                                "method": method,
                                "outcome": "error",
                                "error": error,
                                "elapsedMs": probe_started.elapsed().as_millis(),
                            }),
                        );
                        "error"
                    }
                    Err(error) => {
                        let _ = logger.record(
                            "warn",
                            "app_server_readiness_probe",
                            serde_json::json!({
                                "method": method,
                                "outcome": "error",
                                "error": error.to_string(),
                                "elapsedMs": probe_started.elapsed().as_millis(),
                            }),
                        );
                        "error"
                    }
                };
                let _ = logger.record(
                    "info",
                    "app_server_readiness_probe",
                    serde_json::json!({
                        "method": method,
                        "outcome": outcome,
                        "elapsedMs": probe_started.elapsed().as_millis(),
                    }),
                );
            }
        })
    };
    println!("wonderd listening on {listen_addr}");
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
    let server = axum::serve(listener, router(state.clone())).with_graceful_shutdown(async {
        let _ = stop_rx.await;
    });
    let server = std::future::IntoFuture::into_future(server);
    tokio::pin!(server);
    tokio::select! {
        result = &mut server => result?,
        _ = shutdown_signal() => {
            let _ = stop_tx.send(());
            // A connected native event socket must not prevent logout/quit.
            let _ = tokio::time::timeout(std::time::Duration::from_secs(2), &mut server).await;
        }
    }
    drop(notification_service);
    scheduler_task.abort();
    dispatcher_task.abort();
    push_task.abort();
    let _ = scheduler_task.await;
    deferred_readiness_task.abort();
    let _ = deferred_readiness_task.await;
    state.computer_supervisor.shutdown(&state).await;
    let mut app_server = app_server.lock().await;
    app_server.shutdown().await?;
    if let Some(claude) = &state.claude {
        claude.client.lock().await.shutdown().await?;
    }
    logger.record("info", "daemon_stopped", serde_json::json!({}))?;
    Ok(())
}

async fn resolve_codex() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Ok(path) = std::env::var("WONDER_CODEX_BIN") {
        return Ok(PathBuf::from(path));
    }
    let resources = Path::new("/Applications/ChatGPT.app/Contents/Resources");
    // The supported launcher preserves adjacency with codex-code-mode-host.
    // Do not select the nested Mach-O directly; its helper lives elsewhere.
    let current = resources.join("codex-cli/bin/codex");
    Ok(if current.is_file() {
        current
    } else {
        resources.join("codex")
    })
}

fn data_directory() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Ok(path) = std::env::var("WONDER_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    let home = std::env::var("HOME")?;
    Ok(data_home::prepare(Path::new(&home))?)
}

fn persistent_host_installation_id(data_dir: &Path) -> Result<String, Box<dyn std::error::Error>> {
    let path = data_dir.join("host-installation-id");
    match std::fs::read_to_string(&path) {
        Ok(value) => {
            let value = value.trim();
            if uuid::Uuid::parse_str(value).is_err() {
                return Err("stored host installation id is invalid".into());
            }
            return Ok(value.to_owned());
        }
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => return Err(error.into()),
        Err(_) => {}
    }

    let generated = uuid::Uuid::new_v4().to_string();
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
    {
        Ok(mut file) => {
            use std::io::Write;
            writeln!(file, "{generated}")?;
            Ok(generated)
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let value = std::fs::read_to_string(&path)?;
            let value = value.trim();
            if uuid::Uuid::parse_str(value).is_err() {
                return Err("stored host installation id is invalid".into());
            }
            Ok(value.to_owned())
        }
        Err(error) => Err(error.into()),
    }
}

fn log_directory() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Ok(path) = std::env::var("WONDER_LOG_DIR") {
        return Ok(PathBuf::from(path));
    }
    let home = std::env::var("HOME")?;
    Ok(PathBuf::from(home).join("Library/Logs/Wonder"))
}

fn sensitive_roots(codex_state: &Path) -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    let home = std::env::var("HOME")?;
    let home = PathBuf::from(home);
    let mut roots = vec![
        codex_state.to_path_buf(),
        home.join(".claude"),
        home.join(".claude.json"),
        home.join(".ssh"),
        home.join(".aws"),
        home.join(".gnupg"),
        home.join(".config/gcloud"),
    ];
    roots.sort_unstable();
    Ok(roots)
}

fn effective_codex_home() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(path) = std::env::var_os("CODEX_HOME") {
        return Ok(PathBuf::from(path));
    }
    let home = std::env::var("HOME")?;
    Ok(PathBuf::from(home).join(".codex"))
}

fn unix_timestamp_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_millis()
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("install SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {},
            _ = terminate.recv() => {},
        }
    }
    #[cfg(not(unix))]
    let _ = tokio::signal::ctrl_c().await;
}
