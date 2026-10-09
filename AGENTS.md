# Wonder agent guidance

Wonder is a native messenger for persistent agent conversations and Projects.
Keep the experience understandable without knowledge of the App Server protocol.
Apply guidance to the current implementation; verify callers before carrying
forward rules for an older feature or workflow.

## Working method

- Define done as a check that can pass or fail, plus the evidence that proves it:
  command output, the stored value, or a capture of the real app. Label each claim
  as measured, inferred or guessed. Never hand the user a check you could run.
- Reproduce a defect on the affected surface before fixing it, then fix the root
  cause. After two fixes sharing one premise fail the same check, question that
  premise instead of writing a third fix.
- When a "which approach" question can be answered by running something (behavior,
  layout, timing, performance), prototype and let the result decide. Ask only for
  product or preference calls and actions this file does not already authorize.
- Proceed on reversible work and report what you did. Give real judgment: decline
  scope or an approach that does not earn its place rather than agreeing by default.
- For repetitive edits, audits or checks, write the script or codemod that does or
  proves the work and keep it rerunnable instead of working by hand.
- You own delegated work. Review a subagent's diff and evidence yourself; give
  follow-up work to a fresh agent with the consolidated brief rather than trusting
  a "done" summary.
- For long or unattended runs, keep a short decision log under `.local/` and report
  the decisions that changed the outcome.
- When the user corrects a repeated mistake, fix it at the strongest layer that
  works: one owner in the architecture, then types, then a lint or CI check whose
  error names the fix, then a test. Add a rule here only for judgment calls, and
  drop a rule once something enforces it.

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

- Put the evidence for every user-visible change on its pull request, not in a
  separate document. Capture the actual app (never a mockup or an old capture),
  upload with `scripts/pr-evidence upload --pr N --label before|after FILES` and
  show Before/After in the PR description. Label evidence as simulator, Mac or
  physical device and state limitations. If a capture is impossible, say so in
  the PR rather than claiming verification. CI adds the scenario results for both
  simulators, and the release workflow adds TestFlight builds, as PR comments.
- Prove iOS behavior with `scripts/wonderctl` scenarios on `iphone` and `duo`
  rather than screenshot-driven computer use; run them on this Mac's simulators
  (no `--host`) while developing. CI runs the feature map on the Mac mini for
  every pull request. See [apps/ios/CONTROL.md](apps/ios/CONTROL.md). Extend the
  feature map when you add user-visible behavior. Run the scenarios a change
  affects locally before opening its PR.
- A scenario must not depend on state an earlier run left (saved settings, a
  previous install, a shared cache): select the state it needs. Hold a brief state
  (a progress overlay) in its fixture rather than lengthening the wait. Treat a
  "flaky" failure as a deterministic bug until its screenshot says otherwise; read
  it before rerunning.
- **For now, physical iPhone/iPad testing is optional and runs only when explicitly
  requested.** Use relevant unit/model/contract checks and focused simulator UI
  checks by default. Physical sessions, mirroring and device availability must not
  block completion or TestFlight uploads. Report hardware-only behavior as unverified.
- For Mac UI checks and other computer use, prefer the installed Codex Computer
  Use MCP server `cua_repl` (manifest under
  `~/.codex/plugins/cache/openai-bundled/unified-computer-use/<version>/.mcp.json`;
  tools `js`, `js_reset`, `turn_ended`) over Claude computer use. GPUI windows do
  not repaint while occluded, so bring the window forward before capturing.
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
- CI skips `RelayKeychainTests` (`apps/native-relay`) because the Mac mini runners
  cannot use the login Keychain. When a change touches `RelayKeychain` or how the
  relay identity is stored, run them on a developer Mac with
  `WONDER_LOCAL_BUILD=1 WONDER_RELAY_LIB_DIR="$PWD/$(apps/native-relay/scripts/build-relay-ffi.sh macos)" swift test --package-path apps/native-relay --filter RelayKeychainTests`
  and report the result under Verification in the PR.
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
- Uploads are automatic: when an iOS change merges to `main`, the Wonder Release
  workflow uploads both channels from the Mac mini and comments the build numbers
  on the PR. Check that comment. To upload by hand (a failed or deferred release),
  run these sequentially from the repository root on a pushed commit (see
  [fastlane/USAGE.md](fastlane/USAGE.md)):

  ```sh
  scripts/wonder-remote --ref HEAD --signing --lock testflight -- bundle exec fastlane ios beta channel:testing profile:release
  scripts/wonder-remote --ref HEAD --signing --lock testflight -- bundle exec fastlane ios beta channel:production profile:release
  ```

- Develop on the MacBook: run agent sessions, Rust/Swift/Xcode builds and test
  suites locally. The Mac mini (marked by `~/.config/wonder/is-build-host`) is
  reserved for the two self-hosted CI runners and their simulators, TestFlight
  uploads and Mac signing/notarization; use `scripts/wonder-remote` only for
  signing, notarization and release. Do not run agent sessions on the mini.
- Keep at most 2–3 concurrent agent sessions, each in its own worktree. Keep at
  most two app PRs waiting on CI; land a stack one PR at a time. One session at a
  time changes CI, workflows or `wonderctl`; others report problems to it.

- Keep blue `com.swaymun.wonder.testing` and orange `com.swaymun.wonder` identities,
  pairing, drafts and Keychain access separate. Do not install development or
  Diagnostics builds over orange Wonder. The Mac has no separate testing variant.
- **After a completed change to the shipped Mac companion (`apps/desktop`,
  `apps/menubar`, the daemon or bundled helpers), a Developer ID signed, notarized
  and stapled Mac release installed to `/Applications/Wonder.app` is likewise
  standing-authorized when needed.** Follow [RELEASING.md](RELEASING.md#mac-artifact)
  with the next monotonic build version: build, sign and notarize on the Mac mini
  with `scripts/release-mac.sh` through `scripts/wonder-remote --ref HEAD`, install
  here with `scripts/install-mac-dmg.sh` and record the version in `BETA_STATUS.md`. Once the installed app passes its health checks, delete the
  installer's rollback bundles (`~/.wonder/Backups/signed-update-*`); do not keep
  old app backups. Publishing a GitHub release or appcast still needs approval.
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
- The internal Owner Beta group automatically distributes new Wonder Testing
  Xcode builds to its existing tester. Verify each processed build's group
  membership and internal testing state with the read-only App Store Connect
  check in the beta lane (or `verify_testing_distribution build:NUMBER`). Do not
  manually assign builds in the normal flow. Preserve Owner Beta Legacy as
  history. New tester invitations, beta-review submissions and other group
  changes still require explicit authorization.

## Delivery and cleanup

- Deliver every change as a pull request that merges itself. Work on a branch
  (`agent/<topic>`), stage only intended paths, push, and open it with
  `gh pr create --label automerge` using the PR template: what changed for the
  user, Before/After evidence, Verification (what was and was not checked) and
  the model that made it. CI squash-merges it once every job passes; fix failures
  on the same branch. CI runs only the jobs a change needs (`scripts/ci-changes`),
  so docs-only PRs merge within minutes. Do not push to `main` directly. Preserve concurrent
  work without reset/stash/force-push.
- If selected public source changes, sync the existing public checkout using
  [RELEASING.md](RELEASING.md) and `scripts/public-source-files.txt`. Review new
  inclusions, run the audit and verify bytes/executable modes. Make a separate public
  commit; never publish internal history, private evidence, credentials or artifacts.
- After a merge that ships an app, check the release comment on the PR and sync
  corresponding public source before completion. Verify remote heads and report commit IDs, checks,
  excluded work and concrete blockers. Do not make empty commits or rebuild unchanged
  shipped code just for source synchronization.
- Once your PR merges, delete its worktree and branch: run `scripts/prune-merged-worktrees`
  and then `--apply`. It removes only clean worktrees and local branches whose PR merged,
  and moves their `.local/` evidence to the main checkout. GitHub deletes the remote
  branch on merge. Each Rust/iOS worktree holds several GB.
- For build/test/upload tasks, follow [RELEASING.md](RELEASING.md#build-and-installation-cleanup).
  Reuse one DerivedData directory per platform/configuration under `.local/build/`;
  never clean another task's active build. After dependent checks, preview
  `python3 scripts/clean-build-artifacts.py`, then run it with `--apply`.
  Preserve source, user data, evidence and matching symbols; remove disposable
  compiler output, test clones and redundant app/archive copies safely.
