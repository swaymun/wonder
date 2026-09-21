# Wonder TestFlight

Use a managed Ruby (3.3 or newer) with Bundler. From the repository root:

```sh
bundle install
bundle exec fastlane ios validate
bundle exec fastlane ios beta
```

`validate` checks the local private key and release inputs without contacting
Apple. `beta` installs the encrypted Match signing assets into Wonder's
dedicated keychain, archives and exports with manual signing, uploads, and waits
up to 30 minutes for Apple processing. It uses the next build number reported by
App Store Connect; an explicit higher number can be supplied with `build:123`.
Run one upload at a time.

Credentials default to `~/.config/wonder/app-store-connect/upload.json`.
`WONDER_ASC_CONFIG` can override that location. The JSON fields are `keyId`,
`issuerId`, `privateKeyPath`, and `appBundleId` (`com.swaymun.wonder`). Keep the
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
renewal.

This lane supports an upload-only Developer key. It does not edit release
notes, tester groups, review submissions, or notification preferences. The
upload action skips its distribution phase, followed by fastlane's read-only
build watcher. Existing App Store Connect automatic distribution settings may
still apply. Processed does not mean tester availability was verified.

Evidence is saved in a fresh `.local/testflight-*` directory. If processing
times out, inspect `upload-result.json` and App Store Connect before retrying;
the upload may already have succeeded. Do not rerun blindly or reuse a build
number Apple has accepted. A failed archive/export has no successful upload
result. Archive logs and identity/encryption checks use the existing script.

Gemfile.lock pins dependencies. Analytics and update checks are disabled.
