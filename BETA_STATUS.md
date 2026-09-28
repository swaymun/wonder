# Wonder beta status

The signed Mac beta is available. Release iOS build 1.0 (60) is uploaded,
processed, and available for internal testing. Apple reports it as ready for
external beta submission; external review and public enrollment have not been
opened for this build. No tester groups or notifications were changed.

Wonder connects native iPhone and iPad conversations to agents on your own Mac.
The Mac companion requires Apple Silicon. Follow [installation](INSTALL.md) for
the supported runtime, Tailscale, provider sign-in and pairing requirements.
Keep the Mac awake and online while using it remotely.

## Availability

| Component | Status |
| --- | --- |
| iPhone and iPad | Release 1.0 (60) includes cached startup, read-receipt retries, and stable conversation opening/scrolling. Apple reports `VALID` and `IN_BETA_TESTING`; external status is `READY_FOR_BETA_SUBMISSION`. Installation of this build through TestFlight remains unverified. |
| Mac companion | [Version 1.0.80](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.80-beta.1) remains the public download. The 1.0.92 candidate is signed, notarized, stapled, installed locally, and passes signature, Gatekeeper, `/readyz`, and verification against the official ChatGPT 26.924.22138 (11645) runtime. Its DMG and signed update feed are prepared but not published. |
| Source | The reviewed MIT source is public at [swaymun/wonder](https://github.com/swaymun/wonder). The performance-overhaul update is prepared for publication. Third-party components retain their own licenses. |

The 1.0.92 update preserves the installed Mac's pairing and history. A signed
1.0.78→1.0.79 automatic upgrade previously completed on this Mac; the new candidate
was installed through the signed local installer. Fresh-Mac setup remains unverified.

The [landing page, setup guide and privacy information](https://wonder-launch-preview.saimun-h-shahee.chatgpt.site) are public.

## Qualification still in progress

The final optimized Diagnostics build passed physical iPhone 11 checks on iOS
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
for build 60. Physical iPad, fresh-Mac setup, external TestFlight installation,
independent-network behavior, complete VoiceOver navigation, and scheduler
recovery remain unverified. Teaching a task and replaying taught tasks remain
outside the beta scope.

## Beta limitations

- Initial setup requires both devices, Tailscale and access to the supported model provider.
- Model requests are sent to your provider. Wonder does not include a model subscription or credits.
- Remote access depends on the Mac being reachable. Tailscale may relay encrypted traffic when a direct connection is unavailable.
- Signed automatic Mac updates are implemented, including saved preferences and installation after work finishes. One signed automatic upgrade passed on this Mac; use the [signed Mac DMG](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.80-beta.1) if an update does not complete.
- Teaching a task and replaying taught tasks are unavailable in this beta.
- Notifications require permission and network access. Disabling notifications does not stop work on the Mac.
- Supported OS versions and verification evidence are different: simulator checks do not establish physical-device behavior on every supported model.

Release qualification is described in [RELEASING.md](RELEASING.md). The public
TestFlight link will be enabled only after the updated build and installation
checks pass.

Use synthetic examples when reporting issues. See [security reporting](SECURITY.md)
before sharing any sensitive reproduction information.
