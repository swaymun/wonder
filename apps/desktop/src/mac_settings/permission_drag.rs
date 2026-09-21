use super::*;
use std::path::PathBuf;

pub(super) fn open(model: Entity<MacSettings>, request: Value, cx: &mut App) {
    let path = PathBuf::from(text(&request, "path"));
    if !path.is_dir() {
        return;
    }
    let x = request["x"].as_f64().unwrap_or(800.) as f32;
    let y = request["y"].as_f64().unwrap_or(200.) as f32;
    let result = cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                point(px(x), px(y)),
                size(px(240.), px(170.)),
            ))),
            window_min_size: Some(size(px(240.), px(170.))),
            ..Default::default()
        },
        |window, cx| {
            window.set_window_title("Allow Wonder");
            let view = cx.new(|_| AppDrag { path });
            cx.new(|cx| Root::new(view, window, cx))
        },
    );
    match result {
        Ok(handle) => model.update(cx, |model, _| model.permission_drag_window = Some(handle)),
        Err(error) => model.update(cx, |model, cx| {
            model.error = Some(error.to_string());
            cx.notify();
        }),
    }
}
struct AppDrag {
    path: PathBuf,
}
impl Render for AppDrag {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .p_4()
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .gap_3()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(
                div()
                    .id("drag-wonder-app")
                    .p_3()
                    .border_1()
                    .border_color(cx.theme().border)
                    .rounded_md()
                    .cursor_grab()
                    .role(Role::Label)
                    .aria_label("Drag Wonder into System Settings")
                    .child("Wonder.app")
                    .on_drag(self.path.clone(), |_, _, _, cx| cx.new(|_| Empty))
                    .external_drag_payload(|path: &PathBuf, _, _| {
                        Some(ExternalDragPayload::Files(FileDragPaths::new([(
                            path.clone(),
                            true,
                        )])))
                    }),
            )
            .child(note("Drag Wonder into System Settings.").text_sm())
    }
}
