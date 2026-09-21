use gpui_kit::{
    component::{button::*, checkbox::Checkbox, *},
    prelude::FluentBuilder,
    *,
};
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    process::{Child, Command, Stdio},
    sync::{mpsc, Arc},
    time::{Duration, Instant},
};

mod permission_drag;
mod setup_window;
mod voice;

actions!(
    wonder_settings,
    [
        StatusSettings,
        DeviceSettings,
        AccessSettings,
        DictationSettings
    ]
);

#[derive(Clone, Copy, PartialEq)]
enum Page {
    Status,
    Devices,
    Access,
    Dictation,
    About,
}

struct Bridge {
    child: Child,
    sender: mpsc::Sender<Value>,
    receiver: mpsc::Receiver<Result<Value, String>>,
}
impl Bridge {
    fn start() -> Result<Self, String> {
        let path = std::env::current_exe()
            .map_err(|e| e.to_string())?
            .with_file_name("WonderMacBridge");
        let mut child = Command::new(path)
            .arg("--bridge")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|_| {
                "Mac settings couldn’t start. Reopen the installed Wonder app.".to_owned()
            })?;
        let mut stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, requests) = mpsc::channel::<Value>();
        let (responses, receiver) = mpsc::channel();
        let errors = responses.clone();
        std::thread::spawn(move || {
            for request in requests {
                if writeln!(stdin, "{request}")
                    .and_then(|_| stdin.flush())
                    .is_err()
                {
                    let _ = errors.send(Err(
                        "Mac settings stopped responding. Quit and reopen Wonder before trying again."
                            .into(),
                    ));
                    break;
                }
            }
        });
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let result = line
                    .map_err(|_| "Mac settings stopped responding.".to_owned())
                    .and_then(|line| {
                        serde_json::from_str(&line)
                            .map_err(|_| "Mac settings returned an unreadable response.".into())
                    });
                if responses.send(result).is_err() {
                    return;
                }
            }
            let _ = responses.send(Err(
                "Mac settings closed. Quit and reopen Wonder to restore settings.".into(),
            ));
        });
        Ok(Self {
            child,
            sender,
            receiver,
        })
    }
}
impl Drop for Bridge {
    fn drop(&mut self) {
        // Closing stdin lets the bridge cancel its native operations. The shell's
        // process-group cleanup remains the fallback on a forced app shutdown.
        let _ = self.child.try_wait();
    }
}

pub struct MacSettings {
    pub focus: FocusHandle,
    bridge: Option<Bridge>,
    state: Value,
    page: Page,
    pending: Option<(String, Instant)>,
    error: Option<String>,
    received: bool,
    open_when_ready: bool,
    setup_window: Option<WindowHandle<Root>>,
    connected: bool,
    qr_id: String,
    qr: Option<Arc<Image>>,
    revoke: Option<(String, String)>,
    revoked_expanded: bool,
    device_details: Option<String>,
    connection_details: bool,
    selected_folder: Option<String>,
    permission_drag_id: String,
    permission_drag_window: Option<WindowHandle<Root>>,
    folder_picker_busy: bool,
    last_clock: Instant,
    voice: voice::VoiceSettings,
}
impl MacSettings {
    pub fn new(cx: &mut Context<Self>) -> Self {
        cx.bind_keys([
            KeyBinding::new("cmd-1", StatusSettings, Some("WonderSettings")),
            KeyBinding::new("cmd-2", DeviceSettings, Some("WonderSettings")),
            KeyBinding::new("cmd-3", AccessSettings, Some("WonderSettings")),
            KeyBinding::new("cmd-4", DictationSettings, Some("WonderSettings")),
        ]);
        let (bridge, error) = match Bridge::start() {
            Ok(b) => (Some(b), None),
            Err(e) => (None, Some(e)),
        };
        cx.spawn(async move |this, cx| loop {
            cx.background_executor()
                .timer(Duration::from_millis(150))
                .await;
            if this.update(cx, |this, cx| this.tick(cx)).is_err() {
                break;
            }
        })
        .detach();
        Self {
            focus: cx.focus_handle(),
            bridge,
            state: Value::Null,
            page: Page::Status,
            pending: None,
            error,
            received: false,
            open_when_ready: false,
            setup_window: None,
            connected: false,
            qr_id: String::new(),
            qr: None,
            revoke: None,
            revoked_expanded: false,
            device_details: None,
            connection_details: false,
            selected_folder: None,
            permission_drag_id: String::new(),
            permission_drag_window: None,
            folder_picker_busy: false,
            last_clock: Instant::now(),
            voice: voice::VoiceSettings::default(),
        }
    }
    fn select_page(&mut self, page: Page, cx: &mut Context<Self>) {
        self.page = page;
        if page == Page::Dictation {
            self.voice.refresh();
        }
        self.revoke = None;

        cx.notify();
    }
    fn tick(&mut self, cx: &mut Context<Self>) {
        let mut changed = self.voice.tick(
            self.page == Page::Dictation
                || (!self.flag("setupCompleted") && self.state["setupStep"] == 5),
        );
        while let Some(result) = self
            .bridge
            .as_ref()
            .and_then(|b| b.receiver.try_recv().ok())
        {
            changed = true;
            match result {
                Ok(state) => {
                    let drag_id = text(&state["permissionDrag"], "id");
                    if drag_id != self.permission_drag_id {
                        self.permission_drag_id = drag_id.to_owned();
                        if let Some(handle) = self.permission_drag_window.take() {
                            let _ = handle.update(cx, |_, window, _| window.remove_window());
                        }
                        if !drag_id.is_empty() {
                            let request = state["permissionDrag"].clone();
                            let model = cx.entity();
                            cx.defer(move |cx| permission_drag::open(model, request, cx));
                        }
                    }
                    let first = !self.received;
                    self.received = true;
                    self.connected = true;
                    if self
                        .pending
                        .as_ref()
                        .is_some_and(|(id, _)| state["acknowledged"] == *id)
                    {
                        self.pending = None;
                    }
                    let id = text(&state["offer"], "id");
                    if id != self.qr_id {
                        self.qr_id = id.to_owned();
                        self.qr = state["offer"]["qr"].as_array().and_then(|bytes| {
                            let bytes: Option<Vec<u8>> = bytes
                                .iter()
                                .map(|b| b.as_u64().and_then(|b| u8::try_from(b).ok()))
                                .collect();
                            bytes
                                .filter(|b| !b.is_empty() && b.len() < 1_000_000)
                                .map(|b| Arc::new(Image::from_bytes(ImageFormat::Png, b)))
                        });
                    }
                    if self.revoke.as_ref().is_some_and(|(id, _)| {
                        array(&state, "devices")
                            .iter()
                            .any(|device| device["id"] == *id && device["revoked"] == true)
                    }) {
                        self.revoke = None;
                    }
                    let finished_setup = self.received
                        && self.state["setupCompleted"] == false
                        && state["setupCompleted"] == true;
                    self.state = state;
                    if first && !self.flag("setupCompleted") {
                        let model = cx.entity();
                        cx.defer(move |cx| setup_window::open(model, cx));
                    } else if finished_setup {
                        if let Some(handle) = self.setup_window.take() {
                            let _ = handle.update(cx, |_, window, _| window.remove_window());
                        }
                        cx.defer(crate::open_settings);
                    } else if first && self.open_when_ready {
                        cx.defer(crate::open_settings);
                    }
                    if first {
                        self.open_when_ready = false;
                    }
                }
                Err(error) => {
                    // Losing another process with our bundle identity can unregister
                    // the status item; keep the GPUI launcher available for recovery.
                    cx.defer(|cx| {
                        cx.global_mut::<crate::DesktopShell>()._menu =
                            crate::menu_bar::MenuBar::new()
                    });
                    self.error = Some(error);
                    self.connected = false;
                    self.pending = None;
                }
            }
        }
        if self
            .pending
            .as_ref()
            .is_some_and(|(_, at)| at.elapsed() > Duration::from_secs(45))
        {
            self.pending = None;
            self.connected = false;
            self.error = Some("This change could not be confirmed. Quit and reopen Wonder and review its state before trying again.".into());
            changed = true;
        }
        if (self.page == Page::Devices || !self.flag("setupCompleted"))
            && self.last_clock.elapsed() >= Duration::from_secs(1)
            && (self.state["offer"].is_object() || !array(&self.state, "pending").is_empty())
        {
            self.last_clock = Instant::now();
            changed = true;
        }
        if changed {
            cx.notify();
        }
    }
    fn send(&mut self, mut command: Value, cx: &mut Context<Self>) {
        if self.pending.is_some() || !self.connected {
            return;
        }
        let id = uuid::Uuid::new_v4().to_string();
        command["id"] = json!(id);
        self.error = None;
        if self
            .bridge
            .as_ref()
            .is_some_and(|bridge| bridge.sender.send(command).is_ok())
        {
            self.pending = Some((id, Instant::now()));
        } else {
            self.error = Some("Mac settings are unavailable. Quit and reopen Wonder.".into());
            self.connected = false;
        }
        cx.notify();
    }
    fn retry(&mut self, cx: &mut Context<Self>) {
        if self.connected {
            self.send(json!({"action":"refresh"}), cx);
            return;
        }
        self.bridge = None;
        match Bridge::start() {
            Ok(bridge) => {
                self.bridge = Some(bridge);
                self.error = None;
                self.received = false;
                self.pending = None;
            }
            Err(error) => self.error = Some(error),
        }
        cx.notify();
    }
    fn flag(&self, key: &str) -> bool {
        self.state[key] == true
    }
    fn disabled(&self) -> bool {
        !self.connected || self.pending.is_some() || self.flag("busy")
    }
    fn action(
        &self,
        id: impl Into<SharedString>,
        label: impl Into<SharedString>,
        command: Value,
        disabled: bool,
        cx: &Context<Self>,
    ) -> Button {
        Button::new(id.into())
            .flex_shrink_0()
            .self_start()
            .label(label.into())
            .disabled(self.disabled() || disabled)
            .on_click(cx.listener(move |this, _, _, cx| this.send(command.clone(), cx)))
    }
    fn toggle(
        &self,
        id: &'static str,
        label: &'static str,
        key: &str,
        action: &'static str,
        cx: &Context<Self>,
    ) -> Checkbox {
        Checkbox::new(id)
            .label(label)
            .checked(self.flag(key))
            .disabled(self.disabled())
            .on_click(cx.listener(move |this, checked, _, cx| {
                this.send(json!({"action":action,"enabled":checked}), cx)
            }))
    }
    fn general(&self, cx: &Context<Self>) -> Div {
        let local = self.flag("serviceRunning");
        let remote = self.flag("remoteReady");
        let ready = self.flag("ready") && remote && self.connected;
        let mut status = stack()
            .gap_2()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().size(px(8.)).rounded_full().bg(if ready {
                        cx.theme().success
                    } else {
                        cx.theme().warning
                    }))
                    .child(
                        note(if ready {
                            "Wonder is ready"
                        } else {
                            "Wonder needs attention"
                        })
                        .role(Role::Heading)
                        .text_xl()
                        .font_weight(FontWeight::SEMIBOLD),
                    ),
            )
            .child(note(text(&self.state, "hostName")).text_color(cx.theme().muted_foreground))
            .child(row(
                "Local service",
                if !self.connected {
                    "Unavailable"
                } else if local {
                    "Running"
                } else {
                    "Unavailable"
                },
            ));
        if !self.flag("ready") {
            status = status.child(note(if local {
                "Wonder can’t run Bot requests yet. Try restarting services."
            } else {
                "The local service isn’t responding. Try restarting services."
            }));
        }
        let mut actions = div().flex().gap_2().pt_2();
        if let Some(open_chats) = cx.global::<crate::DesktopShell>().open_chats {
            actions = actions.child(
                Button::new("open-wonder")
                    .label("Open Wonder")
                    .on_click(move |_, _, cx| open_chats(cx)),
            );
        }
        actions = actions.child(self.action(
            "restart",
            "Restart services",
            json!({"action":"restart"}),
            self.flag("serviceBusy"),
            cx,
        ));
        let mut remote_view = stack().gap_2().child(heading("Remote access")).child(row(
            if remote {
                "Available for paired devices."
            } else {
                "Paired devices can’t reach this Mac remotely."
            },
            remote_label(&self.state),
        ));
        if !remote {
            remote_view = remote_view.child(self.connection(cx));
        }
        remote_view = remote_view.child(
            Button::new("connection-details")
                .label(if self.connection_details {
                    "Hide connection details"
                } else {
                    "Connection details"
                })
                .ghost()
                .self_start()
                .on_click(cx.listener(|this, _, _, cx| {
                    this.connection_details = !this.connection_details;
                    cx.notify();
                })),
        );
        if self.connection_details {
            remote_view = remote_view.child(note(
                "Keep this Mac awake and online for your paired devices.",
            ));
            if !text(&self.state, "remoteOrigin").is_empty() {
                remote_view = remote_view.child(row("Address", text(&self.state, "remoteOrigin")));
            }
        }
        status = messages(
            status.child(remote_view).child(actions),
            &self.state,
            &["serviceMessage"],
            cx,
        );
        let startup = messages(
            stack().child(self.toggle("login", "Launch Wonder at login", "login", "login", cx)),
            &self.state,
            &["loginMessage"],
            cx,
        )
        .when(self.flag("loginApproval"), |v| {
            v.child(self.action(
                "login-settings",
                "Open Login Settings…",
                json!({"action":"login-settings"}),
                false,
                cx,
            ))
        });
        let updates = if self.flag("updatesAvailable") {
            stack()
                .child(self.toggle(
                    "updates",
                    "Check for updates automatically",
                    "automaticUpdates",
                    "automatic-updates",
                    cx,
                ))
                .child(self.action(
                    "check-updates",
                    "Check for updates…",
                    json!({"action":"check-updates"}),
                    false,
                    cx,
                ))
        } else {
            stack()
                .gap_1()
                .child(note("Install beta updates from signed downloads."))
                .child(self.action(
                    "download-update",
                    "Open releases",
                    json!({"action":"download-update"}),
                    false,
                    cx,
                ))
                .child(
                    note("Automatic updates unavailable").text_color(cx.theme().muted_foreground),
                )
        };
        stack()
            .gap_4()
            .child(status)
            .child(settings_section("Startup", startup, cx))
            .child(settings_section("Updates", updates, cx))
    }
    fn about(&self, _cx: &Context<Self>) -> Div {
        stack()
            .gap_4()
            .child(
                note("About Wonder")
                    .role(Role::Heading)
                    .text_xl()
                    .font_weight(FontWeight::SEMIBOLD),
            )
            .child(note(
                "A local-first messenger for your Bots and Group Chats.",
            ))
            .child(row("Version", text(&self.state, "version")))
    }
    fn connection(&self, cx: &Context<Self>) -> Div {
        stack()
            .gap_2()
            .child(note(
                "Connect this Mac and your phone to the same Tailscale network.",
            ))
            .child(note(text(&self.state, "remoteDetail")))
            .child(self.action(
                "tailscale-open",
                "Open Tailscale",
                json!({"action":"tailscale-open"}),
                false,
                cx,
            ))
            .child(self.action(
                "tailscale-configure",
                "Enable private connection",
                json!({"action":"tailscale-configure"}),
                self.flag("serviceBusy"),
                cx,
            ))
            .child(note(text(&self.state, "serviceMessage")))
    }
    fn devices(&self, cx: &Context<Self>) -> Div {
        let mut view = stack().gap_4().child(first_section(
            "This Mac",
            stack()
                .gap_1()
                .child(note(text(&self.state, "hostName")))
                .child(note("This device").text_color(cx.theme().muted_foreground)),
            cx,
        ));
        view = messages(view, &self.state, &["pairingError", "pairingMessage"], cx);
        if !text(&self.state, "pairingError").is_empty() {
            view = view.child(self.action(
                "retry-devices",
                "Try again",
                json!({"action":"refresh"}),
                self.flag("pairingBusy"),
                cx,
            ));
        }
        let mut trusted = stack().gap_1();
        let devices = array(&self.state, "devices");
        if !devices.iter().any(|phone| phone["revoked"] != true) {
            trusted = trusted.child(note(if self.flag("pairingFresh") {
                "No paired devices yet."
            } else {
                "Paired devices are unavailable."
            }));
        }
        for phone in devices.iter().filter(|phone| phone["revoked"] != true) {
            trusted = trusted.child(self.device(phone, cx));
        }
        view = view.child(settings_section("Paired devices", trusted, cx));
        let pending = array(&self.state, "pending");
        for phone in pending {
            let id = text(phone, "id");
            let disabled = self.flag("pairingBusy") || !self.flag("pairingFresh") || expired(phone);
            let request = stack().id(SharedString::from(format!("pairing-{id}"))).child(heading(format!("Connect {}?",text(phone,"label"))))
                .child(note("Match this code on your device before connecting."))
                .child(note(text(phone,"verification")).text_xl().font_weight(FontWeight::SEMIBOLD))
                .child(note(expiry(phone)))
                .child(div().flex().gap_2()
                    .child(self.action(format!("approve-{id}"),"Connect",json!({"action":"approve","key":id,"verification":phone["verification"]}),disabled,cx).primary())
                    .child(self.action(format!("reject-{id}"),"Reject",json!({"action":"reject","key":id,"verification":phone["verification"]}),disabled,cx)));
            view = view.child(request);
        }
        if pending.is_empty() {
            let offer = &self.state["offer"];
            if offer.is_object() {
                if expired(offer) || offer["expired"] == true {
                    view = view.child(note("Pairing code expired. Create a new code below."));
                } else {
                    if let Some(qr) = &self.qr {
                        view = view.child(
                            div()
                                .bg(rgb(0xffffff))
                                .p_3()
                                .w(px(204.))
                                .child(img(qr.clone()).size(px(180.))),
                        );
                    }
                    view = view
                        .child(note(
                            "Scan in Wonder on your iPhone or iPad, or copy and paste the pairing link.",
                        ))
                        .child(note(text(offer, "origin")))
                        .child(
                            note(text(offer, "code"))
                                .text_xl()
                                .font_weight(FontWeight::SEMIBOLD),
                        )
                        .child(note(expiry(offer)))
                        .child(
                            Button::new("copy-pairing")
                                .label("Copy pairing link")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    cx.write_to_clipboard(ClipboardItem::new_string(
                                        text(&this.state["offer"], "url").to_owned(),
                                    ));
                                })),
                        );
                }
            }
            view = view.child(
                self.action(
                    "pair",
                    "Pair Device",
                    json!({"action":"pair"}),
                    self.flag("pairingBusy") || !self.flag("remoteReady"),
                    cx,
                )
                .primary(),
            );
        }
        let revoked = devices
            .iter()
            .filter(|phone| phone["revoked"] == true)
            .count();
        if revoked > 0 {
            view = view.child(
                Button::new("revoked-devices")
                    .label(format!(
                        "{} revoked devices ({revoked})",
                        if self.revoked_expanded {
                            "Hide"
                        } else {
                            "Show"
                        }
                    ))
                    .ghost()
                    .self_start()
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.revoked_expanded = !this.revoked_expanded;
                        cx.notify();
                    })),
            );
            if self.revoked_expanded {
                for phone in devices.iter().filter(|phone| phone["revoked"] == true) {
                    view = view.child(self.device(phone, cx));
                }
            }
        }
        view
    }
    fn device(&self, phone: &Value, cx: &Context<Self>) -> Stateful<Div> {
        let id = text(phone, "id").to_owned();
        let label = text(phone, "label").to_owned();
        let seen = last_seen(phone);
        let mut view = stack()
            .py_3()
            .border_b_1()
            .border_color(cx.theme().border)
            .id(SharedString::from(format!("device-{id}")));
        let mut line = div().flex().items_center().justify_between().gap_3().child(
            stack()
                .flex_1()
                .child(note(label.clone()))
                .child(note(seen.clone()).text_color(cx.theme().muted_foreground)),
        );
        if phone["revoked"] != true {
            let target = id.clone();
            line = line.child(
                Button::new(SharedString::from(format!("device-details-{id}")))
                    .label("Details")
                    .accessibility_label(format!("Details for {label}, {seen}"))
                    .disabled(self.disabled() || self.flag("pairingBusy"))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.device_details = if this.device_details.as_deref() == Some(&target) {
                            None
                        } else {
                            Some(target.clone())
                        };
                        cx.notify();
                    })),
            );
        }
        if phone["revoked"] == true {
            line = line.child(
                self.action(
                    format!("forget-{id}"),
                    "",
                    json!({"action":"forget-device","key":id}),
                    self.flag("pairingBusy") || !self.flag("pairingFresh"),
                    cx,
                )
                .icon(IconName::Close)
                .ghost()
                .accessibility_label(format!("Remove {label} from revoked devices"))
                .tooltip("Remove from list"),
            );
        }
        view = view.child(line);
        if self.device_details.as_deref() == Some(&id) {
            let target = id.clone();
            let name = label.clone();
            view = view.child(
                stack()
                    .gap_2()
                    .child(row("Device name", &label))
                    .child(row("Paired", &date_label(text(phone, "pairedAt"))))
                    .child(row("Last connected", &date_label(text(phone, "lastSeen"))))
                    .child(row(
                        "Remote access",
                        if self.flag("remoteReady") {
                            "Available"
                        } else {
                            "Unavailable"
                        },
                    ))
                    .child(
                        Button::new(format!("revoke-{id}"))
                            .label("Revoke device")
                            .self_start()
                            .disabled(
                                self.disabled()
                                    || self.flag("pairingBusy")
                                    || !self.flag("pairingFresh"),
                            )
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.revoke = Some((target.clone(), name.clone()));
                                cx.notify();
                            })),
                    ),
            );
        }
        if self
            .revoke
            .as_ref()
            .is_some_and(|(selected, _)| selected == &id)
        {
            view=view.child(stack().py_2().child(heading(format!("Revoke {label}?")))
                .child(note("This ends the device’s sessions and prevents it from reconnecting. Pair it again to restore access."))
                .child(div().flex().gap_2().child(self.action("confirm-revoke","Revoke device",json!({"action":"revoke","key":id}),self.flag("pairingBusy"),cx))
                    .child(Button::new("cancel-revoke").label("Cancel").on_click(cx.listener(|this,_,_,cx|{this.revoke=None;cx.notify();})))));
        }
        view
    }
    fn add_computer_folders(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        if self.disabled() || self.folder_picker_busy {
            return;
        }
        self.folder_picker_busy = true;
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: true,
            prompt: Some("Add folders".into()),
        });
        cx.spawn(async move |view, cx| {
            let result = picker.await;
            let _ = view.update(cx, |this, cx| {
                this.folder_picker_busy = false;
                match result {
                    Ok(Ok(Some(paths))) => {
                        let paths: Option<Vec<String>> = paths
                            .iter()
                            .map(|path| path.to_str().map(str::to_owned))
                            .collect();
                        if let Some(paths) = paths {
                            this.send(json!({"action":"computer-folder-add", "paths":paths}), cx);
                        } else {
                            this.error = Some("A folder name could not be saved.".into());
                        }
                    }
                    Ok(Ok(None)) => {}
                    _ => this.error = Some("The folder picker could not open. Try again.".into()),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    fn computer_folders(&self, cx: &Context<Self>) -> Div {
        let folders = array(&self.state, "computerFolders");
        let mut list = stack().gap_0().min_h(px(100.));
        if folders.is_empty() {
            list = list.child(
                note("Add folders to prepare access before using your phone.")
                    .p_3()
                    .text_color(cx.theme().muted_foreground),
            );
        }
        for folder in folders {
            let path = text(folder, "path").to_owned();
            let selected = self.selected_folder.as_deref() == Some(path.as_str());
            let target = path.clone();
            list = list.child(
                Button::new(SharedString::from(format!("folder-{path}")))
                    .ghost()
                    .w_full()
                    .h_auto()
                    .p_3()
                    .selected(selected)
                    .accessibility_label(format!("Select folder {path}"))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected_folder = Some(target.clone());
                        cx.notify();
                    }))
                    .child(note(path).w_full()),
            );
        }
        let chosen = self
            .selected_folder
            .as_deref()
            .filter(|path| folders.iter().any(|f| text(f, "path") == *path));
        stack().child(heading("Folders"))
            .child(div().border_1().border_color(cx.theme().border).rounded_md().overflow_hidden()
                .child(div().id("computer-folder-list").max_h(px(220.)).overflow_y_scroll().child(list))
                .child(div().flex().justify_end().gap_1().p_1().border_t_1().border_color(cx.theme().border)
                    .child(Button::new("computer-folder-add").label("+").disabled(self.disabled() || self.folder_picker_busy).accessibility_label("Add folders").on_click(cx.listener(|this, _, window, cx| this.add_computer_folders(window, cx))))
                    .child(self.action("computer-folder-remove", "−", json!({"action":"computer-folder-remove","key":chosen}), self.folder_picker_busy || chosen.is_none(), cx).accessibility_label("Remove selected folder"))))
            .child(note("Includes files and subfolders. Bot permissions still apply. Removing a selection does not revoke macOS permissions.").text_sm().text_color(cx.theme().muted_foreground))
            .child(self.action("folder-privacy", "Manage folder permissions…", json!({"action":"computer-folder-settings"}), false, cx))
            .when(!text(&self.state,"computerFoldersMessage").is_empty(), |v| v.child(note(text(&self.state,"computerFoldersMessage"))))
    }
    fn mac_permissions(&self, setup: bool, cx: &Context<Self>) -> Div {
        let mut rows = stack().gap_1();
        for (action, label, key) in [
            ("screen", "Screen recording", "screen"),
            ("input", "Computer control", "input"),
            ("computer-full-disk", "Full Disk Access", "fullDisk"),
        ] {
            let status = if key == "fullDisk" {
                "Check in Settings"
            } else {
                match text(&self.state, key) {
                    "Enabled" => "Allowed",
                    "Unavailable" => "Unavailable",
                    "Checking…" => "Checking…",
                    "Needs attention" => "Needs attention",
                    _ => "Not allowed",
                }
            };
            rows = rows.child(
                div()
                    .id(action)
                    .flex()
                    .items_center()
                    .gap_3()
                    .py_3()
                    .border_b_1()
                    .border_color(cx.theme().border)
                    .child(note(label).flex_1())
                    .child(note(status).text_color(if status == "Allowed" {
                        cx.theme().success
                    } else {
                        cx.theme().muted_foreground
                    }))
                    .child(
                        self.action(
                            format!("manage-{action}"),
                            "Manage",
                            json!({"action":action,"setup":setup}),
                            self.flag("permissionsBusy") || status == "Unavailable",
                            cx,
                        )
                        .accessibility_label(format!("Manage {label}")),
                    ),
            );
        }
        let paired_control = messages(
            stack()
                .child(self.toggle(
                    "allow-control-from-paired-devices",
                    "Allow control from paired devices",
                    "allowControlFromPairedDevices",
                    "allow-control-from-paired-devices",
                    cx,
                ))
                .child(note(
                    "Once enabled, authenticated paired devices can start control later without another Mac approval. Turning this off or unpairing a device removes that authorization; Stop releases the current session.",
                )),
            &self.state,
            &["controlPreferencesMessage"],
            cx,
        );
        first_section("Mac access", rows, cx)
            .child(paired_control)
            .children(
                (!text(&self.state, "permissionsMessage").is_empty())
                    .then(|| note(text(&self.state, "permissionsMessage"))),
            )
            .child(self.computer_folders(cx))
    }
    fn permissions(&self, cx: &Context<Self>) -> Div {
        self.mac_permissions(false, cx)
    }
    fn setup(&self, cx: &Context<Self>) -> Div {
        let step = self.state["setupStep"].as_u64().unwrap_or(0);
        let title = match step {
            0 => "Get this Mac ready",
            4 => "Connect with Tailscale",
            5 => "On-device dictation",
            1 => "Choose what Wonder can do",
            2 => "Connect your phone",
            _ => "Wonder stays with you",
        };
        let mut view = stack()
            .child(
                note(title)
                    .role(Role::Heading)
                    .text_xl()
                    .font_weight(FontWeight::SEMIBOLD),
            )
            .child(note(format!(
                "Step {} of 6",
                [0, 4, 1, 5, 2, 3]
                    .iter()
                    .position(|value| *value == step)
                    .unwrap_or(0)
                    + 1
            )));
        view=match step {
            0=>view.child(note("Your Bots work on this Mac. Pair your iPhone or iPad to chat with them wherever you are."))
                .child(row("This Mac", text(&self.state,"hostName")))
                .child(row("Wonder", if self.flag("ready") { "Ready to set up" } else { "Getting ready…" }))
                .when(!self.flag("ready") && self.flag("needsRepair"), |v| v.child(note("Wonder needs attention before setup can continue."))
                    .child(self.action("setup-restart", "Restart services", json!({"action":"restart"}), self.flag("serviceBusy"), cx))
                    .child(self.action("setup-repair", "Check installed runtime", json!({"action":"repair"}), self.flag("serviceBusy"), cx))),
            4=>view.child(self.connection(cx)),
            5=>view.child(self.voice_content(cx)),
            1=>view.child(self.mac_permissions(true, cx)),
            2=>view.when(!self.flag("remoteReady"), |v| v.child(note("Connect Tailscale on both devices before pairing. You can finish setup and pair later.")).child(self.connection(cx)))
                .child(self.devices(cx)),
            _=>view.child(note("Wonder stays in your menu bar while your Bots work."))
                .child(self.toggle("setup-login","Launch Wonder at login","login","login",cx))
                .child(note(text(&self.state,"loginMessage")))
                .when(self.flag("loginApproval"), |v| v.child(self.action("setup-login-settings","Open Login Settings…",json!({"action":"login-settings"}),false,cx)))
                .child(note("Remote access needs this Mac to be awake and online. Closing setup keeps Wonder running; Quit Wonder stops Bots and remote access.")),
        };
        view
    }
    fn setup_controls(&self, cx: &Context<Self>) -> Div {
        let step = self.state["setupStep"].as_u64().unwrap_or(0);
        let steps = [0, 4, 1, 5, 2, 3];
        let position = steps.iter().position(|value| *value == step).unwrap_or(0);
        let mut controls = div().w_full().flex().justify_end().gap_2().pt_4();
        if position > 0 {
            controls = controls.child(self.action(
                "back",
                "Back",
                json!({"action":"setup-step","step":steps[position-1]}),
                false,
                cx,
            ));
        }
        if position < steps.len() - 1 {
            controls = controls.child(
                self.action(
                    "continue",
                    if step == 4 && !self.flag("remoteReady") {
                        "Set up later"
                    } else if step == 5 {
                        self.voice.setup_continue_label()
                    } else if step == 1
                        && (text(&self.state, "screen") != "Enabled"
                            || text(&self.state, "input") != "Enabled")
                    {
                        "Set up later"
                    } else if step == 2
                        && !array(&self.state, "devices")
                            .iter()
                            .any(|device| device["revoked"] != true)
                    {
                        "Continue without pairing"
                    } else {
                        "Continue"
                    },
                    json!({"action":"setup-step","step":steps[position+1]}),
                    (step == 0 && (!self.flag("ready") || self.flag("serviceBusy"))),
                    cx,
                )
                .primary(),
            );
        } else {
            controls = controls.child(
                self.action(
                    "done",
                    "Done",
                    json!({"action":"setup-finish"}),
                    !self.flag("ready"),
                    cx,
                )
                .primary(),
            );
        }
        controls
    }
}
impl Render for MacSettings {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let pages = [
            (Page::Status, "Status"),
            (Page::Devices, "Devices"),
            (Page::Access, "Access"),
            (Page::Dictation, "Dictation"),
            (Page::About, "About"),
        ];
        let selected = pages
            .iter()
            .position(|(page, _)| *page == self.page)
            .unwrap_or(0);
        let nav = tab::TabBar::new("settings-tabs")
            .segmented()
            .children(pages.iter().map(|(_, label)| *label))
            .selected_index(selected)
            .on_click(cx.listener(move |this, index: &usize, _, cx| {
                this.select_page(pages[*index].0, cx);
            }));
        let appearance = tab::TabBar::new("appearance")
            .segmented()
            .children([
                tab::Tab::new()
                    .label("System")
                    .aria_label("Use system appearance"),
                tab::Tab::new()
                    .icon(IconName::Sun)
                    .aria_label("Light appearance"),
                tab::Tab::new()
                    .icon(IconName::Moon)
                    .aria_label("Dark appearance"),
            ])
            .selected_index(
                crate::appearance::Preference::ALL
                    .iter()
                    .position(|p| p == cx.global::<crate::appearance::Preference>())
                    .unwrap_or(0),
            )
            .on_click(cx.listener(|this, index: &usize, window, cx| {
                this.error = crate::appearance::select(
                    crate::appearance::Preference::ALL[*index],
                    window,
                    cx,
                )
                .err();
                cx.notify();
            }));
        let content = if self.page == Page::Dictation {
            self.voice_content(cx)
        } else if !self.received {
            stack().child(note(if self.error.is_some() {
                "Settings are unavailable."
            } else {
                "Loading Mac settings…"
            }))
        } else {
            match self.page {
                Page::Status => self.general(cx),
                Page::Devices => self.devices(cx),
                Page::Access => self.permissions(cx),
                Page::Dictation => self.voice_content(cx),
                Page::About => self.about(cx),
            }
        };
        div()
            .id("mac-settings")
            .key_context("WonderSettings")
            .track_focus(&self.focus)
            .on_action(
                cx.listener(|this, _: &StatusSettings, _, cx| this.select_page(Page::Status, cx)),
            )
            .on_action(
                cx.listener(|this, _: &DeviceSettings, _, cx| this.select_page(Page::Devices, cx)),
            )
            .on_action(
                cx.listener(|this, _: &AccessSettings, _, cx| this.select_page(Page::Access, cx)),
            )
            .on_action(cx.listener(|this, _: &DictationSettings, _, cx| {
                this.select_page(Page::Dictation, cx)
            }))
            .size_full()
            .flex()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .gap_4()
                            .p_4()
                            .child(nav)
                            .child(appearance),
                    )
                    .child(
                        div()
                            .id(SharedString::from(format!("settings-scroll-{selected}")))
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .px_6()
                            .pt_4()
                            .pb_6()
                            .child(
                                stack()
                                    .when(self.error.is_some(), |v| {
                                        v.child(
                                            note(self.error.as_deref().unwrap_or(""))
                                                .text_color(cx.theme().danger),
                                        )
                                    })
                                    .when(!text(&self.state, "error").is_empty(), |v| {
                                        v.child(
                                            note(text(&self.state, "error"))
                                                .text_color(cx.theme().danger),
                                        )
                                    })
                                    .when(
                                        self.pending.is_some()
                                            || self.flag("serviceBusy")
                                            || self.flag("pairingBusy"),
                                        |v| v.child(note("Updating…")),
                                    )
                                    .when(
                                        self.error.is_some()
                                            || !text(&self.state, "error").is_empty(),
                                        |v| {
                                            v.child(
                                                Button::new("retry-settings")
                                                    .label("Try again")
                                                    .disabled(self.pending.is_some())
                                                    .on_click(
                                                        cx.listener(|this, _, _, cx| {
                                                            this.retry(cx)
                                                        }),
                                                    ),
                                            )
                                        },
                                    )
                                    .child(content),
                            ),
                    ),
            )
    }
}
/// Delay an early open until the bridge has loaded persisted setup progress.
pub fn route_setup(cx: &mut App) -> bool {
    let model = cx.global::<crate::DesktopShell>().settings_model.clone();
    if !model.read(cx).received && model.read(cx).error.is_some() {
        return false;
    }
    if !model.read(cx).received {
        model.update(cx, |this, _| this.open_when_ready = true);
        return true;
    }
    if !model.read(cx).flag("setupCompleted") {
        setup_window::open(model, cx);
        return true;
    }
    false
}

fn settings_section(title: &str, content: Div, cx: &App) -> Div {
    first_section(title, content, cx)
        .border_t_1()
        .border_color(cx.theme().border)
}
fn first_section(title: &str, content: Div, _: &App) -> Div {
    stack()
        .gap_2()
        .pt_3()
        .child(
            note(title.to_owned())
                .role(Role::Heading)
                .font_weight(FontWeight::SEMIBOLD),
        )
        .child(content)
}
fn stack() -> Div {
    div().flex().flex_col().gap_3().min_w_0()
}
fn heading(value: impl Into<SharedString>) -> Stateful<Div> {
    let value = value.into();
    note(value)
        .role(Role::Heading)
        .mt_3()
        .pt_4()
        .pb_2()
        .border_t_1()
        .border_color(rgb(0x808080).opacity(0.18))
        .text_base()
        .font_weight(FontWeight::SEMIBOLD)
}
#[track_caller]
fn note(value: impl Into<SharedString>) -> Stateful<Div> {
    let value = value.into();
    let location = std::panic::Location::caller();
    div()
        .id(SharedString::from(format!(
            "text-{}-{}-{value}",
            location.line(),
            location.column()
        )))
        .role(Role::Label)
        .aria_label(value.clone())
        .text_sm()
        .child(value)
}
fn row(label: &str, value: &str) -> Stateful<Div> {
    div()
        .id(SharedString::from(label.to_owned()))
        .role(Role::Label)
        .aria_label(format!("{label}: {value}"))
        .flex()
        .justify_between()
        .gap_3()
        .child(label.to_owned())
        .child(value.to_owned())
}

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}
fn array<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value[key].as_array().map(Vec::as_slice).unwrap_or(&[])
}
fn messages(mut view: Div, state: &Value, keys: &[&str], _: &App) -> Div {
    for key in keys {
        if !text(state, key).is_empty() {
            view = view.child(note(text(state, key)));
        }
    }
    view
}
fn expired(value: &Value) -> bool {
    value["expiresAtMs"]
        .as_u64()
        .is_none_or(|end| now_ms() >= end)
}
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn expiry(value: &Value) -> String {
    let seconds = value["expiresAtMs"]
        .as_u64()
        .unwrap_or(0)
        .saturating_sub(now_ms())
        / 1000;
    format!("Expires in {}:{:02}", seconds / 60, seconds % 60)
}

fn parsed_date(raw: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    raw.parse::<i64>()
        .ok()
        .and_then(chrono::DateTime::from_timestamp_millis)
        .or_else(|| {
            chrono::DateTime::parse_from_rfc3339(raw)
                .ok()
                .map(|d| d.with_timezone(&chrono::Utc))
        })
}
fn date_label(raw: &str) -> String {
    parsed_date(raw)
        .map(|d| {
            d.with_timezone(&chrono::Local)
                .format("%b %-d, %Y at %-I:%M %p")
                .to_string()
        })
        .unwrap_or_else(|| "Not available".into())
}
fn remote_label(state: &Value) -> &'static str {
    if state["remoteReady"] == true {
        "Available"
    } else if state["remoteChecking"] == true {
        "Connecting…"
    } else {
        "Unavailable"
    }
}
fn last_seen(phone: &Value) -> String {
    if phone["revoked"] == true {
        return "Access revoked".into();
    }
    let Some(date) = parsed_date(text(phone, "lastSeen")) else {
        return "Waiting for first connection".into();
    };
    let minutes = (chrono::Utc::now() - date).num_minutes().max(0);
    if minutes < 1 {
        "Last seen just now".into()
    } else if minutes < 60 {
        format!("Last seen {minutes} min ago")
    } else if minutes < 1440 {
        format!("Last seen {} hr ago", minutes / 60)
    } else if minutes < 2880 {
        "Last seen yesterday".into()
    } else {
        format!(
            "Last seen {}",
            date.with_timezone(&chrono::Local).format("%b %-d, %Y")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{expired, last_seen, now_ms};
    use serde_json::json;
    #[test]
    fn missing_or_elapsed_pairing_deadlines_fail_closed() {
        assert!(expired(&json!({})));
        assert!(expired(&json!({"expiresAtMs":now_ms().saturating_sub(1)})));
        assert!(!expired(&json!({"expiresAtMs":now_ms()+60_000})));
    }
    #[test]
    fn device_history_distinguishes_revoked_waiting_and_seen() {
        assert_eq!(
            last_seen(&json!({"revoked":true,"lastSeen":"2026-09-08T13:00:00Z"})),
            "Access revoked"
        );
        assert_eq!(last_seen(&json!({})), "Waiting for first connection");
        let seen = last_seen(&json!({"lastSeen":"2026-09-08T13:00:00Z"}));
        assert!(seen.starts_with("Last seen "));
        let millis = chrono::DateTime::parse_from_rfc3339("2026-09-08T13:00:00Z")
            .unwrap()
            .timestamp_millis()
            .to_string();
        assert_eq!(last_seen(&json!({"lastSeen":millis})), seen);
    }
}
