# Wonder push-only service

This Worker carries encrypted reply, approval and question previews through APNs,
with generic fallback alerts. It is not
a chat relay and has no Wonder account login. The official app can use the official
provider with any compatible Mac host, including a source-built host.

An independently signed iOS build needs its own Apple App ID with Push
Notifications, a matching entitlement/provisioning profile, an APNs authentication
key, and a Worker deployment. APNs topic, Apple team and environment must match.
An App Store Connect upload key is not an APNs key.

## Deploy your own

Use Node/npm and your Cloudflare account. Copy `wrangler.jsonc` to a local config,
choose your Worker/database names, then create a D1 database and put its ID in that
config. Set `APNS_TOPIC` to the iOS bundle ID and `APNS_ENVIRONMENT` to `production`
for TestFlight/distribution or `sandbox` for development-signed installs.

```sh
npm ci
npx wrangler login
npx wrangler d1 create your-wonder-push
# Edit database_id, Worker name, topic and environment in your config.
npx wrangler d1 migrations apply your-wonder-push --remote
npx wrangler deploy
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_PRIVATE_KEY < /private/path/AuthKey_KEYID.p8
# Supply a cryptographically random, private rate-limit hashing secret.
npx wrangler secret put RATE_SECRET
npm run check
npm test
```

Use `--config /path/to/config.jsonc` consistently for a separate config. Never
commit key files, `.dev.vars`, or secret values. Set the Mac's
`WONDER_PUSH_ENDPOINT=https://your-worker.your-subdomain.workers.dev`,
`WONDER_PUSH_TOPIC`, and `WONDER_PUSH_ENVIRONMENT` before launch. The endpoint must
be an HTTPS origin, without credentials, a path, query or fragment.

In the phone's connection settings, turn on **Notifications**. Enrollment
requires a signed challenge delivered to that specific phone through APNs. The
public HTTP challenge endpoint alone cannot authorize alert delivery. The app
retains a separate signing key and sending capability for each paired Mac. The
Mac verifies provider registration before storing the capability. There is no
shared credential embedded in an app binary.

## Delivery and retention

The Mac durably records completion/attention intent with the corresponding event
or question transaction, then distributes it to authorized devices. Notification
payloads contain generic fallback text, random registration/routing identifiers
and optional AES-256-GCM ciphertext. Only the Mac and phone hold the per-registration
preview key. A native notification service extension decrypts on the phone, even
when the app is closed. The Worker neither decrypts nor persists previews. Parent
conversation lookup remains on the Mac and is scoped to the requesting device.
Group workers and verified subagents do not generate duplicate completion alerts;
attention routes through their persisted parent ownership.

Previews use the exact completed turn or still-pending request. They are bounded
excerpts, not complete transcripts or attachments. Missing keys and authentication
failures retain the generic fallback. iOS controls lock-screen preview visibility.

Wonder suppresses banners and sounds whenever it is in the foreground. A signed
per-device heartbeat, sent to every enabled paired Mac every 15 seconds, suppresses
new and queued deliveries there too. Foreground arrivals stay suppressed after
leaving the app. Leases expire after 45 seconds if the phone disconnects; a background
transition clears them immediately when reachable. A network race may still send
an in-flight push, but iOS foreground presentation remains suppressed.

Source-built apps must embed `WonderNotificationService` and sign both App IDs.
Set `WONDER_APP_BUNDLE_IDENTIFIER` for both targets and retain the matching shared
Keychain group. Only preview keys enter that group; existing pairing credentials
stay in the app's original private group. APNs authentication keys stay in the Worker.

Registration renews on token changes and at least every 30 days when the app is
active. Enable it in the foreground: APNs background delivery is not guaranteed.
The toggle persists intent before connecting and has no connection/success subtext.
Temporary setup failures retry while foregrounded with exponential delays capped
at five minutes; reopening retries immediately. Permission, signing-identity or
configuration failures that need action turn the preference off and show an alert.
Turning off cancels setup immediately and queues revocation across disconnects.
Revocation is per
registration; a Mac device revocation also cancels durable deliveries and queues
provider revocation. Unknown/stale tokens fail closed.

The Worker bounds enrollment and delivery requests, deduplicates delivery intent,
and permits at most five send attempts. APNs collapse IDs reduce duplicate visible
alerts after an uncertain transport outcome; this is not an exactly-once delivery
guarantee. The Mac retries with bounded backoff for at most 24 hours. Routes and
intent history expire after seven days.

Provider metadata is limited to:

- APNs tokens, device public keys and hashes of per-device sending capabilities;
- ten-minute enrollment challenges;
- opaque event/routing IDs, delivery state, attempts and timing retained seven days;
- salted IP hashes in Cloudflare's short-lived edge limiter, and opaque/token-hash
  quota counters in D1, removed after seven days without use;
- registrations removed after 90 days without renewal.

Hourly cleanup expires records. Workers observability/logging is disabled in the
template. Cloudflare and Apple still process network/delivery metadata under their
own services. Account-level logs/backups have separate retention; review them when
deploying your own service. No conversation text, file, screenshot, email account,
Mac address or model credential belongs in this service.

## Cost and limits

The ordinary successful delivery performs four D1 row writes: one device quota,
one global quota, one receipt claim, and one completion. Expiring that receipt
adds one write. Duplicate delivery requests read the receipt without writing it
or spending another delivery quota. Enrollment, revocation, failed/retried sends,
and quota reclamation add work beyond this five-write lifetime budget.

Migration `0002_push_write_budget.sql` preserves receipts and current quota counts.
It uses `WITHOUT ROWID` tables to avoid duplicate primary-key index writes, and
reuses quota rows across hours. The hourly receipt sweep scans the seven-day
retention window instead of maintaining an expiry index on every delivery.
At 10 million sends per 30 days this is about 2.33 million retained receipts and
1.68 billion scanned rows per month. The local workerd scale test exercises that
full window; it does not certify production latency or burst capacity. Revisit
partitioning/indexing if production sweep time approaches the D1 query limit.

IP abuse is gated at 30 requests/minute by the native `IP_RATE_LIMITER` binding.
This gate is approximate and per Cloudflare location, not a global accounting
limit. Exact D1 quotas remain 60 send attempts/device/hour, 30,000 service-wide
attempts/hour, 300 enrollment challenges/hour and three challenges/token/hour.
Reusing a rate-limit namespace shares its counters; use a distinct `namespace_id`
when deploying another independent push service in the same Cloudflare account.

On the September 2026 Workers Standard pricing, 10 million successful sends use
the included 50 million D1 writes, before the extra work described above. The
$5/month account plan includes 10 million Worker requests and 30 million CPU-ms;
at an **assumed**, unmeasured 5 CPU-ms/request, execution adds about $0.40. Reads
fit the 25-billion-row allowance and fixture receipts occupy well below 5 GB.
Other projects share these allowances. This is a planning model, not a bill or
an all-in price guarantee; retries, enrollment, abuse and existing account usage
must be included in production estimates.

Sources: [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/),
[D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/), and
[edge limiter accuracy](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/#accuracy).

For an existing deployment, apply the migration and deploy the new Worker with
the rate-limit binding in one maintenance window. Keep registration/delivery
traffic quiescent during the migration/cutover so the old Worker cannot recreate
bucket-suffixed counters. The iOS/Mac HTTP contract is unchanged.

## Verify

Mocks prove authentication, deduplication and stale-token behavior; they do not
prove APNs delivery. Confirm actual foreground enrollment and alerts while the
app is backgrounded and terminated, denied permission, token rotation, revocation,
and the correct parent conversation after a Tailscale reconnect. Keep sandbox
and production results separate. `/healthz` reports configuration only.
