# Self-hosted beta release qualification

Keep implementation, simulator/device verification and distribution acceptance
separate. Summarize public availability and limitations in [BETA_STATUS.md](BETA_STATUS.md).
Keep detailed qualification logs, personal-device captures and private findings
outside the public source tree; a checklist total is not a readiness percentage.

## Mac artifact

Select an existing Developer ID Application identity and build:

```sh
WONDER_APP_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
WONDER_NOTARIZE=1 \
WONDER_BUILD_VERSION=1.0.47 scripts/package-dev-app.sh .local/release/Wonder.app
scripts/package-macos-dmg.sh .local/release/Wonder.app .local/release/Wonder.dmg
xcrun notarytool submit .local/release/Wonder.dmg --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple .local/release/Wonder.dmg
xcrun stapler validate .local/release/Wonder.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 .local/release/Wonder.dmg
scripts/verify-macos-dmg.sh .local/release/Wonder.dmg 1.0.47
```

An authorized operator may pass an existing App Store Connect API key directly
to `notarytool` instead of a Keychain profile. Keep its private key outside the
repository. The DMG path requires no Developer ID Installer identity. Legacy PKG
scripts are not the beta distribution path.

Retain the notarization submission ID/status, app and DMG signatures, exact digest,
source revision/diff and dependency notices. Test the downloaded/quarantined DMG
with Gatekeeper, drag installation and first launch on a fresh Mac. Verify
permissions, runtime compatibility, private Serve, phone pairing, restart and
an upgrade with existing history/drafts/attachments. A locally development-signed
app has a different designated requirement from a Developer ID app; a test of a
development-to-development upgrade does not prove permission retention across
that signing transition. Do not edit TCC databases to claim a pass.

## Keeping Mac privacy grants across updates

macOS keeps Screen Recording and Accessibility for Wonder while each update
satisfies the requirement recorded when they were granted: bundle ID
`com.saimun.wonder`, signed by Developer ID team `8KKNVD7758`. Claude.app and
ChatGPT.app rely on the same kind of requirement. To avoid asking users again:

- Ship only Developer ID builds with that bundle ID and team. `package-macos-dmg.sh`
  rejects any other designated requirement; Sparkle also refuses a mismatched update.
- Keep helpers as plain executables in `Contents/Helpers` that Wonder starts as
  children. Never give a helper its own bundle ID or launch it through
  LaunchServices; that creates a second privacy identity.
- Update agent runtimes (the Claude Agent SDK in `~/.wonder/claude-runtime`, the
  ChatGPT runtime) outside the bundle. They run as Wonder's children and use its grants.
- Do not install Apple Development or ad-hoc builds over a Developer ID install;
  `install-signed-app.py` refuses a changed requirement for this reason.

macOS may still ask users to reconfirm Screen Recording periodically. That prompt
is independent of updates.

## iPhone/iPad artifact

After every completed change to the shipped iOS app, including affected shared
code, run relevant native/model and focused simulator UI checks, then upload both
Release channels sequentially. Both uploads have standing owner authorization;
no separate candidate approval is required unless the owner defers uploads.
Documentation, source-sync and tooling-only changes that do not alter the shipped
app need no new binary.

```sh
bundle exec fastlane ios beta channel:testing profile:release
bundle exec fastlane ios beta channel:production profile:release
```

Blue Wonder Testing installs beside orange Wonder with separate local data. See
[the Testing setup](apps/ios/TESTING.md).

Physical iPhone/iPad testing is optional for now and runs only when explicitly
requested. It must not block completion or TestFlight uploads. Report hardware,
cellular, APNs delivery and actual TestFlight installation as unverified when
they have not been exercised; simulator checks do not establish those results.

Use `~/.config/wonder/app-store-connect/upload.json` or `WONDER_ASC_CONFIG`.
Prefer the encrypted Match/manual-signing path. Never fall back silently to
Apple-ID signing or create a new certificate/profile without current approval.
Inspect the exported APNs entitlement, topic and production environment. Verify
Release excludes diagnostic recorder/UI/fixtures and retain matching dSYMs.
Record upload, Apple processing, internal availability, external review and actual
TestFlight installation as separate results. The upload lane does not submit
beta review or change tester groups.

## Network, push and product gates

Use these to report product qualification. Mobile checks requiring physical
hardware are optional under the current policy above, including for a public
prerelease; retain their unverified status rather than making them release blockers.

- Real screen frames and visible input effects through Tailscale; HTTPS alone
  does not pass media. Cellular/independent-network testing remains separate.
- Parent-owned subagent pill, running/completed transitions, long transcript,
  medium/large sheet, accessibility, draft and reading-position restoration.
- Completion/attention APNs delivery while backgrounded and terminated; denied
  permission, stale/rotated tokens, duplicates, device revocation and correct
  parent conversation routing across multiple Macs.
- Direct/Group messages, approvals, queues, attachments, scheduler recovery,
  Mac sleep/restart and phone network changes.

Teaching capture and taught-task replay are excluded from this beta. Before
re-enabling them, qualify genuine changed-input teaching replay; capture/save
alone is insufficient. Existing stored teaching data must remain intact.

Before making source public, inspect every selected file and every commit that
will be published for credentials, private evidence, account identifiers,
proprietary reference apps, IPAs, extracted bundles, model data and oversized
artifacts. For a fresh public repository, review the clean export and its initial
commit; the historical private repository remains private and is not imported.
Retain the findings report privately. Resolve findings in selected files before
publishing; excluding private history does not clear findings in the export.
Review dependency licenses and include notices in binaries. MIT applies only to
Wonder-owned material.

Create the GitHub Release only after those gates are accepted. Publish the
notarized DMG, its digest, supported matrix, known limitations and source revision;
exclude reference apps and local diagnostics. Publish the matching signed update
feed only after the archive is accessible anonymously. Keep manual signed downloads
available alongside automatic updates.

## Automatic Mac updates

Wonder uses the pinned Sparkle framework, its standard consent and preferences,
Developer ID verification, and an EdDSA-signed archive. The private signing key
stays in the release operator's login Keychain under account `wonder-public-beta`.
Never export it into source, an app bundle, a website or a CI log. The public key
and HTTPS feed URL are committed in the Mac Info.plist.

After building, notarizing and stapling a new monotonically numbered DMG, generate
its feed with the existing Sparkle tools:

```sh
python3 scripts/generate-sparkle-appcast.py \
  --dmg .local/release/Wonder-1.0.80.dmg \
  --asset-url https://github.com/swaymun/wonder/releases/download/mac-v1.0.80-beta.1/Wonder-1.0.80.dmg \
  --version 1.0.80 --output .local/release/appcast.xml
```

Use the actual candidate version and source tag. GitHub's `latest/download` path
does not select prereleases. Publish the exact verified archive first, then the
generated feed at the configured Sites `/updates/appcast.xml` path. Preserve its
bytes and signature, serve it as XML, and check both URLs without authentication.
Do not change the feed to advertise a missing or unqualified download.

Before accepting the updater, install a real signed version N and upgrade it to
signed/notarized N+1 through Sparkle. Verify consent and opt-out persistence,
manual checks, automatic downloads, busy-work and computer-sharing deferral,
complete launcher shutdown, one relaunch, `/readyz`, and preserved pairing/history.
An authenticated local-owner admission lease prevents new work during the final
shutdown; cancellation or expiry must restore normal admission. Test malformed
or incorrectly signed updates without altering the installed signed bundle.
Unit tests and lifecycle fixtures support this check but do not replace it.

## Public release handoff

Start from the final reviewed source revision, with no unrecorded source changes.
Use a monotonically increasing Mac build version; `1.0.47` above is the prepared
candidate, not a permanent version to reuse. Retain the source commit, dirty diff
and untracked-source snapshot when qualifying an uncommitted candidate. A GitHub
tag must identify the committed source actually used to build its DMG.

Before a public prerelease:

1. Verify the public vendor installer’s runtime with Wonder’s packaged verifier.
   An installed development runtime passing is not enough. If unavailable or
   incompatible, keep the release blocked; do not relax runtime checks.
2. Review every file and commit intended for publication. A fresh export starts
   with only its reviewed initial commit; do not copy private historical branches
   or tags. For later public releases, review all newly published commits too.
3. Complete fresh-Mac install and upgrade and relevant simulator/integration
   checks. External TestFlight installation and physical mobile acceptance are
   optional for now. Keep detailed evidence privately and summarize unverified
   behavior and remaining limits in `BETA_STATUS.md`.
4. Run `python3 scripts/verify-release-docs.py` and validate external links. Ensure
   screenshot provenance matches the shipped UI, with no personal content.
5. Prepare a GitHub prerelease with the verified DMG, a `SHA256SUMS` file, supported
   configurations, known limitations and source revision. Enable README download
   and TestFlight links only after the associated public assets are accessible.

Source-build CI follows `cmd/wonder-tunnel/go.mod`; push checks run separately
with Node 22. The docs check is offline and does not establish external link,
Gatekeeper, TestFlight, or physical acceptance. The DMG verifier mounts read-only,
checks the Applications shortcut, payload signature/version and notices, then
unmounts. It does not launch the app or modify installed user data.

Retain a compact release report and symbols. Run the build-cleanup script in
preview mode, then apply only after dependent checks are complete. Keep the final
DMG and its digest; remove redundant app staging copies after verification.

## Build and installation cleanup

- Reuse one DerivedData directory per platform/configuration under `.local/build/`.
  Keep it until dependent tests, installation and verification finish. Never clean
  a directory another build/test uses.
- Reuse named simulators: `Wonder Beta iPhone WS2`, `Wonder Connected QA`,
  `Wonder Overnight iPhone QA`, `Wonder Overnight iPad QA`, `Wonder Group iPad QA`.
  Shutdown fixtures are still retained fixtures. Prefer
  `-parallel-testing-enabled NO` for focused UI/Diagnostics runs. Record temporary
  UDIDs and remove only those destinations after stopping the run.
- After simulator tests, inspect `xcrun simctl list devices`. Use
  `xcrun simctl delete unavailable` only after checking no required runtime/fixture
  is affected. Preserve named fixtures and paired physical-device records.
- Before cleaning `~/Library/Developer/XCTestDevices`, confirm no `xcodebuild` or
  `xctest` process is active and entries are generated `Clone ...` devices. Use
  Xcode's supported cleanup or narrowly clean that verified clone root; never a
  broad Library path. Verify removal and record substantial before/after disk use.
- Once dependent checks finish, preview `python3 scripts/clean-build-artifacts.py`,
  then run with `--apply`. It retains source, logs, test results and crash symbols.
  The archive script clears its own DerivedData after verifying a signed archive.
- After Apple confirms processing, retain upload/build metadata, matching dSYMs,
  source commit, dirty diff and untracked-source snapshot. Remove redundant IPAs,
  exported app copies and archive app/products. Retain unresolved upload packages
  until Apple status is known.
- Compress/deduplicate dSYMs under `.local/symbols/` with an original-path index.
  Verify archived file hashes before deleting originals; extract for symbolication.
- Keep `/Applications/Wonder.app` as the single installed Mac version. After
  signature, launch and `/readyz` pass, remove superseded app bundles in staging,
  `~/Applications` and `~/.wonder/Backups/signed-update-*`. A rollback app may remain
  during validation. Preserve pairing, databases, credentials, runtime/model data
  and source backups.
- Remove an obsolete worktree only when clean, reachable from `main` and unused
  by any process/task. Use `git worktree remove`, inspect ignored contents before
  forcing removal and prune stale metadata.
- Keep compact final reports and relevant crash/failure evidence. Avoid duplicate
  screenshots, repository copies and repeated test bundles for unchanged code.
  Record substantial disk savings and deliberately retained large artifacts.

## Prepare a clean public source tree

Review `scripts/public-source-files.txt` before export. It is the exact file
inventory: new files are not included automatically. Keep private history,
evidence, reference media and credentials outside it. From the reviewed checkout:

```sh
python3 scripts/test-export-public-source.py
python3 scripts/export-public-source.py --output .local/public-source/source --report .local/public-source/audit
python3 scripts/export-public-source.py --verify .local/public-source/source --report .local/public-source/verified
```

Use a new output path for each export; the tool refuses to overwrite an existing
tree. It copies selected bytes and executable flags without Git history or local
metadata. Reports stay outside the export and record exact hashes, exclusions and
findings without including matched credential values. Automated checks cannot
certify privacy or redistribution rights: review the inventory and assets, then
run the documented checks from the exported tree before creating its initial
public commit. Build the final release from that reviewed source revision.
