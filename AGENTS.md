# Wonder product UI guidance

Wonder is a product-facing messenger for persistent Bots and Group Chats. Keep
the experience understandable to a person who does not know the App Server
protocol or the internal orchestration model.

## Conversation-first rules

- Treat direct Bot conversations and Group Chats as one conversation surface.
- Prefer a compact Chats list, clear names, stable colored avatar blocks, and
  readable previews over decorative cards or role-specific icon tiles.
- Keep conversation headers compact and keep the composer prominent and
  available at the bottom of the conversation.
- Use denser spacing, stronger text contrast, fewer borders, and restrained
  corner radii. Accent color is for focus, selection, and primary actions, not
  decorative rails.
- On mobile, opening a conversation replaces the list and provides an obvious
  way back to Chats.
- For native clients, prefer standard SwiftUI/iOS and messaging UX patterns.
  When a pattern is unclear, inspect the ChatGPT mobile app as a behavioral
  reference before inventing an interaction. Follow the native UX guidance in
  this file and, when available locally, `docs/native-ios-blueprint/PLAN.md`;
  Wonder is a messenger with additional agent-message rendering, not a new
  interaction paradigm.

## Product-facing language

- Make the UI self-explanatory. Avoid helper text that narrates visible activity
  or obvious controls. Add explanatory copy only when it helps users make a
  decision, understand a meaningful limitation, or recover from a problem.

- Do not show raw App Server methods, lifecycle events, token usage, thread IDs,
  transport state, worker/synthesis/direct/phase labels, or internal dispatch
  terminology in the normal feed.
- Do not expose raw capability, API, plugin, or MCP inventories in normal
  Settings. If developer observability is added later, put it behind an
  explicit developer details view.
- Direct chats identify the Bot in the conversation header; do not repeat its
  name or avatar over each reply. Use left-aligned Bot bubbles and right-aligned
  user bubbles with distinct, restrained fills. Group Chats identify each speaker
  change with the Bot’s stable avatar and human name. Preserve accessible speaker
  identification even when visual labels are omitted.
- Avoid AI-slop metadata, unnecessary system labels, oversized empty cards,
  and copy that explains implementation instead of helping the user act.

## Controls and trust

- Every visible user control must work, persist its change, and show loading or
  failure feedback; otherwise label it as unavailable.
- Preserve approval gates and explain them in user language without exposing
  protocol payloads.
- Keep artifact previews, downloads, MIME validation, and integrity hashes
  honest. If a tool cannot produce an artifact, say so instead of fabricating
  one.
- Browser automation uses the Codex/App Server or connected computer-use path;
  Wonder must not depend on a Chrome extension.
- Preserve read-only-first boundaries. Keep diagnostic collection confined to
  the Diagnostics build; do not add telemetry to Release.

## Test ownership

- Before adding a test, name the observable contract, a credible regression, and
  the strongest existing test boundary that would catch it. Extend that owner's
  fixture or table when it already covers the risk.
- Avoid tests that merely copy source strings, declared flags, inventories, or
  a mock's own behavior. Keep independent guards for security, protocol, storage,
  migration, package, and release contracts.
- Do not keep a production route, flag, export, or helper solely to support a
  test for a feature no longer shipped. Remove the obsolete path, its test, and
  related smoke, documentation, and inventory entries together.
- When pruning tests, inspect their history and callers first. Report test and
  production lines separately, run the owning tests, and distinguish measured
  CI savings from hypothetical savings for tests CI never ran.
- Before filtering a CI workflow by paths, check required status rules; GitHub
  leaves a filtered required check pending on a pull request.

## SwiftUI coding practices

Apply these when adding or changing views; keep refactors proportional to a
measured problem. Apple's [SwiftUI performance guidance](https://developer.apple.com/videos/play/wwdc2023/10160/)
explains view dependencies, update cost, and identity.

- Keep `body`, view initializers, and properties read by `body` cheap and free of
  side effects. Do not parse JSON/Markdown, format full tool output, decode images,
  perform I/O, or repeatedly sort/project the full history there. Moving that work
  into a computed property does not cache it; prepare a presentation when its inputs
  change and let rows consume it.
- Keep dependencies narrow. Put rapidly changing state near the controls that need
  it, and pass rows their presentation values and actions rather than observing
  the entire connection model. Extract a child `View` with focused inputs when it
  reduces invalidations; extracting a helper function alone does not do that.
- Preserve identity through inserts, paging, and streaming. Use stable model IDs
  in `ForEach` and scroll targets, never a fresh `UUID()` or changing array offsets.
  Do not change `.id(...)` to force refreshes; that also resets state and task
  lifetimes. Keep row structure predictable and flatten activity children as below.
- Give reference models one owner. With the existing `ObservableObject` pattern,
  use `@StateObject` for a view-owned model and `@ObservedObject` for an injected
  one; do not create clients or models on every view evaluation. Keep transient
  interaction values in `@State`. See Apple's [StateObject ownership guidance](https://developer.apple.com/documentation/swiftui/stateobject).
- Treat geometry/preference callbacks as frequent events. Derive the smallest
  useful value, such as bottom visibility, and only publish meaningful changes.
  Avoid measurement → state → layout feedback loops and per-row geometry readers
  unless needed. Never trigger persistence or a full chat refresh per pixel moved.
- Scope animation to the intended control or transition and respect Reduce Motion.
  Avoid animating whole-history replacement or every streamed text update. Check
  expansion anchors with the keyboard, large Dynamic Type, and older-history inserts.
- Keep UIKit bridges idempotent: `updateUIView` changes only differing properties.
  Preserve text selection, marked text/IME composition, and internal scroll position;
  do not replace the text on every SwiftUI update. Use finite, bounded sizing for
  large editors/output and avoid layout callbacks that synchronously write bindings.
- Diagnose both expensive updates and excessive update frequency with the
  [SwiftUI Instruments template](https://developer.apple.com/videos/play/wwdc2025/306/),
  including representable updates. Use Time Profiler to locate actual work.
  `Self._printChanges()` is temporary debugger investigation only; remove it before
  any distribution archive, including Diagnostics TestFlight builds.

## iOS concurrency and resource practices

- Keep UI mutations on `MainActor`, with expensive decoding, projection, image work,
  and persistence behind an explicit worker boundary. `async` or `Task {}` alone
  does not establish background execution; tasks can inherit main-actor isolation.
  Check the project's compiler/isolation settings and use an appropriate worker
  actor or existing queue. Do not block the main thread with semaphores, synchronous
  dispatch, or waits. See Apple's [responsiveness guidance](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).
- Tie asynchronous work to an owner and stable request identity. Prefer `.task(id:)`
  for view-scoped loading; retain and cancel longer-lived work explicitly. Check
  cancellation and conversation/pairing generation before applying results after
  `await`. Cancellation is cooperative. If a detached task is needed, explicitly
  manage its cancellation and capture immutable, concurrency-safe inputs.
- Bound concurrent image/detail work and deduplicate identical in-flight requests.
  A fast scroll must not start one unbounded task per appearance. Make appearance
  handlers safe to repeat and avoid preformatting hidden details or all history.
- Treat caches as disposable derived data, separate from drafts and durable history.
  Include source revision and relevant presentation inputs in cache validity; account
  for locale, time zone, Dynamic Type, or display size when they affect the result.
  Bound retained bytes/items and release unused presentations/images on eviction or
  memory pressure. Test changed and removed items, not just repeated cache hits.
- Coalesce redundant streaming updates and small persistence writes at the shared
  boundary. Preserve ordering, terminal states, approval events, and read semantics;
  never drop a final result to reduce update frequency. Flush pending durable intent
  on the appropriate navigation/background boundary without rewriting full history.
- Stop screen-scoped timers, observers, display links, and tasks when their owner or
  foreground lifetime ends. Reuse transports and preserve explicit session cleanup
  as described below. Verify repeated open/close cycles release resources, not just
  that the first presentation is fast.
- Keep deployment-target fallbacks functional. Newer scroll/layout APIs require
  availability checks and testing of the older supported path. Do not trade away
  accessibility, text selection, or correct live updates to improve a benchmark.

## iOS performance and diagnostics

Read [apps/ios/DIAGNOSTICS.md](apps/ios/DIAGNOSTICS.md) before changing conversation
rendering, recording, or performance tests. Keep durable operating instructions
in tracked files; `/docs/` and `.local/` are ignored. Use this checkout and keep
builds, traces, crash reports, and matching dSYMs under `.local/`, without creating
another Wonder checkout for profiling.

- Investigate a hang from the device's crash/CPU report and matching symbol UUIDs.
  Preserve that evidence before rebuilding. A watchdog in SwiftUI layout can be
  excessive main-thread work without a conventional exception or crash backtrace.
- Keep expanded activity rows in the conversation's single lazy stack, with
  stable IDs and expansion state. Nested lazy stacks caused a ten-second watchdog.
  Prepare cheap summaries first; format and cache full details only as needed,
  invalidating them when the underlying item changes. Use bounded native text
  viewports for large command output/diffs and downsample image thumbnails off
  the main thread. Exercise command, diff, commentary, and image views separately.
- Keep rapidly changing scroll geometry below the timeline/composer view. Reuse
  projected rows and timestamps across local expansion changes, with explicit
  invalidation for live data changes. Persist a small reading anchor separately;
  never reserialize the full history/replay cache for a scroll-position update.
- Reuse network clients. A `URLSession` with a delegate must be explicitly
  invalidated when its owner is released; creating a session per report batch
  leaked memory. Preserve transport lifetime regression coverage.
- Authentication/presence updates such as `devices.last_seen_at` must not emit
  conversation invalidations. Otherwise a refresh authenticates another request
  and creates a feedback loop. Keep real device/session/revocation changes visible.
- Preserve automatic older-history loading, search navigation, reading position,
  read acknowledgements, accessibility, and the bottom arrow. Do not replace
  automatic history loading with a permanent "Load older messages" button.
  Normal interaction and scenario tests must use the same expansion/scroll actions.
- Profile optimized Diagnostics builds (`WONDER_DIAGNOSTICS`, independent of
  `DEBUG`) against a real paired Mac on simulator and physical iPhone. Check
  `/readyz`, not just `/healthz`; a reachable Mac can have an incompatible runtime.
  Validate the pinned runtime version/protocol instead of bypassing those checks,
  and identify temporary runtime overrides as temporary in handoff notes.
- Use unique accessibility IDs and assert Expanded/Collapsed state after taps.
  `isHittable` alone can include lazy rows behind navigation/composer overlays;
  select a fully visible control and retain its stable identity. Use the complete
  `-only-testing:Target/Class/testMethod` filter and verify nonzero executed tests.
  A skip, zero-test run, or successful tap call is not interaction acceptance.
- Scale physical sessions to the fix and state the chosen duration and reason
  before testing. Use 1–3 minutes for localized layout, styling, or rendering fixes;
  3–5 minutes for changes to image loading, caching, concurrency, persistence, or
  scroll anchoring; and ten minutes for suspected leaks, watchdogs, long-lived
  resource/lifecycle issues, or broad timeline restructuring. These are starting
  ranges, not mandatory soak times for every change. Extend a run when the original
  failure takes longer to reproduce or measurements have not stabilized.
- Exercise the affected interaction: usually 10–15 repetitions for a small fix,
  and at least 30 for intermittent scrolling/expansion bugs or resource-lifetime
  changes. Image scroll crossings count for image fixes; do not require unrelated
  expansion cycles. Reuse evidence from the same product code and configuration;
  test-only, documentation, signing, or packaging changes do not restart a full
  session. Stop after relevant checks pass unless new evidence warrants more work.
- Initial targets: local readiness p95 <100 ms, no local interaction >250 ms,
  measured scroll hitch time <5 ms/s, and no watchdog or sustained memory growth
  during the chosen session. Retain both resident memory and physical footprint;
  distinguish warmup from sustained growth and report the actual observation window.
- Compare recording on/off on the same device and data after warmup when changing
  the recorder, adding high-frequency instrumentation, or investigating recording
  overhead; target <5% added p95 latency. Do not repeat an unaffected recorder
  comparison for every UI fix. Identify any reused evidence and its limits.
- Report sample count, p50/p95/max, device/build/session, and separate network,
  decoding, projection, and UI timings. Display-callback/readiness timings are
  proxies; scenario success does not certify touch handling or rendered frames.
  Use physical XCTest/Instruments for scrolling, retain anomalous metric fields,
  and distinguish simulator, scenario, and physical acceptance. MetricKit delivery
  is delayed; mark interrupted sessions without inferring a crash absent an OS report.
- Live tests send no messages or start model work unless explicitly requested.
  `/api/v1/bots/new` starts model-backed onboarding. Use the existing explicit
  `POST /api/v1/bots` path for a dedicated read-only test Bot, persist its request/ID
  before creation, recover interrupted cleanup, and archive only that exact Bot.
  Verify its message count stays zero. Retain fixture ownership through cleanup.
- Keep recording content-free and bounded: no message text, prompts, tool output,
  credentials, filenames, or raw URLs. Batch serialization/writes off the main
  thread; never write every row/frame. Detailed captures stop after two minutes
  or on backgrounding. Preserve phone 20 MB/seven-day and Mac 200 MB/14-day limits,
  paired authentication/CSRF, retry deduplication, offline retention, and manual export.
- Verify exported Release excludes the recorder, developer UI, uploader, runner,
  and fixtures, and compare exported sizes. Keep the same app identity and pairing.
  Preserve matching dSYMs and source evidence outside the installed app. TestFlight
  upload/processing and tester availability are separate checks.

## iOS changes and TestFlight

- After completing any iOS app change, including shared native code that affects
  iPhone or iPad behavior, run the relevant checks and upload a new TestFlight
  build as part of the task. This is standing user authorization; do not ask
  again unless the user explicitly excludes uploading for that task.
- Use `bundle exec fastlane ios beta` from the repository root. It reuses the
  archive script, selects a build number above the latest uploaded build,
  exports with API-key authentication, uploads, and waits for processing.
  The default profile is Release. Use `profile:diagnostics` for a requested
  diagnostics build and `profile:release` for regular beta/production behavior.
- Load credentials from `~/.config/wonder/app-store-connect/upload.json`, or the
  `WONDER_ASC_CONFIG` override. Keep the private key outside the repository;
  never print it or fall back silently to interactive Apple ID authentication.
- Keep archive evidence under `.local/`. Distinguish uploaded, processing,
  processed, and available to testers. If upload or processing fails, report
  the blocker and existing build number; check Apple before retrying so an
  already uploaded build is not uploaded twice.
- The default lane uploads only; it does not submit beta review, invite or
  notify testers, or change tester groups. Those actions need explicit user
  authorization and suitable App Store Connect permissions.
- Documentation-only and release-tooling-only changes that do not alter the
  shipped iOS app do not require a new binary. Concurrent tasks should serialize
  uploads and recheck the latest build number before starting.

## Build and installation cleanup

- Cleanup is part of finishing every build/test task and TestFlight upload.
  Compiler output and old app copies are disposable; rebuild a previous version
  from its recorded source when needed. Do not accumulate a cache per fix or run.
- During a task, reuse one DerivedData directory per platform/configuration under
  `.local/build/`. Keep it until all dependent `test-without-building`, installation,
  and verification steps finish. Never clean a directory another build/test uses.
- Keep Wonder's simulator inventory deliberate. Reuse the named QA fixtures
  `Wonder Beta iPhone WS2`, `Wonder Connected QA`, `Wonder Overnight iPhone QA`,
  `Wonder Overnight iPad QA`, and `Wonder Group iPad QA`; a `Shutdown` state does
  not make one redundant. Do not create a new generic simulator or persistent
  XCTest clone for each run when one of these fixtures covers the scenario.
- Prefer `-parallel-testing-enabled NO` for focused Wonder UI or Diagnostics
  runs unless parallelism is required and its cleanup owner is explicit. If a
  run needs temporary destinations, record the created UDIDs, stop the run,
  delete those exact temporary simulators, and verify the inventory afterward.
- After simulator testing, inspect `xcrun simctl list devices`. Remove
  unavailable devices with `xcrun simctl delete unavailable` only after checking
  that no required runtime or fixture is affected. Never remove the named Wonder
  fixtures or a paired physical-device record as part of simulator cleanup.
- Treat `~/Library/Developer/XCTestDevices` as disposable test-run state, not a
  retained fixture store. Before cleanup, verify that no `xcodebuild` or `xctest`
  process is active and that the entries are generated `Clone ...` devices.
  Do not leave persistent clone trees behind; use the host's supported Xcode
  cleanup path, or a narrowly scoped cleanup of that verified clone root when
  no dedicated command exists; never clean a broad `~/Library` path. Verify the
  clone data and its disk usage are gone. Record before/after usage when a test
  run creates more than a small temporary clone.
- At task completion, preview `python3 scripts/clean-build-artifacts.py`, then run
  it with `--apply`. It clears recognized Rust, Swift and Xcode compiler output
  while retaining source, logs, test results and crash symbols. The archive script
  also clears its own DerivedData after producing a verified signed archive.
- After Apple confirms an upload is processed, retain the build/upload metadata,
  matching dSYMs, source commit, dirty diff and untracked-source snapshot. Remove
  redundant IPAs, exported app copies and the archive's app/products. Keep an
  unprocessed or failed upload's package until its Apple status is resolved.
- Compress and deduplicate retained dSYMs under `.local/symbols/`, with an index
  mapping their original paths to archives. Verify archived file hashes before
  deleting originals. Extract the indexed archive when symbolication is needed;
  do not retain identical symbol bundles for every repeated test run.
- `/Applications/Wonder.app` is the single installed Mac version. After its
  signature, launch and `/readyz` checks pass, remove superseded app bundles from
  `~/Applications`, staging directories and `~/.wonder/Backups/signed-update-*`.
  A rollback copy may exist while validating an installation, then remove it.
  Preserve pairing, live databases, credentials, runtime/model data and source
  backups; application backups are not a reason to delete user data.
- Remove an obsolete worktree only after checking it is clean, its commit is
  reachable from `main`, and no process/task uses it. Use `git worktree remove`,
  inspect ignored contents before forcing removal, and prune stale metadata.
- Keep compact final test reports and relevant failure/crash evidence. Avoid
  duplicate screenshot exports, copied repositories and repeated full test
  bundles when a retained final result covers the same code and configuration.
  Record before/after disk usage and any deliberately retained large artifacts.
