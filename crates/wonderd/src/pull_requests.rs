//! Pull requests a Project thread worked with, read through the GitHub CLI the
//! owner already signed in to on this Mac. Wonder never reads or forwards the
//! GitHub token: `gh` keeps it, and the phone receives titles, states and
//! check summaries only.
//!
//! Two sources name a thread's pull requests: GitHub pull request links in its
//! saved agent replies and tool output (including what `gh pr create` prints),
//! and `gh pr list --head` for the branch its folder is on. Results are cached
//! per thread and `gh` calls are bounded, so opening a thread repeatedly does
//! not spend the owner's GitHub rate limit.

use crate::{projects, AppState, OwnerAuthority};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Extension, Json,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path as FsPath, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

/// Bumped when the response changes meaning; clients check it.
const VERSION: u32 = 1;
/// A thread's list is reused this long before `gh` is asked again.
const CACHE_TTL: Duration = Duration::from_secs(60);
/// An explicit refresh within this window returns the cached list.
const MIN_REFRESH: Duration = Duration::from_secs(10);
/// Sign-in state changes rarely; checking it costs a process launch.
const AUTH_TTL: Duration = Duration::from_secs(300);
const MAX_PULL_REQUESTS: usize = 10;
const MAX_TRANSCRIPT_ROWS: u32 = 200;
const GH_TIMEOUT: Duration = Duration::from_secs(15);
const GH_OUTPUT_LIMIT: u64 = 1024 * 1024;
const FIELDS: &str = "number,title,state,isDraft,url,statusCheckRollup";
const MAX_CACHED_THREADS: usize = 200;

/// At most two `gh` processes at once across every thread.
static GH_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);
/// Per thread: when it was read, what named its pull requests, and the list.
/// A new link or branch reads GitHub again at once; otherwise the TTL holds.
#[allow(clippy::type_complexity)]
static CACHE: LazyLock<Mutex<HashMap<String, (Instant, Sources, PullRequestList)>>> =
    LazyLock::new(Default::default);
static AUTH: LazyLock<Mutex<Option<(Instant, GhAccess)>>> = LazyLock::new(Default::default);

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PullRequestList {
    version: u32,
    /// False when `gh` is not installed or not signed in; the app hides the pill.
    available: bool,
    detail: Option<String>,
    pull_requests: Vec<PullRequest>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PullRequest {
    number: u64,
    /// `owner/name`.
    repository: String,
    title: String,
    /// `open`, `draft`, `merged` or `closed`.
    state: &'static str,
    checks: CheckSummary,
    url: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CheckSummary {
    /// `passing`, `failing`, `pending` or `none`.
    state: &'static str,
    passed: u32,
    failed: u32,
    pending: u32,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ListQuery {
    refresh: Option<bool>,
}

#[derive(Clone, Debug, PartialEq)]
enum GhAccess {
    Missing,
    SignedOut,
    Ready(PathBuf),
}

/// A pull request named by its canonical GitHub address.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct PullRef {
    owner: String,
    repo: String,
    number: u64,
}

impl PullRef {
    fn url(&self) -> String {
        format!(
            "https://github.com/{}/{}/pull/{}",
            self.owner, self.repo, self.number
        )
    }
}

fn unavailable_list() -> PullRequestList {
    PullRequestList {
        version: VERSION,
        available: false,
        detail: Some(
            "Sign in with the GitHub CLI (gh auth login) on your Mac to see pull requests.".into(),
        ),
        pull_requests: Vec::new(),
    }
}

pub(crate) async fn list(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(conversation_id): Path<String>,
    Query(query): Query<ListQuery>,
) -> Response {
    let Ok(Some(conversation)) = state.store.project_conversation(&conversation_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let project = match state.store.project(&conversation.project_id).await {
        Ok(Some(project)) => project,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "The Project could not be checked.",
            )
                .into_response()
        }
    };
    if !project.is_included || project.root_for(&conversation.cwd).is_none() {
        return StatusCode::FORBIDDEN.into_response();
    }
    let denied = state.denied_roots.clone();
    let checked = project.clone();
    match tokio::task::spawn_blocking(move || projects::validate_execution_roots(&checked, &denied))
        .await
    {
        Ok(Ok(_)) => {}
        Ok(Err(_)) => return StatusCode::CONFLICT.into_response(),
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "The Project folders could not be checked.",
            )
                .into_response()
        }
    }

    let refresh = query.refresh == Some(true);
    let texts = match state
        .store
        .conversation_text_containing(
            &conversation_id,
            ["github.com/", "/pull/"],
            MAX_TRANSCRIPT_ROWS,
        )
        .await
    {
        Ok(texts) => texts,
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "This thread's history could not be read.",
            )
                .into_response()
        }
    };
    let cwd = FsPath::new(&conversation.cwd);
    let sources = discover(cwd, &texts).await;
    if let Some(cached) = cached(&conversation_id, &sources, refresh) {
        return Json(cached).into_response();
    }
    let gh = match gh_access(refresh).await {
        GhAccess::Ready(gh) => gh,
        GhAccess::Missing | GhAccess::SignedOut => return Json(unavailable_list()).into_response(),
    };
    match fetch(&gh, cwd, &sources).await {
        Ok(list) => {
            store_cached(&conversation_id, sources, &list);
            Json(list).into_response()
        }
        Err(detail) => (StatusCode::SERVICE_UNAVAILABLE, detail).into_response(),
    }
}

fn cached(conversation: &str, sources: &Sources, refresh: bool) -> Option<PullRequestList> {
    let cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let (at, known, list) = cache.get(conversation)?;
    let limit = if refresh { MIN_REFRESH } else { CACHE_TTL };
    (known == sources && at.elapsed() < limit).then(|| list.clone())
}

fn store_cached(conversation: &str, sources: Sources, list: &PullRequestList) {
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if cache.len() >= MAX_CACHED_THREADS {
        cache.retain(|_, (at, _, _)| at.elapsed() < CACHE_TTL);
        if cache.len() >= MAX_CACHED_THREADS {
            cache.clear();
        }
    }
    cache.insert(
        conversation.to_owned(),
        (Instant::now(), sources, list.clone()),
    );
}

/// The `gh` binary. A Mac app's daemon often runs without the shell's PATH,
/// so Homebrew's locations are checked first.
fn find_gh() -> Option<PathBuf> {
    let mut candidates = vec![
        PathBuf::from("/opt/homebrew/bin/gh"),
        PathBuf::from("/usr/local/bin/gh"),
    ];
    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&path).map(|dir| dir.join("gh")));
    }
    candidates.into_iter().find(|path| path.is_file())
}

async fn gh_access(refresh: bool) -> GhAccess {
    if let Some((at, access)) = AUTH.lock().unwrap_or_else(|e| e.into_inner()).clone() {
        // A refresh rechecks a missing sign-in sooner, after the owner fixes it.
        let limit = if refresh && !matches!(access, GhAccess::Ready(_)) {
            MIN_REFRESH
        } else {
            AUTH_TTL
        };
        if at.elapsed() < limit {
            return access;
        }
    }
    let access = match find_gh() {
        None => GhAccess::Missing,
        Some(gh) => {
            match run_gh(&gh, None, &["auth", "status", "--hostname", "github.com"]).await {
                Ok(_) => GhAccess::Ready(gh),
                Err(_) => GhAccess::SignedOut,
            }
        }
    };
    *AUTH.lock().unwrap_or_else(|e| e.into_inner()) = Some((Instant::now(), access.clone()));
    access
}

/// Runs `gh` without a shell, prompts or update checks, bounded in time and
/// output. Arguments are validated pull request addresses and branch names.
async fn run_gh(gh: &FsPath, cwd: Option<&FsPath>, args: &[&str]) -> Result<Vec<u8>, String> {
    use tokio::io::AsyncReadExt;
    let _slot = GH_SLOTS.acquire().await.map_err(|e| e.to_string())?;
    let mut command = tokio::process::Command::new(gh);
    command.args(args);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    // `gh` finds the repository through git, which also needs a usable PATH.
    let mut path = std::env::var_os("PATH").unwrap_or_default();
    if !path.is_empty() {
        path.push(":");
    }
    path.push("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin");
    command
        .env("PATH", path)
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_SPINNER_DISABLED", "1")
        .env("NO_COLOR", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    let stdout = child.stdout.take().ok_or("gh output unavailable")?;
    let stderr = child.stderr.take().ok_or("gh error output unavailable")?;
    let read = |stream: std::pin::Pin<Box<dyn tokio::io::AsyncRead + Send>>| async move {
        let mut bytes = Vec::new();
        stream
            .take(GH_OUTPUT_LIMIT + 1)
            .read_to_end(&mut bytes)
            .await
            .map_err(|e| e.to_string())?;
        Ok::<_, String>(bytes)
    };
    tokio::time::timeout(GH_TIMEOUT, async {
        let (out, err, status) =
            tokio::try_join!(read(Box::pin(stdout)), read(Box::pin(stderr)), async {
                child.wait().await.map_err(|e| e.to_string())
            })?;
        if out.len() as u64 > GH_OUTPUT_LIMIT {
            return Err("gh output exceeded its limit".to_owned());
        }
        if !status.success() {
            return Err(String::from_utf8_lossy(&err).chars().take(500).collect());
        }
        Ok(out)
    })
    .await
    .map_err(|_| "gh timed out".to_owned())?
}

/// What names a thread's pull requests: its folder's feature branch and the
/// pull request links in its history, newest first.
#[derive(Clone, Debug, Default, PartialEq)]
struct Sources {
    branch: Option<String>,
    refs: Vec<PullRef>,
}

async fn discover(cwd: &FsPath, texts: &[String]) -> Sources {
    let mut refs = Vec::new();
    for text in texts {
        for reference in pull_request_refs(text) {
            if !refs.contains(&reference) {
                refs.push(reference);
            }
        }
    }
    Sources {
        branch: current_branch(cwd).await,
        refs,
    }
}

/// Finds the thread's pull requests and reads their current state.
#[cfg(test)]
async fn collect(gh: &FsPath, cwd: &FsPath, texts: &[String]) -> Result<PullRequestList, String> {
    fetch(gh, cwd, &discover(cwd, texts).await).await
}

/// Reads the current state of the pull requests the sources name.
async fn fetch(gh: &FsPath, cwd: &FsPath, sources: &Sources) -> Result<PullRequestList, String> {
    let mut found: Vec<PullRequest> = Vec::new();
    let mut failures = 0;
    let mut attempts = 0;
    if let Some(branch) = &sources.branch {
        attempts += 1;
        match run_gh(
            gh,
            Some(cwd),
            &[
                "pr", "list", "--head", branch, "--state", "all", "--limit", "5", "--json", FIELDS,
            ],
        )
        .await
        {
            Ok(bytes) => match serde_json::from_slice::<Vec<Value>>(&bytes) {
                Ok(rows) => found.extend(rows.iter().filter_map(pull_request)),
                Err(_) => failures += 1,
            },
            Err(_) => failures += 1,
        }
    }
    let mut pending = Vec::new();
    for reference in &sources.refs {
        if found.len() + pending.len() >= MAX_PULL_REQUESTS {
            break;
        }
        let url = reference.url();
        if found.iter().any(|pr| pr.url.eq_ignore_ascii_case(&url)) {
            continue;
        }
        pending.push(url);
    }
    let views = futures_util::future::join_all(pending.iter().map(|url| async move {
        let bytes = run_gh(gh, None, &["pr", "view", url, "--json", FIELDS]).await?;
        let value: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        pull_request(&value).ok_or_else(|| "gh returned an invalid pull request".to_owned())
    }))
    .await;
    for view in views {
        attempts += 1;
        match view {
            Ok(pr) if !found.iter().any(|known| known.url == pr.url) => found.push(pr),
            Ok(_) => {}
            Err(_) => failures += 1,
        }
    }
    if attempts > 0 && failures == attempts {
        return Err("GitHub could not be reached from your Mac. Try again.".into());
    }
    found.truncate(MAX_PULL_REQUESTS);
    Ok(PullRequestList {
        version: VERSION,
        available: true,
        detail: (failures > 0).then(|| "Some pull requests could not be loaded.".into()),
        pull_requests: found,
    })
}

/// The branch the thread's folder is on, when it is a feature branch whose
/// name is safe to hand to `gh`.
async fn current_branch(cwd: &FsPath) -> Option<String> {
    let bytes = crate::project_assignments::read_only_git_bytes(
        cwd.to_str()?,
        &["symbolic-ref", "--quiet", "--short", "HEAD"],
    )
    .await
    .ok()?;
    let branch = String::from_utf8(bytes).ok()?.trim().to_owned();
    (valid_branch(&branch) && !matches!(branch.as_str(), "main" | "master")).then_some(branch)
}

fn valid_branch(branch: &str) -> bool {
    !branch.is_empty()
        && branch.len() <= 200
        && !branch.starts_with('-')
        && !branch.contains("..")
        && branch
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'/' | b'-'))
}

/// GitHub pull request links in `text`, in order of appearance.
fn pull_request_refs(text: &str) -> Vec<PullRef> {
    const PREFIX: &str = "https://github.com/";
    let mut refs = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find(PREFIX) {
        rest = &rest[start + PREFIX.len()..];
        if let Some(reference) = parse_ref(rest) {
            if !refs.contains(&reference) {
                refs.push(reference);
            }
        }
    }
    refs
}

fn parse_ref(text: &str) -> Option<PullRef> {
    let take = |s: &str, allowed: fn(u8) -> bool, max: usize| -> Option<usize> {
        let len = s.bytes().take_while(|b| allowed(*b)).count();
        (1..=max).contains(&len).then_some(len)
    };
    let owner_len = take(text, |b| b.is_ascii_alphanumeric() || b == b'-', 39)?;
    let owner = &text[..owner_len];
    let text = text[owner_len..].strip_prefix('/')?;
    let repo_len = take(
        text,
        |b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'),
        100,
    )?;
    let repo = &text[..repo_len];
    let text = text[repo_len..].strip_prefix("/pull/")?;
    let digits = take(text, |b| b.is_ascii_digit(), 9)?;
    if owner.starts_with('-') || repo.starts_with('.') {
        return None;
    }
    Some(PullRef {
        owner: owner.to_owned(),
        repo: repo.to_owned(),
        number: text[..digits].parse().ok().filter(|n| *n > 0)?,
    })
}

/// One `gh pr view/list --json` row, or nothing when it is not a github.com
/// pull request with the fields Wonder shows.
fn pull_request(value: &Value) -> Option<PullRequest> {
    let url = value.get("url")?.as_str()?;
    let reference = url
        .strip_prefix("https://github.com/")
        .and_then(parse_ref)?;
    let number = value.get("number")?.as_u64()?;
    if number != reference.number {
        return None;
    }
    let state = match (
        value.get("state")?.as_str()?,
        value.get("isDraft").and_then(Value::as_bool),
    ) {
        ("OPEN", Some(true)) => "draft",
        ("OPEN", _) => "open",
        ("MERGED", _) => "merged",
        ("CLOSED", _) => "closed",
        _ => return None,
    };
    let title: String = value.get("title")?.as_str()?.chars().take(300).collect();
    Some(PullRequest {
        number,
        repository: format!("{}/{}", reference.owner, reference.repo),
        title,
        state,
        checks: checks(value.get("statusCheckRollup")),
        url: reference.url(),
    })
}

/// Counts check runs (status/conclusion) and commit statuses (state).
fn checks(rollup: Option<&Value>) -> CheckSummary {
    let mut summary = CheckSummary::default();
    for check in rollup.and_then(Value::as_array).into_iter().flatten() {
        let field = |name: &str| check.get(name).and_then(Value::as_str).unwrap_or_default();
        let outcome = if check.get("status").is_some() || check.get("conclusion").is_some() {
            if field("status") != "COMPLETED" {
                "pending"
            } else {
                match field("conclusion") {
                    "SUCCESS" | "NEUTRAL" | "SKIPPED" => "passed",
                    _ => "failed",
                }
            }
        } else {
            match field("state") {
                "SUCCESS" => "passed",
                "PENDING" | "EXPECTED" => "pending",
                _ => "failed",
            }
        };
        match outcome {
            "passed" => summary.passed += 1,
            "pending" => summary.pending += 1,
            _ => summary.failed += 1,
        }
    }
    summary.state = if summary.failed > 0 {
        "failing"
    } else if summary.pending > 0 {
        "pending"
    } else if summary.passed > 0 {
        "passing"
    } else {
        "none"
    };
    summary
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Links come from agent replies and tool output, including the line
    // `gh pr create` prints; look-alikes and other GitHub pages are ignored.
    #[test]
    fn pull_request_links_are_found_in_transcript_text() {
        let text = r#"{"aggregatedOutput":"Creating pull request\nhttps://github.com/swaymun/wonder/pull/68\n"} see https://github.com/swaymun/wonder/pull/68#issuecomment-1 and https://github.com/other-org/repo.name/pull/7/files, not https://github.com/swaymun/wonder/issues/3, https://github.com/a/b/pull/0, https://github.com/-x/b/pull/2 or https://github.com.evil/a/b/pull/1"#;
        let refs = pull_request_refs(text);
        assert_eq!(
            refs.iter().map(PullRef::url).collect::<Vec<_>>(),
            [
                "https://github.com/swaymun/wonder/pull/68",
                "https://github.com/other-org/repo.name/pull/7"
            ]
        );
    }

    // The cache spares GitHub for an unchanged thread, but a pull request
    // linked since the last read is fetched at once, and a refresh inside ten
    // seconds is answered from the cache.
    #[test]
    fn cache_follows_the_thread_sources() {
        let sources = Sources {
            branch: Some("agent/x".into()),
            refs: pull_request_refs("https://github.com/o/r/pull/1"),
        };
        let list = unavailable_list();
        store_cached("cache-test", sources.clone(), &list);
        assert_eq!(cached("cache-test", &sources, false), Some(list.clone()));
        assert_eq!(cached("cache-test", &sources, true), Some(list));
        let linked = Sources {
            refs: pull_request_refs("https://github.com/o/r/pull/2 https://github.com/o/r/pull/1"),
            ..sources.clone()
        };
        assert_eq!(cached("cache-test", &linked, false), None);
        assert_eq!(cached("other-thread", &sources, false), None);
    }

    #[test]
    fn only_plain_branch_names_reach_gh() {
        for ok in ["agent/pr-pill", "feature_1.2", "claude/pr-pill-8ebce2"] {
            assert!(valid_branch(ok), "{ok}");
        }
        for bad in ["", "-flag", "a..b", "a b", "a;rm", "名前"] {
            assert!(!valid_branch(bad), "{bad}");
        }
    }

    // Check runs report status and conclusion; commit statuses report state.
    #[test]
    fn check_rollups_summarize_failures_first() {
        let rollup = json!([
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},
            {"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""},
            {"__typename":"StatusContext","state":"PENDING"},
        ]);
        let summary = checks(Some(&rollup));
        assert_eq!(
            (
                summary.state,
                summary.passed,
                summary.pending,
                summary.failed
            ),
            ("pending", 2, 2, 0)
        );
        let failing = json!([{"status":"COMPLETED","conclusion":"FAILURE"},{"state":"SUCCESS"}]);
        assert_eq!(checks(Some(&failing)).state, "failing");
        assert_eq!(checks(Some(&json!([{"state":"SUCCESS"}]))).state, "passing");
        assert_eq!(checks(None).state, "none");
    }

    #[test]
    fn gh_rows_map_to_user_states() {
        let row = |state: &str, draft: bool| {
            json!({"number":5,"title":"Add the pill","state":state,"isDraft":draft,
                   "url":"https://github.com/o/r/pull/5","statusCheckRollup":[]})
        };
        let states: Vec<_> = [
            ("OPEN", false),
            ("OPEN", true),
            ("MERGED", false),
            ("CLOSED", false),
        ]
        .iter()
        .map(|(state, draft)| pull_request(&row(state, *draft)).unwrap().state)
        .collect();
        assert_eq!(states, ["open", "draft", "merged", "closed"]);
        assert!(pull_request(&row("UNKNOWN", false)).is_none());
        let mut mismatched = row("OPEN", false);
        mismatched["number"] = json!(6);
        assert!(
            pull_request(&mismatched).is_none(),
            "number must match the URL"
        );
        let mut enterprise = row("OPEN", false);
        enterprise["url"] = json!("https://github.example.com/o/r/pull/5");
        assert!(pull_request(&enterprise).is_none());
    }

    /// A stand-in `gh` that answers `pr list` for the branch and `pr view` for
    /// one linked pull request, and fails for another.
    fn fake_gh(dir: &FsPath) -> PathBuf {
        let gh = dir.join("gh");
        std::fs::write(
            &gh,
            r#"#!/bin/sh
echo "$@" >> "$(dirname "$0")/calls"
case "$1 $2" in
  "pr list") echo '[{"number":12,"title":"Branch work","state":"OPEN","isDraft":true,"url":"https://github.com/o/r/pull/12","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}]' ;;
  "pr view")
    case "$3" in
      */pull/9) echo '{"number":9,"title":"Linked work","state":"MERGED","isDraft":false,"url":"https://github.com/o/r/pull/9","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}' ;;
      *) echo 'not found' >&2; exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
"#,
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
        gh
    }

    fn repo_on_branch(dir: &FsPath, branch: &str) -> PathBuf {
        let repo = dir.join("repo");
        std::fs::create_dir(&repo).unwrap();
        assert!(std::process::Command::new("git")
            .arg("-C")
            .arg(&repo)
            .args(["init", "-q", "-b", branch])
            .status()
            .unwrap()
            .success());
        repo
    }

    // The branch's pull request comes first, a linked one is read once even
    // when mentioned twice, and a link that fails is reported, not hidden.
    #[tokio::test]
    async fn thread_pull_requests_combine_branch_and_transcript_and_match_the_contract() {
        let dir = tempfile::tempdir().unwrap();
        let gh = fake_gh(dir.path());
        let repo = repo_on_branch(dir.path(), "agent/pr-pill");
        let texts = vec![
            "Opened https://github.com/o/r/pull/9 and https://github.com/o/r/pull/12".to_owned(),
            "https://github.com/o/r/pull/9 again, and https://github.com/o/r/pull/404".to_owned(),
        ];
        let list = collect(&gh, &repo, &texts).await.unwrap();
        let summary: Vec<_> = list
            .pull_requests
            .iter()
            .map(|pr| (pr.number, pr.state, pr.checks.state))
            .collect();
        assert_eq!(
            summary,
            [(12, "draft", "passing"), (9, "merged", "failing")]
        );
        assert_eq!(
            list.detail.as_deref(),
            Some("Some pull requests could not be loaded.")
        );
        let calls = std::fs::read_to_string(dir.path().join("calls")).unwrap();
        assert_eq!(
            calls.lines().filter(|l| l.contains("/pull/9")).count(),
            1,
            "{calls}"
        );
        assert!(
            calls.contains("pr list --head agent/pr-pill --state all"),
            "{calls}"
        );
        crate::tests::validate_http_contract(
            "projectPullRequestList",
            &serde_json::to_value(&list).unwrap(),
        );
        crate::tests::validate_http_contract(
            "projectPullRequestList",
            &serde_json::to_value(unavailable_list()).unwrap(),
        );
        // The shared fixture the app's decoder is tested against.
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../packages/protocol/fixtures/project-pull-requests-v1.json"
        ))
        .unwrap();
        crate::tests::validate_http_contract("projectPullRequestList", &fixture);
    }

    // A default branch is not a thread's own work, and with nothing linked
    // `gh` is not called at all.
    #[tokio::test]
    async fn default_branch_without_links_needs_no_gh_call() {
        let dir = tempfile::tempdir().unwrap();
        let gh = fake_gh(dir.path());
        let repo = repo_on_branch(dir.path(), "main");
        let list = collect(&gh, &repo, &[]).await.unwrap();
        assert!(list.available && list.pull_requests.is_empty() && list.detail.is_none());
        assert!(!dir.path().join("calls").exists());
    }

    #[tokio::test]
    async fn unreachable_github_is_an_error_not_an_empty_list() {
        let dir = tempfile::tempdir().unwrap();
        let gh = fake_gh(dir.path());
        let repo = repo_on_branch(dir.path(), "main");
        let error = collect(&gh, &repo, &["https://github.com/o/r/pull/404".to_owned()])
            .await
            .unwrap_err();
        assert!(error.contains("GitHub could not be reached"));
    }
}
