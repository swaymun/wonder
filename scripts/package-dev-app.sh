#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/Wonder.app}"
python3 - "$APP_PATH" <<'CHECK_BUILD_PATH'
import sys
from pathlib import Path
app = Path(sys.argv[1]).resolve()
if app.name != 'Wonder.app' or any(root == app or root in app.parents for root in
        [Path('/Applications'), Path.home() / 'Applications']):
    raise SystemExit('Build Wonder.app in a staging directory, then use install-dev-app.sh.')
CHECK_BUILD_PATH
ICON_SOURCE="$ROOT_DIR/research/assets/wonder-brand/wonder-sun-logo-source.png"
ICON_WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wonder-icon.XXXXXX")"
ICONSET_PATH="$ICON_WORK_ROOT/Wonder.iconset"
trap 'rm -rf "$ICON_WORK_ROOT"' EXIT

cd "$ROOT_DIR"
# Resolve signing before spending time building; reuse this exact identity.
export WONDER_APP_SIGNING_IDENTITY="$(python3 scripts/sign-macos-app.py --check-identity)"
cargo build --release -p wonderd
cargo build --release --locked --manifest-path apps/desktop/Cargo.toml --no-default-features --bin wonder-host
swift build -c release --package-path apps/menubar
swift build -c release --package-path native/computer-use
MENUBAR_BUILD_PATH="$(swift build -c release --package-path apps/menubar --show-bin-path)"
COMPUTER_USE_BUILD_PATH="$(swift build -c release --package-path native/computer-use --show-bin-path)"
scripts/build-tunnel.sh "$ROOT_DIR/dist/wonder-tunnel"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp apps/menubar/Resources/Info.plist "$APP_PATH/Contents/Info.plist"
if [[ -n "${WONDER_BUILD_VERSION:-}" ]]; then
  [[ "$WONDER_BUILD_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] || { echo 'Build version must be numeric and monotonic' >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $WONDER_BUILD_VERSION" "$APP_PATH/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $WONDER_BUILD_VERSION" "$APP_PATH/Contents/Info.plist"
fi
mkdir -p "$ICONSET_PATH"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_PATH/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$ICON_SOURCE" --out "$ICONSET_PATH/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_PATH" -o "$APP_PATH/Contents/Resources/Wonder.icns"
mkdir -p "$APP_PATH/Contents/Frameworks"
ditto "apps/menubar/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
WEBRTC_FRAMEWORK="native/computer-use/.build/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework"
test -f "$WEBRTC_FRAMEWORK/WebRTC" || { echo 'Missing resolved macOS WebRTC framework' >&2; exit 1; }
ditto "$WEBRTC_FRAMEWORK" "$APP_PATH/Contents/Frameworks/WebRTC.framework"
cp native/computer-use/.build/checkouts/WebRTC/LICENSE.md "$APP_PATH/Contents/Resources/WebRTC-LICENSE.md"
# Sparkle uses the bundled HTTPS feed and public EdDSA key; private keys never ship.
cp apps/desktop/target/release/wonder-host "$APP_PATH/Contents/MacOS/WonderHost"
cp "$MENUBAR_BUILD_PATH/WonderMenu" "$APP_PATH/Contents/MacOS/WonderMacBridge"
xcrun swiftc -O -target "$(uname -m)-apple-macosx14.0" apps/menubar/Launcher/main.swift -o "$APP_PATH/Contents/MacOS/WonderMenu"
cp apps/menubar/WonderMenu.launcher "$APP_PATH/Contents/Resources/WonderService.sh"
cp target/release/wonderd "$APP_PATH/Contents/Resources/wonderd"
COMPUTER_USE_APP="$APP_PATH/Contents/Resources/WonderComputerUse.app"
mkdir -p "$COMPUTER_USE_APP/Contents/MacOS"
cp native/computer-use/Resources/WonderComputerUse-Info.plist "$COMPUTER_USE_APP/Contents/Info.plist"
cp "$COMPUTER_USE_BUILD_PATH/WonderComputerUse" "$COMPUTER_USE_APP/Contents/MacOS/WonderComputerUse"
cp "$ROOT_DIR/dist/wonder-tunnel" "$APP_PATH/Contents/Resources/wonder-tunnel"
cp "$ICON_SOURCE" "$APP_PATH/Contents/Resources/WonderSunLogo.png"
cp apps/menubar/Resources/WonderMenuIcon.pdf "$APP_PATH/Contents/Resources/WonderMenuIcon.pdf"
cp scripts/manage-runtime.sh "$APP_PATH/Contents/Resources/manage-runtime.sh"
python3 scripts/package-claude-runtime.py "$APP_PATH/Contents/Resources"
cp scripts/nemo-speech-worker.py "$APP_PATH/Contents/Resources/nemo-speech-worker.py"
cp scripts/install-parakeet-model.sh "$APP_PATH/Contents/Resources/install-parakeet-model.sh"
cp vendor/nemo-speech/ASR-LICENSES.md "$APP_PATH/Contents/Resources/ASR-LICENSES.md"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/"
mkdir -p "$APP_PATH/Contents/Resources/Licenses"
cp licenses/RUST-NOTICES.txt licenses/rust-dependencies.json licenses/Rust-COPYRIGHT.html.gz licenses/Go-LICENSE.txt licenses/Sparkle-LICENSE.txt "$APP_PATH/Contents/Resources/Licenses/"
install_name_tool -add_rpath '@loader_path/../../../../Frameworks' "$COMPUTER_USE_APP/Contents/MacOS/WonderComputerUse"
chmod +x "$APP_PATH/Contents/MacOS/WonderMenu" "$APP_PATH/Contents/MacOS/WonderMacBridge" "$APP_PATH/Contents/Resources/wonderd" "$APP_PATH/Contents/Resources/wonder-tunnel" "$COMPUTER_USE_APP/Contents/MacOS/WonderComputerUse" "$APP_PATH/Contents/Resources/nemo-speech-worker.py" "$APP_PATH/Contents/Resources/install-parakeet-model.sh"

python3 scripts/sign-macos-app.py "$APP_PATH"
scripts/verify-package-artifacts.sh "$APP_PATH"

echo "Built $APP_PATH"
