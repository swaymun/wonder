#!/usr/bin/env bash
# Package an already built Developer ID app. No Installer certificate is needed.
set -euo pipefail
APP="${1:?Usage: package-macos-dmg.sh SIGNED_APP OUTPUT_DMG}"
OUT="${2:?Output DMG required}"
[[ ! -e "$OUT" ]] || { echo 'Refusing to overwrite an existing distribution artifact' >&2; exit 2; }
codesign --verify --deep --strict "$APP"
SIGNING_INFO="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNING_INFO" == *'Authority=Developer ID Application:'* ]] || { echo 'Developer ID Application signing is required' >&2; exit 2; }
IDENTITY="$(printf '%s\n' "$SIGNING_INFO" | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -1)"
# macOS keeps Screen Recording and Accessibility grants only while this exact
# requirement holds: the same bundle ID and Developer ID team. Any other signing
# identity would make every user grant them again after the update.
STABLE_REQUIREMENT='identifier "com.saimun.wonder" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "8KKNVD7758"'
[[ "$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')" == "$STABLE_REQUIREMENT" ]] || { echo 'Wonder must keep its stable Developer ID requirement, or users lose privacy grants' >&2; exit 2; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wonder-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Wonder.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$(dirname "$OUT")"
hdiutil create -volname Wonder -srcfolder "$STAGE" -format UDZO "$OUT"
codesign --force --sign "$IDENTITY" --timestamp "$OUT"
codesign --verify --strict "$OUT"
hdiutil verify "$OUT"
echo "Signed DMG created: $OUT. Notarization, Gatekeeper and fresh-install acceptance are separate."
