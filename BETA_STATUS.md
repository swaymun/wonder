# Wonder beta status

The signed Mac beta is available. Public TestFlight enrollment is not open yet.
Build 1.0 (50) is waiting for Apple’s external Beta App Review; the first group
is limited to 100 people.

Wonder connects native iPhone and iPad conversations to agents on your own Mac.
The Mac companion requires Apple Silicon. Follow [installation](INSTALL.md) for
the supported runtime, Tailscale, provider sign-in and pairing requirements.
Keep the Mac awake and online while using it remotely.

## Availability

| Component | Status |
| --- | --- |
| iPhone and iPad | Release 1.0 (50) is uploaded and processed. It is in the internal Owner Beta group and waiting for external Beta App Review in Public Beta. Installation of build 50 through TestFlight on the iPhone 11, notification delivery, and public enrollment remain unverified. |
| Mac companion | [Version 1.0.51](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.51-beta.1) is Developer ID signed, notarized, stapled and publicly downloadable. Its downloaded DMG matched the published checksum and installed on the development Mac; `/readyz` returned 200 with the installed ChatGPT Desktop runtime 0.155.0-alpha.16.3. A fresh-Mac install and signed automatic upgrade remain open. |
| Source | The reviewed MIT source is public at [swaymun/wonder](https://github.com/swaymun/wonder). Third-party components retain their own licenses. |

The [landing page, setup guide and privacy information](https://wonder-launch-preview.saimun-h-shahee.chatgpt.site) are public.

## Qualification still in progress

The iPhone 11 passed the focused approval-box tests and the permission/helper interaction session. Simulator regression checks and source CI also pass. These do not establish clean installation, production notification delivery, independent-network control, VoiceOver, physical performance or scheduler recovery. Those release gates remain open. Teaching a task and replaying taught tasks have been removed from the beta scope until verified.

## Beta limitations

- Initial setup requires both devices, Tailscale and access to the supported model provider.
- Model requests are sent to your provider. Wonder does not include a model subscription or credits.
- Remote access depends on the Mac being reachable. Tailscale may relay encrypted traffic when a direct connection is unavailable.
- Signed automatic Mac updates are implemented, including saved preferences and installation after work finishes. A genuine signed-version upgrade is still being qualified; the [signed manual download](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.51-beta.1) is available.
- Teaching a task and replaying taught tasks are unavailable in this beta.
- Notifications require permission and network access. Disabling notifications does not stop work on the Mac.
- Supported OS versions and verification evidence are different: simulator checks do not establish physical-device behavior on every supported model.

Release qualification is described in [RELEASING.md](RELEASING.md). The public
TestFlight link will be enabled only after approval and installation checks pass.

Use synthetic examples when reporting issues. See [security reporting](SECURITY.md)
before sharing any sensitive reproduction information.
