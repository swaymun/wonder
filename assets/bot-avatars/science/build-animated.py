#!/usr/bin/env python3
"""Derive self-contained animated SVGs without changing the static originals."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", NS)


def element(tag, **attributes):
    return ET.Element(f"{{{NS}}}{tag}", attributes)


def wrap(parent, child, part):
    index = list(parent).index(child)
    parent.remove(child)
    group = element("g", **{"data-part": part})
    group.append(child)
    parent.insert(index, group)
    return group


output = ROOT / "animated"
output.mkdir(exist_ok=True)
css = (ROOT / "motion.css").read_text()
for index, name in enumerate(("sun", "orbit", "nova", "comet", "prism", "atom", "luna")):
    root = ET.fromstring((ROOT / f"{name}.svg").read_text())
    root.set("class", "wonder-avatar")
    root.set("data-avatar", name)
    root.set("data-state", "idle")
    root.set("data-motion", "on")
    root.set("style", f"--avatar-blink-delay: {-index * .71:.2f}s; --avatar-idle-delay: {-index * .83:.2f}s")
    style = element("style")
    style.text = css
    root.insert(1, style)
    character = element("g", **{"data-part": "character"})
    for child in list(root)[2:]:
        root.remove(child)
        character.append(child)
    root.append(character)
    face = next(child for child in character if child.get("data-part") == "face")
    wrap(character, face, "gaze")
    for eye in face:
        if eye.tag in (f"{{{NS}}}ellipse", f"{{{NS}}}rect"):
            eye.set("class", "avatar-eye")
    if name == "orbit":
        for child in list(character):
            if child.get("data-part") in ("ring-back", "ring-front"):
                wrap(character, child, "ring-motion")
    if name == "atom":
        electron = next(child for child in character if child.get("data-part") == "electron")
        wrap(character, electron, "electron-track")
    if name == "prism":
        body = next(child for child in character if child.get("data-part") == "body")
        next(child for child in body if child.get("data-part") == "highlight").set("data-part", "glint")
    if name == "luna":
        # Separate the original closed eyes and smile; show open eyes in active states.
        parts = re.findall(r"[Mm][^Mm]*", face[0].get("d"))
        assert len(parts) == 3, "Expected Luna's two eyes and smile"
        face[0].set("data-part", "closed-eyes")
        face[0].set("d", "".join(parts[:2]))
        face.append(element("path", d=parts[2]))
        eyes = element("g", **{"data-part": "awake-eyes", "fill": face.get("stroke"), "stroke": "none"})
        for x, y in ((77.5, 142), (109.5, 142)):
            eyes.append(element("ellipse", cx=str(x), cy=str(y), rx="5.6", ry="8.8", **{"class": "avatar-eye"}))
        face.append(eyes)
    ET.indent(root, space="  ")
    (output / f"{name}.svg").write_text(ET.tostring(root, encoding="unicode") + "\n")
print(f"Built seven animated SVGs in {output}")
