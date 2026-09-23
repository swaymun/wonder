//! Bundled Mac host: menu bar, Settings and setup, without the Chats UI.
#[allow(dead_code)]
mod appearance;
#[allow(dead_code)]
mod client;
#[allow(dead_code)]
mod forms;
mod mac_settings;
mod menu_bar;
use gpui_kit::{component::*, *};
use std::time::Duration;

#[cfg(target_os = "macos")]
actions!(wonder, [OpenSettings]);

const CHAT_CLIENT: bool = false;
struct DesktopShell {
    open_chats: Option<fn(&mut App)>,
    #[cfg(target_os = "macos")]
    _menu: menu_bar::MenuBar,
    #[cfg(target_os = "macos")]
    settings: Option<WindowHandle<Root>>,
    #[cfg(target_os = "macos")]
    settings_model: Entity<mac_settings::MacSettings>,
}
impl Global for DesktopShell {}
#[cfg(target_os = "macos")]
fn open_settings(cx: &mut App) {
    if mac_settings::route_setup(cx) {
        return;
    }
    cx.activate(true);
    if let Some(window) = cx.global::<DesktopShell>().settings {
        if window
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
        {
            return;
        }
    }
    let model = cx.global::<DesktopShell>().settings_model.clone();
    let bounds = Bounds::centered(None, size(px(640.), px(700.)), cx);
    match cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            window_min_size: Some(size(px(620.), px(480.))),
            ..Default::default()
        },
        |window, cx| {
            window.set_window_title("Wonder Settings");
            window.focus(&model.read(cx).focus.clone(), cx);
            cx.new(|cx| Root::new(model, window, cx))
        },
    ) {
        Ok(handle) => cx.global_mut::<DesktopShell>().settings = Some(handle),
        Err(error) => menu_bar::show_error(&error.to_string()),
    }
}
fn main() {
    let application = gpui_kit::application().with_assets(gpui_kit::assets::Assets);
    application.on_reopen(open_settings);
    application.run(|cx| {
        gpui_kit::init(cx);
        appearance::init(cx);
        #[cfg(target_os = "macos")]
        {
            cx.bind_keys([KeyBinding::new("cmd-,", OpenSettings, None)]);
            cx.on_action(|_: &OpenSettings, cx| open_settings(cx));
        }
        #[cfg(target_os = "macos")]
        let settings_model = cx.new(mac_settings::MacSettings::new);
        cx.set_global(DesktopShell {
            open_chats: None,
            #[cfg(target_os = "macos")]
            _menu: menu_bar::MenuBar::new(),
            #[cfg(target_os = "macos")]
            settings: None,
            #[cfg(target_os = "macos")]
            settings_model,
        });
        #[cfg(not(target_os = "macos"))]
        cx.on_window_closed(|cx, _| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        cx.spawn(async move |cx| loop {
            cx.background_executor()
                .timer(Duration::from_millis(150))
                .await;
            cx.update(|cx| {
                #[cfg(target_os = "macos")]
                {
                    let refresh = std::env::var("WONDER_SERVICE_DIR")
                        .ok()
                        .map(|path| std::path::Path::new(&path).join("refresh-menu"));
                    let refresh_menu = refresh
                        .filter(|path| path.exists())
                        .is_some_and(|path| std::fs::remove_file(path).is_ok());
                    let shell = cx.global_mut::<DesktopShell>();
                    if refresh_menu {
                        shell._menu = menu_bar::MenuBar::new();
                    }
                    if let Ok(service) = std::env::var("WONDER_SERVICE_DIR") {
                        let directory = std::path::Path::new(&service);
                        if directory.join("open-settings").exists()
                            && std::fs::remove_file(directory.join("open-settings")).is_ok()
                        {
                            open_settings(cx);
                        }
                        if directory.join("update-ready").exists()
                            && directory.join("stopped").exists()
                        {
                            cx.quit();
                            return;
                        }
                    }
                    let actions = menu_bar::pending();
                    if actions & menu_bar::QUIT != 0 {
                        cx.quit();
                        return;
                    }

                    if actions & menu_bar::SETTINGS != 0 {
                        open_settings(cx);
                    }
                }
            });
        })
        .detach();
    });
}
