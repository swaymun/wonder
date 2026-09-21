use crate::*;
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use serde_json::{json, Value};

fn effort_label(value: &str) -> String {
    let mut chars = value.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

fn speed_label(id: &str, label: &str) -> String {
    if id == "default" {
        "Default".to_owned()
    } else {
        effort_label(label)
    }
}

fn speed_detail(value: &str) -> String {
    value
        .replace("Standard speed, standard usage", "Default speed and usage")
        .replace("2x", "2×")
        .replace("1.5x", "1.5×")
}

impl Chats {
    pub(super) fn tick_settings(&mut self, cx: &mut Context<Self>) {
        while let Ok(result) = self.settings_receiver.try_recv() {
            self.settings_saving = false;
            self.composer_options = Value::Null;
            match result {
                Ok(bot) => {
                    if let Some(bots) = self.bots.as_array_mut() {
                        if let Some(saved) = bots.iter_mut().find(|saved| saved["id"] == bot["id"])
                        {
                            *saved = bot;
                        }
                    }
                    self.error = None;
                }
                Err(error) => self.error = Some(error),
            }
            self.last_refresh = Instant::now() - Duration::from_secs(3);
            cx.notify();
        }
    }
    fn save_composer_settings(&mut self, bot: String, patch: Value, cx: &mut Context<Self>) {
        if self.busy || self.settings_saving {
            return;
        }
        let (Some(connection), Some(host)) = (self.connection.clone(), self.host.clone()) else {
            return;
        };
        self.settings_saving = true;
        self.error = None;
        let sender = self.settings_sender.clone();
        std::thread::spawn(move || {
            let parts = ["api", "v1", "bots", &bot].map(String::from);
            let _ = sender.send(connection.request("PATCH", &parts, &patch, &host));
        });
        cx.notify();
    }
    pub(super) fn composer_settings(&self, cx: &mut Context<Self>) -> Div {
        let bot = self.bots.as_array().into_iter().flatten().find(|bot| {
            self.selected
                .as_deref()
                .is_some_and(|id| bot["conversationId"] == id)
        });
        let Some(bot) = bot.cloned() else {
            return div();
        };
        let bot_id = bot["id"].as_str().unwrap_or_default().to_owned();
        let approval = bot["approvalMode"].as_str().unwrap_or_else(|| {
            if bot["permissionMode"] == "full-access" { "full-access" } else { "ask-for-approval" }
        });
        let approval_title = match approval {
            "ask-for-approval" => "Ask for approval",
            "approve-for-me" => "Approve for me",
            "full-access" => "Full access",
            _ => "Ask for approval",
        };
        let models = self.composer_options["models"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let selected = models.iter().find(|m| m["id"] == bot["model"]);
        let model_name = selected
            .and_then(|m| m["displayName"].as_str())
            .or(bot["model"].as_str())
            .unwrap_or("Default model");
        let effort = effort_label(bot["reasoningEffort"].as_str().unwrap_or_default());
        let service_tier = bot["serviceTier"].as_str().unwrap_or("default").to_owned();
        let speed = selected
            .and_then(|model| model["serviceTiers"].as_array())
            .and_then(|tiers| tiers.iter().find(|tier| tier["id"] == service_tier))
            .filter(|tier| tier["id"] != "default")
            .and_then(|tier| tier["label"].as_str())
            .map(effort_label);
        let title = [
            Some(model_name.to_owned()),
            (!effort.is_empty()).then_some(effort),
            speed,
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" · ");
        let disabled = self.busy || self.settings_saving || bot["isArchived"] == true;
        let view = cx.entity().downgrade();
        let permission_bot = bot_id.clone();
        let current_approval = approval.to_owned();
        let modes = self.composer_options["approvalModes"].clone();
        let approval_modes_available = modes.is_array();
        let permission_menu_view = cx.entity().downgrade();
        let model_menu_view = cx.entity().downgrade();
        let permission_button = Button::new("composer-permissions")
            .ghost()
            .label(approval_title)
            .text_color(cx.theme().muted_foreground)
            .icon(IconName::ChevronDown)
            .disabled(disabled || !approval_modes_available)
            .dropdown_menu_with_anchor(Anchor::BottomLeft, move |mut menu, _, _| {
                for (id, title, detail) in [
                    (
                        "ask-for-approval",
                        "Ask for approval",
                        "Ask you before actions that need approval.",
                    ),
                    (
                        "approve-for-me",
                        "Approve for me",
                        "Approve eligible actions automatically within this Bot’s access.",
                    ),
                    (
                        "full-access",
                        "Full access",
                        "Unrestricted files and network; no approval prompts.",
                    ),
                ] {
                    let view = view.clone();
                    let bot = permission_bot.clone();
                    let allowed = modes.as_array().is_some_and(|modes| {
                        modes.iter().any(|m| m["id"] == id && m["allowed"] == true)
                    });
                    let selected = current_approval == id;
                    menu = menu
                        .item(
                            PopupMenuItem::new(title)
                                .checked(selected)
                                .disabled(!allowed)
                                .on_click(move |_, _, cx| {
                                    if selected {
                                        return;
                                    }
                                    let _ = view.update(cx, |this, cx| {
                                        this.save_composer_settings(
                                            bot.clone(),
                                            json!({"approvalMode":id}),
                                            cx,
                                        )
                                    });
                                }),
                        )
                        .label(detail);
                }
                menu
            })
            .on_open_change(move |open, _, cx| {
                let _ = permission_menu_view.update(cx, |this, _| this.composer_menu_open = *open);
            });
        let view = cx.entity().downgrade();
        let model_button = Button::new("composer-model")
            .ghost()
            .label(title)
            .icon(IconName::ChevronDown)
            .disabled(disabled || self.composer_options.is_null())
            .dropdown_menu_with_anchor(Anchor::BottomRight, move |mut menu, _, _| {
                let mut choices = vec![("".to_owned(), "Default model".to_owned())];
                choices.extend(
                    models
                        .iter()
                        .filter(|m| m["hidden"] != true)
                        .filter_map(|m| {
                            Some((
                                m["id"].as_str()?.to_owned(),
                                m["displayName"].as_str()?.to_owned(),
                            ))
                        }),
                );
                for (id, name) in choices {
                    let view = view.clone();
                    let target = bot_id.clone();
                    menu = menu.item(
                        PopupMenuItem::new(name)
                            .checked(bot["model"].as_str().unwrap_or_default() == id)
                            .on_click(move |_, _, cx| {
                                let _ = view.update(cx, |this, cx| {
                                    this.save_composer_settings(
                                        target.clone(),
                                        json!({"model":id,"reasoningEffort":"","serviceTier":"default"}),
                                        cx,
                                    )
                                });
                            }),
                    );
                }
                if let Some(model) = models.iter().find(|m| m["id"] == bot["model"]) {
                    menu = menu.separator().label("Reasoning");
                    let mut efforts = vec![("".to_owned(), "Default".to_owned())];
                    efforts.extend(
                        model["reasoningEfforts"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|e| {
                                Some((
                                    e["id"].as_str()?.to_owned(),
                                    effort_label(e["label"].as_str()?),
                                ))
                            }),
                    );
                    for (id, name) in efforts {
                        let view = view.clone();
                        let target = bot_id.clone();
                        menu = menu.item(
                            PopupMenuItem::new(name)
                                .checked(bot["reasoningEffort"].as_str().unwrap_or_default() == id)
                                .on_click(move |_, _, cx| {
                                    let _ = view.update(cx, |this, cx| {
                                        this.save_composer_settings(
                                            target.clone(),
                                            json!({"reasoningEffort":id}),
                                            cx,
                                        )
                                    });
                                }),
                        );
                    }
                    if let Some(tiers) = model["serviceTiers"].as_array().filter(|tiers| tiers.len() > 1) {
                        menu = menu.separator().label("Speed");
                        for tier in tiers {
                            let Some(id) = tier["id"].as_str() else { continue };
                            let label = speed_label(id, tier["label"].as_str().unwrap_or(id));
                            let detail = speed_detail(tier["description"].as_str().unwrap_or_default());
                            let selected = service_tier == id;
                            let view = view.clone();
                            let target = bot_id.clone();
                            let id = id.to_owned();
                            menu = menu.item(
                                PopupMenuItem::new(label)
                                    .checked(selected)
                                    .on_click(move |_, _, cx| {
                                        if selected { return; }
                                        let _ = view.update(cx, |this, cx| {
                                            this.save_composer_settings(
                                                target.clone(),
                                                json!({"serviceTier":id}),
                                                cx,
                                            )
                                        });
                                    }),
                            );
                            if !detail.is_empty() { menu = menu.label(detail); }
                        }
                    }
                }
                menu
            })
            .on_open_change(move |open, _, cx| {
                let _ = model_menu_view.update(cx, |this, _| this.composer_menu_open = *open);
            });
        div()
            .flex()
            .w_full()
            .items_center()
            .justify_between()
            .flex_wrap()
            .gap_2()
            .child(permission_button)
            .when(self.settings_saving, |v| v.child("Saving…"))
            .child(model_button)
            .when(!approval_modes_available, |v| {
                v.child("Update Wonder on your Mac to change approval settings.")
            })
    }
}
