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
| iPhone and iPad | Release 1.0 (48) is processed and available to internal testers. External review and public enrollment are pending. |
| Mac companion | The final signed download is undergoing installation and compatibility checks. |
| Source | The reviewed MIT source release is being prepared. Third-party components retain their own licenses. |

## Beta limitations

- Initial setup requires both devices, Tailscale and access to the supported model provider.
- Model requests are sent to your provider. Wonder does not include a model subscription or credits.
- Remote access depends on the Mac being reachable. Tailscale may relay encrypted traffic when a direct connection is unavailable.
- Updates to the Mac companion use signed downloads; automatic updates are unavailable in this beta.
- Notifications require permission and network access. Disabling notifications does not stop work on the Mac.
- Supported OS versions and verification evidence are different: simulator checks do not establish physical-device behavior on every supported model.

Release qualification is described in [RELEASING.md](RELEASING.md). Download and
TestFlight links will be enabled only after their respective checks pass.

Use synthetic examples when reporting issues. See [security reporting](SECURITY.md)
before sharing any sensitive reproduction information.
