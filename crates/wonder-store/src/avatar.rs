//! The server-side science avatar catalog and legacy color migration rules.
//!
//! Keep this list in lockstep with `assets/bot-avatars/science/palettes.json`.
//! Native clients copy the identifiers and display metadata into their own
//! platform model so a client never needs to parse the asset manifest.

pub const CATALOG_SOURCE_VERSION: &str = "science-avatar-v1";
pub const CATALOG_SOURCE_HASH: &str =
    "9324e397b3c5d27dd693bac25f5a776d451fb7ad941f7567f21446e79fc63c3a";
pub const DEFAULT_SHAPE: &str = "sun";
pub const DEFAULT_PALETTE: &str = "amber";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AvatarPalette {
    pub id: &'static str,
    pub name: &'static str,
    pub body: &'static str,
    pub shadow: &'static str,
    pub accent: &'static str,
    pub ink: &'static str,
}

pub const AVATAR_SHAPES: [&str; 7] = ["sun", "orbit", "nova", "comet", "prism", "atom", "luna"];

pub const AVATAR_PALETTES: [AvatarPalette; 12] = [
    AvatarPalette {
        id: "amber",
        name: "Amber",
        body: "#ffb51c",
        shadow: "#ff8b20",
        accent: "#fff0b3",
        ink: "#3b2709",
    },
    AvatarPalette {
        id: "coral",
        name: "Coral",
        body: "#ff925c",
        shadow: "#db633b",
        accent: "#ffe4ad",
        ink: "#392623",
    },
    AvatarPalette {
        id: "rose",
        name: "Rose",
        body: "#e893b5",
        shadow: "#ba638d",
        accent: "#f9dce9",
        ink: "#54243a",
    },
    AvatarPalette {
        id: "violet",
        name: "Violet",
        body: "#b4a0f3",
        shadow: "#7765c8",
        accent: "#e4dcff",
        ink: "#312653",
    },
    AvatarPalette {
        id: "indigo",
        name: "Indigo",
        body: "#8893ee",
        shadow: "#5d65b8",
        accent: "#d9dcff",
        ink: "#262d56",
    },
    AvatarPalette {
        id: "ocean",
        name: "Ocean",
        body: "#5699e7",
        shadow: "#3264ad",
        accent: "#b4e8ef",
        ink: "#182d49",
    },
    AvatarPalette {
        id: "sky",
        name: "Sky",
        body: "#77cedf",
        shadow: "#4298b4",
        accent: "#d1f5f7",
        ink: "#17424a",
    },
    AvatarPalette {
        id: "teal",
        name: "Teal",
        body: "#57b8b3",
        shadow: "#308e8c",
        accent: "#b9e9e0",
        ink: "#153d3c",
    },
    AvatarPalette {
        id: "mint",
        name: "Mint",
        body: "#62c8aa",
        shadow: "#359d85",
        accent: "#c8f1df",
        ink: "#163d35",
    },
    AvatarPalette {
        id: "olive",
        name: "Olive",
        body: "#adbe66",
        shadow: "#788c42",
        accent: "#e4edbe",
        ink: "#343d1b",
    },
    AvatarPalette {
        id: "cocoa",
        name: "Cocoa",
        body: "#c49a7d",
        shadow: "#946d56",
        accent: "#ecd6c0",
        ink: "#40291f",
    },
    AvatarPalette {
        id: "slate",
        name: "Slate",
        body: "#a4b0c5",
        shadow: "#77849d",
        accent: "#dee4ee",
        ink: "#293447",
    },
];

/// The initial conversational Bot name matches its resolved character.
pub fn shape_name(shape: &str) -> &'static str {
    match shape {
        "orbit" => "Orbit",
        "nova" => "Nova",
        "comet" => "Comet",
        "prism" => "Prism",
        "atom" => "Atom",
        "luna" => "Luna",
        _ => "Sun",
    }
}

pub fn valid_shape(value: Option<&str>) -> bool {
    value.is_none_or(|value| AVATAR_SHAPES.contains(&value))
}

pub fn valid_palette(value: Option<&str>) -> bool {
    value.is_none_or(|value| AVATAR_PALETTES.iter().any(|palette| palette.id == value))
}

pub fn valid_color(value: Option<&str>) -> bool {
    value.is_none_or(|value| parse_hex(value).is_some())
}

pub fn palette(id: &str) -> Option<&'static AvatarPalette> {
    AVATAR_PALETTES.iter().find(|palette| palette.id == id)
}

pub fn default_palette_for_shape(shape: &str) -> &'static str {
    match shape {
        "orbit" => "coral",
        "nova" => "amber",
        "comet" => "sky",
        "prism" => "violet",
        "atom" => "ocean",
        "luna" => "violet",
        _ => "amber",
    }
}

/// Stable only on the immutable Bot identity. Names may change without moving
/// a character to another shape.
pub fn default_shape_for_identity(identity: &str) -> &'static str {
    let hash = identity.bytes().fold(2_166_136_261u32, |hash, byte| {
        (hash ^ u32::from(byte)).wrapping_mul(16_777_619)
    });
    AVATAR_SHAPES[(hash as usize) % AVATAR_SHAPES.len()]
}

/// New identities vary once, while retries and relaunches keep their palette.
pub fn default_palette_for_identity(identity: &str) -> &'static str {
    let hash = format!("palette:{identity}")
        .bytes()
        .fold(2_166_136_261u32, |hash, byte| {
            (hash ^ u32::from(byte)).wrapping_mul(16_777_619)
        });
    AVATAR_PALETTES[hash as usize % AVATAR_PALETTES.len()].id
}

fn parse_hex(value: &str) -> Option<(u8, u8, u8)> {
    let value = value.strip_prefix('#')?;
    if value.len() != 6 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    Some((
        u8::from_str_radix(&value[0..2], 16).ok()?,
        u8::from_str_radix(&value[2..4], 16).ok()?,
        u8::from_str_radix(&value[4..6], 16).ok()?,
    ))
}

/// Map the five colors offered by the old clients before falling back to a
/// stable nearest-body-color calculation for older/custom valid values.
pub fn palette_for_legacy_color(value: &str) -> Option<&'static str> {
    let normalized = value.to_ascii_lowercase();
    let explicit = match normalized.as_str() {
        // Values used by the old iOS picker.
        "#9a5a00" => Some("amber"),
        "#3864a0" => Some("ocean"),
        "#287b75" | "#167a7a" => Some("teal"),
        "#7654a3" => Some("violet"),
        "#a44d68" => Some("rose"),
        // Values used by the older desktop picker.
        "#9a7253" => Some("amber"),
        "#3478cb" => Some("ocean"),
        "#168c8c" => Some("teal"),
        "#5856d6" | "#9656ad" => Some("violet"),
        _ => None,
    };
    explicit.or_else(|| {
        let source = parse_hex(&normalized)?;
        AVATAR_PALETTES
            .iter()
            .min_by_key(|palette| {
                let body = parse_hex(palette.body).expect("catalog body is valid hex");
                let dr = i32::from(source.0) - i32::from(body.0);
                let dg = i32::from(source.1) - i32::from(body.1);
                let db = i32::from(source.2) - i32::from(body.2);
                dr * dr + dg * dg + db * db
            })
            .map(|palette| palette.id)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_character_has_its_initial_display_name() {
        let names: Vec<_> = AVATAR_SHAPES.into_iter().map(shape_name).collect();
        assert_eq!(
            names,
            ["Sun", "Orbit", "Nova", "Comet", "Prism", "Atom", "Luna"]
        );
        assert_eq!(shape_name(default_shape_for_identity("bot-id")), "Luna");
    }

    #[test]
    fn new_identity_defaults_vary_without_rerolling() {
        let shapes: std::collections::HashSet<_> = (0..100)
            .map(|i| default_shape_for_identity(&format!("bot-{i}")))
            .collect();
        let palettes: std::collections::HashSet<_> = (0..100)
            .map(|i| default_palette_for_identity(&format!("bot-{i}")))
            .collect();
        assert_eq!(shapes.len(), AVATAR_SHAPES.len());
        assert_eq!(palettes.len(), AVATAR_PALETTES.len());
        assert_eq!(default_palette_for_identity("bot-id"), "violet");
    }

    #[test]
    fn catalog_and_legacy_rules_are_stable() {
        assert_eq!(CATALOG_SOURCE_HASH.len(), 64);
        assert_eq!(
            CATALOG_SOURCE_HASH,
            "9324e397b3c5d27dd693bac25f5a776d451fb7ad941f7567f21446e79fc63c3a"
        );
        assert_eq!(AVATAR_SHAPES.len(), 7);
        assert_eq!(AVATAR_PALETTES.len(), 12);
        assert_eq!(DEFAULT_SHAPE, "sun");
        assert_eq!(DEFAULT_PALETTE, "amber");
        assert_eq!(palette_for_legacy_color("#9A5A00"), Some("amber"));
        assert_eq!(palette_for_legacy_color("#3864A0"), Some("ocean"));
        assert_eq!(palette_for_legacy_color("#287B75"), Some("teal"));
        assert_eq!(palette_for_legacy_color("#7654A3"), Some("violet"));
        assert_eq!(palette_for_legacy_color("#A44D68"), Some("rose"));
        assert_eq!(palette_for_legacy_color("#3478cb"), Some("ocean"));
        assert_eq!(palette_for_legacy_color("#5856d6"), Some("violet"));
        assert_eq!(palette_for_legacy_color("#a44d68"), Some("rose"));
        assert_eq!(palette_for_legacy_color("#5699e7"), Some("ocean"));
        assert_eq!(palette_for_legacy_color("#123456"), Some("teal"));
        assert_eq!(palette_for_legacy_color("not-a-color"), None);
        assert!(!valid_color(Some("#12345")));
        assert!(valid_color(Some("#123456")));
        assert_eq!(
            default_shape_for_identity("bot-id"),
            default_shape_for_identity("bot-id")
        );
        assert_eq!(default_shape_for_identity("bot-id"), "luna");
        assert_ne!(
            default_shape_for_identity("bot-id"),
            default_shape_for_identity("other-id")
        );
    }
}
