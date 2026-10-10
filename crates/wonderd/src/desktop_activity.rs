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

/// Sessions whose reply Claude Code on the Mac is writing right now. Its
/// record says "busy" also while only background agents run after the reply
/// ended; the transcript's last entry tells the two apart, so background work
/// alone does not show the chat as working.
pub(crate) async fn claude_busy_sessions() -> HashSet<String> {
    let Some(dir) = claude_sessions_dir() else {
        return HashSet::new();
    };
    let projects = claude_projects_dir();
    tokio::task::spawn_blocking(move || busy_sessions_with_transcripts(&dir, projects.as_deref()))
        .await
        .unwrap_or_default()
}

fn busy_sessions_with_transcripts(dir: &Path, projects: Option<&Path>) -> HashSet<String> {
    live_records_in(dir)
        .into_iter()
        .filter(|record| record.writing(projects))
        .map(|record| record.session)
        .collect()
}

fn claude_projects_dir() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CLAUDE_CONFIG_DIR") {
        return Some(PathBuf::from(path).join("projects"));
    }
    Some(PathBuf::from(std::env::var_os("HOME")?).join(".claude/projects"))
}

/// Claude Code names a project's transcript folder after its working folder.
fn project_folder_name(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

const TRANSCRIPT_TAIL_BYTES: u64 = 512 * 1024;

/// Whether the session's main turn is unfinished, from the end of its
/// transcript: the newest top-level message is a prompt, a tool result, or a
/// reply that stopped to call a tool. Mirrors `mainTurnRunning` in the Claude
/// runtime. `None` when the transcript cannot be read.
pub(crate) fn main_turn_running(path: &Path) -> Option<bool> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    let start = length.saturating_sub(TRANSCRIPT_TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut tail = Vec::new();
    file.take(TRANSCRIPT_TAIL_BYTES)
        .read_to_end(&mut tail)
        .ok()?;
    let text = String::from_utf8_lossy(&tail);
    for line in text.lines().rev() {
        let Ok(entry) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let flag = |name: &str| entry.get(name).and_then(serde_json::Value::as_bool) == Some(true);
        if flag("isSidechain") || flag("isMeta") {
            continue;
        }
        match entry.get("type").and_then(serde_json::Value::as_str) {
            Some("assistant") => {
                let reason = entry
                    .pointer("/message/stop_reason")
                    .and_then(serde_json::Value::as_str);
                return Some(matches!(reason, None | Some("tool_use" | "pause_turn")));
            }
            Some("user") => {
                let content = entry.pointer("/message/content");
                let first = content.and_then(|c| match c {
                    serde_json::Value::String(text) => Some(text.as_str()),
                    serde_json::Value::Array(blocks) => blocks
                        .iter()
                        .find_map(|b| b.get("text").and_then(serde_json::Value::as_str)),
                    _ => None,
                });
                return Some(
                    !first.is_some_and(|t| {
                        t.trim_start().starts_with("[Request interrupted by user")
                    }),
                );
            }
            _ => {}
        }
    }
    Some(false)
}

/// Sessions a live Claude Code process (desktop or terminal) has open, and
/// whether each has work running: a reply, a dialog, or background agents,
/// commands or monitors.
pub(crate) async fn claude_live_sessions() -> HashMap<String, bool> {
    let Some(dir) = claude_sessions_dir() else {
        return HashMap::new();
    };
    tokio::task::spawn_blocking(move || live_sessions_in(&dir))
        .await
        .unwrap_or_default()
}

/// Whether the session is open in Claude Code outside the desktop app, such as
/// a terminal, where Wonder cannot take the chat over.
pub(crate) async fn claude_open_in_terminal(session: &str) -> bool {
    let Some(dir) = claude_sessions_dir() else {
        return false;
    };
    let session = session.to_owned();
    tokio::task::spawn_blocking(move || open_in_terminal_in(&dir, &session))
        .await
        .unwrap_or(false)
}

fn open_in_terminal_in(dir: &Path, session: &str) -> bool {
    live_records_in(dir)
        .into_iter()
        .any(|record| record.session == session && record.outside_desktop_app())
}

/// Session IDs whose live Claude Code process reports itself busy.
#[cfg(test)]
pub(crate) fn busy_sessions_in(dir: &Path) -> HashSet<String> {
    busy_sessions_with_transcripts(dir, None)
}

fn live_sessions_in(dir: &Path) -> HashMap<String, bool> {
    let mut live = HashMap::new();
    for record in live_records_in(dir) {
        let working = record.background();
        *live.entry(record.session).or_insert(false) |= working;
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
    /// "busy" (a reply or background agents), "shell" (only background
    /// commands or monitors), "waiting" (a dialog) or "idle".
    status: String,
    cwd: Option<String>,
    desktop: bool,
}

impl LiveRecord {
    fn busy(&self) -> bool {
        matches!(self.status.as_str(), "busy" | "waiting")
    }
    /// Whether this process is writing the chat's reply (or waits on a dialog
    /// in it), rather than only keeping background work after its reply.
    fn writing(&self, projects: Option<&Path>) -> bool {
        if !self.busy() {
            return false;
        }
        let transcript = projects.zip(self.cwd.as_deref()).map(|(projects, cwd)| {
            projects
                .join(project_folder_name(cwd))
                .join(format!("{}.jsonl", self.session))
        });
        // Without a readable transcript, trust the record.
        transcript
            .and_then(|path| main_turn_running(&path))
            .unwrap_or(true)
    }
    fn outside_desktop_app(&self) -> bool {
        !self.desktop || !desktop_claude_process(self.pid)
    }
    /// Work that reports back into this process's copy of the conversation.
    fn background(&self) -> bool {
        matches!(self.status.as_str(), "busy" | "shell" | "waiting")
    }
}

/// Why Wonder cannot continue a Claude chat right now.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum StopRefusal {
    /// Claude on the Mac is writing a reply in it (or waits on a dialog).
    Busy,
    /// It is open in Claude Code outside the desktop app, such as a terminal.
    Terminal,
    /// The desktop app's process for it did not exit.
    StillRunning,
}

/// Whether Claude on the Mac holds this chat, so a Wonder message waits: a
/// reply it is writing, or the chat open in Claude Code in a terminal. Only
/// reads; background work left running after a reply does not hold it.
pub(crate) async fn claude_holds_session(session: &str) -> Option<StopRefusal> {
    let dir = claude_sessions_dir()?;
    let projects = claude_projects_dir();
    let session = session.to_owned();
    tokio::task::spawn_blocking(move || holds_in(&dir, projects.as_deref(), &session))
        .await
        .unwrap_or(Some(StopRefusal::StillRunning))
}

fn holds_in(dir: &Path, projects: Option<&Path>, session: &str) -> Option<StopRefusal> {
    let records: Vec<LiveRecord> = live_records_in(dir)
        .into_iter()
        .filter(|record| record.session == session)
        .collect();
    if records.iter().any(|record| record.writing(projects)) {
        return Some(StopRefusal::Busy);
    }
    if records.iter().any(LiveRecord::outside_desktop_app) {
        return Some(StopRefusal::Terminal);
    }
    None
}

/// Ends the process the Claude desktop app keeps for this chat, so a turn from
/// Wonder becomes part of the conversation: the app starts the chat again from
/// its transcript when it is next used. Background agents, commands or
/// monitors still running in that process end with it; Wonder says so before
/// the message is sent. A reply being written, or a chat open in Claude Code
/// in a terminal, is never ended. `Ok` when nothing holds the chat.
pub(crate) async fn end_desktop_session(session: &str) -> Result<(), StopRefusal> {
    let Some(dir) = claude_sessions_dir() else {
        return Ok(());
    };
    let projects = claude_projects_dir();
    let session = session.to_owned();
    tokio::task::spawn_blocking(move || {
        end_desktop_session_in(&dir, projects.as_deref(), &session, false)
    })
    .await
    .unwrap_or(Err(StopRefusal::StillRunning))
}

/// After Wonder's turn, closes a desktop process opened for the chat during
/// it, which holds the conversation from before, but only while it is idle:
/// nothing the app runs there is ended for this.
pub(crate) async fn close_idle_desktop_session(session: &str) {
    let Some(dir) = claude_sessions_dir() else {
        return;
    };
    let projects = claude_projects_dir();
    let session = session.to_owned();
    let _ = tokio::task::spawn_blocking(move || {
        end_desktop_session_in(&dir, projects.as_deref(), &session, true)
    })
    .await;
}

fn end_desktop_session_in(
    dir: &Path,
    projects: Option<&Path>,
    session: &str,
    only_idle: bool,
) -> Result<(), StopRefusal> {
    if let Some(refusal) = holds_in(dir, projects, session) {
        return Err(refusal);
    }
    let records: Vec<LiveRecord> = live_records_in(dir)
        .into_iter()
        .filter(|record| record.session == session)
        .collect();
    if only_idle && records.iter().any(LiveRecord::background) {
        return Err(StopRefusal::Busy);
    }
    for record in &records {
        // SIGTERM lets Claude Code save the chat and end its shells and agents.
        unsafe { libc::kill(record.pid, libc::SIGTERM) };
    }
    for _ in 0..80 {
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
                    close_idle_desktop_session(&session).await;
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
    #[cfg(test)]
    if tests::DESKTOP_PIDS.lock().unwrap().contains(&pid) {
        return true;
    }
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
        // Agent SDK processes, including Wonder's own Claude runs, are not a
        // chat open in Claude on the Mac.
        if record.get("entrypoint").and_then(serde_json::Value::as_str) == Some("sdk-ts") {
            continue;
        }
        let Some(session) = record.get("sessionId").and_then(serde_json::Value::as_str) else {
            continue;
        };
        if process_alive(pid) {
            live.push(LiveRecord {
                pid,
                session: session.to_owned(),
                status: record
                    .get("status")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("idle")
                    .chars()
                    .take(32)
                    .collect(),
                cwd: record
                    .get("cwd")
                    .and_then(serde_json::Value::as_str)
                    .filter(|cwd| cwd.starts_with('/') && cwd.len() <= 4096)
                    .map(str::to_owned),
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
        // Wonder's own Agent SDK run is not a chat open on the Mac.
        let sdk = tempfile::tempdir().unwrap();
        std::fs::write(
            sdk.path().join(format!("{me}.json")),
            serde_json::json!({"pid": me, "sessionId": "wonder", "status": "busy", "entrypoint": "sdk-ts"}).to_string(),
        )
        .unwrap();
        assert!(live_sessions_in(sdk.path()).is_empty());
        // The test process is not the desktop app's Claude Code, so it is never stopped.
        let me_session = "busy";
        assert_eq!(
            end_desktop_session_in(dir.path(), None, me_session, false),
            Err(StopRefusal::Busy)
        );
        std::fs::write(
            idle.join(format!("{me}.json")),
            serde_json::json!({"pid": me, "sessionId": "idle", "status": "idle", "entrypoint": "claude-desktop"}).to_string(),
        )
        .unwrap();
        assert_eq!(
            end_desktop_session_in(&idle, None, "idle", false),
            Err(StopRefusal::Terminal)
        );
        assert_eq!(holds_in(&idle, None, "idle"), Some(StopRefusal::Terminal));
        assert_eq!(end_desktop_session_in(&idle, None, "absent", false), Ok(()));
        // Only a chat Wonder cannot take over is reported as held on the Mac.
        assert!(open_in_terminal_in(&idle, "idle"));
        assert!(!open_in_terminal_in(&idle, "absent"));
        // An idle session is still open in that app.
        assert_eq!(
            live_sessions_in(&idle),
            HashMap::from([("idle".to_owned(), false)])
        );
    }

    pub(super) static DESKTOP_PIDS: std::sync::LazyLock<std::sync::Mutex<HashSet<i32>>> =
        std::sync::LazyLock::new(Default::default);

    /// A stand-in for the desktop app's Claude Code: a child process that is
    /// reaped when it exits, so its pid stops existing.
    fn desktop_process() -> i32 {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let pid = child.id() as i32;
        DESKTOP_PIDS.lock().unwrap().insert(pid);
        std::thread::spawn(move || child.wait());
        pid
    }

    // Background agents keep the record "busy" after the reply ends, and
    // background commands may leave it "idle" or "shell": none shows the chat
    // as working or holds a Wonder message. Wonder ends the app's process (and
    // that work) to continue the chat; only a reply being written holds it,
    // and the idle-only close after Wonder's own turn never ends that work.
    #[test]
    fn background_work_is_not_a_running_reply_and_ends_on_takeover() {
        let sessions = tempfile::tempdir().unwrap();
        let projects = tempfile::tempdir().unwrap();
        let cwd = "/work/My App";
        let folder = projects.path().join(project_folder_name(cwd));
        std::fs::create_dir_all(&folder).unwrap();
        assert_eq!(project_folder_name(cwd), "-work-My-App");
        let mut pid = desktop_process();
        let record = |pid: i32, status: &str| {
            for entry in std::fs::read_dir(sessions.path()).unwrap() {
                std::fs::remove_file(entry.unwrap().path()).unwrap();
            }
            std::fs::write(
                sessions.path().join(format!("{pid}.json")),
                serde_json::json!({"pid": pid, "sessionId": "s1", "status": status, "cwd": cwd, "entrypoint": "claude-desktop"})
                    .to_string(),
            )
            .unwrap()
        };
        let transcript = |lines: &[serde_json::Value]| {
            let text: Vec<String> = lines.iter().map(|l| l.to_string()).collect();
            std::fs::write(folder.join("s1.jsonl"), text.join("\n") + "\n").unwrap();
        };
        let prompt = serde_json::json!({"type": "user", "message": {"content": "Go"}});
        let tool = serde_json::json!({"type": "assistant", "message": {"stop_reason": "tool_use", "content": []}});
        let reply = serde_json::json!({"type": "assistant", "message": {"stop_reason": "end_turn", "content": []}});
        let child = serde_json::json!({"type": "assistant", "isSidechain": true, "message": {"stop_reason": null}});
        let busy = || busy_sessions_with_transcripts(sessions.path(), Some(projects.path()));
        let end = |only_idle| {
            end_desktop_session_in(sessions.path(), Some(projects.path()), "s1", only_idle)
        };

        record(pid, "busy");
        transcript(&[prompt.clone(), tool.clone()]);
        assert_eq!(
            busy(),
            HashSet::from(["s1".to_owned()]),
            "the reply is still running"
        );
        assert_eq!(
            end(false),
            Err(StopRefusal::Busy),
            "a reply being written is never ended"
        );
        transcript(&[prompt.clone(), tool, reply.clone(), child]);
        assert!(busy().is_empty(), "the reply ended; only agents run");
        assert_eq!(holds_in(sessions.path(), Some(projects.path()), "s1"), None);
        assert_eq!(
            end(true),
            Err(StopRefusal::Busy),
            "the idle-only close keeps the agents"
        );
        assert!(process_alive(pid));
        assert_eq!(end(false), Ok(()), "a Wonder message takes the chat over");
        assert!(!process_alive(pid));

        for status in ["shell", "idle"] {
            pid = desktop_process();
            record(pid, status);
            assert!(busy().is_empty());
            assert_eq!(
                live_sessions_in(sessions.path()),
                HashMap::from([("s1".to_owned(), status == "shell")])
            );
            assert_eq!(end(false), Ok(()));
            assert!(!process_alive(pid));
        }

        let me = std::process::id() as i32;
        let record = |status: &str| {
            std::fs::write(
                sessions.path().join(format!("{me}.json")),
                serde_json::json!({"pid": me, "sessionId": "s1", "status": status, "cwd": cwd})
                    .to_string(),
            )
            .unwrap()
        };
        // An unreadable transcript keeps trusting the record.
        std::fs::remove_file(folder.join("s1.jsonl")).unwrap();
        record("busy");
        assert_eq!(busy(), HashSet::from(["s1".to_owned()]));
        let interrupted = serde_json::json!({"type": "user", "message": {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}});
        transcript(&[prompt, reply, interrupted]);
        assert!(busy().is_empty());
    }
}
