#!/usr/bin/env bash
set -euo pipefail

MODEL_ROOT="${WONDER_MODEL_DIR:-${WONDER_DATA_DIR:-$HOME/Library/Application Support/Wonder}/NeMoSpeech/models}"
MODEL_NAME="parakeet-tdt-0.6b-v3.q8_0.gguf"
MODEL_URL="https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/resolve/541d1f99c6b0c3cd0b11a95167540bb8edefd82b/$MODEL_NAME"
EXPECTED_SHA256="e3880d0aaaaf2c308ea2c35016b2b895c423eb3fda924c1b463d1c19b7f4d32e"
EXPECTED_BYTES="713975456"
MODEL_PATH="$MODEL_ROOT/$MODEL_NAME"
PART_PATH="$MODEL_PATH.part"

mkdir -p "$MODEL_ROOT"
umask 077
parent_watch_pid=""
cleanup() {
  [[ -z "$parent_watch_pid" ]] || kill "$parent_watch_pid" 2>/dev/null || true
  rm -f "$PART_PATH"
}
trap cleanup EXIT
trap 'exit 130' TERM INT
# The daemon gives the installer its own process group. End interrupted downloads
# if the daemon disappears, including its curl child, before a restart can retry.
if [[ -n "${WONDER_ASR_PARENT_PID:-}" ]]; then
  installer_pid="$$"
  (
    while [[ "$(ps -o ppid= -p "$installer_pid" | tr -d ' ')" == "$WONDER_ASR_PARENT_PID" ]]; do sleep 0.1; done
    kill -TERM -- "-$installer_pid" 2>/dev/null || true
  ) &
  parent_watch_pid="$!"
fi

verify_model() {
  [[ -f "$1" ]] &&
    [[ "$(wc -c < "$1" | tr -d ' ')" == "$EXPECTED_BYTES" ]] &&
    [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$EXPECTED_SHA256" ]]
}

if ! verify_model "$MODEL_PATH"; then
  available_kb="$(df -Pk "$MODEL_ROOT" | awk 'END {print $4}')"
  required_kb="$((EXPECTED_BYTES / 1024 + 65536))"
  if [[ "$available_kb" -lt "$required_kb" ]]; then
    echo "Not enough free disk space for the Parakeet download" >&2
    exit 1
  fi
  curl -L --fail --proto '=https' --proto-redir '=https' --connect-timeout 20 \
    --max-time 540 --max-filesize "$EXPECTED_BYTES" --silent --show-error \
    "$MODEL_URL" -o "$PART_PATH"
  if ! verify_model "$PART_PATH"; then
    echo "Parakeet model integrity check failed" >&2
    exit 1
  fi
  # Only verified bytes become visible to transcription jobs.
  mv -f "$PART_PATH" "$MODEL_PATH"
fi
actual_sha256="$EXPECTED_SHA256"
actual_bytes="$EXPECTED_BYTES"

python3 - "$MODEL_ROOT/manifest.json" "$MODEL_PATH" "$MODEL_URL" "$actual_sha256" "$actual_bytes" <<'PY'
import json
import sys
from pathlib import Path
from datetime import datetime, timezone

manifest_path, model_path, source_url, sha256, byte_count = sys.argv[1:]
manifest = {
    "model": "nvidia/parakeet-tdt-0.6b-v3",
    "artifact": Path(model_path).name,
    "revision": "541d1f99c6b0c3cd0b11a95167540bb8edefd82b",
    "sourceUrl": source_url,
    "license": "CC BY 4.0",
    "sha256": sha256,
    "bytes": int(byte_count),
    "installedAt": datetime.now(timezone.utc).isoformat(),
}
Path(manifest_path).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

echo "Installed and verified $MODEL_PATH"
echo "Manifest: $MODEL_ROOT/manifest.json"
