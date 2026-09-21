# Verified local ASR boundary

Wonder uses NeMo-Speech.cpp 0.1.0 with one verified artifact: NVIDIA Parakeet TDT 0.6B v3 Q8_0 GGUF. Ordinary tests never download model weights. Whisper artifacts require a separate verified runtime and are not in this catalog.

The installer and daemon default to `~/Library/Application Support/Wonder/NeMoSpeech`. Existing Application Support symlinks are preserved. `WONDER_DATA_DIR` overrides the Wonder data root, `WONDER_MODEL_DIR` overrides its model directory, and the daemon supplies the selected absolute paths to its worker. Model metadata pins revision `541d1f99c6b0c3cd0b11a95167540bb8edefd82b`, 713,975,456 bytes and SHA-256 `e3880d0aaaaf2c308ea2c35016b2b895c423eb3fda924c1b463d1c19b7f4d32e`. Partial downloads must pass size and hash verification before atomic activation.

The model advertises 25 languages; Wonder has exercised English and Spanish fixtures on an M5 Pro with 64 GB. Its adapter uses automatic language detection. Language forcing and Apple fallback are not implemented by this adapter. A 300-second concatenated English fixture completed in 5.22 seconds, and a concatenated Spanish fixture in 4.72 seconds, with about 966 MB maximum resident set size. These are single-machine fixture observations, not minimum hardware requirements, accuracy guarantees or physical-device capture acceptance. Keep the bounded 55-second runtime, 60-second worker, and 15-second decoder deadlines until measurements justify a change.

## Existing HTTP routes, asynchronous jobs

- `POST /api/v1/asr/transcriptions`: supported raw audio body; `X-Wonder-Request-ID` UUID, `X-Wonder-Duration-Ms` 250–300000, optional `X-Wonder-Model-ID: parakeet-tdt-0.6b-v3-q8`, optional `X-Wonder-Language: auto`. Returns 202 with the durable job. Same device/request identity and identical body/metadata returns the existing job; conflicting content returns 409. One worker, no unbounded queue; busy returns 429 before creating another job.
- `GET /api/v1/asr/transcriptions/{id}`: originating-device scoped status. Unknown and other-device IDs return 404.
- `DELETE /api/v1/asr/transcriptions/{id}`: persist cancellation before terminating the process group. Repeated cancellation returns the terminal job; a completed job remains completed. The client must preserve its own explicit cancellation intent and suppress draft insertion after the user cancels.
- `POST /api/v1/asr/transcriptions/{id}/retry`: explicit retry only while failed audio remains within the 120-second window. No automatic re-execution on restart. Successful/cancelled audio is removed; interrupted jobs become failed with `interrupted` recovery feedback.

The response preserves the existing fields and adds `modelId`, `language`, and `processingSource: paired_mac`. Clients pin conversation/draft insertion intent and insert a successful transcript exactly once without sending it. Capture duration and decoder output are validated independently: 300 seconds of 16 kHz mono signed 16-bit PCM is 9,600,000 bytes, expanding to about 12.8 MB in the internal JSONL/base64 request. The raw upload ceiling remains 16 MiB. Decoder input/output are pumped concurrently to avoid pipe deadlocks on large recordings.

## Model management

`GET /api/v1/asr/models` reports the selected model, readiness, supported/tested languages, installed state, byte progress and real download/error state. Model mutations require the authenticated local owner capability; a paired phone can inspect readiness but cannot silently download or delete weights.

`POST /api/v1/asr/models/{modelId}/download` starts the pinned installer, `DELETE` on that download route cancels, `POST /api/v1/asr/models/{modelId}/select` persists selection, and `DELETE /api/v1/asr/models/{modelId}` removes the unused model. Busy model mutations return 409. The active transcription/download slot prevents deletion during use. Failure preserves the previous selected model. The daemon does not install the runtime implicitly; missing runtime/installer reports unavailable.

See [ASR-LICENSES.md](ASR-LICENSES.md) for runtime and model attribution. Package the installed runtime's LICENSE, NOTICE and third-party notices with its binary.

To cancel before the upload response supplies a job ID, DELETE
`/api/v1/asr/transcriptions/by-request/{clientRequestId}`. This authenticated,
originating-device-scoped operation returns 204 even when the upload has not
arrived. It durably records cancellation and stops an existing worker. A late
upload using that request UUID receives 409 `cancelled` and cannot start work.
Keep the phone's cancellation intent until this acknowledgement arrives; losing
an upload response must not discard the only identity needed to cancel it.
