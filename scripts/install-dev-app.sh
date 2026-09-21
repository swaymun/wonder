#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/Wonder.app}"
INSTALL_DIR="${2:-/Applications}"

"$ROOT_DIR/scripts/package-dev-app.sh" "$APP_PATH"
python3 "$ROOT_DIR/scripts/install-signed-app.py" "$APP_PATH" "$INSTALL_DIR"
