use gpui_kit::{
    component::{
        button::*,
        menu::{DropdownMenu, PopupMenuItem},
        switch::Switch,
        *,
    },
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

actions!(
    wonder_settings,
    [StatusSettings, DeviceSettings, AccessSettings,]
);

#[derive(Clone, Copy, PartialEq)]
enum Page {
    Status,
    Devices,
    Access,
    About,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ReadinessAction {
    Retry,
    Repair,
    Reopen,
    ConnectMac,
    OpenTailscale,
    PairDevice,
    ReviewAccess,
    None,
}

#[derive(Debug, PartialEq, Eq)]
struct ReadinessSummary {
    title: &'static str,
    detail: String,
    action: ReadinessAction,
    fully_ready: bool,
}

impl ReadinessSummary {
    fn from_snapshot(state: &Value, bridge_connected: bool) -> Self {
        let summary = |title, detail: String, action| Self {
            title,
            detail,
            action,
            fully_ready: false,
        };
        if !bridge_connected {
            return summary(
                "Mac settings unavailable",
                "Wonder could not check this Mac. Reopen the app to restore its status.".into(),
                ReadinessAction::Retry,
            );
        }
        if state["serviceRunning"] != true {
            return summary(
                "Wonder is offline",
                "Quit and reopen Wonder.".into(),
                ReadinessAction::Reopen,
            );
        }
        if state["ready"] != true {
            let detail = text(state, "executionDetail");
            return summary(
                "Agent work needs attention",
                if detail.is_empty() {
                    "Wonder cannot start agent work yet. Check again in a moment.".into()
                } else {
                    detail.to_owned()
                },
                if text(state, "executionReason") == "runtime_unavailable" {
                    ReadinessAction::Repair
                } else {
                    ReadinessAction::Retry
                },
            );
        }
        if state["updatePreparing"] == true {
            return summary(
                "Preparing an update",
                "Wonder is waiting for active work to finish before installing the update.".into(),
                ReadinessAction::None,
            );
        }
        if state["remoteReady"] != true {
            if state["remoteChecking"] == true {
                return summary(
                    "Ready on this Mac",
                    "Checking access from paired devices.".into(),
                    ReadinessAction::None,
                );
            }
            return summary(
                "Ready on this Mac",
                "Paired devices cannot reach this Mac until remote access reconnects.".into(),
                if state["canConnect"] == true {
                    ReadinessAction::ConnectMac
                } else {
                    ReadinessAction::OpenTailscale
                },
            );
        }
        if state["pairingFresh"] != true {
            return summary(
                "Ready for chats",
                "Wonder could not check paired devices. Open Devices to refresh their status."
                    .into(),
                ReadinessAction::PairDevice,
            );
        }
        if !array(state, "devices")
            .iter()
            .any(|device| device["revoked"] != true)
        {
            return summary(
                "Ready to connect a device",
                "Wonder is reachable. Pair an iPhone or iPad to work from it.".into(),
                ReadinessAction::PairDevice,
            );
        }
        let screen = text(state, "screen");
        let input = text(state, "input");
        let screen_missing = matches!(screen, "Not enabled" | "Needs attention");
        let input_missing = matches!(input, "Not enabled" | "Needs attention");
        if screen_missing || input_missing {
            let detail = match (screen_missing, input_missing) {
                (true, true) => "Phone chats work. Screen viewing and computer control need permission in Access.",
                (true, false) => "Phone chats work. Screen viewing needs Screen Recording permission in Access.",
                (false, true) => "Phone chats work. Computer control needs Accessibility permission in Access.",
                (false, false) => unreachable!(),
            };
            return summary(
                "Ready for messages",
                detail.into(),
                ReadinessAction::ReviewAccess,
            );
        }
        if screen == "Unavailable" || input == "Unavailable" {
            return summary(
                "Ready for chats",
                "Phone chats work. Computer access could not be checked; review Access.".into(),
                ReadinessAction::ReviewAccess,
            );
        }
        if screen == "Checking…" || input == "Checking…" {
            return summary(
                "Ready for chats",
                "Phone chats work. Wonder is checking computer access.".into(),
                ReadinessAction::None,
            );
        }
        if screen != "Enabled" || input != "Enabled" {
            return summary(
                "Ready for chats",
                "Phone chats work. Computer access could not be confirmed; review Access.".into(),
                ReadinessAction::ReviewAccess,
            );
        }
        Self {
            title: "Ready",
            detail: "Wonder's private address responds from this Mac, and a device is paired."
                .into(),
            action: ReadinessAction::None,
            fully_ready: true,
        }
    }
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
    brand_icon: Arc<Image>,
    revoke: Option<(String, String)>,
    revoked_expanded: bool,
    device_details: Option<String>,
    permission_drag_id: String,
    permission_drag_window: Option<WindowHandle<Root>>,
    last_clock: Instant,
    last_auto_pair: Option<Instant>,
}
impl MacSettings {
    pub fn new(cx: &mut Context<Self>) -> Self {
        cx.bind_keys([
            KeyBinding::new("cmd-1", StatusSettings, Some("WonderSettings")),
            KeyBinding::new("cmd-2", DeviceSettings, Some("WonderSettings")),
            KeyBinding::new("cmd-3", AccessSettings, Some("WonderSettings")),
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
            brand_icon: Arc::new(Image::from_bytes(
                ImageFormat::Png,
                include_bytes!("../../ios/Wonder/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
                    .to_vec(),
            )),
            revoke: None,
            revoked_expanded: false,
            device_details: None,
            permission_drag_id: String::new(),
            permission_drag_window: None,
            last_clock: Instant::now(),
            last_auto_pair: None,
        }
    }
    fn select_page(&mut self, page: Page, cx: &mut Context<Self>) {
        self.page = page;
        self.revoke = None;

        cx.notify();
    }
    fn tick(&mut self, cx: &mut Context<Self>) {
        let mut changed = false;
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
                    let reviewing_setup =
                        self.state["setupCompleted"] == true && state["setupCompleted"] == false;
                    self.state = state;
                    if (first && !self.flag("setupCompleted")) || reviewing_setup {
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
        self.keep_pairing_code(cx);
        if changed {
            cx.notify();
        }
    }
    /// While pairing is on screen, keep a live code available: replace a missing
    /// or expired offer, backing off after failures.
    fn keep_pairing_code(&mut self, cx: &mut Context<Self>) {
        let offer = &self.state["offer"];
        let needs_code = !offer.is_object() || expired(offer) || offer["expired"] == true;
        let open = |handle: Option<WindowHandle<Root>>| {
            handle.is_some_and(|handle| {
                cx.windows()
                    .iter()
                    .any(|window| window.window_id() == handle.window_id())
            })
        };
        let visible = if self.flag("setupCompleted") {
            self.page == Page::Devices && open(cx.global::<crate::DesktopShell>().settings)
        } else {
            self.state["setupStep"].as_u64() == Some(2) && open(self.setup_window)
        };
        let backoff = if text(&self.state, "pairingError").is_empty() {
            Duration::from_secs(5)
        } else {
            Duration::from_secs(30)
        };
        if needs_code
            && visible
            && self.connected
            && self.pending.is_none()
            && self.flag("remoteReady")
            && !self.flag("pairingBusy")
            && array(&self.state, "pending").is_empty()
            && self.last_auto_pair.is_none_or(|at| at.elapsed() >= backoff)
        {
            self.last_auto_pair = Some(Instant::now());
            self.send(json!({"action":"pair"}), cx);
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
    ) -> Switch {
        Switch::new(id)
            .accessibility_label(label)
            .checked(self.flag(key))
            .disabled(self.disabled())
            .on_click(cx.listener(move |this, checked, _, cx| {
                this.send(json!({"action":action,"enabled":checked}), cx)
            }))
    }
    fn login_row(&self, id: &'static str, cx: &Context<Self>) -> Div {
        let detail = text(&self.state, "loginMessage");
        let mut rows = vec![form_row(
            "Launch at login",
            (!detail.is_empty()).then(|| detail.to_owned()),
            self.toggle(id, "Launch at login", "login", "login", cx),
            cx,
        )
        .into_any_element()];
        if self.flag("loginApproval") {
            rows.push(
                form_row(
                    "Login Items",
                    None,
                    self.action(
                        format!("{id}-settings"),
                        "Open Login Settings…",
                        json!({"action":"login-settings"}),
                        false,
                        cx,
                    )
                    .small(),
                    cx,
                )
                .into_any_element(),
            );
        }
        group(cx, rows)
    }
    /// Auto, Light and Dark as one compact icon toggle at the foot of the sidebar.
    fn appearance(&self, cx: &Context<Self>) -> Div {
        use crate::appearance::Preference;
        let current = *cx.global::<Preference>();
        div()
            .flex()
            .self_start()
            .gap_0p5()
            .p_0p5()
            .mx_2()
            .mb_3()
            .rounded(px(8.))
            .bg(cx.theme().foreground.opacity(0.06))
            .children(
                [
                    (Preference::System, "Match System"),
                    (Preference::Light, "Light"),
                    (Preference::Dark, "Dark"),
                ]
                .map(|(preference, label)| {
                    let button = Button::new(SharedString::from(format!("appearance-{label}")))
                        .ghost()
                        .small()
                        .selected(preference == current)
                        .w(px(30.))
                        .h(px(24.))
                        .tooltip(label)
                        .accessibility_label(format!("Appearance: {label}"))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.error = crate::appearance::select(preference, window, cx).err();
                            cx.notify();
                        }));
                    match preference {
                        Preference::System => button.child(
                            div()
                                .size(px(13.))
                                .rounded_full()
                                .border_1()
                                .border_color(cx.theme().foreground)
                                .child(
                                    div()
                                        .w(px(5.5))
                                        .h_full()
                                        .rounded_l(px(6.))
                                        .bg(cx.theme().foreground),
                                ),
                        ),
                        Preference::Light => button.icon(IconName::Sun),
                        Preference::Dark => button.icon(IconName::Moon),
                    }
                }),
            )
    }
    fn general(&self, cx: &Context<Self>) -> Div {
        let summary = ReadinessSummary::from_snapshot(&self.state, self.connected);
        let action = match summary.action {
            ReadinessAction::Retry => Some(
                Button::new("retry-readiness")
                    .label("Try again")
                    .on_click(cx.listener(|this, _, _, cx| this.retry(cx))),
            ),
            ReadinessAction::Repair => Some(self.action(
                "repair-runtime",
                "Set up agents",
                json!({"action":"repair"}),
                self.flag("serviceBusy"),
                cx,
            )),
            ReadinessAction::ConnectMac => Some(self.action(
                "connect-mac",
                "Finish remote sign-in",
                json!({"action":"connect-mac"}),
                false,
                cx,
            )),
            ReadinessAction::OpenTailscale => Some(self.action(
                "open-tailscale",
                "Open Tailscale",
                json!({"action":"tailscale-open"}),
                false,
                cx,
            )),
            ReadinessAction::PairDevice => Some(
                Button::new("open-devices")
                    .label("Open Devices")
                    .on_click(cx.listener(|this, _, _, cx| this.select_page(Page::Devices, cx))),
            ),
            ReadinessAction::ReviewAccess => Some(
                Button::new("open-access")
                    .label("Review Access")
                    .on_click(cx.listener(|this, _, _, cx| this.select_page(Page::Access, cx))),
            ),
            ReadinessAction::Reopen | ReadinessAction::None => None,
        };
        let status = card(cx).child(
            div()
                .flex()
                .items_center()
                .gap_3()
                .p_4()
                .child(div().size(px(10.)).flex_shrink_0().rounded_full().bg(
                    if summary.fully_ready {
                        cx.theme().success
                    } else {
                        cx.theme().warning
                    },
                ))
                .child(
                    stack()
                        .gap_0p5()
                        .flex_1()
                        .child(
                            note(summary.title)
                                .role(Role::Heading)
                                .text_base()
                                .font_weight(FontWeight::SEMIBOLD),
                        )
                        .child(muted(text(&self.state, "hostName"), cx))
                        .when(!summary.fully_ready, |view| {
                            view.child(note(summary.detail).pt_1())
                        }),
                )
                .children(action.map(|button| button.primary().small())),
        );
        let mut view = stack().gap_5().child(status);
        if self.flag("claudeAuthRequired") {
            view = view.child(group(
                cx,
                vec![form_row(
                    "Claude",
                    Some("Sign in so agents can start work.".into()),
                    self.action(
                        "claude-sign-in",
                        "Sign In…",
                        json!({"action":"claude-sign-in"}),
                        self.flag("serviceBusy"),
                        cx,
                    )
                    .small(),
                    cx,
                )
                .into_any_element()],
            ));
        }
        view.child(self.login_row("login", cx))
    }
    fn about(&self, cx: &Context<Self>) -> Div {
        let mut rows = vec![
            form_row("Version", None, muted(text(&self.state, "version"), cx), cx)
                .into_any_element(),
        ];
        if self.flag("updatesAvailable") {
            rows.push(
                form_row(
                    "Install updates automatically",
                    None,
                    Switch::new("automatic-update-policy")
                        .accessibility_label("Install updates automatically")
                        .checked(
                            self.flag("automaticUpdates") && self.flag("automaticUpdateDownloads"),
                        )
                        .disabled(self.disabled())
                        .on_click(cx.listener(|this, checked, _, cx| {
                            this.send(
                                json!({"action":"automatic-update-policy","enabled":checked}),
                                cx,
                            );
                        })),
                    cx,
                )
                .into_any_element(),
            );
            rows.push(
                form_row(
                    "Updates",
                    None,
                    self.action(
                        "check-updates",
                        "Check for Updates…",
                        json!({"action":"check-updates"}),
                        !self.flag("canCheckUpdates"),
                        cx,
                    )
                    .small(),
                    cx,
                )
                .into_any_element(),
            );
        } else {
            rows.push(
                form_row(
                    "Updates",
                    None,
                    self.action(
                        "download-update",
                        "Download Latest Version…",
                        json!({"action":"download-update"}),
                        false,
                        cx,
                    )
                    .small(),
                    cx,
                )
                .into_any_element(),
            );
        }
        messages(
            stack().gap_3().child(group(cx, rows)),
            &self.state,
            &["updatesMessage"],
            cx,
        )
    }
    fn connection(&self, cx: &Context<Self>) -> Div {
        stack()
            .gap_2()
            .child(note(
                "Connect this Mac and your phone to the same Tailscale network.",
            ))
            .child(note(text(&self.state, "remoteDetail")))
            .child(
                div()
                    .flex()
                    .gap_2()
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
                    )),
            )
    }
    fn devices(&self, cx: &Context<Self>) -> Div {
        let devices = array(&self.state, "devices");
        let pending = array(&self.state, "pending");
        let mut view = stack().gap_4();
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
        for phone in pending {
            let id = text(phone, "id");
            let disabled = self.flag("pairingBusy") || !self.flag("pairingFresh") || expired(phone);
            view = view.child(
                card(cx).id(SharedString::from(format!("pairing-{id}"))).child(
                    stack()
                        .gap_2()
                        .p_4()
                        .child(
                            note(format!("Connect {}?", text(phone, "label")))
                                .role(Role::Heading)
                                .font_weight(FontWeight::SEMIBOLD),
                        )
                        .child(muted("Check that this code matches your device.", cx))
                        .child(
                            note(text(phone, "verification"))
                                .text_2xl()
                                .font_weight(FontWeight::SEMIBOLD),
                        )
                        .child(muted(expiry(phone), cx))
                        .child(
                            div()
                                .flex()
                                .gap_2()
                                .pt_1()
                                .child(
                                    self.action(
                                        format!("approve-{id}"),
                                        "Connect",
                                        json!({"action":"approve","key":id,"verification":phone["verification"]}),
                                        disabled,
                                        cx,
                                    )
                                    .primary(),
                                )
                                .child(self.action(
                                    format!("reject-{id}"),
                                    "Reject",
                                    json!({"action":"reject","key":id,"verification":phone["verification"]}),
                                    disabled,
                                    cx,
                                )),
                        ),
                ),
            );
        }
        let offer = &self.state["offer"];
        let live = offer.is_object() && !expired(offer) && offer["expired"] != true;
        if pending.is_empty() && self.flag("remoteReady") {
            let qr = self.qr.clone().filter(|_| live);
            view = view.child(
                card(cx).child(
                    div()
                        .flex()
                        .items_center()
                        .gap_4()
                        .p_4()
                        .child(
                            div()
                                .flex_shrink_0()
                                .size(px(148.))
                                .flex()
                                .items_center()
                                .justify_center()
                                .bg(rgb(0xffffff))
                                .rounded(px(8.))
                                .children(qr.map(|qr| img(qr).size(px(132.)))),
                        )
                        .child(
                            stack()
                                .gap_1p5()
                                .flex_1()
                                .child(note(
                                    "Pair an iPhone or iPad by scanning this code in Wonder.",
                                ))
                                .child(
                                    note(if live {
                                        text(offer, "code")
                                    } else {
                                        "––––"
                                    })
                                    .text_xl()
                                    .font_weight(FontWeight::SEMIBOLD),
                                )
                                .child(muted(
                                    if live {
                                        expiry(offer).replace("Expires in", "New code in")
                                    } else {
                                        "Creating a code…".into()
                                    },
                                    cx,
                                ))
                                .child(
                                    Button::new("copy-pairing")
                                        .label("Copy Pairing Link")
                                        .small()
                                        .self_start()
                                        .disabled(!live)
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            cx.write_to_clipboard(ClipboardItem::new_string(
                                                text(&this.state["offer"], "url").to_owned(),
                                            ));
                                        })),
                                ),
                        ),
                ),
            );
        }
        let mut trusted: Vec<AnyElement> = Vec::new();
        let active: Vec<&Value> = devices
            .iter()
            .filter(|phone| phone["revoked"] != true)
            .collect();
        if active.is_empty() {
            trusted.push(
                form_row(
                    if self.flag("pairingFresh") {
                        "No paired devices yet"
                    } else {
                        "Paired devices are unavailable"
                    },
                    None,
                    div(),
                    cx,
                )
                .into_any_element(),
            );
        }
        for phone in active {
            trusted.push(self.device(phone, cx).into_any_element());
        }
        view = view.child(
            section("Paired devices", None, group(cx, trusted), cx).when(
                !self.flag("remoteReady") && pending.is_empty(),
                |view| {
                    view.child(
                        muted(
                            "Pairing needs remote access. Connect Tailscale on this Mac first.",
                            cx,
                        )
                        .px_3(),
                    )
                },
            ),
        );
        let revoked: Vec<&Value> = devices
            .iter()
            .filter(|phone| phone["revoked"] == true)
            .collect();
        if !revoked.is_empty() {
            let mut list = vec![disclosure(
                "revoked-devices",
                format!("Revoked devices ({})", revoked.len()),
                None,
                self.revoked_expanded,
                cx.listener(|this, _, _, cx| {
                    this.revoked_expanded = !this.revoked_expanded;
                    cx.notify();
                }),
                cx,
            )
            .into_any_element()];
            if self.revoked_expanded {
                for phone in revoked {
                    list.push(self.device(phone, cx).into_any_element());
                }
            }
            view = view.child(group(cx, list));
        }
        view
    }
    fn device(&self, phone: &Value, cx: &Context<Self>) -> Stateful<Div> {
        let id = text(phone, "id").to_owned();
        let label = text(phone, "label").to_owned();
        let seen = last_seen(phone);
        let view = div()
            .flex()
            .flex_col()
            .id(SharedString::from(format!("device-{id}")));
        if phone["revoked"] == true {
            return view.child(form_row(
                label.clone(),
                Some(seen),
                self.action(
                    format!("forget-{id}"),
                    "",
                    json!({"action":"forget-device","key":id}),
                    self.flag("pairingBusy") || !self.flag("pairingFresh"),
                    cx,
                )
                .icon(IconName::Close)
                .ghost()
                .small()
                .accessibility_label(format!("Remove {label} from revoked devices"))
                .tooltip("Remove from list"),
                cx,
            ));
        }
        let expanded = self.device_details.as_deref() == Some(&id);
        let target = id.clone();
        let mut view = view.child(disclosure(
            format!("device-details-{id}"),
            label.clone(),
            Some(seen),
            expanded,
            cx.listener(move |this, _, _, cx| {
                this.revoke = None;
                this.device_details = if this.device_details.as_deref() == Some(&target) {
                    None
                } else {
                    Some(target.clone())
                };
                cx.notify();
            }),
            cx,
        ));
        if !expanded {
            return view;
        }
        let details = stack().gap_1p5().px_3().pb_3().pl(px(36.));
        let confirming = self
            .revoke
            .as_ref()
            .is_some_and(|(selected, _)| selected == &id);
        let details = if confirming {
            details
                .child(note(format!("Revoke {label}?")).font_weight(FontWeight::SEMIBOLD))
                .child(muted(
                    "It disconnects now and needs to pair again to return.",
                    cx,
                ))
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .pt_1()
                        .child(
                            Button::new("cancel-revoke")
                                .label("Cancel")
                                .small()
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.revoke = None;
                                    cx.notify();
                                })),
                        )
                        .child(
                            self.action(
                                "confirm-revoke",
                                "Revoke",
                                json!({"action":"revoke","key":id}),
                                self.flag("pairingBusy"),
                                cx,
                            )
                            .danger()
                            .small(),
                        ),
                )
        } else {
            let name = label.clone();
            let target = id.clone();
            details
                .child(detail_row(
                    "Paired",
                    &date_label(text(phone, "pairedAt")),
                    cx,
                ))
                .child(detail_row(
                    "Last connected",
                    &date_label(text(phone, "lastSeen")),
                    cx,
                ))
                .child(
                    Button::new(format!("revoke-{id}"))
                        .label("Revoke…")
                        .small()
                        .self_start()
                        .mt_1()
                        .accessibility_label(format!("Revoke {label}"))
                        .disabled(
                            self.disabled()
                                || self.flag("pairingBusy")
                                || !self.flag("pairingFresh"),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.revoke = Some((target.clone(), name.clone()));
                            cx.notify();
                        })),
                )
        };
        view = view.child(details);
        view
    }
    fn mac_permissions(&self, setup: bool, cx: &Context<Self>) -> Div {
        let mut rows: Vec<AnyElement> = Vec::new();
        for (action, label, key) in [
            ("screen", "Screen Recording", "screen"),
            ("input", "Accessibility", "input"),
            ("computer-full-disk", "Full Disk Access", "fullDisk"),
        ] {
            let purpose = match key {
                "screen" => "See your screen from a paired device",
                "input" => "Control the mouse and keyboard",
                _ => "Open files anywhere on this Mac",
            };
            let status = if key == "fullDisk" {
                ""
            } else {
                text(&self.state, key)
            };
            let trailing = match status {
                "Enabled" => div()
                    .flex()
                    .items_center()
                    .gap_1()
                    .text_color(cx.theme().success)
                    .child(Icon::new(IconName::CircleCheck).small())
                    .child(note("Allowed")),
                "Unavailable" | "Checking…" => div().child(muted(status, cx)),
                _ => div().child(
                    self.action(
                        format!("manage-{action}"),
                        if key == "fullDisk" {
                            "Open Settings…"
                        } else {
                            "Allow…"
                        },
                        json!({"action":action,"setup":setup}),
                        self.flag("permissionsBusy"),
                        cx,
                    )
                    .small()
                    .accessibility_label(format!("Manage {label}")),
                ),
            };
            rows.push(
                div()
                    .id(action)
                    .child(form_row(label, Some(purpose.into()), trailing, cx))
                    .into_any_element(),
            );
        }
        let permissions = section("Permissions", None, group(cx, rows), cx).children(
            (!text(&self.state, "permissionsMessage").is_empty())
                .then(|| muted(text(&self.state, "permissionsMessage"), cx).px_3()),
        );
        let control_detail = match text(&self.state, "controlPreferencesMessage") {
            "" => "Paired devices can control this Mac without asking each time.",
            message => message,
        };
        let mut control = vec![form_row(
            "Allow control from paired devices",
            Some(control_detail.into()),
            self.toggle(
                "allow-control-from-paired-devices",
                "Allow control from paired devices",
                "allowControlFromPairedDevices",
                "allow-control-from-paired-devices",
                cx,
            ),
            cx,
        )
        .into_any_element()];
        if !setup {
            control.push(self.shared_display_row(cx).into_any_element());
        }
        stack().gap_5().child(permissions).child(section(
            "Remote control",
            None,
            group(cx, control),
            cx,
        ))
    }
    fn shared_display_row(&self, cx: &Context<Self>) -> Div {
        let displays = array(&self.state, "sharedDisplays");
        let saved = text(&self.state, "preferredDisplayID").to_owned();
        let saved_connected = displays.iter().any(|display| text(display, "id") == saved);
        // The main display is listed once, first and by name; choosing it keeps
        // the automatic main-display choice ("").
        let main = displays.iter().find(|display| display["main"] == true);
        let main_id = main.map(|display| text(display, "id")).unwrap_or_default();
        let mut options = vec![(
            String::new(),
            main.map(|display| text(display, "name"))
                .filter(|name| !name.is_empty())
                .unwrap_or("Main display")
                .to_owned(),
        )];
        options.extend(
            displays
                .iter()
                .filter(|display| display["main"] != true)
                .map(|display| {
                    (
                        text(display, "id").to_owned(),
                        text(display, "name").to_owned(),
                    )
                }),
        );
        let current = if saved_connected && saved != main_id {
            saved.clone()
        } else {
            String::new()
        };
        let current_label = options
            .iter()
            .find(|(id, _)| *id == current)
            .map(|(_, name)| name.clone())
            .unwrap_or_default();
        let model = cx.entity().downgrade();
        let picker = Button::new("shared-display")
            .label(current_label.clone())
            .small()
            .dropdown_caret(true)
            .disabled(self.disabled())
            .accessibility_label(format!("Screen to share: {current_label}"))
            .dropdown_menu_with_anchor(Anchor::TopRight, move |mut menu, _, _| {
                for (id, name) in options.clone() {
                    let model = model.clone();
                    let checked = id == current;
                    menu = menu.item(PopupMenuItem::new(name).checked(checked).on_click(
                        move |_, _, cx| {
                            let _ = model.update(cx, |this, cx| {
                                this.send(json!({"action":"shared-display","key":id}), cx)
                            });
                        },
                    ));
                }
                menu
            });
        form_row(
            "Screen to share",
            (!saved.is_empty() && !saved_connected)
                .then(|| "Your saved screen is disconnected, so the main display is shared until it returns.".into()),
            picker,
            cx,
        )
    }
    fn shared_display_choice(&self, cx: &Context<Self>) -> Div {
        group(cx, vec![self.shared_display_row(cx).into_any_element()])
    }
    fn permissions(&self, cx: &Context<Self>) -> Div {
        self.mac_permissions(false, cx)
    }
    fn setup(&self, cx: &Context<Self>) -> Div {
        let step = self.state["setupStep"].as_u64().unwrap_or(0);
        let title = match step {
            0 => "Get this Mac ready",
            4 => "Connect with Tailscale",
            1 => "Choose what Wonder can do",
            6 => "Choose a screen to share",
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
                [0, 4, 1, 6, 2, 3]
                    .iter()
                    .position(|value| *value == step)
                    .unwrap_or(0)
                    + 1
            )));
        view=match step {
            0=>view.child(note("Wonder connects your chats and Projects to this Mac. Pair your iPhone or iPad to use them wherever you are."))
                .child(row("This Mac", text(&self.state,"hostName")))
                .child(row("Wonder", if self.flag("ready") { "Ready to set up" } else { "Getting ready…" }))
                .when(!self.flag("ready") && self.flag("needsRepair"), |v| v.child(note("Wonder needs attention before setup can continue."))
                    .child(note("Quit and reopen Wonder if setup stops responding."))
                    .child(self.action("setup-repair", "Set up agents", json!({"action":"repair"}), self.flag("serviceBusy"), cx))),
            4=>view.child(self.connection(cx)),
            1=>view.child(self.mac_permissions(true, cx)),
            6=>view.child(self.shared_display_choice(cx)),
            2=>view.when(!self.flag("remoteReady"), |v| v.child(note("Connect Tailscale on both devices before pairing. You can finish setup and pair later.")).child(self.connection(cx)))
                .child(self.devices(cx)),
            _=>view.child(note("Wonder stays in your menu bar so your chats and Projects remain available."))
                .child(self.login_row("setup-login", cx))
                .child(note("Remote access needs this Mac to be awake and online. Closing setup keeps Wonder running; Quit Wonder stops active agent work and remote access.")),
        };
        view
    }
    fn setup_controls(&self, cx: &Context<Self>) -> Div {
        let step = self.state["setupStep"].as_u64().unwrap_or(0);
        let steps = [0, 4, 1, 6, 2, 3];
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
                    } else if step == 6 && text(&self.state, "preferredDisplayID").is_empty() {
                        "Use main display"
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
                    step == 0 && (!self.flag("ready") || self.flag("serviceBusy")),
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
            (Page::Status, "General", IconName::Settings),
            (Page::Devices, "Devices", IconName::Network),
            (Page::Access, "Access", IconName::Eye),
            (Page::About, "About", IconName::Info),
        ];
        let selected = pages
            .iter()
            .position(|(page, _, _)| *page == self.page)
            .unwrap_or(0);
        let (sunrise, sunset) = if cx.theme().is_dark() {
            (rgb(0x2d241b), rgb(0x382a1e))
        } else {
            (rgb(0xfff7de), rgb(0xffe9c8))
        };
        let nav = stack()
            .gap_0p5()
            .w(px(176.))
            .flex_shrink_0()
            .h_full()
            .px_3()
            .pt_4()
            .bg(linear_gradient(
                170.,
                linear_color_stop(sunrise, 0.),
                linear_color_stop(sunset, 1.),
            ))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .pb_4()
                    .child(img(self.brand_icon.clone()).size(px(28.)).rounded(px(7.)))
                    .child(note("Wonder").text_base().font_weight(FontWeight::SEMIBOLD)),
            )
            .children(
                pages
                    .iter()
                    .enumerate()
                    .map(|(index, (page, label, icon))| {
                        let page = *page;
                        Button::new(SharedString::from(format!("settings-page-{index}")))
                            .ghost()
                            .selected(self.page == page)
                            .w_full()
                            .h(px(30.))
                            .accessibility_label(*label)
                            .child(
                                h_flex()
                                    .flex_1()
                                    .gap_2()
                                    .items_center()
                                    .child(Icon::new(icon.clone()).small())
                                    .child(*label),
                            )
                            .on_click(cx.listener(move |this, _, _, cx| this.select_page(page, cx)))
                    }),
            )
            .child(div().flex_1())
            .child(self.appearance(cx));
        let content = if !self.received {
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
            .size_full()
            .flex()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(nav)
            .child(
                div().flex_1().min_w_0().h_full().flex().flex_col().child(
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
                                .child(
                                    note(pages[selected].1)
                                        .role(Role::Heading)
                                        .text_xl()
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .pb_4(),
                                )
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
                                    |v| v.child(muted("Updating…", cx).pb_2()),
                                )
                                .when(
                                    self.error.is_some() || !text(&self.state, "error").is_empty(),
                                    |v| {
                                        v.child(
                                            Button::new("retry-settings")
                                                .label("Try again")
                                                .disabled(self.pending.is_some())
                                                .on_click(
                                                    cx.listener(|this, _, _, cx| this.retry(cx)),
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

/// A titled settings group, optionally with an action beside its title.
fn section(title: &str, action: Option<Button>, content: Div, cx: &App) -> Div {
    stack()
        .gap_1p5()
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .px_3()
                .min_h(px(24.))
                .child(
                    note(title.to_owned())
                        .role(Role::Heading)
                        .text_xs()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(cx.theme().muted_foreground),
                )
                .children(action),
        )
        .child(content)
}
/// A rounded surface; `group` adds separators between its rows.
fn card(cx: &App) -> Div {
    div().flex().flex_col().min_w_0().rounded(px(10.)).bg(cx
        .theme()
        .secondary
        .opacity(if cx.theme().is_dark() { 0.55 } else { 0.4 }))
}
fn group(cx: &App, rows: Vec<AnyElement>) -> Div {
    card(cx).children(rows.into_iter().enumerate().map(|(index, row)| {
        div()
            .when(index > 0, |row| {
                row.border_t_1().border_color(separator(cx))
            })
            .child(row)
    }))
}
fn separator(cx: &App) -> Hsla {
    cx.theme().border.opacity(0.8)
}
/// One settings row: label (and optional detail) on the left, control on the right.
fn form_row(
    label: impl Into<SharedString>,
    detail: Option<String>,
    trailing: impl IntoElement,
    cx: &App,
) -> Div {
    div()
        .flex()
        .items_center()
        .justify_between()
        .gap_4()
        .px_3()
        .py_2()
        .min_h(px(44.))
        .child(
            stack()
                .gap_0p5()
                .flex_1()
                .child(note(label.into()))
                .children(detail.map(|detail| muted(detail, cx).text_xs())),
        )
        .child(div().flex_shrink_0().child(trailing))
}
/// A full-width row that expands or collapses the content below it.
fn disclosure(
    id: impl Into<SharedString>,
    label: impl Into<SharedString>,
    detail: Option<String>,
    expanded: bool,
    on_click: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    cx: &App,
) -> Button {
    let label = label.into();
    Button::new(id.into())
        .ghost()
        .w_full()
        .h_auto()
        .min_h(px(44.))
        .py_2()
        .px_3()
        .rounded(px(10.))
        .accessibility_label(match &detail {
            Some(detail) => format!("{label}, {detail}"),
            None => label.to_string(),
        })
        .child(
            h_flex()
                .flex_1()
                .min_w_0()
                .gap_3()
                .items_center()
                .child(
                    Icon::new(if expanded {
                        IconName::ChevronDown
                    } else {
                        IconName::ChevronRight
                    })
                    .small()
                    .text_color(cx.theme().muted_foreground),
                )
                .child(
                    stack()
                        .gap_0p5()
                        .flex_1()
                        .min_w_0()
                        .child(note(label.clone()))
                        .children(detail.map(|detail| muted(detail, cx).text_xs())),
                ),
        )
        .on_click(on_click)
}
fn detail_row(label: &str, value: &str, cx: &App) -> Div {
    div()
        .flex()
        .justify_between()
        .gap_3()
        .child(muted(label.to_owned(), cx).text_xs())
        .child(note(value.to_owned()).text_xs())
}
#[track_caller]
fn muted(value: impl Into<SharedString>, cx: &App) -> Stateful<Div> {
    note(value).text_color(cx.theme().muted_foreground)
}
fn stack() -> Div {
    div().flex().flex_col().gap_3().min_w_0()
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
    use super::{expired, last_seen, now_ms, ReadinessAction, ReadinessSummary};
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

    #[test]
    fn readiness_summary_preserves_readiness_and_selects_real_recovery() {
        let healthy = json!({
            "serviceRunning":true, "ready":true, "remoteReady":true,
            "pairingFresh":true, "devices":[{"revoked":false}],
            "screen":"Enabled", "input":"Enabled"
        });
        let summary = ReadinessSummary::from_snapshot(&healthy, true);
        assert_eq!(summary.title, "Ready");
        assert!(summary.fully_ready);
        assert_eq!(summary.action, ReadinessAction::None);

        let mut state = healthy.clone();
        state["remoteReady"] = json!(false);
        let summary = ReadinessSummary::from_snapshot(&state, true);
        assert_eq!(summary.title, "Ready on this Mac");
        assert!(!summary.fully_ready);
        assert_eq!(summary.action, ReadinessAction::OpenTailscale);
        state["canConnect"] = json!(true);
        assert_eq!(
            ReadinessSummary::from_snapshot(&state, true).action,
            ReadinessAction::ConnectMac
        );

        let mut state = healthy.clone();
        state["ready"] = json!(false);
        state["executionDetail"] = json!("Chat storage is unavailable.");
        let summary = ReadinessSummary::from_snapshot(&state, true);
        assert_eq!(summary.detail, "Chat storage is unavailable.");
        assert_eq!(summary.action, ReadinessAction::Retry);
        assert!(!summary.detail.contains("Claude"));

        state["executionReason"] = json!("runtime_unavailable");
        state["executionDetail"] = json!("The installed runtime is unavailable.");
        let summary = ReadinessSummary::from_snapshot(&state, true);
        assert_eq!(summary.action, ReadinessAction::Repair);
        assert!(summary.detail.contains("installed runtime"));

        let mut state = healthy.clone();
        state["serviceRunning"] = json!(false);
        assert_eq!(
            ReadinessSummary::from_snapshot(&state, true).action,
            ReadinessAction::Reopen
        );
        assert_eq!(
            ReadinessSummary::from_snapshot(&healthy, false).action,
            ReadinessAction::Retry
        );

        let mut state = healthy.clone();
        state["devices"] = json!([]);
        assert_eq!(
            ReadinessSummary::from_snapshot(&state, true).action,
            ReadinessAction::PairDevice
        );
        state["pairingFresh"] = json!(false);
        assert!(ReadinessSummary::from_snapshot(&state, true)
            .detail
            .contains("could not check"));
        state.as_object_mut().unwrap().remove("pairingFresh");
        assert_eq!(
            ReadinessSummary::from_snapshot(&state, true).action,
            ReadinessAction::PairDevice
        );

        let mut state = healthy.clone();
        state["screen"] = json!("Needs attention");
        let summary = ReadinessSummary::from_snapshot(&state, true);
        assert_eq!(summary.title, "Ready for messages");
        assert_eq!(summary.action, ReadinessAction::ReviewAccess);
        assert!(summary.detail.contains("Screen Recording"));

        let mut state = healthy.clone();
        state["screen"] = json!("Unavailable");
        let summary = ReadinessSummary::from_snapshot(&state, true);
        assert_eq!(summary.title, "Ready for chats");
        assert_eq!(summary.action, ReadinessAction::ReviewAccess);

        let mut state = healthy.clone();
        state["screen"] = json!("Unexpected value");
        let summary = ReadinessSummary::from_snapshot(&state, true);
        assert!(!summary.fully_ready);
        assert_eq!(summary.action, ReadinessAction::ReviewAccess);

        let mut state = healthy;
        state["updatePreparing"] = json!(true);
        let summary = ReadinessSummary::from_snapshot(&state, true);
        assert_eq!(summary.title, "Preparing an update");
        assert_eq!(summary.action, ReadinessAction::None);
    }
}
