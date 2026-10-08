#!/usr/bin/env bash
# Local archive only. Optional trailing xcodebuild authentication arguments may allow provisioning; never uploads or installs.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:?usage: archive-ios-release.sh BUILD OUTPUT_DIRECTORY}"
OUT="${2:?output directory required}"
shift 2
PROFILE="${WONDER_IOS_PROFILE:-release}"
case "$PROFILE" in
  release) CONFIGURATION=Release; SCHEME=Wonder ;;
  diagnostics) CONFIGURATION=Diagnostics; SCHEME=Diagnostics ;;
  *) echo 'Profile must be release or diagnostics' >&2; exit 2 ;;
esac
CHANNEL="${WONDER_IOS_CHANNEL:-testing}"
case "$CHANNEL" in
  production) BUNDLE_ID=com.swaymun.wonder ;;
  testing)
    BUNDLE_ID=com.swaymun.wonder.testing
    SCHEME=WonderTesting
    if [[ "$PROFILE" == diagnostics ]]; then CONFIGURATION=TestingDiagnostics; else CONFIGURATION=Testing; fi
    ;;
  *) echo 'Channel must be testing or production' >&2; exit 2 ;;
esac
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo 'Use a positive integer build number' >&2; exit 2; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
for artifact in Wonder.xcarchive archive.log source-commit.txt source-status.txt build.json; do
  [[ ! -e "$OUT/$artifact" && ! -L "$OUT/$artifact" ]] || { echo 'Use a new output directory; preserve prior evidence' >&2; exit 2; }
done
cd "$ROOT_DIR"
# wonder-remote --ref copies have no .git; they are exactly the named commit
# and pass its identity, so there is no working-tree status, diff or new file.
if [[ -n "${WONDER_SOURCE_COMMIT:-}" ]] && ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "$WONDER_SOURCE_COMMIT" > "$OUT/source-commit.txt"
  : > "$OUT/source-status.txt"
else
  git rev-parse HEAD > "$OUT/source-commit.txt"
  git status --porcelain > "$OUT/source-status.txt"
  git diff --binary HEAD > "$OUT/source-diff.patch"
  python3 - "$OUT" <<'PY'
import subprocess, sys, tarfile
from pathlib import Path
paths = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z']).split(b'\0')
with tarfile.open(Path(sys.argv[1]) / 'source-new-files.tar.gz', 'w:gz') as archive:
    for raw in paths:
        if raw:
            path = Path(raw.decode())
            if path.is_file(): archive.add(path, arcname=str(path), recursive=False)
PY
fi
if ! xcodebuild -project apps/ios/Wonder.xcodeproj -scheme "$SCHEME" WONDER_APNS_ENVIRONMENT=production \
  -configuration "$CONFIGURATION" -destination 'generic/platform=iOS' \
  -archivePath "$OUT/Wonder.xcarchive" -derivedDataPath "$OUT/DerivedData" \
  CURRENT_PROJECT_VERSION="$BUILD" "$@" archive > "$OUT/archive.log" 2>&1; then
  echo "Archive failed; inspect $OUT/archive.log" >&2
  exit 1
fi
APP="$OUT/Wonder.xcarchive/Products/Applications/Wonder.app"
codesign --verify --deep --strict "$APP"
WEBRTC_LICENSE="$APP/WebRTC-LICENSE.md"
WEBRTC_LICENSE_SHA256="843529896bae499c92af3ecade86855128f930334ba97530695ccecef56e966d"
[[ -f "$WEBRTC_LICENSE" ]] || {
  echo 'Archive is missing WebRTC-LICENSE.md' >&2
  exit 1
}
[[ "$(shasum -a 256 "$WEBRTC_LICENSE" | awk '{print $1}')" == "$WEBRTC_LICENSE_SHA256" ]] || {
  echo 'Archive WebRTC-LICENSE.md does not match the reviewed WebRTC license' >&2
  exit 1
}
EPUB_LICENSE="$APP/EPUB-LICENSES.md"
[[ -s "$EPUB_LICENSE" ]] && cmp -s apps/ios/Wonder/EPUB-LICENSES.md "$EPUB_LICENSE" || {
  echo 'Archive is missing the reviewed EPUB dependency notices' >&2
  exit 1
}
if find "$APP/Frameworks" -maxdepth 1 -type d -name '*.framework' -print -quit 2>/dev/null | grep -q .; then
  [[ "$(otool -l "$APP/Wonder")" == *"path @executable_path/Frameworks "* ]] || {
    echo 'Archive embeds dynamic frameworks but Wonder is missing @executable_path/Frameworks from LC_RPATH' >&2
    exit 1
  }
fi
xcrun dwarfdump --uuid "$OUT/Wonder.xcarchive/dSYMs/Wonder.app.dSYM" > "$OUT/symbol-uuids.txt"
python3 - "$APP/Info.plist" "$BUILD" "$OUT/build.json" "$PROFILE" "$OUT" "$BUNDLE_ID" "$CHANNEL" <<'PY'
import json, plistlib, subprocess, sys
from pathlib import Path
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
if info.get('CFBundleIdentifier') != sys.argv[6] or info.get('CFBundleVersion') != sys.argv[2]:
    raise SystemExit('Archive identity/build does not match the requested Release build')
app = Path(sys.argv[1]).parent
def entitlements(bundle):
    signed = subprocess.check_output(
        ['codesign', '-d', '--entitlements', ':-', str(bundle)], stderr=subprocess.DEVNULL)
    return plistlib.loads(signed)
group = 'group.' + info['CFBundleIdentifier']
main = entitlements(app)
if (main.get('application-identifier') != '8KKNVD7758.' + info['CFBundleIdentifier']
    or main.get('com.apple.developer.team-identifier') != '8KKNVD7758'
    or main.get('aps-environment') != 'production'
    or main.get('get-task-allow') is not False
    or main.get('com.apple.security.application-groups') != [group]
    or main.get('keychain-access-groups') != [
        '8KKNVD7758.' + info['CFBundleIdentifier'],
        '8KKNVD7758.' + info['CFBundleIdentifier'] + '.push']):
    raise SystemExit('Archive main-app signing, push or channel isolation is invalid')
for bundle, suffix, extension_point in [
    ('WonderNotificationService', '.NotificationService', 'com.apple.usernotifications.service'),
    ('WonderShare', '.Share', 'com.apple.share-services'),
    ('WonderWidget', '.Widget', 'com.apple.widgetkit-extension'),
]:
    extension_info = plistlib.loads((Path(sys.argv[1]).parent / f'PlugIns/{bundle}.appex/Info.plist').read_bytes())
    if (not extension_info.get('CFBundleDisplayName')
        or extension_info.get('CFBundleIdentifier') != info['CFBundleIdentifier'] + suffix
        or extension_info.get('CFBundleVersion') != info['CFBundleVersion']
        or extension_info.get('CFBundleShortVersionString') != info['CFBundleShortVersionString']
        or extension_info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != extension_point):
        raise SystemExit(f'{bundle} display name, identity, version or extension point is invalid')
widget = entitlements(app / 'PlugIns/WonderWidget.appex')
if (widget.get('application-identifier') != '8KKNVD7758.' + info['CFBundleIdentifier'] + '.Widget'
    or widget.get('com.apple.developer.team-identifier') != '8KKNVD7758'
    or widget.get('get-task-allow') is not False
    or widget.get('com.apple.security.application-groups') != [group]):
    raise SystemExit('Archive Widget signing or App Group is invalid')
if info.get('ITSAppUsesNonExemptEncryption') is not False:
    raise SystemExit('Archive must declare its encryption exemption; review encryption use before changing this check')
Path(sys.argv[3]).write_text(json.dumps({
    'profile': sys.argv[4],
    'channel': sys.argv[7],
    'sourceCommit': (Path(sys.argv[5]) / 'source-commit.txt').read_text().strip(),
    'sourceDirty': bool((Path(sys.argv[5]) / 'source-status.txt').read_text().strip()),
    'symbolUUIDs': (Path(sys.argv[5]) / 'symbol-uuids.txt').read_text().strip(),
    'bundleIdentifier': info['CFBundleIdentifier'],
    'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
    'archiveSignatureVerified': True, 'testFlightReady': False,
}, indent=2) + '\n')
PY
echo "Signed archive prepared in $OUT. Distribution export and TestFlight acceptance remain separate."
# The signed archive is self-contained; do not retain a compiler cache per upload.
if ! python3 "$ROOT_DIR/scripts/clean-build-artifacts.py" --xcode-directory "$OUT/DerivedData" --apply > "$OUT/cache-cleanup.log" 2>&1; then
  echo "Compiler cache cleanup deferred; inspect $OUT/cache-cleanup.log" >&2
fi
