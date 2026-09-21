use super::*;
use serde_json::Value;

pub(super) struct QuestionForm {
    pub id: String,
    pub chat: String,
    deadline: u64,
    questions: Vec<Value>,
    inputs: Vec<Entity<TextareaState>>,
    _subscriptions: Vec<Subscription>,
}
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
impl Chats {
    pub(super) fn update_question(
        &mut self,
        value: &Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(error) = value["questionsError"].as_str() {
            self.question_load_error = Some(error.into());
            return;
        }
        self.question_load_error = None;
        let next = value["questions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|q| {
                q["state"] == "pending"
                    && q["expiresAtMs"]
                        .as_u64()
                        .is_some_and(|deadline| deadline > now_ms())
            });
        let Some(q) = next else {
            if self
                .question
                .as_ref()
                .is_some_and(|q| q.deadline <= now_ms())
            {
                self.question_error =
                    Some("This optional question expired without an answer.".into());
            }
            self.question = None;
            return;
        };
        let (Some(id), Some(chat), Some(questions), Some(deadline)) = (
            q["id"].as_str(),
            self.selected.clone(),
            q["questions"].as_array(),
            q["expiresAtMs"].as_u64(),
        ) else {
            return;
        };
        if self
            .question
            .as_ref()
            .is_some_and(|old| old.id == id && old.chat == chat)
        {
            return;
        }
        let key = self.draft_key(&format!("question:{id}"));
        let mut inputs = vec![];
        let mut subscriptions = vec![];
        for index in 0..questions.len() {
            let text = self
                .saved
                .answers
                .get(&key)
                .and_then(|d| d.values.get(index))
                .cloned()
                .unwrap_or_default();
            let input = cx.new(|cx| {
                let mut input = TextareaState::new(window, cx).placeholder("Your answer");
                input.set_value(text, window, cx);
                input
            });
            let key = key.clone();
            let count = questions.len();
            subscriptions.push(cx.subscribe(&input, move |this, input, event, cx| {
                if matches!(event, InputEvent::Change) {
                    let draft = this.saved.answers.entry(key.clone()).or_default();
                    draft.values.resize(count, String::new());
                    draft.values[index] = input.read(cx).value().to_string();
                    if let Some(disk) = &this.disk {
                        if let Err(error) = disk.save(&this.saved) {
                            this.question_error = Some(error);
                        }
                    }
                    cx.notify();
                }
            }));
            inputs.push(input);
        }
        self.question = Some(QuestionForm {
            id: id.into(),
            chat,
            deadline,
            questions: questions.clone(),
            inputs,
            _subscriptions: subscriptions,
        });
    }
    fn answer_question(&mut self, skip: bool, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let (Some(q), Some(connection), Some(disk), Some(host)) = (
            &self.question,
            self.connection.clone(),
            &self.disk,
            self.host.clone(),
        ) else {
            return;
        };
        let id = q.id.clone();
        let chat = q.chat.clone();
        let values: Vec<String> = q
            .inputs
            .iter()
            .map(|v| v.read(cx).value().to_string())
            .collect();
        let key = self.draft_key(&format!("question:{id}"));
        let draft = self.saved.answers.entry(key).or_default();
        if draft.pending.is_none() {
            if q.deadline <= now_ms()
                || (!skip && values.iter().any(|v| v.trim().is_empty() || v.len() > 8192))
            {
                return;
            }
            draft.values = values.clone();
            draft.pending =
                Some(serde_json::json!({"answers":if skip {vec![]} else {values},"skip":skip}));
        }
        let body = draft.pending.clone().unwrap();
        if let Err(error) = disk.save(&self.saved) {
            self.question_error = Some(error);
            cx.notify();
            return;
        }
        self.busy = true;
        self.question_error = None;
        let sender = self.sender.clone();
        std::thread::spawn(move || {
            let result = connection
                .answer(&chat, &id, &body, &host)
                .map(|_| Value::Null);
            let _ = sender.send(Response {
                chat: Some(chat),
                result,
                sent: false,
                apps: false,
                answer: Some(id),
            });
        });
        cx.notify();
    }
    pub(super) fn question_view(&self, cx: &mut Context<Self>) -> Div {
        let mut view = div().flex().flex_col().gap_2();
        if let Some(q) = &self.question {
            let key = self.draft_key(&format!("question:{}", q.id));
            let pending = self
                .saved
                .answers
                .get(&key)
                .is_some_and(|d| d.pending.is_some());
            let expired = q.deadline <= now_ms();
            let valid = q.inputs.iter().all(|input| {
                let value = input.read(cx).value();
                !value.trim().is_empty() && value.len() <= 8192
            });
            view = view
                .px_6()
                .py_3()
                .child(
                    div()
                        .font_weight(FontWeight::SEMIBOLD)
                        .child("A question for you"),
                )
                .child(
                    div()
                        .id("question-fields")
                        .max_h(px(220.))
                        .overflow_y_scroll()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .children(q.questions.iter().zip(&q.inputs).enumerate().map(
                            |(index, (question, input))| {
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_2()
                                    .child(
                                        question["title"].as_str().unwrap_or("Question").to_owned(),
                                    )
                                    .child(
                                        div().flex().flex_wrap().gap_2().children(
                                            question["options"]
                                                .as_array()
                                                .into_iter()
                                                .flatten()
                                                .filter_map(Value::as_str)
                                                .enumerate()
                                                .map(|(option, label)| {
                                                    let text = label.to_owned();
                                                    let input = input.clone();
                                                    Button::new((
                                                        SharedString::from(format!(
                                                            "question-option-{index}"
                                                        )),
                                                        option,
                                                    ))
                                                    .label(text.clone())
                                                    .disabled(self.busy || pending || expired)
                                                    .selected(
                                                        input.read(cx).value().as_ref() == text,
                                                    )
                                                    .on_click(cx.listener(
                                                        move |this, _, window, cx| {
                                                            input.update(cx, |state, cx| {
                                                                state.set_value(
                                                                    text.clone(),
                                                                    window,
                                                                    cx,
                                                                )
                                                            });
                                                            if let Some(q) = &this.question {
                                                                let key = this.draft_key(&format!(
                                                                    "question:{}",
                                                                    q.id
                                                                ));
                                                                let values = q
                                                                    .inputs
                                                                    .iter()
                                                                    .map(|v| {
                                                                        v.read(cx)
                                                                            .value()
                                                                            .to_string()
                                                                    })
                                                                    .collect();
                                                                this.saved
                                                                    .answers
                                                                    .entry(key)
                                                                    .or_default()
                                                                    .values = values;
                                                                if let Some(disk) = &this.disk {
                                                                    if let Err(error) =
                                                                        disk.save(&this.saved)
                                                                    {
                                                                        this.question_error =
                                                                            Some(error);
                                                                    }
                                                                }
                                                            }
                                                            cx.notify();
                                                        },
                                                    ))
                                                }),
                                        ),
                                    )
                                    .child(
                                        Textarea::new(input)
                                            .h(px(58.))
                                            .disabled(self.busy || pending || expired),
                                    )
                            },
                        )),
                )
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(
                            Button::new("answer-question")
                                .label(if pending {
                                    "Check saved reply"
                                } else {
                                    "Reply"
                                })
                                .disabled(
                                    self.busy
                                        || self.disk.is_none()
                                        || (!pending && (expired || !valid)),
                                )
                                .on_click(
                                    cx.listener(|this, _, _, cx| this.answer_question(false, cx)),
                                ),
                        )
                        .when(!pending, |v| {
                            v.child(
                                Button::new("skip-question")
                                    .label("Skip")
                                    .disabled(self.busy || expired || self.disk.is_none())
                                    .on_click(
                                        cx.listener(|this, _, _, cx| {
                                            this.answer_question(true, cx)
                                        }),
                                    ),
                            )
                        }),
                );
        }
        if let Some(error) = self
            .question_error
            .as_ref()
            .or(self.question_load_error.as_ref())
        {
            view = view.child(
                div()
                    .px_6()
                    .text_color(cx.theme().danger)
                    .child(error.clone()),
            );
        }
        view
    }
}
