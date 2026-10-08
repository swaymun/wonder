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
- `node/LICENSE` in app Resources contains Node.js and its bundled third-party
  notices. The bundled npm distribution retains its license files.
- `claude-runtime/node_modules` retains the license files of the locked production
  dependencies listed in `services/claude-runtime/package-lock.json`, including
  Anthropic's separately licensed Agent SDK/native executable, the Model Context
  Protocol SDK and Zod. Wonder's MIT license does not cover the Agent SDK.

- Portions of `crates/wonderd/src/provider_switch.rs` (the provider-session
  transition decision, switch planning, context-handoff budget, history
  selection and delivery rules) are ported from t3code
  (https://github.com/pingdotgg/t3code, `apps/server/src/orchestration-v2/`),
  which is licensed under the MIT License:

  > MIT License
  >
  > Copyright (c) 2026 T3 Tools Inc.
  >
  > Permission is hereby granted, free of charge, to any person obtaining a copy
  > of this software and associated documentation files (the "Software"), to deal
  > in the Software without restriction, including without limitation the rights
  > to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  > copies of the Software, and to permit persons to whom the Software is
  > furnished to do so, subject to the following conditions:
  >
  > The above copyright notice and this permission notice shall be included in all
  > copies or substantial portions of the Software.
  >
  > THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  > IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  > FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  > AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  > LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  > OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  > SOFTWARE.

The push Worker has no runtime npm dependencies. Its development dependencies
are recorded in `services/push/package-lock.json` and retain their own licenses.
Apple SDKs, ChatGPT, Codex and other user-installed runtimes are separately
licensed. Proprietary reference IPAs and extracted bundles are not distributed.
