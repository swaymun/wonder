use reqwest::{blocking::Client, redirect::Policy, Url};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fs, io::Write, path::PathBuf, time::Duration};

#[derive(Clone)]
pub struct Connection {
    pub origin: Url,
    capability: String,
    http: Client,
}
impl Connection {
    pub fn from_environment() -> Result<Self, String> {
        let address = std::env::var("WONDER_LISTEN_ADDR").unwrap_or("127.0.0.1:3777".into());
        let origin = Url::parse(&format!("http://{address}")).map_err(|_| "Invalid Mac address")?;
        if origin.host_str() != Some("127.0.0.1")
            || origin.path() != "/"
            || origin.query().is_some()
            || origin.fragment().is_some()
            || !origin.username().is_empty()
            || origin.password().is_some()
        {
            return Err("Desktop host connection must use local loopback".into());
        }
        let capability = std::env::var("WONDER_LOOPBACK_CAPABILITY")
            .map_err(|_| "Open Chats from Wonder on your Mac")?;
        if capability.is_empty() {
            return Err("Open Chats from Wonder on your Mac".into());
        }
        let http = Client::builder()
            .no_proxy()
            .redirect(Policy::none())
            .timeout(Duration::from_secs(8))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self {
            origin,
            capability,
            http,
        })
    }
    fn url(&self, parts: &[&str]) -> Url {
        let mut url = self.origin.clone();
        {
            let mut segments = url.path_segments_mut().expect("HTTP base URL");
            segments.clear().extend(parts);
        }
        url
    }
    pub fn get(&self, parts: &[&str]) -> Result<Value, String> {
        self.get_url(self.url(parts))
    }
    pub fn apps(&self, cursor: Option<&str>, refresh: bool) -> Result<Value, String> {
        let mut url = self.url(&["api", "v1", "connected-apps"]);
        url.query_pairs_mut().append_pair(
            "refresh",
            if refresh && cursor.is_none() {
                "true"
            } else {
                "false"
            },
        );
        if let Some(cursor) = cursor {
            url.query_pairs_mut().append_pair("cursor", cursor);
        }
        self.get_url(url)
    }
    fn get_url(&self, url: Url) -> Result<Value, String> {
        let response = self
            .http
            .get(url)
            .header("x-wonder-loopback-capability", &self.capability)
            .send()
            .map_err(|_| "Mac unavailable. Your draft is saved.")?;
        if !response.status().is_success() {
            return Err("Couldn’t load this conversation. Check Wonder on your Mac.".into());
        }
        response
            .json()
            .map_err(|_| "The Mac returned an unreadable response".into())
    }
    pub fn request(
        &self,
        method: &str,
        parts: &[String],
        body: &Value,
        host: &str,
    ) -> Result<Value, String> {
        if self.get(&["api", "v1", "host", "status"])?["hostInstallationId"] != host {
            return Err("Mac identity changed. Reopen Chats from Wonder.".into());
        }
        let method =
            reqwest::Method::from_bytes(method.as_bytes()).map_err(|_| "Invalid action")?;
        let deleting = method == reqwest::Method::DELETE;
        let response = self.http.request(method, self.url(&parts.iter().map(String::as_str).collect::<Vec<_>>()))
            .header("x-wonder-loopback-capability", &self.capability).json(body).send()
            .map_err(|_| "The Mac did not confirm this change. Check the saved request to try the same action again.")?;
        let status = response.status();
        if deleting && status.as_u16() == 404 {
            return Ok(Value::Null);
        }
        if !status.is_success() {
            let message = response.text().unwrap_or_default();
            let message = if message.len() <= 500 && !message.trim().is_empty() {
                message
            } else {
                format!(
                    "The Mac could not complete this change ({}).",
                    status.as_u16()
                )
            };
            return Err(if status.is_client_error() && status.as_u16() != 408 {
                format!("Rejected: {message}")
            } else {
                message
            });
        }
        let bytes = response
            .bytes()
            .map_err(|_| "The change was not confirmed. Check the saved request.")?;
        if bytes.is_empty() {
            Ok(Value::Null)
        } else {
            serde_json::from_slice(&bytes)
                .map_err(|_| "The change was not confirmed. Check the saved request.".into())
        }
    }
    pub fn download_file(
        &self,
        chat: &str,
        file: &PreviewFile,
        host: &str,
    ) -> Result<Vec<u8>, String> {
        use std::io::Read;
        if !file.supported() {
            return Err("Preview is unavailable for this file type or size.".into());
        }
        if self.get(&["api", "v1", "host", "status"])?["hostInstallationId"] != host {
            return Err("Mac identity changed. Reopen Chats from Wonder.".into());
        }
        let response = self
            .http
            .get(self.url(&["api", "v1", "conversations", chat, "files", &file.id]))
            .header("x-wonder-loopback-capability", &self.capability)
            .send()
            .map_err(|_| "File unavailable. Try again.")?;
        if !response.status().is_success() {
            return Err("This file changed or is no longer available. Refresh the chat.".into());
        }
        let mime = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .split(';')
            .next()
            .unwrap_or("")
            .trim();
        if Some(mime) != file.mime_type.as_deref() {
            return Err("File type did not match its preview.".into());
        }
        let mut bytes = vec![];
        response
            .take(file.byte_size.unwrap_or(0) + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "File download did not finish")?;
        if !file.matches(&bytes) {
            return Err("File contents changed. Refresh the chat before opening it.".into());
        }
        Ok(bytes)
    }
    pub fn answer(
        &self,
        chat: &str,
        question: &str,
        body: &Value,
        host: &str,
    ) -> Result<(), String> {
        if self.get(&["api", "v1", "host", "status"])?["hostInstallationId"] != host {
            return Err("Mac identity changed. Reopen Chats from Wonder.".into());
        }
        let response = self
            .http
            .post(self.url(&["api", "v1", "conversations", chat, "questions", question]))
            .header("x-wonder-loopback-capability", &self.capability)
            .json(body)
            .send()
            .map_err(|_| "Reply not confirmed. Check the saved reply to retry the same answer.")?;
        if !response.status().is_success() {
            return Err(if response.status().as_u16() == 409 {
                "This question expired or was answered elsewhere. Your answer is saved."
            } else {
                "Reply not confirmed. Your answer is saved; check the saved reply."
            }
            .into());
        }
        Ok(())
    }
    pub fn send(
        &self,
        chat: &str,
        group: Option<&str>,
        pending: &Pending,
        host: &str,
    ) -> Result<(), String> {
        if self.get(&["api", "v1", "host", "status"])?["hostInstallationId"] != host {
            return Err("Mac identity changed. Close Chats and reopen it from Wonder.".into());
        }
        let route = match group {
            Some(group) => self.url(&["api", "v1", "channels", group, "messages"]),
            None => self.url(&["api", "v1", "conversations", chat, "messages"]),
        };
        let response = self.http.post(route)
            .header("x-wonder-loopback-capability", &self.capability)
            .json(&serde_json::json!({"deviceId":"wonder-desktop","clientMessageId":pending.id,"body":pending.body,"attachmentIds":pending.attachment_ids}))
            .send().map_err(|_| "Delivery unconfirmed. Check delivery to reuse the saved message identity.")?;
        if !response.status().is_success() {
            return Err(format!(
                "Message not confirmed ({}). Your message is saved.",
                response.status().as_u16()
            ));
        }
        let receipt: Value = response
            .json()
            .map_err(|_| "Delivery unconfirmed. Your message is saved.")?;
        if !valid_receipt(&receipt, chat, pending) {
            return Err("Delivery receipt did not match. Your message is saved.".into());
        }
        Ok(())
    }
}
fn valid_receipt(receipt: &Value, chat: &str, pending: &Pending) -> bool {
    let digest = Sha256::digest(pending.body.as_bytes())
        .iter()
        .map(|v| format!("{v:02x}"))
        .collect::<String>();
    receipt["clientMessageId"] == pending.id
        && receipt["conversationId"] == chat
        && receipt["bodySha256"] == digest
        && receipt["wonderMessageId"]
            .as_str()
            .is_some_and(|v| !v.is_empty())
}
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviewFile {
    pub id: String,
    pub name: String,
    pub mime_type: Option<String>,
    pub byte_size: Option<u64>,
    pub sha256: Option<String>,
    pub state: String,
}
impl PreviewFile {
    pub fn supported(&self) -> bool {
        self.state == "available"
            && self
                .byte_size
                .is_some_and(|size| size > 0 && size <= 8 * 1024 * 1024)
            && self
                .sha256
                .as_ref()
                .is_some_and(|hash| hash.len() == 64 && hash.bytes().all(|c| c.is_ascii_hexdigit()))
            && matches!(
                self.mime_type.as_deref(),
                Some(
                    "image/png"
                        | "image/jpeg"
                        | "image/gif"
                        | "image/webp"
                        | "text/plain"
                        | "text/markdown"
                )
            )
    }
    fn matches(&self, bytes: &[u8]) -> bool {
        let hash = Sha256::digest(bytes)
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>();
        self.byte_size == Some(bytes.len() as u64) && self.sha256.as_deref() == Some(hash.as_str())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StagedFile {
    pub upload_id: String,
    pub name: String,
    pub mime_type: String,
    pub byte_size: usize,
    pub sha256: String,
    pub file_id: Option<String>,
    pub error: Option<String>,
}
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Draft {
    #[serde(default)]
    pub attachments: Vec<StagedFile>,
    pub text: String,
    pub pending: Option<Pending>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Pending {
    #[serde(default)]
    pub attachment_ids: Vec<String>,
    pub id: String,
    pub body: String,
}
#[derive(Default, Serialize, Deserialize)]
pub struct Saved {
    pub chats: BTreeMap<String, Draft>,
    #[serde(default)]
    pub answers: BTreeMap<String, AnswerDraft>,
}
#[derive(Default, Serialize, Deserialize)]
pub struct AnswerDraft {
    pub values: Vec<String>,
    pub pending: Option<Value>,
}
pub struct Disk {
    path: PathBuf,
    _lock: Option<fs::File>,
}
impl Disk {
    pub fn new() -> Result<Self, String> {
        let root = std::env::var_os("WONDER_DESKTOP_DATA_DIR")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|root| PathBuf::from(root).join(".wonder-desktop"))
            })
            .ok_or("Desktop data folder unavailable")?;
        fs::create_dir_all(&root).map_err(|_| "Couldn’t create the draft folder")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
                .map_err(|_| "Couldn’t protect the draft folder")?;
        }
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(root.join("instance.lock"))
            .map_err(|_| "Couldn’t open the draft lock")?;
        lock.try_lock()
            .map_err(|_| "Wonder Chats is already open")?;
        Ok(Self {
            path: root.join("drafts.json"),
            _lock: Some(lock),
        })
    }
    pub fn attachment_root(&self) -> PathBuf {
        self.path.with_file_name("attachments")
    }
    pub fn management_path(&self) -> PathBuf {
        self.path.with_file_name("management-request.json")
    }
    pub fn load(&self) -> Result<Saved, String> {
        match fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|_| "Saved drafts could not be read. They have been preserved.".into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Saved::default()),
            Err(_) => Err("Saved drafts could not be read".into()),
        }
    }
    pub fn save(&self, value: &Saved) -> Result<(), String> {
        let temporary = self.path.with_extension("tmp");
        let bytes = serde_json::to_vec(value).map_err(|e| e.to_string())?;
        let mut options = fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temporary)
            .map_err(|_| "Your draft could not be saved")?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| "Your draft could not be saved")?;
        fs::rename(&temporary, &self.path).map_err(|_| "Your draft could not be saved".into())
    }
}

#[derive(Clone)]
pub struct Chat {
    pub id: String,
    pub title: String,
    pub preview: String,
    pub can_send: bool,
    pub attachments_supported: bool,
    pub group: Option<String>,
    pub bot_id: Option<String>,
    pub avatar_color: Option<String>,
    pub avatar_shape: Option<String>,
    pub avatar_palette: Option<String>,
}
pub fn chats(value: Value, groups: &Value, bots: &Value) -> Vec<Chat> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| {
            let group = groups
                .as_array()
                .into_iter()
                .flatten()
                .find(|group| group["conversationId"] == v["conversationId"]);
            let bot = bots
                .as_array()
                .into_iter()
                .flatten()
                .find(|b| b["id"] == v["botId"]);
            if bot.is_some_and(|b| b["isArchived"] == true) && group.is_none() {
                return None;
            }
            Some(Chat {
                avatar_color: bot
                    .and_then(|b| b["avatarColor"].as_str())
                    .map(str::to_owned),
                avatar_shape: bot
                    .and_then(|b| b["avatarShape"].as_str())
                    .map(str::to_owned),
                avatar_palette: bot
                    .and_then(|b| b["avatarPalette"].as_str())
                    .map(str::to_owned),
                id: v["conversationId"].as_str()?.into(),
                title: group
                    .and_then(|g| g["name"].as_str())
                    .or_else(|| bot.and_then(|b| b["name"].as_str()))
                    .or_else(|| v["title"].as_str())
                    .unwrap_or("Chat")
                    .into(),
                preview: v["lastMessagePreview"].as_str().unwrap_or("").into(),
                attachments_supported: group
                    .map(|g| g["attachmentsSupported"] == true)
                    .unwrap_or(true),
                can_send: group
                    .map(|g| g["isArchived"] == false)
                    .unwrap_or_else(|| v["botId"].is_string()),
                group: group.and_then(|g| g["id"].as_str()).map(str::to_owned),
                bot_id: v["botId"].as_str().map(str::to_owned),
            })
        })
        .collect()
}
#[derive(Debug, PartialEq)]
pub struct Row {
    pub author: String,
    pub identity: Option<String>,
    pub text: String,
    pub outgoing: bool,
    pub status: bool,
}
pub fn rows(snapshot: &Value, title: &str, identity: Option<&str>) -> Vec<Row> {
    if snapshot["members"].is_array() {
        return snapshot["messages"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|message| {
                let kind = message["authorKind"].as_str()?;
                if !matches!(kind, "user" | "automation" | "member" | "coordinator") {
                    return None;
                }
                Some(Row {
                    identity: message["authorBotId"].as_str().map(str::to_owned),
                    author: message["authorBotName"].as_str().unwrap_or("You").into(),
                    text: attachment_message_text(message)?,
                    outgoing: matches!(kind, "user" | "automation"),
                    status: message["presentationKind"] == "status",
                })
            })
            .collect();
    }
    direct_rows(snapshot)
        .into_iter()
        .map(|(author, text)| Row {
            identity: identity.map(str::to_owned),
            outgoing: author == "You",
            status: author != "You" && author != "Bot",
            author: if author == "Bot" {
                title.into()
            } else {
                author
            },
            text,
        })
        .collect()
}
fn direct_rows(snapshot: &Value) -> Vec<(String, String)> {
    let mut rows = Vec::new();
    let mut users = std::collections::HashSet::new();
    for turn in snapshot["thread"]["turns"].as_array().into_iter().flatten() {
        for item in turn["items"].as_array().into_iter().flatten() {
            match item["type"].as_str().unwrap_or("") {
                "userMessage" => {
                    let user =
                        snapshot["messages"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .find(|message| {
                                (message["clientMessageId"].is_string()
                                    && message["clientMessageId"] == item["payload"]["clientId"])
                                    || (message["messageId"].is_string()
                                        && message["messageId"] == item["id"])
                            });
                    if let Some(message) = user {
                        if users.insert(message["messageId"].as_str().unwrap_or("").to_owned()) {
                            push_user(&mut rows, message);
                        }
                    }
                }
                "agentMessage" => {
                    if let Some(text) = item["text"].as_str().filter(|s| !s.is_empty()) {
                        rows.push(("Bot".into(), text.into()));
                    }
                }
                _ => {}
            }
        }
    }
    if rows.is_empty() {
        for message in snapshot["messages"].as_array().into_iter().flatten() {
            push_user(&mut rows, message);
            users.insert(message["messageId"].as_str().unwrap_or("").to_owned());
        }
        for message in snapshot["assistantMessages"]
            .as_array()
            .into_iter()
            .flatten()
        {
            if let Some(text) = message["text"].as_str() {
                rows.push(("Bot".into(), text.into()));
            }
        }
    }
    // Accepted/queued messages may not have a runtime user item yet. Keep them
    // visible alongside existing history after their composer has cleared.
    for message in snapshot["messages"].as_array().into_iter().flatten() {
        let id = message["messageId"].as_str().unwrap_or("");
        if !users.contains(id)
            && matches!(
                message["state"].as_str(),
                Some(
                    "accepted_by_wonder"
                        | "dispatching_to_codex"
                        | "accepted_by_codex"
                        | "streaming"
                        | "uncertain"
                        | "safe_to_retry"
                        | "failed"
                )
            )
        {
            push_user(&mut rows, message);
            users.insert(id.to_owned());
        }
    }

    rows
}
fn attachment_message_text(message: &Value) -> Option<String> {
    let text = message["body"].as_str()?;
    let count = message["attachmentIds"]
        .as_array()
        .map(Vec::len)
        .unwrap_or(0);
    if count == 0 {
        return Some(text.into());
    }
    let suffix = if count == 1 {
        "1 attachment".into()
    } else {
        format!("{count} attachments")
    };
    Some(if text.trim().is_empty() {
        suffix
    } else {
        format!("{text}\n\n{suffix}")
    })
}
fn push_user(rows: &mut Vec<(String, String)>, message: &Value) {
    if let Some(text) = attachment_message_text(message) {
        rows.push(("You".into(), text));
    }
    match message["state"].as_str().unwrap_or("") {
        "accepted_by_wonder" => rows.push(("Queued".into(), String::new())),
        "dispatching_to_codex" | "accepted_by_codex" | "streaming" => {
            rows.push(("Working…".into(), String::new()))
        }
        "safe_to_retry" | "failed" => rows.push((
            "Couldn’t start".into(),
            "Check Wonder on your Mac before trying again.".into(),
        )),
        "uncertain" | "unknown" | "outcome_unknown" => rows.push((
            "Outcome unknown".into(),
            "Review this conversation and its files before sending another request.".into(),
        )),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn uncertain_direct_and_group_sends_replay_the_frozen_payload() {
        use std::io::{BufRead, BufReader, Read, Write};
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let mut posts = Vec::new();
            for _ in 0..8 {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(3)))
                    .unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut request = String::new();
                reader.read_line(&mut request).unwrap();
                let mut length = 0;
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    if line == "\r\n" {
                        break;
                    }
                    if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                        length = value.trim().parse::<usize>().unwrap();
                    }
                }
                let mut bytes = vec![0; length];
                reader.read_exact(&mut bytes).unwrap();
                let (status, body) = if request.starts_with("GET ") {
                    ("200 OK", serde_json::json!({"hostInstallationId":"host"}))
                } else {
                    let payload: Value = serde_json::from_slice(&bytes).unwrap();
                    posts.push((request, payload.clone()));
                    if posts.len() % 2 == 1 {
                        ("503 Service Unavailable", Value::Null)
                    } else {
                        (
                            "200 OK",
                            serde_json::json!({"clientMessageId":payload["clientMessageId"],"conversationId":"conversation","bodySha256":format!("{:x}",Sha256::digest(b"frozen text")),"wonderMessageId":"accepted"}),
                        )
                    }
                };
                let body = body.to_string();
                write!(stream,"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
            }
            posts
        });
        let connection = Connection {
            origin: Url::parse(&format!("http://{address}")).unwrap(),
            capability: "test-only".into(),
            http: Client::builder()
                .no_proxy()
                .timeout(std::time::Duration::from_secs(3))
                .build()
                .unwrap(),
        };
        let frozen = Pending {
            id: "same-request".into(),
            body: "frozen text".into(),
            attachment_ids: vec!["first-file".into(), "second-file".into()],
        };
        for group in [None, Some("group")] {
            assert!(connection
                .send("conversation", group, &frozen, "host")
                .is_err());
            let restored: Pending =
                serde_json::from_slice(&serde_json::to_vec(&frozen).unwrap()).unwrap();
            assert!(connection
                .send("conversation", group, &restored, "host")
                .is_ok());
        }
        let posts = server.join().unwrap();
        assert_eq!(posts[0], posts[1]);
        assert_eq!(posts[2], posts[3]);
        assert!(posts[0]
            .0
            .contains("/api/v1/conversations/conversation/messages"));
        assert!(posts[2].0.contains("/api/v1/channels/group/messages"));
        assert_eq!(
            posts[0].1["attachmentIds"],
            serde_json::json!(["first-file", "second-file"])
        );
        assert_eq!(posts[0].1["clientMessageId"], "same-request");
    }
    #[test]
    fn attachment_only_messages_are_visible_in_direct_and_group_feeds() {
        let direct = rows(
            &serde_json::json!({"messages":[{"body":"","messageId":"direct","attachmentIds":["one"]}]}),
            "Bot",
            None,
        );
        assert_eq!(direct[0].text, "1 attachment");
        let group = rows(
            &serde_json::json!({"members":[],"messages":[{"body":"Look","authorKind":"user","attachmentIds":["one","two"]}]}),
            "Group",
            None,
        );
        assert_eq!(group[0].text, "Look\n\n2 attachments");
    }
    #[test]
    fn group_attachments_require_explicit_host_capability() {
        let conversation = serde_json::json!([{"conversationId":"chat","botId":"bot"}]);
        let old = serde_json::json!([{"id":"group","conversationId":"chat","isArchived":false}]);
        assert!(!chats(conversation.clone(), &old, &Value::Null)[0].attachments_supported);
        let mut current = old;
        current[0]["attachmentsSupported"] = Value::Bool(true);
        assert!(chats(conversation.clone(), &current, &Value::Null)[0].attachments_supported);
        assert!(chats(conversation, &Value::Null, &Value::Null)[0].attachments_supported);
    }
    #[test]
    fn preview_requires_matching_size_digest_and_supported_metadata() {
        let bytes = b"Hello";
        let mut file = PreviewFile {
            id: "file".into(),
            name: "file.txt".into(),
            mime_type: Some("text/plain".into()),
            byte_size: Some(5),
            sha256: Some(
                Sha256::digest(bytes)
                    .iter()
                    .map(|v| format!("{v:02x}"))
                    .collect(),
            ),
            state: "available".into(),
        };
        assert!(file.supported() && file.matches(bytes));
        assert!(!file.matches(b"Other"));
        file.byte_size = Some(6);
        assert!(!file.matches(bytes));
        file.mime_type = Some("text/html".into());
        assert!(!file.supported());
        file.mime_type = Some("image/svg+xml".into());
        assert!(!file.supported());
    }
    #[test]
    fn receipt_must_match_identity_conversation_and_body() {
        let pending = Pending {
            attachment_ids: vec![],
            id: "request".into(),
            body: "hello".into(),
        };
        let digest = Sha256::digest(b"hello")
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>();
        let mut receipt = serde_json::json!({"clientMessageId":"request","conversationId":"chat","bodySha256":digest,"wonderMessageId":"message"});
        assert!(valid_receipt(&receipt, "chat", &pending));
        assert!(!valid_receipt(&receipt, "other", &pending));
        receipt["bodySha256"] = Value::String("changed".into());
        assert!(!valid_receipt(&receipt, "chat", &pending));
    }
    #[test]
    fn runtime_user_echo_uses_canonical_message() {
        let snapshot = serde_json::json!({"messages":[{"messageId":"m","clientMessageId":"c","body":"Hello"}],"thread":{"turns":[{"items":[
            {"type":"userMessage","id":"i","text":"Internal instructions","payload":{"clientId":"c"}},
            {"type":"agentMessage","text":"Hi"}]}]}});
        assert_eq!(
            direct_rows(&snapshot),
            vec![("You".into(), "Hello".into()), ("Bot".into(), "Hi".into())]
        );
    }
    #[test]
    fn queued_send_is_visible_before_runtime_echo_and_not_duplicated_afterward() {
        let mut snapshot = serde_json::json!({"messages":[{"messageId":"new","clientMessageId":"new-client","body":"Next task","state":"accepted_by_wonder"}],"thread":{"turns":[{"items":[{"type":"agentMessage","text":"Previous answer"}]}]}});
        assert_eq!(
            direct_rows(&snapshot),
            vec![
                ("Bot".into(), "Previous answer".into()),
                ("You".into(), "Next task".into()),
                ("Queued".into(), String::new())
            ]
        );
        snapshot["thread"]["turns"][0]["items"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!({"type":"userMessage","payload":{"clientId":"new-client"}}));
        snapshot["messages"][0]["state"] = serde_json::json!("streaming");
        let rows = direct_rows(&snapshot);
        assert_eq!(rows.iter().filter(|(author, _)| author == "You").count(), 1);
        assert!(rows.iter().any(|(author, _)| author == "Working…"));
    }
    #[test]
    fn group_speakers_and_archived_routing_remain_distinct() {
        let groups = serde_json::json!([{"id":"group","conversationId":"chat","isArchived":true}]);
        let list = chats(
            serde_json::json!([{"conversationId":"chat","title":"Team"}]),
            &groups,
            &Value::Null,
        );
        assert_eq!(list[0].group.as_deref(), Some("group"));
        assert!(!list[0].can_send);
        let snapshot = serde_json::json!({"members":[],"messages":[
            {"authorKind":"user","body":"hello","presentationKind":"message"},
            {"authorKind":"member","authorBotName":"You","body":"answer","presentationKind":"message"},
            {"authorKind":"internal","body":"hidden"}
        ]});
        let visible = rows(&snapshot, "Team", None);
        assert_eq!(visible.len(), 2);
        assert!(visible[0].outgoing);
        assert!(!visible[1].outgoing);
        assert_eq!(visible[1].author, "You");
        assert!(!visible[1].status);
    }
    #[test]
    fn bot_changes_update_name_color_and_hide_archived_direct_chats() {
        let conversations =
            serde_json::json!([{"conversationId":"chat","botId":"bot","title":"Old name"}]);
        let active = serde_json::json!([{"id":"bot","name":"Ada","avatarColor":"#168c8c","isArchived":false}]);
        let visible = chats(conversations.clone(), &serde_json::json!([]), &active);
        assert_eq!(visible[0].title, "Ada");
        assert_eq!(visible[0].avatar_color.as_deref(), Some("#168c8c"));
        let mut archived = active;
        archived[0]["isArchived"] = serde_json::json!(true);
        assert!(chats(conversations.clone(), &serde_json::json!([]), &archived).is_empty());
        let group = serde_json::json!([{"id":"group","conversationId":"chat","name":"Team","isArchived":true}]);
        let visible = chats(conversations, &group, &archived);
        assert_eq!(visible[0].title, "Team");
        assert!(!visible[0].can_send);
    }
    #[test]
    fn draft_round_trip_preserves_uncertain_request() {
        let root =
            std::env::temp_dir().join(format!("wonder-desktop-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let disk = Disk {
            path: root.join("drafts.json"),
            _lock: None,
        };
        let mut saved = Saved::default();
        saved.chats.insert(
            "host:chat".into(),
            Draft {
                attachments: vec![],
                text: "follow-up".into(),
                pending: Some(Pending {
                    attachment_ids: vec!["file-original".into()],
                    id: "same-request".into(),
                    body: "original".into(),
                }),
            },
        );
        saved.answers.insert(
            "host:question:id".into(),
            AnswerDraft {
                values: vec!["edited draft".into()],
                pending: Some(serde_json::json!({"answers":["original answer"],"skip":false})),
            },
        );
        disk.save(&saved).unwrap();
        let restored = disk.load().unwrap();
        assert_eq!(
            restored.chats["host:chat"].pending.as_ref().unwrap().id,
            "same-request"
        );
        assert_eq!(restored.chats["host:chat"].text, "follow-up");
        assert_eq!(
            restored.chats["host:chat"]
                .pending
                .as_ref()
                .unwrap()
                .attachment_ids,
            vec!["file-original"]
        );
        assert_eq!(
            restored.answers["host:question:id"]
                .pending
                .as_ref()
                .unwrap()["answers"][0],
            "original answer"
        );
        assert_eq!(
            restored.answers["host:question:id"].values[0],
            "edited draft"
        );
        fs::write(&disk.path, b"broken").unwrap();
        assert!(disk.load().is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
