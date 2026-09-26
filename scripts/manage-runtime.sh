#!/bin/bash
# ChatGPT owns the runtime; Wonder verifies it without modifying its bundle.
set -euo pipefail
RESOURCES="${WONDER_RESOURCES:-$(cd "$(dirname "$0")" && pwd)}"
case "${1:-check}" in
  claude-check|claude-login)
    action="${1#claude-}"
    exec "$RESOURCES/node/bin/node" "$RESOURCES/claude-runtime/manage.mjs" "$action"
    ;;
  check|install|login) ;;
  *) echo 'Runtime versions are managed by ChatGPT. Update ChatGPT, then restart Wonder.' >&2; exit 1 ;;
esac
RUNTIME="${WONDER_CODEX_BIN:-$("$RESOURCES/wonderd" --locate-runtime)}"
[[ -x "$RUNTIME" ]] || { echo 'Install ChatGPT in Applications, then restart Wonder.' >&2; exit 1; }
"$RESOURCES/wonderd" --verify-runtime "$RUNTIME"
if [[ "${1:-check}" == login ]]; then
  exec "$RUNTIME" login
fi
echo 'ChatGPT runtime verified. Restart Wonder to reconnect.'
