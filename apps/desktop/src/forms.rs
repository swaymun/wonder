use gpui_kit::{
    component::{
        input::{Input, InputState, Textarea, TextareaState},
        select::{Select, SelectItem, SelectState},
        *,
    },
    *,
};
use std::collections::BTreeMap;

#[derive(Clone)]
pub struct Choice {
    pub id: String,
    pub label: String,
}
impl SelectItem for Choice {
    type Value = String;
    fn title(&self) -> SharedString {
        self.label.clone().into()
    }
    fn value(&self) -> &String {
        &self.id
    }
}
pub fn choices(items: &[(&str, &str)]) -> Vec<Choice> {
    items
        .iter()
        .map(|(id, label)| Choice {
            id: (*id).into(),
            label: (*label).into(),
        })
        .collect()
}
#[derive(Default)]
pub struct Form {
    fields: BTreeMap<&'static str, Entity<InputState>>,
    texts: BTreeMap<&'static str, Entity<TextareaState>>,
    selects: BTreeMap<&'static str, Entity<SelectState<Vec<Choice>>>>,
}
impl Form {
    pub fn input(&mut self, key: &'static str, value: &str, window: &mut Window, cx: &mut App) {
        self.fields.insert(
            key,
            cx.new(|cx| {
                let mut state = InputState::new(window, cx);
                state.set_value(value.to_owned(), window, cx);
                state
            }),
        );
    }
    pub fn text(&mut self, key: &'static str, value: &str, window: &mut Window, cx: &mut App) {
        self.texts.insert(
            key,
            cx.new(|cx| {
                let mut state = TextareaState::new(window, cx);
                state.set_value(value.to_owned(), window, cx);
                state
            }),
        );
    }
    pub fn select(
        &mut self,
        key: &'static str,
        value: &str,
        options: Vec<Choice>,
        window: &mut Window,
        cx: &mut App,
    ) {
        let selected = options
            .iter()
            .position(|c| c.id == value)
            .map(IndexPath::new);
        self.selects.insert(
            key,
            cx.new(|cx| SelectState::new(options, selected, window, cx)),
        );
    }
    pub fn observe<T: 'static>(
        &self,
        cx: &mut Context<T>,
        changed: fn(&mut T, &mut Context<T>),
    ) -> Vec<Subscription> {
        let mut subscriptions = vec![];
        for state in self.fields.values() {
            subscriptions.push(cx.observe(state, move |this, _, cx| changed(this, cx)));
        }
        for state in self.texts.values() {
            subscriptions.push(cx.observe(state, move |this, _, cx| changed(this, cx)));
        }
        for state in self.selects.values() {
            subscriptions.push(cx.observe(state, move |this, _, cx| changed(this, cx)));
        }
        subscriptions
    }
    pub fn is_empty(&self) -> bool {
        self.fields.is_empty() && self.texts.is_empty() && self.selects.is_empty()
    }
    pub fn snapshot(&self, cx: &App) -> serde_json::Value {
        self.fields
            .keys()
            .chain(self.texts.keys())
            .chain(self.selects.keys())
            .map(|key| ((*key).into(), serde_json::json!(self.value(key, cx))))
            .collect::<serde_json::Map<_, _>>()
            .into()
    }
    pub fn restore(&mut self, values: &serde_json::Value, window: &mut Window, cx: &mut App) {
        for (key, state) in &self.fields {
            if let Some(value) = values[*key].as_str() {
                state.update(cx, |state, cx| {
                    state.set_value(value.to_owned(), window, cx)
                });
            }
        }
        for (key, state) in &self.texts {
            if let Some(value) = values[*key].as_str() {
                state.update(cx, |state, cx| {
                    state.set_value(value.to_owned(), window, cx)
                });
            }
        }
        for (key, state) in &self.selects {
            if let Some(value) = values[*key].as_str() {
                state.update(cx, |state, cx| {
                    state.set_selected_value(&value.to_owned(), window, cx)
                });
            }
        }
    }
    pub fn value(&self, key: &str, cx: &App) -> String {
        if let Some(v) = self.fields.get(key) {
            v.read(cx).value().to_string()
        } else if let Some(v) = self.texts.get(key) {
            v.read(cx).value().to_string()
        } else {
            self.selects
                .get(key)
                .and_then(|v| v.read(cx).selected_value().cloned())
                .unwrap_or_default()
        }
    }
    pub fn set_value(
        &self,
        key: &str,
        value: &str,
        window: &mut Window,
        cx: &mut App,
    ) {
        if let Some(state) = self.fields.get(key) {
            state.update(cx, |state, cx| state.set_value(value.to_owned(), window, cx));
        } else if let Some(state) = self.texts.get(key) {
            state.update(cx, |state, cx| state.set_value(value.to_owned(), window, cx));
        } else if let Some(state) = self.selects.get(key) {
            state.update(cx, |state, cx| state.set_selected_value(&value.to_owned(), window, cx));
        }
    }
    pub fn field(&self, key: &'static str, label: &'static str, disabled: bool) -> Div {
        let field = if let Some(v) = self.fields.get(key) {
            Input::new(v)
                .aria_label(label)
                .disabled(disabled)
                .w_full()
                .into_any_element()
        } else if let Some(v) = self.texts.get(key) {
            Textarea::new(v)
                .aria_label(label)
                .disabled(disabled)
                .h(px(100.))
                .w_full()
                .into_any_element()
        } else {
            Select::new(&self.selects[key])
                .accessibility_label(label)
                .disabled(disabled)
                .w_full()
                .into_any_element()
        };
        div()
            .flex()
            .flex_col()
            .gap_2()
            .w_full()
            .child(div().text_sm().font_weight(FontWeight::MEDIUM).child(label))
            .child(field)
    }
}
