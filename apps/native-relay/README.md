# Wonder native relay proof

This is an additive native proof package, tested on macOS and compiled for iOS.
It is disabled from the existing
native app and does not change the current Tailscale transport.

`RelayInitiator`, `RelayResponder`, and `RelaySession` are small Swift
ownership and bounds wrappers around the Rust `snow` implementation. The Rust
library must expose the declarations in
`Sources/WonderRelayFFI/include/wonder_relay.h` as a static library named
`libwonder_relay_ffi.a`; this package does not implement Noise primitives in Swift.
The FFI accepts raw 32-byte X25519 keys and the three context identities. Rust
constructs the canonical prologue used by the shared `wonder-relay` crate. A
fresh session is created per connection and all transport frames are capped at
the Noise 65,535-byte limit.

The keychain helper deliberately stores the separate X25519 private key as a
generic-password item with `WhenUnlockedThisDeviceOnly` accessibility and
`kSecAttrSynchronizable=false`. It is not a Secure Enclave key and is not the
existing P-256 signing identity. Callers must pin the peer public key through
the reviewed enrollment flow before constructing a session.

Private bytes temporarily occupy ordinary Swift `Data` and CryptoKit buffers;
this proof does not guarantee erasure of every memory copy. It has not verified
locked-device access, signed host/bridge Keychain sharing, backup/restore or
rotation. Those remain enrollment/release requirements. The iOS results are
cross-compilation, not signed-app linking, installation or Keychain testing on a phone.

## Local compile and interop test

Build the separate FFI crate and point SwiftPM at Cargo's output directory:

```sh
WONDER_RELAY_LIB_DIR="$PWD/$(apps/native-relay/scripts/build-relay-ffi.sh macos)" \
  swift test --package-path apps/native-relay
```

The script isolates these artifacts under `target/native-relay` and fixes the
deployment targets at macOS 14 and iOS 17. Do not substitute a cached archive
built for a newer OS. Keychain operations are synchronous and serialized within
the process; call them from a blocking-work context, not a group of cooperative
Swift tasks. Atomic `SecItemAdd` still resolves creation races across processes.

For an iOS device or simulator build, use the matching Rust target so SwiftPM
never links the macOS archive into an iOS product:

```sh
WONDER_RELAY_LIB_DIR="$PWD/$(apps/native-relay/scripts/build-relay-ffi.sh ios)" \
  swift build --package-path apps/native-relay --triple arm64-apple-ios \
  --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"
WONDER_RELAY_LIB_DIR="$PWD/$(apps/native-relay/scripts/build-relay-ffi.sh ios-simulator)" \
  swift build --package-path apps/native-relay --triple arm64-apple-ios-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
```

The test uses unique service names and deletes only its exact Keychain entries.
It exercises both directions of a Noise KK handshake, authenticated payload
round trips, a mismatched context failure, and the daemon adapter's
length-prefixed handshake plus bounded JSON request/response shapes. This is
local compile/test evidence only; it does not enroll an account, install an
app, or connect to a relay.
