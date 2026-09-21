#!/bin/bash
# Optimized, development-signed simulator build. Uses the normal live connection.
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:?Usage: scripts/build-ios-performance.sh SIMULATOR_UDID}"
output="${WONDER_PERFORMANCE_OUTPUT:-.local/scroll-performance/live}"
mkdir -p "$output"
xcodebuild -project apps/ios/Wonder.xcodeproj -scheme Diagnostics \
  -configuration Diagnostics -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath "$output" build > "$output/build.log" 2>&1
xcrun simctl install "$device" "$output/Build/Products/Diagnostics-iphonesimulator/Wonder.app"
xcrun simctl launch --terminate-running-process "$device" com.swaymun.wonder
