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
            let busy = record.get("status").and_then(serde_json::Value::as_str) == Some("busy");
            *live.entry(session.to_owned()).or_insert(false) |= busy;
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
        // An idle session is still open in that app.
        assert_eq!(
            live_sessions_in(&idle),
            HashMap::from([("idle".to_owned(), false)])
        );
    }
}
