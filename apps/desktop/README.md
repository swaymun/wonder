# Wonder desktop

GPUI Kit 0.6.0 desktop Chats, sharing the Swift clients’ compact messenger layout. The Mac menu launches this executable with its authenticated local daemon connection. Closing Chats leaves the daemon running.

```sh
cargo test --locked --manifest-path apps/desktop/Cargo.toml
cargo clippy --locked --manifest-path apps/desktop/Cargo.toml -- -D warnings
scripts/package-dev-app.sh /path/to/staging/Wonder.app
```

Open Chats from the packaged Wonder menu. Development launches require `WONDER_LISTEN_ADDR` (127.0.0.1 only) and `WONDER_LOOPBACK_CAPABILITY` from the same isolated daemon. Never put the capability in arguments or screenshots. `WONDER_DESKTOP_DATA_DIR` overrides the private draft directory.

Enter sends; Shift+Enter inserts a line break. Drafts and unconfirmed message identities survive restarts. Check delivery reuses the original request. Only one client can write the draft store. The host identity scopes drafts and fences reconnects.

Apps shows current installed service status for the Mac and links to allowlisted ChatGPT app pages. It does not grant access or resume waiting tasks.

This initial desktop slice supports direct Bot and Group text conversations. Tool previews, approvals, questions, Group editing, older-history pagination and full accessibility acceptance remain open. macOS build and real local sends are verified; Windows/Linux packaging and platform services are not yet implemented. The separate Cargo workspace keeps graphics dependencies out of the daemon and mobile builds.

## Desktop navigation

The native polish stack adds search and a new-conversation menu, a growing composer,
and contextual Details. See [release qualification](../../RELEASING.md)
for installation, distribution and physical-device verification requirements.

Settings → General → Appearance offers System, Light, and Dark. The choice applies to all Wonder desktop windows and is saved across launches; System follows macOS appearance.
