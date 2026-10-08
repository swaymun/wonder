#!/bin/bash
# Build, sign, notarize and staple a Mac release (RELEASING.md#mac-artifact).
#   scripts/release-mac.sh 1.0.126
# On the Mac mini run it through scripts/wonder-remote --ref HEAD --signing; with
# MATCH_KEYCHAIN_PASSWORD set it signs from the dedicated wonder-signing keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:?usage: scripts/release-mac.sh VERSION}
[[ "$V" =~ ^[0-9]+([.][0-9]+)*$ ]] || { echo "Version must be numeric" >&2; exit 1; }
R=.local/release/mac-$V
mkdir -p "$R"

CFG="${WONDER_ASC_CONFIG:-$HOME/.config/wonder/app-store-connect/upload.json}"
field() { python3 -I -c 'import json, os, sys; v = json.load(open(sys.argv[1]))[sys.argv[2]]; print(os.path.expanduser(v))' "$CFG" "$1"; }
KEY=$(field privateKeyPath); KID=$(field keyId); ISS=$(field issuerId)
notarize() {
  xcrun notarytool submit "$1" --key "$KEY" --key-id "$KID" --issuer "$ISS" --wait --output-format json > "$2"
  cat "$2"; echo
  grep -q '"status":"Accepted"' "$2"
}

KEYCHAIN="$HOME/Library/Keychains/wonder-signing.keychain-db"
if [[ -n "${MATCH_KEYCHAIN_PASSWORD:-}" && -f "$KEYCHAIN" ]]; then
  security unlock-keychain -p "$MATCH_KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security list-keychains -d user | tr -d '"' | grep -qx "[[:space:]]*$KEYCHAIN" ||
    security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  trap 'security lock-keychain "$KEYCHAIN"' EXIT
fi

# wonder-remote copies have no .git and pass the source identity instead.
if [[ -n "${WONDER_SOURCE_COMMIT:-}" ]]; then
  echo "$WONDER_SOURCE_COMMIT" > "$R/source-commit.txt"
else
  git rev-parse HEAD > "$R/source-commit.txt"; git status --short > "$R/source-status.txt"
fi
rm -rf "$R/Wonder.app"
WONDER_APP_SIGNING_IDENTITY='Developer ID Application: Saimun Shahee (8KKNVD7758)' WONDER_NOTARIZE=1 WONDER_BUILD_VERSION=$V \
  scripts/package-dev-app.sh "$R/Wonder.app" > "$R/build.log" 2>&1 || { tail -30 "$R/build.log"; exit 1; }
codesign -dvv "$R/Wonder.app" > "$R/app-signature.txt" 2>&1
ditto -c -k --keepParent "$R/Wonder.app" "$R/Wonder-app.zip"
notarize "$R/Wonder-app.zip" "$R/app-notarization.json"
xcrun stapler staple "$R/Wonder.app" && rm "$R/Wonder-app.zip"
scripts/package-macos-dmg.sh "$R/Wonder.app" "$R/Wonder-$V.dmg" >> "$R/build.log" 2>&1
notarize "$R/Wonder-$V.dmg" "$R/dmg-notarization.json"
xcrun stapler staple "$R/Wonder-$V.dmg"
xcrun stapler validate "$R/Wonder-$V.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$R/Wonder-$V.dmg"
scripts/verify-macos-dmg.sh "$R/Wonder-$V.dmg" "$V"
(cd "$R" && shasum -a 256 "Wonder-$V.dmg" > SHA256SUMS)
echo "release $V ready: $R/Wonder-$V.dmg"
