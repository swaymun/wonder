# Wonder beta status

The public beta is in preparation. Public TestFlight enrollment is not open yet.
The first external testing group is planned for 100 people.

Wonder connects native iPhone and iPad conversations to agents on your own Mac.
The Mac companion requires Apple Silicon. Follow [installation](INSTALL.md) for
the supported runtime, Tailscale, provider sign-in and pairing requirements.
Keep the Mac awake and online while using it remotely.

## Availability

| Component | Status |
| --- | --- |
| iPhone and iPad | Release 1.0 (49), including boxed approval choices, is uploaded and processed. Physical TestFlight installation, external review and public enrollment remain pending. |
| Mac companion | Candidate 1.0.49 is notarized, stapled and installed on the development Mac with a healthy readiness check. Fresh-Mac and public-runtime qualification remain open; there is no public download yet. |
| Source | The reviewed MIT source is public at [swaymun/wonder](https://github.com/swaymun/wonder). Third-party components retain their own licenses. |

The [landing page, setup guide and privacy information](https://wonder-launch-preview.saimun-h-shahee.chatgpt.site) are public.

## Qualification still in progress

The iPhone 11 passed the focused approval-box tests and the permission/helper interaction session. Simulator regression checks and source CI also pass. These do not establish clean installation, production notification delivery, independent-network control, VoiceOver, physical performance or scheduler recovery. Those release gates remain open. Teaching a task and replaying taught tasks have been removed from the beta scope until verified.

## Beta limitations

- Initial setup requires both devices, Tailscale and access to the supported model provider.
- Model requests are sent to your provider. Wonder does not include a model subscription or credits.
- Remote access depends on the Mac being reachable. Tailscale may relay encrypted traffic when a direct connection is unavailable.
- Signed automatic Mac updates are implemented, including saved preferences and installation after work finishes. A genuine signed-version upgrade is still being qualified; candidate 1.0.49 does not include this change. Manual signed downloads remain an alternative.
- Teaching a task and replaying taught tasks are unavailable in this beta.
- Notifications require permission and network access. Disabling notifications does not stop work on the Mac.
- Supported OS versions and verification evidence are different: simulator checks do not establish physical-device behavior on every supported model.

Release qualification is described in [RELEASING.md](RELEASING.md). Download and
TestFlight links will be enabled only after their respective checks pass.

Use synthetic examples when reporting issues. See [security reporting](SECURITY.md)
before sharing any sensitive reproduction information.
