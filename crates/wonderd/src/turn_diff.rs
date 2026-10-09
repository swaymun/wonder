//! Codex's whole-turn diff (`turn/diff/updated`) is the authority for what a
//! response edited: it includes shell edits and sub-agent work that per-item
//! `fileChange` rows miss. Codex sends it live only (`thread/read` turns carry
//! no diff), so the latest one is held until `turn/completed` and saved once.

use std::collections::VecDeque;
use std::sync::{LazyLock, Mutex};

/// Turns in flight across all threads; older entries are dropped first.
const MAX_TURNS: usize = 64;
/// A larger diff is not kept; the phone falls back to the turn's edit rows.
const MAX_DIFF_BYTES: usize = 4 * 1024 * 1024;

static LATEST: LazyLock<Mutex<VecDeque<(String, String, String)>>> =
    LazyLock::new(|| Mutex::new(VecDeque::new()));

pub(crate) fn record(thread_id: &str, turn_id: &str, diff: &str) {
    let mut latest = LATEST.lock().unwrap_or_else(|e| e.into_inner());
    latest.retain(|(thread, turn, _)| !(thread == thread_id && turn == turn_id));
    if diff.len() > MAX_DIFF_BYTES {
        return;
    }
    latest.push_back((thread_id.to_owned(), turn_id.to_owned(), diff.to_owned()));
    while latest.len() > MAX_TURNS {
        latest.pop_front();
    }
}

pub(crate) fn take(thread_id: &str, turn_id: &str) -> Option<String> {
    let mut latest = LATEST.lock().unwrap_or_else(|e| e.into_inner());
    let index = latest
        .iter()
        .position(|(thread, turn, _)| thread == thread_id && turn == turn_id)?;
    latest.remove(index).map(|(_, _, diff)| diff)
}

/// A `turnDiff` item whose `changes` match `fileChange` so history counts and
/// sanitizes them the same way. An empty diff still records "no edits".
pub(crate) fn item(turn_id: &str, diff: &str) -> serde_json::Value {
    serde_json::json!({
        "id": format!("turn-diff:{turn_id}"),
        "type": "turnDiff",
        "status": "completed",
        "changes": changes(diff),
    })
}

/// Split a `git diff` into one change per file, keeping only its hunks.
fn changes(diff: &str) -> Vec<serde_json::Value> {
    let mut files = Vec::new();
    let mut current: Option<(String, &'static str, Vec<&str>)> = None;
    let mut finish = |file: Option<(String, &'static str, Vec<&str>)>| {
        if let Some((path, kind, hunks)) = file {
            if !path.is_empty() {
                files.push(serde_json::json!({
                    "path": path, "kind": {"type": kind}, "diff": hunks.join("\n"),
                }));
            }
        }
    };
    for line in diff.lines() {
        if let Some(header) = line.strip_prefix("diff --git ") {
            finish(current.take());
            current = Some((header_path(header), "update", Vec::new()));
            continue;
        }
        let Some((path, kind, hunks)) = current.as_mut() else {
            continue;
        };
        if !hunks.is_empty() || line.starts_with("@@") {
            hunks.push(line);
        } else if line.starts_with("new file mode") {
            *kind = "add";
        } else if line.starts_with("deleted file mode") {
            *kind = "delete";
        } else if let Some(target) = line.strip_prefix("+++ b/") {
            *path = target.to_owned();
        } else if let Some(source) = line.strip_prefix("--- a/") {
            if *kind == "delete" {
                *path = source.to_owned();
            }
        } else if let Some(target) = line.strip_prefix("rename to ") {
            *path = target.to_owned();
        }
    }
    finish(current.take());
    files
}

/// `a/x b/x` → `x`; quoted or spaced paths are corrected by the `+++`/`---` lines.
fn header_path(header: &str) -> String {
    header
        .rsplit_once(" b/")
        .map(|(_, path)| path.to_owned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_a_turn_diff_into_files_with_their_hunks() {
        let diff = "diff --git a/src/app.js b/src/app.js\nindex 1..2 100644\n--- a/src/app.js\n+++ b/src/app.js\n@@ -1,3 +1,4 @@\n line\n-old\n+new\n+more\ndiff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+a\n+b\ndiff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\ndiff --git a/logo.png b/logo.png\nnew file mode 100644\nBinary files /dev/null and b/logo.png differ\n";
        let files = changes(diff);
        let summary = files
            .iter()
            .map(|f| {
                (
                    f["path"].as_str().unwrap(),
                    f["kind"]["type"].as_str().unwrap(),
                    f["diff"].as_str().unwrap(),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            summary,
            [
                (
                    "src/app.js",
                    "update",
                    "@@ -1,3 +1,4 @@\n line\n-old\n+new\n+more"
                ),
                ("new.txt", "add", "@@ -0,0 +1,2 @@\n+a\n+b"),
                ("gone.txt", "delete", "@@ -1 +0,0 @@\n-x"),
                ("logo.png", "add", ""),
            ]
        );
    }

    #[test]
    fn keeps_only_the_latest_diff_per_turn_and_takes_it_once() {
        record("thread-td", "turn-td", "first");
        record("thread-td", "turn-td", "second");
        assert_eq!(take("thread-td", "turn-td").as_deref(), Some("second"));
        assert_eq!(take("thread-td", "turn-td"), None);
        record("thread-td", "too-big", &"x".repeat(MAX_DIFF_BYTES + 1));
        assert_eq!(take("thread-td", "too-big"), None);
    }
}
