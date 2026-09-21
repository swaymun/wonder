#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT_DIR/scripts/verify-package-release-gates.py" "${1:?app path is required}" "${2:?pkg path is required}"
