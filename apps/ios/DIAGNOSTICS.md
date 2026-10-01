# iOS diagnostics

## Current verification policy

Use focused unit/model/contract checks and simulator UI tests by default. Physical
iPhone/iPad sessions are optional for now and run only when explicitly requested;
they must not block completion or either TestFlight upload. Hardware-only cases
and the physical procedures below are references for those optional runs. Label
unexercised hardware behavior as unverified; retain separate simulator, scenario
and physical results. See [AGENTS.md](../../AGENTS.md) for the current workflow.

## Projects and creation

`testLiveProjectsSidebarAndDraftsStayReadOnly` uses an explicitly owned project
selected with `WONDER_PROJECT_ID` and `WONDER_PROJECT_NAME`. It checks search,
disclosure state, native conversation reopening, independent destination drafts,
and restoration after relaunch. `WONDER_PROJECT_CYCLES=30` exercises repeated
navigation; `WONDER_PROJECT_CAPTURE=1` starts the existing bounded two-minute
resource capture. Neither selection nor navigation sends a message. Retain the
actual observation window separately from the capture window.

Run it on iPhone and iPad simulators alongside the durable creation outbox, draft
restoration, and shared scene ownership diagnostics tests.

Wonder has separate Production and Testing identities, each with two optimized
distribution profiles. Testing is the default for development acceptance and
installs beside production. Changing profiles within one channel preserves its
pairing and local data; pairing and drafts are isolated between channels.

| Profile | Scheme/configuration | Included behavior |
| --- | --- | --- |
| Release (default) | Wonder / Release | Product UI; no custom recorder, diagnostic UI, uploader, fixtures, or scenario runner |
| Diagnostics | Diagnostics / Diagnostics | Product UI plus bounded local recording, native signposts, MetricKit subscription, capture controls, and live tests |

`WONDER_DIAGNOSTICS` is independent of `DEBUG`. Both profiles use Release optimization and produce matching dSYMs in the archive, outside the installed app.

## Build and distribute

Normal app changes upload Release builds to both channels as described in
[TESTING.md](TESTING.md). Use Diagnostics only when specifically requested:

```sh
bundle exec fastlane ios beta channel:testing profile:diagnostics
```

Omitting `profile` selects Release. Credentials use the existing owner-only App Store Connect configuration. Use existing Match/manual signing; do not fall back to an Xcode account or create profiles without explicit approval.

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

## Startup and reconnection

`testRootSceneSurvivesRepeatedLaunchAndForeground` exercises the real App and
WindowGroup with the existing isolated connections preview: ten cold launches
and twenty foreground returns. It catches failures outside individual view
fixtures, including the build 57 root-builder actor assertion. Keep app-owned
state reads outside WindowGroup's asynchronously evaluated content builder;
the builder returns a prepared view, whose body owns actor-isolated work.

`testPairedConnectionSurvivesRelaunchAndForeground` repeats the same lifecycle
against the explicit `WONDER_PAIRING_HOST_NAME` host. It checks connection
renewal without opening conversations, sending messages, or starting Bot work.
Missing pairing or unavailable XCTest automation is not a passed live check.
Retain OS crash reports and distinguish direct device launch checks from UI
automation and simulator results.

The three `testConnectionRenewal...` diagnostics tests use the existing synthetic
HTTP transport and an in-memory signing identity. They cover offline/DNS/timeout
feedback followed by successful renewal, stale background responses followed by
retry, and rejection of a different host without replacing saved credentials.

## Repeatable verification

The conversation uses one native reusable `List`, with stable message/activity
IDs and expanded activity children as separate rows. A variable-height
`LazyVStack` repeatedly alternated estimated content heights during large-text
scrolling; changing scroll anchors or disabling animation did not resolve it.
Keep a single virtualization owner rather than nesting a lazy stack inside a
list cell. Reading-position and read-receipt observation publishes only visible
IDs or visibility changes, not per-pixel frames.

Conversation UI tests select the `conversation-scroll` accessibility identifier,
independent of whether UIKit exposes it as a scroll view or collection view.
Native row controls can expose full-width accessibility tap targets: verify
visible padding using their label bounds, and retain the separate assertions for
saved positions, tall replies, bottom actions, and fully visible controls.

`testChatOpeningFramesStartAtTheIntendedReadingPosition` captures the first 1.5
seconds of the real conversation view at normal text size. It checks rendered
text for both a saved older reply and the default latest reply, including the
first readable frame. An ordinary UI query waits for idleness and can miss a
visible opening jump. Keep the transcript covered by its loading state until
the requested position is measured in the viewport; do not substitute a fixed
delay. Older-history paging starts after that initial positioning completes.
For opening regressions, run this focused check first. Reuse existing large-text
and lifecycle evidence when their product code is unchanged instead of repeating
the whole suite for test, documentation, signing, or packaging changes.

The Diagnostics section exposes 30 expansion cycles, a ten-minute live session, an interleaved recording-overhead comparison, Stop, and test-Bot cleanup. The runner navigates the actual paired conversation views and uses the same expansion actions. It sends no messages and uses the existing explicit Bot-creation endpoint, which creates its dedicated fixture with explicit settings. It creates and archives only its own read-only test Bot, retaining its idempotency key and identifiers until cleanup succeeds. Runner success verifies state changes and layout execution; it does not certify gestures.

Launch arguments for development tooling:

- `-diagnostics-scenario`: 30 live cycles plus test-Bot lifecycle.
- `-diagnostics-scenario -diagnostics-soak`: at least ten minutes and 30 cycles.
- `-diagnostics-scenario -diagnostics-compare`: 120 measured interactions per recording mode after warmup.
- `-diagnostics-fixtures`: deterministic large command, diff, and commentary renderers, plus the product composer attachment strip with synthetic photo/file inputs. Attachment removal here changes fixture state only.
- Existing Claude history can be replayed offline through the chat-layout fixture. Project the provider events into a native conversation snapshot, preserve stable turn/item IDs, and copy it to the Diagnostics app's `Documents/history-replay.json`. Invoke `WonderUITests/WonderUITests/testExistingClaudeSessionReplay` with `TEST_RUNNER_WONDER_HISTORY_REPLAY=1`. The app consumes and removes that fixture on launch; copy it again before another run. This opts into private local data; retain captures locally and never commit session contents. The test exercises the production conversation's expansion and scrolling without sending messages. Raw SDK image blocks do not substitute for daemon-validated authenticated attachments, and simulator interaction is separate from physical hitch acceptance.
- The **Turn lifecycle** fixture uses the shared timeline grouping and compaction marker with completed, running, stopped, failed, and unknown states. Visible activity segments for the authoritative running turn start expanded; the fixture also supports an offline terminal transition and manual reopen. `WonderUITests/WonderUITests/testDiagnosticsCompactionMarkersRemainVisibleAroundCollapsedActivity` checks visible markers and private-summary exclusion; `WonderUITests/WonderUITests/testDiagnosticsTurnLifecycleFixtureUsesAuthoritativeStatus` checks automatic expansion/collapse, manual reopen, and the single live spinner. Run the marker case at large Dynamic Type as well. These fixtures never send messages or trigger compaction/model work.
- Add `-diagnostics-stale-active` to `-diagnostics-fixtures` for the completed-canonical-refresh regression. It merges a cache-only older `inProgress` turn with a completed newest page and verifies the real conversation composer shows Send, not Stop response. The fixture is deterministic and never sends messages or starts model work.
- The **Command** fixture uses a long shell-wrapped command with a five-second duration and bounded, scrollable output. Add `-diagnostics-command-narrow` (220pt) or `-diagnostics-command-constrained` (150pt) to `-diagnostics-fixtures` for width checks, and `-diagnostics-command-short` when verifying that duration appears only beside a fully visible command. The two `testDiagnosticsCommandSummary*` XCTest cases verify that rule, maximum Dynamic Type, the untruncated accessibility label, and repeated expansion with raw command/output retained. No command is executed.
- `-diagnostics-fixtures -diagnostics-camera-capture`: exercises the product Camera sheet with synthetic image input and an isolated durable draft. The denied, unavailable, cancel, options, and limit Camera variants remain offline as well.
- `-diagnostics-fixtures -diagnostics-camera-physical`: uses the real camera and permission prompt with an isolated durable draft. Use only for explicitly authorized physical Camera XCTest. Capture attaches locally; it does not send a message, upload a file, or save to Photos. Check the initial half-height sheet bounds, capture and dismissal, cancellation, camera controls, and foreground recovery on the actual device. Simulator fixtures do not establish camera hardware acceptance.
- `-diagnostics-fixtures -diagnostics-permission-fixture`: exercises the shared approval menu with isolated local persistence, without changing any Bot or contacting a runtime. Add `-diagnostics-permission-auto-available` for all three enabled choices, `-diagnostics-permission-old-host` for the update state, or `-diagnostics-permission-reset` to clear only this fixture's saved selection on first appearance. The two `testDiagnostics*Approval*` XCTest cases cover selection, unavailable choices, and persistence across relaunch.

The `WonderUITests` target exercises expansion, swipes and large detail fixtures on simulators. Optional live/physical cases require the pairing, data and hardware specified by that case. Missing prerequisites are a skip, not a pass; do not make a hardware-only case part of default simulator acceptance. Simulator duration measurements are not physical-device hitch acceptance. `WonderDiagnosticsTests` covers storage, retries/export, host assignment, background suspension, and bounded image decoding; shared native tests cover flattened large activity histories.

When a physical run is explicitly requested, choose its length for the fix: normally 1–3 minutes for localized rendering fixes, 3–5 minutes for loading/cache/concurrency/anchoring changes, and ten minutes for leaks, watchdogs, long-lived resource issues or broad timeline changes. Use the affected interaction, with 10–15 repetitions for small fixes and at least 30 for intermittent bugs or resource-lifetime changes. Extend only when reproduction or unstable measurements warrant it. These are optional physical-run procedures, not default completion gates.

Initial acceptance targets are local expansion/readiness p95 below 100 ms, no local interaction above 250 ms, actual scroll hitch time below 5 ms/s, and no watchdog/crash or sustained memory growth during the selected physical session. Check recording overhead when changing the recorder, adding high-frequency instrumentation or investigating recording cost; target less than 5% additional p95 latency after warmup on the same device and data. Preserve the actual device, session, duration, dataset, and measurement type with each result. Never substitute scenario or simulator results for physical touch/hitch evidence.

The optional `WonderUITests/WonderUITests/testLiveImagePreview` case expects a dedicated read-only Bot named `Diagnostics image preview` with a retained `Preview fixture 4000x3000.png`. Prepare that synthetic 12-megapixel file through the existing explicit Bot-creation and conversation-file upload APIs, retaining the created Bot ID for cleanup. The test sends no messages, opens the live verified image three times, and measures physical memory. Archive only that prepared Bot afterward. Without the fixture it skips explicitly.

`WonderUITests/WonderUITests/testLiveInlineImageScrolling` uses the paired `Wonder iOS` conversation with an existing working image. It expands the image's Working disclosure, scrolls to a fully visible preview, retains its stable accessibility identity, and measures ten sets of three scroll round trips. It collapses the disclosure afterward. `testLiveWorkingImageDisclosure` checks ten expand/load/collapse cycles and verifies that the image disappears when Working is collapsed. Both send no messages. Missing pairing is a skip; failure to reach the image is a failure. Retain exported image attachments and available screen recordings alongside the metrics, since row-position jumps can happen without a long frame stall. Diagnostics records image download and thumbnail decode durations separately, plus content-free cache-hit counts. Thumbnail tests cover fixed loading/failure geometry, revision and connection invalidation, deduplication, bounded work, cancellation and eviction.

## Computer controls

Computer view keeps Refresh beside More and exposes its live/unavailable status
through the green/red dot's accessibility value. The Mac-name picker switches
only the computer viewer: it closes the previous receiver and releases its
control lease before opening a host-level view on the selected saved connection.
The presenting chat and its draft stay on their original connection.

While control is active, the upper row shows icons and sends the default macOS
All windows, App windows and Next window shortcuts. Command-Tab opens the native app switcher
and holds Command. Tab moves through it; another Command-Tab tap or Return
chooses the highlighted app, Escape cancels, and clicking an app releases Command.
Clicks first move the native pointer to the target while Command is still held.
Other shortcuts, text entry and clipboard actions cancel the switcher first.
Done, backgrounding, disconnect and host changes use the existing release-all
lease cleanup. Apps/Launchpad is not exposed because the input protocol does not
support its Fn modifier. These defaults can differ from customized Mac shortcuts.

`testComputerAppSwitcherHoldsCommandUntilSelectionOrCancellation` owns the ordered
held-key contract. The existing computer UI fixtures check both 44-point control
rows, native keyboard use, unavailable status and zoom, while
`testDiagnosticsComputerPickerSwitchesHostsAndReleasesControl` checks two saved
hosts, held-switcher cleanup and same-host reselection. Run the focused fixtures
on iPhone and iPad, including the largest accessibility text size. Fixtures do
not prove that a real Mac's app switcher or customized shortcuts respond.

## Bot startup and appearance regression

`testConnectedAppsKeepNamesAndIconsAcrossFamilies` uses the existing synthetic
transport via `-diagnostics-connected-apps`. It checks repeated provider switches,
normalized names, light mode and dark mode with large Dynamic Type on
iPhone and iPad. `testConnectedAppAssetsAreAvailableOffline` verifies the bundled
icons load in both appearances. Neither test contacts connectors or starts model
work. Bridge tests separately own prefix removal and resolved model labels while
preserving selection and permission identities.

`BotStartupTests` covers legacy read-cache decoding, durable first-send model
revision and stable avatar identities for existing Bot conversations. Physical
and live paired-host acceptance remain separate from fixture checks.

## Avatar geometry regression

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
The geometry and motion semantics tests remain required.
Run `generate-ios.py --check` and `test_generate_ios.py` in
`assets/bot-avatars/science` to verify source synchronization, SVG arc direction,
large arcs, relative/reflected curves and unsupported-feature rejection.

## Conversation layout and visible read regression

### Initial conversation layout

`testChatInitialLayoutKeepsMarginsBeforeFirstDrag` opens a cached conversation
ten times through the synthetic layout fixture. `testChatInitialLayoutWithoutSavedPosition`
repeats five times without a saved anchor. Both compare the reply bounds before
and after the first short vertical drag, including the space above the composer.
Run both on iPhone and iPad for 30 opening/drag cycles.
These tests explicitly select the standard text size.
`testChatInitialLayoutAtAccessibilitySize` repeats the saved/unsaved cases at
an accessibility text size without inheriting the Simulator's last setting.

`testChatRestoresOlderReadingPositionAndReturnsToBottom` checks an older saved
reply, the bottom button, and activity expansion/collapse.
These use `-diagnostics-chat-layout` with the existing isolated synthetic
transport, plus `-diagnostics-chat-layout-unsaved` or
`-diagnostics-chat-layout-older`. History is loaded before navigating so the
tests cover cached first layout, not only a network-delayed conversation.
No real chats, messages, or model work are involved.

`ReadAcknowledgementTests` preserves viewport, newer-unseen-message and host
safeguards.

`testProjectThreadReadMenuAndVisibleAcknowledgement` uses
`-diagnostics-subagent-fixture -diagnostics-chat-layout
-diagnostics-chat-layout-unsaved -diagnostics-project-read` to exercise twelve
read/unread menu cycles without opening the thread, then automatic reading of
its latest visible reply. It also checks that explicitly marking an open iPad
thread unread stays set. The fixture renews only a synthetic connection with an
in-memory signing identity; it never changes real pairing or starts model work.
Run on iPhone and iPad, including large text. The two Project-read diagnostics
tests own request failures/retries, persistence across relaunch and stale-refresh
fencing. Synthetic physical-device interaction and live paired-host acceptance
are separate evidence.

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

`testDiagnosticsGoalPillAndSheetAtAccessibilitySize` exercises the Goal pill
beside the agent pill on iPad with an open keyboard and large text. It checks
the half sheet, pause/resume, objective and budget editing, removal confirmation,
and preservation of the parent draft. `testDiagnosticsGoalPillAndSheet` covers
normal iPhone text size. The synthetic Goal fixture uses the product conversation
view and never starts model work; physical paired-host Goal continuation and
enforcement remain separate checks.

`testComposerApprovalChangesWithoutSavingIndicatorAndPersists` uses the actual
composer and helper roster against `-diagnostics-subagent-fixture
-diagnostics-optimistic-approval`. The synthetic PATCH waits 250 ms, writes only
the isolated `wonder.diagnostics.approval-settings` preference, and verifies
selection, absence of Saving text, helper sheet return, and persistence after
relaunch. `-diagnostics-approval-reset` resets only that fixture preference.
No real Bot, message, permission grant, or model work is involved.

The optional `testBotPolishPhysicalSession` runs the same controls for at least three minutes
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
