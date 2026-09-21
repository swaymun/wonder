use super::*;
use crate::science_avatar;

impl Manager {
    fn bots_view(&self, archived: bool, cx: &mut Context<Self>) -> Div {
        let mut view = div().flex().flex_col().gap_3().child(
            div()
                .flex()
                .gap_2()
                .child(
                    Button::new("new-bot")
                        .primary()
                        .label("New Bot")
                        .disabled(self.busy || self.pending.is_some())
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.open(Page::Bot(None), window, cx)
                        })),
                )
                .child(
                    Button::new("new-group")
                        .label("New Group")
                        .disabled(self.busy || self.pending.is_some())
                        .on_click(
                            cx.listener(|this, _, window, cx| this.open(Page::Group, window, cx)),
                        ),
                )
                .child(
                    Button::new("archived-bots")
                        .ghost()
                        .label(if archived {
                            "Active Bots"
                        } else {
                            "Archived Bots"
                        })
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open(Page::Bots(!archived), window, cx)
                        })),
                ),
        );
        let bots: Vec<_> = self
            .bots
            .iter()
            .filter(|b| (b["isArchived"] == true) == archived)
            .collect();
        if bots.is_empty() {
            view = view.child(div().py_6().text_color(cx.theme().muted_foreground).child(
                if archived {
                    "No archived Bots."
                } else {
                    "Create your first Bot to start a conversation."
                },
            ));
        }
        for bot in bots {
            let id = strv(bot, "id").to_owned();
            let name = strv(bot, "name").to_owned();
            let scope = self.scope(bot);
            let mut row = div()
                .flex()
                .items_center()
                .gap_3()
                .py_3()
                .border_b_1()
                .border_color(cx.theme().border)
                .child(science_avatar::avatar(
                    &name,
                    &id,
                    bot["avatarShape"].as_str(),
                    bot["avatarPalette"].as_str(),
                    bot["avatarColor"].as_str(),
                    34.,
                ))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .child(div().font_weight(FontWeight::SEMIBOLD).child(name.clone()))
                        .child(
                            div()
                                .text_sm()
                                .text_color(cx.theme().muted_foreground)
                                .child(strv(bot, "role").to_owned()),
                        ),
                );
            if archived {
                let restore = id.clone();
                let delete = id.clone();
                let delete_name = name.clone();
                row=row.child(Button::new(SharedString::from(format!("restore-{id}"))).label("Restore").disabled(self.busy||self.pending.is_some()).on_click(cx.listener(move|this,_,_,cx|this.write("POST",route(&["api","v1","bots",&restore,"unarchive"]),json!({}),"archive",cx))))
                    .child(Button::new(SharedString::from(format!("delete-{id}"))).ghost().label("Delete forever").disabled(self.busy||self.pending.is_some()).on_click(cx.listener(move|this,_,window,cx|this.open(Page::Confirm{title:"Delete Bot forever".into(),explanation:format!("Delete {delete_name} and its owned chat history and workspace permanently. Shared files stay in place. This cannot be undone. Type the Bot’s name to confirm."),name:Some(delete_name.clone()),method:"DELETE".into(),path:route(&["api","v1","bots",&delete]),body:Value::Null,completion:"delete".into()},window,cx))));
            } else {
                row = row.child(
                    Button::new(SharedString::from(format!("bot-{id}")))
                        .label("Details")
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open(Page::Details(scope.clone()), window, cx)
                        })),
                );
            }
            view = view.child(row);
        }
        view
    }
    fn details_view(&self, scope: &Scope, cx: &mut Context<Self>) -> Div {
        let mut view = div().flex().flex_col().gap_4();
        let conversation = scope.conversation.clone();
        let automations = scope.clone();
        view = view.child(
            div()
                .flex()
                .gap_2()
                .when(!self.is_inspector(), |v| {
                    v.child(
                        Button::new("open-conversation")
                            .primary()
                            .label("Open chat")
                            .on_click(cx.listener(move |_, _, _, cx| {
                                cx.emit(Event::Open(conversation.clone()))
                            })),
                    )
                })
                .child(
                    Button::new("automations")
                        .label("Automations")
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open(Page::Automations(automations.clone()), window, cx)
                        })),
                ),
        );
        if scope.kind == "bot" {
            if let Some(bot) = self.bots.iter().find(|b| b["id"] == scope.id) {
                let id = scope.id.clone();
                let access_id = id.clone();
                let archive = id.clone();
                let name = scope.title.clone();
                view=view.child(div().text_color(cx.theme().muted_foreground).child(strv(bot,"role").to_owned()))
                    .when(strv(bot,"systemPrompt") != strv(bot,"role"), |v| v.child(div().child(strv(bot,"systemPrompt").to_owned())))
                    .child(div().text_sm().child(format!("Workspace: {}",bot["workingDirectory"].as_str().unwrap_or(strv(bot,"workspacePath")))))
                    .child(div().flex().flex_wrap().gap_2().child(Button::new("edit-bot").label("Edit Bot").disabled(self.pending.is_some()).on_click(cx.listener(move|this,_,window,cx|this.open(Page::Bot(Some(id.clone())),window,cx))))
                        .child(Button::new("file-access").label("File access").disabled(self.pending.is_some()).on_click(cx.listener(move|this,_,window,cx|this.open(Page::FileAccess(access_id.clone()),window,cx))))
                        .child(Button::new("archive-bot").ghost().label("Archive Bot").disabled(self.pending.is_some()).on_click(cx.listener(move|this,_,window,cx|this.open(Page::Confirm{title:"Archive Bot".into(),explanation:format!("Archive {name}? Its conversation and files stay saved. You can restore it from Archived Bots."),name:None,method:"POST".into(),path:route(&["api","v1","bots",&archive,"archive"]),body:json!({}),completion:"archive".into()},window,cx)))));
            }
        } else if let Some(group) = self.groups.iter().find(|g| g["id"] == scope.id) {
            view = view.child(div().child(strv(group, "description").to_owned()));
            let edit_id = scope.id.clone();
            view = view.child(
                Button::new("edit-group")
                    .label("Group settings")
                    .disabled(self.pending.is_some())
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open(Page::GroupEdit(edit_id.clone()), window, cx)
                    })),
            );
            let assignments = scope.clone();
            view = view.child(
                Button::new("group-assignments")
                    .label("Assignments")
                    .disabled(self.busy)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open(Page::Assignments(assignments.clone()), window, cx)
                    })),
            );
            let coordinator = strv(group, "coordinatorBotId");
            for member in group["members"].as_array().into_iter().flatten() {
                let name = member["botName"].as_str().unwrap_or("Bot");
                view = view.child(
                    div()
                        .flex()
                        .items_center()
                        .gap_3()
                        .child(science_avatar::avatar(
                            name,
                            member["botId"].as_str().unwrap_or(name),
                            self.bots
                                .iter()
                                .find(|bot| bot["id"] == member["botId"])
                                .and_then(|bot| bot["avatarShape"].as_str()),
                            self.bots
                                .iter()
                                .find(|bot| bot["id"] == member["botId"])
                                .and_then(|bot| bot["avatarPalette"].as_str()),
                            self.bots
                                .iter()
                                .find(|bot| bot["id"] == member["botId"])
                                .and_then(|bot| bot["avatarColor"].as_str()),
                            28.,
                        ))
                        .child(format!(
                            "{name}{}",
                            if member["botId"] == coordinator {
                                " · Lead Bot"
                            } else {
                                ""
                            }
                        )),
                );
            }
        }
        view
    }
    fn bot_form(&self, id: &Option<String>, cx: &mut Context<Self>) -> Div {
        let disabled = self.busy || self.pending.is_some();
        let mut view = div().flex().flex_col().gap_4();
        for (key, label) in [("name", "Name"), ("role", "Purpose")] {
            view = view.child(self.form.field(key, label, disabled));
        }
        view = view.child(self.avatar_picker(id, cx));
        let permission = self.form.value("permissionMode", cx);
        let approval = self.form.value("approvalMode", cx);
        view = view.child(self.form.field("approvalMode", "Approval", disabled || !self.options["approvalModes"].is_array()))
            .child(div().text_sm().text_color(cx.theme().muted_foreground).child(match approval.as_str() {
                "ask-for-approval" => "Ask you before actions that need approval.",
                "approve-for-me" => "Approve eligible actions automatically within this Bot’s access.",
                "full-access" => "Unrestricted files and network; no approval prompts. macOS permissions still apply.",
                _ => "Choose an approval setting.",
            }));
        if !self.options["approvalModes"].is_array() {
            view = view.child(div().text_sm().text_color(cx.theme().muted_foreground).child("Update Wonder on your Mac to change approval settings."));
        }
        if let Some(id) = id {
            let id = id.clone();
            view = view.child(
                Button::new("edit-bot-file-access")
                    .label("File access…")
                    .disabled(disabled)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open(Page::FileAccess(id.clone()), window, cx)
                    })),
            );
        } else {
            view = view.child(self.locations_view(cx));
            view = view.child(div().text_sm().text_color(cx.theme().muted_foreground).child(match permission.as_str() {
                "workspace" => "Read access is not limited to these locations. Folders added with write access join the Workspace.",
                "full-access" => "Saved locations do not limit Full access.",
                "read-only" => "Saved write locations stay inactive in Read-only mode.",
                _ => "",
            }));
            if !self.locations.folders().is_empty() {
                view = view.child(
                    self.form
                        .field("workingDirectory", "Workspace", disabled),
                );
            }
        }
        view = view.child(
            Button::new("bot-advanced")
                .ghost()
                .label("Advanced")
                .icon(if self.bot_advanced {
                    IconName::ChevronDown
                } else {
                    IconName::ChevronRight
                })
                .accessibility_label(if self.bot_advanced {
                    "Advanced options, expanded"
                } else {
                    "Advanced options, collapsed"
                })
                .on_click(cx.listener(|this, _, _, cx| {
                    this.bot_advanced = !this.bot_advanced;
                    cx.notify();
                })),
        );
        if self.bot_advanced {
            for (key, label) in [
                ("systemPrompt", "Instructions"),
                ("model", "Model"),
                ("reasoningEffort", "Reasoning"),
                ("serviceTier", "Speed"),
            ] {
                if id.is_none() || key == "systemPrompt" {
                    view = view.child(self.form.field(key, label, disabled));
                }
            }
            if id.is_some() && !self.file_access.is_null() {
                view = view.child(
                    self.form
                        .field("workingDirectory", "Workspace", disabled),
                );
            }
        }
        view.child(
            Button::new("save-bot")
                .primary()
                .label(if id.is_some() {
                    "Save Bot"
                } else {
                    "Create Bot"
                })
                .disabled(disabled)
                .on_click(cx.listener(|this, _, _, cx| this.submit(cx))),
        )
    }

    fn avatar_picker(&self, id: &Option<String>, cx: &mut Context<Self>) -> Div {
        let identity = id.as_deref().unwrap_or("new-bot");
        let name = self.form.value("name", cx);
        let selected_shape = self.form.value("avatarShape", cx);
        let selected_palette = self.form.value("avatarPalette", cx);
        let preview = science_avatar::avatar(
            &name,
            identity,
            Some(&selected_shape),
            Some(&selected_palette),
            None,
            72.,
        );
        let disabled = self.busy || self.pending.is_some();
        let mut shapes = div().flex().flex_wrap().gap_2();
        for shape in science_avatar::Shape::ALL {
            let shape_id = shape.id().to_owned();
            let identity = identity.to_owned();
            let palette = selected_palette.clone();
            shapes = shapes.child(
                Button::new(SharedString::from(format!("avatar-shape-{shape_id}")))
                    .ghost()
                    .disabled(disabled)
                    .selected(shape_id == selected_shape)
                    .accessibility_label(format!("{} character", shape.title()))
                    .child(science_avatar::avatar(
                        &name,
                        &identity,
                        Some(&shape_id),
                        Some(&palette),
                        None,
                        42.,
                    ))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.form.set_value("avatarShape", &shape_id, window, cx);
                        cx.notify();
                    })),
            );
        }
        let mut palettes = div().flex().flex_wrap().gap_2();
        for palette in science_avatar::PALETTES {
            let palette_id = palette.id.to_owned();
            let palette_name = palette.name.to_owned();
            palettes = palettes.child(
                Button::new(SharedString::from(format!("avatar-palette-{}", palette.id)))
                    .ghost()
                    .disabled(disabled)
                    .selected(palette_id == selected_palette)
                    .accessibility_label(format!("{} color palette", palette_name))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .size(px(18.))
                                    .rounded_full()
                                    .bg(rgb(palette.body))
                                    .border_1()
                                    .border_color(rgb(palette.shadow)),
                            )
                            .child(palette_name),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.form.set_value("avatarPalette", &palette_id, window, cx);
                        cx.notify();
                    })),
            );
        }
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().font_weight(FontWeight::MEDIUM).child("Avatar"))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(preview)
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(div().font_weight(FontWeight::MEDIUM).child(format!(
                                "{} · {}",
                                science_avatar::Shape::from_id(&selected_shape)
                                    .map(|shape| shape.title())
                                    .unwrap_or("Saved avatar"),
                                science_avatar::palette(&selected_palette)
                                    .map(|palette| palette.name)
                                    .unwrap_or("Saved palette"),
                            )))
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(cx.theme().muted_foreground)
                                    .child("Choose a character and color for this Bot."),
                            ),
                    ),
            )
            .child(
                div()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child("Character"),
            )
            .child(shapes.when(disabled, |view| view.opacity(0.55)))
            .child(
                div()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child("Color palette"),
            )
            .child(palettes.when(disabled, |view| view.opacity(0.55)))
    }
    fn locations_view(&self, cx: &mut Context<Self>) -> Div {
        let disabled = self.busy || self.pending.is_some();
        let mut view = div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().font_weight(FontWeight::MEDIUM).child("File access"))
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(
                        Button::new("choose-read-locations")
                            .label("Add read-only…")
                            .disabled(disabled)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.choose_locations(false, window, cx)
                            })),
                    )
                    .child(
                        Button::new("choose-write-locations")
                            .label("Add read/write…")
                            .disabled(disabled)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.choose_locations(true, window, cx)
                            })),
                    ),
            );
        for (write, paths, label) in [
            (false, &self.locations.read_roots, "Read-only"),
            (true, &self.locations.write_roots, "Read and write"),
        ] {
            for (index, path) in paths.iter().enumerate() {
                let remove_path = path.clone();
                let name = std::path::Path::new(path)
                    .file_name()
                    .and_then(|v| v.to_str())
                    .unwrap_or(path)
                    .to_owned();
                view = view.child(
                    div()
                        .id((
                            if write {
                                "write-location"
                            } else {
                                "read-location"
                            },
                            index,
                        ))
                        .role(Role::Group)
                        .aria_label(format!("{label}: {path}"))
                        .flex()
                        .items_center()
                        .gap_3()
                        .py_2()
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .gap_1()
                                .child(
                                    div()
                                        .text_sm()
                                        .font_weight(FontWeight::MEDIUM)
                                        .child(format!("{name} · {label}")),
                                )
                                .child(
                                    div()
                                        .text_sm()
                                        .text_color(cx.theme().muted_foreground)
                                        .overflow_hidden()
                                        .text_ellipsis()
                                        .child(path.clone()),
                                ),
                        )
                        .child(
                            Button::new((
                                if write { "remove-write" } else { "remove-read" },
                                index,
                            ))
                            .ghost()
                            .label("Remove")
                            .accessibility_label(format!("Remove {path} from {label} access"))
                            .disabled(disabled)
                            .on_click(cx.listener(
                                move |this, _, window, cx| {
                                    this.remove_location(&remove_path, write, window, cx)
                                },
                            )),
                        ),
                );
            }
        }
        if self.locations.read_roots.is_empty() && self.locations.write_roots.is_empty() {
            view = view.child(
                div()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child("No additional locations selected."),
            );
        }
        view
    }
    fn group_form(&self, cx: &mut Context<Self>) -> Div {
        let disabled = self.busy || self.pending.is_some();
        let mut view = div()
            .flex()
            .flex_col()
            .gap_4()
            .child(self.form.field("name", "Name", disabled))
            .child(self.form.field("description", "Description", disabled))
            .child(self.form.field("coordinator", "Lead Bot", disabled))
            .when(!matches!(self.page, Page::GroupEdit(_)), |v| {
                v.child(div().font_weight(FontWeight::MEDIUM).child("Members"))
            });
        for bot in self
            .bots
            .iter()
            .filter(|b| b["isArchived"] != true && !matches!(self.page, Page::GroupEdit(_)))
        {
            let id = strv(bot, "id").to_owned();
            let selected = self.members.contains(&id);
            view = view.child(
                Checkbox::new(SharedString::from(format!("member-{id}")))
                    .label(strv(bot, "name").to_owned())
                    .checked(selected)
                    .disabled(disabled)
                    .on_click(cx.listener(move |this, checked, _, cx| {
                        if *checked {
                            this.members.push(id.clone());
                        } else {
                            this.members.retain(|m| m != &id);
                        }
                        this.form_changed(cx);
                    })),
            );
        }
        if let Page::GroupEdit(id) = &self.page {
            view = view.child(self.group_member_settings(id, cx));
        }
        view.child(
            Button::new("create-group")
                .primary()
                .label(if matches!(self.page, Page::GroupEdit(_)) {
                    "Save Group"
                } else {
                    "Create Group"
                })
                .disabled(disabled)
                .on_click(cx.listener(|this, _, _, cx| this.submit(cx))),
        )
    }
    fn automations_view(&self, scope: &Scope, cx: &mut Context<Self>) -> Div {
        let create_scope = scope.clone();
        let disabled = self.busy || self.pending.is_some();
        let mut view = div().flex().flex_col().gap_4().child(
            Button::new("new-automation")
                .primary()
                .label("New automation")
                .disabled(disabled)
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.open(Page::Automation(create_scope.clone(), None), window, cx)
                })),
        );
        let list: Vec<_> = self
            .automations
            .iter()
            .filter(|a| a["scopeType"] == scope.kind && a["scopeId"] == scope.id)
            .collect();
        if list.is_empty() {
            view = view.child(
                div()
                    .py_6()
                    .text_color(cx.theme().muted_foreground)
                    .child("No automations in this conversation."),
            );
        }
        for automation in list {
            let id = strv(automation, "id").to_owned();
            let edit = id.clone();
            let history = id.clone();
            let run = id.clone();
            let toggle = id.clone();
            let delete = id.clone();
            let edit_scope = scope.clone();
            let history_scope = scope.clone();
            let active = automation["status"] == "active";
            let name = strv(automation, "name").to_owned();
            let row=div().flex().flex_col().gap_2().py_4().border_b_1().border_color(cx.theme().border)
                .child(div().flex().items_center().justify_between().child(div().font_weight(FontWeight::SEMIBOLD).child(name.clone())).child(div().text_sm().text_color(cx.theme().muted_foreground).child(if active {"Active"}else{"Paused"})))
                .child(div().child(strv(automation,"prompt").to_owned()))
                .child(div().text_sm().text_color(cx.theme().muted_foreground).child(format!("Next: {}",schedule_timestamp(&automation["nextRunAt"],strv(automation,"timezone")))))
                .child(div().text_sm().text_color(cx.theme().muted_foreground).child(format!("Last attempt: {} · Last success: {}",timestamp(&automation["lastAttemptAt"]),timestamp(&automation["lastSuccessAt"]))))
                .child(div().flex().flex_wrap().gap_2()
                    .child(Button::new(SharedString::from(format!("edit-{id}"))).label("Edit").disabled(disabled).on_click(cx.listener(move|this,_,window,cx|this.open(Page::Automation(edit_scope.clone(),Some(edit.clone())),window,cx))))
                    .child(Button::new(SharedString::from(format!("pause-{id}"))).label(if active {"Pause"}else{"Resume"}).disabled(disabled).on_click(cx.listener(move|this,_,_,cx|this.write("PATCH",route(&["api","v1","automations",&toggle]),json!({"status":if active {"paused"}else{"active"}}),"refresh",cx))))
                    .child(Button::new(SharedString::from(format!("run-{id}"))).label("Run now").disabled(disabled).on_click(cx.listener(move|this,_,_,cx|this.write("POST",route(&["api","v1","automations",&run,"run"]),json!({"clientRequestId":uuid::Uuid::new_v4().to_string()}),"run",cx))))
                    .child(Button::new(SharedString::from(format!("history-{id}"))).label("History").disabled(self.busy).on_click(cx.listener(move|this,_,window,cx|this.open(Page::Runs(history_scope.clone(),history.clone()),window,cx))))
                    .child(Button::new(SharedString::from(format!("delete-{id}"))).ghost().label("Delete").disabled(disabled).on_click(cx.listener(move|this,_,window,cx|this.open(Page::Confirm{title:"Delete automation".into(),explanation:format!("Delete {name}? Future runs will stop. This cannot be undone."),name:None,method:"DELETE".into(),path:route(&["api","v1","automations",&delete]),body:Value::Null,completion:"refresh".into()},window,cx)))));
            view = view.child(row);
        }
        view
    }
    fn automation_editor(&self, scope: &Scope, id: &Option<String>, cx: &mut Context<Self>) -> Div {
        let disabled = self.busy || self.pending.is_some();
        let frequency = self.form.value("frequency", cx);
        let mut view = div().flex().flex_col().gap_4();
        for (key, label) in [
            ("name", "Name"),
            ("prompt", "Instructions"),
            ("kind", "Conversation"),
            ("frequency", "Frequency"),
        ] {
            view = view.child(self.form.field(key, label, disabled));
        }
        if frequency == "MINUTELY" {
            view = view.child(self.form.field(
                "interval",
                "Interval in minutes (1–1440)",
                disabled,
            ));
        }
        if frequency == "HOURLY" {
            view = view.child(self.form.field("hourInterval", "Interval", disabled));
        }
        if frequency != "MINUTELY" {
            view = view.child(self.form.field(
                "time",
                if frequency == "HOURLY" {
                    "At minute (HH:MM)"
                } else {
                    "Time (24-hour)"
                },
                disabled,
            ));
        }
        if frequency == "MONTHLY" {
            view = view.child(self.form.field("monthday", "Day of month", disabled));
        }
        if frequency == "WEEKLY" {
            view = view.child(div().flex().flex_wrap().gap_2().children(
                automation_form::DAYS.into_iter().map(|(id, label)| {
                    Button::new(id)
                        .label(label)
                        .selected(self.days.iter().any(|d| d == id))
                        .disabled(disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if this.days.iter().any(|d| d == id) {
                                this.days.retain(|d| d != id);
                            } else {
                                this.days.push(id.into());
                            }
                            this.preview = None;
                            this.form_changed(cx);
                        }))
                }),
            ));
        }
        view = view.child(self.form.field("timezone", "Time zone", disabled));
        if scope.kind != "group_chat" {
            view = view
                .child(self.form.field("model", "Model", disabled))
                .child(self.form.field("reasoningEffort", "Reasoning", disabled));
        }
        view.child(
            div()
                .flex()
                .items_center()
                .gap_3()
                .child(
                    Button::new("preview-schedule")
                        .label("Preview next run")
                        .disabled(disabled)
                        .on_click(cx.listener(|this, _, _, cx| this.preview_schedule(cx))),
                )
                .when_some(
                    self.preview
                        .as_ref()
                        .filter(|_| self.has_current_preview(cx)),
                    |v, preview| {
                        v.child(div().text_sm().child(schedule_timestamp(
                            &preview["nextRunAt"],
                            strv(preview, "timezone"),
                        )))
                    },
                ),
        )
        .child(
            Button::new("save-automation")
                .primary()
                .label(if id.is_some() {
                    "Save automation"
                } else {
                    "Create automation"
                })
                .disabled(disabled || !self.has_current_preview(cx))
                .on_click(cx.listener(|this, _, _, cx| this.submit(cx))),
        )
    }
    fn runs_view(&self, cx: &mut Context<Self>) -> Div {
        let mut view = div().flex().flex_col().gap_3();
        if self.runs.is_empty() && !self.busy {
            view = view.child("This automation has not run yet.");
        }
        for run in &self.runs {
            let id = strv(run, "id").to_owned();
            let conversation = run["conversationId"].as_str().map(str::to_owned);
            view = view.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .py_3()
                    .border_b_1()
                    .border_color(cx.theme().border)
                    .child(format!(
                        "{} · {}",
                        timestamp(&run["startedAt"]),
                        strv(run, "status")
                    ))
                    .when_some(run["error"].as_str(), |v, error| {
                        v.child(div().text_color(cx.theme().danger).child(error.to_owned()))
                    })
                    .when_some(conversation, |v, conversation| {
                        v.child(
                            Button::new(SharedString::from(format!("run-chat-{id}")))
                                .label("Open conversation")
                                .on_click(cx.listener(move |_, _, _, cx| {
                                    cx.emit(Event::Open(conversation.clone()))
                                })),
                        )
                    }),
            );
        }
        view
    }
}
impl Render for Manager {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let title = match &self.page {
            Page::Bots(true) => "Archived Bots".into(),
            Page::Bots(false) => "Bots".into(),
            Page::Bot(Some(_)) => "Edit Bot".into(),
            Page::Bot(None) => "New Bot".into(),
            Page::Group => "New Group".into(),
            Page::GroupEdit(_) => "Group settings".into(),
            Page::GroupBot(_, bot) => self
                .bots
                .iter()
                .find(|b| b["id"] == *bot)
                .map(|b| format!("{} settings", strv(b, "name")))
                .unwrap_or("Bot settings".into()),
            Page::Details(scope) => scope.title.clone(),
            Page::Assignments(scope) => format!("{} · Assignments", scope.title),
            Page::Assignment(_, _) => "Assignment".into(),
            Page::Automations(scope) => format!("{} · Automations", scope.title),
            Page::Automation(_, Some(_)) => "Edit automation".into(),
            Page::Automation(_, None) => "New automation".into(),
            Page::Runs(_, _) => "Run history".into(),
            Page::FileAccess(_) => "File access".into(),
            Page::Confirm { title, .. } => title.clone(),
        };
        let back = match &self.page {
            Page::GroupBot(group, _) => Some(Page::GroupEdit(group.clone())),
            Page::FileAccess(bot) => match &self.return_page {
                Some(Page::GroupBot(group, member)) if member == bot => {
                    Some(Page::GroupBot(group.clone(), member.clone()))
                }
                _ => Some(Page::Bot(Some(bot.clone()))),
            },
            Page::Automation(scope, _) | Page::Runs(scope, _) => {
                Some(Page::Automations(scope.clone()))
            }
            Page::Assignments(scope) => Some(Page::Details(scope.clone())),
            Page::Assignment(scope, _) => Some(Page::Assignments(scope.clone())),
            Page::Automations(scope) => Some(Page::Details(scope.clone())),
            Page::Confirm { .. } => self.return_page.clone(),
            _ => Some(
                self.detail_scope
                    .clone()
                    .map(Page::Details)
                    .unwrap_or(Page::Bots(false)),
            ),
        };
        let mut content = div().flex().flex_col().gap_4();
        if !self.loaded {
            content = content.child("Loading…");
        } else {
            content = match &self.page {
                Page::Bots(archived) => self.bots_view(*archived, cx),
                Page::Bot(id) => self.bot_form(id, cx),
                Page::Group | Page::GroupEdit(_) => self.group_form(cx),
                Page::GroupBot(_, bot) => self.group_bot_form(bot, cx),
                Page::Details(scope) => self.details_view(scope, cx),
                Page::Assignments(scope) => self.assignments_view(scope, cx),
                Page::Assignment(scope, id) => self.assignment_view(scope, id, cx),
                Page::Automations(scope) => self.automations_view(scope, cx),
                Page::Automation(scope, id) => self.automation_editor(scope, id, cx),
                Page::Runs(_, _) => self.runs_view(cx),
                Page::FileAccess(id) => {
                    let bot = self
                        .bots
                        .iter()
                        .find(|bot| bot["id"] == *id);
                    let mode = bot.map(|bot| strv(bot, "permissionMode")).unwrap_or("");
                    let workspace = bot
                        .and_then(|bot| {
                            bot["workingDirectory"]
                                .as_str()
                                .filter(|path| !path.is_empty())
                                .or_else(|| bot["workspacePath"].as_str())
                        })
                        .unwrap_or_else(|| strv(&self.file_access, "workspacePath"));
                    let scope = match mode {
                        "workspace" => "Workspace: reads are unrestricted. Saved write locations join the workspace.",
                        "read-only" => "Read-only: saved write locations stay inactive until you switch modes.",
                        "full-access" => "Full access: these saved locations do not restrict file or network access.",
                        _ => "This Bot uses its saved selected-location access.",
                    };
                    if self.file_access.is_null() {
                        div().child("Loading file access…")
                    } else {
                        div().flex().flex_col().gap_4()
                            .child(div().text_sm().text_color(cx.theme().muted_foreground).child(format!("Workspace: {workspace}")))
                            .child(div().text_sm().text_color(cx.theme().muted_foreground).child(scope))
                            .child(self.locations_view(cx))
                            .when(self.file_access["access"]["revision"]!=self.file_access["access"]["appliedRevision"],|v|v.child(div().text_color(cx.theme().danger).child("These grants are saved but not active. Apply again to retry.")))
                            .child(Button::new("apply-access").primary().label("Apply file access").disabled(self.busy||self.pending.is_some()).on_click(cx.listener(|this,_,_,cx|this.submit(cx))))
                    }
                }
                Page::Confirm {
                    title,
                    explanation,
                    name,
                    method,
                    path,
                    body,
                    completion,
                } => {
                    let allowed = name
                        .as_ref()
                        .is_none_or(|name| self.form.value("confirmation", cx) == *name);
                    let method = method.clone();
                    let path = path.clone();
                    let body = body.clone();
                    let completion = completion.clone();
                    div()
                        .flex()
                        .flex_col()
                        .gap_4()
                        .child(explanation.clone())
                        .when(name.is_some(), |v| {
                            v.child(self.form.field(
                                "confirmation",
                                "Bot name",
                                self.busy || self.pending.is_some(),
                            ))
                        })
                        .child(
                            Button::new("confirm-change")
                                .danger()
                                .label(title.clone())
                                .disabled(!allowed || self.busy || self.pending.is_some())
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.write(&method, path.clone(), body.clone(), &completion, cx)
                                })),
                        )
                }
            };
        }
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(
                div()
                    .h(px(56.))
                    .flex_shrink_0()
                    .px_5()
                    .flex()
                    .items_center()
                    .gap_3()
                    .border_b_1()
                    .border_color(cx.theme().border)
                    .child(
                        Button::new("close-management")
                            .ghost()
                            .label(if self.is_inspector() {
                                "Close"
                            } else {
                                "Chats"
                            })
                            .accessibility_label(if self.is_inspector() {
                                "Close details"
                            } else {
                                "Chats"
                            })
                            .on_click(cx.listener(|this, _, _, cx| this.close(cx))),
                    )
                    .when(
                        !self.is_inspector() && !matches!(self.page, Page::Bots(_)),
                        |v| {
                            v.child(
                                Button::new("management-back")
                                    .ghost()
                                    .label("Back")
                                    .disabled(self.busy)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        if let Some(page) = back.clone() {
                                            this.open(page, window, cx)
                                        }
                                    })),
                            )
                        },
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .overflow_hidden()
                            .text_ellipsis()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(title),
                    )
                    .when(drafts::key(&self.host, &self.page).is_some(), |v| {
                        v.child(
                            Button::new("discard-form")
                                .ghost()
                                .label("Discard draft")
                                .disabled(self.busy || self.pending.is_some())
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.discard_draft(window, cx)
                                })),
                        )
                    })
                    .when(self.busy, |v| {
                        v.child(
                            div()
                                .text_sm()
                                .text_color(cx.theme().muted_foreground)
                                .child(if self.pending.is_some() {
                                    "Saving…"
                                } else {
                                    "Loading…"
                                }),
                        )
                    }),
            )
            .child(
                div()
                    .id("management-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .p_6()
                    .flex()
                    .justify_center()
                    .items_start()
                    .child(
                        div()
                            .flex_shrink_0()
                            .pb_6()
                            .w_full()
                            .max_w(px(660.))
                            .flex()
                            .flex_col()
                            .gap_4()
                            .when_some(self.drafts_error.clone(), |v, error| {
                                v.child(div().text_color(cx.theme().danger).child(error))
                            })
                            .when_some(self.options_error.clone(), |v, _| {
                                v.child(
                                    div()
                                        .flex()
                                        .flex_col()
                                        .gap_2()
                                        .child(
                                            "Mac model and time zone options could not be loaded.",
                                        )
                                        .child(
                                            Button::new("retry-options")
                                                .label("Retry Mac options")
                                                .disabled(self.busy)
                                                .on_click(cx.listener(|this, _, _, cx| {
                                                    this.retry_options(cx)
                                                })),
                                        ),
                                )
                            })
                            .when_some(self.error.clone(), |v, error| {
                                v.child(
                                    div()
                                        .id("management-error")
                                        .role(Role::Label)
                                        .aria_label(error.clone())
                                        .text_color(cx.theme().danger)
                                        .child(error),
                                )
                            })
                            .when_some(self.notice.clone(), |v, notice| {
                                v.child(div().text_color(cx.theme().muted_foreground).child(notice))
                            })
                            .when(self.pending.is_some(), |v| {
                                v.child(
                                    Button::new("retry-saved-change")
                                        .label(
                                            if self
                                                .pending
                                                .as_ref()
                                                .is_some_and(|p| p["completion"] == "assignment")
                                            {
                                                "Check assignment status"
                                            } else {
                                                "Check saved request"
                                            },
                                        )
                                        .disabled(self.busy)
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            if this
                                                .pending
                                                .as_ref()
                                                .is_some_and(|p| p["completion"] == "assignment")
                                            {
                                                this.open_saved_assignment(window, cx)
                                            } else {
                                                this.retry(cx)
                                            }
                                        })),
                                )
                            })
                            .when(!self.loaded && !self.busy, |v| {
                                v.child(
                                    Button::new("retry-management")
                                        .label("Try again")
                                        .on_click(cx.listener(|this, _, _, _| this.load())),
                                )
                            })
                            .child(content),
                    ),
            )
    }
}
