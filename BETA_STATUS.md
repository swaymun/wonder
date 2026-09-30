# Wonder beta status

The signed Mac beta is available. Release iOS build 1.0 (69) is uploaded,
processed, and available for internal testing. Apple reports it as ready for
external beta submission; external review and public enrollment have not been
opened for this build. Production tester groups and notifications were not changed.

Wonder connects native iPhone and iPad conversations to agents on your own Mac.
The Mac companion requires Apple Silicon. Follow [installation](INSTALL.md) for
the supported runtime, Tailscale, provider sign-in and pairing requirements.
Keep the Mac awake and online while using it remotely.

## Availability

| Component | Status |
| --- | --- |
| iPhone and iPad | Production Release 1.0 (69) is the Projects-only shell: pinned threads, provider icons, model/Plan settings, read-state and model-list fixes, and no Bot or Group management screens. Apple reports `VALID` and `IN_BETA_TESTING`; external status is `READY_FOR_BETA_SUBMISSION`. Installation of this build through TestFlight remains unverified. |
| Wonder Testing | The separate blue app, Release 1.0 (4), replaces connection status text in the composer computer menu with green/red dots. It is `VALID` and `IN_BETA_TESTING`; external status is `READY_FOR_BETA_SUBMISSION`. Its private internal testing group has one invited tester and access to build 4. It keeps its own pairing, drafts, and Keychain access. Installation through TestFlight remains unverified. |
| Mac companion | [Version 1.0.99](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.99-beta.1) is the public download. It is signed, notarized, stapled, installed locally, and passes signature, Gatekeeper, `/readyz`, and packaged verification against the installed Codex 0.159.0 runtime. |
| Source | The reviewed MIT source is public at [swaymun/wonder](https://github.com/swaymun/wonder). The Projects-first shell and compact connection-menu update are published on `main`. Third-party components retain their own licenses. |

The 1.0.99 update preserves the installed Mac's pairing and history. A signed
1.0.78→1.0.79 automatic upgrade previously completed on this Mac; version 1.0.99
was installed through the signed local installer. Fresh-Mac setup remains unverified.

The [landing page, setup guide and privacy information](https://wonder-launch-preview.saimun-h-shahee.chatgpt.site) are public.

## Qualification still in progress

Testing build 4 passed its optimized Simulator build and two existing checks for
connection-scoped drafts and shared connection ownership. Its signed Release
export passed identity, entitlement, Keychain-isolation and Diagnostics-exclusion
checks. Visual and physical acceptance of the connection-menu dots, and actual
TestFlight installation of this candidate, remain unverified. Production
promotion awaits owner approval.

The current shell passed 30 iPhone and 15 iPad Simulator navigation cycles,
including saved drafts, Settings navigation and pin toggle/reopen/restoration.
The app launch check passed 10 launches and 20 foreground/Settings cycles.
Four focused client state tests and 14 shared native tests passed.
No model requests were sent during these checks. Physical-device acceptance of
this shell remains unverified.

Earlier build 66 Projects qualification passed composer-control placement,
durable draft/dictation, and Group review checks. An optimized
Diagnostics build passed 30 navigation cycles on a physical iPhone 11 running
iOS 27 in 529 seconds including setup. That build kept model and permission
choices, attachments, dictation and Send inside the composer; Connection and
Destination sat above it. No model requests were sent during these navigation checks.

The content-free capture covered the first 111 seconds: opening readiness was
92.7 ms at p95 across 11 samples; the main-thread probe was 51.3 ms at p95 across
194 samples. Network requests were measured separately (98.0 ms p95, 611.2 ms
maximum). Resident memory settled at 166.9–168.0 MiB and physical footprint at
54.0–55.3 MiB during the final 30 seconds of that capture. This short capture
does not establish memory stability across the full navigation run or certify
touch latency and rendered-frame performance.

Both current Release exports exclude the recorder, developer controls,
scenario runner and fixtures. Their signatures, app/extension identities,
APNs entitlements and separate Keychain groups passed verification; provider
icons include sRGB fallbacks and P3 variants.

Both providers passed exact-session terminal continuity on the tested compatible
runtimes. A live Codex request read its uploaded attachment, and retrying the same
request produced only one user message. Live Claude attachment verification was
blocked by the provider session quota; scoped attachment and permission tests
passed, but they do not replace that live check. Direct Codex-app and Claude
Desktop selection remain unverified. Continue on Mac provides terminal commands;
finish work in one client before switching because simultaneous writers are not
coordinated across applications.

Earlier build 60 qualification passed physical iPhone 11 checks on iOS
27.0 and iPhone/iPad simulator checks on iOS 26.5. Normal opening-frame regression
captures the first 1.5 seconds for both a saved older position and the latest
reply; both failed before the fix and passed afterward. The focused automated
check takes about eight seconds on the iPad simulator.

Physical live scrolling passed 88 gestures over 396 seconds. XCTest reported
3.215 ms/s mean hitch time and 56.86 fps, with peak physical memory below 85 MB.
Its frame-count field was anomalously zero, so those reported timings are not a
complete frame-level certification. A separate ten-minute run completed 246
cycles without a failure or sustained memory growth in its final five-minute
window. Activity/detail readiness proxies were 73.10/83.00 ms at p95; their
maxima were below 131 ms. Opening readiness was 211.49 ms at p95 across three
samples, above the initial 100 ms target. Network time remains separate from
local rendering. A warmed, interleaved comparison of 120 interactions per
recording mode found no added p95 recording cost. These are device-specific
measurements, not guarantees for every chat or device.

Earlier Release build 52 passed user-observed notification routing and live
computer viewing/input checks on an iPhone Air. Those checks were not repeated
for the current shell. Physical iPad, fresh-Mac setup, external TestFlight installation,
independent-network behavior, complete VoiceOver navigation, and scheduler
recovery remain unverified. Teaching a task and replaying taught tasks remain
outside the beta scope.

## Beta limitations

- Initial setup requires both devices, Tailscale and access to the supported model provider.
- Model requests are sent to your provider. Wonder does not include a model subscription or credits.
- Remote access depends on the Mac being reachable. Tailscale may relay encrypted traffic when a direct connection is unavailable.
- Signed automatic Mac updates are implemented, including saved preferences and installation after work finishes. One signed automatic upgrade passed on this Mac; use the [signed Mac DMG](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.99-beta.1) if an update does not complete.
- Teaching a task and replaying taught tasks are unavailable in this beta.
- Notifications require permission and network access. Disabling notifications does not stop work on the Mac.
- Supported OS versions and verification evidence are different: simulator checks do not establish physical-device behavior on every supported model.

Release qualification is described in [RELEASING.md](RELEASING.md). The public
TestFlight link will be enabled only after the updated build and installation
checks pass.

Use synthetic examples when reporting issues. See [security reporting](SECURITY.md)
before sharing any sensitive reproduction information.
