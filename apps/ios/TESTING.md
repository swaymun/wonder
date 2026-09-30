# Wonder Testing for iPhone and iPad

Wonder Testing uses the same product source as Wonder, with a blue icon and its
own app identity. Install it beside orange Wonder, pair it separately with your
Mac, and use it to approve a candidate before updating the main app. Local
pairing, Keychain access, preferences and drafts remain separate. Both clients
can still read and change the same conversations on the paired Mac.

| Channel | App ID | Display name | Icon |
| --- | --- | --- | --- |
| Production | `com.swaymun.wonder` | Wonder | Orange |
| Testing | `com.swaymun.wonder.testing` | Wonder Testing | Blue |

The Xcode `WonderTesting` scheme runs and archives the optimized `Testing`
configuration. Its tests use `TestingDiagnostics`, which includes the existing
bounded Diagnostics tools. Regular Testing uploads use Release behavior, without
the recorder. Each channel includes matching `.NotificationService` and `.Share`
extensions; their Keychain access is confined to their own channel.

## Upload and promotion

```sh
bundle exec fastlane ios validate channel:testing
bundle exec fastlane ios beta channel:testing profile:release
```

Testing is the lane and archive script default. Each app has an independent
increasing build number. The existing API key is reused with the selected app ID;
no private key is copied into source. Production requires explicit owner approval
of the candidate, then:

```sh
bundle exec fastlane ios beta channel:production profile:release
```

A passing test or processed Testing build does not authorize production promotion.
Do not install a production-identity Diagnostics build over the owner's orange app.
No Mac testing app is part of this workflow.

## Apple setup

Create one App Store Connect record for `com.swaymun.wonder.testing`, named
**Wonder Testing**, using iOS (which includes iPad). It is a separate app record,
not another version of the existing Wonder record.

Apple Developer needs the Testing app ID with Push Notifications enabled, plus
`com.swaymun.wonder.testing.NotificationService` and
`com.swaymun.wonder.testing.Share` with no additional capabilities. The production
share extension separately requires `com.swaymun.wonder.Share`. There is no App
Group to create: Share reads the containing app's existing Keychain access group
and never renews or writes its saved connection.

Each ID needs an App Store provisioning profile saved in encrypted Match using
the existing Apple Distribution certificate. Profile creation requires explicit
owner approval. The normal upload lane remains read-only for signing assets.

For physical QA, use the approved Testing development profiles. Set
`WONDER_APP_SIGNING_STYLE=Manual` and supply `WONDER_MAIN_PROFILE`,
`WONDER_PUSH_PROFILE` and `WONDER_SHARE_PROFILE` to `xcodebuild` with the
`TestingDiagnostics` configuration. Test runners retain automatic signing and
can reuse an installed Xcode-managed development profile; this does not require
`-allowProvisioningUpdates` or new certificates.

## Share to Wonder

Recovered from the earlier Claude share-sheet work, the extension accepts text,
links, and up to four photos/files (8 MB each). Select a Mac and an existing Bot
or Group, add a note, then Send. The Testing extension is named **Wonder Testing**
in the system share sheet. If pairing has expired, open that same app to reconnect.
Retrying the same send while the sheet remains open retains the message identity.
Closing the sheet does not retain a durable send outbox. Projects are not yet
share destinations.

Read-only QA stages an image, loads chats and cancels without sending. Actual Send
starts model work and requires explicit authorization or an owner-performed test.

## Current limitation

The installed Mac and hosted notification service currently advertise only the
production app's APNs topic. Testing retains identity validation and cannot enable
notifications against that service. Chat, files and share-sheet reads can use the
same Mac. Testing notification delivery requires a separately configured service
and compatible host routing; the blue app alone does not provide it.

## Icon provenance

The blue icon was generated with the built-in ImageGen tool from the existing
orange app icon. Prompt: change only the palette to sky/cobalt blue, a pale icy-blue
background and navy facial features; preserve the smiling half-sun, five rays,
composition and texture; no text, badge or outer mask. The generated artwork was
resized to 1024 square for the app asset catalog. The orange source is unchanged.
