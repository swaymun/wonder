use super::*;

fn settings_patch(bot: &Value, fields: &Value, options: &Value) -> Result<Value, String> {
    let mut patch = json!({});
    for field in ["model", "reasoningEffort", "serviceTier", "approvalMode"] {
        // Older saved forms omit approvalMode. Omission preserves access; it
        // must not become an explicit empty/Ask permission update.
        if field == "approvalMode" && !fields[field].is_string() { continue; }
        let value = strv(fields, field);
        let old = if field == "approvalMode" && bot["approvalMode"].is_null() {
            if bot["permissionMode"] == "full-access" { "full-access" } else { "ask-for-approval" }
        } else {
            strv(bot, field)
        };
        if field == "approvalMode" && bot["approvalMode"].is_null() && value == old {
            continue;
        }
        if value == old || (field == "serviceTier" && value.is_empty() && old == "default") {
            continue;
        }
        if field == "approvalMode"
            && !options["approvalModes"].as_array().is_some_and(|modes| {
                modes
                    .iter()
                    .any(|m| m["id"] == value && m["allowed"] == true)
            })
        {
            return Err("Approval settings are unavailable. Update Wonder on your Mac, then try again.".into());
        }
        patch[field] = json!(if field == "serviceTier" && value.is_empty() {
            "default"
        } else {
            value
        });
    }
    if patch.get("model").is_some() {
        // A model change clears old overrides unless the owner explicitly chose new ones.
        patch["reasoningEffort"] = json!(strv(fields, "reasoningEffort"));
        patch["serviceTier"] = json!(if strv(fields, "serviceTier").is_empty() {
            "default"
        } else {
            strv(fields, "serviceTier")
        });
    }
    Ok(patch)
}

impl Manager {
    pub(super) fn open_group_bot(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let bot = self
            .bots
            .iter()
            .find(|b| b["id"] == id)
            .cloned()
            .unwrap_or(Value::Null);
        let current = match bot["approvalMode"].as_str() {
            Some(value) if !value.is_empty() => value,
            _ if bot["permissionMode"] == "full-access" => "full-access",
            _ => "ask-for-approval",
        };
        let mut modes = self.options["approvalModes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|m| m["allowed"] == true)
            .map(|m| Choice {
                id: strv(m, "id").into(),
                label: match strv(m, "id") {
                    "ask-for-approval" => "Ask for approval",
                    "approve-for-me" => "Approve for me",
                    "full-access" => "Full access",
                    other => other,
                }
                .into(),
            })
            .collect::<Vec<_>>();
        if !modes.iter().any(|m| m.id == current) {
            modes.push(Choice {
                id: current.into(),
                label: if current.is_empty() {
                    "Ask for approval".into()
                } else {
                    match current {
                        "full-access" => "Full access (unavailable)".into(),
                        "approve-for-me" => "Approve for me (unavailable)".into(),
                        _ => "Ask for approval (unavailable)".into(),
                    }
                },
            });
        }
        self.form
            .select("approvalMode", current, modes, window, cx);
        self.model_fields(&bot, false, window, cx);
    }

    pub(super) fn group_member_settings(&self, group_id: &str, cx: &mut Context<Self>) -> Div {
        let mut view = div().flex().flex_col().gap_2().child(
            div()
                .font_weight(FontWeight::MEDIUM)
                .child("Member settings"),
        );
        if let Some(group) = self.groups.iter().find(|g| g["id"] == group_id) {
            for (index, member) in group["members"]
                .as_array()
                .into_iter()
                .flatten()
                .enumerate()
            {
                let id = strv(member, "botId").to_owned();
                let group_id = group_id.to_owned();
                let name = strv(member, "botName");
                let lead = member["botId"] == group["coordinatorBotId"];
                let bot = self.bots.iter().find(|b| b["id"] == id);
                view = view.child(
                    Button::new(("group-member-settings", index))
                        .ghost()
                        .label(format!("{}{}", name, if lead { " · Lead Bot" } else { "" }))
                        .icon(IconName::ChevronRight)
                        .accessibility_label(format!("Settings for {name}"))
                        .disabled(
                            self.busy
                                || self.pending.is_some()
                                || bot.is_none_or(|b| b["isArchived"] == true),
                        )
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open(Page::GroupBot(group_id.clone(), id.clone()), window, cx)
                        })),
                );
            }
        }
        view
    }

    pub(super) fn group_bot_form(&self, bot_id: &str, cx: &mut Context<Self>) -> Div {
        let disabled = self.busy || self.pending.is_some() || self.options.is_null();
        let mut view = div().flex().flex_col().gap_4().child(
            div()
                .text_sm()
                .text_color(cx.theme().muted_foreground)
                .child("Changes apply to this Bot in all chats."),
        );
        for (key, title) in [
            ("model", "Model"),
            ("reasoningEffort", "Reasoning"),
            ("serviceTier", "Speed"),
            ("approvalMode", "Approval"),
        ] {
            view = view.child(self.form.field(key, title, disabled));
        }
        let detail = match self.form.value("approvalMode", cx).as_str() {
            "ask-for-approval" => "Ask you before actions that need approval.",
            "approve-for-me" => "Approve eligible actions automatically within this Bot’s access.",
            "full-access" => "Unrestricted files and network; no approval prompts. macOS permissions still apply.",
            _ => "Existing location grants remain active.",
        };
        let bot = self.bots.iter().find(|b| b["id"] == bot_id);
        let changed = bot
            .and_then(|b| settings_patch(b, &self.form.snapshot(cx), &self.options).ok())
            .is_some_and(|p| p.as_object().is_some_and(|p| !p.is_empty()));
        let access_bot = bot_id.to_owned();
        view.child(
            if !self.options["approvalModes"].is_array() {
                div().text_sm().text_color(cx.theme().muted_foreground).child("Update Wonder on your Mac to change approval settings.")
            } else {
                div()
            },
        )
        .child(
            Button::new("member-file-access")
                .label("Workspace and file access…")
                .disabled(disabled)
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.open(Page::FileAccess(access_bot.clone()), window, cx)
                })),
        )
        .child(
            div()
                .text_sm()
                .text_color(cx.theme().muted_foreground)
                .child(detail),
        )
        .child(
            Button::new("save-member-settings")
                .primary()
                .label("Save settings")
                .disabled(disabled || !changed)
                .on_click(cx.listener(|this, _, _, cx| this.submit(cx))),
        )
    }

    pub(super) fn group_bot_body(
        &self,
        group: &str,
        bot: &str,
        cx: &App,
    ) -> Result<(&'static str, Vec<String>, Value, &'static str), String> {
        if !self.groups.iter().any(|g| {
            g["id"] == group
                && g["members"]
                    .as_array()
                    .is_some_and(|m| m.iter().any(|m| m["botId"] == bot))
        }) {
            return Err("This Bot is no longer in the Group. Reopen Group settings.".into());
        }
        let current = self
            .bots
            .iter()
            .find(|b| b["id"] == bot && b["isArchived"] != true)
            .ok_or("This Bot is unavailable. Reopen Group settings.")?;
        let patch = settings_patch(current, &self.form.snapshot(cx), &self.options)?;
        if patch.as_object().is_none_or(|p| p.is_empty()) {
            return Err("These settings are already saved.".into());
        }
        Ok((
            "PATCH",
            route(&["api", "v1", "bots", bot]),
            patch,
            "group-bot",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::settings_patch;
    use serde_json::json;
    #[test]
    fn model_change_resets_overrides_without_touching_permissions() {
        let bot = json!({"model":"old","reasoningEffort":"high","serviceTier":"priority"});
        let patch = settings_patch(
            &bot,
            &json!({"model":"new","reasoningEffort":"","serviceTier":"","permissionMode":""}),
            &json!({}),
        )
        .unwrap();
        assert_eq!(
            patch,
            json!({"model":"new","reasoningEffort":"","serviceTier":"default"})
        );
    }
    #[test]
    fn unrelated_settings_preserve_legacy_grants_and_forbid_disallowed_modes() {
        let bot = json!({"model":"same","permissionMode":null});
        assert_eq!(
            settings_patch(
                &bot,
                &json!({"model":"same","permissionMode":""}),
                &json!({})
            )
            .unwrap(),
            json!({})
        );
        assert!(settings_patch(
            &bot,
            &json!({"model":"same","approvalMode":"full-access"}),
            &json!({"approvalModes":[{"id":"full-access","allowed":false}]})
        )
        .is_err());
    }

    #[test]
    fn legacy_full_access_display_does_not_create_a_permission_patch() {
        let bot = json!({"permissionMode":"full-access"});
        assert_eq!(settings_patch(&bot, &json!({"approvalMode":"full-access"}), &json!({})).unwrap(), json!({}));
        assert_eq!(settings_patch(&bot, &json!({}), &json!({})).unwrap(), json!({}));
    }
}
