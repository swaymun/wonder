# Wonder macOS integrations

GPUI owns Chats, the menu-bar launcher, Settings and setup. This package builds the windowless `WonderMacBridge` integration process; it has no SwiftUI dependency or Wonder windows. Its JSON-lines stdin/stdout protocol carries settings actions and display snapshots to GPUI. Pairing secrets and the loopback capability are not logged.

The existing native models retain pairing verification and expiry, signed computer-use permission checks, file-access review through macOS file dialogs, `SMAppService.mainApp` registration and Sparkle. Initial setup applies the existing launch-at-login default once and preserves later user choices. The launcher supervises the daemon and tunnel; closing a GPUI window keeps Wonder running, while Quit Wonder stops both.

`scripts/package-dev-app.sh` builds the development app. Wonder uses `/Applications/ChatGPT.app/Contents/Resources/codex` by default, or an explicit `WONDER_CODEX_BIN` override. ChatGPT must be installed. Startup verifies the tested `codex-cli 0.155.0-alpha.9` version, both protocol schema hashes, and that the adjacent `codex-code-mode-host` can execute. ChatGPT owns runtime installation and updates; Wonder's repair action checks it without modifying ChatGPT or downloading another copy. An incompatible ChatGPT update blocks execution until Wonder's compatibility check is updated; saved chats remain intact. Old Wonder-managed runtime directories are left unused on disk.

The executable path does not provide access to ChatGPT's private app connections or computer-use session. Wonder's existing computer-use boundary remains in force. `python3 scripts/test-code-mode-runtime.py /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host` verifies JavaScript execution and nested tool delegation offline, without a model call. `python3 scripts/test-runtime-selection.py` exercises runtime-selection failures without touching the host installation.

Sparkle remains a bundled dependency, but the self-hosted beta uses signed manual downloads. Automatic updates are unavailable. Follow the [installation guide](../../INSTALL.md#updates-and-existing-installations) to replace the app while preserving its separate data. Private signing keys never enter the app.

See [release qualification](../../RELEASING.md) for installation, distribution and physical-device checks. A generated development app is not a qualified public release.
