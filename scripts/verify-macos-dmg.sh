#!/usr/bin/env bash
# Artifact checks only. This does not certify a fresh install or device behavior.
set -euo pipefail
DMG="${1:?Usage: verify-macos-dmg.sh SIGNED_NOTARIZED_DMG [EXPECTED_VERSION]}"
EXPECTED="${2:-}"
[[ -f "$DMG" ]] || { echo 'DMG not found' >&2; exit 2; }
codesign --verify --strict "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
hdiutil verify "$DMG"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/wonder-dmg-check.XXXXXX")"
mounted=0
cleanup() {
  if (( mounted )); then hdiutil detach "$MOUNT" >/dev/null; fi
  rmdir "$MOUNT"
}
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null
mounted=1
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]] || { echo 'Missing Applications shortcut' >&2; exit 2; }
APP="$MOUNT/Wonder.app"
codesign --verify --deep --strict "$APP"
INFO="$(codesign -dvv "$APP" 2>&1)"
[[ "$INFO" == *'Authority=Developer ID Application:'* ]] || { echo 'Payload must use Developer ID Application signing' >&2; exit 2; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ -z "$EXPECTED" || "$VERSION" == "$EXPECTED" ]] || { echo 'Unexpected payload version' >&2; exit 2; }
"$(dirname "$0")/verify-package-artifacts.sh" "$APP"
shasum -a 256 "$DMG"
echo "DMG artifact checks passed (version $VERSION). Fresh installation, upgrade and phone acceptance remain separate."
