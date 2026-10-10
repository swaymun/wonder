#!/bin/bash
# ChatGPT owns the runtime; Wonder verifies it without modifying its bundle.
# `status` and `claude-status` print "version<TAB>account" and exit 0 when signed
# in, 42 when signed out, 43 for an unsupported version and 44 when not installed.
set -euo pipefail
RESOURCES="${WONDER_RESOURCES:-$(cd "$(dirname "$0")" && pwd)}"
case "${1:-check}" in
  claude-check|claude-login|claude-status|claude-logout)
    action="${1#claude-}"
    exec "$RESOURCES/node/bin/node" "$RESOURCES/claude-runtime/manage.mjs" "$action"
    ;;
  check|install|login|status|logout) ;;
  *) echo 'Runtime versions are managed by ChatGPT. Update ChatGPT, then restart Wonder.' >&2; exit 1 ;;
esac
RUNTIME="${WONDER_CODEX_BIN:-$("$RESOURCES/wonderd" --locate-runtime)}"
if [[ ! -x "$RUNTIME" ]]; then
  echo 'Install ChatGPT in Applications, then restart Wonder.' >&2
  [[ "${1:-check}" == status ]] && exit 44
  exit 1
fi
case "${1:-check}" in
  status)
    version="$("$RUNTIME" --version 2>/dev/null | head -n 1 || true)"
    if ! "$RESOURCES/wonderd" --verify-runtime "$RUNTIME" >&2; then
      printf '%s\t\n' "$version"; exit 43
    fi
    # Never print the login output: an API-key login includes a key prefix.
    if login="$("$RUNTIME" login status 2>&1)"; then
      case "$login" in
        *ChatGPT*) account='ChatGPT account' ;;
        *'API key'*) account='API key' ;;
        *) account='' ;;
      esac
      printf '%s\t%s\n' "$version" "$account"; exit 0
    fi
    printf '%s\t\n' "$version"
    [[ "$login" == *'Not logged in'* ]] && exit 42
    echo 'Codex sign-in status could not be read.' >&2; exit 1
    ;;
  # Signing out needs no verified protocol; an outdated runtime can still remove its own login.
  logout) exec "$RUNTIME" logout ;;
esac
"$RESOURCES/wonderd" --verify-runtime "$RUNTIME"
if [[ "${1:-check}" == login ]]; then
  exec "$RUNTIME" login
fi
echo 'ChatGPT runtime verified. Restart Wonder to reconnect.'
