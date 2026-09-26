use std::{
    collections::HashMap,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
    sync::{Arc, Mutex},
};

use serde_json::Value;
use std::collections::VecDeque;

use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{oneshot, Mutex as AsyncMutex};
use tokio::time::{timeout, Duration};

use crate::{
    initialize_request, is_allowed_method, require_experimental_api, JsonRpcError, RpcResponse,
};

const APP_SERVER_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const CONTROL_PLANE_ENV_VARS: [&str; 8] = [
    "TS_AUTHKEY",
    "WONDER_CODEX_BIN",
    "WONDER_COMPUTER_USE_BIN",
    "WONDER_COMPUTER_USE_ENABLED",
    "WONDER_LOOPBACK_CAPABILITY",
    "WONDER_LOGO_PATH",
    "WONDER_PUBLIC_ORIGIN",
    "WONDER_PUBLIC_ORIGIN_FILE",
];

type PendingRequests = Arc<Mutex<HashMap<u64, oneshot::Sender<Result<RpcResponse, String>>>>>;

#[derive(Debug)]
pub enum RuntimeError {
    Io(std::io::Error),
    Json(serde_json::Error),
    Protocol(String),
    Incompatible(String),
}

impl std::fmt::Display for RuntimeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "App Server I/O error: {error}"),
            Self::Json(error) => write!(formatter, "App Server JSONL error: {error}"),
            Self::Protocol(message) => write!(formatter, "App Server protocol error: {message}"),
            Self::Incompatible(message) => {
                write!(formatter, "Codex runtime incompatible: {message}")
            }
        }
    }
}

impl std::error::Error for RuntimeError {}

impl RuntimeError {
    pub fn is_transport_failure(&self) -> bool {
        match self {
            Self::Io(_) => true,
            Self::Protocol(message) => {
                message.contains("App Server EOF")
                    || message.contains("App Server read error")
                    || message.contains("response channel closed")
            }
            Self::Json(_) | Self::Incompatible(_) => false,
        }
    }
}

impl From<std::io::Error> for RuntimeError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for RuntimeError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

#[derive(Clone, Debug)]
pub struct LaunchConfig {
    pub codex_bin: PathBuf,
    pub runtime_home: Option<PathBuf>,
    pub wonder_version: String,
    pub permission_overrides: Vec<String>,
}

/// Wonder-owned provider bridge, using the same durable JSONL transport. This
/// has its own handshake; it never bypasses verification for a Codex process.
#[derive(Clone, Debug)]
pub struct BridgeLaunchConfig {
    pub node_bin: PathBuf,
    pub entrypoint: PathBuf,
    pub state_dir: PathBuf,
    pub npm_cli: Option<PathBuf>,
    pub wonder_version: String,
}

impl LaunchConfig {
    pub fn args(&self) -> Vec<String> {
        let mut args = vec!["app-server".into()];
        if let Some(home) = &self.runtime_home {
            args.push("-c".into());
            args.push(format!(
                "sqlite_home={}",
                serde_json::to_string(home).expect("UTF-8 runtime home")
            ));
        }
        // Wonder owns its Computer Use boundary. Do not let a Bot silently
        // fall through to the host desktop's node_repl/CUA MCP, which has a
        // different permission model and can expose the wrong UI to the
        // model. Wonder's native helper is registered as a dynamic tool and
        // is resolved through the paired owner's approval flow instead.
        for override_value in [
            "features.default_mode_request_user_input=true",
            // Use the code-mode helper beside the verified ChatGPT runtime.
            "features.code_mode_host=true",
            "mcp_servers.node_repl.enabled=false",
            "mcp_servers.cua_repl={command=\"/usr/bin/true\",args=[],enabled=false,startup_timeout_sec=1}",
            "plugins.\"unified-computer-use@openai-bundled\".enabled=false",
            "plugins.\"computer-use@openai-bundled\".enabled=false",
        ] {
            args.push("-c".into());
            args.push(override_value.into());
        }
        for override_value in &self.permission_overrides {
            args.push("-c".into());
            args.push(override_value.clone());
        }
        args.push("--stdio".into());
        args
    }
}

/// Called before a notification is broadcast. Returning an error keeps the
/// original envelope in the reader and retries with backpressure.
pub type NotificationSink =
    Arc<dyn Fn(Value) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send>> + Send + Sync>;

#[derive(Clone, Default)]
pub struct RuntimeHealth {
    id: Arc<String>,
    alive: Arc<AtomicBool>,
    storage_blocked: Arc<AtomicBool>,
}

impl RuntimeHealth {
    pub fn id(&self) -> &str {
        &self.id
    }
    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }
    pub fn storage_blocked(&self) -> bool {
        self.storage_blocked.load(Ordering::SeqCst)
    }
}

struct ReaderGuard(RuntimeHealth);
impl Drop for ReaderGuard {
    fn drop(&mut self) {
        self.0.alive.store(false, Ordering::SeqCst);
    }
}

pub struct AppServerClient {
    child: Option<Child>,
    health: RuntimeHealth,
    reader_task: tokio::task::JoinHandle<()>,
    notification_sink: Option<NotificationSink>,
    stdin: Arc<AsyncMutex<Option<ChildStdin>>>,
    next_id: Arc<AtomicU64>,
    wonder_version: String,
    pending: PendingRequests,
    notifications: Arc<Mutex<VecDeque<Value>>>,
    notification_tx: tokio::sync::broadcast::Sender<Value>,
}

/// Multiplexed requests bound to one runtime generation. Cloning does not own
/// the child process; restart closes old handles instead of retargeting them.
#[derive(Clone)]
pub struct RpcClient {
    stdin: Arc<AsyncMutex<Option<ChildStdin>>>,
    pending: PendingRequests,
    next_id: Arc<AtomicU64>,
    health: RuntimeHealth,
}

struct PendingRequest {
    id: u64,
    pending: PendingRequests,
}
impl Drop for PendingRequest {
    fn drop(&mut self) {
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.id);
    }
}

impl RpcClient {
    pub fn health(&self) -> RuntimeHealth {
        self.health.clone()
    }
    pub async fn request(&self, method: &str, params: Value) -> Result<RpcResponse, RuntimeError> {
        if !self.health.is_alive() {
            return Err(RuntimeError::Protocol("App Server transport closed".into()));
        }
        if !is_allowed_method(method) {
            return Err(RuntimeError::Protocol(format!(
                "App Server method is not allowlisted: {method}"
            )));
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        self.request_value(serde_json::json!({ "method": method, "id": id, "params": params }))
            .await
    }

    async fn request_value(&self, request: Value) -> Result<RpcResponse, RuntimeError> {
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| RuntimeError::Protocol("request id is required".into()))?;
        let (sender, receiver) = oneshot::channel();
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id, sender);
        let _pending = PendingRequest {
            id,
            pending: self.pending.clone(),
        };
        if let Err(error) = self.write_json(&request).await {
            self.pending
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&id);
            return Err(error);
        }
        match timeout(APP_SERVER_REQUEST_TIMEOUT, receiver).await {
            Ok(Ok(Ok(response))) => Ok(response),
            Ok(Ok(Err(message))) => Err(RuntimeError::Protocol(message)),
            Ok(Err(_)) => Err(RuntimeError::Protocol(
                "App Server response channel closed".into(),
            )),
            Err(_) => {
                self.pending
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(&id);
                Err(RuntimeError::Protocol(
                    "App Server response timed out".into(),
                ))
            }
        }
    }

    pub async fn respond_value(
        &self,
        id: Value,
        result: Option<Value>,
        error: Option<JsonRpcError>,
    ) -> Result<(), RuntimeError> {
        self.write_json(&response_value(id, result, error)?).await
    }
    async fn write_json(&self, value: &Value) -> Result<(), RuntimeError> {
        if !self.health.is_alive() {
            return Err(RuntimeError::Protocol("App Server transport closed".into()));
        }
        let mut guard = self.stdin.lock().await;
        let stdin = guard
            .as_mut()
            .ok_or_else(|| RuntimeError::Protocol("Runtime unavailable".into()))?;
        stdin
            .write_all(serde_json::to_string(value)?.as_bytes())
            .await?;
        stdin.write_all(b"\n").await?;
        stdin.flush().await?;
        Ok(())
    }
}

impl Drop for AppServerClient {
    fn drop(&mut self) {
        self.fail_pending();
        self.reader_task.abort();
        self.health.alive.store(false, Ordering::SeqCst);
        if let Some(child) = self.child.as_mut() {
            let _ = child.start_kill();
        }
    }
}

impl AppServerClient {
    /// A closed transport lets authenticated local reads survive missing or
    /// incompatible installation. Recovery uses the same strict spawn checks.
    pub fn unavailable(wonder_version: String, sink: NotificationSink) -> Self {
        let (notification_tx, _) = tokio::sync::broadcast::channel(256);
        Self {
            child: None,
            health: RuntimeHealth::default(),
            reader_task: tokio::spawn(async {}),
            notification_sink: Some(sink),
            stdin: Arc::new(AsyncMutex::new(None)),
            next_id: Arc::new(AtomicU64::new(1)),
            wonder_version,
            pending: Arc::new(Mutex::new(HashMap::new())),
            notifications: Arc::new(Mutex::new(VecDeque::new())),
            notification_tx,
        }
    }
    pub async fn spawn(config: LaunchConfig) -> Result<Self, RuntimeError> {
        let (notification_tx, _) = tokio::sync::broadcast::channel(256);
        Self::spawn_with_notifications(config, notification_tx, None).await
    }

    pub async fn spawn_with_notification_sink(
        config: LaunchConfig,
        sink: NotificationSink,
    ) -> Result<Self, RuntimeError> {
        let (tx, _) = tokio::sync::broadcast::channel(256);
        Self::spawn_with_notifications(config, tx, Some(sink)).await
    }

    pub fn health(&self) -> RuntimeHealth {
        self.health.clone()
    }

    fn fail_pending(&self) {
        for (_, sender) in self
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .drain()
        {
            let _ = sender.send(Err("App Server transport closed".into()));
        }
    }

    async fn spawn_with_notifications(
        config: LaunchConfig,
        notification_tx: tokio::sync::broadcast::Sender<Value>,
        notification_sink: Option<NotificationSink>,
    ) -> Result<Self, RuntimeError> {
        let canonical_bin = verify_runtime(&config.codex_bin).await?;

        let mut command = Command::new(canonical_bin);
        command
            .kill_on_drop(true)
            .args(config.args())
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        for variable in CONTROL_PLANE_ENV_VARS {
            command.env_remove(variable);
        }
        if let Some(home) = &config.runtime_home {
            command
                .env("CODEX_HOME", home)
                .env("CODEX_SQLITE_HOME", home);
        }
        Self::spawn_transport(
            command,
            config.wonder_version,
            notification_tx,
            notification_sink,
            false,
        )
        .await
    }

    pub async fn spawn_bridge(
        config: BridgeLaunchConfig,
        sink: NotificationSink,
    ) -> Result<Self, RuntimeError> {
        let (tx, _) = tokio::sync::broadcast::channel(256);
        Self::spawn_bridge_with_notifications(config, tx, Some(sink)).await
    }

    async fn spawn_bridge_with_notifications(
        config: BridgeLaunchConfig,
        notification_tx: tokio::sync::broadcast::Sender<Value>,
        notification_sink: Option<NotificationSink>,
    ) -> Result<Self, RuntimeError> {
        let mut command = Command::new(tokio::fs::canonicalize(&config.node_bin).await?);
        command.env_clear();
        for variable in [
            "HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL",
        ] {
            if let Some(value) = std::env::var_os(variable) {
                command.env(variable, value);
            }
        }
        command
            .arg(tokio::fs::canonicalize(&config.entrypoint).await?)
            .arg("--state-dir")
            .arg(&config.state_dir)
            .kill_on_drop(true)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        if let Some(npm) = config.npm_cli {
            command.arg("--npm-cli").arg(npm);
        }
        Self::spawn_transport(
            command,
            config.wonder_version,
            notification_tx,
            notification_sink,
            true,
        )
        .await
    }

    async fn spawn_transport(
        mut command: Command,
        wonder_version: String,
        notification_tx: tokio::sync::broadcast::Sender<Value>,
        notification_sink: Option<NotificationSink>,
        bridge: bool,
    ) -> Result<Self, RuntimeError> {
        let mut child = command.spawn()?;
        if let Some(mut stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let mut buffer = [0_u8; 8192];
                loop {
                    match stderr.read(&mut buffer).await {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                }
            });
        }
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| RuntimeError::Protocol("stdout/stdin pipe unavailable".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| RuntimeError::Protocol("stdout pipe unavailable".into()))?;
        let stdin = Arc::new(AsyncMutex::new(Some(stdin)));
        let pending: PendingRequests = Arc::new(Mutex::new(HashMap::new()));
        let notifications = Arc::new(Mutex::new(VecDeque::new()));
        let reader_pending = Arc::clone(&pending);
        let reader_notifications = Arc::clone(&notifications);
        let reader_notification_tx = notification_tx.clone();
        let health = RuntimeHealth {
            id: Arc::new(format!(
                "{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            )),
            ..RuntimeHealth::default()
        };
        health.alive.store(true, Ordering::SeqCst);
        let reader_health = health.clone();
        let sink = notification_sink.clone();
        let reader_task = tokio::spawn(async move {
            let _guard = ReaderGuard(reader_health.clone());
            let mut lines = BufReader::new(stdout).lines();
            loop {
                let line = match lines.next_line().await {
                    Ok(Some(line)) => line,
                    Ok(None) => {
                        let mut pending = reader_pending.lock().unwrap_or_else(|e| e.into_inner());
                        for (_, sender) in pending.drain() {
                            let _ = sender.send(Err("App Server EOF before response".into()));
                        }
                        break;
                    }
                    Err(error) => {
                        let mut pending = reader_pending.lock().unwrap_or_else(|e| e.into_inner());
                        let message = format!("App Server read error: {error}");
                        for (_, sender) in pending.drain() {
                            let _ = sender.send(Err(message.clone()));
                        }
                        break;
                    }
                };
                let mut value: Value = match serde_json::from_str(&line) {
                    Ok(value) => value,
                    Err(_) => break,
                };
                if !value.is_object() {
                    break;
                }
                if value.get("method").is_none() {
                    if let Some(id) = value.get("id").and_then(Value::as_u64) {
                        let sender = reader_pending
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .remove(&id);
                        if let Some(sender) = sender {
                            let result = serde_json::from_value::<RpcResponse>(value)
                                .map_err(|error| error.to_string());
                            let _ = sender.send(result);
                        }
                        continue;
                    }
                }
                if let Some(sink) = &sink {
                    if value.is_object() {
                        value["_wonderRuntimeId"] = Value::String(reader_health.id().to_owned());
                    }
                    while sink(value.clone()).await.is_err() {
                        reader_health.storage_blocked.store(true, Ordering::SeqCst);
                        tokio::time::sleep(Duration::from_millis(250)).await;
                    }
                    reader_health.storage_blocked.store(false, Ordering::SeqCst);
                }
                if let Ok(mut queue) = reader_notifications.lock() {
                    if queue.len() >= 256 {
                        queue.pop_front();
                    }
                    queue.push_back(value.clone());
                }
                let _ = reader_notification_tx.send(value);
            }
        });
        let mut client = Self {
            child: Some(child),
            health,
            reader_task,
            notification_sink,
            stdin,
            next_id: Arc::new(AtomicU64::new(1)),
            wonder_version,
            pending,
            notifications,
            notification_tx,
        };
        client.initialize_protocol(bridge).await?;
        Ok(client)
    }

    pub async fn initialize(&mut self) -> Result<Value, RuntimeError> {
        self.initialize_protocol(false).await
    }

    async fn initialize_protocol(&mut self, bridge: bool) -> Result<Value, RuntimeError> {
        if self.next_id.load(Ordering::SeqCst) != 1 {
            return Err(RuntimeError::Protocol(
                "initialize may only be sent once".into(),
            ));
        }
        let request = initialize_request(&self.wonder_version).request;
        let response = self.request_value(serde_json::to_value(request)?).await?;
        let result = response
            .result
            .ok_or_else(|| RuntimeError::Incompatible("initialize returned no result".into()))?;
        if bridge {
            if result
                .pointer("/wonderBridge/protocolVersion")
                .and_then(Value::as_u64)
                != Some(1)
                || result
                    .pointer("/wonderBridge/family")
                    .and_then(Value::as_str)
                    != Some("claude")
            {
                return Err(RuntimeError::Protocol(
                    "Claude bridge returned an incompatible handshake".into(),
                ));
            }
        } else {
            require_experimental_api(&result)
                .map_err(|message| RuntimeError::Incompatible(message.into()))?;
        }
        self.write_json(&serde_json::json!({ "method": "initialized", "params": {} }))
            .await?;
        self.next_id.store(2, Ordering::SeqCst);
        Ok(result)
    }

    /// Capture one transport generation while holding only the lifecycle lock.
    pub fn rpc(&self) -> RpcClient {
        RpcClient {
            stdin: self.stdin.clone(),
            pending: self.pending.clone(),
            next_id: self.next_id.clone(),
            health: self.health.clone(),
        }
    }

    pub async fn request(
        &mut self,
        method: &str,
        params: Value,
    ) -> Result<RpcResponse, RuntimeError> {
        self.rpc().request(method, params).await
    }

    async fn request_value(&self, request: Value) -> Result<RpcResponse, RuntimeError> {
        self.rpc().request_value(request).await
    }

    pub fn drain_notifications(&mut self) -> impl Iterator<Item = Value> + '_ {
        let values = self
            .notifications
            .lock()
            .map(|mut queue| queue.drain(..).collect::<Vec<_>>())
            .unwrap_or_default();
        values.into_iter()
    }

    pub fn subscribe_notifications(&self) -> tokio::sync::broadcast::Receiver<Value> {
        self.notification_tx.subscribe()
    }

    pub async fn respond(
        &self,
        id: u64,
        result: Option<Value>,
        error: Option<JsonRpcError>,
    ) -> Result<(), RuntimeError> {
        self.respond_value(serde_json::json!(id), result, error)
            .await
    }

    pub async fn respond_value(
        &self,
        id: Value,
        result: Option<Value>,
        error: Option<JsonRpcError>,
    ) -> Result<(), RuntimeError> {
        self.write_json(&response_value(id, result, error)?).await
    }

    pub async fn restart(&mut self, config: LaunchConfig) -> Result<(), RuntimeError> {
        self.health.alive.store(false, Ordering::SeqCst);
        self.stop_child().await?;
        let replacement = Self::spawn_with_notifications(
            config,
            self.notification_tx.clone(),
            self.notification_sink.clone(),
        )
        .await?;
        *self = replacement;
        Ok(())
    }

    pub async fn restart_bridge(&mut self, config: BridgeLaunchConfig) -> Result<(), RuntimeError> {
        self.stop_child().await?;
        *self = Self::spawn_bridge_with_notifications(
            config,
            self.notification_tx.clone(),
            self.notification_sink.clone(),
        )
        .await?;
        Ok(())
    }

    async fn write_json(&self, value: &Value) -> Result<(), RuntimeError> {
        self.rpc().write_json(value).await
    }

    async fn stop_child(&mut self) -> Result<(), RuntimeError> {
        self.health.alive.store(false, Ordering::SeqCst);
        self.fail_pending();
        if let Some(mut stdin) = self.stdin.lock().await.take() {
            let _ = stdin.shutdown().await;
        }
        let Some(child) = self.child.as_mut() else {
            return Ok(());
        };
        match timeout(Duration::from_secs(2), child.wait()).await {
            Ok(status) => {
                let _ = status?;
            }
            Err(_) => {
                child.kill().await?;
                let _ = child.wait().await?;
            }
        }
        Ok(())
    }

    pub async fn shutdown(&mut self) -> Result<(), RuntimeError> {
        self.stop_child().await
    }
}

fn response_value(
    id: Value,
    result: Option<Value>,
    error: Option<JsonRpcError>,
) -> Result<Value, RuntimeError> {
    match (result, error) {
        (Some(result), None) => Ok(serde_json::json!({ "id": id, "result": result })),
        (None, Some(error)) => Ok(serde_json::json!({ "id": id, "error": error })),
        (None, None) => Ok(serde_json::json!({ "id": id, "result": null })),
        (Some(_), Some(_)) => Err(RuntimeError::Protocol(
            "JSON-RPC response must contain exactly one of result or error".into(),
        )),
    }
}

/// Offline compatibility check used by the installer before activation.
pub async fn verify_runtime(
    codex_bin: &std::path::Path,
) -> Result<std::path::PathBuf, RuntimeError> {
    timeout(Duration::from_secs(30), verify_runtime_inner(codex_bin))
        .await
        .map_err(|_| RuntimeError::Incompatible("Runtime verification timed out".into()))?
}

async fn verify_runtime_inner(
    codex_bin: &std::path::Path,
) -> Result<std::path::PathBuf, RuntimeError> {
    let canonical_bin = tokio::fs::canonicalize(codex_bin).await?;
    verify_code_mode_host(&canonical_bin).await?;
    let version = Command::new(&canonical_bin)
        .kill_on_drop(true)
        .arg("--version")
        .output()
        .await?;
    if !version.status.success() {
        return Err(RuntimeError::Incompatible("codex --version failed".into()));
    }
    let version = String::from_utf8_lossy(&version.stdout).trim().to_owned();
    if !version.starts_with("codex-cli ") {
        return Err(RuntimeError::Incompatible(format!(
            "unexpected runtime version: {version}"
        )));
    }
    verify_generated_schemas(&canonical_bin, crate::expected_schema_hashes(&version)).await?;

    Ok(canonical_bin)
}

// A successful --help is not evidence that the embedded JavaScript runtime works.
// This local probe has no tools, credentials, network request or model invocation.
async fn verify_code_mode_host(codex_bin: &std::path::Path) -> Result<(), RuntimeError> {
    let helper = codex_bin.with_file_name("codex-code-mode-host");
    timeout(Duration::from_secs(10), probe_code_mode_host(&helper))
        .await
        .map_err(|_| RuntimeError::Incompatible("Code-mode helper timed out. Update or reinstall ChatGPT, then restart Wonder.".into()))?
        .map_err(|error| RuntimeError::Incompatible(format!("Code-mode helper could not execute: {error}. Update or reinstall ChatGPT, then restart Wonder.")))
}

async fn probe_code_mode_host(helper: &std::path::Path) -> Result<(), RuntimeError> {
    let mut child = Command::new(helper)
        .args(["--listen", "stdio"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()?;
    let mut input = child
        .stdin
        .take()
        .ok_or_else(|| RuntimeError::Protocol("missing probe input".into()))?;
    let mut output = child
        .stdout
        .take()
        .ok_or_else(|| RuntimeError::Protocol("missing probe output".into()))?;
    async fn send(input: &mut ChildStdin, value: Value) -> Result<(), RuntimeError> {
        let bytes = serde_json::to_vec(&value)?;
        input.write_u32_le(bytes.len() as u32).await?;
        input.write_all(&bytes).await?;
        input.flush().await?;
        Ok(())
    }
    async fn receive(output: &mut tokio::process::ChildStdout) -> Result<Value, RuntimeError> {
        let size = output.read_u32_le().await?;
        if size > 1024 * 1024 {
            return Err(RuntimeError::Protocol("oversized probe response".into()));
        }
        let mut bytes = vec![0; size as usize];
        output.read_exact(&mut bytes).await?;
        Ok(serde_json::from_slice(&bytes)?)
    }
    send(&mut input, serde_json::json!({"type":"connection/hello", "supportedVersions":[1], "requiredCapabilities":[], "optionalCapabilities":[]})).await?;
    if receive(&mut output).await?["type"] != "connection/ready" {
        return Err(RuntimeError::Protocol(
            "unsupported code-mode handshake".into(),
        ));
    }
    send(&mut input, serde_json::json!({"type":"operation/request", "id":1, "request":{"method":"session/open", "sessionId":"wonder-readiness"}})).await?;
    let opened = receive(&mut output).await?;
    if opened["id"] != 1 || opened["result"]["value"]["type"] != "session/ready" {
        return Err(RuntimeError::Protocol(
            "code-mode session unavailable".into(),
        ));
    }
    send(&mut input, serde_json::json!({"type":"operation/request", "id":2, "request":{"method":"session/execute", "sessionId":"wonder-readiness", "request":{
        "tool_call_id":"readiness", "enabled_tools":[], "source":"text(6 * 7)", "yield_time_ms":1000, "max_output_tokens":100
    }}})).await?;
    let mut result = receive(&mut output).await?;
    // The host may acknowledge startup before publishing the initial result.
    if result["type"] == "operation/response"
        && result["id"] == 2
        && result["result"]["status"] == "ok"
        && result["result"]["value"]["type"] == "execution/started"
    {
        result = receive(&mut output).await?;
    }
    if !valid_code_mode_probe_result(&result) {
        return Err(RuntimeError::Protocol("code-mode execution failed".into()));
    }
    child.kill().await?;
    child.wait().await?;
    Ok(())
}

fn valid_code_mode_probe_result(result: &Value) -> bool {
    result["type"] == "execute/initialResponse"
        && result["id"] == 2
        && result["result"]["status"] == "ok"
        && result["result"]["value"]["Result"]["error_text"].is_null()
        && result["result"]["value"]["Result"]["content_items"]
            == serde_json::json!([{"type":"input_text", "text":"42"}])
}

async fn verify_generated_schemas(
    codex_bin: &std::path::Path,
    expected_hashes: Option<(&str, &str)>,
) -> Result<(), RuntimeError> {
    let temporary = tempfile::tempdir().map_err(RuntimeError::Io)?;
    let stable_dir = temporary.path().join("stable");
    let experimental_dir = temporary.path().join("experimental");
    tokio::fs::create_dir_all(&stable_dir).await?;
    tokio::fs::create_dir_all(&experimental_dir).await?;
    for (args, output_dir) in [
        (
            vec!["app-server", "generate-json-schema", "--out"],
            stable_dir.as_path(),
        ),
        (
            vec![
                "app-server",
                "generate-json-schema",
                "--experimental",
                "--out",
            ],
            experimental_dir.as_path(),
        ),
    ] {
        let mut command = Command::new(codex_bin);
        let output = command
            .kill_on_drop(true)
            .args(args)
            .arg(output_dir)
            .output()
            .await?;
        if !output.status.success() {
            return Err(RuntimeError::Incompatible(
                "schema generation failed".into(),
            ));
        }
    }
    let stable =
        tokio::fs::read(stable_dir.join("codex_app_server_protocol.v2.schemas.json")).await?;
    let experimental =
        tokio::fs::read(experimental_dir.join("codex_app_server_protocol.v2.schemas.json")).await?;
    let stable_hash = hex::encode(Sha256::digest(&stable));
    let experimental_hash = hex::encode(Sha256::digest(&experimental));
    if let Some(hashes) = expected_hashes {
        if stable_hash == hashes.0 && experimental_hash == hashes.1 {
            return Ok(());
        }
    }
    crate::schema_compat::verify(&stable, &experimental).map_err(|reason| {
        RuntimeError::Incompatible(format!(
            "Codex changed a required protocol contract ({reason}; stable {stable_hash}, experimental {experimental_hash}); update Wonder"
        ))
    })?;
    Ok(())
}

pub fn build_permission_override(
    profile_name: &str,
    bot_home: &str,
    read_roots: &[&str],
    write_roots: &[&str],
    deny_roots: &[&str],
) -> Result<String, RuntimeError> {
    if profile_name.is_empty()
        || !profile_name.chars().all(|character| {
            character.is_ascii_alphanumeric() || character == '_' || character == '-'
        })
    {
        return Err(RuntimeError::Protocol(
            "invalid permission profile name".into(),
        ));
    }
    let filesystem = permission_filesystem(bot_home, read_roots, write_roots, deny_roots)?;
    let entries = filesystem
        .iter()
        .map(|(path, access)| format!("{}={}", toml_string(path), toml_string(access)))
        .collect::<Vec<_>>();
    Ok(format!("permissions.{profile_name}={{description=\"Wonder Bot\",filesystem={{{}}},network={{enabled=true}}}}",entries.join(",")))
}

pub fn permission_filesystem(
    bot_home: &str,
    read_roots: &[&str],
    write_roots: &[&str],
    deny_roots: &[&str],
) -> Result<std::collections::BTreeMap<String, String>, RuntimeError> {
    let bot_home = validated_profile_path(bot_home, false)?;
    validate_write_root(&bot_home)?;
    let mut rules = std::collections::BTreeMap::from([
        (":minimal".into(), "read".into()),
        (bot_home.clone(), "write".into()),
    ]);
    for path in instruction_files(Path::new(&bot_home)) {
        rules.insert(path.to_string_lossy().into_owned(), "read".into());
    }
    for path in read_roots {
        rules
            .entry(validated_profile_path(path, false)?)
            .or_insert("read".into());
    }
    for path in write_roots {
        let path = validated_profile_path(path, false)?;
        validate_write_root(&path)?;
        rules.insert(path, "write".into());
    }
    for path in deny_roots {
        rules.insert(validated_profile_path(path, true)?, "deny".into());
    }
    Ok(rules)
}

fn instruction_files(workspace: &Path) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    for parent in workspace.ancestors() {
        candidates.push(parent.join("AGENTS.md"));
        candidates.push(parent.join("AGENTS.override.md"));
    }
    let codex = std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")));
    if let Some(codex) = codex {
        candidates.push(codex.join("AGENTS.md"));
        candidates.push(codex.join("AGENTS.override.md"));
    }
    candidates.retain(|path| {
        std::fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
    });
    candidates.sort();
    candidates.dedup();
    candidates
}

fn validate_write_root(path: &str) -> Result<(), RuntimeError> {
    let path = Path::new(path);
    let system = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/private/etc",
        "/Library",
        "/Applications",
        "/private/var/db",
        "/private/var/root",
        "/dev",
    ];
    let broad_home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .is_some_and(|home| home.starts_with(path));
    if broad_home
        || system
            .iter()
            .any(|root| path.starts_with(root) || Path::new(root).starts_with(path))
    {
        return Err(RuntimeError::Protocol(
            "write roots cannot overlap system files or the whole user home".into(),
        ));
    }
    Ok(())
}

fn validated_profile_path(path: &str, allow_sensitive_deny: bool) -> Result<String, RuntimeError> {
    let candidate = Path::new(path);
    if !candidate.is_absolute()
        || candidate == Path::new("/")
        || candidate
            .components()
            .any(|component| component == std::path::Component::ParentDir)
    {
        return Err(RuntimeError::Protocol(
            "permission roots must be absolute, normalized, and cannot be the filesystem root"
                .into(),
        ));
    }
    let canonical = canonicalize_with_existing_parent(candidate)?;
    if !allow_sensitive_deny && is_sensitive_path(&canonical) {
        return Err(RuntimeError::Protocol(
            "permission roots cannot include sensitive credential state".into(),
        ));
    }
    Ok(canonical.to_string_lossy().into_owned())
}

fn canonicalize_with_existing_parent(candidate: &Path) -> Result<PathBuf, RuntimeError> {
    if candidate.exists() {
        return std::fs::canonicalize(candidate).map_err(RuntimeError::Io);
    }
    let mut existing = candidate.to_path_buf();
    let mut suffix = Vec::new();
    while !existing.exists() {
        let name = existing
            .file_name()
            .ok_or_else(|| RuntimeError::Protocol("permission root has no existing parent".into()))?
            .to_owned();
        suffix.push(name);
        existing.pop();
    }
    let mut canonical = std::fs::canonicalize(existing).map_err(RuntimeError::Io)?;
    for component in suffix.iter().rev() {
        canonical.push(component);
    }
    Ok(canonical)
}

fn is_sensitive_path(path: &Path) -> bool {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return false;
    };
    [".codex", ".ssh", ".aws", ".gnupg", ".config/gcloud"]
        .iter()
        .map(|suffix| home.join(suffix))
        .any(|root| path == root || path.starts_with(root))
}

fn toml_string(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[tokio::test]
    async fn newer_runtime_uses_local_schema_contract_and_rejects_breakage() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../research/codex-app-server/0.155.0-alpha.16.3");
        let stable = fixture.join("stable/codex_app_server_protocol.v2.schemas.json");
        let experimental = dir.path().join("experimental.json");
        std::fs::copy(
            fixture.join("experimental/codex_app_server_protocol.v2.schemas.json"),
            &experimental,
        )
        .unwrap();
        let binary = dir.path().join("codex");
        std::fs::write(
            &binary,
            format!(
                "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'codex-cli 9.9.9'; exit 0; fi\nlast=''; for arg in \"$@\"; do last=\"$arg\"; done\nif [ \"$3\" = --experimental ]; then cp '{}' \"$last/codex_app_server_protocol.v2.schemas.json\"; else cp '{}' \"$last/codex_app_server_protocol.v2.schemas.json\"; fi\n",
                experimental.display(),
                stable.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        let helper = dir.path().join("codex-code-mode-host");
        std::fs::write(
            &helper,
            include_str!("../../../tests/fixtures/code-mode-host.py"),
        )
        .unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o700)).unwrap();

        assert!(verify_runtime(&binary).await.is_ok());
        let mut changed: Value =
            serde_json::from_slice(&std::fs::read(&experimental).unwrap()).unwrap();
        changed["definitions"]["TurnStartParams"]["properties"]["permissions"]["type"] =
            serde_json::json!("object");
        std::fs::write(&experimental, serde_json::to_vec(&changed).unwrap()).unwrap();
        assert!(matches!(
            verify_runtime(&binary).await,
            Err(RuntimeError::Incompatible(_))
        ));
    }

    #[tokio::test]
    async fn missing_code_mode_helper_is_incompatible() {
        let dir = tempfile::tempdir().unwrap();
        let result = verify_code_mode_host(&dir.path().join("codex")).await;
        assert!(matches!(result, Err(RuntimeError::Incompatible(_))));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn broken_code_mode_helper_is_incompatible() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let helper = dir.path().join("codex-code-mode-host");
        std::fs::write(&helper, "#!/bin/sh\nexit 1\n").unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(matches!(
            verify_code_mode_host(&dir.path().join("codex")).await,
            Err(RuntimeError::Incompatible(_))
        ));
        std::fs::write(&helper, "#!/bin/sh\nexit 0\n").unwrap();
        // Even a binary that exits successfully must fail without the protocol.
        assert!(verify_code_mode_host(&dir.path().join("codex"))
            .await
            .is_err());
    }

    #[test]
    fn probe_requires_its_exact_successful_execution_result() {
        let mut result = serde_json::json!({"type":"execute/initialResponse", "id":2,
            "result":{"status":"ok","value":{"Result":{"content_items":[{"type":"input_text","text":"42"}],"error_text":null}}}});
        assert!(valid_code_mode_probe_result(&result));
        result["id"] = serde_json::json!(42);
        assert!(!valid_code_mode_probe_result(&result));
        result["id"] = serde_json::json!(2);
        result["result"]["value"]["Result"]["error_text"] = serde_json::json!("failed 42");
        assert!(!valid_code_mode_probe_result(&result));
        result["result"]["value"]["Result"]["error_text"] = Value::Null;
        result["result"]["value"]["Result"]["content_items"] = serde_json::json!([]);
        assert!(!valid_code_mode_probe_result(&result));
    }

    #[test]
    fn launch_is_direct_stdio_and_does_not_expose_a_listener() {
        let config = LaunchConfig {
            runtime_home: None,
            codex_bin: "/usr/local/bin/codex".into(),
            wonder_version: "0.1.0".into(),
            permission_overrides: vec!["permissions.wonder_bot_1={network={enabled=false}}".into()],
        };
        assert_eq!(
            config.args(),
            vec![
                "app-server",
                "-c",
                "features.default_mode_request_user_input=true",
            "-c",
            "features.code_mode_host=true",
                "-c",
                "mcp_servers.node_repl.enabled=false",
                "-c",
                "mcp_servers.cua_repl={command=\"/usr/bin/true\",args=[],enabled=false,startup_timeout_sec=1}",
                "-c",
                "plugins.\"unified-computer-use@openai-bundled\".enabled=false",
                "-c",
                "plugins.\"computer-use@openai-bundled\".enabled=false",
                "-c",
                "permissions.wonder_bot_1={network={enabled=false}}",
                "--stdio"
            ]
        );
        assert!(!config
            .args()
            .iter()
            .any(|argument| argument.contains("--listen")));
    }

    // The bridge shares durable ingestion, but must not be accepted on a
    // Codex-like handshake alone. Exercise an actual child process and pipes.
    #[tokio::test]
    async fn provider_bridge_checks_identity_and_persists_before_broadcast() {
        let root = tempfile::tempdir().unwrap();
        let entrypoint = root.path().join("bridge.py");
        std::fs::write(&entrypoint, r#"
import json,sys
for line in sys.stdin:
    value=json.loads(line)
    if value.get('method')=='initialize':
        result={'wonderBridge':{'protocolVersion':1,'family':'claude'}}
    elif value.get('method')=='account/read':
        print(json.dumps({'method':'thread/started','params':{'thread':{'id':'claude-test'}}}),flush=True)
        result={'connected':True}
    else: continue
    print(json.dumps({'id':value['id'],'result':result}),flush=True)
"#).unwrap();
        let saved = Arc::new(Mutex::new(Vec::new()));
        let observed = saved.clone();
        let sink: NotificationSink = Arc::new(move |frame| {
            let observed = observed.clone();
            Box::pin(async move {
                observed.lock().unwrap().push(frame);
                Ok(())
            })
        });
        let config = BridgeLaunchConfig {
            node_bin: "/usr/bin/python3".into(),
            entrypoint: entrypoint.clone(),
            state_dir: root.path().join("state"),
            npm_cli: None,
            wonder_version: "test".into(),
        };
        let mut client = AppServerClient::spawn_bridge(config.clone(), sink.clone())
            .await
            .unwrap();
        let mut notifications = client.subscribe_notifications();
        let result = client
            .request("account/read", serde_json::json!({}))
            .await
            .unwrap();
        assert_eq!(result.result.unwrap()["connected"], true);
        let frame = timeout(Duration::from_secs(2), notifications.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(frame["_wonderRuntimeId"], client.health().id());
        assert_eq!(saved.lock().unwrap().as_slice(), &[frame]);
        client.shutdown().await.unwrap();
        let source = std::fs::read_to_string(&entrypoint)
            .unwrap()
            .replace("'family':'claude'", "'family':'other'");
        std::fs::write(&entrypoint, source).unwrap();
        assert!(AppServerClient::spawn_bridge(config, sink).await.is_err());
    }

    #[test]
    fn private_runtime_overrides_sqlite_storage() {
        let config = LaunchConfig {
            runtime_home: Some("/tmp/Wonder runtime".into()),
            codex_bin: "codex".into(),
            wonder_version: "test".into(),
            permission_overrides: vec![],
        };
        assert_eq!(config.args()[2], "sqlite_home=\"/tmp/Wonder runtime\"");
    }

    #[test]
    fn control_plane_environment_is_not_forwarded_to_app_server() {
        for variable in [
            "TS_AUTHKEY",
            "WONDER_LOOPBACK_CAPABILITY",
            "WONDER_PUBLIC_ORIGIN",
            "WONDER_PUBLIC_ORIGIN_FILE",
            "WONDER_COMPUTER_USE_BIN",
        ] {
            assert!(
                CONTROL_PLANE_ENV_VARS.contains(&variable),
                "missing scrub for {variable}"
            );
        }
    }

    #[test]
    fn ancestor_instructions_are_read_as_files_without_granting_the_folder() {
        let root = tempfile::tempdir().unwrap();
        let workspace = root.path().join("workspace");
        std::fs::create_dir(&workspace).unwrap();
        let instructions = root.path().join("AGENTS.md");
        std::fs::write(&instructions, "Use the workspace").unwrap();
        assert!(instruction_files(&workspace).contains(&instructions));
        let profile =
            build_permission_override("bot", workspace.to_str().unwrap(), &[], &[], &[]).unwrap();
        assert!(profile.contains(&format!("{}\"=\"read", instructions.display())));
        assert!(!profile.contains(&format!("{}\"=\"read", root.path().display())));
    }

    #[test]
    fn profile_override_has_minimal_read_bot_write_and_enabled_network() {
        let profile = build_permission_override(
            "wonder_bot_1",
            "/tmp/bot",
            &["/tmp/read"],
            &[],
            &["/Users/example/.codex"],
        )
        .expect("valid profile");
        assert!(profile.contains(":minimal\"=\"read"));
        assert!(profile.contains("/tmp/bot\"=\"write"));
        assert!(profile.contains("/tmp/read\"=\"read"));
        assert!(profile.contains("network={enabled=true}"));
        assert!(!profile.contains("sandboxPolicy"));
    }

    #[test]
    fn system_write_roots_are_rejected_with_network_enabled() {
        for root in [
            "/System",
            "/usr/local",
            "/private/etc",
            "/Library",
            "/Applications",
            "/private/var/db",
            "/private/var/root",
            "/dev",
        ] {
            assert!(
                build_permission_override("bot", root, &[], &[], &[]).is_err(),
                "allowed {root}"
            );
        }
        assert!(build_permission_override("bot", "/tmp/bot", &[], &["/System"], &[]).is_err());
    }

    #[test]
    fn profile_roots_reject_filesystem_root_and_sensitive_write_paths() {
        assert!(build_permission_override("wonder_bot_1", "/", &[], &[], &[]).is_err());
        let ssh_root = std::env::var_os("HOME")
            .map(PathBuf::from)
            .expect("tests run with a home directory")
            .join(".ssh");
        assert!(build_permission_override(
            "wonder_bot_1",
            "/tmp/bot",
            &[],
            &[ssh_root.to_str().expect("home path is valid UTF-8")],
            &[]
        )
        .is_err());
    }

    #[test]
    fn json_rpc_response_contains_only_result_or_error() {
        let success = response_value(
            serde_json::json!(7),
            Some(serde_json::json!({"ok": true})),
            None,
        )
        .expect("success");
        assert_eq!(
            success,
            serde_json::json!({"id": 7, "result": {"ok": true}})
        );
        let failure = response_value(
            serde_json::json!(7),
            None,
            Some(JsonRpcError {
                code: -1,
                message: "no".into(),
                data: None,
            }),
        )
        .expect("failure");
        assert_eq!(
            failure,
            serde_json::json!({"id": 7, "error": {"code": -1, "message": "no", "data": null}})
        );
        assert!(response_value(
            serde_json::json!(7),
            Some(serde_json::json!(null)),
            Some(JsonRpcError {
                code: -1,
                message: "no".into(),
                data: None
            })
        )
        .is_err());
    }
}
