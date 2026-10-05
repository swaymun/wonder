# Wonder protocol authority — v1, revision 2

September 5, 2026. Native migration gates 01–02. This package defines the wire contract; Rust handlers implement it. Changes to either must pass the same response fixtures. TypeScript interfaces in `src/index.ts` are hand-maintained consumer types, not generated authority.

## Authority and compatibility

- HTTP: `schemas/wonder-http-v1.json`, with the endpoint's named `$defs` schema as the root. The file's outer envelope is a schema catalog, **not** a wrapper emitted by HTTP handlers.
- WebSocket: `schemas/wonder-websocket-v1.json`. Optional correlation fields are nullable and use camelCase. Event data uses each Rust event variant's existing field names; do not apply a blanket casing conversion.
- Signing: `crates/wonder-api/src/pairing.rs`; normative byte/signature vectors in `tests/contracts/native/signing-v1.json`.
- Runtime: root `compatibility-manifest.json` records exact known schema hashes and the local additive-compatibility policy. A newer Codex runtime must preserve the bundled stable and experimental contracts and pass the code-mode probe. Wonder API v1 does not imply compatibility with arbitrary runtime versions.
- Revision 1 corrects previously omitted `conversationSnapshot.thread` and WebSocket correlation properties. It does not change the emitted response shape or the URI version.

The snapshot route `GET /api/v1/conversations/{id}` returns `conversationSnapshot`; a successful send/steer returns `messageReceipt`. The checked-in fixtures come from the real Axum handler against an isolated SQLite store and a fake stdio App Server. They contain synthetic IDs and may contain temporary test paths. Never regenerate them from an owner's live daemon.

Producer tests are strict about fields to catch drift. Consumers tolerate additional object properties. Removing fields, changing existing meanings or introducing mandatory behavior requires a new major contract. Additive display kinds may be introduced within v1. New write actions require an explicit reviewed client implementation; do not derive write authority from an unknown string or an HTTP success alone.

## Liveness and execution readiness (revision 2)

`GET /healthz` remains a public liveness probe (`200`, `{"status":"ok"}`). It does not authorize execution. `GET /readyz` returns `executionReadiness` with `200` when ready and `503` during recovery, storage failure, stopped/stalled projection, or substantial notification backlog. The authenticated `GET /api/v1/host/status` returns `hostStatus`, adding the same `execution` object; its existing `state` is degraded when execution or the public route is unavailable.

Consumers preserve drafts and disable new sends while `execution.ready` is false; `detail` explains recovery in user language. Missing execution readiness requires a host update, not an assumption of readiness. New sends, retries, steering, and manual/scheduled automation admission pause during recovery. Reading history and interrupting work remain available. A small, progressing inbox is normal; backlog above 256 envelopes or no projection progress for five seconds is degraded. The durable inbox, not this threshold or the observer broadcast, owns delivery.

Runtime restart never submits a new turn. Authoritative retained items/turns reconcile existing messages; incomplete history keeps readiness degraded. Outcomes that cannot be confirmed remain `uncertain` and the ordinary retry endpoint rejects them. Approval identities are opaque and scoped to their issuing runtime; their raw JSON-RPC IDs must never be sent to another runtime or inferred from display text.

## Unknown data and unsupported actions

An unfamiliar transcript item becomes a non-interactive “Unsupported activity” entry; preserve identity/order and surrounding messages, sanitize its content, and never interpret its payload as an executable action, approval or rendered HTML. The current daemon maps unknown runtime items to `type: unknown`; existing projection tests exercise this boundary.

An unknown state-bearing event is **not** equivalent to an ignorable display item. Native clients must preserve their last committed cursor and local intent, pause writes, request a snapshot once, and show “Update Wonder to continue syncing” if the event is still unsupported. Do not loop, acknowledge it as applied, or silently advance the cursor. The current Rust enum rejects unknown event variants; native client integration of this policy belongs to gate 09. Missing required fields or invalid types also stop application of the batch. Additional fields on known variants are tolerated.

No generic “forward request” mechanism is permitted. Unsupported HTTP methods fail (405); unknown approval/tool responses fail before runtime forwarding. New native clients must disable any action whose contract/runtime support is absent or unknown, preserve the attempted draft, and show “Update Wonder on your Mac and this device to use this action.” API version mismatch permits local cached reading only. Do not claim capability negotiation is implemented: native capability discovery is a prerequisite to enabling its write controls.

## Session and signature contract

Proposed native choice: reuse `__Host-wonder_session` over HTTPS, scoped to the paired origin, with `x-wonder-csrf` on non-GET requests and the exact public `Origin`. Keep an isolated native session per paired host; store identity and session material in Keychain, never UserDefaults, URLs, logs or shared browser storage. Reject cross-origin credential forwarding, including redirects and preview fetches. The existing server accepts this cookie form; no bearer-token alternative is implied.

Pairing uses P-256, public JWK coordinates as unpadded base64url, SHA-256 ECDSA and a 64-byte raw `r || s` signature (CryptoKit `rawRepresentation`, not DER). Canonical transcripts are UTF-8, LF-separated, ordered exactly as the Rust module, decimal unsigned timestamps, with no trailing LF or normalization. The action body hash is the existing action-specific canonical semantic body; it is not arbitrary JSON reserialization. Session binding is the issued CSRF value. All signed identifiers/origins come from the authenticated pairing/action flow, not display text.

Offer/challenge expiry, nonce consumption, host/device/origin binding, durable session insertion and revocation stay authoritative on the daemon. Signature interoperability tests do not establish secure Keychain storage or real-device pairing acceptance.

## Snapshot limitations

Revision 1 describes today's actual snapshot. `thread.hydrated` is a projection field, not proof of an atomic replay boundary. `thread.nextCursor` is not a host replay cursor. Gate 04 must introduce and validate a consistent host epoch/cursor with transactional snapshot/replay; native live synchronization remains blocked until then. Do not invent those guarantees by adding schema fields without changing storage/publication.

## Checks

From the repository root:

```sh
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo run --locked -p wonder-smoke -- recorded --restart
bash tests/contracts/native/check-signing.sh
```

`jsonschema` is a development-only validator with default network/file resolution disabled. Tests validate saved fixtures and freshly emitted handler responses, and reject a snapshot missing `thread`. To intentionally refresh the synthetic HTTP fixtures, run the named handler test with `WONDER_CONTRACT_FIXTURE_DIR` set to the absolute path of `tests/contracts/native`; review the resulting diff. Do not automatically refresh expected fixtures in ordinary test runs.


## Step 05 local history

`GET /api/v1/conversations/{id}` and `/history` now return the latest local page,
with `limit=1..100` (default 100). Pass `thread.nextCursor` as `before` to load
older entries. A page counts canonical user messages, assistant messages and
saved typed activities together. Responses stay chronological within the page;
merge by message/item identity, because a turn can cross page boundaries. Invalid,
wrong-conversation or unsupported-version cursors return 400; cursors survive
restart and do not depend on replay retention. An empty page is valid after deletion.

Each page is one committed SQLite read. Its `lastSequence` covers that page, not
unfetched history. Do not advance a whole-client replay cursor based on a later
page alone. Keep the initial page cursor while fetching older pages; on a replay
invalidation discard/refetch affected cached pages. This is live pagination, not
an immutable historical export. `thread.hydrated=false` honestly identifies local
projections; it does not mean the page is unreadable.

`POST /history/refresh` starts independent runtime hydration and returns 202
`{state:"refreshing",detail:null}`. It never performs a model turn or resumes a
thread. `GET /history/refresh` returns idle/refreshing/completed/failed and a
user-readable failure detail. At most two refreshes run per daemon, with one
per conversation; saturation returns retryable 429. Failed or abandoned refreshes
can be requested again. Saved history remains available. Fresh runtime history
fills missing entries and does not overwrite existing live projections.

The existing PWA is deliberately outside this migration step and has not been
adapted to pagination. Native scrolling, position restoration and cached display
remain native-client work.

### Native read acknowledgements

`PATCH /api/v1/conversations/{id}` accepts `markRead: true` only with the displayed snapshot's `hostEpoch` and `readThroughSequence` (its `lastSequence`). Send it only while the conversation's newest displayed content is actually visible in the active scene. The store clears unread state atomically only when no newer invalidation for that conversation exists and the snapshot epoch/retention boundary remains valid. A delayed, repeated or stale acknowledgement cannot clear newer unseen work. The returned summary remains authoritative; clients must not clear a newer local unread state from an older response. Archiving, renaming and pinning do not imply reading.

Group Chat reads include `hasUnread`, `hostEpoch` and `lastSequence` from the
same committed snapshot as their messages. A client that has actually displayed
the newest content may POST `{hostEpoch, readThroughSequence}` to
`/api/v1/group-chats/{id}/read`. The response is the current Group projection;
a delayed acknowledgement cannot clear a later reply. Clients must also reject
responses overtaken by their own newer projection or host change. No read
acknowledgement should be sent for cached, covered, inactive or offscreen content.

### New Bot readiness and folder approvals

A conversation snapshot may include `initialization: {questionId: null}` while
its first optional purpose question is being prepared. Once the question is
saved, `questionId` identifies it in the conversation's questions endpoint.
Native clients enable the composer only after that question reaches the device;
answering is optional. Null/absent initialization preserves existing chat behavior.
The message endpoint rejects premature sends with 409. A failed or interrupted
initialization is repaired with one default purpose question when the conversation
is read, without another model request. A late runtime question cannot duplicate it.

Approving a pending Bot folder request commits access, the selected workspace,
and one queued Bot follow-up together. Retrying the same approval does not queue
another turn. The follow-up uses the normal dispatcher and the saved execution
settings; its internal input is excluded from the transcript, search and editable
queue, while the Bot's acknowledgement is a normal persisted reply. Immediately
approved full-access requests remain in their existing conversational turn.

### Computer text and clipboard input

The existing `text` action accepts 1–4096 Unicode scalar values. The
`clipboard` action with `pasteFromPhone` accepts 0–8192 Unicode scalar values
and inserts them into the focused Mac application without changing the Mac
clipboard. Both permit newline (`\n`) and tab (`\t`), and reject other Unicode
control characters. Native clients, the daemon and the Mac helper enforce the
same limits. `fixtures/computer-clipboard-v1.json` records the whitespace and
control-character boundary cases.
