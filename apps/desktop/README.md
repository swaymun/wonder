# Wonder Mac companion

The GPUI Kit application provides the menu bar, Settings and setup for Wonder’s
Mac host. Conversations run on iPhone and iPad. There is no desktop Chats client.

```sh
cargo test --locked --manifest-path apps/desktop/Cargo.toml --bin wonder-host
cargo clippy --locked --manifest-path apps/desktop/Cargo.toml --bin wonder-host -- -D warnings
scripts/package-dev-app.sh /path/to/staging/Wonder.app
```

Open Settings from Wonder’s menu bar. The companion keeps pairing, provider
setup, permissions, dictation and service recovery available. Appearance offers
System, Light and Dark and persists the choice across launches.

The separate Cargo workspace keeps graphics dependencies out of the daemon and
mobile builds. Packaging and installed verification follow [RELEASING.md](../../RELEASING.md).
