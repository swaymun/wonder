//! Group work review uses the daemon's exact result and target revisions.
use super::*;
use std::time::Instant;

#[derive(Default)]
pub(super) struct Assignments {
    pub rows: Vec<Value>,
    pub detail: Value,
    fresh: bool,
    refreshed: Option<Instant>,
    confirming_integration: bool,
}

fn status(state: &str) -> &'static str {
    match state {
        "queued" | "ready" => "Queued",
        "working" => "Working",
        "awaiting_input" => "Needs your answer",
        "submitted" => "Ready for review",
        "reviewed" => "Reviewed",
        "integrating" => "Integrating",
        "integrated" => "Integrated",
        "failed" => "Couldn’t finish",
        "cancelled" => "Stopped",
        _ => "Outcome not confirmed",
    }
}
fn revision(value: &Value, key: &str) -> Option<String> {
    value[key]
        .as_str()
        .filter(|v| matches!(v.len(), 40 | 64) && v.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(str::to_owned)
}
pub(super) fn review_draft_key(
    host: &str,
    group: &str,
    id: &str,
    detail: &Value,
) -> Option<String> {
    if detail["id"] != id || detail["groupId"] != group {
        return None;
    }
    Some(format!(
        "{host}:assignment:{group}:{id}:{}",
        revision(detail, "resultRevision")?
    ))
}
fn pending_action(pending: &Value) -> &str {
    pending["path"]
        .as_array()
        .and_then(|p| p.last())
        .and_then(Value::as_str)
        .unwrap_or("")
}
fn matches_saved(pending: &Value, detail: &Value) -> bool {
    pending["completion"] == "assignment"
        && pending["assignmentId"] == detail["id"]
        && pending["assignmentGroupId"] == detail["groupId"]
}
fn confirmed(pending: &Value, detail: &Value) -> bool {
    if !matches_saved(pending, detail) {
        return false;
    }
    let state = strv(detail, "state");
    match pending_action(pending) {
        "cancel" => state == "cancelled",
        "review" => {
            pending["body"]["resultRevision"] == detail["resultRevision"]
                && matches!(state, "reviewed" | "integrating" | "integrated")
        }
        "integrate" => {
            pending["body"]["resultRevision"] == detail["resultRevision"] && state == "integrated"
        }
        _ => false,
    }
}
fn may_reconsider(pending: &Value, detail: &Value) -> bool {
    matches_saved(pending, detail)
        && pending_action(pending) == "integrate"
        && pending["rejected"] == true
        && matches!(strv(detail, "state"), "submitted" | "reviewed")
}
fn action_body(detail: &Value, action: &str, validation: &str) -> Result<Value, String> {
    match action {
        "cancel" if detail["canCancel"] == true && detail["state"] == "queued" => Ok(json!({})),
        "review" if detail["state"] == "submitted" => {
            let result = revision(detail, "resultRevision")
                .ok_or("Refresh to load the complete result revision.")?;
            if validation.trim().is_empty() || validation.len() > 8000 {
                return Err("Describe your checks and review in 8,000 characters or fewer.".into());
            }
            if !detail["diff"].is_string() {
                return Err("Load the complete changes before reviewing this result.".into());
            }
            Ok(json!({"resultRevision":result,"validation":validation.trim()}))
        }
        "integrate" if detail["state"] == "reviewed" => {
            let result = revision(detail, "resultRevision")
                .ok_or("Refresh to load the complete result revision.")?;
            let head = revision(detail, "repositoryHead")
                .ok_or("Refresh to load the current project revision.")?;
            if Some(&head) != revision(detail, "baseRevision").as_ref() {
                return Err("The project changed. Rebase the assignment on its current revision and review it again before integrating.".into());
            }
            if !detail["diff"].is_string() {
                return Err("Load the complete changes before integrating.".into());
            }
            Ok(json!({"resultRevision":result,"expectedHead":head}))
        }
        _ => Err("This action is no longer available. Refresh the assignment.".into()),
    }
}
fn saved_request<'a>(pending: &'a Value, host: &str) -> Result<(Vec<String>, &'a Value), String> {
    if pending["host"] != host || pending["completion"] != "assignment" {
        return Err("The saved request belongs to another Mac.".into());
    }
    let path: Vec<String> = serde_json::from_value(pending["path"].clone())
        .map_err(|_| "The saved assignment request is unreadable.")?;
    if path.len() != 5
        || path[..3] != ["api", "v1", "assignments"]
        || pending["assignmentId"] != path[3]
        || !matches!(path[4].as_str(), "review" | "integrate" | "cancel")
        || pending["method"] != "POST"
        || !pending["body"].is_object()
        || pending["assignmentGroupId"]
            .as_str()
            .is_none_or(str::is_empty)
    {
        return Err("The saved assignment request is unreadable. It has been preserved.".into());
    }
    Ok((path, &pending["body"]))
}

fn execute_saved_request(
    pending: &Value,
    host: &str,
    mut request: impl FnMut(&str, &[String], &Value) -> Result<Value, String>,
) -> Result<Value, String> {
    let (path, body) = saved_request(pending, host)?;
    let detail = request(
        "GET",
        &route(&["api", "v1", "assignments", &path[3]]),
        &Value::Null,
    )
    .map_err(|error| {
        format!(
            "Could not check the saved assignment: {}",
            error.trim_start_matches("Rejected: ")
        )
    })?;
    if !matches_saved(pending, &detail) {
        return Err(
            "The assignment identity changed. The saved request has been preserved.".into(),
        );
    }
    if confirmed(pending, &detail) {
        return Ok(detail);
    }
    let response = request("POST", &path, body)?;
    if !confirmed(pending, &response) {
        return Err("The Mac has not confirmed the saved assignment action. Check its status before retrying.".into());
    }
    Ok(response)
}

fn assignment_text(id: impl Into<SharedString>, value: impl Into<SharedString>) -> Stateful<Div> {
    let value = value.into();
    let id: SharedString = id.into();
    div()
        .id(id)
        .role(Role::Label)
        .aria_label(value.clone())
        .child(value)
}
fn open_assignment_label(assignment: &Value) -> String {
    format!(
        "Open {}, {}, {}",
        strv(assignment, "title"),
        strv(assignment, "projectName"),
        status(strv(assignment, "state"))
    )
}

impl Manager {
    pub(super) fn assignment_scope(&self, group: &str) -> Option<Scope> {
        let value = self.groups.iter().find(|g| g["id"] == group)?;
        Some(Scope {
            kind: "group_chat".into(),
            id: group.into(),
            conversation: strv(value, "conversationId").into(),
            title: strv(value, "name").into(),
            bot_id: strv(value, "coordinatorBotId").into(),
        })
    }
    pub(super) fn fetch_assignments(&mut self, group: &str, id: Option<&str>) {
        if self.busy {
            return;
        }
        self.assignments.fresh = false;
        self.assignments.refreshed = Some(Instant::now());
        self.assignments.confirming_integration = false;
        self.busy = true;
        let group = group.to_owned();
        let id = id.map(str::to_owned);
        let connection = self.connection.clone();
        let host = self.host.clone();
        let sender = self.sender.clone();
        std::thread::spawn(move || {
            let kind = if id.is_some() {
                "assignment-detail"
            } else {
                "assignment-list"
            };
            let path = id
                .as_ref()
                .map(|id| route(&["api", "v1", "assignments", id]))
                .unwrap_or_else(|| route(&["api", "v1", "groups", &group, "assignments"]));
            let result = connection
                .request("GET", &path, &Value::Null, &host)
                .and_then(|data| {
                    if id
                        .as_ref()
                        .is_some_and(|id| data["id"] != *id || data["groupId"] != group)
                    {
                        return Err(
                            "This assignment belongs to another Group. Reopen its Group details."
                                .into(),
                        );
                    }
                    Ok(json!({"group":group,"id":id,"data":data}))
                });
            let _ = sender.send(Reply { kind, result });
        });
    }
    pub(super) fn poll_assignments(&mut self) {
        if self.busy
            || self.assignments.confirming_integration
            || self
                .assignments
                .refreshed
                .is_none_or(|time| time.elapsed() < Duration::from_secs(4))
        {
            return;
        }
        match self.page.clone() {
            Page::Assignments(scope)
                if self.assignments.rows.iter().any(|a| {
                    matches!(
                        strv(a, "state"),
                        "queued" | "working" | "awaiting_input" | "integrating"
                    )
                }) =>
            {
                self.fetch_assignments(&scope.id, None)
            }
            Page::Assignment(scope, id)
                if matches!(
                    strv(&self.assignments.detail, "state"),
                    "queued" | "working" | "awaiting_input" | "integrating"
                ) =>
            {
                self.fetch_assignments(&scope.id, Some(&id))
            }
            _ => {}
        }
    }
    pub(super) fn receive_assignments(
        &mut self,
        kind: &str,
        value: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if kind == "assignment-list" {
            if !matches!(&self.page,Page::Assignments(scope) if value["group"]==scope.id) {
                return;
            }
            let Some(rows) = value["data"]["assignments"].as_array().cloned() else {
                self.error = Some(
                    "The Mac returned an unreadable assignment list. Refresh to try again.".into(),
                );
                return;
            };
            if rows.iter().any(|a| a["groupId"] != value["group"]) {
                self.error = Some("The Mac returned assignments for a different Group.".into());
                return;
            }
            self.assignments.rows = rows;
            self.assignments.fresh = true;
            return;
        }
        if !matches!(&self.page,Page::Assignment(scope,id) if value["group"]==scope.id && value["id"]==*id)
        {
            return;
        }
        self.persist_draft(cx);
        let old_revision = self.assignments.detail["resultRevision"].clone();
        self.assignments.detail = value["data"].clone();
        self.assignments.fresh = true;
        let detail = &self.assignments.detail;
        if self.pending.as_ref().is_some_and(|p| confirmed(p, detail)) {
            if let Err(error) = self.clear_assignment_pending() {
                self.error = Some(error);
                return;
            }
            self.notice = Some("Change confirmed".into());
        }
        if kind == "assignment-reconsider" {
            if self
                .pending
                .as_ref()
                .is_some_and(|p| may_reconsider(p, &self.assignments.detail))
            {
                if let Err(error) = self.clear_assignment_pending() {
                    self.error = Some(error);
                    return;
                }
                self.notice=Some("The earlier integration was rejected. Review the current project before trying again.".into());
            } else if self.pending.is_some() {
                self.error=Some("The earlier integration is not confirmed. Check status or retry its saved request.".into());
            }
        }
        if old_revision != self.assignments.detail["resultRevision"] || self.form.is_empty() {
            self.form = Form::default();
            self.form.text("validation", "", window, cx);
            self.restore_draft(window, cx);
            self.subscriptions = self.form.observe(cx, Self::form_changed);
        }
    }
    fn clear_assignment_pending(&mut self) -> Result<(), String> {
        match std::fs::remove_file(&self.pending_path) {
            Ok(()) => {},
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {},
            Err(_) => return Err("The saved confirmation could not be cleared. Reopen Wonder before making another change.".into()),
        }
        self.pending = None;
        Ok(())
    }
    pub(super) fn preserve_rejected_integration(
        &mut self,
        message: &str,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(mut pending) = self
            .pending
            .clone()
            .filter(|p| p["completion"] == "assignment" && pending_action(p) == "integrate")
        else {
            return false;
        };
        pending["rejected"] = json!(true);
        pending["rejectionReason"] = json!(message);
        match save_pending(&self.pending_path, &pending) {
            Ok(()) => {
                self.pending = Some(pending);
                self.error = Some(message.into());
            }
            Err(e) => self.error = Some(e),
        }
        self.assignments.fresh = false;
        self.assignments.confirming_integration = false;
        cx.notify();
        true
    }
    pub(super) fn open_saved_assignment(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(pending) = self.pending.clone() else {
            return;
        };
        if let Err(e) = saved_request(&pending, &self.host) {
            self.error = Some(e);
            cx.notify();
            return;
        }
        let Some(scope) = self.assignment_scope(strv(&pending, "assignmentGroupId")) else {
            self.error = Some("Open the Group that owns this saved assignment.".into());
            cx.notify();
            return;
        };
        self.open(
            Page::Assignment(scope, strv(&pending, "assignmentId").into()),
            window,
            cx,
        );
    }
    pub(super) fn retry_assignment(&mut self, pending: Value, cx: &mut Context<Self>) {
        self.busy = true;
        self.error = None;
        self.assignments.confirming_integration = false;
        let connection = self.connection.clone();
        let host = self.host.clone();
        let sender = self.sender.clone();
        std::thread::spawn(move || {
            let result = execute_saved_request(&pending, &host, |method, path, body| {
                connection.request(method, path, body, &host)
            });
            let _ = sender.send(Reply {
                kind: "write",
                result,
            });
        });
        cx.notify();
    }
    fn reconsider_assignment(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Page::Assignment(scope, id) = self.page.clone() else {
            return;
        };
        self.busy = true;
        self.assignments.fresh = false;
        self.assignments.confirming_integration = false;
        let connection = self.connection.clone();
        let sender = self.sender.clone();
        let host = self.host.clone();
        std::thread::spawn(move || {
            let result = connection
                .request(
                    "GET",
                    &route(&["api", "v1", "assignments", &id]),
                    &Value::Null,
                    &host,
                )
                .and_then(|data| {
                    if data["id"] != id || data["groupId"] != scope.id {
                        return Err("The assignment identity changed.".into());
                    }
                    Ok(json!({"group":scope.id,"id":id,"data":data}))
                });
            let _ = sender.send(Reply {
                kind: "assignment-reconsider",
                result,
            });
        });
        cx.notify();
    }
    fn assignment_action(&mut self, action: &str, cx: &mut Context<Self>) {
        if self.busy || self.pending.is_some() || !self.assignments.fresh {
            return;
        }
        let Page::Assignment(scope, id) = &self.page else {
            return;
        };
        if self.assignments.detail["id"] != *id || self.assignments.detail["groupId"] != scope.id {
            return;
        }
        match action_body(
            &self.assignments.detail,
            action,
            &self.form.value("validation", cx),
        ) {
            Ok(body) => {
                self.assignments.confirming_integration = false;
                self.write(
                    "POST",
                    route(&["api", "v1", "assignments", id, action]),
                    body,
                    "assignment",
                    cx,
                );
            }
            Err(e) => {
                self.error = Some(e);
                cx.notify();
            }
        }
    }
    pub(super) fn assignments_view(&self, scope: &Scope, cx: &mut Context<Self>) -> Div {
        let group = scope.id.clone();
        let mut view = div().flex().flex_col().gap_3().child(
            Button::new("refresh-assignments")
                .label("Refresh")
                .disabled(self.busy)
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.error = None;
                    this.fetch_assignments(&group, None);
                    cx.notify();
                })),
        );
        if self.assignments.rows.is_empty() {
            return view.child(assignment_text(
                "assignment-list-status",
                if self.busy {
                    "Loading assignments…"
                } else if !self.assignments.fresh {
                    "Assignments could not be loaded."
                } else {
                    "No assignments yet. Ask the Group’s coordinator to assign project work."
                },
            ));
        }
        for a in &self.assignments.rows {
            let id = strv(a, "id").to_owned();
            let target = id.clone();
            let scope = scope.clone();
            view = view.child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .py_3()
                    .border_b_1()
                    .border_color(cx.theme().border)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .child(
                                assignment_text(
                                    format!("assignment-{id}-title"),
                                    strv(a, "title").to_owned(),
                                )
                                .font_weight(FontWeight::SEMIBOLD),
                            )
                            .child(
                                assignment_text(
                                    format!("assignment-{id}-status"),
                                    format!(
                                        "{} · {}",
                                        strv(a, "projectName"),
                                        status(strv(a, "state"))
                                    ),
                                )
                                .text_sm()
                                .text_color(cx.theme().muted_foreground),
                            ),
                    )
                    .child(
                        Button::new(SharedString::from(format!("assignment-{id}")))
                            .label("Open")
                            .accessibility_label(open_assignment_label(a))
                            .disabled(self.busy)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.open(
                                    Page::Assignment(scope.clone(), target.clone()),
                                    window,
                                    cx,
                                )
                            })),
                    ),
            );
        }
        view
    }
    pub(super) fn assignment_view(&self, scope: &Scope, id: &str, cx: &mut Context<Self>) -> Div {
        let group = scope.id.clone();
        let target = id.to_owned();
        let mut view = div().flex().flex_col().gap_4().child(
            Button::new("refresh-assignment")
                .label("Refresh status")
                .disabled(self.busy)
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.error = None;
                    this.fetch_assignments(&group, Some(&target));
                    cx.notify();
                })),
        );
        let a = &self.assignments.detail;
        if a["id"] != id || a["groupId"] != scope.id {
            return view.child(assignment_text(
                "assignment-detail-status",
                if self.busy {
                    "Loading assignment…"
                } else {
                    "Assignment details could not be loaded."
                },
            ));
        }
        view = view
            .child(
                assignment_text("assignment-title", strv(a, "title").to_owned())
                    .role(Role::Heading)
                    .text_lg()
                    .font_weight(FontWeight::SEMIBOLD),
            )
            .child(
                assignment_text(
                    "assignment-project-status",
                    format!("{} · {}", strv(a, "projectName"), status(strv(a, "state"))),
                )
                .text_sm()
                .text_color(cx.theme().muted_foreground),
            )
            .child(assignment_text(
                "assignment-instruction",
                strv(a, "instruction").to_owned(),
            ));
        if let Some(summary) = a["summary"].as_str().filter(|s| !s.is_empty()) {
            view = view.child(assignment_text("assignment-summary", summary.to_owned()));
        }
        if let Some(diff) = a["diff"].as_str() {
            let copy = diff.to_owned();
            view = view
                .child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .child(
                            assignment_text("assignment-changes-heading", "Changes")
                                .role(Role::Heading)
                                .font_weight(FontWeight::SEMIBOLD),
                        )
                        .child(
                            Button::new("copy-assignment-diff")
                                .ghost()
                                .label("Copy diff")
                                .on_click(cx.listener(move |_, _, _, cx| {
                                    cx.write_to_clipboard(ClipboardItem::new_string(copy.clone()))
                                })),
                        ),
                )
                .child(
                    assignment_text(
                        "assignment-diff",
                        if diff.is_empty() {
                            "No file changes in this result.".to_owned()
                        } else {
                            diff.to_owned()
                        },
                    )
                    .w_full()
                    .max_h(px(440.))
                    .overflow_y_scroll()
                    .overflow_x_scroll()
                    .p_3()
                    .bg(cx.theme().muted)
                    .font_family("Menlo")
                    .text_sm(),
                );
        }
        for (key, label) in [
            ("resultRevision", "Result revision"),
            ("repositoryHead", "Project revision"),
        ] {
            if let Some(value) = revision(a, key) {
                view = view.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(
                            assignment_text(format!("assignment-{key}-label"), label.to_owned())
                                .text_sm()
                                .text_color(cx.theme().muted_foreground),
                        )
                        .child(
                            assignment_text(format!("assignment-{key}"), value.clone())
                                .aria_label(format!("{label}: {value}"))
                                .font_family("Menlo")
                                .text_sm(),
                        ),
                );
            }
        }
        if let Some(validation) = a["validation"].as_str().filter(|s| !s.is_empty()) {
            view = view
                .child(
                    assignment_text(
                        "assignment-recorded-review-heading",
                        "Recorded checks and review",
                    )
                    .role(Role::Heading)
                    .font_weight(FontWeight::SEMIBOLD),
                )
                .child(assignment_text(
                    "assignment-recorded-review",
                    validation.to_owned(),
                ));
        }
        let disabled = self.busy
            || self.pending.is_some()
            || !self.assignments.fresh
            || self.drafts_error.is_some();
        if a["state"] == "submitted" {
            view = view
                .child(self.form.field("validation", "Checks and review", disabled))
                .child(
                    Button::new("review-assignment")
                        .primary()
                        .label("Mark reviewed")
                        .disabled(disabled || self.form.value("validation", cx).trim().is_empty())
                        .on_click(
                            cx.listener(|this, _, _, cx| this.assignment_action("review", cx)),
                        ),
                );
        }
        if a["state"] == "reviewed" {
            if let Err(reason) = action_body(a, "integrate", "") {
                view = view
                    .child(assignment_text("assignment-integration-unavailable", reason).text_sm());
            } else if self.assignments.confirming_integration {
                view = view.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(assignment_text(
                            "assignment-integration-confirmation",
                            format!(
                                "Apply this reviewed result to {} on {}?",
                                strv(a, "projectName"),
                                strv(a, "targetBranch")
                            ),
                        ))
                        .child(
                            div()
                                .flex()
                                .gap_2()
                                .child(
                                    Button::new("confirm-integrate-assignment")
                                        .primary()
                                        .label("Integrate reviewed changes")
                                        .disabled(disabled)
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.assignment_action("integrate", cx)
                                        })),
                                )
                                .child(
                                    Button::new("cancel-integrate-confirmation")
                                        .ghost()
                                        .label("Cancel")
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.assignments.confirming_integration = false;
                                            cx.notify();
                                        })),
                                ),
                        ),
                );
            } else {
                view = view.child(
                    Button::new("integrate-assignment")
                        .primary()
                        .label("Integrate changes…")
                        .disabled(disabled)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.assignments.confirming_integration = true;
                            cx.notify();
                        })),
                );
            }
        }
        if a["canCancel"] == true && a["state"] == "queued" {
            view = view.child(
                Button::new("cancel-assignment")
                    .label("Stop queued assignment")
                    .disabled(disabled)
                    .on_click(cx.listener(|this, _, _, cx| this.assignment_action("cancel", cx))),
            );
        }
        if let Some(pending) = self.pending.as_ref().filter(|p| matches_saved(p, a)) {
            view = view
                .child(
                    assignment_text(
                        "assignment-pending-action",
                        "A saved action is waiting for confirmation.",
                    )
                    .text_sm(),
                )
                .child(
                    Button::new("retry-assignment-action")
                        .label("Retry saved action")
                        .disabled(self.busy)
                        .on_click(cx.listener(|this, _, _, cx| this.retry(cx))),
                );
            if pending_action(pending) == "integrate" && pending["rejected"] == true {
                view = view
                    .child(
                        assignment_text(
                            "assignment-rejection-reason",
                            strv(pending, "rejectionReason").to_owned(),
                        )
                        .text_sm(),
                    )
                    .child(
                        Button::new("reconsider-assignment-integration")
                            .label("Review current project")
                            .disabled(self.busy)
                            .on_click(cx.listener(|this, _, _, cx| this.reconsider_assignment(cx))),
                    );
            }
        }
        view
    }
}

#[cfg(test)]
mod tests {
    use super::{
        action_body, confirmed, execute_saved_request, may_reconsider, open_assignment_label,
        review_draft_key, save_pending, saved_request,
    };
    use serde_json::{json, Value};
    fn detail(state: &str) -> Value {
        json!({"id":"task","groupId":"group","state":state,"baseRevision":"a".repeat(40),"repositoryHead":"a".repeat(40),"resultRevision":"b".repeat(40),"diff":"diff --git a/a b/a","canCancel":state=="queued"})
    }
    fn pending() -> Value {
        json!({"host":"host","completion":"assignment","assignmentGroupId":"group","assignmentId":"task","method":"POST","path":["api","v1","assignments","task","integrate"],"body":{"resultRevision":"b".repeat(40),"expectedHead":"a".repeat(40)}})
    }
    #[test]
    fn integration_uses_exact_revisions_and_rejects_changed_project() {
        let a = detail("reviewed");
        let body = action_body(&a, "integrate", "").unwrap();
        assert_eq!(body["expectedHead"], a["repositoryHead"]);
        let mut changed = a;
        changed["repositoryHead"] = json!("c".repeat(40));
        assert!(action_body(&changed, "integrate", "").is_err());
        assert!(action_body(&detail("submitted"), "integrate", "").is_err());
    }
    #[test]
    fn saved_identity_and_reconsideration_require_authoritative_scope() {
        let mut p = pending();
        let (_, body) = saved_request(&p, "host").unwrap();
        assert_eq!(body["expectedHead"], "a".repeat(40));
        assert!(saved_request(&p, "another-host").is_err());
        assert!(!may_reconsider(&p, &detail("reviewed")));
        p["rejected"] = json!(true);
        assert!(may_reconsider(&p, &detail("reviewed")));
        assert!(!may_reconsider(&p, &detail("integrating")));
        assert!(confirmed(&p, &detail("integrated")));
        let mut wrong = detail("integrated");
        wrong["groupId"] = json!("another-group");
        assert!(!confirmed(&p, &wrong));
    }
    #[test]
    fn review_notes_are_bound_to_result_and_group() {
        let a = detail("submitted");
        assert!(action_body(&a, "review", "").is_err());
        assert!(action_body(&a, "review", "Verified the focused test").is_ok());
        let key = review_draft_key("host", "group", "task", &a).unwrap();
        let mut b = a.clone();
        b["resultRevision"] = json!("c".repeat(40));
        assert_ne!(Some(key), review_draft_key("host", "group", "task", &b));
        assert!(review_draft_key("host", "wrong-group", "task", &a).is_none());
    }
    #[test]
    fn restart_replays_the_frozen_body_and_confirms_without_duplicate_write() {
        let path =
            std::env::temp_dir().join(format!("wonder-assignment-{}.json", uuid::Uuid::new_v4()));
        save_pending(&path, &pending()).unwrap();
        let restored: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        std::fs::remove_file(path).unwrap();
        let mut methods = vec![];
        execute_saved_request(&restored, "host", |method, route, body| {
            methods.push(method.to_owned());
            assert_eq!(route[3], "task");
            if method == "GET" {
                return Ok(detail("reviewed"));
            }
            assert_eq!(route[4], "integrate");
            assert_eq!(body, &restored["body"]);
            Ok(detail("integrated"))
        })
        .unwrap();
        assert_eq!(methods, ["GET", "POST"]);
        execute_saved_request(&restored, "host", |method, _, _| {
            assert_eq!(method, "GET");
            Ok(detail("integrated"))
        })
        .unwrap();
    }
    #[test]
    fn failed_status_read_cannot_be_mistaken_for_a_rejected_integration() {
        let error = execute_saved_request(&pending(), "host", |method, _, _| {
            assert_eq!(method, "GET");
            Err("Rejected: Access denied".into())
        })
        .unwrap_err();
        assert!(!error.starts_with("Rejected: "));
        let mut other_group = detail("reviewed");
        other_group["groupId"] = json!("elsewhere");
        assert!(execute_saved_request(&pending(), "host", |method, _, _| {
            assert_eq!(method, "GET");
            Ok(other_group.clone())
        })
        .is_err());
    }
    #[test]
    fn cancellation_is_queued_only_and_reconciles_its_terminal_state() {
        assert!(action_body(&detail("working"), "cancel", "").is_err());
        assert_eq!(
            action_body(&detail("queued"), "cancel", "").unwrap(),
            json!({})
        );
        let mut request = pending();
        request["path"][4] = json!("cancel");
        request["body"] = json!({});
        execute_saved_request(&request, "host", |method, _, _| {
            assert_eq!(method, "GET");
            Ok(detail("cancelled"))
        })
        .unwrap();
    }
    #[test]
    fn open_buttons_identify_assignment_project_and_readable_status() {
        let assignment =
            json!({"title":"Add Group navigation","projectName":"Wonder","state":"submitted"});
        assert_eq!(
            open_assignment_label(&assignment),
            "Open Add Group navigation, Wonder, Ready for review"
        );
        let reviewed = json!({"title":"Fix dictation","projectName":"Wonder","state":"reviewed"});
        assert_eq!(
            open_assignment_label(&reviewed),
            "Open Fix dictation, Wonder, Reviewed"
        );
    }
}
