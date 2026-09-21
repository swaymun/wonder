#!/bin/bash
# ChatGPT owns the runtime; Wonder verifies it without modifying its bundle.
set -euo pipefail
RESOURCES="${WONDER_RESOURCES:-$(cd "$(dirname "$0")" && pwd)}"
RUNTIME="${WONDER_CODEX_BIN:-/Applications/ChatGPT.app/Contents/Resources/codex}"
case "${1:-check}" in
  check|install|login) ;;
  *) echo 'Runtime versions are managed by ChatGPT. Update ChatGPT, then restart Wonder.' >&2; exit 1 ;;
esac
[[ -x "$RUNTIME" ]] || { echo 'Install ChatGPT in Applications, then restart Wonder.' >&2; exit 1; }
"$RESOURCES/wonderd" --verify-runtime "$RUNTIME"
if [[ "${1:-check}" == login ]]; then
  exec "$RUNTIME" login
fi
echo 'ChatGPT runtime verified. Restart Wonder to reconnect.'
