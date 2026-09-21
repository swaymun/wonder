# Wonder science avatars

Seven original SVG assets: **Sun, Orbit, Nova, Comet, Prism, Atom, and Luna**.
Open `preview.html` to compare palettes, light/dark backgrounds, sizes, and
activity states, or save a recolored animated or still SVG. The preview works
offline without dependencies.

Sun follows the geometry of Wonder's existing iOS app icon: a rising half sun,
five rounded rays, pill-shaped eyes, and curved smile. The other six translate
the approved astronomy/science concept sheet into simple editable vectors.
The shipped native clients consume the stable shape and palette identifiers
from this catalog and render equivalent native geometry without parsing SVG at
runtime.

The September 15 refinement preserves Sun and all twelve palettes byte for
byte. Orbit and Atom gain clearer ring crossings, Nova has balanced points,
Prism has aligned facets and a centered face, Comet has a gentler expression,
and Luna has quieter craters. Comet and Luna use intentional optical scaling.
Stored shape and palette IDs remain unchanged.

## Colors

The preview offers 12 fixed colors: **Amber, Coral, Rose, Violet, Indigo,
Ocean, Sky, Teal, Mint, Olive, Cocoa, and Slate**. Each includes coordinated
body, shadow, accent, and face colors defined in `palettes.json`. There are no
custom color inputs. **Character colors** applies a default from this same
set to each character; Sun defaults to Amber.

Each SVG has a `0 0 256 256` viewBox, a transparent background, accessible name,
and fallback colors. The rendering implementation uses these CSS custom
properties; they are not user-editable controls:

```css
.bot-avatar {
  --avatar-body: #5699e7;
  --avatar-shadow: #3264ad;
  --avatar-accent: #b4e8ef;
  --avatar-ink: #182d49;
}
```

Put the SVG inline inside that element, or apply the variables directly to its
root. CSS variables on a parent do not cross into an SVG loaded through `<img>`.
Use **Save SVG** in the preview for a portable version with literal colors;
it resolves every color variable, including defaults. This is also the form
to use with SVG renderers that do not support CSS custom properties. Browser
preview results remain separate from native rendering verification.

## Data-contract source validation

The root SVGs and `palettes.json` are the authoritative source for the S3
avatar identity contract. Run the dependency-free build-time gate from the
repository root:

```sh
python3 assets/bot-avatars/science/validate-assets.py
```

It requires exactly seven root SVGs and twelve palettes, validates the authored
SVG subset, rejects unsupported elements/attributes/paints/path tokens, and
checks `catalog-manifest.json` for the deterministic source version/hash. Use
`--write-manifest` only when an intentional source change is reviewed. The
current source version is `science-avatar-v1`; the manifest hash is the input
to the native renderer handoff. Native code must consume the stable shape and
palette identifiers plus pre-parsed geometry; it must not parse SVG/JSON,
rasterize, or use a WebView at runtime.

Sun intentionally uses body/shadow/face only; its geometry has no accent part.

## Native iOS geometry

The iOS renderer uses cached paths generated directly from the seven originals.
This preserves SVG arc directions, front/back ring halves, layer order, facets,
face details, transforms and opacity. No SVG parsing occurs in the app.

After intentionally editing and validating the originals, run:

```sh
python3 assets/bot-avatars/science/generate-ios.py
python3 assets/bot-avatars/science/generate-ios.py --check
python3 -m unittest discover -s assets/bot-avatars/science -p 'test_generate_ios.py'
```

Commit `apps/ios/Wonder/ScienceAvatarGeometry.swift` with its SVG sources. The
compiler supports the current authored subset and fails for unsupported paints,
nonuniform scaling or group opacity. Translation, rotation, uniform scaling,
SVG transform order and scaled stroke widths are preserved. Arc conversion follows the
[SVG endpoint conversion rules](https://www.w3.org/TR/SVG/implnote.html#ArcImplementationNotes).
Do not manually approximate arc curves or replace foreground half-rings with
full ellipses. Recheck the generated native gallery against the SVG browser
preview after any source change. The existing Mac renderer is a separate consumer.

`subagents/` contains seven generated SVG family marks, each combining three
copies of the corresponding original in a compact cluster. The iOS helper pill
and roster use the same placement and parent palette through static cached
geometry. These marks are decorative: the adjoining text supplies the actual
agent count and lifecycle state. `generate-ios.py` regenerates both native
geometry and these portable SVGs; `--check` verifies both. Edit the original
characters or the generator's shared placements, not the derived group files.

## Motion

The top-level SVGs remain static originals. `animated/` contains standalone
SVGs with embedded CSS keyframes and the same color variables. They have no
embedded scripts or external dependencies. The preview supplies pointer
tracking; a standalone SVG uses a neutral gaze unless its host provides one.

- **Idle:** quiet breathing, staggered blinking, and each character's own motion.
- **Thinking:** a slight head tilt and upward gaze.
- **Working:** faster movement of rays, rings, tail, facets, or orbits.
- **Done:** one 800 ms completion bounce. **Celebrate** replays it.
- **Sleeping:** closed eyes and slow breathing; decorative motion rests.

Sun's rays pulse; Orbit's rings tilt; Nova gently expands; Comet's tail flutters;
Prism's highlight changes; Atom's orbits turn; Luna rocks and opens her eyes in
active states. Geometry remains the approved vector family.

Set `data-state` on an animated SVG to `idle`, `thinking`, `working`, `done`, or
`sleeping`. Set `data-motion="off"` for still output, or `data-paused="true"` to
freeze an animation at its current position. All animated SVGs honor
`prefers-reduced-motion: reduce` by keeping their state visible without movement.
An inline host can set `--avatar-look-x` and `--avatar-look-y` in SVG coordinate
pixels for gaze. The preview bounds these offsets to 4 and 3 pixels respectively.

The preview pauses offscreen/hidden avatars with IntersectionObserver and
document visibility, and schedules at most one gaze update per animation frame
while the pointer moves. Small comparison samples remain static. These host
behaviors must also be preserved during app integration; a standalone image
does not supply a host's visibility policy.

**Export → Animated SVG** includes the selected activity and motion setting.
**Still SVG** uses the original geometry. Both resolve the color variables;
animated exports retain the CSS needed for motion. CSS animation support is
required for playback; a static-only SVG renderer shows the default pose.

## Editing

Edit the individual SVGs or `motion.css`, then run `python3 build-animated.py`
followed by `python3 refresh-preview.py`. Edit `palettes.json` to change the
curated set or character defaults, then run `python3 refresh-preview.py`.
The preview remembers its selected palette ID and other controls locally.
Selecting a color applies it to the whole set; **Character colors** restores
the per-character defaults. Previously saved custom colors fall back to these
defaults. Exports use the concrete preset ID in their filenames.

No raster images, embedded scripts, external resources, filters, masks, or
font dependencies are present in the SVG originals.

## Verification

All seven originals passed XML and SVG path-token checks. Browser previews
were inspected at 1440px desktop and 390px mobile widths. Palette, size, and
theme controls were checked, including persistence after reload. The fixed
palette update validates exactly 12 entries and their hex values, and the
preview has no custom color inputs. Cocoa was checked across all seven
characters and exported with the expected literal colors and animation CSS.

Chrome's **Save SVG** produced `sun-ocean.svg`, verified as valid XML with the
requested literal colors. The in-app browser's Blob download neither saved a
file nor emitted a download event; use Chrome for the verified save workflow.
SwiftUI rendering and selection were exercised with deterministic iPhone and
iPad Simulator fixtures. The GPUI renderer is covered by native layer/catalog
tests and local builds; its unbundled chat window was not addressable by the Mac
UI harness for screenshot verification.

Animation checks covered state selection, bounded pointer gaze, motion-off,
sleeping eyes, finite celebration/replay, offscreen pausing, and standalone
SVG playback. Chrome exports were checked for a working Ocean Sun with embedded
animation CSS and a still Mint Sun without animation CSS. The mobile preview
was checked at 390px, including 32px avatars. Device Reduce Motion and hidden-tab
handling were reviewed in source; system preferences were not changed for this
check. Native Reduce Motion, visibility, and lifecycle behavior are verified
separately by the app tests; physical-device animation performance remains an
explicit acceptance item.
