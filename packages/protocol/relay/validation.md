# Local relay validation

This record describes isolated synthetic tests, not device, Cloudflare deployment,
enrollment, or public-beta acceptance. Existing installed applications were not
changed. GitHub Actions remain disabled.

## Encrypted protocol and daemon adapter

- `cargo test -p wonder-relay --locked`: 11 passed. Covers fresh bidirectional
  handshake, strict frame limits, wrong peer/context, tamper, replay, ordering,
  old-session replay, unambiguous context and rejected handshake payloads.
- `cargo clippy -p wonder-relay -- -D warnings`: passed.
- `cargo test -p wonderd --features experimental-relay relay::tests --locked`:
  four tests exercise encrypted duplex streams, a new handshake after disconnect,
  exact stale-frame rejection, session/device/CSRF binding, revocation, forbidden
  local-management paths/headers and durable submission identity after reopening
  an isolated SQLite store. Enrollment is synthetic restored state. The lost
  response is discarded by the test, not a physical network interruption.
- `cargo test -p wonderd sync::tests --locked`: four passed, exercising committed
  replay order, checkpoints, gap/epoch resync and nonblocking snapshots.
- `cargo test -p wonderd --features experimental-relay dispatch::tests --locked`:
  four passed, including accepted/claimed restart recovery, execution before a
  lost receipt, receipt-commit failure and uncertain outcomes. Uses a fake stdio
  runtime, with no model invocation.
- Strict combined daemon/relay Clippy is blocked by pre-existing
  `needless_borrow` in `project_assignments.rs` and `field_reassign_with_default`
  in `asr_tests.rs`. Both were confirmed in the base checkout. The same check
  passes with only those two lint categories allowed:
  `cargo clippy -p wonderd --features experimental-relay --all-targets --locked -- -D warnings -A clippy::needless_borrow -A clippy::field_reassign_with_default`.

## Native interoperability proof

- `cargo test -p wonder-relay-ffi --locked`: two C ABI tests passed, including
  handle ownership, pointer/length errors and encrypted round trips.
- `cargo clippy -p wonder-relay-ffi --all-targets --locked -- -D warnings`: passed.
- `WONDER_RELAY_LIB_DIR="$PWD/target/native-relay/debug" swift test --package-path apps/native-relay`:
  10 linked macOS tests passed. Covers canonical framing, CryptoKit-generated
  X25519 keys with Rust Noise, wrong context, permanently poisoned oversized
  receive, Keychain attributes, exact entry cleanup and concurrent identity creation.
- Platform-specific Rust static libraries and Swift package compilation passed
  for `aarch64-apple-ios`/`iphoneos` and `aarch64-apple-ios-sim`/`iphonesimulator`.
  See the native package README for exact commands. This does not establish
  signed iOS app linking, installation or physical Keychain behavior.

### Final review correction

One review run hung while the concurrent Keychain test invoked synchronous
Security.framework calls from Swift cooperative tasks. Earlier runs had passed.
Keychain access is now serialized within the process, and the concurrency test
uses blocking GCD work instead. Five fresh full-suite runs passed (10 tests each)
under a 45-second process watchdog, with no hangs or deployment-target warnings.
This is bounded repeat evidence, not proof that OS Keychain calls can never block.
The API is synchronous and does not promise task cancellation.

The Rust build helper now fixes macOS 14/iOS 17 deployment targets in an isolated
target directory. `otool -l` confirmed the macOS archive's object minima are 11.0
or 14.0 and the linked XCTest executable targets 14.0. It no longer contains the
previously observed 26.5 minimum. Device archive objects target iOS 10.0 or 17.0;
simulator archive objects target iOS 14.0 or 17.0. All are within the supported
iOS 17 floor. The terminated earlier run did not record its
random test Keychain service ID, so cleanup of that one test entry is unverified;
no unrelated Keychain entries were inspected or deleted. The concurrency test
now prints its generated test service for exact recovery if a future run fails.

## Remaining integration evidence

The daemon adapter has no outbound connection or binary entry point. It handles
bounded JSON requests only. Native transport selection, authenticated enrollment,
pin rotation, shared secure host-key access, files/event framing and deployment
are separate unfinished integration work. Protocol and adapter tests must not be
reported as a completed end-to-end product.

Physical Wi-Fi/cellular transitions, revoked-phone behavior, host sleep/wake,
tunnel restarts, signed device builds and independent cryptographic review remain
unverified. No screenshots are claimed for these backend-only changes. The
existing direct transport remains available pending the release decision.
