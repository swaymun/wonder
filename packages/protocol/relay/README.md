# Relay transport review boundary

Status: experimental components, disabled in the product. Neither the daemon nor
the native app connects to this relay. Tailscale remains the working transport.
This document does not accept the remote-connectivity release gates.

## Trust model

Assume the relay can inspect, replace, replay, reorder, delay and drop every byte;
misroute connections; and lie about device membership. TLS to Cloudflare protects
the network hop but terminates at Cloudflare. It is not endpoint encryption.

The endpoint channel uses the maintained `snow` implementation of
`Noise_KK_25519_ChaChaPoly_BLAKE2s`. Both static peer keys must already be verified
and pinned outside the relay. The handshake binds the host, device and route to a
versioned, length-delimited prologue. Application bytes are forbidden in the
handshake. A fresh handshake is required for every new connection; cipher state
is never resumed or restored. An authentication/framing error ends the session.
The Noise specification limits a message to 65,535 bytes, including its tag.
See the [Noise specification](https://noiseprotocol.org/noise.html) and
[`snow` documentation](https://docs.rs/snow/latest/snow/).

The channel authenticates possession of pinned keys, not current device access.
The daemon must still enforce durable device revocation, session expiry, CSRF,
action signatures, approval policy and readiness at the existing API boundary.
No decrypted packet may acquire the loopback capability or local-owner authority.
Routing credentials are admission limits only and cannot authorize Mac actions.

## Enrollment dependency: not implemented

Current `PairingLink` carries an origin, offer secret, offer ID and host ID.
`Challenge` proves the phone's existing P-256 signing identity; neither structure
pins a host encryption key. The phone stores that signing key in Secure Enclave
on hardware and its saved connection in Keychain. There is no corresponding
host Noise identity or approved device-to-Noise-key association today.

Therefore the existing pairing URL cannot simply be changed to a Cloudflare URL.
Before integration, a separate reviewed enrollment change must:

1. Generate and retain endpoint encryption identities in platform secure storage.
   X25519 is a distinct key from the existing Secure Enclave P-256 signing key;
   do not silently export, repurpose or downgrade that signing identity.
2. Bind protocol version, host ID, host encryption public key, one-use offer and
   expiration into the locally displayed QR offer. Bind the phone encryption
   public key to its signing identity and explicit Mac approval. Reject expired,
   replayed, substituted and cross-host offers before saving an association.
3. Store peer pins with the approved device record and load private keys through
   a reviewed Keychain/native bridge. No private key in config, logs, argv, relay
   storage or a checked-in fixture. Test hardware lock/unlock and daemon access.
4. Persist revocation before closing channels, recheck authorization on every
   request, and invalidate active channels on revocation. Restart must reload
   revocations before accepting traffic; a stale relay record cannot restore access.
5. Rotate keys through existing trusted-device approval or explicit re-enrollment.
   Losing all trusted identities requires local re-enrollment. Account recovery,
   relay administration and possession of an old routing token cannot replace pins.

The new library's caller-supplied keys are a testing/integration interface, not
secure storage or a completed enrollment implementation. Independent cryptographic
and enrollment review is required before public launch.

## Experimental daemon adapter and remaining native integration

The `wonderd` feature `experimental-relay` adds `relay::serve_stream`, a bounded
ordered-stream adapter. It opens no listener and is not enabled by the daemon
binary. The caller must supply keys and context from verified enrollment. Each
connection performs a new handshake; each decrypted request binds its existing
session/CSRF credentials to the enrolled device before entering the normal router.
Revocation notifications close idle streams and every request rechecks access.

The laboratory wire format uses a four-byte big-endian length followed by each
handshake message. Transport frames use the encrypted channel's own length prefix.
The JSON envelope is `{requestId, method, path, sessionToken, csrfToken, body}`;
`body` is an HTTP body string, not a nested object. The response is
`{requestId, status, body}`. Correlation IDs do not replace durable submission IDs.
No arbitrary headers are accepted. The host supplies Origin and never injects
its loopback capability. Pairing management, event sockets and ASR routes are
excluded. This slice limits body strings to 24 KiB, frames to 65,535 bytes and
idle reads/writes to 30 seconds. Oversized/unreadable responses after dispatch
require receipt reconciliation, never automatic execution retry.

Product integration remains unfinished. Keep transport selection explicit and additive. The native shared transport must
carry the existing authenticated HTTP contract inside the encrypted channel;
the daemon must dispatch through the same authorization and durable handlers.
Do not add a parallel send queue or acknowledge a message at the relay.
Files, dictation, paginated reads and event replay require bounded framing and
flow control before native transport replacement; one Noise message is not an
unbounded HTTP response or file transfer.

The existing `clientMessageId` and durable request identity survive disconnect,
network change and transport change. On a lost response, query/reconcile that
identity. Never create a replacement ID or treat connection failure as proof
that execution did not start. Unknown execution outcomes remain blocked.
Snapshots/cursors still come from committed Mac storage, and native projection
and cursor commits remain atomic. Relay buffers are never history or receipts.

Reconnect uses bounded exponential backoff with jitter, observes cancellation,
and starts a new channel. Close both ends on peer loss; discard transient bytes.
Foreground recovery works without push. Host sleep cannot be represented as
completed work. There is no automatic downgrade after authentication failure.

## Operator and acceptance decisions

The Worker is a single-pair laboratory scaffold, not a customer device registry.
Before deployment, identify the Cloudflare account/operator, domain, secret
custodian, permitted cohort, request/connection/byte quotas, spending ceiling,
metadata/log retention and incident shutdown procedure. Review Cloudflare's
platform observability and backups as well as application logging. Do not enable
public routes, provision paid infrastructure or distribute credentials from this
configuration alone.

The relay can observe IPs, routing identifiers, timing, sizes and connection
lifetime. Endpoint encryption is not anonymity. Endpoint compromise and denial
of service are outside its confidentiality guarantee. Model providers continue
to receive inference context through the existing intentional boundary.

Required final evidence, on exact signed endpoint builds and deployed Worker:

| Scenario | Required result | Current evidence |
| --- | --- | --- |
| Separate Wi-Fi and cellular | Pair, send, stream, recover same receipt | Not run |
| Wi-Fi/cellular transition after acceptance | Same request reconciles; one execution | Not run |
| Tunnel/relay restart during send | Fresh handshake; no duplicate or lost receipt | Not run |
| Host restart and sleep/wake | Durable replay or explicit resnapshot; retained intent | Not run |
| Revoked phone, including restart | Immediate denial; no stale-channel access | Not run |
| Wrong pins, altered frames and replay | Fail closed before application delivery | Local protocol tests only |
| Slow peer and over-quota traffic | Bounded resource use; closed connection | Local Worker tests only |

Local synthetic cryptographic and Worker tests do not establish these physical
or deployment outcomes. Keep the existing transport until the integrated path
passes this matrix and receives the release decision.
