# Wonder beta status

The signed Mac beta is available. Public TestFlight enrollment is not open yet.
Apple shows iOS build 1.0 (50) as Approved for external testing, but the Public
Beta group has no testers and no public link. The planned first wave is limited
to 100 people; release qualification is still in progress.

Wonder connects native iPhone and iPad conversations to agents on your own Mac.
The Mac companion requires Apple Silicon. Follow [installation](INSTALL.md) for
the supported runtime, Tailscale, provider sign-in and pairing requirements.
Keep the Mac awake and online while using it remotely.

## Availability

| Component | Status |
| --- | --- |
| iPhone and iPad | Release 1.0 (50) is uploaded, processed and externally approved. New Goal and notification fixes are under test and require a later Release build. Notification delivery, the updated build's physical installation, and public enrollment remain unverified. |
| Mac companion | [Version 1.0.63](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.63-beta.1) is Developer ID signed, notarized, stapled and publicly downloadable. Its downloaded DMG matched the published checksum, and the live signed update feed matches the release. It is installed on the development Mac: `/readyz` returned 200, the previous Bots/messages/pairings remained, and Screen Recording and Accessibility remained allowed. A fresh-Mac install and an end-to-end automatic upgrade remain open. |
| Source | The reviewed MIT source is public at [swaymun/wonder](https://github.com/swaymun/wonder). Third-party components retain their own licenses. |

The [landing page, setup guide and privacy information](https://wonder-launch-preview.saimun-h-shahee.chatgpt.site) are public.

## Qualification still in progress

The iPhone 11 passed the focused approval-box tests, the permission/helper interaction session, and the Goal sheet test. A ten-minute Diagnostics session completed 214 live interaction cycles, and a physical scrolling XCTest measured 0 ms/s hitch time over ten iterations. The expansion-readiness proxy reached 203 ms at p95, and physical footprint rose toward 81 MiB; these need a repeat against the updated host before performance is accepted. On the iPhone Air, remote viewing followed the selected Dell display and returned to the main built-in display when the preference was cleared; an earlier dedicated QA-window input test and Stop Control succeeded. The final selected-display session did not repeat remote input because the QA note was not visible in the preview. Simulator regression checks and source CI also pass. Clean installation, production notification delivery, independent-network control, VoiceOver, and scheduler recovery remain open. Teaching a task and replaying taught tasks have been removed from the beta scope until verified.

## Beta limitations

- Initial setup requires both devices, Tailscale and access to the supported model provider.
- Model requests are sent to your provider. Wonder does not include a model subscription or credits.
- Remote access depends on the Mac being reachable. Tailscale may relay encrypted traffic when a direct connection is unavailable.
- Signed automatic Mac updates are implemented, including saved preferences and installation after work finishes. A complete automatic installation is still unverified; use the [signed Mac DMG](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.63-beta.1) if an update does not complete.
- Teaching a task and replaying taught tasks are unavailable in this beta.
- Notifications require permission and network access. Disabling notifications does not stop work on the Mac.
- Supported OS versions and verification evidence are different: simulator checks do not establish physical-device behavior on every supported model.

Release qualification is described in [RELEASING.md](RELEASING.md). The public
TestFlight link will be enabled only after the updated build and installation
checks pass.

Use synthetic examples when reporting issues. See [security reporting](SECURITY.md)
before sharing any sensitive reproduction information.
