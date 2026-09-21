#!/usr/bin/env python3
"""Embed the SVG originals so preview.html also works offline as a local file."""
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
palettes = json.loads((root / "palettes.json").read_text())
if len(palettes["colors"]) != 12:
    raise SystemExit("Expected twelve fixed avatar palettes")
for color in palettes["colors"].values():
    if not all(re.fullmatch(r"#[0-9a-fA-F]{6}", color[role]) for role in ("body", "shadow", "accent", "ink")):
        raise SystemExit("Every palette must define four hex colors")
avatars = []
for name in ("sun", "orbit", "nova", "comet", "prism", "atom", "luna"):
    source = (root / f"{name}.svg").read_text()
    ET.fromstring(source)
    animated = (root / "animated" / f"{name}.svg").read_text()
    ET.fromstring(animated)
    default_palette = palettes["defaults"][name]
    if default_palette not in palettes["colors"]:
        raise SystemExit(f"Unknown default palette for {name}")
    avatars.append({"id": name, "name": name.title(), "svg": source, "animated": animated, "defaultPalette": default_palette})

preview = root / "preview.html"
updated = preview.read_text()
for script_id, value in (("avatar-data", avatars), ("palette-data", palettes["colors"])):
    marker = rf'(<script id="{script_id}" type="application/json">).*?(</script>)'
    data = json.dumps(value, ensure_ascii=False).replace("<", "\\u003c")
    updated, count = re.subn(marker, lambda m: m[1] + data + m[2], updated, flags=re.S)
    if count != 1:
        raise SystemExit(f"Expected exactly one {script_id} script in preview.html")
preview.write_text(updated)
print(f"Embedded {len(avatars)} SVGs in {preview}")
