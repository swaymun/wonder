#!/usr/bin/env python3
"""Validate the authored science-avatar source contract at build time.

This is intentionally a build-time tool. Native clients consume catalog
identifiers and generated/hand-authored geometry; they never parse these files
at runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SOURCE_VERSION = "science-avatar-v1"
SHAPES = ("sun", "orbit", "nova", "comet", "prism", "atom", "luna")
PALETTE_FIELDS = ("name", "body", "shadow", "accent", "ink")
HEX = re.compile(r"^#[0-9a-fA-F]{6}$")
PATH_CHARS = re.compile(r"^[MmZzLlHhVvCcSsQqTtAa0-9eE+.,\s-]+$")
PATH_TOKEN = re.compile(r"[MmZzLlHhVvCcSsQqTtAa]|[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?")

ALLOWED_TAGS = {"svg", "title", "g", "path", "circle", "ellipse", "rect"}
ALLOWED_ATTRIBUTES = {
    "svg": {"viewBox", "role", "aria-label"},
    "title": set(),
    "g": {"data-part", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "opacity", "transform"},
    "path": {"data-part", "d", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "opacity", "transform"},
    "circle": {"data-part", "cx", "cy", "r", "fill", "stroke", "stroke-width", "opacity"},
    "ellipse": {"data-part", "cx", "cy", "rx", "ry", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "opacity", "transform"},
    "rect": {"data-part", "x", "y", "width", "height", "rx", "ry", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "opacity"},
}


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def fail(message: str) -> None:
    raise ValueError(message)


def validate_paint(value: str, path: str) -> None:
    if value == "none":
        return
    if not re.fullmatch(r"var\(--avatar-(body|shadow|accent|ink), #[0-9a-fA-F]{6}\)", value):
        fail(f"{path}: unsupported paint {value!r}; use an avatar CSS variable or none")


def validate_path(value: str, path: str) -> None:
    if not PATH_CHARS.fullmatch(value):
        fail(f"{path}: unsupported SVG path token")
    compact = re.sub(r"[\s,]+", "", value)
    if "".join(PATH_TOKEN.findall(value)) != compact:
        fail(f"{path}: malformed SVG path token")


def validate_svg(path: Path) -> None:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as error:
        fail(f"{path.name}: invalid XML: {error}")
    if local_name(root.tag) != "svg":
        fail(f"{path.name}: root must be svg")
    title = None

    def walk(element: ET.Element, location: str) -> None:
        nonlocal title
        tag = local_name(element.tag)
        if tag not in ALLOWED_TAGS:
            fail(f"{path.name}{location}: unsupported authored SVG element <{tag}>")
        attrs = set(element.attrib)
        unknown = attrs - ALLOWED_ATTRIBUTES[tag]
        if unknown:
            fail(f"{path.name}{location}: unsupported SVG attributes {sorted(unknown)}")
        if tag == "title":
            title = (element.text or "").strip()
        if tag == "path":
            if not element.attrib.get("d"):
                fail(f"{path.name}{location}: path needs d")
            validate_path(element.attrib["d"], f"{path.name}{location}")
        for paint in ("fill", "stroke"):
            if paint in element.attrib:
                validate_paint(element.attrib[paint], f"{path.name}{location}@{paint}")
        for child_index, child in enumerate(element):
            walk(child, f"{location}/{local_name(child.tag)}[{child_index}]")

    walk(root, "")
    if root.attrib != {"viewBox": "0 0 256 256", "role": "img", "aria-label": title}:
        fail(f"{path.name}: root must have viewBox, role, and matching aria-label")
    if not title:
        fail(f"{path.name}: title is required")
    if sum(local_name(node.tag) == "title" for node in root.iter()) != 1:
        fail(f"{path.name}: exactly one title is required")


def source_hash(root: Path) -> str:
    digest = hashlib.sha256()
    for relative in (Path("palettes.json"), *(Path(f"{shape}.svg") for shape in SHAPES)):
        data = (root / relative).read_bytes()
        digest.update(str(relative).encode("utf-8"))
        digest.update(b"\0")
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def validate(root: Path) -> dict[str, object]:
    palette_data = json.loads((root / "palettes.json").read_text(encoding="utf-8"))
    colors = palette_data.get("colors")
    defaults = palette_data.get("defaults")
    if not isinstance(colors, dict) or len(colors) != 12:
        fail("palettes.json must contain exactly 12 colors")
    if set(colors) != {"amber", "coral", "rose", "violet", "indigo", "ocean", "sky", "teal", "mint", "olive", "cocoa", "slate"}:
        fail("palettes.json contains an unsupported palette identifier")
    for palette_id, palette in colors.items():
        if set(palette) != set(PALETTE_FIELDS):
            fail(f"palette {palette_id}: fields must be {PALETTE_FIELDS}")
        if any(not isinstance(palette[field], str) for field in PALETTE_FIELDS):
            fail(f"palette {palette_id}: fields must be strings")
        if any(not HEX.fullmatch(palette[field]) for field in PALETTE_FIELDS[1:]):
            fail(f"palette {palette_id}: colors must be six-digit hex values")
    if not isinstance(defaults, dict) or set(defaults) != set(SHAPES) or any(value not in colors for value in defaults.values()):
        fail("palettes.json defaults must cover all seven shapes")

    authored = sorted(path.stem for path in root.glob("*.svg"))
    if tuple(authored) != tuple(sorted(SHAPES)):
        fail(f"root SVGs must be exactly {SHAPES}; found {tuple(authored)}")
    for shape in SHAPES:
        validate_svg(root / f"{shape}.svg")

    return {
        "sourceVersion": SOURCE_VERSION,
        "sourceHash": source_hash(root),
        "shapes": list(SHAPES),
        "palettes": list(colors),
        "defaultShape": "sun",
        "defaultPalette": "amber",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-manifest", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    try:
        manifest = validate(root)
        manifest_path = root / "catalog-manifest.json"
        if args.write_manifest:
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        elif manifest_path.exists():
            checked_in = json.loads(manifest_path.read_text(encoding="utf-8"))
            if checked_in != manifest:
                fail("catalog-manifest.json is stale; rerun with --write-manifest")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"science avatar validation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(manifest, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
