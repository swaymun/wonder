#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/Wonder.app}"
CONTENTS_PATH="$APP_PATH/Contents"

test ! -e "$CONTENTS_PATH/MacOS/WonderDesktop" || { echo "Chats client must not be bundled" >&2; exit 1; }

required_files=(
  "$CONTENTS_PATH/Resources/WonderService.sh"
  "$CONTENTS_PATH/Info.plist"
  "$CONTENTS_PATH/Frameworks/Sparkle.framework/Sparkle"
  "$CONTENTS_PATH/Frameworks/WebRTC.framework/WebRTC"
  "$CONTENTS_PATH/Resources/WebRTC-LICENSE.md"
  "$CONTENTS_PATH/Resources/LICENSE"
  "$CONTENTS_PATH/Resources/THIRD_PARTY_NOTICES.md"
  "$CONTENTS_PATH/Resources/Licenses/RUST-NOTICES.txt"
  "$CONTENTS_PATH/Resources/Licenses/rust-dependencies.json"
  "$CONTENTS_PATH/Resources/Licenses/Rust-COPYRIGHT.html.gz"
  "$CONTENTS_PATH/Resources/Licenses/Go-LICENSE.txt"
  "$CONTENTS_PATH/Resources/Licenses/Sparkle-LICENSE.txt"
  "$CONTENTS_PATH/Resources/manage-runtime.sh"
  "$CONTENTS_PATH/Resources/Wonder.icns"
  "$CONTENTS_PATH/Resources/WonderMenuIcon.pdf"
  "$CONTENTS_PATH/MacOS/WonderHost"
  "$CONTENTS_PATH/MacOS/WonderMacBridge"
  "$CONTENTS_PATH/Resources/wonderd"
  "$CONTENTS_PATH/Resources/WonderComputerUse.app/Contents/Info.plist"
  "$CONTENTS_PATH/Resources/WonderComputerUse.app/Contents/MacOS/WonderComputerUse"
  "$CONTENTS_PATH/Resources/wonder-tunnel"
  "$CONTENTS_PATH/MacOS/WonderMenu"
)

test ! -e "$CONTENTS_PATH/MacOS/WonderMenuUI" || { echo "obsolete SwiftUI helper is present" >&2; exit 1; }
test ! -e "$CONTENTS_PATH/Resources/WonderComputerUse" || { echo "legacy flat computer helper is present" >&2; exit 1; }
[[ "$(otool -L "$CONTENTS_PATH/MacOS/WonderMacBridge")" != *"/SwiftUI.framework/"* ]] || { echo "Mac bridge must not link SwiftUI" >&2; exit 1; }
COMPUTER_USE_BIN="$CONTENTS_PATH/Resources/WonderComputerUse.app/Contents/MacOS/WonderComputerUse"
COMPUTER_USE_PLIST="$CONTENTS_PATH/Resources/WonderComputerUse.app/Contents/Info.plist"
[[ "$(otool -L "$COMPUTER_USE_BIN")" == *"@rpath/WebRTC.framework/WebRTC"* ]] || { echo "computer helper must link the bundled WebRTC framework" >&2; exit 1; }
[[ "$(otool -l "$COMPUTER_USE_BIN")" == *"@loader_path/../../../../Frameworks"* ]] || { echo "computer helper is missing its outer-app WebRTC rpath" >&2; exit 1; }

test ! -e "$CONTENTS_PATH/Resources/pwa" || { echo "obsolete PWA bundle is present" >&2; exit 1; }

for path in "${required_files[@]}"; do
  test -e "$path" || { echo "missing package artifact: $path" >&2; exit 1; }
done

test ! -d "$CONTENTS_PATH/Resources/WebRTC-M153-dSYM" || { echo "WebRTC dSYM must not be shipped" >&2; exit 1; }
test ! -e "$CONTENTS_PATH/Resources/WebRTC-M153-dSYM.zip" || { echo "WebRTC dSYM archive must not be shipped" >&2; exit 1; }

for path in \
  "$CONTENTS_PATH/MacOS/WonderHost" \
  "$CONTENTS_PATH/MacOS/WonderMacBridge" \
  "$CONTENTS_PATH/Resources/wonderd" \
  "$COMPUTER_USE_BIN" \
  "$CONTENTS_PATH/Resources/wonder-tunnel" \
  "$CONTENTS_PATH/MacOS/WonderMenu"; do
  test -x "$path" || { echo "package artifact is not executable: $path" >&2; exit 1; }
done

codesign --verify --strict "$CONTENTS_PATH/Frameworks/WebRTC.framework"
codesign --verify --deep --strict "$CONTENTS_PATH/Frameworks/Sparkle.framework"
codesign --verify --strict "$CONTENTS_PATH/Resources/WonderComputerUse.app"
codesign --verify --strict "$COMPUTER_USE_BIN"
[[ "$(shasum -a 256 "$CONTENTS_PATH/Resources/WebRTC-LICENSE.md" | awk '{print $1}')" == "843529896bae499c92af3ecade86855128f930334ba97530695ccecef56e966d" ]] || { echo "WebRTC license evidence mismatch" >&2; exit 1; }

/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS_PATH/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$CONTENTS_PATH/Info.plist" >/dev/null
python3 - "$CONTENTS_PATH/Info.plist" <<'VERIFY_UPDATER'
import base64, plistlib, sys
from urllib.parse import urlsplit
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
feed = urlsplit(info.get('SUFeedURL', ''))
assert feed.scheme == 'https' and feed.hostname and not feed.username and not feed.password
assert not feed.query and not feed.fragment
assert len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) == 32
assert info.get('SUVerifyUpdateBeforeExtraction') is True
assert info.get('SURequireSignedFeed') is True
assert info.get('SUSendProfileInfo') is False
assert 'SUEnableAutomaticChecks' not in info, 'Preserve the user consent and opt-out flow'
VERIFY_UPDATER

helper_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$COMPUTER_USE_PLIST" 2>/dev/null || true
}
[[ "$(helper_value CFBundleIdentifier)" == "com.saimun.wonder.computer-use" ]] || { echo "unexpected computer helper bundle identifier" >&2; exit 1; }
[[ "$(helper_value CFBundleExecutable)" == "WonderComputerUse" ]] || { echo "unexpected computer helper executable" >&2; exit 1; }
[[ "$(helper_value LSUIElement)" == "true" ]] || { echo "computer helper must be an LSUIElement app" >&2; exit 1; }

verify_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$CONTENTS_PATH/Info.plist" 2>/dev/null || true)"
  [[ -n "$actual" && "$actual" == "$expected" ]] || {
    echo "unexpected or missing $key in package Info.plist" >&2
    exit 1
  }
}

verify_plist_value \
  "NSLocalNetworkUsageDescription" \
  "Wonder connects directly to devices you pair with this Mac for secure live screen viewing."
verify_plist_value \
  "NSScreenCaptureUsageDescription" \
  "Wonder shares this Mac’s screen with a device you paired, only while Computer View is open."

echo "package artifacts verified: $APP_PATH"
