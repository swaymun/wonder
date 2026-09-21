#[cfg(feature = "chats")]
use crate::client::Row;
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
            "#101011", "#171718", "#ececef", "#929298", "#252526", "#303032", "#f2b84b", "#dea83d",
            "#231b0b",
        )
    } else {
        (
            "#fafaf8", "#f0f0ed", "#1c1c1f", "#64646b", "#eaeae6", "#dcdcd7", "#9a5a00", "#824b00",
            "#ffffff",
        )
    };
    serde_json::from_value(serde_json::json!({
        "name": if dark {"Wonder Dark"} else {"Wonder Light"},
        "mode": if dark {"dark"} else {"light"}, "font.size": 14, "radius": 6, "radius.lg": 8, "shadow": false,
        "colors": {"background":bg,"foreground":fg,"sidebar.background":sidebar,"sidebar.foreground":fg,
            "muted.background":secondary,"muted.foreground":muted,"border":line,
            "accent.background":secondary,"accent.foreground":fg,"primary.background":amber,
            "primary.foreground":ink,"primary.hover.background":hover,"primary.active.background":hover,
            "ring":amber,"link":amber,"link.hover":hover,"input.background":bg,
            "button.primary.background":amber,"button.primary.foreground":ink,
            "button.primary.hover.background":hover,"button.primary.active.background":hover}
    })).expect("Wonder theme is valid")
}
#[cfg(feature = "chats")]
pub fn show_speaker(group: bool, rows: &[Row], index: usize) -> bool {
    let row = &rows[index];
    group
        && !row.outgoing
        && !row.status
        && (index == 0 || {
            let previous = &rows[index - 1];
            previous.outgoing
                || previous.status
                || previous.identity != row.identity
                || previous.author != row.author
        })
}

pub fn avatar(name: &str, identity: Option<&str>, size: f32) -> Div {
    avatar_color(name, identity, None, size)
}
pub fn avatar_color(name: &str, identity: Option<&str>, color: Option<&str>, size: f32) -> Div {
    let colors = [0x9a7253, 0x5856d6, 0x168c8c, 0x9656ad, 0x3478cb];
    let index = identity
        .unwrap_or(name)
        .bytes()
        .fold(0usize, |value, byte| {
            (value * 31 + byte as usize) % colors.len()
        });
    let color = color
        .and_then(|v| v.strip_prefix('#'))
        .filter(|v| v.len() == 6)
        .and_then(|v| u32::from_str_radix(v, 16).ok())
        .unwrap_or(colors[index]);
    let luminance = |channel: u32| {
        let c = channel as f64 / 255.;
        if c <= 0.04045 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    let light = 0.2126 * luminance((color >> 16) & 255)
        + 0.7152 * luminance((color >> 8) & 255)
        + 0.0722 * luminance(color & 255);
    div()
        .flex()
        .flex_shrink_0()
        .items_center()
        .justify_center()
        .size(px(size))
        .rounded(px(7.))
        .bg(rgb(color))
        .text_color(rgb(if light > 0.179 { 0x111111 } else { 0xffffff }))
        .text_size(px(size * 0.47))
        .font_weight(FontWeight::SEMIBOLD)
        .child(
            name.chars()
                .next()
                .unwrap_or('B')
                .to_uppercase()
                .to_string(),
        )
}

#[cfg(all(test, feature = "chats"))]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn themes_and_speaker_changes() {
        assert_eq!(config(false).font_size, Some(14.));
        assert!(config(true).mode.is_dark());
        let row = |name: &str, outgoing: bool| Row {
            author: name.into(),
            identity: Some(name.into()),
            text: "Reply".into(),
            outgoing,
            status: false,
        };
        let rows = vec![
            row("Ada", false),
            row("Ada", false),
            row("Milo", false),
            row("You", true),
            row("Milo", false),
        ];
        assert!(!show_speaker(false, &rows, 0));
        assert!(show_speaker(true, &rows, 0));
        assert!(!show_speaker(true, &rows, 1));
        assert!(show_speaker(true, &rows, 2));
        assert!(!show_speaker(true, &rows, 3));
        assert!(show_speaker(true, &rows, 4));
    }
}
