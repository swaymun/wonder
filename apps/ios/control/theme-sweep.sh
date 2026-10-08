#!/bin/bash
# Usage: theme-sweep.sh DEVICE [SIMULATOR-NAME-PREFIX APPEARANCE] -- THEME_ID...
# Run from the repo root with WONDER_CONTROL_HOST=mac-mini. Runs theme-appearance.wctl once
# per theme (the copy lives under the synced tree so a remote host can read it) and names
# the screenshots theme-<id>-sidebar|chat|picker. With APPEARANCE (light|dark) the
# simulator's appearance is set first, for the "wonder" theme that follows the device.
set -u
device=$1; shift
appearance=""
if [ "$1" != "--" ]; then appearance=$1; shift; fi
shift
src=apps/ios/control/scenarios/theme-appearance.wctl
tmpdir=apps/ios/control/.sweep; mkdir -p "$tmpdir"
if [ -n "$appearance" ]; then
  udid=$(scripts/wonderctl --device "$device" device | tail -1)
  ssh "${WONDER_CONTROL_HOST:?}" "xcrun simctl ui $udid appearance $appearance"
fi
for id in "$@"; do
  name=$id; [ -n "$appearance" ] && name="$id-$appearance"
  sed -e "s/theme-nord-/theme-$name-/g" -e "s/--arg nord/--arg $id/" "$src" > "$tmpdir/$name.wctl"
  scripts/wonderctl --device "$device" run "$tmpdir/$name.wctl" 2>&1 | tail -1
done
rm -rf "$tmpdir"
