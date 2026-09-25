# Wonder beta status

The signed Mac beta is available. Public TestFlight enrollment is not open yet.
Apple shows iOS build 1.0 (50) as Approved for external testing. Build 1.0 (52)
is processed but ready for beta submission, and the Public Beta group has no
testers or public link. The planned first wave is limited to 100 people; release
qualification is still in progress.

Wonder connects native iPhone and iPad conversations to agents on your own Mac.
The Mac companion requires Apple Silicon. Follow [installation](INSTALL.md) for
the supported runtime, Tailscale, provider sign-in and pairing requirements.
Keep the Mac awake and online while using it remotely.

## Availability

| Component | Status |
| --- | --- |
| iPhone and iPad | Release 1.0 (50) is externally approved. Release 1.0 (52), containing Goal mode, notification setup feedback, and the reading-anchor fix, is uploaded, processed, and installed through internal TestFlight on the iPhone Air. Its external approval, visible background notification delivery, and public enrollment are unverified. |
| Mac companion | [Version 1.0.80](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.80-beta.1) is the public signed and notarized download. Its hosted DMG matches the verified local artifact. It is installed on the development Mac and passes Gatekeeper and `/readyz` with ChatGPT's `0.155.0-alpha.16.4` runtime. Screen Recording and Computer Control both show Allowed after installation. A signed 1.0.78→1.0.79 automatic upgrade completed and relaunched this Mac in about 31 seconds; 1.0.80 was installed manually. A fresh-Mac setup remains unverified. |
| Source | The reviewed MIT source is public at [swaymun/wonder](https://github.com/swaymun/wonder). Third-party components retain their own licenses. |

The [landing page, setup guide and privacy information](https://wonder-launch-preview.saimun-h-shahee.chatgpt.site) are public.

## Qualification still in progress

The iPhone 11 passed the focused approval-box tests, the permission/helper interaction session, and the Goal sheet test. Two initial ten-minute Diagnostics sessions on a 647-row conversation reached 203 and 214 ms p95 activity-readiness proxies. A same-binary comparison completed 231 cycles without automatic activity-row scrolling (92 ms p95, 95 ms max, final five-minute physical-footprint trend +1.3 MiB) and 232 cycles with it (111 ms p95, 119 ms max, +1.8 MiB). The no-scroll behavior is now in the app; its large-text reading anchor passed focused iPhone, iPad and physical iPhone 11 tests. The comparison also saw intermittent failed requests, whose cause is still being checked. The scrolling XCTest reported zero hitch time but also zero measured frames, and Instruments currently lists the connected phone as offline; neither proves smooth rendered scrolling. On the iPhone Air, regular Release build 52 retained pairing and displayed the Goal sheet. Its notification switch turned off and re-registered; the host's push outbox recorded a delivered completion event for a synthetic QA conversation while the app was backgrounded. This proves provider acceptance, not a visible alert or tap-through. Final Release live viewing showed the selected main display, synthetic input reached only a dedicated TextEdit note, and Done returned control to view-only. Independent-network behavior, disconnect/reconnect, VoiceOver, and scheduler recovery remain open. Teaching a task and replaying taught tasks have been removed from the beta scope until verified.

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
