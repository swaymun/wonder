# Build Wonder from source

For normal use, follow [the installation guide](INSTALL.md). Source builds require
Xcode with command-line tools, Rust/Cargo, Go matching `cmd/wonder-tunnel/go.mod`,
and an existing Apple signing identity. Node 22 or later is used for push Worker
development. Wonder does not install these tools automatically.

```sh
git clone https://github.com/swaymun/wonder.git
cd wonder
scripts/setup-self-hosted.sh
export WONDER_APP_SIGNING_IDENTITY='Apple Development: Your Name (IDENTIFIER)'
scripts/install-dev-app.sh
```

The preflight checks build tools, the installed runtime, and Tailscale without
changing your tailnet. The installer builds a signed app at `/Applications/Wonder.app`
and preserves the separate data home, host identity, and device records. Do not
replace a running app by copying individual executables into its bundle.

Known runtime versions and schema hashes are in `compatibility-manifest.json`.
Wonder discovers ChatGPT's current `Contents/Resources/codex-cli/bin/codex` launcher and falls back to its older `Contents/Resources/codex` location. `wonderd --locate-runtime` reports the selected path; `WONDER_CODEX_BIN` remains an explicit override. Discovery does not bypass runtime or protocol verification.
`WONDER_CODEX_BIN` selects an explicit executable for controlled development, but
it must pass the same local schema and helper checks. Newer compatible schemas
can pass without a Wonder update; changed required contracts still fail closed.
The preflight reports the installed version; startup performs the full check.

Mac packaging downloads checksum-pinned official Node bytes and installs the
Claude adapter’s locked production dependencies with lifecycle scripts disabled.
It signs the bundled native executables along with Wonder. Claude authentication
uses the official subscription login. The adapter strips API-billing environment
overrides; use Haiku 4.5 for inexpensive live acceptance. Live SDK probes and
private research are excluded from the public source inventory.

## iOS

Open `apps/ios/Wonder.xcodeproj`. Use the **Wonder** scheme for Release and
**Diagnostics** for local fixture and performance checks. Choose your signing
team, configure your main app and Notification Service Extension IDs and shared
Keychain group, and follow [push setup](services/push/README.md).

Debug/Diagnostics use sandbox APNs. TestFlight uses production APNs; the distribution
archive explicitly sets `WONDER_APNS_ENVIRONMENT=production`. The Mac supplies its
push endpoint, topic, and environment through the authenticated connection. The
phone rejects mismatched identities. Do not embed APNs keys or shared passwords.

## Checks

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all -- --check
swift test --package-path apps/native
swift test --package-path apps/menubar
(cd services/claude-runtime && npm ci --ignore-scripts && npm test)
(cd cmd/wonder-tunnel && go test ./...)
(cd services/push && npm ci && npm run check && npm test)
python3 scripts/verify-release-docs.py
```

The protocol authority is `packages/protocol/schemas/wonder-http-v1.json`.
Native tests and their fixtures use the product renderers; fixture success is not
physical device or network qualification. Read `apps/ios/DIAGNOSTICS.md` before
changing conversation rendering or performance tests.

For a signed DMG or TestFlight archive, use [RELEASING.md](RELEASING.md). Release
builds exclude diagnostic fixtures and recorder UI. Do not distribute proprietary
reference apps, extracted bundles, credentials, or local device evidence.
