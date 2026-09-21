#!/usr/bin/env bash
set -euo pipefail

# This is a disposable-volume rehearsal of the package lifecycle. It is not
# the fresh-VM acceptance gate from the implementation plan.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_PATH="${1:-$ROOT_DIR/dist/Wonder-dev.pkg}"

if [[ "$(id -u)" != "0" ]]; then
  echo "package lifecycle rehearsal requires root because macOS installer requires root" >&2
  echo "run this script from a disposable VM or invoke it through sudo after reviewing the target" >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d /tmp/wonder-package-lifecycle.XXXXXX)"
IMAGE_PATH="$TMP_ROOT/lifecycle.dmg"
MOUNT_PATH="$TMP_ROOT/mount"
mkdir -p "$MOUNT_PATH"

cleanup() {
  hdiutil detach "$MOUNT_PATH" -force >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if [[ ! -f "$PKG_PATH" ]]; then
  scripts/package-dev-pkg.sh "$PKG_PATH"
fi

hdiutil create -quiet -size 512m -fs APFS -volname WonderLifecycle "$IMAGE_PATH"
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT_PATH" "$IMAGE_PATH"

install_pkg() {
  installer -pkg "$PKG_PATH" -target "$MOUNT_PATH"
}

install_pkg
test -x "$MOUNT_PATH/Applications/Wonder.app/Contents/MacOS/WonderMenu"
mkdir -p "$MOUNT_PATH/Library/Application Support/Wonder"
printf '%s\n' 'preserve-this-state' >"$MOUNT_PATH/Library/Application Support/Wonder/lifecycle-sentinel"

install_pkg
test -f "$MOUNT_PATH/Library/Application Support/Wonder/lifecycle-sentinel"

BACKUP_PATH="$TMP_ROOT/Wonder.rollback.app"
ditto "$MOUNT_PATH/Applications/Wonder.app" "$BACKUP_PATH"
rm -rf "$MOUNT_PATH/Applications/Wonder.app"
ditto "$BACKUP_PATH" "$MOUNT_PATH/Applications/Wonder.app"
test -x "$MOUNT_PATH/Applications/Wonder.app/Contents/MacOS/WonderMenu"

rm -rf "$MOUNT_PATH/Applications/Wonder.app"
test ! -e "$MOUNT_PATH/Applications/Wonder.app"
test -f "$MOUNT_PATH/Library/Application Support/Wonder/lifecycle-sentinel"

echo "package lifecycle rehearsal passed (temporary volume; not a fresh-VM gate)"
