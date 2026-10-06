# Wonder beta status

The signed public Mac beta remains available. On October 4, Wonder Testing
Release 1.0 (31) uploaded, processed and passed the read-only lane check
for automatic Owner Beta availability. Production Release 1.0 (88) uploaded
and processed successfully. TestFlight installation and production tester
availability remain unverified. Mac 1.0.111 is signed, notarized and installed
locally with Mac dictation removed. No external beta review, public enrollment
or new public Mac binary release was requested.

Wonder connects native iPhone and iPad conversations to agents on your own Mac.
The Mac companion requires Apple Silicon. Follow [installation](INSTALL.md) for
the supported runtime, Tailscale, provider sign-in and pairing requirements.
Keep the Mac awake and online while using it remotely.

## Availability

| Component | Status |
| --- | --- |
| iPhone and iPad | Production Release 1.0 (95) uploaded and Apple reports processing complete. Built from clean, pushed source (`797c1ebf`) with Diagnostics fixtures absent from the exported binary. Tester availability and TestFlight installation remain unverified. |
| Wonder Testing | Blue Release 1.0 (38) uploaded, processed and available in automatic Owner Beta. Built from the same clean source as production 95. TestFlight installation remains unverified; pairing, drafts and Keychain access stay separate from production. |
| Mac companion | [Version 1.0.101](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.101-beta.1) remains the public download. Local 1.0.122 (redesigned Settings with an automatically refreshing pairing code and a single named main display in the screen menu) is Developer ID signed, notarized, stapled, Gatekeeper accepted and installed; `/healthz` and `/readyz` passed after install. Settings pages were checked against a local test bridge, and General on the installed app. Fresh-Mac pairing and private-permission acceptance remain open. |
| Source | Reviewed MIT source is at [swaymun/wonder](https://github.com/swaymun/wonder). Both current iOS archives came from the same clean, pushed source; all 614 selected public source files matched bytes and executable modes. Third-party components retain their own licenses. |

Testing 37, production 94 and Mac 1.0.119 add new Claude chats started in Wonder to the Claude desktop app, deliver messages sent from Wonder to a Claude session started on the Mac (a leftover task notice no longer ends the turn early) and hold them while that chat is open in Claude on the Mac; Send now closes the idle desktop chat first, list Claude agent tasks (including
those launched before a compaction), keep earlier Claude turns after a
compaction, render Claude's Bash and file edits like Codex and collapse its tool
work into one group. Desktop runs show within seconds, including the sidebar
spinner; a message sent meanwhile waits on the Mac and is delivered when that
turn finishes. Files offers Comment in the selection menu for text, HTML source
and PDFs, downloads with a cancellable progress ring, and edited files open from
a pill as numbered unified or side-by-side diffs. Chat bubbles render Markdown,
and the Recent Projects widget needs no configuration. Evidence is from
iPhone/iPad simulators with offline fixtures; live use with a paired Mac and real
devices remains to be checked.

Testing 32, production 89 and Mac 1.0.112 add the October 4 review fixes:
Files replaces an open saved-diff review; saved diffs capped by the host are
labeled as partial; Files opened from Bot chat Details closes with Done; chats
stay at their end through composer notices and new messages; the Files header
fits large text, hidden files can be shown inside folders, and closing a preview
returns to its row. Workspace previews now stream up to 256 MB with load
progress (the Mac host must be 1.0.112). GitHub pull-request review was removed
at the owner's request; Mac migration 0088 deletes saved repository grants.
Evidence is simulator-only (iPhone 17 Pro and iPad Pro 13-inch, iOS 26.5, offline
fixtures); real Wi-Fi transfer of large files, hardware keyboard and VoiceOver
remain unverified.

Native-only progressive dictation is included in Testing 31 and production 88,
built from clean internal `0980b910` and corresponding public source `11ccabb`.
Wonder requires iOS/iPadOS 26. It uses SpeechTranscriber where supported and
Apple's DictationTranscriber for older supported devices/locales, both through
SpeechAnalyzer. The mic turns blue while listening; tapping again stops and keeps
all accumulated phrases. The composer and attachments remain visible. Provisional
words stay separate from the saved draft until committed.

The paired-Mac recorder/upload/retry path, model picker, Mac setup step, speech
worker and installer are removed. Existing drafts, attachments, database history
and legacy recordings are preserved. No new recording files are saved. Unsupported
native speech offers keyboard-microphone recovery instead of a Mac setup choice.
Mac 1.0.111 also removes the retired speech worker and model installer from its package.

Nine focused checks passed on each iPhone 17/iPad A16 simulator. Eight shared
speech/composition cases, 355 host cases, 158 storage cases, four desktop cases
and 11 setup cases passed; one host test remains ignored. Both simulators reported
native recognition unavailable. Injected multi-phrase results verify composer,
selection, cancellation, manual edits, attachment and stale-result behavior; they
do not establish hardware speech accuracy or first-word latency. Physical native
recognition and language-asset behavior remain for owner-run TestFlight acceptance.
Both signed Release exports include both Apple transcribers and exclude diagnostic
fixtures and the removed ASR upload path. See [progressive dictation testing](apps/ios/TESTING.md#progressive-dictation)
and [speech startup regression](apps/ios/DIAGNOSTICS.md#speech-startup-regression).

Completed responses now show their edited files below the answer, with added/removed
line counts and selectable colored saved diffs. The composer remains available.
Current workspace diffs identify staged versus unstaged changes. Eight native
model checks and four focused iPhone/iPad simulator checks passed, including
landscape and Accessibility XXXL. These changes are included in Testing 26 and production 84, both uploaded and
processed from clean internal `1bdd5e1b` and matching public source `2f59da0`.
Both exported Release apps exclude the edited-files diagnostic fixture.
TestFlight-installed interaction remains unverified.

The chronological qualification notes below retain the limits of earlier checks.
The October 4 releases include the later Settings and
Project Apps recovery and local edited-files source. Simulator checks include iPhone/iPad landscape;
actual TestFlight-installed behavior remains unverified.

The earlier Mac 1.0.110 qualification kept the native host, menu bar and Settings. Its Settings uses the
original sun icon, a restrained yellow/apricot sidebar and warm light/dark colors,
shorter readiness and Access copy, and one automatic-update policy in About.
The redundant provider-check and restart controls and desktop Chats are removed.
The installed host is ready, preserves Project IDs. (GitHub review support was later removed in 1.0.112.) Global Codex Usage/Apps and scoped Project Files reads pass; unloaded
Project Apps now returns the specific unavailable response. Manual update checking
completes with “No newer compatible update is available.” The disconnected Tailscale check showed reconnect recovery; a later read-only
check found Tailscale Running and Settings Ready. No new privacy grant or live
model turn was made. The previous 1.0.110 DMG remains local:
SHA-256 `20e02c529729729f4d9ae1fce075dc5b4bdac6fb7e2508d9d350ad4cf68c363c`.
Notarization was accepted, and staple, Gatekeeper and payload checks passed.
The installed 1.0.110 helper now distinguishes disconnected Tailscale from a
sign-in requirement; actual Stopped state shows reconnect recovery with no
advertised origin. Installed health/readiness checks passed and Project IDs
were preserved.

Testing 24 adds New Chat preview notes to the unsent composer and binds them
to the first Project message after prepare-only thread creation. Notes can be
edited or removed, survive relaunch, and warn before a folder switch removes
them. Native Projects and Files checks passed 2/2 and 8/8; the offline
annotation flow passed 1/1 on iPhone 17 and iPad Pro 13-inch M5 simulators,
with screenshots inspected. The signed Release archive came from clean
internal commit `016cea22` and corresponding public source `c99c7c0`.
Apple processed build 24, and the upload lane plus an independent read-only
check confirmed automatic Owner Beta availability. The archive, upload and
matching dSYM evidence is under
`.local/testflight-testing-24-20261004T025633Z-98abdb/`.
No live provider first send or TestFlight-installed interaction was tested;
the artifact annotation acceptance gate remains open. Production remains 82
under the owner's Testing-only checkpoint request.

Testing 23 clarifies the saved Project history shown when a desktop-owned task
continues beyond Wonder's last recorded turn. An interrupted activity row now
reads “Earlier response interrupted,” and its compaction marker reads “Context
compaction interrupted.” The native checks passed 2/2; the visible Project
fixture passed 1/1 on each iPhone and iPad simulator, with screenshots
inspected. Codex desktop reported the exact task active while Wonder's separate
App Server saw an older interrupted turn. These labels do not report live
desktop Running. A supported, fresh status source is still needed. Production
82 retains the older wording, and installed Testing 23 interaction is unverified.

An October 3 follow-up addresses the owner's Files and helper
screenshots. Project helper rows now distinguish unknown, waiting, failed and
last-known states; focused host/native tests and a stale-roster UI check passed
on both simulators. Files uses the conversation area and bottom toggle in both
Project conversations and New Chat, with a compact Workspace/hidden-file
control and quiet background refresh. Focused in-chat Files, preview/diff and
paginated refresh checks passed on iPhone and iPad, including an overlap where
the user taps Load more during a delayed refresh. iPhone 17 Pro Max also kept
the Project draft and Chats sidebar through portrait-landscape-portrait. The
Wonder Testing Release simulator build and testing-lane validation passed. The
Testing 22 includes these source changes, including the scoped “This response
stopped” wording; its installed behavior has not yet been observed.
A truthful live status for a Codex desktop-owned turn needs a supported shared
status source. New Chat preview notes, genuine iPad two-app Split View and
iPhone Duo pose testing remain open.

An additional host-only helper fix follows up to ten provider list pages when
checking a verified Project task's archive state. A focused test passed for a
child on page two and for a repeated cursor returning unavailable. The visible
roster still stops at 100 tasks. This source is not installed in Mac 1.0.108;
Testing 22 includes the iOS client, while production 82 and Mac 1.0.108 remain
unchanged. Another Device Hub attempt did
not establish two visible iPad app panes, so Split View remains unverified.

A subsequent Project helper slice adds paged roster loading for
older verified current and archived tasks. The client keeps loaded older rows
when the first page refreshes, marks rows not refreshed as “Last known,” and
preserves paging during first-page refresh, and stops on a repeated provider
cursor. The roster stops after ten pages per archive state, matching the
host's transcript verification bound, and explains that limit if more exist.
Host ownership tests passed 2/2, native
wire parsing passed 1/1, and the paged roster plus interleaved refresh/cursor
loop checks passed 2/2 on both iPhone and iPad simulators. Concurrent request
timing remains unforced by those fixtures. The iOS client is in Testing 22;
production 82 and Mac 1.0.108 do not have it. The provider-side desktop Running
relay is still unresolved; a historical “Stopped” entry in Testing 21 is not evidence
that the current desktop turn has stopped.

The October 3 post-checkpoint composer hardening is verified in source and
signed TestingDiagnostics simulator builds and is included in Testing 22, but
not production 82. With a large staged attachment, draft edits now persist a
small text overlay instead of encoding and atomically replacing the attachment
bytes on every keystroke. The overlay is tied to the base intent file identity
so an interrupted cleanup cannot restore text after a committed Send; file
request encoding moves off the UI actor. Native intent and transport tests
passed 25/25, the focused durable reload UI test passed 1/1 on each iPhone
and iPad simulator, and `fastlane ios validate` passed. This has not been
measured as a typing-latency improvement on physical hardware. PDF document
parsing on preview open or revision is still on the main actor and remains a
measured performance gate.

A separate post-checkpoint PDF failure fix is also in Testing 22. A malformed
PDF now shows a readable error on initial open or after an updated revision,
instead of a blank or stale page. The focused invalid-PDF UI test and the
existing valid image/PDF revision test each passed 1/1 on iPhone 17 and iPad
Pro 13-inch M5 simulators (iOS 26.5). The invalid-file error also passed at
Accessibility XXXL on both; its final screenshots were inspected. The malformed
file fixture has a PDF header but no renderable page,
matching the gap between content-signature validation and PDFKit parsing.
Production 82 does not contain this correction. Testing 22 installation remains
unverified.

A replacement Mac companion, 1.0.108, has been signed, notarized, stapled and
installed over 1.0.107 on the owner's Mac. The same verified DMG installed and
first-launched on a clean second Mac; both reached `/readyz`, including after a
restart. The public download remains 1.0.101 while fresh-Mac phone pairing,
private permissions and existing-draft upgrade behavior await acceptance.

The 1.0.101 update preserves the installed Mac's project chats and pairing. It
loads shared model options through the normal project runtime and starts the
private Bot runtime only when a Bot exists. The daemon and transport suites
passed 324 tests, with three existing tests ignored; strict Clippy and isolated
missing/mismatched-runtime restart checks passed. Opening an existing project
chat passed without creating private Bot folders or starting model work. A signed
1.0.78→1.0.79 automatic upgrade previously completed on this Mac; version 1.0.101
was installed through the signed local installer. Fresh-Mac setup remains unverified.

The [landing page, setup guide and privacy information](https://wonder-launch-preview.saimun-h-shahee.chatgpt.site) are public.

## Agent workspace qualification

The current source passed the daemon library suite (327 passed, 3 existing
ignored), store (159 passed), desktop (55 passed), host (17 passed), native
pairing (246 passed, one expected skip), Computer View (8 passed), and Mac
menu bar (36 passed). Focused iPhone and iPad simulator runs covered Project
controls, Automations, questions, subagent pills, Files and diffs, annotation
selection and revision recovery, EPUB and common bounded 3D previews, deep
links and Widget snapshots. A final delayed Files/Git/diff navigation regression
passed 2/2 on each simulator. Signed Release archives for both channels passed
main app and Widget identities, entitlements, bundled notices, and symbol export.

The Mac 1.0.108 replacement DMG passed signature, notarization, Gatekeeper,
local upgrade and clean second-Mac first launch; both installed copies reached
`/readyz`. Its public release remains gated as stated above. An accepted
annotation now dispatches its frozen source copy even after an unrelated
Project root change, verified by a fake-provider regression. On the installed
1.0.108 Mac, an isolated read-only Project thread completed a live Codex turn,
then a Project Automation claimed its scheduled run and completed a second turn.
Its durable message, native turn and assistant reply were verified. The
Automation was deleted and only its disposable thread was archived afterward.
This verifies the installed host's scheduled execution path; paired iPhone and
iPad interaction with that path remains unverified.

A post-upload review found retry and stale-response cases in these binaries:
some Project sends can remain uncertain after a definite pre-execution failure,
and a late New Chat error after re-pairing the same Mac can disturb the current
draft. Rapid PDF page turns can overlap preview work, and long Project history
scans can delay update handoff or miss receipts beyond 20,000 items. The Mac
install helper checks process health after replacement; these two installed
copies were also checked manually for `/readyz`. Source corrections and focused
iPhone, iPad, daemon and installer checks are complete. The iOS corrections
are in Testing 21; production 82 and Mac 1.0.108 still need later releases.

Native progressive dictation had no supported SpeechTranscriber locale on the
tested iOS 26.5 simulators, so the existing dictation path remains in place.
EPUB and read-only USDZ/OBJ/PLY/STL viewers passed focused checks, while
repeated SceneKit conversion retained measurable memory; broader GLB support
remains at a research gate. Configured small Widget presentation and new-chat
taps, plus medium recent-chat presentation and taps, pass on both simulators
with a team-signed Testing QA copy. The medium tap opened an existing Project
conversation with its composer. Paired live-Project Widget routing,
mobile-to-Mac provider-send roundtrips, and installation of this source
through TestFlight remain unverified. Paired read-only Files, PNG/PDF previews,
audio/video playback and seeking, and an unsent preview note passed on both
simulators as described below.

After the upload cap, the open Files list gained event-driven refresh with a
bounded retry, a manual Refresh control and a fence for a workspace root that
changes path under the same ID. The selected preview stays open through a
message send. The latest signed Diagnostics UI runs passed 6/6 each on iPhone
and iPad, including an accepted synthetic send, a failed-read retry, the
replacement-root case, HTML reading-position retention and a script-blocked
HTML preview. An out-of-order annotation download regression passed 1/1 on
each simulator; the composer keeps the newest stale-source warning. These are
synthetic checks of source included in Testing 21. A paired live edit and
provider send, installed TestFlight interaction and physical-device behavior
remain open.

A final review found that authorization or missing-resource responses during
Files refresh could leave previously listed rows available. The browser now
clears cached roots, directory and Git rows in those cases; transient failures
retain rows with retry feedback. Synthetic revocation after the initial list
loaded, transient retry and same-ID root replacement passed 5/5 focused UI
checks on each simulator, with no skips. The fix is included in Testing 21;
installed behavior remains unverified.

A compact full-screen iPad mini check found that a PDF annotation page shrank
to 126 points at Accessibility XXXL with the keyboard open, even though the
larger iPad Pro passed. Source now gives the page more room while typing and
provides a visible Done action to restore page navigation and whole-page/image
selection. The existing focused PDF UI check passed on iPad mini, iPad Pro and
iPhone (1/1 each); the shared image-region check passed on iPad mini (1/1).
Files/diff, full-screen text comments and video preview had passed the initial
compact iPad run (3/4). The later resized-window check passed as described
below. A live paired-host annotation send and TestFlight-installed behavior
remain unverified.

The post-release hardening review additionally corrected Bot and Project
history/lifecycle waits that could delay update handoff. One ambiguous Bot
receipt now yields after 20 history pages, and Project recovery cannot restart
its runtime during the update lease. The combined daemon library suite passed
345 tests with three existing ignores, and the installer
handoff suite passed 12/12. A visible Chats control in the iPad conversation
shell passed a real-shell accessibility-size UI regression on iPad and the
corresponding iPhone check (1/1 each). The iOS source is in Testing 21; Mac
host corrections remain uninstalled. A further cold-Project regression passed
1/1 after a history refresh
race was fixed: a cached Project now waits for session renewal before reporting
failure. The Project toolbar title was bounded at large text sizes and passed
a visible-header check on both simulators (1/1 each). New Chat host switching
now keeps its draft visible if saving fails. The iOS fixes are included in
Testing 21, with installed interaction unverified.
With the owner's approval, enlarging and scrolling Mac Settings →
Devices exposed a usable copied pairing link. The owner approved exactly two
Wonder Testing development profiles (main app and Widget) using the existing
certificate; both were verified and installed. The TestingDiagnostics app
built and launched on the owned iPhone and iPad. Xcode's simulator signature
has an empty entitlement payload, while its simulated entitlements contain the
Testing App Group and Keychain groups. Each simulator claimed a fresh copied
HTTPS link, showed verification text matching the Mac, and connected only after
owner approval in the installed Mac Devices UI. The exact two temporary devices
appeared in the Mac roster. Each passed a live paired-host check through ten
app relaunches and twenty foreground resumes (1/1 each). This confirms the
effective simulator Keychain path for these builds; it does not verify a
TestFlight install or a physical device.
An address-and-code option now exposes the existing pairing-code path in draft
PR #61. Its focused UI check passed 1/1 on each iPhone and iPad simulator,
including codes with `-` and `_`. The first live link UI attempt exposed a
keyboard-obscured connect action on iPad. PR #61 pins that action and puts
the fields before large-text instructions; a focused accessibility XXL UI
check for both link and code routes passed 1/1 on iPad and 1/1 on iPhone with
the keyboard open. The subsequent live claims, Mac approval and durable
relaunch checks passed on both simulators. The installed host's authenticated
read-only workspace route returned the Project root, README, PNG and PDF with
matching MIME, size and SHA-256, plus a live Git status and diff. A second
temporary pairing session used the same owned Project thread after the Mac
was unlocked. On both iPhone and iPad, a focused live UI check opened README,
staged a line note as a composer attachment, removed it without sending, and
displayed a live Git diff (1/1 each). iPhone rendered the authenticated PNG
and PDF in one passing live UI check; iPad rendered the PNG in a partial media
run and rendered the PDF in a separate passing focused check. The first iPad
Files attempt had stalled while the Mac was locked, and broad iPad media
navigation runs failed on test scrolling or a disappearing sheet; their failures
are not counted as preview passes. At that stage, audio/video, a revision refresh after
annotation, and a mobile provider send remain unverified. No model request was
sent during the paired mobile checks. Both devices from each temporary pairing
session were revoked and their `revokedAt` state verified without changing
other devices. The exact disposable Project conversation was rearchived after
the first session, then unarchived for the second. Its second-session archive
and one guarded retry through Wonder returned HTTP 503. The same exact idle
native thread was then archived through the Codex app; its archived listing
and Wonder's fresh conversation read both confirmed `isArchived=true`.
Wonder's archive error path still needs investigation. A focused held-send
New Chat draft test passed 1/1 on iPhone after
the host-switch fix. These postrelease corrections remain in draft PR #61 and
are not in the uploaded Release builds.

The second-session archive 503 prompted a further draft-only host fix. Wonder
now confirms provider archive state after a failed RPC response, maps Codex's
active-writer rejection to a recoverable 409 with a Mac action, and rejects
archive during a host update lease before contacting the provider. The focused
fake-provider regression passed, the daemon library suite passed 345 tests
with three existing ignores, and strict Clippy passed. An independent review
found no remaining concrete race in this path. The exact live provider error
from the earlier 503 was not retained; this fix has not been installed or
checked against that live condition.

An actual Wonder Testing Widget was placed from SpringBoard's gallery on the
iPhone and iPad simulators (one passing focused placement test each). The
small unconfigured Widget rendered on both Home Screens; its initial title and
instruction clipped. Draft Widget source shortens that small empty state. The
iPhone Project picker displayed three saved fixture Projects and showed a
selected Project in its editor. The first rebuilt extension appeared to retain
WidgetKit's old timeline, so that attempt did not accept the revised rendering.

An earlier October 2 configured-Widget retry stopped before acceptance: the
Diagnostics fixture did not change the simulator's saved App Group snapshot,
and SpringBoard stalled twice while opening the Widget editor. Independent
review also found that SpringBoard can expose the Widget icon without its
rendered text as accessible descendants, so the proposed text assertion could
have rejected a correct Widget. The fixture and test were removed. The retained
attempt log is
`.local/build/widget-configured-iphone-final.log`.

A later signed Testing QA copy carried the existing Apple Development team and
Testing App Group entitlement on both the app and Widget. The prior simulator
ad hoc signature let the editor list Projects but caused WidgetKit to resolve
the saved App Entity as nil. With team signing, the selected `Project 1` card
rendered on both Home Screens. A small-card `Link` opened the Project's unsent
New Chat view after a fresh WidgetKit timeline on iPhone and iPad; the focused
foreground/destination/composer check passed 1/1 each, and both destination
screenshots were inspected. Earlier iPad tap probes with a cached timeline
failed the foreground check and are not counted as passes. Recent-chat Widget
links and TestFlight Widget installation remain open. The exact two temporary
simulator pairings for this check were revoked; the Mac roster showed six
revoked devices and neither overnight QA device in the paired list.

An October 3 source correction lets recent-chat Widgets include Wonder-created
Project conversations that have a durable conversation ID but no provider
session yet. It publishes the new row after the prepare-only creation succeeds
and keeps locally changed rows when an older thread page returns. A held-read
regression covering two drafts and a rename passed 1/1 on each iPhone and iPad
simulator; the exact-conversation deep-link UI check also passed 1/1 on each.
The Wonder Testing Release simulator build passed with no focused Diagnostics
markers. A configured medium Widget recent-chat tap, installed TestFlight
behavior and the current source's paired-host path remain unverified. Testing
21 includes this correction; production 82 predates it.

At the owner's request, draft Mac Settings removes its redundant Folders list.
Project roots and Bot file grants are separate daemon-owned controls; a
read-only review found no access boundary using that list. The retired list's
saved paths/bookmarks are cleared when the new bridge starts, while the Full
Disk Access action remains. Its previous owning tests passed 3/3 before
removal; the current Mac menu suite passed 33/33 and both desktop binary checks
passed. The new Access screen is not installed or visually accepted in Mac
1.0.108. No second replacement DMG was made; the later owner-authorized
Testing 21 checkpoint does not change the installed Mac.

A live Project conversation showed “Stopped” while its task was active in
Codex desktop. Read-only comparison confirmed that Codex desktop reported the
thread active, while Wonder's separate App Server reported `notLoaded` and
only an older interrupted turn. The earlier client labeled that saved turn
“This response stopped” (and a failed turn “This response couldn’t finish”),
without claiming to know the current desktop task state. The shared
turn-label test passed, and the actual Project view passed a focused 1/1 UI
check on each iPhone and iPad simulator; both screenshots were inspected.
Production build 82 still has the old wording; Testing 21 and 22 include the
scoped label, while Testing 23 uses the clearer saved-history labels above. A
truthful live Running indicator for desktop-owned turns needs a supported
shared status source and remains open.

The same Widget destination review exposed oversized New Chat picker icons
overlapping labels at accessibility text sizes. Draft UI now stacks secondary
actions, allows two-line picker labels and bounds decorative symbols. The
existing New Project Files test checked ordinary large and accessibility XXXL
text in one run. It passed 1/1 on each iPhone and iPad simulator, including
distinct visible controls and Files → Modified → diff navigation. All four
final screenshots were inspected. This UI correction is included in Testing 21.

Final independent review found a New Chat send lifetime edge: a late creation
response could navigate back after leaving the screen. Draft source cancels the
view-owned creation task on disappearance and lets the connection model deliver
an already prepared, durable message. The held-response test passed 1/1, the
pairing-replacement regression passed 1/1, and focused New Chat UI passed 1/1
on each iPhone and iPad simulator at two text sizes. A live held-response
navigation UI test was not run. The desktop-owned writer-lock path was also
checked: the provider rejects a competing resume/archive before another turn
starts. Draft Wonder now gives a specific retry message on the exact resume
writer conflict; a `notLoaded` plus interrupted-turn fixture passed 1/1 with
no `turn/start`, archive regression passed 1/1, and strict Clippy/fmt passed.
The iOS retry text is in Testing 21; the Mac host changes remain uninstalled.
Accurate live desktop Running is still open.

On October 3, a fresh, owner-authorized temporary Wonder Testing pairing to
the installed Mac passed on iPhone and iPad. Each simulator opened a disposable
8-second H.264/AAC Project video from the Mac's authenticated Files route,
showed a rendered frame in retained screenshots, advanced playback, and while
paused sought first to the start and then to about six seconds (75% of the timeline),
then opened an AAC audio file and advanced its playback before returning to
the conversation composer. The focused live UI test passed 1/1 on each
simulator, with video tap-to-player at 2.08 seconds on iPhone and 2.33 seconds
on iPad; paused seek interaction took 1.71 and 2.10 seconds respectively.
The passing bundles are `.local/build/live-media-strong-seek-iphone.xcresult`
and `.local/build/live-media-strong-seek-ipad.xcresult`. These are
single end-to-end UI samples over the configured Mac route, not transfer-only
latency or same-Wi-Fi versus remote measurements. One first iPad pairing test
timed out before the Mac approval was visible in Wonder; that orphaned Mac
device was revoked and the second code pairing passed. The exact final iPhone
and iPad test devices were also revoked, and neither remains in the paired
roster; Mac Settings shows 12 revoked devices. The synthetic media directory
and temporary code files were removed.
No mobile model turn was sent. Live unsupported-codec and offline recovery,
background/reopen with these larger files, repeated performance samples and
TestFlight-installed media playback remain open; F2 stays pending.

The subsequent Files slice replaces the Project conversation timeline
with its file browser and selected preview while keeping the composer visible.
An explicit full-screen control works on iPhone and iPad. Text selection opens
a compact comment editor; saving stages a versioned preview note in the
composer without changing the file or closing the preview. A file revision
check offers new bytes without silently rebinding an unsent note. Shared
preview state preserves unsaved comments and offered revisions across
expansion; the video player survives expansion and collapse. The focused
Files, text annotation, revision and video paths passed on both simulators;
the latest iPad rerun passed 4/4, the iPhone Files/annotation/revision paths
passed 3/3, and its comment-draft and video reruns passed 1/1 each. An 8 MiB
text file opened with a visible 128 KiB preview limit and usable Files/composer
controls in 1/1 focused checks on each simulator. Inline and expanded iPhone
and iPad screenshots were inspected. An earlier iPad approval-shortcut test
failed because its selector matched two Files controls; after correcting the
selector, the shortcut passed 1/1 on each simulator. These iOS changes are
included in Testing 21; production 82 predates them.
An actual mobile send with Files left open, paired-host live revision timing,
large-file repeated memory behavior, narrow iPad windows and TestFlight
installation remain unverified. No model turn was sent by these simulator tests.

A further review caught duplicate full-screen PDF and diff rendering. The
inline renderer now unmounts while the cover owns the selected preview. The
focused iPhone Files/diff and PDF annotation checks passed 2/2, including
returning to the composer. The new image check initially used the wrong
accessibility element type; its corrected one-page assertion passed 1/1 on
iPhone. A later handoff keeps PDF page/reading point/zoom in a
shared session and stores EPUB text size across preview remounts; focused
diagnostic and simulator checks passed. HTML/diff scroll and 3D camera pose
remain unverified across full-screen transitions. The selected file and staged
annotation/revision state stay bound to the conversation.
After the single-renderer change, five focused iPhone tests passed in a
finalized result bundle (comment draft, revision, video, EPUB and 3D), and
four focused iPad tests passed in a finalized bundle (Files/diff, image, PDF
and EPUB). The broader iPad log executed 8/8 tests with zero failures, but
Xcode stalled while finalizing that result bundle; its log is supporting
evidence only. A 3D test emitted an XCTest quality-of-service inversion
warning, so repeated model preview performance remains open. These checks
used TestingDiagnostics on iOS 26.5 simulators; Testing 21 contains the source,
but installation and interaction through TestFlight remain unverified.

The October 3 reader-state and annotation polish is included in Testing 21. Repeated
Files open/close through USDZ, OBJ, PLY, binary STL and unsupported inputs
passed 1/1 on both iPhone and iPad TestingDiagnostics simulators. An earlier
test tapped a file row under the composer; the corrected test scrolls the
Files list until the row is visibly clear before tapping. Four focused PDF
region, text note, video full-screen and EPUB checks passed 4/4 on each
device. A separate text-selection/comment/full-screen/cancel pair passed 2/2
on each after the selected text gained a persistent visual highlight and the
iPad comment editor was narrowed; its screenshots were inspected. EPUB text
size and chapter remain through full-screen changes and reopen. A direct
PDFKit viewport handoff check passed 1/1; real PDF UI checks passed on both
devices without the AttributeGraph warning seen in the direct test harness.
No new 3D temporary directories remained after the completed repeated-open
run; three older simulator test directories remain. Real send retention,
paired-host revision timing, camera gesture pose, narrow iPad windows,
TestFlight installation and repeated memory/performance sampling remain open.
Production 82 predates these changes; no model turn was sent.

A later October 3 review found that typing after opening a text comment in
full screen could prepend to the saved draft. The original UI test checked
only that both phrases existed, and its screenshot showed the wrong order.
The comment field now retains a bounded native cursor range across preview
remounts, shows a visible prompt on entry and rejects events from an editor
that has been replaced or canceled. The test asserts the exact combined note.
The final caret and add/edit/remove checks passed 2/2 on each iPhone and iPad
TestingDiagnostics simulator; the final stale-revision check passed 1/1 on both.
Screenshots show the correct order and persistent source highlight. This fix
is in Testing 21; TestFlight-installed interaction has not been checked.

Workspace EPUB and 3D file previews now offer a verified newer version after
an explicit check or a later conversation sequence, then reopen the reader or
scene only when “Show new version” is chosen. Focused diagnostic iPhone and
iPad UI tests passed 2/2 each: a revised EPUB showed changed Chapter 2 text,
and an OBJ changed from an unsupported sidecar to a rendered standalone scene.
The accepted EPUB and iPad model screenshots were inspected. Existing EPUB,
repeated-model and 3D-control checks passed 3/3 in a finalized iPad bundle.
On iPhone the repeated-model rerun finalized 1/1; the other two passed their
assertions, but Xcode stalled finalizing their combined result bundle, so that
log is supporting evidence only. This verifies manual adoption using synthetic
files, not timing of changes from a paired Mac. Valid-scene-to-valid-scene
replacement, camera gesture pose, VoiceOver, rotation, narrow iPad windows,
memory/performance sampling and installed Release behavior remain open.

HTML in-conversation previews now retain an approximate reading position when
expanded to full screen and returned to chat. The web view also reloads when
the owner accepts verified new HTML bytes; previously its empty update path
could keep showing the old page. A long synthetic HTML page was scrolled to a
lower section, expanded, collapsed, quickly repeated that round trip and revised in focused signed Diagnostics
UI tests: 1/1 each on iPhone and iPad. Inline and accepted-revision screenshots
were inspected. Narrow iPad windows, a real paired-host revision, repeated
WebKit memory and installed Release behavior remain open.

The PDF/image region editor now keeps its Add action and validation feedback
visible while the controls scroll, and collapses expanded area sliders when
the note takes keyboard focus. PDF page arrows use compact icons with full
accessible labels. The page-selection and accessibility XXXL keyboard flows
passed 2/2 each on iPhone 17 and iPad Pro 13-inch TestingDiagnostics
simulators; the resulting screens were inspected. On iPad, the selected page
remained large enough to inspect with the keyboard open. The iPhone's smaller
screen shows the comment controls above the keyboard at that text size; the
page itself must be inspected before typing or after dismissing the keyboard.
The change is included in Testing 21. A real paired-host annotation send and
installed TestFlight behavior remain open.

The latest pre-checkpoint Files review fixed a failed automatic revision check
being treated as a completed check. A selected file now retries a pending
update with bounded delay after a Mac read failure, including a slow timeout;
manual and automatic checks cannot overwrite each other's outcome or move the
observed sequence backward. The existing Diagnostics owner and visible
text-revision/unsent-note UI check each passed 1/1 on both iPhone 17 and iPad
Pro 13-inch iOS 26.5 simulators. Paired-host edit timing and installed Release
behavior remain unverified, so Files acceptance stays open. The desktop task
status comparison also confirmed that Wonder's separate App Server can report
`notLoaded` while Codex desktop owns an active turn. Codex hooks do not by
themselves prove ongoing activity; a supported fresh desktop-owned status
source is still required before showing a live Running state in Wonder.

Broader GLB support remains research gated. An isolated, nonshipping
GLTFKit2 probe rendered a textured GLB in 100 SceneView open/close cycles
on each iPhone and iPad simulator, and a Python hostile-input prototype
passed 19/19 expected cases. Closed process footprint rose about 1.2 MiB
on each device without a demonstrated plateau; simulator GPU allocation
could not be measured. Native input validation, complex/near-limit assets,
GPU tracing and package/license review are still required before adding GLB
to Wonder. The probe was removed from both simulators.

Testing 21 is a checkpoint of the iOS work through October 3.
The Release archive was signed from a clean checkout, uploaded once, processed
and confirmed in Owner Beta with a tester. The source passed a real iPadOS
window resize from 1032 to 698 points: Chats, Settings, Files, README preview
and a staged text note remained usable, and the chat viewport stopped above
the composer. A more extreme 370-point window exposed and verified the same
viewport fix. Focused clean-simulator Chats and Files/send checks passed on
both iPhone and iPad; the send check used the visible bottom arrow to inspect
the accepted message. These checks did not send a live provider request.
The 698-point check measured a side-by-side-sized Wonder window, not a
simultaneous two-app iPad session. That, iPhone Duo adaptation, installed
TestFlight interaction and paired-host provider sends remain open. Production
stays at build 82 by owner request; no production upload was made for this
checkpoint.

After that checkpoint, a source-only Accessibility XXXL Files pass gave the
inline and full-screen preview headers a separate filename row, kept the
staged-file chip and remove control visible, and allowed two draft lines. A
focused malformed-PDF and composer UI test passed 1/1 on each iPhone 17 and
iPad Pro 13-inch M5 simulator (iOS 26.5); both captures were inspected. The
photo/file strip controls also passed a focused iPhone check and an iPad retry;
the first iPad attempt stopped on a preserved Widget ExtensionKit startup crash.
The layout changes were absent from Testing 21 and remain absent from
production 82. They are included in Testing 22; installed behavior awaits review.

[Apple's iPad windowing guide](https://support.apple.com/en-us/125309)
defines a genuine side-by-side session as two apps visible with a divider.
The current 698-point check validates Wonder's available width but not that
two-app arrangement. A dedicated iPadOS 26.5 Safari/Wonder check tried Dock
swipes and Apple's window-arrangement keyboard shortcut. The Dock gestures
opened the app switcher or left Wonder full-screen, and the shortcut left
both reported app windows at full width. Its failed UI test was removed; true
two-app behavior is still unverified. A second iPadOS 26.5 XCTest attempt
confirmed Windowed Apps was selected, launched Safari and Wonder Testing,
and sent Apple's Control-Shift-Globe-Left shortcut twice; Safari remained
full screen and Wonder still measured 1032 points. The provisional test was
removed after its two failures; a visible center divider remains the gate.
For [iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo),
the outer and inner displays have different size classes and the inner display
can multitask. Wonder still selects its drawer by iPhone idiom, so inner-display
layout adaptation is open. This Mac has Xcode 27.0 and no Duo simulator device;
[Apple's developer walkthrough](https://developer.apple.com/videos/play/tech-talks/111461/)
specifies Xcode 27.1 and DeviceHub for pose checks. Duo behavior has not been
verified on a simulator or physical device.

The post-release hardening review additionally corrected Bot and Project
history/lifecycle waits that could delay update handoff; the combined daemon
library suite passed 341 tests with three existing ignores, and the installer
handoff suite passed 12/12. A visible Chats control in the iPad conversation
shell passed a real-shell accessibility-size UI regression on iPad and the
corresponding iPhone check (1/1 each). These changes remain in unshipped draft
PR #61. With the owner's approval, a read-only pairing attempt found the
installed Mac did not expose a usable full link through the accessible Devices
UI, and the available simulator builds lacked durable pairing entitlements.
No new owner device appeared; paired mobile acceptance remains open.
An address-and-code option now exposes the existing pairing-code path in draft
PR #61. Its focused UI check passed 1/1 on each iPhone and iPad simulator,
including codes with `-` and `_`. A simulator-only ad-hoc signed build produced
an empty entitlement payload and was not installed for owner pairing. A live
code claim, Mac approval and paired Files/media/send roundtrip remain open.

## Earlier qualification

Testing build 7 and production build 71 passed six focused iPhone Simulator
checks and three iPad Simulator checks, with no failures or skips. These cover
queue retirement, reopen/reattach behavior, black-area hit testing and pointer
mode, plus question-form expansion and saved answers at normal and accessibility
text sizes. The shared native suites passed 57 tests; the daemon project suite
passed nine, the store repair regression passed one, and strict Clippy passed.
An older imported Wonder chat gained its existing desktop project assignment
through the installed Mac API without changing its conversation or starting a
model turn. Both exported Release packages passed signature, identity,
entitlement, Keychain-isolation and Diagnostics-exclusion checks. Physical touch
acceptance and installation through TestFlight were not repeated; this update
was qualified using simulators at the owner's request.

Earlier Testing build 6 and production build 70 share the updated picker. Optimized
iPhone and iPad Simulator UI checks each switched between Macs ten times in both
directions, verified draft restoration, and opened and canceled Add computer.
They also verified the selected computer remains fully visible above the keyboard
and Add computer can scroll fully into view. Screenshots confirm the 7-point
dots directly after Mac names. Both signed Release exports passed identity,
entitlement, Keychain-isolation and Diagnostics-exclusion checks. An earlier
physical-device build passed, but its UI runner could not initialize because
authentication was canceled; this revision's physical interaction and actual
TestFlight installation remain unverified. The owner authorized uploads to both
app identities.

An earlier shell revision passed 30 iPhone and 15 iPad Simulator navigation cycles,
including saved drafts, Settings navigation and pin toggle/reopen/restoration.
The app launch check passed 10 launches and 20 foreground/Settings cycles.
Four focused client state tests and 14 shared native tests passed.
No model requests were sent during these checks. Physical-device acceptance of
this shell remains unverified.

Earlier build 66 Projects qualification passed composer-control placement,
durable draft/dictation, and Group review checks. An optimized
Diagnostics build passed 30 navigation cycles on a physical iPhone 11 running
iOS 27 in 529 seconds including setup. That build kept model and permission
choices, attachments, dictation and Send inside the composer; Connection and
Destination sat above it. No model requests were sent during these navigation checks.

The content-free capture covered the first 111 seconds: opening readiness was
92.7 ms at p95 across 11 samples; the main-thread probe was 51.3 ms at p95 across
194 samples. Network requests were measured separately (98.0 ms p95, 611.2 ms
maximum). Resident memory settled at 166.9–168.0 MiB and physical footprint at
54.0–55.3 MiB during the final 30 seconds of that capture. This short capture
does not establish memory stability across the full navigation run or certify
touch latency and rendered-frame performance.

Those earlier Release exports exclude the recorder, developer controls,
scenario runner and fixtures. Their signatures, app/extension identities,
APNs entitlements and separate Keychain groups passed verification; provider
icons include sRGB fallbacks and P3 variants.

Both providers passed exact-session terminal continuity on the tested compatible
runtimes. A live Codex request read its uploaded attachment, and retrying the same
request produced only one user message. Live Claude attachment verification was
blocked by the provider session quota; scoped attachment and permission tests
passed, but they do not replace that live check. Direct Codex-app and Claude
Desktop selection remain unverified. Continue on Mac provides terminal commands;
finish work in one client before switching because simultaneous writers are not
coordinated across applications.

Earlier build 60 qualification passed physical iPhone 11 checks on iOS
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
for the current shell. Physical iPad, fresh-Mac setup, external TestFlight installation,
independent-network behavior, complete VoiceOver navigation, and scheduler
recovery remain unverified. Teaching a task and replaying taught tasks remain
outside the beta scope.

## Beta limitations

- Initial setup requires both devices, Tailscale and access to the supported model provider.
- Model requests are sent to your provider. Wonder does not include a model subscription or credits.
- Remote access depends on the Mac being reachable. Tailscale may relay encrypted traffic when a direct connection is unavailable.
- Signed automatic Mac updates are implemented, including saved preferences and installation after work finishes. One signed automatic upgrade passed on this Mac; use the [signed Mac DMG](https://github.com/swaymun/wonder/releases/tag/mac-v1.0.101-beta.1) if an update does not complete.
- Teaching a task and replaying taught tasks are unavailable in this beta.
- Notifications require permission and network access. Disabling notifications does not stop work on the Mac.
- Supported OS versions and verification evidence are different: simulator checks do not establish physical-device behavior on every supported model.

Release qualification is described in [RELEASING.md](RELEASING.md). The public
TestFlight link will be enabled only after the updated build and installation
checks pass.

Use synthetic examples when reporting issues. See [security reporting](SECURITY.md)
before sharing any sensitive reproduction information.
