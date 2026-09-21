#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${WONDER_APP_PATH:-$ROOT_DIR/dist/Wonder.app}"
PKG_PATH="${1:-$ROOT_DIR/dist/Wonder-dev.pkg}"
INSTALLER_IDENTITY="${WONDER_INSTALLER_IDENTITY:-}"

cd "$ROOT_DIR"
scripts/package-dev-app.sh "$APP_PATH"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
[[ "$BUILD_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] || { echo "Invalid app build version" >&2; exit 2; }

mkdir -p "$(dirname "$PKG_PATH")"
PKG_ARGS=(
  --root "$APP_PATH"
  --identifier "com.saimun.wonder"
  --version "$BUILD_VERSION"
  --install-location "/Applications/Wonder.app"
)
if [[ -n "$INSTALLER_IDENTITY" ]]; then
  PKG_ARGS+=(--sign "$INSTALLER_IDENTITY")
else
  echo "Building an unsigned installer package; set WONDER_INSTALLER_IDENTITY for distribution signing." >&2
fi
pkgbuild "${PKG_ARGS[@]}" "$PKG_PATH"

if [[ "${WONDER_NOTARIZE:-0}" == "1" ]]; then
  [[ -n "$INSTALLER_IDENTITY" ]] || { echo "WONDER_NOTARIZE=1 requires WONDER_INSTALLER_IDENTITY" >&2; exit 2; }
  [[ -n "${WONDER_NOTARY_PROFILE:-}" ]] || { echo "WONDER_NOTARIZE=1 requires WONDER_NOTARY_PROFILE" >&2; exit 2; }
  xcrun notarytool submit "$PKG_PATH" --keychain-profile "$WONDER_NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG_PATH"
fi

scripts/verify-package-release-gates.sh "$APP_PATH" "$PKG_PATH"
echo "Built development package $PKG_PATH; consult ${WONDER_PACKAGE_GATE_PATH:-${PKG_PATH%.pkg}.acceptance.json} before treating it as release-ready."
