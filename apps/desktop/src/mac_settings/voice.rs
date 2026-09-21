use super::*;
use crate::client::Connection;

type Response = Result<(Value, String), String>;

pub(super) struct VoiceSettings {
    state: Value,
    host: String,
    pub(super) pending: bool,
    error: Option<String>,
    receiver: mpsc::Receiver<Response>,
    sender: mpsc::Sender<Response>,
    last_poll: Instant,
    delete: Option<String>,
    details: bool,
}
impl Default for VoiceSettings {
    fn default() -> Self {
        let (sender, receiver) = mpsc::channel();
        Self {
            state: Value::Null,
            host: String::new(),
            pending: false,
            error: None,
            receiver,
            sender,
            last_poll: Instant::now(),
            delete: None,
            details: false,
        }
    }
}
impl VoiceSettings {
    fn request(&mut self, action: Option<(&str, Vec<String>)>) {
        if self.pending {
            return;
        }
        self.pending = true;
        self.error = None;
        let sender = self.sender.clone();
        let expected_host = self.host.clone();
        let action = action.map(|(method, path)| (method.to_owned(), path));
        std::thread::spawn(move || {
            let result = (|| {
                let connection = Connection::from_environment()?;
                let host = connection.get(&["api", "v1", "host", "status"])?;
                let host = host["hostInstallationId"]
                    .as_str()
                    .filter(|v| !v.is_empty())
                    .ok_or("Couldn’t identify this Mac. Reopen Wonder.")?
                    .to_owned();
                if let Some((method, path)) = action {
                    if host != expected_host {
                        return Err("Mac identity changed. Refresh before trying again.".into());
                    }
                    connection.request(&method, &path, &json!({}), &host)?;
                }
                let state = connection.get(&["api", "v1", "asr", "models"])?;
                Ok((state, host))
            })();
            let _ = sender.send(result);
        });
    }
    pub(super) fn setup_continue_label(&self) -> &'static str {
        if self.state["ready"] == true {
            "Continue"
        } else if array(&self.state, "models")
            .iter()
            .any(|model| text(model, "downloadState") == "downloading")
        {
            "Continue while downloading"
        } else {
            "Set up later"
        }
    }
    pub(super) fn refresh(&mut self) {
        self.request(None);
    }
    pub(super) fn tick(&mut self, visible: bool) -> bool {
        let mut changed = false;
        while let Ok(result) = self.receiver.try_recv() {
            changed = true;
            self.pending = false;
            self.last_poll = Instant::now();
            match result {
                Ok((state, host)) => {
                    self.state = state;
                    self.host = host;
                    self.error = None;
                }
                Err(error) => self.error = Some(error),
            }
        }
        let downloading = array(&self.state, "models")
            .iter()
            .any(|m| matches!(text(m, "downloadState"), "downloading" | "cancelling"));
        if visible
            && !self.pending
            && self.error.is_none()
            && self.last_poll.elapsed() >= Duration::from_secs(if downloading { 1 } else { 5 })
        {
            self.refresh();
        }
        changed
    }
}
impl MacSettings {
    #[allow(clippy::too_many_arguments)]
    fn voice_action(
        &self,
        id: String,
        label: &str,
        method: &'static str,
        model: &str,
        suffix: Option<&str>,
        disabled: bool,
        cx: &Context<Self>,
    ) -> Button {
        let mut path = vec![
            "api".into(),
            "v1".into(),
            "asr".into(),
            "models".into(),
            model.to_owned(),
        ];
        if let Some(suffix) = suffix {
            path.push(suffix.to_owned());
        }
        Button::new(id)
            .self_start()
            .label(label.to_owned())
            .disabled(disabled || self.voice.pending || self.voice.error.is_some())
            .on_click(cx.listener(move |this, _, _, cx| {
                this.voice.delete = None;
                this.voice.request(Some((method, path.clone())));
                cx.notify();
            }))
    }
    pub(super) fn voice_content(&self, cx: &Context<Self>) -> Div {
        let mut view = stack().gap_4()
            .when(self.state["setupCompleted"] == true || self.state["setupStep"] != 5, |v| v.child(note("On-device dictation").role(Role::Heading).text_xl().font_weight(FontWeight::SEMIBOLD)))
            .child(note("Record up to five minutes from a paired iPhone or iPad. Audio is transcribed locally on this Mac."));
        if let Some(error) = &self.voice.error {
            view = view
                .child(note(error.clone()).text_color(cx.theme().danger))
                .child(
                    Button::new("retry-dictation")
                        .label("Try again")
                        .disabled(self.voice.pending)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.voice.refresh();
                            cx.notify();
                        })),
                );
        }
        if self.voice.state.is_null() {
            return view.child(note(if self.voice.pending {
                "Checking dictation…"
            } else {
                "Dictation status is unavailable."
            }));
        }
        if self.voice.state["decoderAvailable"] == false {
            view = view.child(note(
                "Dictation needs an audio component. Reinstall Wonder to finish setup.",
            ));
        } else if self.voice.state["ready"] == false
            && array(&self.voice.state, "models")
                .iter()
                .any(|m| m["installed"] == true && m["runtimeAvailable"] == true)
        {
            view = view.child(note("Dictation isn’t ready. Enable the installed model below, or reinstall Wonder if it is already enabled."));
        }
        for model in array(&self.voice.state, "models") {
            let id = text(model, "id");
            let installed = model["installed"] == true;
            let runtime = model["runtimeAvailable"] == true;
            let selected = self.voice.state["selectedModelId"] == id;
            let download = text(model, "downloadState");
            let in_use = model["inUse"] == true;
            let downloading = matches!(download, "downloading" | "cancelling");
            let size = storage_label(model["bytes"].as_u64().unwrap_or(0));
            let status = if downloading {
                "Installing"
            } else if installed {
                "Installed"
            } else {
                "Not installed"
            };
            let mut model_view = stack()
                .gap_3()
                .child(note(format!("{status} · {size}")).text_color(cx.theme().muted_foreground));
            if !runtime {
                model_view =
                    model_view.child(note("Reinstall Wonder to enable dictation on this Mac."));
            }
            if in_use {
                model_view = model_view.child(note(
                    "Transcribing… The model can be removed when this finishes.",
                ));
            }
            if downloading {
                model_view = model_view
                    .child(note(if download == "cancelling" {
                        "Cancelling installation…".into()
                    } else {
                        format!(
                            "{} of {size} downloaded",
                            storage_label(model["downloadedBytes"].as_u64().unwrap_or(0))
                        )
                    }))
                    .child(self.voice_action(
                        format!("cancel-{id}"),
                        "Cancel download",
                        "DELETE",
                        id,
                        Some("download"),
                        download == "cancelling",
                        cx,
                    ));
            } else if !installed {
                if download == "failed" {
                    model_view = model_view.child(note(
                        "Installation failed. Check your connection and try again.",
                    ));
                }
                model_view = model_view.child(
                    self.voice_action(
                        format!("download-{id}"),
                        if download == "failed" {
                            "Try again"
                        } else {
                            "Install dictation"
                        },
                        "POST",
                        id,
                        Some("download"),
                        !runtime || in_use,
                        cx,
                    )
                    .primary(),
                );
            } else {
                if !selected {
                    model_view = model_view.child(self.voice_action(
                        format!("select-{id}"),
                        "Enable dictation",
                        "POST",
                        id,
                        Some("select"),
                        !runtime || in_use,
                        cx,
                    ));
                }
                if self.voice.delete.as_deref() == Some(id) {
                    model_view = model_view.child(note("Remove this model? Dictation will be unavailable until you install it again."))
                        .child(div().flex().gap_2()
                            .child(self.voice_action(format!("confirm-delete-{id}"), "Remove model", "DELETE", id, None, model["canDelete"] != true, cx))
                            .child(Button::new("keep-model").label("Cancel").on_click(cx.listener(|this, _, _, cx| { this.voice.delete = None; cx.notify(); }))));
                } else {
                    let id = id.to_owned();
                    model_view = model_view.child(
                        Button::new(format!("delete-{id}"))
                            .label("Remove model")
                            .self_start()
                            .disabled(
                                model["canDelete"] != true
                                    || self.voice.pending
                                    || self.voice.error.is_some(),
                            )
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.voice.delete = Some(id.clone());
                                cx.notify();
                            })),
                    );
                }
            }
            model_view = model_view.child(
                Button::new(format!("details-{id}"))
                    .label(if self.voice.details {
                        "Hide advanced details"
                    } else {
                        "Advanced details"
                    })
                    .ghost()
                    .self_start()
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.voice.details = !this.voice.details;
                        cx.notify();
                    })),
            );
            if self.voice.details {
                model_view = model_view
                    .child(row("Model", text(model, "name")))
                    .child(row("License", text(model, "license")))
                    .child(note(format!(
                        "{} languages supported",
                        array(model, "supportedLanguages").len()
                    )))
                    .child(note(
                        array(model, "supportedLanguages")
                            .iter()
                            .filter_map(Value::as_str)
                            .map(language_name)
                            .collect::<Vec<_>>()
                            .join(", "),
                    ));
            }

            view = view.child(settings_section(
                if id.to_lowercase().contains("parakeet") {
                    "Parakeet"
                } else {
                    text(model, "name")
                },
                model_view,
                cx,
            ));
        }
        view
    }
}

fn storage_label(bytes: u64) -> String {
    if bytes >= 1_000_000_000 {
        format!("{:.1} GB", bytes as f64 / 1_000_000_000.)
    } else {
        format!("{:.0} MB", bytes as f64 / 1_000_000.)
    }
}

fn language_name(code: &str) -> &str {
    match code {
        "bg" => "Bulgarian",
        "hr" => "Croatian",
        "cs" => "Czech",
        "da" => "Danish",
        "nl" => "Dutch",
        "en" => "English",
        "et" => "Estonian",
        "fi" => "Finnish",
        "fr" => "French",
        "de" => "German",
        "el" => "Greek",
        "hu" => "Hungarian",
        "it" => "Italian",
        "lv" => "Latvian",
        "lt" => "Lithuanian",
        "mt" => "Maltese",
        "pl" => "Polish",
        "pt" => "Portuguese",
        "ro" => "Romanian",
        "ru" => "Russian",
        "sk" => "Slovak",
        "sl" => "Slovenian",
        "es" => "Spanish",
        "sv" => "Swedish",
        "uk" => "Ukrainian",
        _ => code,
    }
}

#[cfg(test)]
mod tests {
    use super::{storage_label, VoiceSettings};
    use serde_json::json;
    use std::time::{Duration, Instant};
    #[test]
    fn storage_uses_readable_decimal_units() {
        assert_eq!(storage_label(713975456), "714 MB");
        assert_eq!(storage_label(1500000000), "1.5 GB");
    }
    #[test]
    fn failed_poll_preserves_model_state_and_stops_automatic_retry() {
        let mut voice = VoiceSettings::default();
        voice.state = json!({"models":[{"id":"parakeet", "downloadState":"downloading", "downloadedBytes":42}]});
        voice.pending = true;
        voice.sender.send(Err("Mac unavailable".into())).unwrap();
        assert!(voice.tick(true));
        assert!(!voice.pending);
        assert_eq!(voice.state["models"][0]["downloadedBytes"], 42);
        voice.last_poll = Instant::now() - Duration::from_secs(10);
        assert!(!voice.tick(true));
        assert!(!voice.pending);
        assert_eq!(voice.error.as_deref(), Some("Mac unavailable"));
    }
    #[test]
    fn refreshed_status_replaces_old_host_and_clears_failure() {
        let mut voice = VoiceSettings::default();
        voice.host = "old-host".into();
        voice.error = Some("Offline".into());
        voice.pending = true;
        let state = json!({"ready":true,"models":[{"id":"parakeet","downloadState":"idle","installed":true}]});
        voice
            .sender
            .send(Ok((state.clone(), "current-host".into())))
            .unwrap();
        assert!(voice.tick(true));
        assert_eq!(voice.state, state);
        assert_eq!(voice.host, "current-host");
        assert!(voice.error.is_none());
        assert!(!voice.pending);
    }
}
