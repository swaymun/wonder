#!/usr/bin/env python3
r"""Create a verified, signed single-release appcast; never upload or publish it.

Requires an already Developer ID signed, stapled/notarized Wonder DMG and the
existing wonder-public-beta Keychain account. No private key is exported.
Example (the output must not exist):
  python3 scripts/generate-sparkle-appcast.py --dmg dist/Wonder-1.0.51.dmg \
    --version 1.0.51 --asset-url \
    https://github.com/swaymun/wonder/releases/download/mac-v1.0.51-beta.1/Wonder-1.0.51.dmg \
    --output .local/appcast.xml

The URL is a planned, versioned release asset; this tool does not certify its
remote availability or the installed update lifecycle. Both prerelease and
stable tags are supported. Publish only after uploading those exact DMG bytes.
CLI options follow Sparkle 2.9.6's bundled --help and official documentation:
https://sparkle-project.org/documentation/publishing/
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE_BIN = ROOT / "apps/menubar/.build/artifacts/sparkle/Sparkle/bin"
ACCOUNT = "wonder-public-beta"
PUBLIC_KEY = "1FthPKpyNACzwe42UV0sGT2ql9zhQE+i40wC/pi65Yw="
FEED_URL = "https://wonder-launch-preview.saimun-h-shahee.chatgpt.site/updates/appcast.xml"
REPOSITORY = "swaymun/wonder"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def run(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True,
                            text=True, timeout=600)
    if result.returncode:
        raise ValueError(f"{Path(args[0]).name} failed: {(result.stderr + result.stdout)[-4000:]}")
    return result.stdout.strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_inputs(dmg, version, asset_url, output):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        raise ValueError("Version must be the numeric CFBundleVersion from the signed app.")
    if dmg.is_symlink() or not dmg.is_file() or dmg.name != f"Wonder-{version}.dmg":
        raise ValueError("Expected a regular file named Wonder-VERSION.dmg.")
    # Deliberately canonical: no redirects through latest/download, query strings,
    # credentials, percent escapes, traversal, alternate host or repository.
    tag = rf"(?:mac-)?v?{re.escape(version)}(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?"
    if not re.fullmatch(rf"https://github\.com/{re.escape(REPOSITORY)}/releases/download/{tag}/{re.escape(dmg.name)}", asset_url):
        raise ValueError("Asset URL must use the pinned GitHub repository, matching version tag and exact DMG filename.")
    if output.suffix != ".xml" or not output.parent.is_dir():
        raise ValueError("Output must be an .xml file in an existing directory.")
    if os.path.lexists(output):
        raise ValueError("Refusing to overwrite an existing appcast or symlink.")


def read_verified_app_info(dmg, version, mount):
    # Reuse the repository's codesign, stapler, Gatekeeper, DMG integrity and
    # bundled-artifact gates. This mounts read-only and does not install the app.
    run(ROOT / "scripts/verify-macos-dmg.sh", dmg, version)
    mount.mkdir()
    run("hdiutil", "attach", dmg, "-readonly", "-nobrowse", "-mountpoint", mount)
    try:
        info = plistlib.loads((mount / "Wonder.app/Contents/Info.plist").read_bytes())
    finally:
        run("hdiutil", "detach", mount)
    expected = {"CFBundleIdentifier": "com.saimun.wonder", "CFBundleVersion": version,
                "SUFeedURL": FEED_URL, "SUPublicEDKey": PUBLIC_KEY}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Signed app {key} does not match the expected update configuration.")
    if info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise ValueError("Signed app must verify updates before extraction.")
    if info.get("SURequireSignedFeed") is not True:
        raise ValueError("Signed app must require a signed update feed.")
    for key in ("CFBundleShortVersionString", "LSMinimumSystemVersion"):
        if not isinstance(info.get(key), str) or not info[key].strip():
            raise ValueError(f"Signed app is missing {key}.")
    return info


def validate_appcast(path, info, asset_url, length):
    root = ET.parse(path).getroot()
    items = root.findall("./channel/item")
    if (root.tag != "rss" or len(root.findall("channel")) != 1 or len(items) != 1
            or len(root.findall(".//enclosure")) != 1):
        raise ValueError("Expected exactly one release item and one full-update enclosure.")
    item = items[0]
    for key, expected in (("version", info["CFBundleVersion"]),
                          ("shortVersionString", info["CFBundleShortVersionString"]),
                          ("minimumSystemVersion", info["LSMinimumSystemVersion"])):
        nodes = item.findall(f"{{{SPARKLE_NS}}}{key}")
        if len(nodes) != 1 or nodes[0].text != expected:
            raise ValueError(f"Appcast {key} does not match the signed app.")
    # Wonder uses the default feed channel; a named channel would hide updates
    # from existing clients unless the app explicitly opted into that channel.
    if item.find(f"{{{SPARKLE_NS}}}channel") is not None:
        raise ValueError("Unexpected named update channel.")
    enclosure = item.find("enclosure")
    if (enclosure is None or enclosure.get("url") != asset_url
            or enclosure.get("length") != str(length)
            or enclosure.get("type") != "application/octet-stream"):
        raise ValueError("Appcast enclosure URL, length or type does not match the DMG.")
    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature", "")
    try:
        valid_signature = len(base64.b64decode(signature, validate=True)) == 64
    except ValueError:
        valid_signature = False
    if not valid_signature:
        raise ValueError("Appcast is missing a valid EdDSA signature encoding.")
    return signature


def generate(dmg, version, asset_url, output, tools=SPARKLE_BIN):
    dmg, output, tools = Path(dmg).absolute(), Path(output).absolute(), Path(tools).absolute()
    validate_inputs(dmg, version, asset_url, output)
    for tool in ("generate_keys", "generate_appcast", "sign_update"):
        if not os.access(tools / tool, os.X_OK):
            raise ValueError(f"Missing executable Sparkle tool: {tool}")
    # -p is lookup-only: missing keys fail without creating/importing/exporting one.
    if run(tools / "generate_keys", "--account", ACCOUNT, "-p") != PUBLIC_KEY:
        raise ValueError("The signing account's public key does not match the pinned public key.")
    with tempfile.TemporaryDirectory(prefix=".wonder-appcast-", dir=output.parent) as temporary:
        work = Path(temporary)
        archives = work / "archives"
        archives.mkdir()
        archive = archives / dmg.name
        shutil.copyfile(dmg, archive)
        digest = sha256(archive)
        length = archive.stat().st_size
        info = read_verified_app_info(archive, version, work / "mount")
        feed = work / "appcast.xml"
        run(tools / "generate_appcast", "--account", ACCOUNT,
            "--download-url-prefix", asset_url.rsplit("/", 1)[0] + "/",
            "--versions", version, "--maximum-versions", "1", "--maximum-deltas", "0",
            "-o", feed, archives)
        signature = validate_appcast(feed, info, asset_url, length)
        run(tools / "sign_update", "--account", ACCOUNT, "--verify", archive, signature)
        # Also sign the feed itself; this remains compatible with clients that
        # currently require only the archive signature. Never edit it afterward.
        run(tools / "sign_update", "--account", ACCOUNT, "-p", feed)
        run(tools / "sign_update", "--account", ACCOUNT, "--verify", feed)
        validate_appcast(feed, info, asset_url, length)
        if sha256(archive) != digest or sha256(dmg) != digest:
            raise ValueError("DMG bytes changed during generation; no appcast was written.")
        # Both paths are on the same filesystem; link is atomic and cannot replace
        # an output created by another process after our initial existence check.
        os.link(feed, output)
    return {"appcast": str(output), "feedURL": FEED_URL, "version": version,
            "shortVersion": info["CFBundleShortVersionString"], "assetURL": asset_url,
            "length": length, "sha256": digest, "publicKey": PUBLIC_KEY,
            "published": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--asset-url", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sparkle-bin", type=Path, default=SPARKLE_BIN,
                        help="Directory containing the official Sparkle 2.9.6 tools.")
    args = parser.parse_args()
    try:
        result = generate(args.dmg, args.version, args.asset_url, args.output, args.sparkle_bin)
    except (OSError, ValueError, ET.ParseError, plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
        print(f"Appcast generation failed: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
