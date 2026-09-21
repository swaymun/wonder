# Third-party notices

Wonder-owned source is licensed under MIT. Third-party code retains its original
licenses; Wonder's MIT license does not replace them.

- `licenses/RUST-NOTICES.txt` contains the native Rust dependency inventory and
  full license texts, keyed by SHA-256. `licenses/rust-dependencies.json` records
  exact versions and their published crate source URLs. The packaged dependencies
  are unmodified. Regenerate with `python3 scripts/collect-dependency-notices.py`.
- `licenses/upstream/index.json` records exact upstream sources for texts omitted
  from packaged crates. Seven older crates omit a standalone license file; their
  entries include the declared standard license terms, published manifest authors,
  and any copyright notices present in their source. No copyright year is invented.
- The unmodified MPL-2.0 dependency `option-ext` 0.2.0 is available as source at
  https://crates.io/crates/option-ext/0.2.0 and
  https://static.crates.io/crates/option-ext/option-ext-0.2.0.crate.
  Its MPL terms are included in the Rust notices. It remains under MPL-2.0.
- `licenses/Rust-COPYRIGHT.html.gz` contains the complete notices supplied by the
  Rust toolchain, compressed without modification. Decompress with `gzip -dc`.
- `licenses/Go-LICENSE.txt` covers the Go runtime linked into the private Serve
  helper. The helper uses the Go standard library and calls the separately
  installed Tailscale client; Wonder does not bundle Tailscale.
- `licenses/Sparkle-LICENSE.txt` covers the bundled Sparkle framework. Automatic
  updates are unavailable in this beta.
- `WebRTC-LICENSE.md` in the app Resources covers the bundled WebRTC framework.
- `ASR-LICENSES.md` in app Resources covers the optional speech runtime and model
  sources. Model downloads have their own terms and are not part of the DMG.

The push Worker has no runtime npm dependencies. Its development dependencies
are recorded in `services/push/package-lock.json` and retain their own licenses.
Apple SDKs, ChatGPT, Codex and other user-installed runtimes are separately
licensed. Proprietary reference IPAs and extracted bundles are not distributed.
