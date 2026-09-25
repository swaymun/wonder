<p align="center">
  <img src="apps/ios/Wonder/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="88" alt="Wonder sun icon">
</p>

<h1 align="center">Wonder</h1>
<p align="center"><strong>Your Mac’s agents, on your iPhone and iPad.</strong></p>
<p align="center">Keep a conversation going, review a request, or check your Mac from your phone.</p>

<p align="center"><a href="https://github.com/swaymun/wonder/releases/download/mac-v1.0.67-beta.1/Wonder-1.0.67.dmg">Download the signed Mac beta</a> · <strong>TestFlight — public invite pending</strong> · <a href="INSTALL.md">Setup guide</a></p>

<p align="center"><img src="assets/screenshots/conversation.png" width="280" alt="Wonder’s native conversation and grouped moon helper icon, shown with sample content"></p>

Wonder is a native iPhone and iPad messenger for agents running on your Mac. Give
work to a Bot, bring Bots together in a Group Chat, and return to the same
conversations, files, and decisions later. Your Mac hosts Wonder; your devices
connect through your own Tailscale network.

**The signed Mac beta is available.** External TestFlight enrollment opens after
Apple’s review and device qualification. Source builds are available from this
repository. [Release qualification](RELEASING.md).

## Keep your work with you

| Follow the helpers | Requests you can act on |
| --- | --- |
| <img src="assets/screenshots/agents.png" width="280" alt="A helper roster with grouped moon symbols matching the parent Bot"> | <img src="assets/screenshots/approval.png" width="280" alt="A request to save a Saturday plan with Allow once, Allow for this session and Decline controls"> |
| See each helper’s status above the composer, then open its work without leaving the parent conversation. | Review the requested action and choose how much permission to grant. |

Answer questions and review approval requests from your phone. Permission choices
remain explicit, with server-confirmed settings applied before work starts.

**Remote screen access:** view your Mac and, with permission, control it from Wonder. Screen/control recovery qualification remains part of the beta checks.

Screenshots use demo content in Wonder’s native views. They contain no personal
conversations. [Screenshot provenance](assets/screenshots/README.md).

## Set up your Mac and phone

You need an **Apple Silicon Mac**, an **iPhone or iPad**, a supported **ChatGPT
Desktop runtime**, and **Tailscale on both devices**. Wonder’s deployment targets
are macOS 14 and iOS/iPadOS 17; see the [supported configuration](INSTALL.md#requirements)
for the tested combinations and exact runtime requirement.

1. Install the supported runtime and sign in to your model provider.
2. Connect your Mac and phone to the same Tailscale network.
3. Install Wonder on both devices, scan the Mac’s pairing code, and confirm on the Mac.

[Follow the setup guide →](INSTALL.md)

## Your Mac hosts Wonder

- **No Wonder account.** Pairing requires your confirmation on the Mac. Joining
  the tailnet alone does not grant access to your conversations or computer.
- **Local history and files.** Wonder stores conversations and attachments on
  your Mac, with local copies on paired devices. Agent requests and any content
  needed for them go to your chosen model provider under that provider’s terms.
- **Your network.** Tailscale carries the connection; screen sharing uses direct
  WebRTC. Wonder operates no chat or screen relay. Tailscale may use its encrypted
  relay fallback.
- **Optional notifications.** Replies, approvals, and questions can show encrypted
  previews, subject to your iPhone’s preview settings. Wonder suppresses alerts
  while the app is in the foreground. The push service forwards ciphertext and
  retains device tokens, authorization records, and limited delivery metadata;
  it does not receive plaintext previews, files, or screenshots.

Wonder has no subscription or model credits. Model access and any Tailscale plan
are your responsibility. The official TestFlight app uses Wonder’s push service,
including with a source-built Mac host. If you sign your own iOS app, you need
[your own Apple push configuration and Worker](services/push/README.md).

## During the beta

Keep the Mac awake, online, and running Wonder for new work and remote access.
The Mac companion offers signed automatic updates, with checks and downloads
controlled in Settings. Installation waits for work and computer sharing to finish.
Automatic-upgrade qualification is still in progress; signed manual downloads
remain an alternative. iPhone and iPad updates use TestFlight.
Runtime compatibility is deliberately checked; an unsupported runtime will not
run agent work. Teaching a task and replaying taught tasks are unavailable in
this beta. Remaining device and recovery checks are tracked in the release status.

[Build from source](DEVELOPMENT.md) · [Security reporting](SECURITY.md) ·
[Release process](RELEASING.md) · [MIT license](LICENSE) ·
[Third-party notices](THIRD_PARTY_NOTICES.md)
