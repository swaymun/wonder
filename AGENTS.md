# Wonder agent guidance

Wonder is a native messenger for persistent agent conversations and Projects.
Keep the experience understandable without knowledge of the App Server protocol.
Apply guidance to the current implementation; verify callers before carrying
forward rules for an older feature or workflow.

## Product UI

- Treat project threads, direct chats and existing Group Chats as one conversation
  surface. Use a compact Chats list, clear names, stable avatars and readable previews.
- Keep headers compact and the composer available at the bottom. On mobile, opening
  a conversation replaces the list with an obvious way back to Chats.
- Prefer native SwiftUI messaging patterns, dense spacing, strong contrast, few
  borders and restrained corners. Use accent color for focus and primary actions.
- Direct replies use left-aligned agent bubbles and right-aligned user bubbles;
  identify the agent in the header. Groups identify speaker changes with a stable
  avatar and human name. Preserve accessible speaker identification throughout.
- Explain meaningful choices, limitations and recovery steps. Avoid helper text
  narrating obvious controls, redundant labels and oversized empty cards.
- Keep protocol methods, lifecycle/dispatch labels, IDs, token usage and transport
  state out of normal UI. Raw capability/plugin/MCP inventories belong only in an
  explicit developer details view.
- Every visible control must work, persist and show loading/failure feedback;
  otherwise label it unavailable. Explain approvals in user language.
- Preserve artifact previews, downloads, MIME validation and integrity hashes.
  Never fabricate an artifact. Browser automation uses the connected computer-use
  path without a Chrome extension dependency.
- Keep diagnostic collection confined to Diagnostics builds; do not add telemetry
  to Release.

## Test ownership

- Before adding a test, name the observable contract, credible regression and
  strongest existing owner. Extend its fixture/table when it covers the risk.
- Avoid tests copying source strings, flags, inventories or a mock's own behavior.
  Preserve independent security, protocol, storage, migration and release guards.
- Remove obsolete production paths together with their tests, smoke checks,
  documentation and inventory entries; do not retain code solely for a dead test.
- Before pruning, inspect history/callers and run the owning tests. Report test and
  production lines separately; distinguish measured CI savings from estimates.
- Before path-filtering CI, check required status rules: a filtered required check
  can remain pending on a pull request.

## SwiftUI and concurrency

- Keep view bodies, initializers and properties read by them cheap and side-effect
  free. Prepare parsing, formatting, image decoding and history projection when
  inputs change; a computed property alone does not cache work.
- Narrow dependencies and put fast-changing state near its controls. Pass prepared
  values/actions to rows rather than the whole connection model.
- Use stable model IDs through inserts, paging and streaming. Never force refresh
  with changing IDs. Keep expanded activity children in the single conversation
  lazy stack; nested lazy stacks previously caused a watchdog.
- Own reference models once: `@StateObject` for view-owned models, `@ObservedObject`
  for injected models, `@State` for transient interaction values.
- Keep scroll geometry below the timeline/composer. Publish visibility changes,
  reuse projections across expansion changes and persist a small reading anchor
  separately; never rewrite full history or refresh per pixel.
- Scope animation, respect Reduce Motion and preserve keyboard, Dynamic Type,
  selection, paging, search navigation, read acknowledgements and the bottom arrow.
- Make UIKit updates idempotent. Preserve selection, IME composition and internal
  scrolling; bound large text viewports and avoid synchronous binding writes from
  layout callbacks.
- Keep UI mutations on `MainActor`; move expensive work behind an explicit worker
  actor/queue. `async` or `Task {}` alone does not mean background execution. Never
  block the main thread with semaphores, synchronous dispatch or waits.
- Tie tasks to owners and stable request identity; cancel when ownership ends and
  check cancellation plus conversation/pairing generation after `await`.
- Bound and deduplicate image/detail work. Downsample thumbnails off the main
  thread; format full details only when needed. Invalidate caches for changed or
  removed inputs, revisions and presentation settings; bound bytes/items and evict
  on memory pressure. Keep caches separate from durable history and drafts.
- Coalesce streaming updates and small persistence writes at their shared boundary
  while preserving ordering, terminal results, approvals and read semantics. Flush
  durable intent on navigation/background without rewriting full history.
- Stop timers, observers and tasks when their owner/foreground lifetime ends.
  Reuse network clients and explicitly invalidate delegate-backed `URLSession`s
  on release. Verify repeated open/close cycles release resources.
- Presence/authentication updates such as `devices.last_seen_at` must not invalidate
  conversations and create a refresh feedback loop. Preserve real revocation and
  session/device changes. Keep deployment-target fallbacks functional.

## Verification and diagnostics

- **For now, physical iPhone/iPad testing is optional and runs only when explicitly
  requested.** Use relevant unit/model/contract checks and focused simulator UI
  checks by default. Physical sessions, mirroring and device availability must not
  block completion or TestFlight uploads. Report hardware-only behavior as unverified.
- Read [apps/ios/DIAGNOSTICS.md](apps/ios/DIAGNOSTICS.md) for conversation rendering,
  recording or performance work. Use this checkout and keep private builds, traces,
  crash reports and matching dSYMs under `.local/`. Keep operating instructions in
  tracked files rather than ignored local notes.
- Preserve crash/CPU reports and matching symbol UUIDs before rebuilding. Profile
  optimized Diagnostics builds against a paired Mac when the change needs live
  integration; check `/readyz` and the pinned runtime/protocol without bypasses.
- UI tests use unique accessibility IDs, fully visible controls and assertions of
  the resulting state. Use complete `-only-testing:Target/Class/testMethod` filters
  and confirm nonzero executed tests. A skip or successful tap alone is not a pass.
- Live tests send no messages or start model work without explicit authorization.
  Use existing owned read-only fixtures; recover interrupted cleanup and remove or
  archive only the exact fixture created by the run. Never alter unrelated chats.
- Scale checks to the affected flow and reuse evidence for unchanged code/config.
  Report the build, environment, sample count and relevant timings/limitations;
  keep simulator, scenario and optional physical evidence distinct. Recorder bounds,
  privacy rules and optional performance procedures live in the diagnostics guide.
- Remove temporary `Self._printChanges()` before distribution. Verify exported
  Release excludes the recorder, developer UI, uploader, runner and fixtures.

## iOS changes and TestFlight

- **After every completed change to the shipped iOS app (including shared code that
  affects it), run relevant checks and upload Release builds to BOTH Wonder Testing
  and production Wonder. This is standing authorization for both uploads; no
  separate candidate approval is required.** Respect an explicit request to defer
  uploads. Documentation/source-sync/tooling-only changes that do not alter the
  shipped app need no new binary.
- Run these sequentially from the repository root:

  ```sh
  bundle exec fastlane ios beta channel:testing profile:release
  bundle exec fastlane ios beta channel:production profile:release
  ```

- Keep blue `com.swaymun.wonder.testing` and orange `com.swaymun.wonder` identities,
  pairing, drafts and Keychain access separate. Do not install development or
  Diagnostics builds over orange Wonder. The Mac has no separate testing variant.
- Use `profile:diagnostics` only for a specifically requested Diagnostics build.
  Read [apps/ios/TESTING.md](apps/ios/TESTING.md) and
  [fastlane/USAGE.md](fastlane/USAGE.md) for channel/signing details.
- Load credentials from `~/.config/wonder/app-store-connect/upload.json` or
  `WONDER_ASC_CONFIG`; keep the private key outside Git and never print it. Use
  existing Match/manual signing; no silent Apple ID fallback. New certificates or
  profiles require explicit approval.
- Serialize uploads across tasks and recheck each app's latest build number.
  Retain evidence under `.local/`; report each channel's build number and uploaded,
  processing, processed and tester-availability status separately. Check Apple
  before retrying an uncertain upload to avoid duplicates.
- Upload authorization does not include beta-review submission, tester invitations,
  notifications or group changes. Those require explicit authorization.

## Delivery and cleanup

- Commit and push verified, coherent changes owned by this thread before ending,
  unless explicitly deferred. Inspect status, branch, remotes and staged paths;
  stage only intended changes. Preserve concurrent work without reset/stash/force-push.
- If selected public source changes, sync the existing public checkout using
  [RELEASING.md](RELEASING.md) and `scripts/public-source-files.txt`. Review new
  inclusions, run the audit and verify bytes/executable modes. Make a separate public
  commit; never publish internal history, private evidence, credentials or artifacts.
- A TestFlight task must push its accepted source internally and sync corresponding
  public source before completion. Verify remote heads and report commit IDs, checks,
  excluded work and concrete blockers. Do not make empty commits or rebuild unchanged
  shipped code just for source synchronization.
- For build/test/upload tasks, follow [RELEASING.md](RELEASING.md#build-and-installation-cleanup).
  Reuse one DerivedData directory per platform/configuration under `.local/build/`;
  never clean another task's active build. After dependent checks, preview
  `python3 scripts/clean-build-artifacts.py`, then run it with `--apply`.
  Preserve source, user data, evidence and matching symbols; remove disposable
  compiler output, test clones and redundant app/archive copies safely.
