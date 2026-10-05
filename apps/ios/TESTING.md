# Wonder Testing for iPhone and iPad

Wonder Testing uses the same product source as Wonder, with a blue icon and its
own app identity. Install it beside orange Wonder, pair it separately with your
Mac, and use it for development checks. Local
pairing, Keychain access, preferences and drafts remain separate. Both clients
can still read and change the same conversations on the paired Mac.

| Channel | App ID | Display name | Icon |
| --- | --- | --- | --- |
| Production | `com.swaymun.wonder` | Wonder | Orange |
| Testing | `com.swaymun.wonder.testing` | Wonder Testing | Blue |

The Xcode `WonderTesting` scheme runs and archives the optimized `Testing`
configuration. Its tests use `TestingDiagnostics`, which includes the existing
bounded Diagnostics tools. Regular Testing uploads use Release behavior, without
the recorder. Each channel includes matching `.NotificationService`, `.Share`
and `.Widget` extensions. Share Keychain access and Widget snapshots are confined
to their own channel.

## Upload both channels

After every completed change to the shipped iOS app, including affected shared
code, run relevant checks and upload both Release channels sequentially. Both
uploads have standing owner authorization; no separate candidate approval is
required unless uploads are explicitly deferred. Documentation, source-sync and
tooling-only changes that do not alter the shipped app need no new binary.
Physical phone/tablet tests are optional for now and run only when explicitly
requested; use focused simulator checks by default.

```sh
bundle exec fastlane ios validate channel:testing
bundle exec fastlane ios beta channel:testing profile:release
bundle exec fastlane ios beta channel:production profile:release
```

Testing is the lane and archive script default. Each app has an independent
increasing build number. The existing API key is reused with the selected app ID;
no private key is copied into source. Serialize uploads across tasks, check each
app's latest build number and report its Apple processing status separately.
Upload authorization does not include beta-review submission or tester/group changes.
Do not install a production-identity Diagnostics build over the owner's orange app.
No Mac testing app is part of this workflow.

## Apple setup

Create one App Store Connect record for `com.swaymun.wonder.testing`, named
**Wonder Testing**, using iOS (which includes iPad). It is a separate app record,
not another version of the existing Wonder record.

Apple Developer needs the Testing app ID with Push Notifications enabled, plus
`com.swaymun.wonder.testing.NotificationService` and
`com.swaymun.wonder.testing.Share`, plus the new
`com.swaymun.wonder.testing.Widget` ID. Production has corresponding
`com.swaymun.wonder.NotificationService`, `.Share` and `.Widget` IDs. Share reads
the containing app's existing Keychain access group and never renews or writes
its saved connection. The app and Widget extension must both have their
channel's App Group capability: `group.com.swaymun.wonder.testing` for blue
Testing and `group.com.swaymun.wonder` for orange production. The Widget reads a
bounded saved Project-link snapshot there; names are generic until the user opts
in through Settings. No pairing credential or message text goes in the group.

Each ID needs an App Store provisioning profile saved in encrypted Match using
the existing Apple Distribution certificate. Existing app profiles must also
include their new App Group capability. Creating the Widget IDs, App Groups or
new profiles and renewing existing profiles requires explicit owner approval;
the normal upload lane remains read-only for signing assets. The Widget target
and separate group IDs compile in unsigned iPhone/iPad simulators; this does
not verify signed App Group access, Home Screen presentation or TestFlight upload.

For configured Widget simulator checks, inspect the installed app and Widget
extension with `codesign -dv --verbose=4` and `codesign -d --entitlements :-`.
Both must carry the same Apple Development team and the Testing App Group before
selecting a Project, checking the rendered Home widget, and tapping its link.
In the Xcode 27 `TestingDiagnostics` simulator build, setting a development
identity and profiles still produced ad hoc signatures with no team identifier;
that build could show Projects in the Widget editor but lost the selected App
Entity when WidgetKit loaded it. A QA copy signed with the existing Apple
Development identity and minimal Testing App Group entitlement resolved the
entity and rendered the selected Project. A passing snapshot unit test or
editor selection alone is not configured Widget acceptance.

The optional `testLiveOwnedProjectMediaPreviewWithoutSending` UI check requires
an owner-approved, temporarily paired Wonder Testing simulator, the exact owned
Project deep-link variables used by `liveOwnedProjectURL()`, and
`WONDER_LIVE_PROJECT_MEDIA=1`. Put a disposable `seekable.mp4` and `tone.m4a`
under a fresh, disposable Project-root folder; set
`WONDER_LIVE_PROJECT_MEDIA_FOLDER` to that exact name. The check opens video,
checks advancing playback, pauses and seeks from the start to about six seconds
on an eight-second clip, plays audio and returns to the composer without sending. Keep pairing
codes and result bundles under `.local/`, then remove the files and revoke the
exact simulator device in Mac Settings. Neither a skipped test nor a visible
player alone establishes playback acceptance.

The opt-in medium Recent Projects Widget UI checks require a disposable Wonder
Testing simulator with a synthetic App Group snapshot
(`project-widget-snapshot-v2.json`: the last-used Mac's ID, generic labels and
its Projects). Set `WONDER_WIDGET_RECENT_QA=1` and `WONDER_WIDGET_QA_DEVICE_NAME`
to that simulator's exact `SIMULATOR_DEVICE_NAME`; the tests skip on a different
device or the production app. The placement check changes the simulator Home
Screen; the Widget needs no configuration. The tap check opens a Project tile
(a new chat in that Project) and View computer (that Mac's screen). Afterwards
run `testRemoveMediumProjectWidgetAfterRecentChatQA` for the exact medium card
and restore that simulator's prior App Group snapshot. A direct deep-link test
alone does not verify the Home Screen tap.

Focused Project Files UI checks open Files inside the conversation, then a
file or diff in the same area. The composer stays available; Full screen and
Show in chat switch the preview presentation. Text selection opens a comment
editor, and Save stages an unsent comment. The `-workspace-large-text-preview`
Diagnostics fixture serves a 40 MiB text file in timed steps to verify the
loading progress row and the 128 KiB visible
preview bound on both iPhone and iPad. These fixtures do not send a message or
prove that a live provider receives an annotation.

`-project-running-elsewhere-preview` shows a Project turn that Claude or Codex is
running on the Mac: it reads as running, offers no Stop or Guide, and Send waits.
`-diagnostics-project-claude-tasks` (with `-diagnostics-project-subagents`) lists
Claude background commands and agents in the agent-task sheet. Live liveness comes
from Claude Code's busy record and the Codex rollout log on the paired Mac; these
fixtures do not exercise those Mac signals.

For explicitly requested physical QA, use the approved Testing development profiles. Set
`WONDER_APP_SIGNING_STYLE=Manual` and supply `WONDER_MAIN_PROFILE`,
`WONDER_PUSH_PROFILE`, `WONDER_SHARE_PROFILE` and `WONDER_WIDGET_PROFILE` to `xcodebuild` with the
`TestingDiagnostics` configuration. Test runners retain automatic signing and
can reuse an installed Xcode-managed development profile; this does not require
`-allowProvisioningUpdates` or new certificates.

## Share to Wonder

Recovered from the earlier Claude share-sheet work, the extension accepts text,
links, and up to four photos/files (8 MB each). Select a Mac and an existing Bot
or Group, add a note, then Send. The Testing extension is named **Wonder Testing**
in the system share sheet. If pairing has expired, open that same app to reconnect.
Retrying the same send while the sheet remains open retains the message identity.
Closing the sheet does not retain a durable send outbox. Projects are not yet
share destinations.

Read-only QA stages an image, loads chats and cancels without sending. Actual Send
starts model work and requires explicit authorization or an owner-performed test.

## Current limitation

The installed Mac and hosted notification service currently advertise only the
production app's APNs topic. Testing retains identity validation and cannot enable
notifications against that service. Chat, files and share-sheet reads can use the
same Mac. Testing notification delivery requires a separately configured service
and compatible host routing; the blue app alone does not provide it.

## Icon provenance

The blue icon was generated with the built-in ImageGen tool from the existing
orange app icon. Prompt: change only the palette to sky/cobalt blue, a pale icy-blue
background and navy facial features; preserve the smiling half-sun, five rays,
composition and texture; no text, badge or outer mask. The generated artwork was
resized to 1024 square for the app asset catalog. The orange source is unchanged.

## Progressive dictation

Wonder requires iOS/iPadOS 26 and uses Apple's `SpeechTranscriber` with
`SpeechAnalyzer` and the progressive-transcription preset. Where that module is
unavailable, Apple's `DictationTranscriber` uses its progressive-long-dictation
preset on older supported hardware/locales. The current keyboard
language selects the equivalent supported locale. Check `isAvailable`, locale
support and `AssetInventory` on the running device; OS support alone does not
establish hardware or model availability. Missing language assets are downloaded
through Apple's asset manager before capture starts. Preparation is visible and
can be cancelled with the mic. Only microphone permission is requested.

The mic turns blue while recording; tap it again to stop. The composer and
attachments stay visible. Long-press the mic (or use its accessibility action)
to cancel without accepting words. Send/Guide are disabled during preparation,
recording and finalization. Dictation never sends a message.

Finalized speech ranges accumulate once; revisions replace only the current
provisional phrase. The entire session remains a volatile UTF-16 projection in
the UIKit editor, separate from the saved draft. Stop ends audio input, drains
final results and accepts the displayed words once, with a two-second timeout.
Typing, cursor movement, navigation, backgrounding and audio interruptions keep
the displayed words immediately. Cancel restores the original text and selection.
Pairing changes and external draft replacement discard the projection. New-chat
commits flush before switching destinations. Sessions are bounded to ten minutes.

Dictation runs entirely on the iPhone/iPad. The Mac model picker, runtime,
recording upload and retry path have been removed. Unsupported devices/locales
show an actionable native-unavailability message. Failures preserve the last
visible words, and cancellation preserves the original draft. No new audio file
is saved. Existing legacy recording files and database rows are not deleted.
Audio conversion uses iOS 26 AVAudioConverter; recognition input is bounded and
overflow stops explicitly without silently dropping words.

`DictationTests` owns cumulative range/revision/deduplication and projection
contracts. `WonderDiagnosticsTests` extends real UIKit selection, durable drafts,
manual edits, late results, cancellation, backgrounding, interruptions, revocation
and finalization tests with multiple phrases. The progressive UI case in
`WonderUITests` uses the production mic stop/cancel controls and isolated composer
with an attachment on both iPhone and iPad. Real microphone permission/startup
checks reject all network requests, never using a live host or model request. The
background-preparation case delays native preparation, backgrounds and reopens the app,
then asserts that the late response cannot start recording or change the draft.
App-level background notification retires preparation even after an inactive
scene transition (which can also be caused by a permission sheet).

Injected words establish application behavior only. Simulator capability,
recording and UI checks do not establish device recognition quality or latency.
For the owner-run TestFlight check, insert multiple spoken phrases in the middle
of an existing draft, pause between phrases, then stop, cancel, type, move the
cursor and change conversations. Repeat with an attachment and in New chat.
Do not send. Test microphone denial, interruptions, unavailable language assets
and cancelling preparation. Record device/OS/locale and first-word time from
speech onset for at least five utterances where actual recognition works.

References: [Apple SpeechAnalyzer introduction](https://developer.apple.com/videos/play/wwdc2025/277/),
[asset management](https://developer.apple.com/documentation/speech/assetinventory),
and [Claude's documented start/stop dictation UX](https://support.claude.com/en/articles/12626668-use-quick-entry-with-claude-desktop-on-mac).
Claude's public instructions establish behavior, not its private speech model or implementation.
