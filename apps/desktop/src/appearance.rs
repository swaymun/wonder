use gpui_kit::{
    component::{Theme, ThemeConfig, ThemeMode},
    *,
};
use std::rc::Rc;

#[derive(Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Preference {
    #[default]
    System,
    Light,
    Dark,
}
impl Global for Preference {}
impl Preference {
    pub const ALL: [Self; 3] = [Self::System, Self::Light, Self::Dark];
}
fn preference_path() -> Result<std::path::PathBuf, String> {
    std::env::var_os("WONDER_DESKTOP_DATA_DIR")
        .map(std::path::PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|p| std::path::PathBuf::from(p).join(".wonder-desktop"))
        })
        .map(|p| p.join("appearance.json"))
        .ok_or_else(|| "Desktop settings folder unavailable".into())
}
pub fn select(preference: Preference, window: &mut Window, cx: &mut App) -> Result<(), String> {
    let path = preference_path()?;
    let save = || -> std::io::Result<()> {
        std::fs::create_dir_all(path.parent().unwrap())?;
        let temporary = path.with_extension("json.tmp");
        std::fs::write(&temporary, serde_json::to_vec(&preference)?)?;
        std::fs::rename(temporary, &path)
    };
    save().map_err(|_| "Couldn’t save appearance. Please try again.".to_string())?;
    cx.set_global(preference);
    #[cfg(target_os = "macos")]
    crate::menu_bar::set_appearance(match preference {
        Preference::System => None,
        Preference::Light => Some(false),
        Preference::Dark => Some(true),
    });
    sync(Some(window), cx);
    cx.refresh_windows();
    Ok(())
}
pub fn sync(window: Option<&mut Window>, cx: &mut App) {
    match *cx.global::<Preference>() {
        Preference::System => Theme::sync_system_appearance(window, cx),
        Preference::Light => Theme::change(ThemeMode::Light, window, cx),
        Preference::Dark => Theme::change(ThemeMode::Dark, window, cx),
    }
}

/// Keep the System preference in step with macOS while a window is open.
pub fn follow_system(window: &mut Window) {
    window
        .observe_window_appearance(|window, cx| {
            if *cx.global::<Preference>() == Preference::System {
                Theme::sync_system_appearance(Some(window), cx);
                cx.refresh_windows();
            }
        })
        .detach();
}

// Wonder's authored palettes apply to the existing native component system.
pub fn init(cx: &mut App) {
    let light = config(false);
    let dark = config(true);
    let theme = Theme::global_mut(cx);
    theme.light_theme = Rc::new(light);
    theme.dark_theme = Rc::new(dark);
    let preference = preference_path()
        .ok()
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|bytes| serde_json::from_slice::<Preference>(&bytes).ok())
        .unwrap_or_default();
    cx.set_global(preference);
    #[cfg(target_os = "macos")]
    crate::menu_bar::set_appearance(match preference {
        Preference::System => None,
        Preference::Light => Some(false),
        Preference::Dark => Some(true),
    });
    sync(None, cx);
}
fn config(dark: bool) -> ThemeConfig {
    let (bg, sidebar, fg, muted, secondary, line, amber, hover, ink) = if dark {
        (
            "#211c18", "#2b221a", "#fff5e6", "#b7a896", "#3d3024", "#4b3c2e", "#ffbd55", "#ffab36",
            "#231b0b",
        )
    } else {
        (
            "#fffdf8", "#fff0cc", "#342619", "#766654", "#f8e5bd", "#e8decd", "#a76000", "#8b4e00",
            "#ffffff",
        )
    };
    serde_json::from_value(serde_json::json!({
        "name": if dark {"Wonder Dark"} else {"Wonder Light"},
        "mode": if dark {"dark"} else {"light"}, "font.size": 14, "radius": 6, "radius.lg": 8, "shadow": false,
        "colors": {"background":bg,"foreground":fg,"sidebar.background":sidebar,"sidebar.foreground":fg,
            "muted.background":secondary,"muted.foreground":muted,"border":line,
            "secondary.background":secondary,"secondary.foreground":fg,
            "tab_bar.segmented.background":secondary,"tab.active.background":bg,
            "tab.foreground":fg,"tab.active.foreground":fg,
            "accent.background":secondary,"accent.foreground":fg,"primary.background":amber,
            "primary.foreground":ink,"primary.hover.background":hover,"primary.active.background":hover,
            "ring":amber,"link":amber,"link.hover":hover,"input.background":bg,
            "button.primary.background":amber,"button.primary.foreground":ink,
            "button.primary.hover.background":hover,"button.primary.active.background":hover}
    })).expect("Wonder theme is valid")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn theme_configs_remain_compatible_with_native_components() {
        assert_eq!(config(false).font_size, Some(14.));
        assert!(config(true).mode.is_dark());
    }
}
