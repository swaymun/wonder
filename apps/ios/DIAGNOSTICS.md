# iOS diagnostics

Wonder has one bundle identity and two optimized distribution profiles. Installing either profile preserves the existing pairing and app data.

| Profile | Scheme/configuration | Included behavior |
| --- | --- | --- |
| Release (default) | Wonder / Release | Product UI; no custom recorder, diagnostic UI, uploader, fixtures, or scenario runner |
| Diagnostics | Diagnostics / Diagnostics | Product UI plus bounded local recording, native signposts, MetricKit subscription, capture controls, and live tests |

`WONDER_DIAGNOSTICS` is independent of `DEBUG`. Both profiles use Release optimization and produce matching dSYMs in the archive, outside the installed app.

## Build and distribute

From the repository root:

```sh
bundle exec fastlane ios beta profile:diagnostics
bundle exec fastlane ios beta profile:release
```

Omitting `profile` selects Release. Credentials use the existing owner-only App Store Connect configuration. If the API key cannot perform distribution signing, `xcode_signing:true` explicitly selects the existing Xcode account for export signing; uploading still uses the API key.

Use the Diagnostics scheme for optimized simulator and development-signed device builds. `scripts/build-ios-performance.sh` builds the normal live app. It does not replace pairing with fixtures. The lane retains source revision, dirty source evidence, selected profile, dSYMs, symbol UUIDs, export, and processing results under `.local/`. Upload, Apple processing, and tester availability are separate outcomes.

Compare exported app bundles with:

```sh
python3 scripts/check-ios-profiles.py path/to/diagnostics/Wonder.app path/to/release/Wonder.app
```

## Recording and privacy

In a Diagnostics build, open Settings → Diagnostics. Lightweight recording is enabled initially and can be disabled. Start a detailed capture explicitly for foreground main-thread probes, display callback gaps, and separate resident-memory/physical-footprint samples. Captures end after two minutes or when the app backgrounds. No custom signal handler is installed.

The journal contains operation categories, durations, counts, byte counts, build/device/OS conditions, session IDs, numeric system metrics, and symbol UUID/offset frames. It excludes conversation text, prompts, tool output, credentials, filenames, and raw URLs. Encoding and batched persistence run on a utility queue. Phone storage is bounded to 20 MB and seven days. Interrupted sessions are labeled interrupted; only operating-system reports establish crashes.

Select a paired Mac for reports. Uploads use existing authentication, origin, and CSRF protections at `POST /api/v1/diagnostics/batches`. The Mac derives device identity from authentication, validates versioned batches up to 256 KiB, and deduplicates retries. Reports are separate from conversation history and Bot context, under the Wonder data directory's `diagnostics` folder, bounded to 200 MB and 14 days. No third-party telemetry service is used. An unavailable endpoint preserves bounded phone data and permits manual export.

Analyze a phone export or a Mac report directory:

```sh
python3 scripts/analyze-ios-diagnostics.py /path/to/diagnostics --json /path/to/metrics.json
```

Use `--session UUID` to isolate one run. Reports separate network, decoding, projection, and local interaction distributions (sample count, p50, p95, maximum). Chat-open and history request durations may include network work. Readiness and display-callback timings are proxies; they do not prove that a frame appeared. MetricKit delivery is delayed and supplemental, not a live dashboard.

## Repeatable verification

The Diagnostics section exposes 30 expansion cycles, a ten-minute live session, an interleaved recording-overhead comparison, Stop, and test-Bot cleanup. The runner navigates the actual paired conversation views and uses the same expansion actions. It sends no messages and uses the existing explicit Bot-creation endpoint, which does not start the normal New Bot model-backed onboarding turn. It creates and archives only its own read-only test Bot, retaining its idempotency key and identifiers until cleanup succeeds. Runner success verifies state changes and layout execution; it does not certify gestures.

Launch arguments for development tooling:

- `-diagnostics-scenario`: 30 live cycles plus test-Bot lifecycle.
- `-diagnostics-scenario -diagnostics-soak`: at least ten minutes and 30 cycles.
- `-diagnostics-scenario -diagnostics-compare`: 120 measured interactions per recording mode after warmup.
- `-diagnostics-fixtures`: deterministic large command, diff, and commentary renderers, plus the product composer attachment strip with synthetic photo/file inputs. Attachment removal here changes fixture state only.
- The **Turn lifecycle** fixture uses the shared timeline grouping and compaction marker with completed, running, stopped, failed, and unknown states. Visible activity segments for the authoritative running turn start expanded; the fixture also supports an offline terminal transition and manual reopen. `WonderUITests/WonderUITests/testDiagnosticsCompactionMarkersRemainVisibleAroundCollapsedActivity` checks visible markers and private-summary exclusion; `WonderUITests/WonderUITests/testDiagnosticsTurnLifecycleFixtureUsesAuthoritativeStatus` checks automatic expansion/collapse, manual reopen, and the single live spinner. Run the marker case at large Dynamic Type as well. These fixtures never send messages or trigger compaction/model work.
- Add `-diagnostics-stale-active` to `-diagnostics-fixtures` for the completed-canonical-refresh regression. It merges a cache-only older `inProgress` turn with a completed newest page and verifies the real conversation composer shows Send, not Stop response. The fixture is deterministic and never sends messages or starts model work.
- The **Command** fixture uses a long shell-wrapped command with a five-second duration and bounded, scrollable output. Add `-diagnostics-command-narrow` (220pt) or `-diagnostics-command-constrained` (150pt) to `-diagnostics-fixtures` for width checks, and `-diagnostics-command-short` when verifying that duration appears only beside a fully visible command. The two `testDiagnosticsCommandSummary*` XCTest cases verify that rule, maximum Dynamic Type, the untruncated accessibility label, and repeated expansion with raw command/output retained. No command is executed.
- `-diagnostics-fixtures -diagnostics-camera-capture`: exercises the product Camera sheet with synthetic image input and an isolated durable draft. The denied, unavailable, cancel, options, and limit Camera variants remain offline as well.
- `-diagnostics-fixtures -diagnostics-camera-physical`: uses the real camera and permission prompt with an isolated durable draft. Use only for explicitly authorized physical Camera XCTest. Capture attaches locally; it does not send a message, upload a file, or save to Photos. Check the initial half-height sheet bounds, capture and dismissal, cancellation, camera controls, and foreground recovery on the actual device. Simulator fixtures do not establish camera hardware acceptance.
- `-diagnostics-fixtures -diagnostics-permission-fixture`: exercises the shared approval menu with isolated local persistence, without changing any Bot or contacting a runtime. Add `-diagnostics-permission-auto-available` for all three enabled choices, `-diagnostics-permission-old-host` for the update state, or `-diagnostics-permission-reset` to clear only this fixture's saved selection on first appearance. The two `testDiagnostics*Approval*` XCTest cases cover selection, unavailable choices, and persistence across relaunch.

The `WonderUITests` target exercises live touch expansion and swipes using XCTest scrolling metrics, and independently exercises the large detail fixtures. It requires an unlocked, paired device with a real Wonder conversation. Missing pairing/data is a skip, not a pass. Simulator duration measurements are not physical-device hitch acceptance. `WonderDiagnosticsTests` covers storage, retries/export, host assignment, background suspension, and bounded image decoding; shared native tests cover flattened large activity histories.

Choose the physical session length using `AGENTS.md`: normally 1–3 minutes for localized rendering fixes, 3–5 minutes for loading/cache/concurrency/anchoring changes, and ten minutes for leaks, watchdogs, long-lived resource issues or broad timeline changes. Use the affected interaction, with 10–15 repetitions for small fixes and at least 30 for intermittent bugs or resource-lifetime changes. The ten-minute runner is available when warranted; it is not the default for every UI change.

Initial acceptance targets are local expansion/readiness p95 below 100 ms, no local interaction above 250 ms, actual scroll hitch time below 5 ms/s, and no watchdog/crash or sustained memory growth during the selected physical session. Check recording overhead when changing the recorder, adding high-frequency instrumentation or investigating recording cost; target less than 5% additional p95 latency after warmup on the same device and data. Preserve the actual device, session, duration, dataset, and measurement type with each result. Never substitute scenario or simulator results for physical touch/hitch evidence.

The optional `WonderUITests/WonderUITests/testLiveImagePreview` case expects a dedicated read-only Bot named `Diagnostics image preview` with a retained `Preview fixture 4000x3000.png`. Prepare that synthetic 12-megapixel file through the existing explicit Bot-creation and conversation-file upload APIs, retaining the created Bot ID for cleanup. The test sends no messages, opens the live verified image three times, and measures physical memory. Archive only that prepared Bot afterward. Without the fixture it skips explicitly.

`WonderUITests/WonderUITests/testLiveInlineImageScrolling` uses the paired `Wonder iOS` conversation with an existing working image. It expands the image's Working disclosure, scrolls to a fully visible preview, retains its stable accessibility identity, and measures ten sets of three scroll round trips. It collapses the disclosure afterward. `testLiveWorkingImageDisclosure` checks ten expand/load/collapse cycles and verifies that the image disappears when Working is collapsed. Both send no messages. Missing pairing is a skip; failure to reach the image is a failure. Retain exported image attachments and available screen recordings alongside the metrics, since row-position jumps can happen without a long frame stall. Diagnostics records image download and thumbnail decode durations separately, plus content-free cache-hit counts. Thumbnail tests cover fixed loading/failure geometry, revision and connection invalidation, deduplication, bounded work, cancellation and eviction.

## Bot startup and appearance regression

`WonderUITests/WonderUITests/testNewBotWaitsForPurposeQuestionBeforeShowingComposer`
uses `-read-preview -onboarding-preview`, adding `-onboarding-loading-preview`
for the waiting state. These offline fixtures exercise the real conversation
header, questionnaire, and composer; they never connect or start model work.
The test checks the initial Luna name and saved Luna/Ocean identity, centered
startup indicator, absence of the composer during initialization, and its
presence alongside the optional first question afterward.
Run it on iPhone and iPad. `BotStartupTests` in the native package covers the
host-scoped read-cache round trip, compatibility with caches lacking Bot metadata,
question arrival ordering, and stable varied defaults.

Evidence for the September 14 change is under `.local/bot-startup-*` in the main
checkout. Physical-device acceptance remains separate from these fixture checks.

## Avatar geometry and compact picker regression

`testDiagnosticsScienceAvatarsSelectPersistAndExposeMotionStates` exercises the
shared horizontal character/color picker, selected state, 44 pt color targets,
saved selection restoration, and motion using `-diagnostics-avatar-fixture`.
`testBotSettingsUsesCompactAvatarSection` opens the actual Bot settings Form
through a synthetic conversation and verifies the same compact section with no
large preview or Character/Palette subheadings. These tests send no messages or
Bot mutations. Run on iPhone and iPad, including large Dynamic Type.

`testBotAvatarSettingsMatchSavedIdentityAndSaveAcrossRelaunch` exercises the
actual Bot editor against an isolated synthetic host. It starts with a stale
unrelated draft, checks selection against the chat header, rejects the first save
with a conflict and asserts the immediately visible error alert,
restores the edited draft after relaunch, retries, and verifies character-only
and color-only updates after reopening and restarting. Its PATCH requests and
saved appearance remain in the `wonder.diagnostics.avatar-settings` fixture
suite; it never changes a real Bot or starts model work.

The daemon regression
`bot_management_tests::avatar_updates_persist_with_active_or_uncertain_work_and_unchanged_profile_fields`
checks real PATCH/GET persistence with queued, streaming and uncertain work,
including unchanged profile fields echoed by existing clients. Appearance saves
must succeed without changing the work state; actual profile/directory edits
and archive remain fenced. A synthetic client save alone does not verify this
host-side rule.

`testScienceAvatarRenderedCatalog` retains native light/dark comparison sheets
for all seven Violet avatars at 160, 32 and 48 pt. Inspect them against the SVG
preview; size assertions alone cannot detect broken crescent or ring geometry.
The geometry, large-text sizing and motion semantics tests remain required.
Run `generate-ios.py --check` and `test_generate_ios.py` in
`assets/bot-avatars/science` to verify source synchronization, SVG arc direction,
large arcs, relative/reflected curves and unsupported-feature rejection.

## Chat status and visible read regression

### Initial conversation layout

`testChatInitialLayoutKeepsMarginsBeforeFirstDrag` opens a cached conversation
ten times through the product Chats tab. `testChatInitialLayoutWithoutSavedPosition`
repeats five times without a saved anchor. Both compare the reply bounds before
and after the first short vertical drag, including the space above the composer.
Run both on iPhone and iPad for 30 opening/drag cycles.
These tests explicitly select the standard text size.
`testChatInitialLayoutAtAccessibilitySize` repeats the saved/unsaved cases at
an accessibility text size without inheriting the Simulator's last setting.

`testChatRestoresOlderReadingPositionAndReturnsToBottom` checks an older saved
reply, reopening on iPhone, the bottom button, and activity expansion/collapse.
These use `-diagnostics-chat-layout` with the existing isolated synthetic
transport, plus `-diagnostics-chat-layout-unsaved` or
`-diagnostics-chat-layout-older`. History is loaded before navigating so the
tests cover cached first layout, not only a network-delayed conversation.
No real chats, messages, or model work are involved.

`testChatStatusesAndVisibleReadRetryClearUnreadWithoutScrolling` runs the real
Chats/Conversation views against the synthetic transport with
`-diagnostics-subagent-fixture -diagnostics-read-status`. It shows unread,
working, and read rows; the first read request fails with 503 and the retry
clears unread without scrolling. Live replay is disabled only for this offline
transport. No messages or model work start. Run on iPhone and iPad alongside
`testChatContextMenuPreview`, which covers both chat lists and their menus.
`testChatListStatusPrioritizesWorkAndUsesFreshState` checks cold-list activity,
completed/active snapshots, and invalidated cached work. `ReadAcknowledgementTests`
preserves viewport, newer-unseen-message, host, and covering-sheet safeguards.

## Composer image paste regression

`WonderUITests/WonderUITests/testComposerImagePasteFromLongPressMenuPreservesDraftAndReloads`
uses `-diagnostics-fixtures -diagnostics-composer-paste` to copy a
synthetic PNG, invoke the system long-press Paste menu, and repeat attachment
creation/removal ten times. It also checks draft reload and ordinary text paste
using the product composer editor and durable attachment path. No messages,
uploads, or model work start. Run on iPhone and iPad; these offline fixtures do
not establish paired physical-device acceptance. The four `testImagePaste…`
diagnostics tests cover exact PNG preservation, multiple images, existing files,
atomic size/count/invalid-data rejection, delayed navigation/cancellation, and
text selection. The existing composer-preview UI test covers opening previews.

## File-change presentation regression

`WonderUITests/WonderUITests/testDiagnosticsFileChangeSummaryShowsFilenameCountsAndRetainsDiff`
selects the offline **Diff** fixture with `-diagnostics-fixtures -read-preview`. It checks the filename-only action summary,
spoken added/removed counts, a 44pt filename link opening the Files preview,
return navigation without toggling the diff, repeated disclosure, bounded code output, and maximum
Dynamic Type on iPhone and iPad. The fixture uses a 3,000-line synthetic patch and
never edits a file or sends a message. `FileChangeSummaryTests` covers saved payloads,
action states, legacy diffs and filenames independently of SwiftUI layout.


## Guide with canceled queued work

`-diagnostics-fixtures -diagnostics-cancelled-queue -read-preview -send-preview`
reproduces a running runtime turn followed by an undelivered canceled queue copy.
`testDiagnosticsCancelledQueueKeepsGuideAndWorkingState` checks one user bubble,
Working and Stop remaining visible, no spurious failure banner, continued activity
updates, and an enabled Guide action. It opens the menu but sends no Guide.
`testDiagnosticsLongFilenameKeepsChangeCountsOnTheSameLine` adds
`-diagnostics-file-long` to the Diff fixture and checks a long linked filename
shares the counts' baseline. Run both with the existing file-link and completed
refresh cases on iPhone/iPad; retain maximum Dynamic Type coverage.

## Optimistic approval settings and helper avatars

`testComposerApprovalChangesWithoutSavingIndicatorAndPersists` uses the actual
composer and helper roster against `-diagnostics-subagent-fixture
-diagnostics-optimistic-approval`. The synthetic PATCH waits 250 ms, writes only
the isolated `wonder.diagnostics.approval-settings` preference, and verifies
selection, absence of Saving text, helper sheet return, and persistence after
relaunch. `-diagnostics-approval-reset` resets only that fixture preference.
No real Bot, message, permission grant, or model work is involved.

`testBotPolishPhysicalSession` runs the same controls for at least three minutes
with at least 30 permission changes and 10 helper cycles on physical iPhone; Simulator explicitly skips.
This establishes physical touch behavior against a synthetic host, not live
network latency or frame hitch measurements. Keep it separate from paired-host
readiness and model behavior acceptance.

The eleven approval-related diagnostics tests cover immediate optimistic state,
Send/Guide fencing, navigation, coalescing, stale refreshes, failed and uncertain
responses, successful readback after a timeout, host replacement, and queued
revision conflicts. The rendered avatar catalog includes all seven grouped
marks at their actual 28pt size in light and dark. The existing helper sheet
cases also assert trailing pill placement, proximity, and a 44pt hit target.
