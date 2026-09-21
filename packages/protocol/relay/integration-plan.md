# Remaining relay integration slices

The experimental channel, JSON adapter, local Worker and native crypto/Keychain
proof are review artifacts. A checkpoint request is not a working replacement
for the native messenger. Keep the installed direct transport unchanged.

The estimates below are planning ranges in engineer-days, excluding independent
security review, operator setup and physical acceptance. They are not September
14 delivery promises. Work should follow dependency order and each slice should
have its own reviewable PR. No release gate is accepted by this plan.

| Slice | Depends on | Concrete change and acceptance | Estimate |
| --- | --- | --- | --- |
| A. Secure endpoint identity | Native proof | Load a persistent host X25519 identity through the signed native bridge; store phone identity and peer pins with host/device/version binding. Verify locked/unlocked behavior, atomic creation, restart, exact revocation, rotation and loss-of-key recovery. Preserve existing Secure Enclave P-256 signing identity. | 1–2 days |
| B. Fresh enrollment | A | Extend a locally displayed one-use QR offer to pin the host encryption key; bind the phone encryption key to its existing signing identity and Mac confirmation. KK cannot enroll an unknown phone: review a maintained Noise host-authenticated enrollment pattern, such as NK, for the initial encrypted claim, then switch to pinned KK only after approval. Test substitution, expired/replayed offer, wrong host, rejection and restart at every commit boundary. | 2–3 days |
| C. Renewable per-device relay admission | B | Replace the fixed laboratory tokens/channel with bounded short-lived per-device admission and renewal. Authenticate issuance, partition customers/hosts, enforce active/revoked state, quotas and reconnect jitter. Registry authority never replaces endpoint authorization. Test stale tokens, revoked devices, room exhaustion, concurrent renewal and relay restart locally. | 1–2 days |
| D. Complete daemon transport | B, C | Add outbound WSS supervision with secure key loading. Route bounded JSON through existing handlers; add multiplexed event streams and chunked binary requests/responses for files and dictation. Reuse durable cursor replay, signatures, MIME/integrity checks and receipt reconciliation. Test backpressure, partial chunks, disconnect after acceptance, revocation during a stream and cancellation without duplicate work. | 2–3 days |
| E. Native app transport integration | D | Integrate the platform-specific Rust library into signed iOS packaging and the shared native API. Carry requests, event streams, downloads/uploads and dictation through an explicit selected transport. Preserve durable intent, client IDs and drafts. Reconcile uncertain delivery before any retry; never downgrade after authentication failure. Verify the full app on isolated simulator first. | 1–2 days |
| F. Deployment and physical acceptance | A–E | Deploy only within the chosen operator/domain/cohort/budget boundary, then test fresh pairing, separate Wi-Fi/cellular, network transitions during send/upload, relay/host restart, sleep/wake, revoked phone and app background/foreground. Capture signed builds, receipts, absence of duplicate runtime turns, timing and redacted logs. Review actual observability/retention and obtain independent security review. | At least 1–2 days after access and builds are ready |

An upgrade path for an already paired phone can transfer new pins over the
existing trusted transport, but it does not meet the fresh-user, Tailscale-free
enrollment requirement. Do not present that shortcut as completion of slice B.

## September 14 implication

The full chain is larger than the remaining beta window for a single engineering
track, and the physical/security reviews have uncertain lead time. Retaining the
tested existing transport is the concrete fallback already preserved in code.
The coordinator/owner must decide whether a controlled beta can use that path or
whether relay-backed release should wait. This plan does not make that release
decision or reduce the intended encryption requirements.

## External decisions before public deployment

Name the Cloudflare account/operator and domain, authorized test cohort, secret
custodian, connection/request/byte limits, spending ceiling, log/metadata retention,
and emergency shutdown/rotation owner. Public exposure and paid provisioning
remain unperformed. These decisions block deployment; they do not block the
local engineering slices above.

## Current evidence boundaries

Rust protocol/daemon and local Wrangler tests establish encrypted synthetic
request delivery and existing handler reuse. Native tests establish same-library
FFI interoperability and isolated macOS Keychain attributes/concurrent creation.
iOS device/simulator compilation is not installed-app or physical Keychain proof.
There is no product enrollment, full app transport, deployed Cloudflare path or
physical network evidence. Tracker #66/#94 remain open.
