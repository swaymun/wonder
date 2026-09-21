//! File bytes are frozen privately before their upload identity is saved. Restoring
//! a draft never retries a request; Check upload reuses the same identity/bytes.
use crate::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::VecDeque,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_FILES: usize = 4;
pub use crate::client::StagedFile;
impl StagedFile {
    fn body(&self, root: &Path) -> Result<Value, String> {
        let bytes = read_bounded(&cache_path(root, &self.upload_id)?)?;
        if self.byte_size != bytes.len() || self.sha256 != digest(&bytes) {
            return Err(
                "The saved attachment changed. Remove it and attach the file again.".into(),
            );
        }
        Ok(
            json!({"clientUploadId":self.upload_id,"name":self.name,"mimeType":self.mime_type,"contentBase64":STANDARD.encode(bytes)}),
        )
    }
    fn receipt(&self, chat: &str, value: &Value) -> Result<String, String> {
        let hash = Sha256::digest(format!("native-upload:{chat}:{}", self.upload_id).as_bytes());
        let mut bytes = [0; 16];
        bytes.copy_from_slice(&hash[..16]);
        bytes[6] = (bytes[6] & 0x0f) | 0x50;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        let expected = uuid::Uuid::from_bytes(bytes).to_string();
        if value["id"] == expected
            && value["kind"] == "attachment"
            && value["name"] == self.name
            && value["mimeType"] == self.mime_type
            && value["byteSize"] == self.byte_size
            && value["sha256"] == self.sha256
            && value["state"] == "available"
        {
            Ok(expected)
        } else {
            Err("Upload not confirmed. Check upload to verify the saved file.".into())
        }
    }
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn cache_path(root: &Path, id: &str) -> Result<PathBuf, String> {
    uuid::Uuid::parse_str(id).map_err(|_| "Saved attachment identity is invalid")?;
    Ok(root.join(id))
}
fn read_bounded(path: &Path) -> Result<Vec<u8>, String> {
    let file = fs::File::open(path).map_err(|_| "The attachment could not be opened")?;
    if !file
        .metadata()
        .map_err(|_| "The attachment could not be read")?
        .is_file()
    {
        return Err("Choose a file, not a folder.".into());
    }
    let mut bytes = Vec::new();
    file.take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| "The attachment could not be read")?;
    if bytes.is_empty() || bytes.len() > MAX_BYTES {
        return Err("Choose a nonempty file up to 8 MB.".into());
    }
    Ok(bytes)
}
fn stage(root: &Path, path: &Path) -> Result<StagedFile, String> {
    let name = path
        .file_name()
        .and_then(|v| v.to_str())
        .ok_or("The file name could not be read")?
        .to_owned();
    if name.trim() != name
        || name.is_empty()
        || name.len() > 255
        || name.chars().any(char::is_control)
        || name.contains(['/', '\\'])
    {
        return Err("Rename this file before attaching it.".into());
    }
    let bytes = read_bounded(path)?;
    fs::create_dir_all(root).map_err(|_| "Couldn’t create the attachment folder")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(root, fs::Permissions::from_mode(0o700))
            .map_err(|_| "Couldn’t protect the attachment folder")?;
    }
    let upload_id = uuid::Uuid::new_v4().to_string();
    let destination = cache_path(root, &upload_id)?;
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let written = options
        .open(&destination)
        .and_then(|mut file| file.write_all(&bytes).and_then(|_| file.sync_all()));
    if written.is_err() {
        let _ = fs::remove_file(&destination);
        return Err("The attachment could not be saved".into());
    }
    let mime_type = match path
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "pdf" => "application/pdf",
        "txt" => "text/plain",
        "md" | "markdown" => "text/markdown",
        "csv" => "text/csv",
        "json" => "application/json",
        _ => "application/octet-stream",
    }
    .to_owned();
    Ok(StagedFile {
        upload_id,
        name,
        mime_type,
        byte_size: bytes.len(),
        sha256: digest(&bytes),
        file_id: None,
        error: None,
    })
}
pub fn remove_cached(root: &Path, file: &StagedFile) {
    if let Ok(path) = cache_path(root, &file.upload_id) {
        let _ = fs::remove_file(path);
    }
}
pub fn cleanup_unreferenced(root: &Path, saved: &Saved) {
    let retained: std::collections::HashSet<_> = saved
        .chats
        .values()
        .flat_map(|draft| draft.attachments.iter().map(|file| file.upload_id.as_str()))
        .collect();
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            if let Some(id) = name.to_str().filter(|id| uuid::Uuid::parse_str(id).is_ok()) {
                if !retained.contains(id) {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
    }
}
pub fn complete(draft: &mut Draft) -> Vec<StagedFile> {
    let ids = draft
        .pending
        .as_ref()
        .map(|p| p.attachment_ids.clone())
        .unwrap_or_default();
    let mut removed = vec![];
    draft.attachments.retain(|file| {
        if file.file_id.as_ref().is_some_and(|id| ids.contains(id)) {
            removed.push(file.clone());
            false
        } else {
            true
        }
    });
    removed
}
enum Reply {
    Prepared {
        key: String,
        chat: String,
        host: String,
        files: Vec<StagedFile>,
        error: Option<String>,
    },
    Uploaded {
        key: String,
        upload_id: String,
        result: Result<String, String>,
    },
}
pub struct Uploads {
    sender: mpsc::Sender<Reply>,
    receiver: mpsc::Receiver<Reply>,
    pub preparing: Option<String>,
    active: Option<(String, String)>,
    queue: VecDeque<(String, String, String, String)>,
}
impl Default for Uploads {
    fn default() -> Self {
        let (sender, receiver) = mpsc::channel();
        Self {
            sender,
            receiver,
            preparing: None,
            active: None,
            queue: VecDeque::new(),
        }
    }
}
impl Chats {
    fn attachment_draft(&self) -> Option<&Draft> {
        self.selected
            .as_ref()
            .and_then(|id| self.saved.chats.get(&self.draft_key(id)))
    }
    pub fn has_attachments(&self) -> bool {
        self.attachment_draft()
            .is_some_and(|d| !d.attachments.is_empty())
    }
    pub fn attachments_ready(&self) -> bool {
        let Some(id) = &self.selected else {
            return false;
        };
        self.attachments.preparing.as_ref() != Some(&self.draft_key(id))
            && self
                .attachment_draft()
                .is_none_or(|d| d.attachments.iter().all(|f| f.file_id.is_some()))
            && (!self.has_attachments()
                || self
                    .chats
                    .iter()
                    .any(|c| &c.id == id && c.attachments_supported))
    }
    pub fn can_attach(&self) -> bool {
        self.disk.is_some()
            && self.connection.is_some()
            && self.host.is_some()
            && !self.busy
            && self.attachments.preparing.is_none()
            && self.chats.iter().any(|c| {
                Some(&c.id) == self.selected.as_ref() && c.can_send && c.attachments_supported
            })
            && self
                .attachment_draft()
                .is_none_or(|d| d.pending.is_none() && d.attachments.len() < MAX_FILES)
    }
    pub fn choose_attachments(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_attach() {
            return;
        }
        let chat = self.selected.clone().unwrap();
        let key = self.draft_key(&chat);
        let host = self.host.clone().unwrap();
        let root = self.disk.as_ref().unwrap().attachment_root();
        let slots = MAX_FILES
            - self
                .attachment_draft()
                .map(|d| d.attachments.len())
                .unwrap_or(0);
        self.attachments.preparing = Some(key.clone());
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: Some("Attach files".into()),
        });
        cx.spawn_in(window, async move |view, cx| {
            let result = picker.await;
            let _ = view.update_in(cx, |this, _, cx| {
                match result {
                    Ok(Ok(Some(paths))) if !paths.is_empty() => {
                        let sender = this.attachments.sender.clone();
                        std::thread::spawn(move || {
                            let mut files = vec![];
                            let mut error = (paths.len() > slots)
                                .then(|| "Attach up to four files per message.".to_owned());
                            for path in paths.into_iter().take(slots) {
                                match stage(&root, &path) {
                                    Ok(file) => files.push(file),
                                    Err(e) => error = Some(e),
                                }
                            }
                            let _ = sender.send(Reply::Prepared {
                                key,
                                chat,
                                host,
                                files,
                                error,
                            });
                        });
                    }
                    Ok(Ok(None)) => this.attachments.preparing = None,
                    _ => {
                        this.attachments.preparing = None;
                        this.error = Some("Files could not be selected.".into());
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    fn save_attachment_draft(&mut self) -> bool {
        match self
            .disk
            .as_ref()
            .ok_or("Draft storage is unavailable".into())
            .and_then(|disk| disk.save(&self.saved))
        {
            Ok(()) => true,
            Err(error) => {
                self.error = Some(error);
                false
            }
        }
    }
    pub fn tick_attachments(&mut self, cx: &mut Context<Self>) {
        while let Ok(reply) = self.attachments.receiver.try_recv() {
            match reply {
                Reply::Prepared {
                    key,
                    chat,
                    host,
                    files,
                    error,
                } => {
                    self.attachments.preparing = None;
                    let queued: Vec<_> = files
                        .iter()
                        .map(|f| (key.clone(), chat.clone(), host.clone(), f.upload_id.clone()))
                        .collect();
                    self.saved
                        .chats
                        .entry(key.clone())
                        .or_default()
                        .attachments
                        .extend(files);
                    if self.save_attachment_draft() {
                        self.attachments.queue.extend(queued);
                    }
                    if error.is_some() {
                        self.error = error;
                    }
                }
                Reply::Uploaded {
                    key,
                    upload_id,
                    result,
                } => {
                    self.attachments.active = None;
                    if let Some(file) =
                        self.saved.chats.get_mut(&key).and_then(|d| {
                            d.attachments.iter_mut().find(|f| f.upload_id == upload_id)
                        })
                    {
                        match result {
                            Ok(id) => {
                                file.file_id = Some(id);
                                file.error = None;
                            }
                            Err(error) => file.error = Some(error),
                        }
                        // If saving fails, keep the stable upload UUID and require a
                        // successful save before sending or another upload.
                        self.save_attachment_draft();
                    }
                }
            }
            cx.notify();
        }
        if self.attachments.active.is_none() {
            if let Some((key, chat, host, upload_id)) = self.attachments.queue.pop_front() {
                if self.host.as_ref() != Some(&host) {
                    return;
                }
                let Some(file) = self
                    .saved
                    .chats
                    .get(&key)
                    .and_then(|d| {
                        d.attachments
                            .iter()
                            .find(|f| f.upload_id == upload_id && f.file_id.is_none())
                    })
                    .cloned()
                else {
                    return;
                };
                let (Some(connection), Some(disk)) = (self.connection.clone(), &self.disk) else {
                    return;
                };
                let root = disk.attachment_root();
                if !self.save_attachment_draft() {
                    return;
                }
                self.attachments.active = Some((key.clone(), upload_id.clone()));
                let sender = self.attachments.sender.clone();
                std::thread::spawn(move || {
                    let result = file
                        .body(&root)
                        .and_then(|body| {
                            connection.request(
                                "POST",
                                &[
                                    "api".into(),
                                    "v1".into(),
                                    "conversations".into(),
                                    chat.clone(),
                                    "files".into(),
                                ],
                                &body,
                                &host,
                            )
                        })
                        .and_then(|value| file.receipt(&chat, &value));
                    let _ = sender.send(Reply::Uploaded {
                        key,
                        upload_id,
                        result,
                    });
                });
                cx.notify();
            }
        }
    }
    fn remove_attachment(&mut self, key: &str, id: &str, cx: &mut Context<Self>) {
        if self
            .attachments
            .active
            .as_ref()
            .is_some_and(|v| v.0 == key && v.1 == id)
        {
            return;
        }
        let Some(draft) = self
            .saved
            .chats
            .get_mut(key)
            .filter(|d| d.pending.is_none())
        else {
            return;
        };
        let old = draft.attachments.clone();
        draft.attachments.retain(|f| f.upload_id != id);
        if self.save_attachment_draft() {
            if let Some(disk) = &self.disk {
                for file in old.iter().filter(|f| f.upload_id == id) {
                    remove_cached(&disk.attachment_root(), file);
                }
            }
        } else {
            self.saved.chats.get_mut(key).unwrap().attachments = old;
        }
        cx.notify();
    }
    pub fn attachment_chips(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let key = self
            .selected
            .as_ref()
            .map(|id| self.draft_key(id))
            .unwrap_or_default();
        let files = self
            .attachment_draft()
            .map(|d| d.attachments.clone())
            .unwrap_or_default();
        let pending = self.attachment_draft().is_some_and(|d| d.pending.is_some());
        let preparing = self.attachments.preparing.as_ref() == Some(&key);
        div()
            .flex()
            .flex_col()
            .gap_1()
            .when(preparing, |v| {
                v.child(
                    div()
                        .id("attachment-preparing")
                        .role(Role::Label)
                        .aria_label("Preparing attachments")
                        .text_sm()
                        .child("Preparing attachments…"),
                )
            })
            .children(files.into_iter().map(|file| {
                let active = self
                    .attachments
                    .active
                    .as_ref()
                    .is_some_and(|v| v.0 == key && v.1 == file.upload_id);
                let queued = self
                    .attachments
                    .queue
                    .iter()
                    .any(|v| v.0 == key && v.3 == file.upload_id);
                let status = if active || queued {
                    "Uploading…"
                } else if file.file_id.is_some() {
                    "Attached"
                } else {
                    "Upload not confirmed"
                };
                let label = format!(
                    "{} · {} KB · {status}",
                    file.name,
                    file.byte_size.div_ceil(1024)
                );
                let remove_key = key.clone();
                let retry_key = key.clone();
                let remove_id = file.upload_id.clone();
                let retry_id = file.upload_id.clone();
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .id(SharedString::from(format!(
                                        "attachment-{}",
                                        file.upload_id
                                    )))
                                    .role(Role::Label)
                                    .aria_label(label.clone())
                                    .text_sm()
                                    .flex_1()
                                    .child(label),
                            )
                            .when(file.file_id.is_none(), |v| {
                                v.child(
                                    Button::new(SharedString::from(format!(
                                        "check-upload-{}",
                                        file.upload_id
                                    )))
                                    .label("Check upload")
                                    .accessibility_label(format!("Check upload of {}", file.name))
                                    .disabled(active || queued || pending || self.disk.is_none())
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if let (Some(chat), Some(host)) =
                                            (this.selected.clone(), this.host.clone())
                                        {
                                            if this.draft_key(&chat) == retry_key {
                                                this.attachments.queue.push_back((
                                                    retry_key.clone(),
                                                    chat,
                                                    host,
                                                    retry_id.clone(),
                                                ));
                                                cx.notify();
                                            }
                                        }
                                    })),
                                )
                            })
                            .child(
                                Button::new(SharedString::from(format!(
                                    "remove-attachment-{}",
                                    file.upload_id
                                )))
                                .label("Remove")
                                .accessibility_label(format!("Remove attachment {}", file.name))
                                .disabled(active || pending)
                                .on_click(cx.listener(
                                    move |this, _, _, cx| {
                                        this.remove_attachment(&remove_key, &remove_id, cx)
                                    },
                                )),
                            ),
                    )
                    .when_some(file.error, |v, error| {
                        v.child(
                            div()
                                .id(SharedString::from(format!(
                                    "attachment-error-{}",
                                    file.upload_id
                                )))
                                .role(Role::Label)
                                .aria_label(error.clone())
                                .text_sm()
                                .text_color(cx.theme().danger)
                                .child(error),
                        )
                    })
            }))
    }
}

#[cfg(test)]
mod tests {
    use super::{
        cache_path, cleanup_unreferenced, complete, stage, StagedFile, Uploads, MAX_BYTES,
    };
    use crate::client::{Draft, Pending, Saved};
    use base64::{engine::general_purpose::STANDARD, Engine};
    use serde_json::{json, Value};
    use sha2::{Digest, Sha256};
    use std::{fs, path::PathBuf};
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir()
                .join(format!("wonder-attachment-test-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn source(&self, bytes: &[u8]) -> PathBuf {
            let path = self.0.join("note.txt");
            fs::write(&path, bytes).unwrap();
            path
        }
        fn cache(&self) -> PathBuf {
            self.0.join("cache")
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn response(file: &StagedFile, chat: &str) -> Value {
        let hash = Sha256::digest(format!("native-upload:{chat}:{}", file.upload_id));
        let mut bytes = [0; 16];
        bytes.copy_from_slice(&hash[..16]);
        bytes[6] = (bytes[6] & 15) | 80;
        bytes[8] = (bytes[8] & 63) | 128;
        json!({"id":uuid::Uuid::from_bytes(bytes).to_string(),"kind":"attachment","name":file.name,"mimeType":file.mime_type,"byteSize":file.byte_size,"sha256":file.sha256,"state":"available"})
    }
    #[test]
    fn restart_and_changed_original_preserve_upload_identity_and_bytes() {
        let fixture = Fixture::new();
        let source = fixture.source(b"original bytes");
        let file = stage(&fixture.cache(), &source).unwrap();
        let before = file.body(&fixture.cache()).unwrap();
        let restored: StagedFile =
            serde_json::from_slice(&serde_json::to_vec(&file).unwrap()).unwrap();
        fs::write(&source, b"changed").unwrap();
        assert_eq!(before, restored.body(&fixture.cache()).unwrap());
        assert_eq!(before["contentBase64"], STANDARD.encode(b"original bytes"));
        assert_eq!(before["clientUploadId"], file.upload_id);
        assert!(restored.file_id.is_none());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(fixture.cache()).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(cache_path(&fixture.cache(), &file.upload_id).unwrap())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }
    #[test]
    fn exact_byte_limit_and_empty_file_are_enforced_before_caching() {
        let fixture = Fixture::new();
        let source = fixture.source(&vec![7; MAX_BYTES]);
        let file = stage(&fixture.cache(), &source).unwrap();
        assert_eq!(file.byte_size, MAX_BYTES);
        fs::write(&source, vec![7; MAX_BYTES + 1]).unwrap();
        assert!(stage(&fixture.cache(), &source).is_err());
        fs::write(&source, []).unwrap();
        assert!(stage(&fixture.cache(), &source).is_err());
        assert_eq!(fs::read_dir(fixture.cache()).unwrap().count(), 1);
    }
    #[test]
    fn receipt_rejects_other_chat_wrong_identity_hash_and_mime() {
        let fixture = Fixture::new();
        let file = stage(&fixture.cache(), &fixture.source(b"hello")).unwrap();
        let good = response(&file, "group-conversation");
        assert!(file.receipt("group-conversation", &good).is_ok());
        assert!(file.receipt("other-conversation", &good).is_err());
        for (field, value) in [
            ("id", json!(uuid::Uuid::new_v4().to_string())),
            ("sha256", json!("changed")),
            ("mimeType", json!("image/png")),
            ("byteSize", json!(999)),
            ("state", json!("pending")),
        ] {
            let mut bad = good.clone();
            bad[field] = value;
            assert!(file.receipt("group-conversation", &bad).is_err(), "{field}");
        }
    }
    #[test]
    fn changed_private_bytes_and_invalid_cache_identity_fail_closed() {
        let fixture = Fixture::new();
        let mut file = stage(&fixture.cache(), &fixture.source(b"hello")).unwrap();
        fs::write(
            cache_path(&fixture.cache(), &file.upload_id).unwrap(),
            b"other",
        )
        .unwrap();
        assert!(file.body(&fixture.cache()).is_err());
        file.upload_id = "../note.txt".into();
        assert!(file.body(&fixture.cache()).is_err());
    }
    #[test]
    fn confirmed_send_only_removes_frozen_attachments_and_cleanup_keeps_other_hosts() {
        let fixture = Fixture::new();
        let mut sent = stage(&fixture.cache(), &fixture.source(b"first")).unwrap();
        sent.file_id = Some("sent-file".into());
        let other = stage(&fixture.cache(), &fixture.source(b"second")).unwrap();
        let mut draft = Draft {
            text: "edited draft".into(),
            pending: Some(Pending {
                id: "original-request".into(),
                body: "original body".into(),
                attachment_ids: vec!["sent-file".into()],
            }),
            attachments: vec![sent.clone(), other.clone()],
        };
        let removed = complete(&mut draft);
        assert_eq!(removed.len(), 1);
        assert_eq!(draft.attachments[0].upload_id, other.upload_id);
        assert_eq!(draft.text, "edited draft");
        assert_eq!(draft.pending.as_ref().unwrap().id, "original-request");
        let mut saved = Saved::default();
        saved.chats.insert("other-host:chat".into(), draft);
        cleanup_unreferenced(&fixture.cache(), &saved);
        assert!(!cache_path(&fixture.cache(), &sent.upload_id)
            .unwrap()
            .exists());
        assert!(cache_path(&fixture.cache(), &other.upload_id)
            .unwrap()
            .exists());
    }
    #[test]
    fn legacy_drafts_decode_without_attachments_and_restoration_never_queues_uploads() {
        let draft: Draft = serde_json::from_value(
            json!({"text":"edited","pending":{"id":"request","body":"original"}}),
        )
        .unwrap();
        assert!(draft.attachments.is_empty());
        assert!(draft.pending.unwrap().attachment_ids.is_empty());
        let restored = Uploads::default();
        assert!(restored.active.is_none());
        assert!(restored.queue.is_empty());
    }
}
