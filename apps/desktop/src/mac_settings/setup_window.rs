//! First-run onboarding owns its own window and never becomes a Settings tab.
use super::*;

pub(super) fn open(model: Entity<MacSettings>, cx: &mut App) {
    if let Some(handle) = model.read(cx).setup_window {
        if handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
        {
            return;
        }
    }
    let target = model.clone();
    let bounds = Bounds::centered(None, size(px(580.), px(520.)), cx);
    match cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            window_min_size: Some(size(px(520.), px(420.))),
            ..Default::default()
        },
        |window, cx| {
            window.set_window_title("Set up Wonder");
            let view = cx.new(|cx| {
                let subscription = cx.observe(&target, |_, _, cx| cx.notify());
                SetupWindow {
                    model: target,
                    _subscription: subscription,
                }
            });
            cx.new(|cx| Root::new(view, window, cx))
        },
    ) {
        Ok(handle) => {
            model.update(cx, |this, _| this.setup_window = Some(handle));
            cx.activate(true);
        }
        Err(error) => crate::menu_bar::show_error(&error.to_string()),
    }
}
struct SetupWindow {
    model: Entity<MacSettings>,
    _subscription: Subscription,
}
impl Render for SetupWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.model.update(cx, |this, cx| {
            let mut content = this.setup(cx);
            if let Some(error) = &this.error {
                content = content.child(note(error.clone()).text_color(cx.theme().danger));
            }
            content = messages(content, &this.state, &["error", "serviceMessage"], cx);
            if this.error.is_some() || !text(&this.state, "error").is_empty() {
                content = content.child(
                    Button::new("retry-setup")
                        .label("Try again")
                        .self_start()
                        .disabled(this.pending.is_some())
                        .on_click(cx.listener(|this, _, _, cx| this.retry(cx))),
                );
            }
            div()
                .size_full()
                .flex()
                .flex_col()
                .bg(cx.theme().background)
                .text_color(cx.theme().foreground)
                .child(
                    div()
                        .id(format!("setup-step-{}", this.state["setupStep"]))
                        .flex_1()
                        .min_h_0()
                        .overflow_y_scroll()
                        .p_6()
                        .child(content),
                )
                .child(
                    div()
                        .flex_shrink_0()
                        .px_6()
                        .pb_5()
                        .child(this.setup_controls(cx)),
                )
        })
    }
}
