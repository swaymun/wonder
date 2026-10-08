#!/bin/bash
# Install a notarized Wonder DMG into /Applications with install-signed-app.py.
#   scripts/install-mac-dmg.sh .local/release/mac-1.0.126/Wonder-1.0.126.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
dmg=${1:?usage: scripts/install-mac-dmg.sh WONDER_DMG}
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature "$dmg"
mount=$(mktemp -d)
# The installer may finish in a detached worker, so the staged app must stay put.
stage=".local/release/install-stage/$(basename "$dmg" .dmg)"
rm -rf "$stage" && mkdir -p "$stage"
trap 'hdiutil detach -quiet "$mount" 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true' EXIT
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
ditto "$mount/Wonder.app" "$stage/Wonder.app"
hdiutil detach -quiet "$mount"
codesign --verify --deep --strict "$stage/Wonder.app"
python3 scripts/install-signed-app.py "$stage/Wonder.app" /Applications
