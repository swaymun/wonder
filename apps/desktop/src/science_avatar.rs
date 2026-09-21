use gpui_kit::*;
use serde_json::{Map, Value};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Shape {
    Sun,
    Orbit,
    Nova,
    Comet,
    Prism,
    Atom,
    Luna,
}

impl Shape {
    pub const ALL: [Self; 7] = [
        Self::Sun,
        Self::Orbit,
        Self::Nova,
        Self::Comet,
        Self::Prism,
        Self::Atom,
        Self::Luna,
    ];

    pub const fn id(self) -> &'static str {
        match self {
            Self::Sun => "sun",
            Self::Orbit => "orbit",
            Self::Nova => "nova",
            Self::Comet => "comet",
            Self::Prism => "prism",
            Self::Atom => "atom",
            Self::Luna => "luna",
        }
    }

    pub const fn title(self) -> &'static str {
        match self {
            Self::Sun => "Sun",
            Self::Orbit => "Orbit",
            Self::Nova => "Nova",
            Self::Comet => "Comet",
            Self::Prism => "Prism",
            Self::Atom => "Atom",
            Self::Luna => "Luna",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|shape| shape.id() == id)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Palette {
    pub id: &'static str,
    pub name: &'static str,
    pub body: u32,
    pub shadow: u32,
    pub accent: u32,
    pub ink: u32,
}

pub const PALETTES: [Palette; 12] = [
    Palette {
        id: "amber",
        name: "Amber",
        body: 0xffb51c,
        shadow: 0xff8b20,
        accent: 0xfff0b3,
        ink: 0x3b2709,
    },
    Palette {
        id: "coral",
        name: "Coral",
        body: 0xff925c,
        shadow: 0xdb633b,
        accent: 0xffe4ad,
        ink: 0x392623,
    },
    Palette {
        id: "rose",
        name: "Rose",
        body: 0xe893b5,
        shadow: 0xba638d,
        accent: 0xf9dce9,
        ink: 0x54243a,
    },
    Palette {
        id: "violet",
        name: "Violet",
        body: 0xb4a0f3,
        shadow: 0x7765c8,
        accent: 0xe4dcff,
        ink: 0x312653,
    },
    Palette {
        id: "indigo",
        name: "Indigo",
        body: 0x8893ee,
        shadow: 0x5d65b8,
        accent: 0xd9dcff,
        ink: 0x262d56,
    },
    Palette {
        id: "ocean",
        name: "Ocean",
        body: 0x5699e7,
        shadow: 0x3264ad,
        accent: 0xb4e8ef,
        ink: 0x182d49,
    },
    Palette {
        id: "sky",
        name: "Sky",
        body: 0x77cedf,
        shadow: 0x4298b4,
        accent: 0xd1f5f7,
        ink: 0x17424a,
    },
    Palette {
        id: "teal",
        name: "Teal",
        body: 0x57b8b3,
        shadow: 0x308e8c,
        accent: 0xb9e9e0,
        ink: 0x153d3c,
    },
    Palette {
        id: "mint",
        name: "Mint",
        body: 0x62c8aa,
        shadow: 0x359d85,
        accent: 0xc8f1df,
        ink: 0x163d35,
    },
    Palette {
        id: "olive",
        name: "Olive",
        body: 0xadbe66,
        shadow: 0x788c42,
        accent: 0xe4edbe,
        ink: 0x343d1b,
    },
    Palette {
        id: "cocoa",
        name: "Cocoa",
        body: 0xc49a7d,
        shadow: 0x946d56,
        accent: 0xecd6c0,
        ink: 0x40291f,
    },
    Palette {
        id: "slate",
        name: "Slate",
        body: 0xa4b0c5,
        shadow: 0x77849d,
        accent: 0xdee4ee,
        ink: 0x293447,
    },
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Resolved {
    pub shape: Shape,
    pub palette: Palette,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RenderPlan {
    pub shape: Shape,
    pub size: u32,
    pub layers: u8,
}

pub fn palette(id: &str) -> Option<Palette> {
    PALETTES.into_iter().find(|palette| palette.id == id)
}

#[cfg(test)]
pub fn palette_ids() -> impl Iterator<Item = &'static str> {
    PALETTES.into_iter().map(|palette| palette.id)
}

pub fn stable_shape(identity: &str) -> Shape {
    let hash = identity.bytes().fold(2_166_136_261u32, |hash, byte| {
        (hash ^ u32::from(byte)).wrapping_mul(16_777_619)
    });
    Shape::ALL[(hash as usize) % Shape::ALL.len()]
}

pub fn palette_for_legacy_color(color: &str) -> Option<&'static str> {
    let normalized = color.to_ascii_lowercase();
    let explicit = match normalized.as_str() {
        "#9a5a00" | "#9a7253" => Some("amber"),
        "#3864a0" | "#3478cb" => Some("ocean"),
        "#287b75" | "#167a7a" | "#168c8c" => Some("teal"),
        "#7654a3" | "#5856d6" | "#9656ad" => Some("violet"),
        "#a44d68" => Some("rose"),
        _ => None,
    };
    explicit.or_else(|| {
        let source = parse_hex(&normalized)?;
        PALETTES
            .iter()
            .min_by_key(|palette| {
                let dr = i32::from(((source >> 16) & 255) as u8)
                    - i32::from(((palette.body >> 16) & 255) as u8);
                let dg = i32::from(((source >> 8) & 255) as u8)
                    - i32::from(((palette.body >> 8) & 255) as u8);
                let db = i32::from((source & 255) as u8) - i32::from((palette.body & 255) as u8);
                dr * dr + dg * dg + db * db
            })
            .map(|palette| palette.id)
    })
}

pub fn resolve(
    shape: Option<&str>,
    palette_id: Option<&str>,
    identity: &str,
    legacy_color: Option<&str>,
) -> Resolved {
    let shape = shape
        .and_then(Shape::from_id)
        .unwrap_or_else(|| stable_shape(identity));
    let palette = palette_id
        .and_then(palette)
        .or_else(|| {
            legacy_color
                .and_then(palette_for_legacy_color)
                .and_then(palette)
        })
        .unwrap_or(PALETTES[0]);
    Resolved { shape, palette }
}

pub fn picker_shape(raw: Option<&str>, identity: &str) -> String {
    raw.map(str::to_owned)
        .unwrap_or_else(|| stable_shape(identity).id().to_owned())
}

pub fn picker_palette(raw: Option<&str>, legacy_color: Option<&str>) -> String {
    raw.map(str::to_owned)
        .or_else(|| {
            legacy_color
                .and_then(palette_for_legacy_color)
                .map(str::to_owned)
        })
        .unwrap_or_else(|| "amber".into())
}

/// Existing Bots only send a field when its visible selection changed. This is
/// important for older hosts and future catalog IDs: a safe fallback is for
/// presentation only and must not overwrite the stored identity on a rename or
/// unrelated settings edit.
pub fn update_fields(
    is_new: bool,
    initial_shape: &str,
    initial_palette: &str,
    selected_shape: &str,
    selected_palette: &str,
) -> Map<String, Value> {
    let mut fields = Map::new();
    if is_new || selected_shape != initial_shape {
        fields.insert("avatarShape".into(), Value::String(selected_shape.into()));
    }
    if is_new || selected_palette != initial_palette {
        fields.insert(
            "avatarPalette".into(),
            Value::String(selected_palette.into()),
        );
    }
    fields
}

#[cfg(test)]
pub fn render_plan(resolved: Resolved, size: f32) -> RenderPlan {
    RenderPlan {
        shape: resolved.shape,
        size: size.max(1.).round() as u32,
        layers: match resolved.shape {
            Shape::Sun => 9,
            Shape::Orbit => 6,
            Shape::Nova => 8,
            Shape::Comet => 8,
            Shape::Prism => 7,
            Shape::Atom => 8,
            Shape::Luna => 6,
        },
    }
}

pub fn avatar(
    _name: &str,
    identity: &str,
    shape: Option<&str>,
    palette_id: Option<&str>,
    legacy_color: Option<&str>,
    size: f32,
) -> Div {
    let resolved = resolve(shape, palette_id, identity, legacy_color);
    let palette = resolved.palette;
    let size = size.max(12.);
    let radius = (size * 0.24).max(3.);
    let mut root = div()
        .relative()
        .flex_shrink_0()
        .size(px(size))
        .rounded(px(radius))
        .overflow_hidden();

    root = match resolved.shape {
        Shape::Sun => sun(root, size, palette),
        Shape::Orbit => orbit(root, size, palette),
        Shape::Nova => nova(root, size, palette),
        Shape::Comet => comet(root, size, palette),
        Shape::Prism => prism(root, size, palette),
        Shape::Atom => atom(root, size, palette),
        Shape::Luna => luna(root, size, palette),
    };
    face(root, size, palette.ink)
}

fn dot(_size: f32, diameter: f32, left: f32, top: f32, color: u32) -> Div {
    div()
        .absolute()
        .left(px(left))
        .top(px(top))
        .size(px(diameter))
        .rounded(px(diameter / 2.))
        .bg(rgb(color))
}

fn bar(width: f32, height: f32, left: f32, top: f32, color: u32) -> Div {
    div()
        .absolute()
        .left(px(left))
        .top(px(top))
        .w(px(width))
        .h(px(height))
        .rounded(px(height / 2.))
        .bg(rgb(color))
}

fn sun(mut root: Div, size: f32, palette: Palette) -> Div {
    let ray = (size * 0.07).max(1.5);
    let length = (size * 0.20).max(3.);
    let offset = (size - ray) / 2.;
    root = root
        .child(bar(ray, length, offset, size * 0.06, palette.accent))
        .child(bar(ray, length, offset, size * 0.74, palette.accent))
        .child(bar(length, ray, size * 0.06, offset, palette.accent))
        .child(bar(length, ray, size * 0.74, offset, palette.accent));
    root.child(dot(
        size,
        size * 0.64,
        size * 0.18,
        size * 0.18,
        palette.shadow,
    ))
    .child(dot(
        size,
        size * 0.55,
        size * 0.225,
        size * 0.145,
        palette.body,
    ))
}

fn orbit(mut root: Div, size: f32, palette: Palette) -> Div {
    let ring = (size * 0.08).max(1.);
    root = root
        .child(
            div()
                .absolute()
                .left(px(size * 0.12))
                .top(px(size * 0.28))
                .w(px(size * 0.76))
                .h(px(size * 0.44))
                .rounded_full()
                .border(px(ring))
                .border_color(rgb(palette.accent)),
        )
        .child(dot(
            size,
            size * 0.48,
            size * 0.26,
            size * 0.26,
            palette.shadow,
        ))
        .child(dot(
            size,
            size * 0.40,
            size * 0.30,
            size * 0.21,
            palette.body,
        ));
    root.child(dot(
        size,
        size * 0.10,
        size * 0.75,
        size * 0.42,
        palette.ink,
    ))
}

fn nova(mut root: Div, size: f32, palette: Palette) -> Div {
    let ray = (size * 0.10).max(2.);
    let center = size * 0.45;
    root = root
        .child(bar(ray, size * 0.72, center, size * 0.14, palette.accent))
        .child(bar(size * 0.72, ray, size * 0.14, center, palette.accent))
        .child(dot(
            size,
            size * 0.62,
            size * 0.19,
            size * 0.19,
            palette.shadow,
        ))
        .child(dot(
            size,
            size * 0.43,
            size * 0.285,
            size * 0.285,
            palette.body,
        ));
    root.child(dot(
        size,
        size * 0.10,
        size * 0.30,
        size * 0.38,
        palette.ink,
    ))
    .child(dot(
        size,
        size * 0.10,
        size * 0.60,
        size * 0.38,
        palette.ink,
    ))
}

fn comet(mut root: Div, size: f32, palette: Palette) -> Div {
    root = root
        .child(dot(
            size,
            size * 0.25,
            size * 0.10,
            size * 0.63,
            palette.accent,
        ))
        .child(dot(
            size,
            size * 0.36,
            size * 0.27,
            size * 0.48,
            palette.shadow,
        ))
        .child(dot(
            size,
            size * 0.18,
            size * 0.52,
            size * 0.30,
            palette.accent,
        ))
        .child(dot(
            size,
            size * 0.50,
            size * 0.42,
            size * 0.17,
            palette.body,
        ));
    root.child(dot(
        size,
        size * 0.09,
        size * 0.58,
        size * 0.34,
        palette.ink,
    ))
}

fn prism(mut root: Div, size: f32, palette: Palette) -> Div {
    root = root
        .child(
            div()
                .absolute()
                .left(px(size * 0.20))
                .top(px(size * 0.17))
                .w(px(size * 0.60))
                .h(px(size * 0.66))
                .rounded(px(size * 0.10))
                .bg(rgb(palette.shadow)),
        )
        .child(
            div()
                .absolute()
                .left(px(size * 0.25))
                .top(px(size * 0.12))
                .w(px(size * 0.50))
                .h(px(size * 0.62))
                .rounded(px(size * 0.10))
                .bg(rgb(palette.accent)),
        );
    root.child(bar(
        size * 0.12,
        size * 0.40,
        size * 0.44,
        size * 0.22,
        palette.body,
    ))
    .child(dot(
        size,
        size * 0.08,
        size * 0.35,
        size * 0.57,
        palette.ink,
    ))
    .child(dot(
        size,
        size * 0.08,
        size * 0.57,
        size * 0.57,
        palette.ink,
    ))
}

fn atom(mut root: Div, size: f32, palette: Palette) -> Div {
    root = root
        .child(
            div()
                .absolute()
                .left(px(size * 0.12))
                .top(px(size * 0.29))
                .w(px(size * 0.76))
                .h(px(size * 0.42))
                .rounded_full()
                .border(px((size * 0.055).max(1.)))
                .border_color(rgb(palette.accent)),
        )
        .child(
            div()
                .absolute()
                .left(px(size * 0.29))
                .top(px(size * 0.12))
                .w(px(size * 0.42))
                .h(px(size * 0.76))
                .rounded_full()
                .border(px((size * 0.055).max(1.)))
                .border_color(rgb(palette.accent)),
        )
        .child(dot(
            size,
            size * 0.43,
            size * 0.285,
            size * 0.285,
            palette.shadow,
        ));
    root.child(dot(
        size,
        size * 0.09,
        size * 0.72,
        size * 0.44,
        palette.ink,
    ))
}

fn luna(mut root: Div, size: f32, palette: Palette) -> Div {
    root = root
        .child(dot(
            size,
            size * 0.66,
            size * 0.18,
            size * 0.17,
            palette.shadow,
        ))
        .child(dot(
            size,
            size * 0.58,
            size * 0.25,
            size * 0.12,
            palette.body,
        ))
        .child(dot(
            size,
            size * 0.10,
            size * 0.34,
            size * 0.40,
            palette.ink,
        ))
        .child(dot(
            size,
            size * 0.10,
            size * 0.59,
            size * 0.40,
            palette.ink,
        ));
    root.child(bar(
        size * 0.19,
        (size * 0.07).max(1.5),
        size * 0.405,
        size * 0.61,
        palette.ink,
    ))
}

fn face(mut root: Div, size: f32, ink: u32) -> Div {
    let eye = (size * 0.075).max(1.5);
    root = root
        .child(dot(size, eye, size * 0.35, size * 0.56, ink))
        .child(dot(size, eye, size * 0.57, size * 0.56, ink));
    root.child(bar(
        size * 0.18,
        (size * 0.045).max(1.),
        size * 0.41,
        size * 0.70,
        ink,
    ))
}

pub fn add_avatar_fields(
    body: &mut Value,
    is_new: bool,
    initial_shape: &str,
    initial_palette: &str,
    selected_shape: &str,
    selected_palette: &str,
) {
    let fields = update_fields(
        is_new,
        initial_shape,
        initial_palette,
        selected_shape,
        selected_palette,
    );
    if let Some(object) = body.as_object_mut() {
        object.extend(fields);
    }
}

fn parse_hex(value: &str) -> Option<u32> {
    let value = value.strip_prefix('#')?;
    (value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| u32::from_str_radix(value, 16).ok())
        .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[::core::prelude::v1::test]
    fn catalog_has_exact_shared_shape_and_palette_ids() {
        assert_eq!(
            Shape::ALL.map(Shape::id),
            ["sun", "orbit", "nova", "comet", "prism", "atom", "luna"]
        );
        assert_eq!(
            palette_ids().collect::<Vec<_>>(),
            [
                "amber", "coral", "rose", "violet", "indigo", "ocean", "sky", "teal", "mint",
                "olive", "cocoa", "slate",
            ]
        );
    }

    #[::core::prelude::v1::test]
    fn fallback_is_deterministic_and_legacy_color_aware() {
        assert_eq!(stable_shape("bot-id"), stable_shape("bot-id"));
        assert_eq!(stable_shape("bot-id"), Shape::Luna);
        assert_ne!(stable_shape("bot-id"), stable_shape("other-id"));
        assert_eq!(palette_for_legacy_color("#3478CB"), Some("ocean"));
        assert_eq!(
            resolve(
                Some("future-shape"),
                Some("future-palette"),
                "bot-id",
                Some("#5856d6")
            ),
            Resolved {
                shape: Shape::Luna,
                palette: palette("violet").unwrap()
            }
        );
    }

    #[::core::prelude::v1::test]
    fn payload_omits_unchanged_existing_identity_and_sends_intentional_changes() {
        assert_eq!(
            update_fields(
                false,
                "future-shape",
                "future-palette",
                "future-shape",
                "future-palette"
            ),
            Map::new()
        );
        assert_eq!(
            update_fields(false, "sun", "amber", "luna", "ocean"),
            json!({"avatarShape":"luna","avatarPalette":"ocean"})
                .as_object()
                .unwrap()
                .clone()
        );
        assert_eq!(
            update_fields(true, "sun", "amber", "sun", "amber"),
            json!({"avatarShape":"sun","avatarPalette":"amber"})
                .as_object()
                .unwrap()
                .clone()
        );
    }

    #[::core::prelude::v1::test]
    fn every_shape_has_native_layers_at_practical_sizes() {
        for shape in Shape::ALL {
            for size in [24., 32., 48., 96.] {
                let plan = render_plan(
                    Resolved {
                        shape,
                        palette: PALETTES[0],
                    },
                    size,
                );
                assert_eq!(plan.size, size as u32);
                assert!(plan.layers >= 6);
            }
        }
    }

    #[::core::prelude::v1::test]
    fn add_avatar_fields_keeps_unrelated_payloads_intact() {
        let mut body = json!({"name":"Ada","role":"Research"});
        add_avatar_fields(&mut body, false, "sun", "amber", "sun", "amber");
        assert_eq!(body, json!({"name":"Ada","role":"Research"}));
        add_avatar_fields(&mut body, false, "sun", "amber", "orbit", "amber");
        assert_eq!(body["avatarShape"], "orbit");
        assert!(body.get("avatarPalette").is_none());
    }
}
