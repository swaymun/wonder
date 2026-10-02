# Wonder beta status

The signed public Mac beta remains available. The agent workspace Release
builds, Wonder Testing 1.0 (20) and production Wonder 1.0 (82), were each
uploaded once and processed by Apple. Wonder Testing build 20 is available in
the automatic Owner Beta internal group. Production build 82 tester availability
and installation through TestFlight have not been verified. No external beta
review or public enrollment was requested.

Wonder connects native iPhone and iPad conversations to agents on your own Mac.
The Mac companion requires Apple Silicon. Follow [installation](INSTALL.md) for
the supported runtime, Tailscale, provider sign-in and pairing requirements.
Keep the Mac awake and online while using it remotely.

## Availability

| Component | Status |
| --- | --- |
| iPhone and iPad | Production Release 1.0 (82) is uploaded and Apple reports processing complete. Its signed archive includes the Project Widget and passed channel identity, APNs, App Group, Keychain and Diagnostics-exclusion checks. Tester availability and TestFlight installation remain unverified. |
| Wonder Testing | The separate blue Release 1.0 (20) is uploaded, processed and available in automatic Owner Beta. Its signed archive passed the same channel-specific checks. TestFlight installation remains unverified; pairing, drafts and Keychain access stay separate from production. |
| Mac companion | [Version 1.0.101](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.101-beta.1) remains the public download. Replacement 1.0.108 is signed, notarized and installed locally and on a clean second Mac; publication waits for the remaining pairing, permission and draft-upgrade gates. |
| Source | The reviewed MIT source is at [swaymun/wonder](https://github.com/swaymun/wonder); this release's internal source is `91022396`. Third-party components retain their own licenses. |

A replacement Mac companion, 1.0.108, has been signed, notarized, stapled and
installed over 1.0.107 on the owner's Mac. The same verified DMG installed and
first-launched on a clean second Mac; both reached `/readyz`, including after a
restart. The public download remains 1.0.101 while fresh-Mac phone pairing,
private permissions and existing-draft upgrade behavior await acceptance.

The 1.0.101 update preserves the installed Mac's project chats and pairing. It
loads shared model options through the normal project runtime and starts the
private Bot runtime only when a Bot exists. The daemon and transport suites
passed 324 tests, with three existing tests ignored; strict Clippy and isolated
missing/mismatched-runtime restart checks passed. Opening an existing project
chat passed without creating private Bot folders or starting model work. A signed
1.0.78→1.0.79 automatic upgrade previously completed on this Mac; version 1.0.101
was installed through the signed local installer. Fresh-Mac setup remains unverified.

The [landing page, setup guide and privacy information](https://wonder-launch-preview.saimun-h-shahee.chatgpt.site) are public.

## Agent workspace qualification

The current source passed the daemon library suite (327 passed, 3 existing
ignored), store (159 passed), desktop (55 passed), host (17 passed), native
pairing (246 passed, one expected skip), Computer View (8 passed), and Mac
menu bar (36 passed). Focused iPhone and iPad simulator runs covered Project
controls, Automations, questions, subagent pills, Files and diffs, annotation
selection and revision recovery, EPUB and common bounded 3D previews, deep
links and Widget snapshots. A final delayed Files/Git/diff navigation regression
passed 2/2 on each simulator. Signed Release archives for both channels passed
main app and Widget identities, entitlements, bundled notices, and symbol export.

The Mac 1.0.108 replacement DMG passed signature, notarization, Gatekeeper,
local upgrade and clean second-Mac first launch; both installed copies reached
`/readyz`. Its public release remains gated as stated above. An accepted
annotation now dispatches its frozen source copy even after an unrelated
Project root change, verified by a fake-provider regression. On the installed
1.0.108 Mac, an isolated read-only Project thread completed a live Codex turn,
then a Project Automation claimed its scheduled run and completed a second turn.
Its durable message, native turn and assistant reply were verified. The
Automation was deleted and only its disposable thread was archived afterward.
This verifies the installed host's scheduled execution path; paired iPhone and
iPad interaction with that path remains unverified.

A post-upload review found retry and stale-response cases in these binaries:
some Project sends can remain uncertain after a definite pre-execution failure,
and a late New Chat error after re-pairing the same Mac can disturb the current
draft. Rapid PDF page turns can overlap preview work, and long Project history
scans can delay update handoff or miss receipts beyond 20,000 items. The Mac
install helper checks process health after replacement; these two installed
copies were also checked manually for `/readyz`. Source corrections and focused
iPhone, iPad, daemon and installer checks are complete on an unshipped branch. They are not
in Testing 20, production 82 or Mac 1.0.108; another release is required.

Native progressive dictation had no supported SpeechTranscriber locale on the
tested iOS 26.5 simulators, so the existing dictation path remains in place.
EPUB and read-only USDZ/OBJ/PLY/STL viewers passed focused checks, while
repeated SceneKit conversion retained measurable memory; broader GLB support
remains at a research gate. Actual Widget Home Screen presentation, paired
mobile-to-Mac Files/media and provider-send roundtrips, and TestFlight
installation remain unverified.

The post-release hardening review additionally corrected Bot and Project
history/lifecycle waits that could delay update handoff; the combined daemon
library suite passed 341 tests with three existing ignores, and the installer
handoff suite passed 12/12. A visible Chats control in the iPad conversation
shell passed a real-shell accessibility-size UI regression on iPad and the
corresponding iPhone check (1/1 each). These changes remain in unshipped draft
PR #61. With the owner's approval, a read-only pairing attempt found the
installed Mac did not expose a usable full link through the accessible Devices
UI, and the available simulator builds lacked durable pairing entitlements.
No new owner device appeared; paired mobile acceptance remains open.
An address-and-code option now exposes the existing pairing-code path in draft
PR #61. Its focused UI check passed 1/1 on each iPhone and iPad simulator,
including codes with `-` and `_`. A simulator-only ad-hoc signed build produced
an empty entitlement payload and was not installed for owner pairing. A live
code claim, Mac approval and paired Files/media/send roundtrip remain open.

## Earlier qualification

Testing build 7 and production build 71 passed six focused iPhone Simulator
checks and three iPad Simulator checks, with no failures or skips. These cover
queue retirement, reopen/reattach behavior, black-area hit testing and pointer
mode, plus question-form expansion and saved answers at normal and accessibility
text sizes. The shared native suites passed 57 tests; the daemon project suite
passed nine, the store repair regression passed one, and strict Clippy passed.
An older imported Wonder chat gained its existing desktop project assignment
through the installed Mac API without changing its conversation or starting a
model turn. Both exported Release packages passed signature, identity,
entitlement, Keychain-isolation and Diagnostics-exclusion checks. Physical touch
acceptance and installation through TestFlight were not repeated; this update
was qualified using simulators at the owner's request.

Earlier Testing build 6 and production build 70 share the updated picker. Optimized
iPhone and iPad Simulator UI checks each switched between Macs ten times in both
directions, verified draft restoration, and opened and canceled Add computer.
They also verified the selected computer remains fully visible above the keyboard
and Add computer can scroll fully into view. Screenshots confirm the 7-point
dots directly after Mac names. Both signed Release exports passed identity,
entitlement, Keychain-isolation and Diagnostics-exclusion checks. An earlier
physical-device build passed, but its UI runner could not initialize because
authentication was canceled; this revision's physical interaction and actual
TestFlight installation remain unverified. The owner authorized uploads to both
app identities.

An earlier shell revision passed 30 iPhone and 15 iPad Simulator navigation cycles,
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

Those earlier Release exports exclude the recorder, developer controls,
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
- Signed automatic Mac updates are implemented, including saved preferences and installation after work finishes. One signed automatic upgrade passed on this Mac; use the [signed Mac DMG](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.101-beta.1) if an update does not complete.
- Teaching a task and replaying taught tasks are unavailable in this beta.
- Notifications require permission and network access. Disabling notifications does not stop work on the Mac.
- Supported OS versions and verification evidence are different: simulator checks do not establish physical-device behavior on every supported model.

Release qualification is described in [RELEASING.md](RELEASING.md). The public
TestFlight link will be enabled only after the updated build and installation
checks pass.

Use synthetic examples when reporting issues. See [security reporting](SECURITY.md)
before sharing any sensitive reproduction information.
