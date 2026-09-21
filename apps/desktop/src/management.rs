mod assignments;
mod drafts;
mod group_settings;
mod locations;
mod views;
use crate::{
    automation_form,
    client::Connection,
    forms::{choices, Choice, Form},
    science_avatar,
};
use gpui_kit::{
    component::{button::*, checkbox::Checkbox, *},
    prelude::FluentBuilder,
    *,
};
use serde_json::{json, Value};
use std::{path::PathBuf, sync::mpsc, time::Duration};

#[derive(Clone)]
pub struct Scope {
    pub kind: String,
    pub id: String,
    pub conversation: String,
    pub title: String,
    pub bot_id: String,
}
#[derive(Clone)]
pub enum Page {
    Bots(bool),
    Bot(Option<String>),
    Group,
    GroupEdit(String),
    GroupBot(String, String),
    Details(Scope),
    Assignments(Scope),
    Assignment(Scope, String),
    Automations(Scope),
    Automation(Scope, Option<String>),
    Runs(Scope, String),
    FileAccess(String),
    Confirm {
        title: String,
        explanation: String,
        name: Option<String>,
        method: String,
        path: Vec<String>,
        body: Value,
        completion: String,
    },
}
pub enum Event {
    Close,
    Open(String),
}
struct Reply {
    kind: &'static str,
    result: Result<Value, String>,
}
pub struct Manager {
    connection: Connection,
    host: String,
    pending_path: PathBuf,
    page: Page,
    detail_scope: Option<Scope>,
    return_page: Option<Page>,
    bots: Vec<Value>,
    groups: Vec<Value>,
    automations: Vec<Value>,
    options: Value,
    options_path: Vec<String>,
    model_selection: String,
    options_error: Option<String>,
    drafts: Option<drafts::Drafts>,
    drafts_error: Option<String>,
    last_draft_snapshot: Option<Value>,
    form: Form,
    locations: locations::Locations,
    bot_advanced: bool,
    subscriptions: Vec<Subscription>,
    members: Vec<String>,
    days: Vec<String>,
    original_schedule: Option<(String, String)>,
    loaded: bool,
    busy: bool,
    error: Option<String>,
    notice: Option<String>,
    preview: Option<Value>,
    preview_key: Option<String>,
    runs: Vec<Value>,
    pending: Option<Value>,
    file_access: Value,
    assignments: assignments::Assignments,
    sender: mpsc::Sender<Reply>,
    receiver: mpsc::Receiver<Reply>,
}
impl EventEmitter<Event> for Manager {}
fn strv<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
fn route(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|v| (*v).into()).collect()
}
fn timestamp(value: &Value) -> String {
    value
        .as_str()
        .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
        .map(|time| {
            time.with_timezone(&chrono::Local)
                .format("%b %-d, %-I:%M %p")
                .to_string()
        })
        .unwrap_or_else(|| "Not yet".into())
}
fn schedule_timestamp(value: &Value, timezone: &str) -> String {
    match (
        value
            .as_str()
            .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok()),
        timezone.parse::<chrono_tz::Tz>(),
    ) {
        (Some(time), Ok(zone)) => time
            .with_timezone(&zone)
            .format("%b %-d, %-I:%M %p %Z")
            .to_string(),
        _ => timestamp(value),
    }
}

impl Manager {
    pub fn is_inspector(&self) -> bool {
        self.detail_scope.is_some() && matches!(self.page, Page::Details(_))
    }

    pub fn new(
        connection: Connection,
        host: String,
        pending_path: PathBuf,
        page: Page,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let (sender, receiver) = mpsc::channel();
        let pending = match std::fs::read(&pending_path) {
            Ok(bytes) => {
                Some(serde_json::from_slice::<Value>(&bytes).unwrap_or(json!({"invalid":true})))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => Some(json!({"invalid":true})),
        };
        let loaded_drafts =
            drafts::Drafts::load(pending_path.with_file_name("management-drafts.json"));
        let drafts_error = loaded_drafts.as_ref().err().cloned();
        let mut this = Self {
            connection,
            host,
            pending_path,
            detail_scope: match &page {
                Page::Details(scope) => Some(scope.clone()),
                _ => None,
            },
            page,
            return_page: None,
            bots: vec![],
            groups: vec![],
            automations: vec![],
            options: Value::Null,
            options_path: route(&["api", "v1", "bot-options"]),
            model_selection: String::new(),
            options_error: None,
            drafts: loaded_drafts.ok(),
            drafts_error,
            last_draft_snapshot: None,
            form: Form::default(),
            locations: locations::Locations::default(),
            bot_advanced: false,
            subscriptions: vec![],
            members: vec![],
            days: vec![],
            original_schedule: None,
            loaded: false,
            busy: false,
            error: None,
            notice: None,
            preview: None,
            preview_key: None,
            runs: vec![],
            pending,
            file_access: Value::Null,
            assignments: assignments::Assignments::default(),
            sender,
            receiver,
        };
        if this.pending.is_some() {
            this.notice=Some("A previous change is waiting for confirmation. Check the saved request before making another change.".into());
        }
        this.load();
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
        this
    }
    fn load(&mut self) {
        if self.busy {
            return;
        }
        self.busy = true;
        let connection = self.connection.clone();
        let sender = self.sender.clone();
        let host = self.host.clone();
        std::thread::spawn(move || {
            let result = (|| {
                if connection.get(&["api", "v1", "host", "status"])?["hostInstallationId"] != host {
                    return Err("Mac identity changed. Reopen Chats from Wonder.".into());
                }
                let bots = connection.get(&["api", "v1", "bots"])?;
                let groups = connection.get(&["api", "v1", "channels"])?;
                let automations = connection.get(&["api", "v1", "automations"])?;
                let options = connection.get(&["api", "v1", "bot-options"]);
                Ok(
                    json!({"bots":bots,"groups":groups,"automations":automations,"options":options.as_ref().ok(),"optionsError":options.err()}),
                )
            })();
            let _ = sender.send(Reply {
                kind: "load",
                result,
            });
        });
    }
    fn open(&mut self, page: Page, window: &mut Window, cx: &mut Context<Self>) {
        self.persist_draft(cx);
        self.last_draft_snapshot = None;
        if matches!(page, Page::Confirm { .. } | Page::FileAccess(_)) {
            self.return_page = Some(self.page.clone());
        }
        self.bot_advanced = matches!(page, Page::Bot(Some(_)));
        self.page = page;
        self.error = None;
        self.notice = None;
        self.preview = None;
        self.original_schedule = None;
        self.form = Form::default();
        self.locations = locations::Locations::default();
        self.file_access = Value::Null;
        self.members.clear();
        self.subscriptions.clear();
        match self.page.clone() {
            Page::Bot(id) => {
                let value = id
                    .as_ref()
                    .and_then(|id| self.bots.iter().find(|b| b["id"] == *id).cloned())
                    .unwrap_or(Value::Null);
                for (key, default) in [("name", ""), ("role", "")] {
                    self.form
                        .input(key, value[key].as_str().unwrap_or(default), window, cx);
                }
                let identity = value["id"].as_str().unwrap_or("new-bot");
                let shape = if id.is_some() {
                    science_avatar::picker_shape(value["avatarShape"].as_str(), identity)
                } else {
                    "sun".into()
                };
                let mut shapes = science_avatar::Shape::ALL
                    .into_iter()
                    .map(|shape| Choice {
                        id: shape.id().into(),
                        label: shape.title().into(),
                    })
                    .collect::<Vec<_>>();
                if !shapes.iter().any(|choice| choice.id == shape) {
                    shapes.push(Choice {
                        id: shape.clone(),
                        label: format!("{shape} (saved, unavailable)"),
                    });
                }
                self.form.select("avatarShape", &shape, shapes, window, cx);
                let palette = if id.is_some() {
                    science_avatar::picker_palette(
                        value["avatarPalette"].as_str(),
                        value["avatarColor"].as_str(),
                    )
                } else {
                    "amber".into()
                };
                let mut palettes = science_avatar::PALETTES
                    .into_iter()
                    .map(|palette| Choice {
                        id: palette.id.into(),
                        label: palette.name.into(),
                    })
                    .collect::<Vec<_>>();
                if !palettes.iter().any(|choice| choice.id == palette) {
                    palettes.push(Choice {
                        id: palette.clone(),
                        label: format!("{palette} (saved, unavailable)"),
                    });
                }
                self.form
                    .select("avatarPalette", &palette, palettes, window, cx);
                let approval = value["approvalMode"].as_str().or_else(|| {
                    (value["permissionMode"].as_str() == Some("full-access"))
                        .then_some("full-access")
                }).unwrap_or("ask-for-approval");
                self.form.select(
                    "approvalMode",
                    approval,
                    choices(&[
                        ("ask-for-approval", "Ask for approval"),
                        ("approve-for-me", "Approve for me"),
                        ("full-access", "Full access"),
                    ]),
                    window,
                    cx,
                );
                // Retain legacy scope in saved forms without exposing its old
                // picker. New approval choices are the only visible controls.
                self.form.select("permissionMode", value["permissionMode"].as_str().unwrap_or(""), choices(&[("", ""), ("read-only", "Read-only"), ("workspace", "Workspace"), ("full-access", "Full access")]), window, cx);
                self.form
                    .text("systemPrompt", strv(&value, "systemPrompt"), window, cx);
                self.model_fields(&value, false, window, cx);
                // Working locations are chosen only from the Bot's existing grants.
                if let Some(id) = value["id"].as_str() {
                    self.fetch_access(id.to_owned(), "workingLocations");
                } else {
                    self.update_creation_folder(None, window, cx);
                }
            }
            Page::GroupBot(_, bot) => self.open_group_bot(&bot, window, cx),
            Page::GroupEdit(id) => {
                if let Some(group) = self.groups.iter().find(|g| g["id"] == id) {
                    self.form.input("name", strv(group, "name"), window, cx);
                    self.form
                        .text("description", strv(group, "description"), window, cx);
                    let members = group["members"].as_array().cloned().unwrap_or_default();
                    let choices = members
                        .iter()
                        .filter(|m| {
                            self.bots
                                .iter()
                                .any(|b| b["id"] == m["botId"] && b["isArchived"] != true)
                        })
                        .map(|m| Choice {
                            id: strv(m, "botId").into(),
                            label: strv(m, "botName").into(),
                        })
                        .collect();
                    self.form.select(
                        "coordinator",
                        strv(group, "coordinatorBotId"),
                        choices,
                        window,
                        cx,
                    );
                }
            }
            Page::Group => {
                self.form.input("name", "", window, cx);
                self.form.text("description", "", window, cx);
                self.form
                    .select("coordinator", "", self.bot_choices(), window, cx);
            }
            Page::Automation(scope, id) => {
                let value = id
                    .and_then(|id| self.automations.iter().find(|a| a["id"] == id).cloned())
                    .unwrap_or(Value::Null);
                self.days = automation_form::populate(
                    &mut self.form,
                    &value,
                    self.options["timezone"].as_str().unwrap_or(""),
                    window,
                    cx,
                );
                if let Some(rule) = value["rrule"].as_str() {
                    if let Ok(projected) = automation_form::schedule(&self.form, &self.days, cx) {
                        self.original_schedule = Some((rule.into(), projected));
                    }
                }
                if scope.kind == "group_chat" {
                    self.form.select(
                        "kind",
                        "continuation",
                        choices(&[("continuation", "Continue this Group Chat")]),
                        window,
                        cx,
                    );
                }
                self.model_fields(&value, true, window, cx);
            }
            Page::Assignments(scope) => {
                self.assignments.rows.clear();
                self.fetch_assignments(&scope.id, None);
            }
            Page::Assignment(scope, id) => {
                self.assignments.detail = Value::Null;
                self.form.text("validation", "", window, cx);
                self.fetch_assignments(&scope.id, Some(&id));
            }
            Page::Runs(_, id) => self.fetch_runs(id),
            Page::FileAccess(id) => self.fetch_access(id, "access"),
            Page::Confirm { name: Some(_), .. } => self.form.input("confirmation", "", window, cx),
            _ => {}
        }
        self.restore_draft(window, cx);
        self.subscriptions = self.form.observe(cx, Self::form_changed);
        if self.options_path != self.approval_options_path() && !self.busy {
            self.retry_options(cx);
        }
        cx.notify();
    }
    fn form_changed(&mut self, cx: &mut Context<Self>) {
        self.persist_draft(cx);
        cx.notify();
    }
    fn persist_draft(&mut self, cx: &App) {
        if (self.form.is_empty()
            && (!matches!(self.page, Page::FileAccess(_)) || self.file_access.is_null()))
            || self.pending.is_some()
        {
            return;
        }
        let Some(key) = self.draft_key() else {
            return;
        };
        let value = json!({"fields":self.form.snapshot(cx),"days":self.days,"members":self.members,"locations":self.locations});
        if self.last_draft_snapshot.as_ref() == Some(&value) {
            return;
        }
        if let Some(drafts) = &mut self.drafts {
            match drafts.put(&key, value.clone()) {
                Ok(()) => {
                    self.last_draft_snapshot = Some(value);
                    self.drafts_error = None;
                }
                Err(e) => self.drafts_error = Some(e),
            }
        }
    }
    fn restore_draft(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let value = self
            .draft_key()
            .and_then(|key| self.drafts.as_ref()?.get(&key).cloned());
        if let Some(mut value) = value {
            if value["fields"]["approvalMode"].is_null() && value["fields"]["permissionMode"] == "full-access" {
                value["fields"]["approvalMode"] = json!("full-access");
            }
            if let Some(locations) = locations::Locations::from_draft(&value) {
                self.locations = locations;
            }
            if matches!(self.page, Page::Bot(None)) {
                self.update_creation_folder(
                    value["fields"]["workingDirectory"].as_str(),
                    window,
                    cx,
                );
            }
            self.form.restore(&value["fields"], window, cx);
            if let Ok(days) = serde_json::from_value(value["days"].clone()) {
                self.days = days;
            }
            if let Ok(members) = serde_json::from_value(value["members"].clone()) {
                self.members = members;
            }
        }
        self.last_draft_snapshot = Some(
            json!({"fields":self.form.snapshot(cx),"days":self.days,"members":self.members,"locations":self.locations}),
        );
    }
    fn discard_draft(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.pending.is_some() {
            return;
        }
        if let (Some(key), Some(drafts)) = (self.draft_key(), &mut self.drafts) {
            if let Err(e) = drafts.remove(&key) {
                self.drafts_error = Some(e);
                cx.notify();
                return;
            }
        }
        let back = match &self.page {
            Page::Automation(scope, _) => Page::Automations(scope.clone()),
            _ => Page::Bots(false),
        };
        self.form = Form::default();
        self.file_access = Value::Null;
        self.locations = locations::Locations::default();
        self.open(back, window, cx);
    }
    fn close(&mut self, cx: &mut Context<Self>) {
        self.persist_draft(cx);
        cx.emit(Event::Close);
    }
    fn retry_options(&mut self, cx: &mut Context<Self>) {
        if self.busy { return; }
        self.options_path = self.approval_options_path();
        self.options = Value::Null;
        self.background(
            "options",
            "GET",
            self.options_path.clone(),
            Value::Null,
        );
        cx.notify();
    }
    fn approval_options_path(&self) -> Vec<String> {
        if let Page::Bot(Some(id)) | Page::GroupBot(_, id) = &self.page {
            // A missing conversation must fail closed, not use a different
            // Bot's/global workspace boundary for existing read-only Bots.
            let conversation = self.bots.iter().find(|bot| bot["id"] == *id)
                .and_then(|bot| bot["conversationId"].as_str()).unwrap_or(id);
            route(&["api", "v1", "conversations", conversation, "composer-options"])
        } else { route(&["api", "v1", "bot-options"]) }
    }
    fn model_fields(
        &mut self,
        value: &Value,
        automation: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mut value = value.clone();
        if let Some(draft) = self
            .draft_key()
            .and_then(|key| self.drafts.as_ref()?.get(&key))
        {
            for (field, key) in [
                (if automation { "modelId" } else { "model" }, "model"),
                ("reasoningEffort", "reasoningEffort"),
                ("serviceTier", "serviceTier"),
            ] {
                if let Some(saved) = draft["fields"][key].as_str() {
                    value[field] = json!(saved);
                }
            }
        }
        let mut models = choices(&[("", "Bot default")]);
        if !automation {
            models[0].label = "Default model".into();
        }
        for model in self.options["models"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|m| m["hidden"] != true)
        {
            models.push(Choice {
                id: strv(model, "id").into(),
                label: model["displayName"]
                    .as_str()
                    .unwrap_or(strv(model, "id"))
                    .into(),
            });
        }
        let model = value[if automation { "modelId" } else { "model" }]
            .as_str()
            .unwrap_or("");
        if !model.is_empty() && !models.iter().any(|m| m.id == model) {
            models.push(Choice {
                id: model.into(),
                label: format!("{model} (saved)"),
            });
        }
        self.form.select("model", model, models, window, cx);
        self.model_selection = model.into();
        let mut efforts = choices(&[("", "Default")]);
        let mut tiers = choices(&[("", "Default")]);
        for model in self.options["models"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|m| m["id"] == self.model_selection)
        {
            for (key, list) in [
                ("reasoningEfforts", &mut efforts),
                ("serviceTiers", &mut tiers),
            ] {
                for v in model[key].as_array().into_iter().flatten() {
                    let id = strv(v, "id");
                    if !list.iter().any(|c| c.id == id) {
                        list.push(Choice {
                            id: id.into(),
                            label: v["label"].as_str().unwrap_or(id).into(),
                        });
                    }
                }
            }
        }
        for (key, mut list) in [("reasoningEffort", efforts), ("serviceTier", tiers)] {
            let saved = strv(&value, key);
            if !saved.is_empty() && !list.iter().any(|c| c.id == saved) {
                list.push(Choice {
                    id: saved.into(),
                    label: format!("{saved} (saved)"),
                });
            }
            self.form.select(key, saved, list, window, cx);
        }
    }
    fn bot_choices(&self) -> Vec<Choice> {
        self.bots
            .iter()
            .filter(|b| b["isArchived"] != true)
            .map(|b| Choice {
                id: strv(b, "id").into(),
                label: strv(b, "name").into(),
            })
            .collect()
    }
    fn scope(&self, bot: &Value) -> Scope {
        Scope {
            kind: "bot".into(),
            id: strv(bot, "id").into(),
            conversation: strv(bot, "conversationId").into(),
            title: strv(bot, "name").into(),
            bot_id: strv(bot, "id").into(),
        }
    }
    fn write(
        &mut self,
        method: &str,
        path: Vec<String>,
        body: Value,
        completion: &str,
        cx: &mut Context<Self>,
    ) {
        if self.busy || self.pending.is_some() {
            return;
        }
        let mut pending = json!({"host":self.host,"method":method,"path":path,"body":body,"completion":completion,"draftKey":self.draft_key()});
        if let Page::Assignment(scope, id) = &self.page {
            pending["assignmentGroupId"] = json!(scope.id);
            pending["assignmentId"] = json!(id);
        }
        if let Err(error) = save_pending(&self.pending_path, &pending) {
            self.error = Some(error);
            cx.notify();
            return;
        }
        self.pending = Some(pending);
        self.retry(cx);
    }
    fn retry(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(pending) = self.pending.clone() else {
            self.load();
            return;
        };
        if pending["invalid"] == true {
            self.error=Some("The saved change could not be read. It has been preserved. Resolve the saved request file before making another change.".into());
            cx.notify();
            return;
        }
        if pending["host"] != self.host {
            self.error =
                Some("The saved change belongs to another Mac. Reopen Wonder on that Mac.".into());
            cx.notify();
            return;
        }
        if pending["completion"] == "assignment" {
            self.retry_assignment(pending, cx);
            return;
        }
        let path: Vec<String> = serde_json::from_value(pending["path"].clone()).unwrap_or_default();
        let connection = self.connection.clone();
        let sender = self.sender.clone();
        let host = self.host.clone();
        self.busy = true;
        self.error = None;
        std::thread::spawn(move || {
            let result =
                connection.request(strv(&pending, "method"), &path, &pending["body"], &host);
            let _ = sender.send(Reply {
                kind: "write",
                result,
            });
        });
        cx.notify();
    }
    fn schedule(&self, cx: &App) -> Result<String, String> {
        let rule = automation_form::schedule(&self.form, &self.days, cx)?;
        Ok(self
            .original_schedule
            .as_ref()
            .filter(|(_, projected)| *projected == rule)
            .map(|(original, _)| original.clone())
            .unwrap_or(rule))
    }
    fn has_current_preview(&self, cx: &App) -> bool {
        self.schedule(cx).ok().is_some_and(|rule| {
            current_preview(
                self.preview.as_ref(),
                self.preview_key.as_deref(),
                &rule,
                &self.form.value("timezone", cx),
            )
        })
    }
    fn preview_schedule(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let rule = match self.schedule(cx) {
            Ok(v) => v,
            Err(e) => {
                self.error = Some(e);
                cx.notify();
                return;
            }
        };
        if self.form.value("timezone", cx).trim().is_empty() {
            self.error = Some("Enter a time zone, or retry loading Mac options.".into());
            cx.notify();
            return;
        }
        let body = json!({"rrule":rule,"timezone":self.form.value("timezone",cx)});
        self.preview = None;
        self.preview_key = Some(format!("{}:{}", body["rrule"], body["timezone"]));
        self.background(
            "preview",
            "POST",
            route(&["api", "v1", "automations", "preview"]),
            body,
        );
        cx.notify();
    }
    fn background(
        &mut self,
        kind: &'static str,
        method: &'static str,
        path: Vec<String>,
        body: Value,
    ) {
        if self.busy {
            return;
        }
        self.busy = true;
        self.error = None;
        let connection = self.connection.clone();
        let sender = self.sender.clone();
        let host = self.host.clone();
        std::thread::spawn(move || {
            let result = connection.request(method, &path, &body, &host);
            let _ = sender.send(Reply { kind, result });
        });
    }
    fn update_creation_folder(
        &mut self,
        preferred: Option<&str>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !matches!(self.page, Page::Bot(None)) {
            return;
        }
        let selected = preferred
            .map(str::to_owned)
            .unwrap_or_else(|| self.form.value("workingDirectory", cx));
        let mut options = choices(&[("", "Workspace")]);
        options.extend(self.locations.folders().into_iter().map(|path| Choice {
            id: path.clone(),
            label: path,
        }));
        let selected = if options.iter().any(|o| o.id == selected) {
            selected
        } else {
            String::new()
        };
        self.form
            .select("workingDirectory", &selected, options, window, cx);
    }
    fn choose_locations(&mut self, write: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy || self.pending.is_some() {
            return;
        }
        let page_key = self.draft_key();
        let receiver = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: true,
            multiple: true,
            prompt: Some(
                if write {
                    "Choose files or folders for read and write access"
                } else {
                    "Choose files or folders for read-only access"
                }
                .into(),
            ),
        });
        cx.spawn_in(window, async move |view, cx| {
            let result = receiver.await;
            let _ = view.update_in(cx, |this, window, cx| {
                if drafts::key(&this.host, &this.page) != page_key {
                    return;
                }
                match result {
                    Ok(Ok(Some(paths))) => {
                        let paths: Option<Vec<String>> = paths
                            .iter()
                            .map(|p| p.to_str().map(str::to_owned))
                            .collect();
                        match paths
                            .ok_or("A selected location’s name could not be saved.".to_owned())
                            .and_then(|paths| this.locations.add(paths, write))
                        {
                            Ok(()) => {
                                this.error = None;
                                this.update_creation_folder(None, window, cx);
                                this.subscriptions = this.form.observe(cx, Self::form_changed);
                                this.form_changed(cx);
                            }
                            Err(error) => this.error = Some(error),
                        }
                    }
                    Ok(Ok(None)) => {}
                    _ => {
                        this.error = Some(
                            "The file picker could not open. Try choosing locations again.".into(),
                        )
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
    fn remove_location(
        &mut self,
        path: &str,
        write: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.busy || self.pending.is_some() {
            return;
        }
        self.locations.remove(path, write);
        self.error = None;
        self.update_creation_folder(None, window, cx);
        self.subscriptions = self.form.observe(cx, Self::form_changed);
        self.form_changed(cx);
    }
    fn fetch_runs(&mut self, id: String) {
        self.runs.clear();
        self.background(
            "runs",
            "GET",
            route(&["api", "v1", "automations", &id, "runs"]),
            Value::Null,
        );
    }
    fn fetch_access(&mut self, id: String, kind: &'static str) {
        self.background(
            kind,
            "GET",
            route(&["api", "v1", "bots", &id, "file-access"]),
            Value::Null,
        );
    }
    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.loaded
            && !self.busy
            && self.pending.is_none()
            && matches!(
                self.page,
                Page::Bot(_) | Page::GroupBot(_, _) | Page::Automation(_, _)
            )
        {
            let model = self.form.value("model", cx);
            if model != self.model_selection {
                self.model_selection = model.clone();
                for (field, list_key) in [
                    ("reasoningEffort", "reasoningEfforts"),
                    ("serviceTier", "serviceTiers"),
                ] {
                    let current = self.form.value(field, cx);
                    let mut options = choices(&[("", "Default")]);
                    for option in self.options["models"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .find(|m| m["id"] == model)
                        .into_iter()
                        .flat_map(|m| m[list_key].as_array().into_iter().flatten())
                    {
                        options.push(Choice {
                            id: strv(option, "id").into(),
                            label: option["label"]
                                .as_str()
                                .unwrap_or(strv(option, "id"))
                                .into(),
                        });
                    }
                    let selected = if !matches!(self.page, Page::GroupBot(_, _))
                        && options.iter().any(|o| o.id == current)
                    {
                        current
                    } else {
                        String::new()
                    };
                    self.form.select(field, &selected, options, window, cx);
                }
                self.subscriptions = self.form.observe(cx, Self::form_changed);
                cx.notify();
            }
        }
        if self.preview.is_some()
            && matches!(self.page, Page::Automation(_, _))
            && !self.has_current_preview(cx)
        {
            self.preview = None;
            cx.notify();
        }
        self.poll_assignments();
        while let Ok(reply) = self.receiver.try_recv() {
            self.busy = false;
            match reply.result {
                Err(error) => {
                    if reply.kind == "options" {
                        self.options_error = Some(error.trim_start_matches("Rejected: ").into());
                    }
                    if let Some(message) = error.strip_prefix("Rejected: ") {
                        if reply.kind == "write" && self.preserve_rejected_integration(message, cx)
                        {
                            continue;
                        }
                        if reply.kind == "write" {
                            match std::fs::remove_file(&self.pending_path) {
                                Ok(()) => self.pending = None,
                                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                                    self.pending = None
                                }
                                Err(_) => {
                                    self.error=Some("The Mac rejected this change, but its saved request could not be cleared.".into());
                                    cx.notify();
                                    continue;
                                }
                            }
                        }
                        self.error = Some(message.into());
                    } else {
                        self.error = Some(error);
                    }
                }
                Ok(value) => match reply.kind {
                    "load" => {
                        self.bots = value["bots"].as_array().cloned().unwrap_or_default();
                        self.groups = value["groups"].as_array().cloned().unwrap_or_default();
                        self.automations =
                            value["automations"].as_array().cloned().unwrap_or_default();
                        self.options = value["options"].clone();
                        self.options_path = route(&["api", "v1", "bot-options"]);
                        self.options_error = value["optionsError"].as_str().map(str::to_owned);
                        if !self.loaded {
                            self.loaded = true;
                            self.open(self.page.clone(), window, cx);
                        } else if self.options_path != self.approval_options_path() {
                            self.retry_options(cx);
                        }
                    }
                    "write" => {
                        let completion = self
                            .pending
                            .as_ref()
                            .map(|p| strv(p, "completion").to_owned())
                            .unwrap_or_default();
                        if let Err(error) = std::fs::remove_file(&self.pending_path) {
                            if error.kind() != std::io::ErrorKind::NotFound {
                                self.error=Some("Change completed, but its saved confirmation could not be cleared. Close and reopen Wonder before making another change.".into());
                                cx.notify();
                                continue;
                            }
                        }
                        if let (Some(key), Some(drafts)) = (
                            self.pending.as_ref().and_then(|p| p["draftKey"].as_str()),
                            &mut self.drafts,
                        ) {
                            if let Err(e) = drafts.remove(key) {
                                self.drafts_error = Some(e);
                            }
                        }
                        self.pending = None;
                        self.last_draft_snapshot = Some(
                            json!({"fields":self.form.snapshot(cx),"days":self.days,"members":self.members,"locations":self.locations}),
                        );
                        self.notice = Some("Saved".into());
                        match completion.as_str() {
                            "group-bot" => {
                                if let Some(bot) =
                                    self.bots.iter_mut().find(|b| b["id"] == value["id"])
                                {
                                    *bot = value.clone();
                                }
                                self.load();
                            }
                            "open" => {
                                if let Some(id) = value["conversationId"].as_str() {
                                    cx.emit(Event::Open(id.into()));
                                } else {
                                    self.page = Page::Bots(false);
                                    self.load();
                                }
                            }
                            "archive" => {
                                self.page = Page::Bots(false);
                                self.load();
                            }
                            "delete" => {
                                self.page = Page::Bots(true);
                                self.load();
                            }
                            "automation" => {
                                if let Page::Automation(scope, _) = &self.page {
                                    self.page = Page::Automations(scope.clone());
                                }
                                self.load();
                            }
                            "run" => {
                                self.notice = Some("Run requested".into());
                                self.load();
                            }
                            "assignment" => {
                                if let Some(scope) = self.assignment_scope(strv(&value, "groupId"))
                                {
                                    self.open(
                                        Page::Assignment(scope, strv(&value, "id").into()),
                                        window,
                                        cx,
                                    );
                                }
                            }
                            "access" => {
                                if let Page::FileAccess(id) = self.page.clone() {
                                    self.fetch_access(id, "access");
                                }
                            }
                            _ => {
                                if matches!(self.page, Page::Confirm { .. }) {
                                    self.page =
                                        self.return_page.take().unwrap_or(Page::Bots(false));
                                }
                                self.load();
                            }
                        }
                    }
                    "options" => {
                        self.options = value;
                        self.options_error = None;
                        self.open(self.page.clone(), window, cx);
                    }
                    "assignment-list" | "assignment-detail" | "assignment-reconsider" => {
                        self.receive_assignments(reply.kind, value, window, cx);
                    }
                    "preview" => self.preview = Some(value),
                    "runs" => self.runs = value.as_array().cloned().unwrap_or_default(),
                    "access" => {
                        self.file_access = value.clone();
                        self.locations =
                            serde_json::from_value(value["access"].clone()).unwrap_or_default();
                        self.restore_draft(window, cx);
                        self.subscriptions = self.form.observe(cx, Self::form_changed);
                    }
                    "workingLocations" => {
                        self.file_access = value.clone();
                        let saved = if let Page::Bot(Some(id)) = &self.page {
                            self.bots
                                .iter()
                                .find(|b| b["id"] == *id)
                                .and_then(|b| b["workingDirectory"].as_str())
                                .filter(|path| !path.is_empty())
                                .map(str::to_owned)
                                .unwrap_or_else(|| strv(&value, "workspacePath").to_owned())
                        } else {
                            strv(&value, "workspacePath").to_owned()
                        };
                        let mut locations = Vec::new();
                        if !saved.is_empty() {
                            locations.push(Choice {
                                id: saved.clone(),
                                label: "Workspace".into(),
                            });
                        }
                        for v in ["readRoots", "writeRoots"]
                            .into_iter()
                            .flat_map(|key| value["access"][key].as_array().into_iter().flatten())
                            .filter_map(Value::as_str)
                            .filter(|path| std::path::Path::new(path).is_dir())
                        {
                            if !locations.iter().any(|choice| choice.id == v) {
                                locations.push(Choice {
                                    id: v.into(),
                                    label: v.into(),
                                });
                            }
                        }
                        self.form
                            .select("workingDirectory", &saved, locations, window, cx);
                        self.restore_draft(window, cx);
                        self.subscriptions = self.form.observe(cx, Self::form_changed);
                    }
                    _ => {}
                },
            }
            if !self.busy && self.options_path != self.approval_options_path() {
                self.retry_options(cx);
            }
            cx.notify();
        }
    }
    fn draft_key(&self) -> Option<String> {
        if let Page::Assignment(scope, id) = &self.page {
            return assignments::review_draft_key(
                &self.host,
                &scope.id,
                id,
                &self.assignments.detail,
            );
        }
        drafts::key(&self.host, &self.page)
    }
    fn submit(&mut self, cx: &mut Context<Self>) {
        self.error = None;
        let result = self.body(cx);
        match result {
            Ok((method, path, body, completion)) => self.write(method, path, body, completion, cx),
            Err(error) => {
                self.error = Some(error);
                cx.notify();
            }
        }
    }
    fn body(&self, cx: &App) -> Result<(&'static str, Vec<String>, Value, &'static str), String> {
        let value = |key| self.form.value(key, cx);
        match &self.page {
            Page::GroupBot(group, bot) => self.group_bot_body(group, bot, cx),
            Page::Bot(id) => {
                let name = value("name");
                let role = value("role");
                let prompt = value("systemPrompt");
                let selected_shape = value("avatarShape");
                let selected_palette = value("avatarPalette");
                if name.trim().is_empty() || name.len() > 80 {
                    return Err("Enter a Bot name up to 80 characters.".into());
                }
                if role.trim().is_empty() || role.len() > 160 {
                    return Err("Describe this Bot’s purpose in 160 characters or fewer.".into());
                }
                if prompt.len() > 8000 {
                    return Err("Keep instructions within 8,000 characters.".into());
                }
                let existing = id.as_ref().and_then(|bot_id| {
                    self.bots.iter().find(|bot| bot["id"] == *bot_id)
                });
                let identity = id.as_deref().unwrap_or("new-bot");
                let initial_shape = existing
                    .map(|bot| {
                        science_avatar::picker_shape(bot["avatarShape"].as_str(), identity)
                    })
                    .unwrap_or_else(|| "sun".into());
                let initial_palette = existing
                    .map(|bot| {
                        science_avatar::picker_palette(
                            bot["avatarPalette"].as_str(),
                            bot["avatarColor"].as_str(),
                        )
                    })
                    .unwrap_or_else(|| "amber".into());
                if (id.is_none() || selected_shape != initial_shape)
                    && science_avatar::Shape::from_id(&selected_shape).is_none()
                {
                    return Err("Choose a character for this Bot.".into());
                }
                if (id.is_none() || selected_palette != initial_palette)
                    && science_avatar::palette(&selected_palette).is_none()
                {
                    return Err("Choose a color palette for this Bot.".into());
                }
                let mut body = json!({"name":name.trim(),"role":role.trim(),"systemPrompt":if prompt.trim().is_empty(){role.trim()}else{prompt.trim()}});
                science_avatar::add_avatar_fields(
                    &mut body,
                    id.is_none(),
                    &initial_shape,
                    &initial_palette,
                    &selected_shape,
                    &selected_palette,
                );
                for key in ["model", "reasoningEffort", "serviceTier"] {
                    let v = value(key);
                    if id.is_none() && !v.is_empty() {
                        body[key] = json!(v);
                    }
                }
                let approval = value("approvalMode");
                if id.is_none() && approval.is_empty() {
                    return Err("Choose an approval setting.".into());
                }
                let existing_approval = id.as_ref().and_then(|bot_id| {
                    self.bots.iter().find(|bot| bot["id"] == *bot_id).map(|bot| {
                        bot["approvalMode"].as_str().filter(|value| !value.is_empty())
                            .or_else(|| (bot["permissionMode"].as_str() == Some("full-access")).then_some("full-access"))
                            .unwrap_or("ask-for-approval")
                            .to_owned()
                    })
                });
                let approval_changed = id.is_none() || existing_approval.as_deref() != Some(approval.as_str());
                if approval_changed {
                    if !self.options["approvalModes"].is_array() {
                        return Err("Update Wonder on your Mac to change approval settings, then try again.".into());
                    }
                    if !self.options["approvalModes"].as_array().is_some_and(|modes| {
                        modes.iter().any(|mode| mode["id"] == approval && mode["allowed"] == true)
                    }) {
                        return Err("This approval choice is unavailable under your Mac’s settings. Choose another option.".into());
                    }
                    body["approvalMode"] = json!(approval);
                }
                if id.is_none() && approval != "full-access" {
                    let legacy_scope = value("permissionMode");
                    if !legacy_scope.is_empty() {
                        body["permissionMode"] = json!(legacy_scope);
                    }
                }
                let working = value("workingDirectory");
                if !working.is_empty() {
                    body["workingDirectory"] = json!(working);
                }
                if id.is_none() {
                    body["readRoots"] = json!(self.locations.read_roots);
                    body["writeRoots"] = json!(self.locations.write_roots);
                    body["clientRequestId"] = json!(uuid::Uuid::new_v4().to_string());
                }
                Ok((
                    if id.is_some() { "PATCH" } else { "POST" },
                    if let Some(id) = id {
                        route(&["api", "v1", "bots", id])
                    } else {
                        route(&["api", "v1", "bots"])
                    },
                    body,
                    "open",
                ))
            }
            Page::GroupEdit(id) => {
                let name = value("name");
                let coordinator = value("coordinator");
                if name.trim().is_empty() || name.len() > 80 {
                    return Err("Enter a Group Chat name up to 80 characters.".into());
                }
                if coordinator.is_empty() {
                    return Err("Choose an active coordinating Bot.".into());
                }
                Ok((
                    "PATCH",
                    route(&["api", "v1", "group-chats", id]),
                    json!({"name":name.trim(),"description":value("description"),"coordinatorBotId":coordinator}),
                    "open",
                ))
            }
            Page::Group => {
                let name = value("name");
                let coordinator = value("coordinator");
                if name.trim().is_empty() || name.len() > 80 {
                    return Err("Enter a Group Chat name up to 80 characters.".into());
                }
                if coordinator.is_empty() {
                    return Err("Choose a coordinating Bot.".into());
                }
                Ok((
                    "POST",
                    route(&["api", "v1", "channels"]),
                    json!({"name":name.trim(),"description":value("description"),"coordinatorBotId":coordinator,"memberBotIds":self.members,"clientRequestId":uuid::Uuid::new_v4().to_string()}),
                    "open",
                ))
            }
            Page::Automation(scope, id) => {
                let name = value("name");
                let prompt = value("prompt");
                if name.trim().is_empty() || prompt.trim().is_empty() {
                    return Err("Enter a name and instructions for the automation.".into());
                }
                let rule = self.schedule(cx)?;
                if !self.has_current_preview(cx) {
                    return Err("Preview the next run before saving this schedule.".into());
                }
                let kind = value("kind");
                let bot_id = if scope.kind == "group_chat" {
                    self.groups
                        .iter()
                        .find(|g| g["id"] == scope.id)
                        .and_then(|g| g["coordinatorBotId"].as_str())
                        .unwrap_or(&scope.bot_id)
                } else {
                    &scope.bot_id
                };
                let existing = id
                    .as_ref()
                    .and_then(|id| self.automations.iter().find(|a| a["id"] == *id));
                let conversation = continuation_target(&kind, existing, &scope.conversation);
                let mut body = json!({"name":name.trim(),"prompt":prompt.trim(),"kind":kind,"rrule":rule,"timezone":value("timezone"),"conversationId":conversation});
                for (field, key) in [("modelId", "model"), ("reasoningEffort", "reasoningEffort")] {
                    let v = value(key);
                    if scope.kind != "group_chat" {
                        body[field] = if id.is_some() || !v.is_empty() {
                            json!(v)
                        } else {
                            Value::Null
                        };
                    }
                }
                if id.is_none() {
                    body["botId"] = json!(bot_id);
                    body["scopeType"] = json!(scope.kind);
                    body["scopeId"] = json!(scope.id);
                    body["status"] = json!("active");
                    body["clientRequestId"] = json!(uuid::Uuid::new_v4().to_string());
                }
                Ok((
                    if id.is_some() { "PATCH" } else { "POST" },
                    if let Some(id) = id {
                        route(&["api", "v1", "automations", id])
                    } else {
                        route(&["api", "v1", "automations"])
                    },
                    body,
                    "automation",
                ))
            }
            Page::FileAccess(id) => Ok((
                "PUT",
                route(&["api", "v1", "bots", id, "file-access"]),
                json!({"revision":self.file_access["access"]["revision"],"readRoots":self.locations.read_roots,"writeRoots":self.locations.write_roots}),
                "access",
            )),
            _ => Err("Choose a form to save.".into()),
        }
    }
}

fn save_pending(path: &std::path::Path, value: &Value) -> Result<(), String> {
    use std::io::Write;
    let temporary = path.with_extension("tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temporary)
        .map_err(|_| "Couldn’t save this change. No request was sent.")?;
    file.write_all(&serde_json::to_vec(value).map_err(|e| e.to_string())?)
        .and_then(|_| file.sync_all())
        .map_err(|_| "Couldn’t save this change. No request was sent.")?;
    std::fs::rename(temporary, path)
        .map_err(|_| "Couldn’t save this change. No request was sent.".into())
}

fn current_preview(preview: Option<&Value>, key: Option<&str>, rule: &str, timezone: &str) -> bool {
    preview.is_some_and(|p| p["nextRunAt"].as_str().is_some())
        && key == Some(format!("{}:{}", json!(rule), json!(timezone)).as_str())
}
fn continuation_target<'a>(
    kind: &str,
    existing: Option<&'a Value>,
    current: &'a str,
) -> Option<&'a str> {
    if kind != "continuation" {
        return None;
    }
    existing
        .filter(|a| a["kind"] == "continuation")
        .and_then(|a| a["conversationId"].as_str())
        .or(Some(current))
}

#[cfg(test)]
mod tests {
    use super::{current_preview, save_pending};
    use serde_json::{json, Value};
    #[test]
    fn preview_must_match_rule_and_timezone_and_have_a_next_run() {
        let key = format!("{}:{}", json!("FREQ=DAILY"), json!("America/New_York"));
        let preview = json!({"nextRunAt":"2026-09-09T13:00:00Z"});
        assert!(current_preview(
            Some(&preview),
            Some(&key),
            "FREQ=DAILY",
            "America/New_York"
        ));
        assert!(!current_preview(
            Some(&preview),
            Some(&key),
            "FREQ=WEEKLY",
            "America/New_York"
        ));
        assert!(!current_preview(
            Some(&preview),
            Some(&key),
            "FREQ=DAILY",
            "UTC"
        ));
        assert!(!current_preview(
            Some(&Value::Null),
            Some(&key),
            "FREQ=DAILY",
            "America/New_York"
        ));
        assert!(!current_preview(
            None,
            Some(&key),
            "FREQ=DAILY",
            "America/New_York"
        ));
    }
    #[test]
    fn editing_continuation_keeps_its_original_conversation() {
        let existing = json!({"kind":"continuation","conversationId":"original"});
        assert_eq!(
            super::continuation_target("continuation", Some(&existing), "currently-open"),
            Some("original")
        );
        assert_eq!(
            super::continuation_target("continuation", None, "currently-open"),
            Some("currently-open")
        );
        let standalone = json!({"kind":"standalone","conversationId":"separate"});
        assert_eq!(
            super::continuation_target("continuation", Some(&standalone), "currently-open"),
            Some("currently-open")
        );
        assert_eq!(
            super::continuation_target("standalone", Some(&existing), "currently-open"),
            None
        );
    }
    #[test]
    fn scheduled_time_uses_selected_zone_and_daylight_saving() {
        assert_eq!(
            super::schedule_timestamp(&json!("2026-09-08T13:00:00.000Z"), "America/New_York"),
            "Sep 8, 9:00 AM EDT"
        );
        assert_eq!(
            super::schedule_timestamp(&json!("2026-12-08T14:00:00Z"), "America/New_York"),
            "Dec 8, 9:00 AM EST"
        );
    }
    #[test]
    fn saved_mutation_preserves_request_identity_and_payload() {
        let path =
            std::env::temp_dir().join(format!("wonder-management-{}.json", uuid::Uuid::new_v4()));
        let pending = json!({"host":"host","method":"POST","path":["api","v1","bots"],"body":{"clientRequestId":"stable","name":"Ada"}});
        save_pending(&path, &pending).unwrap();
        let restored: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(restored, pending);
        std::fs::remove_file(path).unwrap();
    }
}
