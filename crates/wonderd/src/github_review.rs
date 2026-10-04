//! Read-only GitHub snapshots for an explicitly authorized Project binding.
//! The caller must validate current host/Project/disk ownership before AND
//! after awaiting this adapter. Tokens, upstream error bodies and arbitrary
//! response URLs never leave this boundary. This grants no command authority.
use reqwest::{
    header::{HeaderValue, AUTHORIZATION},
    Client,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, sync::OnceLock, time::Duration};
use wonder_store::ProjectGitHubReviewBinding;

const RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
const PATCH_BYTES: usize = 1024 * 1024;
const PAGE_SIZE: usize = 100;
const FILE_LIMIT: usize = 3000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReviewError {
    Authentication,
    Access,
    RateLimit,
    Transport,
    Timeout,
    Oversized,
    InvalidResponse,
    ChangedIdentity,
    TooManyFiles,
}

impl ReviewError {
    pub fn detail(self) -> &'static str {
        match self {
            Self::Authentication => "Sign in to the connected GitHub account on your Mac.",
            Self::Access => {
                "This GitHub repository or pull request is unavailable to the connected account."
            }
            Self::RateLimit => "GitHub is limiting requests. Wait before reloading this review.",
            Self::Transport => "GitHub could not be reached. Try again.",
            Self::Timeout => "This GitHub review took too long. Try again.",
            Self::Oversized => "This review exceeds the preview size limit. Open it on GitHub.",
            Self::InvalidResponse => {
                "GitHub returned an incomplete review. Reload or open it on GitHub."
            }
            Self::ChangedIdentity => {
                "The connected account, repository or pull request changed. Reload this review."
            }
            Self::TooManyFiles => {
                "This pull request has too many files for a complete preview. Open it on GitHub."
            }
        }
    }
}

fn client() -> &'static Client {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::none())
            .user_agent("Wonder-GitHub-ReadOnly-Review")
            .build()
            .expect("GitHub client configuration")
    })
}

/// Deliberately has no Debug implementation. Credential discovery/consent is
/// owned by the host integration, not inferred from a folder's Git remote.
pub struct GitHubReviewClient {
    authorization: HeaderValue,
    #[cfg(test)]
    origin: Option<String>,
}

impl GitHubReviewClient {
    pub fn new(token: &str) -> Result<Self, ReviewError> {
        if token.is_empty() || token.len() > 16 * 1024 {
            return Err(ReviewError::Authentication);
        }
        let mut authorization = HeaderValue::from_str(&format!("Bearer {token}"))
            .map_err(|_| ReviewError::Authentication)?;
        authorization.set_sensitive(true);
        Ok(Self {
            authorization,
            #[cfg(test)]
            origin: None,
        })
    }

    async fn read<T: serde::de::DeserializeOwned>(
        &self,
        endpoint: &str,
    ) -> Result<(T, usize), ReviewError> {
        let origin = "https://api.github.com";
        #[cfg(test)]
        let origin = self.origin.as_deref().unwrap_or(origin);
        let mut response = client()
            .get(format!("{origin}/{endpoint}"))
            .header(AUTHORIZATION, self.authorization.clone())
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .send()
            .await
            .map_err(|error| {
                if error.is_timeout() {
                    ReviewError::Timeout
                } else {
                    ReviewError::Transport
                }
            })?;
        match response.status().as_u16() {
            200 => {}
            401 => return Err(ReviewError::Authentication),
            429 => return Err(ReviewError::RateLimit),
            403 if response
                .headers()
                .get("x-ratelimit-remaining")
                .is_some_and(|h| h == "0")
                || response.headers().contains_key("retry-after") =>
            {
                return Err(ReviewError::RateLimit)
            }
            403 | 404 => return Err(ReviewError::Access),
            300..=399 => return Err(ReviewError::ChangedIdentity),
            _ => return Err(ReviewError::Transport),
        }
        if response
            .content_length()
            .is_some_and(|n| n > RESPONSE_BYTES as u64)
        {
            return Err(ReviewError::Oversized);
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|error| {
            if error.is_timeout() {
                ReviewError::Timeout
            } else {
                ReviewError::Transport
            }
        })? {
            if chunk.len() > RESPONSE_BYTES - bytes.len() {
                return Err(ReviewError::Oversized);
            }
            bytes.extend_from_slice(&chunk);
        }
        let size = bytes.len();
        serde_json::from_slice(&bytes)
            .map(|value| (value, size))
            .map_err(|_| ReviewError::InvalidResponse)
    }

    /// Full snapshot only; any pagination/revision failure returns an error,
    /// never an apparently complete empty or partial file list.
    pub async fn snapshot(
        &self,
        binding: &ProjectGitHubReviewBinding,
        number: u64,
    ) -> Result<PullRequestSnapshot, ReviewError> {
        tokio::time::timeout(Duration::from_secs(45), self.collect(binding, number))
            .await
            .map_err(|_| ReviewError::Timeout)?
    }

    async fn collect(
        &self,
        binding: &ProjectGitHubReviewBinding,
        number: u64,
    ) -> Result<PullRequestSnapshot, ReviewError> {
        validate_binding(binding, number)?;
        self.verify_account(binding.account_id).await?;
        let prefix = format!("repos/{}", binding.repository);
        let (repository, _) = self.read::<Repository>(&prefix).await?;
        if repository.id != binding.repository_id || repository.full_name != binding.repository {
            return Err(ReviewError::ChangedIdentity);
        }
        let endpoint = format!("{prefix}/pulls/{number}");
        let (before, _) = self.read::<PullMetadata>(&endpoint).await?;
        let identity = before.identity(binding, number)?;
        if before.changed_files > FILE_LIMIT {
            return Err(ReviewError::TooManyFiles);
        }
        let mut files = Vec::new();
        let mut seen = HashSet::new();
        let mut aggregate = 0;
        for page in 1..=FILE_LIMIT / PAGE_SIZE {
            if files.len() == before.changed_files {
                break;
            }
            let (batch, bytes) = self
                .read::<Vec<UpstreamFile>>(&format!(
                    "{endpoint}/files?per_page={PAGE_SIZE}&page={page}"
                ))
                .await?;
            aggregate += bytes;
            if aggregate > SNAPSHOT_BYTES {
                return Err(ReviewError::Oversized);
            }
            if batch.len() > PAGE_SIZE {
                return Err(ReviewError::InvalidResponse);
            }
            let short = batch.len() < PAGE_SIZE;
            for item in batch {
                if !seen.insert(item.filename.clone()) {
                    return Err(ReviewError::InvalidResponse);
                }
                files.push(item.into_preview()?);
            }
            if files.len() > before.changed_files {
                return Err(ReviewError::InvalidResponse);
            }
            if short {
                break;
            }
        }
        if files.len() != before.changed_files {
            return Err(ReviewError::InvalidResponse);
        }
        // Pinned comparison is used only for merge-base identity, not its
        // separately truncated files list or credential-bearing response URLs.
        let (comparison, _) = self
            .read::<Comparison>(&format!(
                "{prefix}/compare/{}...{}?per_page=1",
                identity.base, identity.head
            ))
            .await?;
        if !valid_sha(&comparison.merge_base_commit.sha) {
            return Err(ReviewError::InvalidResponse);
        }
        let (after, _) = self.read::<PullMetadata>(&endpoint).await?;
        if after.identity(binding, number)? != identity
            || after.changed_files != before.changed_files
        {
            return Err(ReviewError::ChangedIdentity);
        }
        self.verify_account(binding.account_id).await?;
        Ok(PullRequestSnapshot {
            project_id: binding.project_id.clone(),
            root_id: binding.root_id.clone(),
            roots_revision: binding.roots_revision,
            account_id: binding.account_id,
            identity,
            merge_base: comparison.merge_base_commit.sha,
            title: bounded_text(&after.title, 1024)?,
            state: after.state,
            fetched_at: chrono::Utc::now().to_rfc3339(),
            enumeration_complete: true,
            files,
        })
    }

    async fn verify_account(&self, expected: i64) -> Result<(), ReviewError> {
        let (account, _) = self.read::<Account>("user").await?;
        if account.id != expected {
            return Err(ReviewError::ChangedIdentity);
        }
        Ok(())
    }
}

fn validate_binding(binding: &ProjectGitHubReviewBinding, number: u64) -> Result<(), ReviewError> {
    if number == 0
        || binding.account_id <= 0
        || binding.repository_id <= 0
        || binding.roots_revision <= 0
        || binding.project_id.is_empty()
        || binding.root_id.is_empty()
        || !valid_repository(&binding.repository)
    {
        return Err(ReviewError::InvalidResponse);
    }
    Ok(())
}

fn valid_repository(value: &str) -> bool {
    let Some((owner, name)) = value.split_once('/') else {
        return false;
    };
    !owner.is_empty()
        && owner.len() <= 100
        && owner
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        && !name.is_empty()
        && name.len() <= 100
        && name != "."
        && name != ".."
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
}
fn valid_sha(value: &str) -> bool {
    value.len() == 40
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn valid_path(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 4096
        && !value.contains('\\')
        && !value.chars().any(char::is_control)
        && value
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}
fn bounded_text(value: &str, limit: usize) -> Result<String, ReviewError> {
    if value.len() > limit || value.chars().any(char::is_control) {
        return Err(ReviewError::InvalidResponse);
    }
    Ok(value.to_owned())
}

#[derive(Deserialize)]
struct Account {
    id: i64,
}
#[derive(Clone, Deserialize, Eq, PartialEq)]
struct Repository {
    id: i64,
    full_name: String,
}
#[derive(Deserialize)]
struct Revision {
    sha: String,
    repo: Option<Repository>,
}
#[derive(Deserialize)]
struct PullMetadata {
    number: u64,
    base: Revision,
    head: Revision,
    changed_files: usize,
    title: String,
    state: String,
}
impl PullMetadata {
    fn identity(
        &self,
        binding: &ProjectGitHubReviewBinding,
        number: u64,
    ) -> Result<PullRequestIdentity, ReviewError> {
        let base = self
            .base
            .repo
            .as_ref()
            .ok_or(ReviewError::InvalidResponse)?;
        let head = self
            .head
            .repo
            .as_ref()
            .ok_or(ReviewError::InvalidResponse)?;
        if self.number != number
            || base.id != binding.repository_id
            || base.full_name != binding.repository
            || head.id <= 0
            || !valid_repository(&head.full_name)
            || !valid_sha(&self.base.sha)
            || !valid_sha(&self.head.sha)
            || !matches!(self.state.as_str(), "open" | "closed")
        {
            return Err(ReviewError::ChangedIdentity);
        }
        Ok(PullRequestIdentity {
            api_host: "api.github.com".into(),
            repository_id: base.id,
            repository: base.full_name.clone(),
            head_repository_id: head.id,
            head_repository: head.full_name.clone(),
            number,
            base: self.base.sha.clone(),
            head: self.head.sha.clone(),
        })
    }
}
#[derive(Deserialize)]
struct Comparison {
    merge_base_commit: Commit,
}
#[derive(Deserialize)]
struct Commit {
    sha: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestIdentity {
    pub api_host: String,
    pub repository_id: i64,
    pub repository: String,
    pub head_repository_id: i64,
    pub head_repository: String,
    pub number: u64,
    pub base: String,
    pub head: String,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestSnapshot {
    pub project_id: String,
    pub root_id: String,
    pub roots_revision: i64,
    pub account_id: i64,
    pub identity: PullRequestIdentity,
    pub merge_base: String,
    pub title: String,
    pub state: String,
    pub fetched_at: String,
    pub enumeration_complete: bool,
    pub files: Vec<ReviewFile>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PatchState {
    SuppliedCountsMatch,
    Empty,
    Unavailable,
    Partial,
    Oversized,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewFile {
    pub path: String,
    pub previous_path: Option<String>,
    pub sha: String,
    pub status: String,
    pub additions: u64,
    pub deletions: u64,
    pub patch_state: PatchState,
    pub patch: Option<String>,
}
#[derive(Deserialize)]
struct UpstreamFile {
    filename: String,
    previous_filename: Option<String>,
    sha: String,
    status: String,
    additions: u64,
    deletions: u64,
    patch: Option<String>,
}
impl UpstreamFile {
    fn into_preview(self) -> Result<ReviewFile, ReviewError> {
        if !valid_path(&self.filename)
            || self
                .previous_filename
                .as_deref()
                .is_some_and(|p| !valid_path(p))
            || !valid_sha(&self.sha)
            || !matches!(
                self.status.as_str(),
                "added" | "removed" | "modified" | "renamed" | "copied" | "changed" | "unchanged"
            )
            || (matches!(self.status.as_str(), "renamed" | "copied")
                && self.previous_filename.is_none())
        {
            return Err(ReviewError::InvalidResponse);
        }
        let state = patch_state(self.patch.as_deref(), self.additions, self.deletions);
        let patch = if matches!(state, PatchState::SuppliedCountsMatch | PatchState::Empty) {
            self.patch
        } else {
            None
        };
        Ok(ReviewFile {
            path: self.filename,
            previous_path: self.previous_filename,
            sha: self.sha,
            status: self.status,
            additions: self.additions,
            deletions: self.deletions,
            patch_state: state,
            patch,
        })
    }
}

fn range(value: &str) -> Option<(u64, u64)> {
    let (start, count) = value.split_once(',').unwrap_or((value, "1"));
    if start.is_empty()
        || count.is_empty()
        || !start
            .bytes()
            .chain(count.bytes())
            .all(|c| c.is_ascii_digit())
    {
        return None;
    }
    Some((start.parse().ok()?, count.parse().ok()?))
}
fn hunk(line: &str) -> Option<[(u64, u64); 2]> {
    let line = line.strip_prefix("@@ -")?;
    let (old, new) = line.split_once(" +")?;
    let (new, _) = new.split_once(" @@")?;
    Some([range(old)?, range(new)?])
}
fn patch_state(patch: Option<&str>, additions: u64, deletions: u64) -> PatchState {
    let Some(patch) = patch else {
        return PatchState::Unavailable;
    };
    if patch.len() > PATCH_BYTES {
        return PatchState::Oversized;
    }
    if patch.is_empty() {
        return if additions == 0 && deletions == 0 {
            PatchState::Empty
        } else {
            PatchState::Partial
        };
    }
    let mut expected = None;
    let mut consumed = [0u64; 2];
    let mut actual = [0u64; 2];
    let mut ends = [0u64; 2];
    for line in patch.lines() {
        if let Some(ranges) = hunk(line) {
            if expected.is_some_and(|value| consumed != value) {
                return PatchState::Partial;
            }
            for (i, (start, count)) in ranges.into_iter().enumerate() {
                if start < ends[i] || (count > 0 && start == 0) {
                    return PatchState::Partial;
                }
                let Some(end) = start.checked_add(count) else {
                    return PatchState::Partial;
                };
                ends[i] = end;
            }
            expected = Some([ranges[0].1, ranges[1].1]);
            consumed = [0, 0];
        } else if expected.is_none() {
            return PatchState::Partial;
        } else if line.starts_with(' ') {
            consumed[0] += 1;
            consumed[1] += 1;
        } else if line.starts_with('-') {
            consumed[0] += 1;
            actual[1] += 1;
        } else if line.starts_with('+') {
            consumed[1] += 1;
            actual[0] += 1;
        } else if line != "\\ No newline at end of file" {
            return PatchState::Partial;
        }
    }
    if expected == Some(consumed) && actual == [additions, deletions] {
        PatchState::SuppliedCountsMatch
    } else {
        PatchState::Partial
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        extract::State,
        http::{Request, StatusCode},
        response::{IntoResponse, Response},
        routing::any,
        Json, Router,
    };
    use serde_json::{json, Value};
    use std::sync::{Arc, Mutex};

    fn binding() -> ProjectGitHubReviewBinding {
        ProjectGitHubReviewBinding {
            project_id: "project".into(),
            root_id: "root".into(),
            roots_revision: 1,
            account_id: 42,
            repository_id: 123,
            repository: "owner/repo".into(),
            authorized_at: "now".into(),
        }
    }
    fn metadata(count: usize) -> Value {
        json!({"number":7,"base":{"sha":"a".repeat(40),"repo":{"id":123,"full_name":"owner/repo"}},
            "head":{"sha":"b".repeat(40),"repo":{"id":456,"full_name":"fork/repo"}},
            "changed_files":count,"title":"Review a change","state":"open"})
    }
    fn file(index: usize) -> Value {
        json!({"filename":format!("src/{index}.txt"),"sha":"c".repeat(40),"status":"modified","additions":1,"deletions":1,
            "patch":"@@ -1 +1 @@\n-old\n+new"})
    }
    struct Fixture {
        before: Value,
        after: Value,
        pages: Vec<Vec<Value>>,
        account: i64,
        account_after: i64,
        repository: Value,
        requests: Vec<String>,
        metadata_reads: usize,
        account_reads: usize,
        response: Option<u16>,
    }
    impl Fixture {
        fn new(count: usize) -> Self {
            Self {
                before: metadata(count),
                after: metadata(count),
                pages: (0..count)
                    .map(file)
                    .collect::<Vec<_>>()
                    .chunks(100)
                    .map(|p| p.to_vec())
                    .collect(),
                account: 42,
                account_after: 42,
                repository: json!({"id":123,"full_name":"owner/repo"}),
                requests: Vec::new(),
                metadata_reads: 0,
                account_reads: 0,
                response: None,
            }
        }
    }
    struct Server {
        client: GitHubReviewClient,
        fixture: Arc<Mutex<Fixture>>,
        task: tokio::task::JoinHandle<()>,
    }
    impl Drop for Server {
        fn drop(&mut self) {
            self.task.abort();
        }
    }
    async fn server(fixture: Fixture) -> Server {
        let fixture = Arc::new(Mutex::new(fixture));
        let app = Router::new()
            .fallback(any(serve))
            .with_state(fixture.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let mut client = GitHubReviewClient::new("inert-test-token").unwrap();
        client.origin = Some(origin);
        Server {
            client,
            fixture,
            task,
        }
    }
    async fn serve(State(fixture): State<Arc<Mutex<Fixture>>>, request: Request<Body>) -> Response {
        assert_eq!(request.method(), "GET");
        assert_eq!(
            request.headers()["authorization"],
            "Bearer inert-test-token"
        );
        assert_eq!(request.headers()["x-github-api-version"], "2022-11-28");
        let path = request.uri().path_and_query().unwrap().as_str();
        let mut fixture = fixture.lock().unwrap();
        fixture.requests.push(path.into());
        if let Some(status) = fixture.response {
            if status == 302 {
                return (StatusCode::FOUND, [("location", "/credential-trap")]).into_response();
            }
            if status == 413 {
                let chunks = (0..513).map(|_| Ok::<_, std::io::Error>("x".repeat(8192)));
                return Response::new(Body::from_stream(futures_util::stream::iter(chunks)));
            }
            let mut response = (
                StatusCode::from_u16(status).unwrap(),
                "private upstream error body",
            )
                .into_response();
            if status == 429 {
                response
                    .headers_mut()
                    .insert("retry-after", HeaderValue::from_static("30"));
            }
            return response;
        }
        let value = if path == "/user" {
            fixture.account_reads += 1;
            json!({"id":if fixture.account_reads == 1 {fixture.account} else {fixture.account_after}})
        } else if path == "/repos/owner/repo" {
            fixture.repository.clone()
        } else if path == "/repos/owner/repo/pulls/7" {
            fixture.metadata_reads += 1;
            if fixture.metadata_reads == 1 {
                fixture.before.clone()
            } else {
                fixture.after.clone()
            }
        } else if let Some(page) =
            path.strip_prefix("/repos/owner/repo/pulls/7/files?per_page=100&page=")
        {
            let page: usize = page.parse().unwrap();
            json!(fixture.pages.get(page - 1).cloned().unwrap_or_default())
        } else if path
            == format!(
                "/repos/owner/repo/compare/{}...{}?per_page=1",
                "a".repeat(40),
                "b".repeat(40)
            )
        {
            // Malicious links and unrelated comparison file data are ignored.
            json!({"merge_base_commit":{"sha":"d".repeat(40)},"url":"https://untrusted.invalid/credentials","files":[{"filename":"wrong.txt"}]})
        } else {
            panic!("Unexpected read endpoint")
        };
        Json(value).into_response()
    }

    // Contract: complete PR enumeration and immutable identity are assembled
    // from real HTTP pages, not the compare endpoint's smaller file list.
    #[tokio::test]
    async fn paginated_http_snapshot_keeps_fork_revision_and_patch_availability() {
        let mut fixture = Fixture::new(101);
        fixture.pages[0][0].as_object_mut().unwrap().remove("patch");
        fixture.pages[0][1] = json!({"filename":"new.txt","previous_filename":"old.txt","sha":"c".repeat(40),"status":"renamed","additions":0,"deletions":0,"patch":""});
        let server = server(fixture).await;
        let snapshot = server.client.snapshot(&binding(), 7).await.unwrap();
        assert_eq!(snapshot.files.len(), 101);
        assert!(snapshot.enumeration_complete);
        assert_eq!(snapshot.files[0].patch_state, PatchState::Unavailable);
        assert!(snapshot.files[0].patch.is_none());
        assert_eq!(snapshot.files[1].patch_state, PatchState::Empty);
        assert_eq!(snapshot.files[1].previous_path.as_deref(), Some("old.txt"));
        assert_eq!(snapshot.identity.head_repository_id, 456);
        assert_eq!(snapshot.identity.head_repository, "fork/repo");
        assert_eq!(snapshot.merge_base, "d".repeat(40));
        assert_ne!(snapshot.identity.base, snapshot.merge_base);
        assert_eq!(
            snapshot.files[100].patch_state,
            PatchState::SuppliedCountsMatch
        );
        let fixture = server.fixture.lock().unwrap();
        assert_eq!(fixture.requests.len(), 8);
        assert_eq!(fixture.account_reads, 2);
        assert!(fixture
            .requests
            .iter()
            .any(|p| p.ends_with("per_page=100&page=2")));
    }

    #[tokio::test]
    async fn changed_or_incomplete_http_snapshots_never_return_complete_files() {
        for case in [
            "base",
            "head",
            "fork",
            "count",
            "duplicate",
            "short",
            "account",
            "account-after",
            "repository",
            "limit",
        ] {
            let mut fixture = Fixture::new(101);
            let expected = match case {
                "base" => {
                    fixture.after["base"]["sha"] = json!("e".repeat(40));
                    ReviewError::ChangedIdentity
                }
                "head" => {
                    fixture.after["head"]["sha"] = json!("e".repeat(40));
                    ReviewError::ChangedIdentity
                }
                "fork" => {
                    fixture.after["head"]["repo"]["id"] = json!(789);
                    ReviewError::ChangedIdentity
                }
                "count" => {
                    fixture.after["changed_files"] = json!(102);
                    ReviewError::ChangedIdentity
                }
                "duplicate" => {
                    fixture.pages[1][0] = fixture.pages[0][0].clone();
                    ReviewError::InvalidResponse
                }
                "short" => {
                    fixture.pages[0].pop();
                    ReviewError::InvalidResponse
                }
                "account" => {
                    fixture.account = 99;
                    ReviewError::ChangedIdentity
                }
                "account-after" => {
                    fixture.account_after = 99;
                    ReviewError::ChangedIdentity
                }
                "repository" => {
                    fixture.repository["id"] = json!(999);
                    ReviewError::ChangedIdentity
                }
                "limit" => {
                    fixture.before["changed_files"] = json!(3001);
                    ReviewError::TooManyFiles
                }
                _ => unreachable!(),
            };
            let server = server(fixture).await;
            assert_eq!(
                server.client.snapshot(&binding(), 7).await.unwrap_err(),
                expected,
                "{case}"
            );
            if matches!(case, "account" | "repository") {
                assert!(!server
                    .fixture
                    .lock()
                    .unwrap()
                    .requests
                    .iter()
                    .any(|p| p.contains("/pulls/")));
            }
        }
    }

    #[tokio::test]
    async fn http_errors_redirects_and_streamed_bytes_are_bounded() {
        for (status, expected) in [
            (401, ReviewError::Authentication),
            (403, ReviewError::Access),
            (404, ReviewError::Access),
            (429, ReviewError::RateLimit),
            (302, ReviewError::ChangedIdentity),
            (413, ReviewError::Oversized),
        ] {
            let mut fixture = Fixture::new(1);
            fixture.response = Some(status);
            let server = server(fixture).await;
            assert_eq!(
                server.client.snapshot(&binding(), 7).await.unwrap_err(),
                expected
            );
            assert_eq!(server.fixture.lock().unwrap().requests.len(), 1);
            assert!(!expected.detail().contains("private upstream"));
        }
    }

    #[tokio::test]
    async fn aggregate_page_bytes_are_bounded_even_when_each_response_fits() {
        let mut fixture = Fixture::new(300);
        for page in &mut fixture.pages {
            for file in page.iter_mut() {
                file["ignored_upstream_field"] = json!("x".repeat(32 * 1024));
            }
            assert!(serde_json::to_vec(page).unwrap().len() < RESPONSE_BYTES);
        }
        let server = server(fixture).await;
        assert_eq!(
            server.client.snapshot(&binding(), 7).await.unwrap_err(),
            ReviewError::Oversized
        );
        let fixture = server.fixture.lock().unwrap();
        assert_eq!(
            fixture
                .requests
                .iter()
                .filter(|p| p.contains("/files?"))
                .count(),
            3
        );
        assert!(!fixture.requests.iter().any(|p| p.contains("/compare/")));
    }

    #[test]
    fn patch_contract_preserves_unavailable_partial_empty_and_rename_provenance() {
        for (patch, adds, deletes, expected) in [
            (None, 1, 1, PatchState::Unavailable),
            (Some(""), 0, 0, PatchState::Empty),
            (Some(""), 1, 0, PatchState::Partial),
            (
                Some("@@ -1 +1 @@\n-old\n+new"),
                1,
                1,
                PatchState::SuppliedCountsMatch,
            ),
            (
                Some("@@ -1,2 +1,2 @@\n-old\n+new"),
                1,
                1,
                PatchState::Partial,
            ),
            (
                Some("@@ -1 +1 @@\n-old\n+new\n@@ -1 +1 @@\n-old\n+new"),
                2,
                2,
                PatchState::Partial,
            ),
            (
                Some("@@ -2 +2 @@\n-old\n+new\n@@ -1 +1 @@\n-old\n+new"),
                2,
                2,
                PatchState::Partial,
            ),
            (
                Some("@@ -0,0 +1 @@\n+new\n\\ No newline at end of file"),
                1,
                0,
                PatchState::SuppliedCountsMatch,
            ),
            (
                Some("@@ -18446744073709551615,2 +1 @@\n-old\n+new"),
                1,
                1,
                PatchState::Partial,
            ),
        ] {
            assert_eq!(patch_state(patch, adds, deletes), expected);
        }
        assert_eq!(
            patch_state(Some(&"x".repeat(PATCH_BYTES + 1)), 0, 0),
            PatchState::Oversized
        );
        for (key, value) in [
            ("filename", "../secret"),
            ("previous_filename", "a/../../secret"),
            ("sha", "invalid"),
            ("status", "unknown"),
        ] {
            let mut raw = file(1);
            raw[key] = json!(value);
            assert!(serde_json::from_value::<UpstreamFile>(raw)
                .unwrap()
                .into_preview()
                .is_err());
        }
        let mut raw = file(1);
        raw["status"] = json!("renamed");
        assert!(serde_json::from_value::<UpstreamFile>(raw)
            .unwrap()
            .into_preview()
            .is_err());
        let mut raw = file(1);
        raw["patch"] = json!("truncated");
        let preview = serde_json::from_value::<UpstreamFile>(raw)
            .unwrap()
            .into_preview()
            .unwrap();
        assert_eq!(preview.patch_state, PatchState::Partial);
        assert!(preview.patch.is_none());
    }
}
