#!/bin/sh
set -eu

platform="${1:-macos}"
export CARGO_TARGET_DIR=target/native-relay
case "$platform" in
    macos)
        export MACOSX_DEPLOYMENT_TARGET=14.0
        output="$CARGO_TARGET_DIR/debug"
        target_args=""
        ;;
    ios)
        export IPHONEOS_DEPLOYMENT_TARGET=17.0
        output="$CARGO_TARGET_DIR/aarch64-apple-ios/debug"
        target_args="--target aarch64-apple-ios"
        ;;
    ios-simulator)
        export IPHONEOS_DEPLOYMENT_TARGET=17.0
        output="$CARGO_TARGET_DIR/aarch64-apple-ios-sim/debug"
        target_args="--target aarch64-apple-ios-sim"
        ;;
    *)
        printf '%s\n' "usage: $0 [macos|ios|ios-simulator]" >&2
        exit 2
        ;;
esac

# shellcheck disable=SC2086
cargo build -p wonder-relay-ffi --locked $target_args
printf '%s\n' "$output"
