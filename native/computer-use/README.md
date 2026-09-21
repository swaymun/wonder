# Native computer-use boundary

`WonderComputerUse` is a separately packaged, permission-gated unlocked
Computer Use service. In the signed Mac app it is shipped as the
`Resources/WonderComputerUse.app` LSUIElement bundle, with the executable at
`Contents/MacOS/WonderComputerUse`. The helper keeps the stable
`com.saimun.wonder.computer-use` bundle/code identifier so its local consent
window is addressable by native UI automation and its existing TCC identity is
preserved across signed updates. It communicates over JSONL on standard
input/output so `wonderd` can supervise it without exposing a network listener.

Supported actions are deliberately narrow: `status`, `screenshot`, `click`,
`type`, `key`, `focusApp`, the authenticated `capture.*` family, and the
authenticated `control.*` lease/input family. Every input
is bounded and the pointer/keyboard actions fail closed unless macOS
Accessibility is trusted. Screenshots and ScreenCaptureKit capture fail closed
unless Screen Recording is available. The service never enables locked use,
elevates privileges, or accepts arbitrary shell commands.

## Capture boundary

The capture owner is a separate `WonderComputerUseCore` library target backed by
ScreenCaptureKit. It supports `capture.prepare`, `capture.sources`,
`capture.pick`, `capture.start`, `capture.pause`, `capture.resume`,
`capture.stop`, `capture.status`, `capture.viewerCount`, and
`capture.sourceRemoved`. Each capture command is handshake-gated and carries the
session ID and generation where it acts on an existing session. Duplicate stops
are safe for the same identity; a stale identity is rejected.

The initial stream is 1280x720 at 15 fps with audio disabled and a ScreenCaptureKit
queue depth of two. Frames are handled on a dedicated capture queue and handed to
the pinned stasel/WebRTC M153 `RTCVideoSource(forScreenCast: true)` through a
bounded latest-frame sink. Superseded frames are dropped so a slow encoder cannot
accumulate latency. Pixel payloads are never persisted, logged, or placed in chat
events; only bounded metadata is emitted.

On macOS 14 and newer, `capture.pick` uses the system sharing picker. A request
originating from a phone reports **Choose what to share on your Mac** until the
person completes that OS-owned action. It never bypasses TCC. On older supported
macOS versions, the helper reports that the system picker is unavailable and the
caller can use a listed display/window instead. The daemon mediates authenticated,
in-memory offer/answer and bounded trickle-ICE signaling. Direct LAN ICE is used
with an empty ICE-server list in this checkpoint; there is no LiveKit, token
broker, public helper listener, TURN service, or WebRTC remote input/data
channel. Control input is delivered through the authenticated daemon/helper
pipe only. The paired owner, conversation, host, and generation bind every
signaling operation.

Each successful action also returns a bounded accessibility observation: the
frontmost app, focused window, and focused element metadata such as role,
title, description, identifier, and whether its value is settable. Text field
contents are not returned; only value type/length metadata is included. This
lets the agent verify what the desktop reports after an action without making
the driver a general-purpose screen reader or collecting typed secrets.

Build it with:

```text
swift build -c release --package-path native/computer-use
```

Use `--dry-run` for protocol and permission checks; it validates inputs without
posting pointer, keyboard, or application-focus events.

When `computer_use_enabled` is on and the configured executable is present and
executable, `wonderd` supervises one persistent helper for the host. It stores a
session as preparing, starts the child with a fresh per-invocation handshake,
and sends `capture.prepare` followed by `capture.pick`. The system picker stays
Mac-owned and TCC-gated. Helper responses and lifecycle events are bounded,
session/generation checked, and folded into the durable session row. Duplicate
requests for the same device/request reuse the worker; a different owner cannot
take an active provider session. Delete, revocation, helper failure, and daemon
shutdown stop, kill if necessary, and reap the child, releasing any lease.

Direct invocations without the daemon handshake are rejected, including
`status`; `stop` remains available only to terminate the supervised child
process. The helper only publishes to the authenticated daemon-mediated peer.
The iOS renderer and remote-control gestures use the same authenticated lease
boundary. Native input is delivered only when the owner has enabled **Allow
control from paired devices** in local Wonder Settings. Stopping the lease,
disabling the preference, losing the capture binding, backgrounding the
session, or expiry releases held input and hides the local control surface.

The package script builds the nested helper bundle, adds the outer-app-relative
`@loader_path/../../../../Frameworks` rpath to the helper, signs the helper
executable and app inside-out, and rejects the old flat helper path in finished
artifacts. The launcher still falls back to the legacy flat path only when an
older installed bundle is run. Runtime execution and Accessibility/Screen
Recording approval remain explicit acceptance gates; ordinary builds do not
invoke an action.

Run the focused native checks with:

```text
swift test --package-path native/computer-use
python3 -m py_compile scripts/install-signed-app.py scripts/test-signed-update.py scripts/sign-macos-app.py
```

For two signed staged bundles, `scripts/test-signed-update.py` verifies changed
app code, bidirectional designated-requirement compatibility, migration from a
legacy flat helper, and rejection of a tampered nested helper. The helper code
may remain unchanged between app updates; its stable identity and nested code
signatures are still checked. No installation is required by that test.
