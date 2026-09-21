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
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo 'Use a positive integer build number' >&2; exit 2; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
for artifact in Wonder.xcarchive archive.log source-commit.txt source-status.txt build.json; do
  [[ ! -e "$OUT/$artifact" && ! -L "$OUT/$artifact" ]] || { echo 'Use a new output directory; preserve prior evidence' >&2; exit 2; }
done
cd "$ROOT_DIR"
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
if find "$APP/Frameworks" -maxdepth 1 -type d -name '*.framework' -print -quit 2>/dev/null | grep -q .; then
  [[ "$(otool -l "$APP/Wonder")" == *"path @executable_path/Frameworks "* ]] || {
    echo 'Archive embeds dynamic frameworks but Wonder is missing @executable_path/Frameworks from LC_RPATH' >&2
    exit 1
  }
fi
xcrun dwarfdump --uuid "$OUT/Wonder.xcarchive/dSYMs/Wonder.app.dSYM" > "$OUT/symbol-uuids.txt"
python3 - "$APP/Info.plist" "$BUILD" "$OUT/build.json" "$PROFILE" "$OUT" <<'PY'
import json, plistlib, sys
from pathlib import Path
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
if info.get('CFBundleIdentifier') != 'com.swaymun.wonder' or info.get('CFBundleVersion') != sys.argv[2]:
    raise SystemExit('Archive identity/build does not match the requested Release build')
extension_info_path = Path(sys.argv[1]).parent / 'PlugIns/WonderNotificationService.appex/Info.plist'
extension_info = plistlib.loads(extension_info_path.read_bytes())
if (not extension_info.get('CFBundleDisplayName')
    or extension_info.get('CFBundleIdentifier') != info['CFBundleIdentifier'] + '.NotificationService'
    or extension_info.get('CFBundleVersion') != info['CFBundleVersion']
    or extension_info.get('CFBundleShortVersionString') != info['CFBundleShortVersionString']):
    raise SystemExit('Notification extension display name, identity or version is invalid')
if info.get('ITSAppUsesNonExemptEncryption') is not False:
    raise SystemExit('Archive must declare its encryption exemption; review encryption use before changing this check')
Path(sys.argv[3]).write_text(json.dumps({
    'profile': sys.argv[4],
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
