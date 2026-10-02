# Wonder TestFlight

Use a managed Ruby (3.3 or newer) with Bundler. From the repository root:

```sh
bundle install
bundle exec fastlane ios validate
bundle exec fastlane ios beta channel:testing profile:release
bundle exec fastlane ios beta channel:production profile:release
```

The default channel is **testing** (`com.swaymun.wonder.testing`), displayed as
**Wonder Testing** with a blue icon. It installs beside orange Wonder and needs
its own pairing. The Mac host and conversations can be shared. After every completed
change to the shipped iOS app, including affected shared code, run relevant checks
and upload both Release channels sequentially under standing owner authorization.
No separate candidate approval is required unless uploads are explicitly deferred.
Documentation, source-sync and tooling-only changes that do not alter the app need
no binary. Physical phone/tablet testing is optional for now and runs only when
explicitly requested; focused simulator checks are the default.
The profile (`release` or `diagnostics`) is
independent of the channel. Diagnostics uses the same identity within its channel.

`validate` checks the local private key and release inputs without contacting
Apple. `beta` installs the encrypted Match signing assets into Wonder's
dedicated keychain, archives and exports with manual signing, uploads, and waits
up to 30 minutes for Apple processing. It uses the next build number reported by
App Store Connect; an explicit higher number can be supplied with `build:123`.
Run one upload at a time.

Credentials default to `~/.config/wonder/app-store-connect/upload.json`.
`WONDER_ASC_CONFIG` can override that location. The JSON fields are `keyId`,
`issuerId`, `privateKeyPath`, and `appBundleId` (`com.swaymun.wonder`). The
lane reuses the credential but selects the exact app ID from the requested
channel; the Testing app record and its own profiles must already exist. Keep the
key and configuration private and outside Git. No Apple ID session is used.
Signing assets come from the private `swaymun/wonder-signing` Match repository.
Only encrypted Match files belong there. The encryption password is read from
the login Keychain service `wonder-fastlane-match`, and the dedicated signing
keychain password from `wonder-fastlane-keychain`. Environment variables
`MATCH_PASSWORD` and `MATCH_KEYCHAIN_PASSWORD` override those lookups for CI.
The keychain is `~/Library/Keychains/wonder-signing.keychain-db`; the lane
unlocks it only for signing and locks it afterward. GitHub authentication must
already allow cloning the private repository.

The normal beta lane is deliberately Match `readonly`. Certificate/profile
creation and renewal are separate operator actions so a release cannot silently
replace signing credentials. Bootstrap or renew with a reviewed Apple
Distribution certificate and App Store profile, import both into Match, then
verify the readonly lane before releasing. Never use `match nuke` for routine
renewal. For each channel the app, `.NotificationService` and `.Share` extensions each need an
App ID and App Store profile in Match; the upload key cannot register them.

This lane supports the existing upload-only Developer key. It does not edit
release notes, tester groups, review submissions, or notification preferences.
The upload action skips its distribution phase, followed by fastlane's read-only
build watcher. Wonder Testing's internal Owner Beta group has automatic
distribution enabled for Xcode builds. After processing, the lane uses the same
API key to confirm the build is in that group, has reached internal testing,
and the group has a tester. Only then does `upload-result.json` set
`testFlightReady: true`; otherwise it keeps the processed build recorded and
fails the availability check. Production uploads still report tester
availability as unverified. Recheck an existing Testing build without uploading
with `bundle exec fastlane ios verify_testing_distribution build:NUMBER`.
If verification fails, inspect Apple's group settings and the saved evidence
before considering another upload; Apple may already have accepted the build.

Evidence is saved in a fresh `.local/testflight-*` directory. If processing
times out, inspect `upload-result.json` and App Store Connect before retrying;
the upload may already have succeeded. Do not rerun blindly or reuse a build
number Apple has accepted. A failed archive/export has no successful upload
result. Archive logs and identity/encryption checks use the existing script.

Gemfile.lock pins dependencies. Analytics and update checks are disabled.
