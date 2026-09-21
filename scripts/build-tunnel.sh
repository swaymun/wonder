#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/dist/wonder-tunnel}"

mkdir -p "$(dirname "$OUTPUT_PATH")"
(
  cd "$ROOT_DIR/cmd/wonder-tunnel"
  go build -trimpath -ldflags='-s -w' -o "$OUTPUT_PATH" .
)
chmod 755 "$OUTPUT_PATH"
echo "Built $OUTPUT_PATH"
