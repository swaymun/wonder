#!/usr/bin/env python3
"""Adapt Wonder's one-request JSONL ASR contract to nemo-speech transcribe."""

import base64
import binascii
import json
import os
import signal
import threading
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

SAMPLE_RATE = 16_000
CHANNELS = 1
SAMPLE_WIDTH = 2
MAX_AUDIO_BYTES = 9_600_000
DEFAULT_ROOT = Path(os.environ.get("WONDER_DATA_DIR", Path.home() / "Library" / "Application Support" / "Wonder")) / "NeMoSpeech"


def error_response(transcription_id: str, category: str) -> dict:
    return {
        "transcriptionId": transcription_id,
        "transcriptText": None,
        "wordTimestamps": None,
        "confidence": None,
        "errorCategory": category,
    }


def emit(value: dict) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def model_path() -> Path:
    return Path(os.environ.get("WONDER_ASR_MODEL", Path(os.environ.get("WONDER_MODEL_DIR", DEFAULT_ROOT / "models")) / "parakeet-tdt-0.6b-v3.q8_0.gguf"))


def binary_path() -> Path:
    return Path(os.environ.get("WONDER_NEMO_SPEECH_BIN", DEFAULT_ROOT / "bin" / "nemo-speech"))


def transcribe(request: dict) -> dict:
    transcription_id = str(request.get("transcriptionId", ""))
    if not transcription_id:
        return error_response(transcription_id, "transcription")
    if request.get("audioFormat") != "pcm_s16le" or request.get("sampleRateHz") != SAMPLE_RATE or request.get("channels") != CHANNELS:
        return error_response(transcription_id, "decoder")
    try:
        audio = base64.b64decode(request.get("audioBase64", ""), validate=True)
    except (binascii.Error, ValueError):
        return error_response(transcription_id, "decoder")
    if not audio or len(audio) > MAX_AUDIO_BYTES or len(audio) % (CHANNELS * SAMPLE_WIDTH):
        return error_response(transcription_id, "decoder")
    measured_ms = len(audio) * 1000 // (SAMPLE_RATE * CHANNELS * SAMPLE_WIDTH)
    if measured_ms < 250 or request.get("durationMs") != measured_ms:
        return error_response(transcription_id, "decoder")
    model = model_path()
    binary = binary_path()
    if not model.is_file() or not binary.is_file():
        return error_response(transcription_id, "model_unavailable")

    with tempfile.TemporaryDirectory(prefix="wonder-asr-") as directory:
        wav_path = Path(directory) / "input.wav"
        with wave.open(str(wav_path), "wb") as wav_file:
            wav_file.setnchannels(CHANNELS)
            wav_file.setsampwidth(SAMPLE_WIDTH)
            wav_file.setframerate(SAMPLE_RATE)
            wav_file.writeframes(audio)
        try:
            completed = subprocess.run(
                [str(binary), "transcribe", str(wav_path), "--model", str(model), "--format", "json", "--quiet", "--backend", os.environ.get("WONDER_ASR_BACKEND", "metal")],
                check=False,
                capture_output=True,
                text=True,
                timeout=55,
            )
        except subprocess.TimeoutExpired:
            return error_response(transcription_id, "timeout")
        if completed.returncode != 0:
            return error_response(transcription_id, "transcription")
        try:
            result = json.loads(completed.stdout)
        except json.JSONDecodeError:
            return error_response(transcription_id, "decoder")

    words = []
    for word in result.get("words", []) or []:
        if not isinstance(word, dict) or not isinstance(word.get("word"), str):
            continue
        start_ms = max(0, int(float(word.get("start", 0)) * 1000))
        end_ms = max(start_ms + 1, int(float(word.get("end", 0)) * 1000))
        words.append({"word": word["word"], "startMs": start_ms, "endMs": end_ms, "confidence": None})
    return {
        "transcriptionId": transcription_id,
        "transcriptText": result.get("text") or None,
        "wordTimestamps": words or None,
        "confidence": None,
        "errorCategory": None,
    }


def monitor_parent() -> None:
    # The daemon creates a dedicated process group and supplies its PID. If it
    # crashes, stop the runtime rather than leaving an orphaned model job.
    parent = os.environ.get("WONDER_ASR_PARENT_PID")
    if not parent:
        return
    if os.getpgrp() != os.getpid():
        return
    expected = int(parent)
    while True:
        threading.Event().wait(0.1)
        if os.getppid() != expected:
            os.killpg(os.getpgrp(), signal.SIGKILL)


def main() -> None:
    if os.environ.get("WONDER_ASR_PARENT_PID"):
        threading.Thread(target=monitor_parent, daemon=True).start()
    for line in sys.stdin:
        try:
            request = json.loads(line)
            emit(transcribe(request))
        except (TypeError, ValueError, OSError, wave.Error):
            emit(error_response("", "decoder"))


if __name__ == "__main__":
    main()
