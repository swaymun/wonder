//! Threads that a desktop or terminal app on this Mac is running right now.
//! Claude Code records each live interactive session in
//! `~/.claude/sessions/<pid>.json`; Codex writes an unfinished turn to the
//! thread's rollout log. Only these records are read.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

const MAX_SESSION_RECORDS: usize = 256;
const MAX_RECORD_BYTES: u64 = 64 * 1024;
const MAX_KNOWN_ROLLOUTS: usize = 2048;

/// Rollout paths learned from Codex thread listings and reads.
static CODEX_ROLLOUTS: LazyLock<Mutex<HashMap<String, PathBuf>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

pub(crate) fn remember_codex_rollout(thread: &str, path: &str) {
    let path = PathBuf::from(path);
    if !path.is_absolute() {
        return;
    }
    if let Ok(mut known) = CODEX_ROLLOUTS.lock() {
        if known.len() >= MAX_KNOWN_ROLLOUTS && !known.contains_key(thread) {
            known.clear();
        }
        known.insert(thread.to_owned(), path);
    }
}

pub(crate) fn codex_rollout(thread: &str) -> Option<PathBuf> {
    CODEX_ROLLOUTS.lock().ok()?.get(thread).cloned()
}

/// Whether the Codex thread has a recent unfinished turn in its rollout log.
pub(crate) async fn codex_thread_busy(thread: &str) -> bool {
    let Some(path) = codex_rollout(thread) else {
        return false;
    };
    tokio::task::spawn_blocking(move || {
        crate::history::codex_rollout_open_turn(&path, std::time::SystemTime::now()).is_some()
    })
    .await
    .unwrap_or(false)
}

pub(crate) fn claude_sessions_dir() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CLAUDE_CONFIG_DIR") {
        return Some(PathBuf::from(path).join("sessions"));
    }
    Some(PathBuf::from(std::env::var_os("HOME")?).join(".claude/sessions"))
}

pub(crate) async fn claude_busy_sessions() -> HashSet<String> {
    claude_live_sessions()
        .await
        .into_iter()
        .filter_map(|(session, busy)| busy.then_some(session))
        .collect()
}

/// Sessions a live Claude Code process (desktop or terminal) has open, and
/// whether each is busy.
pub(crate) async fn claude_live_sessions() -> HashMap<String, bool> {
    let Some(dir) = claude_sessions_dir() else {
        return HashMap::new();
    };
    tokio::task::spawn_blocking(move || live_sessions_in(&dir))
        .await
        .unwrap_or_default()
}

/// Session IDs whose live Claude Code process reports itself busy.
#[cfg(test)]
pub(crate) fn busy_sessions_in(dir: &Path) -> HashSet<String> {
    live_sessions_in(dir)
        .into_iter()
        .filter_map(|(session, busy)| busy.then_some(session))
        .collect()
}

fn live_sessions_in(dir: &Path) -> HashMap<String, bool> {
    let mut live = HashMap::new();
    for record in live_records_in(dir) {
        *live.entry(record.session).or_insert(false) |= record.busy;
        if live.len() >= MAX_SESSION_RECORDS {
            break;
        }
    }
    live
}

/// One live Claude Code process and the session it has open.
struct LiveRecord {
    pid: i32,
    session: String,
    busy: bool,
    desktop: bool,
}

/// Why a desktop chat could not be stopped for Wonder to continue it.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum StopRefusal {
    Busy,
    Terminal,
    StillRunning,
}

/// Stops the idle process the Claude desktop app keeps for this chat, so a
/// message from Wonder becomes part of the conversation: the app starts the
/// chat again from its transcript when it is next opened. A busy chat, or one
/// open in Claude Code in a terminal, is never stopped.
pub(crate) async fn stop_idle_desktop_session(session: &str) -> Result<(), StopRefusal> {
    let Some(dir) = claude_sessions_dir() else {
        return Ok(());
    };
    let session = session.to_owned();
    tokio::task::spawn_blocking(move || stop_idle_desktop_session_in(&dir, &session))
        .await
        .unwrap_or(Err(StopRefusal::StillRunning))
}

fn stop_idle_desktop_session_in(dir: &Path, session: &str) -> Result<(), StopRefusal> {
    let records: Vec<LiveRecord> = live_records_in(dir)
        .into_iter()
        .filter(|record| record.session == session)
        .collect();
    if records.iter().any(|record| record.busy) {
        return Err(StopRefusal::Busy);
    }
    if records
        .iter()
        .any(|record| !record.desktop || !desktop_claude_process(record.pid))
    {
        return Err(StopRefusal::Terminal);
    }
    for record in &records {
        unsafe { libc::kill(record.pid, libc::SIGTERM) };
    }
    for _ in 0..50 {
        if records.iter().all(|record| !process_alive(record.pid)) {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    Err(StopRefusal::StillRunning)
}

const DESKTOP_APP: &str = "/Applications/Claude.app";
const DESKTOP_BUNDLE_ID: &str = "com.anthropic.claudefordesktop";

/// A new Claude chat started in Wonder also belongs in the Claude desktop app.
/// After its first response, the Mac opens Claude's own resume link in the
/// background, which adds the chat to the app's sidebar, then closes the idle
/// process the app starts for it so Wonder keeps sending directly. The link
/// waits while the app is in front, so the chat you are reading never changes.
pub(crate) fn schedule_desktop_import(
    state: crate::AppState,
    conversation: String,
    session: String,
) {
    if cfg!(test) || !Path::new(DESKTOP_APP).is_dir() || !valid_session_id(&session) {
        return;
    }
    tokio::spawn(async move {
        let started = tokio::time::Instant::now();
        while started.elapsed() < std::time::Duration::from_secs(2 * 60 * 60) {
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            let working = state
                .store
                .conversation_has_active_turn(&conversation)
                .await
                .unwrap_or(true);
            if working || desktop_app_frontmost().await {
                continue;
            }
            if claude_live_sessions().await.contains_key(&session) {
                return; // Already open on the Mac.
            }
            let link = format!("claude://resume?session={session}");
            let opened = tokio::process::Command::new("/usr/bin/open")
                .args(["-g", &link])
                .status()
                .await
                .is_ok_and(|status| status.success());
            if !opened {
                return;
            }
            for _ in 0..20 {
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                if claude_live_sessions().await.get(&session) == Some(&false) {
                    let _ = stop_idle_desktop_session(&session).await;
                    break;
                }
            }
            let _ = state.logger.record(
                "info",
                "claude_desktop_import",
                serde_json::json!({"conversationId": conversation}),
            );
            return;
        }
    });
}

fn valid_session_id(value: &str) -> bool {
    value.len() == 36 && value.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

async fn desktop_app_frontmost() -> bool {
    let Ok(front) = tokio::process::Command::new("/usr/bin/lsappinfo")
        .arg("front")
        .output()
        .await
    else {
        return true;
    };
    let asn = String::from_utf8_lossy(&front.stdout).trim().to_owned();
    if asn.is_empty() {
        return false;
    }
    let Ok(info) = tokio::process::Command::new("/usr/bin/lsappinfo")
        .args(["info", "-only", "bundleid", &asn])
        .output()
        .await
    else {
        return true;
    };
    String::from_utf8_lossy(&info.stdout).contains(DESKTOP_BUNDLE_ID)
}

/// The Claude Code binary the Claude desktop app runs for its chats, checked
/// by executable path so a reused process ID is never signalled.
#[cfg(target_os = "macos")]
fn desktop_claude_process(pid: i32) -> bool {
    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let length =
        unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    if length <= 0 {
        return false;
    }
    let path = String::from_utf8_lossy(&buffer[..length as usize]);
    path.contains("/Library/Application Support/Claude/claude-code/")
        && path.ends_with("/MacOS/claude")
}

#[cfg(not(target_os = "macos"))]
fn desktop_claude_process(_pid: i32) -> bool {
    false
}

fn live_records_in(dir: &Path) -> Vec<LiveRecord> {
    let mut live = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return live;
    };
    for entry in entries.flatten().take(MAX_SESSION_RECORDS * 4) {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(stem) = name.strip_suffix(".json") else {
            continue;
        };
        if stem.is_empty() || stem.len() > 10 || !stem.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let Ok(pid) = stem.parse::<i32>() else {
            continue;
        };
        let path = entry.path();
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if !metadata.is_file() || metadata.len() > MAX_RECORD_BYTES {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(record) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        if record.get("pid").and_then(serde_json::Value::as_i64) != Some(i64::from(pid)) {
            continue;
        }
        let Some(session) = record.get("sessionId").and_then(serde_json::Value::as_str) else {
            continue;
        };
        if process_alive(pid) {
            live.push(LiveRecord {
                pid,
                session: session.to_owned(),
                busy: record.get("status").and_then(serde_json::Value::as_str) == Some("busy"),
                desktop: record.get("entrypoint").and_then(serde_json::Value::as_str)
                    == Some("claude-desktop"),
            });
        }
        if live.len() >= MAX_SESSION_RECORDS {
            break;
        }
    }
    live
}

fn process_alive(pid: i32) -> bool {
    if pid <= 0 {
        return false;
    }
    // Signal 0 checks existence only.
    let result = unsafe { libc::kill(pid, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_live_busy_records_named_by_their_pid_count() {
        let dir = tempfile::tempdir().unwrap();
        let me = std::process::id() as i32;
        let write = |name: &str, value: serde_json::Value| {
            std::fs::write(dir.path().join(name), value.to_string()).unwrap()
        };
        write(
            &format!("{me}.json"),
            serde_json::json!({"pid": me, "sessionId": "busy", "status": "busy"}),
        );
        write(
            "999999999.json",
            serde_json::json!({"pid": 999999999, "sessionId": "gone", "status": "busy"}),
        );
        write(
            "1.json",
            serde_json::json!({"pid": me, "sessionId": "mismatch", "status": "busy"}),
        );
        write(
            &format!("{me}.key"),
            serde_json::json!({"pid": me, "sessionId": "key", "status": "busy"}),
        );
        let idle = dir.path().join("idle");
        std::fs::create_dir(&idle).unwrap();
        std::fs::write(
            idle.join(format!("{me}.json")),
            serde_json::json!({"pid": me, "sessionId": "idle", "status": "idle"}).to_string(),
        )
        .unwrap();
        assert_eq!(
            busy_sessions_in(dir.path()),
            HashSet::from(["busy".to_owned()])
        );
        assert!(busy_sessions_in(&idle).is_empty());
        // The test process is not the desktop app's Claude Code, so it is never stopped.
        let me_session = "busy";
        assert_eq!(
            stop_idle_desktop_session_in(dir.path(), me_session),
            Err(StopRefusal::Busy)
        );
        std::fs::write(
            idle.join(format!("{me}.json")),
            serde_json::json!({"pid": me, "sessionId": "idle", "status": "idle", "entrypoint": "claude-desktop"}).to_string(),
        )
        .unwrap();
        assert_eq!(
            stop_idle_desktop_session_in(&idle, "idle"),
            Err(StopRefusal::Terminal)
        );
        assert_eq!(stop_idle_desktop_session_in(&idle, "absent"), Ok(()));
        // An idle session is still open in that app.
        assert_eq!(
            live_sessions_in(&idle),
            HashMap::from([("idle".to_owned(), false)])
        );
    }
}
