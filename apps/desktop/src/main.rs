mod appearance;
mod attachments;
mod attention;
mod automation_form;
mod composer_settings;
mod forms;
mod management;
mod science_avatar;
use appearance::avatar;
mod client;
#[cfg(target_os = "macos")]
mod mac_settings;
mod markdown;
mod media;
#[cfg(target_os = "macos")]
mod menu_bar;
mod read_acknowledgements;
use client::*;
use gpui_kit::base::text::TextView;
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::{
    component::{
        button::*,
        input::{Input, InputEvent, InputState, Textarea, TextareaState},
        menu::{DropdownMenu, PopupMenuItem},
        *,
    },
    *,
};
use std::{
    sync::mpsc,
    time::{Duration, Instant},
};
use science_avatar::avatar as science_avatar;

actions!(
    wonder,
    [
        SearchChats,
        NewBot,
        NewGroup,
        FocusComposer,
        ToggleSidebar,
        NextChat,
        PreviousChat
    ]
);

struct Response {
    chat: Option<String>,
    result: Result<serde_json::Value, String>,
    sent: bool,
    apps: bool,
    answer: Option<String>,
}
struct Chats {
    manager: Option<Entity<management::Manager>>,
    manager_subscription: Option<Subscription>,
    manager_observer: Option<Subscription>,
    connection: Option<Connection>,
    disk: Option<Disk>,
    saved: Saved,
    host: Option<String>,
    chats: Vec<Chat>,
    bots: serde_json::Value,
    composer_options: serde_json::Value,
    settings_saving: bool,
    composer_menu_open: bool,
    settings_sender: mpsc::Sender<Result<serde_json::Value, String>>,
    settings_receiver: mpsc::Receiver<Result<serde_json::Value, String>>,
    selected: Option<String>,
    attachments: attachments::Uploads,
    pending_send_key: Option<String>,
    files: Vec<PreviewFile>,
    files_error: Option<String>,
    media: Option<media::Preview>,
    media_loading: bool,
    showing_media: bool,
    media_sender: mpsc::Sender<media::Loaded>,
    media_receiver: mpsc::Receiver<media::Loaded>,
    question: Option<attention::QuestionForm>,
    question_error: Option<String>,
    question_load_error: Option<String>,
    showing_apps: bool,
    apps_page: serde_json::Value,
    apps_error: Option<String>,
    apps_loaded_at: Option<Instant>,
    transcript: Vec<Row>,
    input: Entity<TextareaState>,
    search: Entity<InputState>,
    sidebar_hidden: bool,
    focus: FocusHandle,
    _search_subscription: Subscription,
    scroll: ScrollHandle,
    read_acknowledgements: read_acknowledgements::ReadAcknowledgements,
    follow_bottom: bool,
    error: Option<String>,
    busy: bool,
    sender: mpsc::Sender<Response>,
    receiver: mpsc::Receiver<Response>,
    last_refresh: Instant,
    _input_subscription: Subscription,
}
impl Chats {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        cx.observe_window_appearance(window, |_, window, cx| {
            appearance::sync(Some(window), cx);
            cx.notify();
        })
        .detach();
        let (sender, receiver) = mpsc::channel();
        let (settings_sender, settings_receiver) = mpsc::channel();
        let (media_sender, media_receiver) = mpsc::channel();
        let connection = Connection::from_environment();
        let disk = Disk::new();
        let saved = disk.as_ref().map_err(|e| e.clone()).and_then(Disk::load);
        if let (Ok(disk), Ok(saved)) = (&disk, &saved) {
            attachments::cleanup_unreferenced(&disk.attachment_root(), saved);
        }
        let error = connection
            .as_ref()
            .err()
            .cloned()
            .or_else(|| saved.as_ref().err().cloned());
        let input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("Message")
                .auto_grow(1, 6)
                .submit_on_enter(true)
        });
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search chats"));
        let search_subscription = cx.subscribe(&search, |_, _, _: &InputEvent, cx| cx.notify());
        let subscription = cx.subscribe(&input, |this, input, event, cx| {
            if matches!(event, InputEvent::Change | InputEvent::PressEnter { .. }) {
                if let Some(id) = &this.selected {
                    this.saved.chats.entry(this.draft_key(id)).or_default().text =
                        input.read(cx).value().to_string();
                    if let Some(disk) = &this.disk {
                        if let Err(error) = disk.save(&this.saved) {
                            this.error = Some(error);
                        }
                    }
                }
            }
            if matches!(event, InputEvent::PressEnter { shift: false, .. }) {
                this.send(cx);
            }
            cx.notify();
        });
        cx.spawn_in(window, async move |view, cx| loop {
            cx.background_executor()
                .timer(Duration::from_millis(100))
                .await;
            if view
                .update_in(cx, |this, window, cx| this.tick(window, cx))
                .is_err()
            {
                break;
            }
        })
        .detach();
        let mut view = Self {
            manager: None,
            manager_subscription: None,
            manager_observer: None,
            connection: connection.ok(),
            disk: if saved.is_ok() { disk.ok() } else { None },
            saved: saved.unwrap_or_default(),
            host: None,
            chats: vec![],
            bots: serde_json::Value::Null,
            composer_options: serde_json::Value::Null,
            settings_saving: false,
            composer_menu_open: false,
            settings_sender,
            settings_receiver,
            selected: None,
            attachments: attachments::Uploads::default(),
            pending_send_key: None,
            files: vec![],
            files_error: None,
            media: None,
            media_loading: false,
            showing_media: false,
            media_sender,
            media_receiver,
            question: None,
            question_error: None,
            question_load_error: None,
            showing_apps: false,
            apps_page: serde_json::Value::Null,
            apps_error: None,
            apps_loaded_at: None,
            transcript: vec![],
            input,
            search,
            sidebar_hidden: false,
            focus: cx.focus_handle(),
            _search_subscription: search_subscription,
            scroll: ScrollHandle::new(),
            read_acknowledgements: read_acknowledgements::ReadAcknowledgements::default(),
            follow_bottom: true,
            error,
            busy: false,
            sender,
            receiver,
            last_refresh: Instant::now(),
            _input_subscription: subscription,
        };
        window.focus(&view.focus, cx);
        view.refresh();
        view
    }
    fn manage(&mut self, page: management::Page, window: &mut Window, cx: &mut Context<Self>) {
        let (Some(connection), Some(host), Some(disk)) =
            (self.connection.clone(), self.host.clone(), &self.disk)
        else {
            return;
        };
        let path = disk.management_path();
        let manager =
            cx.new(|cx| management::Manager::new(connection, host, path, page, window, cx));
        self.manager_subscription =
            Some(
                cx.subscribe_in(&manager, window, |this, _, event, window, cx| {
                    match event {
                        management::Event::Close => {
                            this.manager = None;
                            this.input.update(cx, |input, cx| input.focus(window, cx));
                            this.last_refresh = Instant::now() - Duration::from_secs(3);
                            this.refresh();
                        }
                        management::Event::Open(id) => {
                            this.manager = None;
                            this.select(id.clone(), window, cx);
                        }
                    }
                    cx.notify();
                }),
            );
        self.manager_observer = Some(cx.observe(&manager, |_, _, cx| cx.notify()));
        self.manager = Some(manager);
        cx.notify();
    }
    fn toggle_sidebar(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if window.bounds().size.width < px(1100.)
            && self
                .manager
                .as_ref()
                .is_some_and(|manager| manager.read(cx).is_inspector())
        {
            self.manager = None;
            self.sidebar_hidden = false;
        } else {
            self.sidebar_hidden = !self.sidebar_hidden;
        }
        cx.notify();
    }
    fn move_chat(&mut self, forward: bool, window: &mut Window, cx: &mut Context<Self>) {
        let query = self.search.read(cx).value().to_lowercase();
        let chats: Vec<_> = self
            .chats
            .iter()
            .filter(|chat| chat_matches(chat, &query))
            .collect();
        if chats.is_empty() {
            return;
        }
        let index = match chats
            .iter()
            .position(|chat| Some(&chat.id) == self.selected.as_ref())
        {
            Some(index) if forward => (index + 1) % chats.len(),
            Some(index) => (index + chats.len() - 1) % chats.len(),
            None => 0,
        };
        self.select(chats[index].id.clone(), window, cx);
    }
    fn new_chat_menu(&self, cx: &Context<Self>) -> impl IntoElement {
        let bot_view = cx.entity().downgrade();
        let group_view = bot_view.clone();
        Button::new("new-conversation")
            .ghost()
            .icon(IconName::Plus)
            .accessibility_label("New conversation")
            .tooltip("New conversation")
            .disabled(self.host.is_none())
            .dropdown_menu(move |menu, _, _| {
                menu.item(PopupMenuItem::new("New Bot").on_click({
                    let view = bot_view.clone();
                    move |_, window, cx| {
                        let _ = view.update(cx, |this, cx| {
                            this.manage(management::Page::Bot(None), window, cx)
                        });
                    }
                }))
                .item(PopupMenuItem::new("New Group").on_click({
                    let view = group_view.clone();
                    move |_, window, cx| {
                        let _ = view.update(cx, |this, cx| {
                            this.manage(management::Page::Group, window, cx)
                        });
                    }
                }))
            })
    }
    fn draft_key(&self, id: &str) -> String {
        format!("{}:{id}", self.host.as_deref().unwrap_or("unconnected"))
    }
    fn refresh(&mut self) {
        if self.showing_apps {
            if self.apps_error.is_none() {
                self.refresh_apps(false, false);
            }
            return;
        }
        if self.busy || self.settings_saving || self.composer_menu_open {
            return;
        }
        let Some(connection) = self.connection.clone() else {
            return;
        };
        self.busy = true;
        self.last_refresh = Instant::now();
        let chat = self.selected.clone();
        let sender = self.sender.clone();
        let expected_host = self.host.clone();
        let load_options = self.composer_options.is_null();
        std::thread::spawn(move || {
            let result = (|| {
                let status = connection.get(&["api", "v1", "host", "status"])?;
                let host = status["hostInstallationId"]
                    .as_str()
                    .ok_or("Mac identity unavailable")?;
                if expected_host
                    .as_deref()
                    .is_some_and(|expected| expected != host)
                {
                    return Err(
                        "Mac identity changed. Close Chats and reopen it from Wonder.".into(),
                    );
                }
                let chats = connection.get(&["api", "v1", "conversations"])?;
                let groups = connection.get(&["api", "v1", "channels"])?;
                let bots = connection.get(&["api", "v1", "bots"])?;
                let options = if load_options {
                    if let Some(id) = chat.as_deref() {
                        connection
                            .get(&["api", "v1", "conversations", id, "composer-options"])
                            .ok()
                    } else {
                        connection.get(&["api", "v1", "bot-options"]).ok()
                    }
                } else {
                    None
                };
                let selected_group = groups
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|g| chat.as_deref().is_some_and(|id| g["conversationId"] == id))
                    .and_then(|g| g["id"].as_str());
                let snapshot = match (&chat, selected_group) {
                    (Some(_), Some(group)) => connection.get(&["api", "v1", "channels", group])?,
                    (Some(id), None) => connection.get(&["api", "v1", "conversations", id])?,
                    _ => serde_json::Value::Null,
                };
                let questions = match (&chat, selected_group) {
                    (Some(id), None) => {
                        connection.get(&["api", "v1", "conversations", id, "questions"])
                    }
                    _ => Ok(serde_json::json!([])),
                };
                let files = match &chat {
                    Some(id) => connection.get(&["api", "v1", "conversations", id, "files"]),
                    _ => Ok(serde_json::json!([])),
                };
                Ok(
                    serde_json::json!({"host":host,"chats":chats,"groups":groups,"bots":bots,"options":options,"snapshot":snapshot,
                    "questions":questions.as_ref().ok(),"questionsError":questions.err(),
                    "files":files.as_ref().ok(),"filesError":files.err()}),
                )
            })();
            let _ = sender.send(Response {
                chat,
                result,
                sent: false,
                apps: false,
                answer: None,
            });
        });
    }
    fn refresh_apps(&mut self, more: bool, force: bool) {
        if self.busy {
            return;
        }
        let (Some(connection), Some(host)) = (self.connection.clone(), self.host.clone()) else {
            return;
        };
        if !more
            && !force
            && self.apps_error.is_none()
            && self.apps_page["hostInstallationId"].as_str() == Some(host.as_str())
            && self
                .apps_loaded_at
                .is_some_and(|at| at.elapsed() < Duration::from_secs(300))
        {
            return;
        }
        let cursor = if more {
            self.apps_page["nextCursor"].as_str().map(str::to_owned)
        } else {
            None
        };
        if more && cursor.is_none() {
            return;
        }
        self.busy = true;
        self.last_refresh = Instant::now();
        let sender = self.sender.clone();
        std::thread::spawn(move || {
            let result = connection.apps(cursor.as_deref(), force).and_then(|page| {
                if page["hostInstallationId"] != host {
                    return Err("Mac identity changed. Reopen Chats from Wonder.".into());
                }
                Ok(serde_json::json!({"appsPage":page,"append":more,"requestedCursor":cursor}))
            });
            let _ = sender.send(Response {
                chat: None,
                result,
                sent: false,
                apps: true,
                answer: None,
            });
        });
    }
    fn apps_view(&self, cx: &mut Context<Self>) -> Div {
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(
                div()
                    .p_4()
                    .flex()
                    .items_center()
                    .gap_4()
                    .child(
                        Button::new("back-chats")
                            .label("Chats")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.showing_apps = false;
                                this.last_refresh = Instant::now() - Duration::from_secs(3);
                                cx.notify();
                            })),
                    )
                    .child("Connected apps")
                    .child(
                        Button::new("refresh-apps")
                            .label("Refresh")
                            .disabled(self.busy)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.refresh_apps(false, true);
                                cx.notify();
                            })),
                    ),
            )
            .when(self.busy, |v| v.child(div().px_4().child("Checking apps…")))
            .when_some(self.apps_error.clone(), |v, e| {
                v.child(div().px_4().child(e))
            })
            .when_some(
                self.apps_page["warning"].as_str().map(str::to_owned),
                |v, e| v.child(div().px_4().child(e)),
            )
            .child(
                div()
                    .id("apps-list")
                    .flex_1()
                    .overflow_y_scroll()
                    .p_4()
                    .flex()
                    .flex_col()
                    .gap_4()
                    .children(
                        self.apps_page["apps"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .enumerate()
                            .map(|(index, app)| {
                                let name = app["name"].as_str().unwrap_or("App").to_owned();
                                let status = match if self.apps_error.is_some() {
                                    "unknown"
                                } else {
                                    app["status"].as_str().unwrap_or("")
                                } {
                                    "available" => "Available",
                                    "disabled" => "Disabled",
                                    "not_connected" => "Not connected",
                                    "unavailable" => "Unavailable",
                                    _ => "Not verified",
                                };
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_4()
                                    .child(avatar(&name, None, 32.))
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w(px(0.))
                                            .child(
                                                div()
                                                    .font_weight(FontWeight::SEMIBOLD)
                                                    .child(name.clone()),
                                            )
                                            .child(div().text_sm().child(status))
                                            .when_some(
                                                app["description"].as_str().map(str::to_owned),
                                                |v, d| {
                                                    v.child(
                                                        div()
                                                            .text_sm()
                                                            .overflow_hidden()
                                                            .text_ellipsis()
                                                            .child(d),
                                                    )
                                                },
                                            ),
                                    )
                                    .when_some(
                                        app["setupUrl"].as_str().map(str::to_owned),
                                        |v, url| {
                                            v.child(
                                                Button::new(("setup-app", index))
                                                    .label("View app")
                                                    .accessibility_label(format!("View {name} app"))
                                                    .on_click(cx.listener(
                                                        move |this, _, _, cx| {
                                                            this.apps_loaded_at = None;
                                                            cx.open_url(&url);
                                                        },
                                                    )),
                                            )
                                        },
                                    )
                            }),
                    )
                    .when(self.apps_page["nextCursor"].is_string(), |v| {
                        v.child(
                            Button::new("more-apps")
                                .label("Load more")
                                .disabled(self.busy)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.refresh_apps(true, false);
                                    cx.notify();
                                })),
                        )
                    }),
            )
            .child(div().p_4().text_sm().child("Based on Codex connections."))
    }
    fn select(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.manager = None;
        self.manager_subscription = None;
        self.manager_observer = None;
        self.selected = Some(id.clone());
        self.composer_options = serde_json::Value::Null;
        self.read_acknowledgements.clear();
        self.transcript.clear();
        self.files.clear();
        self.files_error = None;
        self.media = None;
        self.showing_media = false;
        self.question = None;
        self.question_error = None;
        self.question_load_error = None;
        self.follow_bottom = true;
        let text = self
            .saved
            .chats
            .get(&self.draft_key(&id))
            .map(|d| d.text.clone())
            .unwrap_or_default();
        self.input.update(cx, |input, cx| {
            input.set_value(text, window, cx);
            input.focus(window, cx);
        });
        self.last_refresh = Instant::now() - Duration::from_secs(3);
        self.refresh();
        cx.notify();
    }
    fn send(&mut self, cx: &mut Context<Self>) {
        if self.busy || self.settings_saving || self.disk.is_none() {
            return;
        }
        let (Some(id), Some(connection)) = (self.selected.clone(), self.connection.clone()) else {
            return;
        };
        let Some(chat) = self
            .chats
            .iter()
            .find(|chat| chat.id == id && chat.can_send)
        else {
            return;
        };
        let group = chat.group.clone();
        let attachments_supported = chat.attachments_supported;
        let key = self.draft_key(&id);
        let draft = self.saved.chats.entry(key.clone()).or_default();
        if draft.pending.is_none() {
            if (draft.text.trim().is_empty() && draft.attachments.is_empty())
                || draft.text.len() > 65536
                || draft.attachments.iter().any(|file| file.file_id.is_none())
                || (!draft.attachments.is_empty() && !attachments_supported)
                || self.attachments.preparing.as_ref() == Some(&key)
            {
                return;
            }
            draft.pending = Some(Pending {
                attachment_ids: draft
                    .attachments
                    .iter()
                    .filter_map(|file| file.file_id.clone())
                    .collect(),
                id: uuid::Uuid::new_v4().to_string(),
                body: draft.text.clone(),
            });
        }
        let pending = draft.pending.clone().unwrap();
        let host = self.host.clone().unwrap_or_default();
        if let Err(error) = self.disk.as_ref().unwrap().save(&self.saved) {
            self.error = Some(error);
            cx.notify();
            return;
        }
        self.busy = true;
        self.pending_send_key = Some(key);
        self.follow_bottom = true;
        let sender = self.sender.clone();
        std::thread::spawn(move || {
            let result = connection
                .send(&id, group.as_deref(), &pending, &host)
                .map(|_| serde_json::Value::Null);
            let _ = sender.send(Response {
                chat: Some(id),
                result,
                sent: true,
                apps: false,
                answer: None,
            });
        });
        cx.notify();
    }
    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.tick_attachments(cx);
        self.tick_media(cx);
        self.tick_settings(cx);
        while let Ok(response) = self.receiver.try_recv() {
            self.busy = false;
            if let Some(id) = response.answer {
                if self
                    .question
                    .as_ref()
                    .is_some_and(|q| q.id == id && Some(&q.chat) == self.selected.as_ref())
                {
                    match response.result {
                        Ok(_) => {
                            self.question = None;
                            self.question_error = None;
                        }
                        Err(error) => self.question_error = Some(error),
                    }
                }
                self.last_refresh = Instant::now() - Duration::from_secs(3);
                cx.notify();
                continue;
            }
            match response.result {
                Err(error) => {
                    if response.apps {
                        self.apps_error = Some(error);
                    } else {
                        self.error = Some(error);
                    }
                }
                Ok(value) => {
                    if value["appsPage"].is_object() {
                        let mut page = value["appsPage"].clone();
                        if value["append"] == true {
                            let mut apps = self.apps_page["apps"]
                                .as_array()
                                .cloned()
                                .unwrap_or_default();
                            for app in page["apps"].as_array().into_iter().flatten() {
                                if !apps.iter().any(|old| old["id"] == app["id"]) {
                                    apps.push(app.clone());
                                }
                            }
                            page["apps"] = serde_json::json!(apps);
                            if page["nextCursor"] == value["requestedCursor"] {
                                page["nextCursor"] = serde_json::Value::Null;
                            }
                        }
                        if value["append"] != true {
                            self.apps_loaded_at = Some(Instant::now());
                        }
                        self.apps_page = page;
                        self.apps_error = None;
                        cx.notify();
                        continue;
                    }
                    if response.sent
                        || !self
                            .saved
                            .chats
                            .values()
                            .any(|draft| draft.pending.is_some())
                    {
                        self.error = None;
                    }
                    if response.sent {
                        if let Some(id) = response.chat {
                            let Some(key) = self.pending_send_key.take() else {
                                continue;
                            };
                            let draft = self.saved.chats.entry(key.clone()).or_default();
                            let completed_files = attachments::complete(draft);
                            if draft.pending.as_ref().is_some_and(|p| p.body == draft.text) {
                                draft.text.clear();
                            }
                            draft.pending = None;
                            if let Some(disk) = &self.disk {
                                if let Err(e) = disk.save(&self.saved) {
                                    self.error = Some(e);
                                    self.disk = None;
                                }
                            }
                            if let Some(disk) = &self.disk {
                                for file in completed_files {
                                    attachments::remove_cached(&disk.attachment_root(), &file);
                                }
                            }
                            if self.selected.as_ref() == Some(&id) && self.draft_key(&id) == key {
                                let text = self.saved.chats[&key].text.clone();
                                self.input
                                    .update(cx, |input, cx| input.set_value(text, window, cx));
                            }
                        }
                    } else {
                        self.host = value["host"].as_str().map(str::to_owned);
                        self.bots = value["bots"].clone();
                        if response.chat == self.selected && !value["options"].is_null() {
                            self.composer_options = value["options"].clone();
                        }
                        self.chats =
                            client::chats(value["chats"].clone(), &value["groups"], &self.bots);
                        if response.chat.is_some() && response.chat == self.selected {
                            self.update_question(&value, window, cx);
                            if let Some(error) = value["filesError"].as_str() {
                                self.files_error = Some(error.into());
                            } else {
                                match serde_json::from_value(value["files"].clone()) {
                                    Ok(files) => {
                                        self.files = files;
                                        if !self.showing_media {
                                            self.files_error = None;
                                        }
                                    }
                                    Err(_) => {
                                        self.files_error = Some(
                                            "File list unavailable. Checking again shortly.".into(),
                                        )
                                    }
                                }
                            }
                            let near_bottom = self.scroll.offset().y.abs() + px(60.)
                                >= self.scroll.max_offset().y.abs();
                            let title = self
                                .chats
                                .iter()
                                .find(|chat| Some(&chat.id) == self.selected.as_ref())
                                .map(|chat| chat.title.as_str())
                                .unwrap_or("Bot");
                            let identity = self
                                .chats
                                .iter()
                                .find(|chat| Some(&chat.id) == self.selected.as_ref())
                                .and_then(|chat| chat.bot_id.as_deref());
                            self.transcript = client::rows(&value["snapshot"], title, identity);
                            if let Some(chat) = self
                                .chats
                                .iter()
                                .find(|chat| Some(&chat.id) == self.selected.as_ref())
                            {
                                let unread =
                                    if chat.group.is_some() {
                                        value["snapshot"]["hasUnread"] == true
                                    } else {
                                        value["chats"].as_array().into_iter().flatten().any(
                                            |summary| {
                                                summary["conversationId"] == chat.id
                                                    && summary["hasUnread"] == true
                                            },
                                        )
                                    };
                                self.read_acknowledgements.observe_snapshot(
                                    self.host.as_deref().unwrap_or(""),
                                    &chat.id,
                                    chat.group.as_deref(),
                                    &value["snapshot"],
                                    unread,
                                );
                            }
                            if self.follow_bottom || near_bottom {
                                self.scroll.scroll_to_bottom();
                            }
                            self.follow_bottom = false;
                        }
                    }
                }
            }
            cx.notify();
        }
        self.read_acknowledgements.tick(
            self.connection.as_ref(),
            self.selected.as_deref(),
            self.host.as_deref(),
            window.is_window_active()
                && self.manager.is_none()
                && !self.showing_media
                && !self.showing_apps
                && !self.composer_menu_open,
        );
        if !self.showing_apps && self.last_refresh.elapsed() > Duration::from_secs(2) {
            self.refresh();
        }
    }
}
impl Render for Chats {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let inspector = self
            .manager
            .as_ref()
            .filter(|manager| manager.read(cx).is_inspector())
            .cloned();
        if let Some(manager) = &self.manager {
            if inspector.is_none() {
                return manager.clone().into_any_element();
            }
        }
        let compact_inspector = inspector.is_some() && window.bounds().size.width < px(1100.);

        if self.showing_media {
            return self.media_view(cx).into_any_element();
        }
        if self.showing_apps {
            return self.apps_view(cx).into_any_element();
        }
        let query = self.search.read(cx).value().to_lowercase();
        let is_group = self
            .chats
            .iter()
            .any(|chat| Some(&chat.id) == self.selected.as_ref() && chat.group.is_some());
        let title = self
            .chats
            .iter()
            .find(|chat| Some(&chat.id) == self.selected.as_ref())
            .map(|chat| chat.title.clone())
            .unwrap_or("Wonder".into());
        let pending = self
            .selected
            .as_ref()
            .and_then(|id| self.saved.chats.get(&self.draft_key(id)))
            .is_some_and(|d| d.pending.is_some());
        let can_send = self.connection.is_some()
            && self.disk.is_some()
            && !self.busy
            && !self.settings_saving
            && (pending
                || ((!self.input.read(cx).value().trim().is_empty() || self.has_attachments())
                    && self.attachments_ready()))
            && self
                .chats
                .iter()
                .any(|c| Some(&c.id) == self.selected.as_ref() && c.can_send);
        div()
            .id("wonder-chats")
            .key_context("WonderChats")
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &SearchChats, window, cx| {
                this.sidebar_hidden = false;
                this.manager = None;
                this.search
                    .update(cx, |search, cx| search.focus(window, cx));
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &FocusComposer, window, cx| {
                this.input.update(cx, |input, cx| input.focus(window, cx));
            }))
            .on_action(cx.listener(|this, _: &NewBot, window, cx| {
                this.manage(management::Page::Bot(None), window, cx)
            }))
            .on_action(cx.listener(|this, _: &NewGroup, window, cx| {
                this.manage(management::Page::Group, window, cx)
            }))
            .on_action(
                cx.listener(|this, _: &ToggleSidebar, window, cx| this.toggle_sidebar(window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &NextChat, window, cx| this.move_chat(true, window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &PreviousChat, window, cx| this.move_chat(false, window, cx)),
            )
            .size_full()
            .flex()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(
                div()
                    .w(px(256.))
                    .flex_shrink_0()
                    .bg(cx.theme().sidebar)
                    .h_full()
                    .flex()
                    .flex_col()
                    .when(compact_inspector || self.sidebar_hidden, |v| v.hidden())
                    .border_r_1()
                    .border_color(cx.theme().border)
                    .child(
                        div()
                            .h(px(56.))
                            .px_3()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(div().font_weight(FontWeight::SEMIBOLD).child("Chats"))
                            .child(self.new_chat_menu(cx)),
                    )
                    .child(
                        div()
                            .px_3()
                            .pb_3()
                            .child(Input::new(&self.search).prefix(IconName::Search)),
                    )
                    .when(
                        !self.chats.iter().any(|chat| chat_matches(chat, &query)),
                        |view| {
                            view.child(
                                div()
                                    .px_4()
                                    .py_3()
                                    .text_sm()
                                    .text_color(cx.theme().muted_foreground)
                                    .child(if query.is_empty() {
                                        "No conversations yet"
                                    } else {
                                        "No matching chats"
                                    }),
                            )
                        },
                    )
                    .child(
                        div().id("chats").flex_1().overflow_y_scroll().children(
                            self.chats
                                .iter()
                                .filter(|chat| chat_matches(chat, &query))
                                .map(|chat| {
                                    let id = chat.id.clone();
                                    div().mx_2().py(px(2.)).child(
                                        Button::new(SharedString::from(id.clone()))
                                            .ghost()
                                            .accessibility_label(chat.title.clone())
                                            .child(science_avatar(
                                                &chat.title,
                                                chat.bot_id.as_deref().unwrap_or(&chat.id),
                                                chat.avatar_shape.as_deref(),
                                                chat.avatar_palette.as_deref(),
                                                chat.avatar_color.as_deref(),
                                                32.,
                                            ))
                                            .child(
                                                div()
                                                    .flex_1()
                                                    .min_w_0()
                                                    .flex()
                                                    .flex_col()
                                                    .items_start()
                                                    .gap_1()
                                                    .child(
                                                        div()
                                                            .font_weight(FontWeight::SEMIBOLD)
                                                            .w_full()
                                                            .overflow_hidden()
                                                            .text_ellipsis()
                                                            .child(chat.title.clone()),
                                                    )
                                                    .child(
                                                        div()
                                                            .text_sm()
                                                            .text_color(cx.theme().muted_foreground)
                                                            .w_full()
                                                            .overflow_hidden()
                                                            .text_ellipsis()
                                                            .child(chat.preview.clone()),
                                                    ),
                                            )
                                            .w_full()
                                            .h(px(56.))
                                            .justify_start()
                                            .selected(self.selected.as_ref() == Some(&chat.id))
                                            .on_click(cx.listener(move |this, _, window, cx| {
                                                this.select(id.clone(), window, cx)
                                            })),
                                    )
                                }),
                        ),
                    )
                    .child(
                        div()
                            .p_2()
                            .flex()
                            .flex_wrap()
                            .gap_1()
                            .border_t_1()
                            .border_color(cx.theme().border)
                            .child(
                                Button::new("manage-bots")
                                    .ghost()
                                    .label("Manage Bots")
                                    .disabled(self.host.is_none())
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.manage(management::Page::Bots(false), window, cx)
                                    })),
                            )
                            .child(
                                Button::new("connected-apps")
                                    .ghost()
                                    .label("Apps")
                                    .disabled(self.host.is_none())
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.showing_apps = true;
                                        this.refresh_apps(false, false);
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .px_5()
                            .h(px(56.))
                            .flex_shrink_0()
                            .border_b_1()
                            .border_color(cx.theme().border)
                            .flex()
                            .items_center()
                            .gap_3()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(
                                Button::new("toggle-sidebar")
                                    .ghost()
                                    .icon(IconName::PanelLeft)
                                    .accessibility_label("Toggle chats sidebar")
                                    .tooltip("Toggle chats sidebar")
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.toggle_sidebar(window, cx)
                                    })),
                            )
                            .when(self.selected.is_some(), |v| {
                                v.child(science_avatar(
                                    &title,
                                    self.chats
                                        .iter()
                                        .find(|c| Some(&c.id) == self.selected.as_ref())
                                        .map(|c| c.bot_id.as_deref().unwrap_or(&c.id))
                                        .unwrap_or("chat"),
                                    self.chats
                                        .iter()
                                        .find(|c| Some(&c.id) == self.selected.as_ref())
                                        .and_then(|c| c.avatar_shape.as_deref()),
                                    self.chats
                                        .iter()
                                        .find(|c| Some(&c.id) == self.selected.as_ref())
                                        .and_then(|c| c.avatar_palette.as_deref()),
                                    self.chats
                                        .iter()
                                        .find(|c| Some(&c.id) == self.selected.as_ref())
                                        .and_then(|c| c.avatar_color.as_deref()),
                                    28.,
                                ))
                            })
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .overflow_hidden()
                                    .text_ellipsis()
                                    .child(title.clone()),
                            )
                            .when(
                                self.chats.iter().any(|c| {
                                    Some(&c.id) == self.selected.as_ref()
                                        && (c.bot_id.is_some() || c.group.is_some())
                                }),
                                |v| {
                                    v.child(
                                        Button::new("chat-details")
                                            .ghost()
                                            .label("Details")
                                            .selected(inspector.is_some())
                                            .on_click(cx.listener(|this, _, window, cx| {
                                                if this.manager.as_ref().is_some_and(|manager| {
                                                    manager.read(cx).is_inspector()
                                                }) {
                                                    this.manager = None;
                                                    this.input.update(cx, |input, cx| {
                                                        input.focus(window, cx)
                                                    });
                                                    cx.notify();
                                                    return;
                                                }
                                                if let Some(chat) = this
                                                    .chats
                                                    .iter()
                                                    .find(|c| Some(&c.id) == this.selected.as_ref())
                                                    .cloned()
                                                {
                                                    if chat.group.is_some() || chat.bot_id.is_some()
                                                    {
                                                        this.manage(
                                                            management::Page::Details(
                                                                management::Scope {
                                                                    kind: if chat.group.is_some() {
                                                                        "group_chat".into()
                                                                    } else {
                                                                        "bot".into()
                                                                    },
                                                                    id: chat
                                                                        .group
                                                                        .clone()
                                                                        .or(chat.bot_id.clone())
                                                                        .unwrap_or_default(),
                                                                    conversation: chat.id,
                                                                    title: chat.title,
                                                                    bot_id: chat
                                                                        .bot_id
                                                                        .unwrap_or_default(),
                                                                },
                                                            ),
                                                            window,
                                                            cx,
                                                        );
                                                    }
                                                }
                                            })),
                                    )
                                },
                            ),
                    )
                    .child(
                        div()
                            .on_children_prepainted(
                                self.read_acknowledgements
                                    .layout_listener(self.scroll.clone(), self.transcript.len()),
                            )
                            .id("transcript")
                            .track_scroll(&self.scroll)
                            .flex_1()
                            .overflow_y_scroll()
                            .p_6()
                            .flex()
                            .flex_col()
                            .gap_5()
                            .items_center()
                            .when(self.selected.is_none(), |v| {
                                v.child("Choose a chat to continue.")
                            })
                            .children(self.transcript.iter().enumerate().map(
                                |(row_index, row)| {
                                    let outgoing = row.outgoing;
                                    let author = &row.author;
                                    let text = &row.text;
                                    div()
                                        .id(("message-accessibility", row_index))
                                        .role(Role::Label)
                                        .aria_value(format!(
                                            "{}: {}",
                                            if outgoing { "You" } else { author.as_str() },
                                            markdown::accessible_text(text)
                                        ))
                                        .w_full()
                                        .max_w(px(760.))
                                        .flex()
                                        .when(outgoing, |v| v.justify_end())
                                        .child(
                                            div()
                                                .max_w(px(640.))
                                                .min_w_0()
                                                .flex()
                                                .flex_col()
                                                .gap_2()
                                                .when(
                                                    appearance::show_speaker(
                                                        is_group,
                                                        &self.transcript,
                                                        row_index,
                                                    ),
                                                    |v| {
                                                        v.child(
                                                            div()
                                                                .flex()
                                                                .items_center()
                                                                .gap_2()
                                                                .child(science_avatar(
                                                                    author,
                                                                    row.identity.as_deref().unwrap_or(author),
                                                                    self.bots
                                                                        .as_array()
                                                                        .into_iter()
                                                                        .flatten()
                                                                        .find(|b| {
                                                                            b["id"].as_str()
                                                                                == row
                                                                                    .identity
                                                                                    .as_deref()
                                                                        })
                                                                        .and_then(|b| {
                                                                            b["avatarShape"]
                                                                                .as_str()
                                                                        }),
                                                                    self.bots
                                                                        .as_array()
                                                                        .into_iter()
                                                                        .flatten()
                                                                        .find(|b| {
                                                                            b["id"].as_str()
                                                                                == row
                                                                                    .identity
                                                                                    .as_deref()
                                                                        })
                                                                        .and_then(|b| {
                                                                            b["avatarPalette"]
                                                                                .as_str()
                                                                        }),
                                                                    self.bots
                                                                        .as_array()
                                                                        .into_iter()
                                                                        .flatten()
                                                                        .find(|b| {
                                                                            b["id"].as_str()
                                                                                == row
                                                                                    .identity
                                                                                    .as_deref()
                                                                        })
                                                                        .and_then(|b| {
                                                                            b["avatarColor"]
                                                                                .as_str()
                                                                        }),
                                                                    24.,
                                                                ))
                                                                .child(
                                                                    div()
                                                                        .text_sm()
                                                                        .font_weight(
                                                                            FontWeight::SEMIBOLD,
                                                                        )
                                                                        .child(author.clone()),
                                                                ),
                                                        )
                                                    },
                                                )
                                                .when(row.status, |v| {
                                                    v.child(
                                                        div()
                                                            .text_sm()
                                                            .font_weight(FontWeight::SEMIBOLD)
                                                            .child(author.clone()),
                                                    )
                                                })
                                                .when(!text.is_empty(), |v| {
                                                    v.child(
                                                        div()
                                                            .rounded_lg()
                                                            .when(!row.status, |v| {
                                                                v.px_4().py_3().bg(if outgoing {
                                                                    cx.theme().muted
                                                                } else {
                                                                    cx.theme().sidebar
                                                                })
                                                            })
                                                            .child(if outgoing || row.status {
                                                                div()
                                                                    .child(text.clone())
                                                                    .into_any_element()
                                                            } else {
                                                                TextView::markdown(
                                                                    ("message-markdown", row_index),
                                                                    markdown::safe_markdown(text),
                                                                )
                                                                .on_link_click(|url, _, _, cx| {
                                                                    if markdown::web_link(url) {
                                                                        cx.open_url(url);
                                                                    }
                                                                })
                                                                .into_any_element()
                                                            }),
                                                    )
                                                }),
                                        )
                                },
                            )),
                    )
                    .child(self.files_view(cx))
                    .child(self.question_view(cx))
                    .when_some(self.error.clone(), |v, error| {
                        v.child(
                            div()
                                .px_6()
                                .py_2()
                                .text_color(cx.theme().danger)
                                .child(error),
                        )
                    })
                    .when(self.selected.is_some(), |v| {
                        v.child(
                            div().w_full().px_6().pb_5().flex().justify_center().child(
                                div()
                                    .w_full()
                                    .max_w(px(760.))
                                    .p_2()
                                    .rounded_xl()
                                    .bg(cx.theme().muted)
                                    .flex()
                                    .flex_col()
                                    .gap_2()
                                    .child(self.attachment_chips(cx))
                                    .child(
                                        div()
                                            .flex()
                                            .w_full()
                                            .items_end()
                                            .gap_3()
                                            .child(
                                                Button::new("attach-files")
                                                    .label("Attach")
                                                    .disabled(!self.can_attach())
                                                    .on_click(cx.listener(
                                                        |this, _, window, cx| {
                                                            this.choose_attachments(window, cx)
                                                        },
                                                    )),
                                            )
                                            .child(
                                                Textarea::new(&self.input)
                                                    .aria_label("Message")
                                                    .flex_1(),
                                            )
                                            .child(
                                                Button::new("send")
                                                    .primary()
                                                    .label(if pending {
                                                        "Check delivery"
                                                    } else {
                                                        "Send"
                                                    })
                                                    .disabled(!can_send)
                                                    .on_click(
                                                        cx.listener(|this, _, _, cx| this.send(cx)),
                                                    ),
                                            ),
                                    )
                                    .child(self.composer_settings(cx)),
                            ),
                        )
                    }),
            )
            .when_some(inspector, |view, manager| {
                view.child(
                    div()
                        .w(px(360.))
                        .flex_shrink_0()
                        .h_full()
                        .border_l_1()
                        .border_color(cx.theme().border)
                        .child(manager),
                )
            })
            .into_any_element()
    }
}
#[cfg(target_os = "macos")]
actions!(wonder, [OpenSettings]);

const CHAT_CLIENT: bool = true;
struct DesktopShell {
    open_chats: Option<fn(&mut App)>,
    #[cfg(target_os = "macos")]
    _menu: menu_bar::MenuBar,
    chats: Option<WindowHandle<Root>>,
    #[cfg(target_os = "macos")]
    settings: Option<WindowHandle<Root>>,
    #[cfg(target_os = "macos")]
    settings_model: Entity<mac_settings::MacSettings>,
}
impl Global for DesktopShell {}
fn open_chats(cx: &mut App) {
    cx.activate(true);
    if let Some(window) = cx.global::<DesktopShell>().chats {
        if window
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
        {
            return;
        }
    }
    let bounds = Bounds::centered(None, size(px(1100.), px(760.)), cx);
    let handle = cx
        .open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                window_min_size: Some(size(px(780.), px(520.))),
                ..Default::default()
            },
            |window, cx| {
                window.set_window_title("Wonder Chats");
                let view = cx.new(|cx| Chats::new(window, cx));
                cx.new(|cx| Root::new(view, window, cx))
            },
        )
        .expect("Open Wonder Chats");
    cx.global_mut::<DesktopShell>().chats = Some(handle);
}
#[cfg(target_os = "macos")]
fn open_settings(cx: &mut App) {
    if mac_settings::route_setup(cx) {
        return;
    }
    cx.activate(true);
    if let Some(window) = cx.global::<DesktopShell>().settings {
        if window
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
        {
            return;
        }
    }
    let model = cx.global::<DesktopShell>().settings_model.clone();
    let bounds = Bounds::centered(None, size(px(640.), px(700.)), cx);
    match cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            window_min_size: Some(size(px(620.), px(480.))),
            ..Default::default()
        },
        |window, cx| {
            window.set_window_title("Wonder Settings");
            window.focus(&model.read(cx).focus.clone(), cx);
            cx.new(|cx| Root::new(model, window, cx))
        },
    ) {
        Ok(handle) => cx.global_mut::<DesktopShell>().settings = Some(handle),
        Err(error) => menu_bar::show_error(&error.to_string()),
    }
}
fn main() {
    let application = gpui_kit::application().with_assets(gpui_kit::assets::Assets);
    application.on_reopen(open_chats);
    application.run(|cx| {
        gpui_kit::init(cx);
        appearance::init(cx);
        cx.bind_keys([
            KeyBinding::new("cmd-k", SearchChats, Some("WonderChats")),
            KeyBinding::new("cmd-n", NewBot, Some("WonderChats")),
            KeyBinding::new("cmd-shift-n", NewGroup, Some("WonderChats")),
            KeyBinding::new("cmd-l", FocusComposer, Some("WonderChats")),
            KeyBinding::new("cmd-shift-l", ToggleSidebar, Some("WonderChats")),
            KeyBinding::new("cmd-alt-down", NextChat, Some("WonderChats")),
            KeyBinding::new("cmd-alt-up", PreviousChat, Some("WonderChats")),
        ]);
        #[cfg(target_os = "macos")]
        {
            cx.bind_keys([KeyBinding::new("cmd-,", OpenSettings, None)]);
            cx.on_action(|_: &OpenSettings, cx| open_settings(cx));
        }
        #[cfg(target_os = "macos")]
        let settings_model = cx.new(mac_settings::MacSettings::new);
        cx.set_global(DesktopShell {
            open_chats: Some(open_chats),
            #[cfg(target_os = "macos")]
            _menu: menu_bar::MenuBar::new(),
            chats: None,
            #[cfg(target_os = "macos")]
            settings: None,
            #[cfg(target_os = "macos")]
            settings_model,
        });
        #[cfg(not(target_os = "macos"))]
        cx.on_window_closed(|cx, _| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        open_chats(cx);
        cx.spawn(async move |cx| loop {
            cx.background_executor()
                .timer(Duration::from_millis(150))
                .await;
            cx.update(|cx| {
                let reopen = std::env::var("WONDER_SERVICE_DIR")
                    .ok()
                    .map(|path| std::path::Path::new(&path).join("open-chats"));
                if let Some(path) = reopen.filter(|path| path.exists()) {
                    if std::fs::remove_file(path).is_ok() {
                        open_chats(cx);
                    }
                }
                #[cfg(target_os = "macos")]
                {
                    let refresh = std::env::var("WONDER_SERVICE_DIR")
                        .ok()
                        .map(|path| std::path::Path::new(&path).join("refresh-menu"));
                    let refresh_menu = refresh
                        .filter(|path| path.exists())
                        .is_some_and(|path| std::fs::remove_file(path).is_ok());
                    let shell = cx.global_mut::<DesktopShell>();
                    if refresh_menu {
                        shell._menu = menu_bar::MenuBar::new();
                    }
                    if let Ok(service) = std::env::var("WONDER_SERVICE_DIR") {
                        let directory = std::path::Path::new(&service);
                        if directory.join("open-settings").exists()
                            && std::fs::remove_file(directory.join("open-settings")).is_ok()
                        {
                            open_settings(cx);
                        }
                        if directory.join("update-ready").exists()
                            && directory.join("stopped").exists()
                        {
                            cx.quit();
                            return;
                        }
                    }
                    let actions = menu_bar::pending();
                    if actions & menu_bar::QUIT != 0 {
                        cx.quit();
                        return;
                    }
                    if actions & menu_bar::OPEN != 0 {
                        open_chats(cx);
                    }

                    if actions & menu_bar::SETTINGS != 0 {
                        open_settings(cx);
                    }
                }
            });
        })
        .detach();
    });
}

fn chat_matches(chat: &Chat, query: &str) -> bool {
    query.trim().is_empty()
        || chat.title.to_lowercase().contains(query.trim())
        || chat.preview.to_lowercase().contains(query.trim())
}
