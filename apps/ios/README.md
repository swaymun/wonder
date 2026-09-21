# Wonder native enrollment

Open `Wonder.xcodeproj` in Xcode. The Wonder scheme targets iPhone and iPad, iOS 17+. Its local Swift package is `../native`.

```sh
swift test --package-path apps/native
swift test --package-path apps/menubar
cargo test -p wonder-api pairing --lib
cargo test -p wonderd enrollment_tests --lib
xcodebuild -project apps/ios/Wonder.xcodeproj -scheme Wonder -configuration Debug -sdk iphonesimulator build
xcodebuild -project apps/ios/Wonder.xcodeproj -scheme Wonder -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Debug builds use `com.saimun.wonder.native` (version `0.1.0`) to preserve the existing paired development installation. Release builds use `com.swaymun.wonder` (version `1.0`), matching App Store Connect app `6810059586`. Both use team `8KKNVD7758`; increment the build number before uploading a subsequent build. The Mac companion keeps its existing signing identity.

The Release app has a separate app container and default Keychain access group. Installing it does not upgrade the Debug app or transfer its pairing: keep the existing app installed and pair the Release app separately. The legacy Keychain service label remains unchanged so Debug builds can still find their saved credentials.

A local compilation/archive check without provisioning changes is:

```sh
xcodebuild -project apps/ios/Wonder.xcodeproj -scheme Wonder -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/Wonder-release-check.xcarchive CODE_SIGNING_ALLOWED=NO archive
```

This unsigned archive cannot be installed or uploaded. Distribution still requires matching signing/provisioning, a signed archive/export, fresh pairing and device acceptance. The app record alone does not establish TestFlight readiness. Push registration/APNs delivery and the share extension are separate implementation gates; this identifier change does not enable them.

Use normal simulator signing: disabling signing prevents Keychain access. Physical devices require Developer Mode, an unlocked device, and a development provisioning profile. The checked-in development team is the existing owner's team; choose your own team for another installation.

On the Mac, open Wonder's settings → Phones and tablets, then create a pairing code. Scan the QR inside the native app, paste its complete pairing link, or enter the HTTPS Mac address and the alternative code. Compare the verification text and confirm the device on the Mac. Creating or scanning an offer alone grants no access.

The app uses a Secure Enclave P-256 identity on physical devices. The encrypted key representation and connection credentials live in device-only, when-unlocked Keychain items. Simulator builds use a simulator-only software key in Keychain. Redirects during API requests are rejected. Renewal validates both the original Mac installation identity and the device identity before signing.

Device approval remains valid until revoked. Individual session credentials last at most one hour and renew using the approved device key. Revoke a lost phone from the Mac; it does not need to be present. Removing a saved connection on the phone clears local credentials; it does not revoke the server's device record.

Chats includes Bot/Group history, saved reading positions and host-partitioned cached content. Foreground replay uses the daemon's authenticated `/api/v1/sync/checkpoint` endpoint; install a matching daemon build for recovery. Direct Bot conversations now support persistent drafts, sending, delivery reconciliation and live response refreshes. The review stack adds Group sending, Guide/Stop, questions, files and a direct Bot queue. Remote viewing/control remain unavailable. Removing a connection deletes that host/device partition's cache and intent in addition to credentials.

Long-press a Bot or Group in Chats to open the native context menu: **Archive**, then **Advanced → Copy ID / Delete**. Copy ID copies the conversation ID and works offline. Delete requires confirmation and uses the existing Bot or Group deletion endpoint; Bot deletion first archives it, preserving active-work and Group-lead safeguards. The confirmation describes what will be removed. Both the combined computer list and the single-computer list share these actions.

Bot settings has one compact **Avatar** section: a horizontal character row with names and a selected check, then a horizontal row of color dots. Colors keep accessible names and selected state, with 44 pt hit targets. The saved selections scroll into view. iOS avatar paths are compiled from the SVG originals, preserving the crescent, rings, facets and facial details.

Chat rows use one trailing indicator: a spinner while working, a white dot for unread activity, or blank when read and idle. Working takes priority over unread. The navigation chevron is hidden; the whole row still opens the conversation. Read status clears after the latest message is visible and the Mac confirms it, with bounded retries for transient failures.

Tool image previews stay inside the **Working / Worked** disclosure, immediately after the activity that produced them. Collapsing it hides those previews. Verified files explicitly attached to a final message remain with that message; completing a turn does not promote every working image into the conversation. Inline images omit repeated filename captions; their accessible preview labels and full file details remain available.

Working activities include explicit presentations for timed waits, additional instructions, agent updates, review transitions, and conversation summarization. Wait details show the requested duration; an interrupted wait does not claim that duration elapsed. Activity status follows the recorded lifecycle, and expanded details omit internal agent paths and identifiers.

Draft photo attachments appear as compact thumbnails inside the composer, with an individual remove button. Other files retain a compact filename chip. Restored attachments remain removable when their metadata or preview is unavailable. Removing a draft attachment preserves the message text, other attachments, and any accepted pending request.

Copy an image or screenshot, then hold in the message editor and choose **Paste** to add it as a draft attachment. Keyboard Paste uses the same path. Image pasting preserves the existing text and original image format, supports up to four total attachments of 8 MB each, and saves locally until sending. Text-only clipboard contents paste into the editor normally.

See [release qualification](../../RELEASING.md) for required device and distribution checks. Debug simulator builds support `-read-preview` for a synthetic conversation with no network or production cache access. This option is excluded from physical-device and Release builds.

The [release process](../../RELEASING.md) includes send recovery verification on the final paired artifacts. Drafts and the immutable pending request are committed together before HTTP submission. A lost reply is recovered from a matching snapshot or by checking the same submission ID and body. A daemon-reported unknown execution outcome never creates a new retry. Direct Bot follow-ups can enter the Mac-owned queue while work is active; Group queueing remains unavailable pending step 30. Live updates preserve row identity and reading position; Latest message provides an explicit jump. Command-Return sends when eligible.

For synthetic composer inspection, add `-send-preview` alongside `-read-preview`; add `-send-unconfirmed-preview` to show preserved pending text and a separate follow-up draft. These fixtures use memory only and disable network actions. They do not establish paired-device acceptance.

Use `-read-preview -composer-attachments-preview` for a staged photo and file, or `-read-preview -composer-restored-attachments-preview` for a restored photo and an attachment with missing metadata. `-composer-running-preview` and `-composer-queued-preview` add work and queue states to these fixtures.

See the [release checks and acceptance limits](../../RELEASING.md). `-files-preview -preview-document notes.pdf` and `-queue-preview` extend the existing simulator-only `-read-preview -send-preview` fixtures. These are synthetic local renders, not paired-device evidence.

## Reproducible Release preparation

Use a new private output directory and an explicitly selected build number:

```sh
scripts/archive-ios-release.sh 2 .local/ios-release-2
xcodebuild -exportArchive \
  -archivePath .local/ios-release-2/Wonder.xcarchive \
  -exportPath .local/ios-release-2/export \
  -exportOptionsPlist apps/ios/ExportOptions.plist
```

Choose a build number greater than the latest uploaded build for the release
version after checking App Store Connect; `2` above is an example, not a reserved
number. The script records source SHA and dirty status, validates the archive's
signature and Release identifier/build, and never overwrites an archive/log.
Build only reviewed clean source for a candidate. A signed archive may still use
a development profile and is not evidence of App Store distribution signing.

The export options use `app-store-connect`, local `export` destination and disable
automatic build-number changes. Neither command supplies
`-allowProvisioningUpdates`; missing signing/profile access fails rather than
creating credentials. The plist does not upload, invite testers or submit review.
After a successful export, inspect the IPA's identifier, signature, provisioning,
entitlements and build again before an authorized upload. Preserve the upload
receipt and processing result separately. See the [release process](../../RELEASING.md).

Release builds declare `ITSAppUsesNonExemptEncryption = NO` so App Store Connect can skip the recurring encryption questionnaire. The iOS app uses Apple-provided CryptoKit, Security and URLSession, with no third-party cryptography dependency. Reassess this declaration if encryption implementations or dependencies change. The archive script verifies the generated Boolean before export.
