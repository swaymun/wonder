//! Local-only ASR contract for the optional Mac-hosted Parakeet service.
//!
//! This crate intentionally contains policy and IPC-facing data only. Model
//! loading belongs to a separately reviewed `nemo-speech` process and is never
//! implicit in a Wonder launch.

use serde::{Deserialize, Serialize};

pub const MODEL_ID: &str = "parakeet-tdt-0.6b-v3-q8";
pub const MODEL_ARTIFACT: &str = "parakeet-tdt-0.6b-v3.q8_0.gguf";
pub const MODEL_REVISION: &str = "541d1f99c6b0c3cd0b11a95167540bb8edefd82b";
pub const MODEL_SHA256: &str = "e3880d0aaaaf2c308ea2c35016b2b895c423eb3fda924c1b463d1c19b7f4d32e";
pub const MODEL_BYTES: u64 = 713_975_456;
pub const MAX_PCM_BYTES: usize = 9_600_000;
pub const TARGET_MODEL: &str = "nvidia/parakeet-tdt-0.6b-v3";
pub const MAX_RECORDING_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_RECORDING_DURATION_MS: u64 = 300_000;
pub const MIN_RECORDING_DURATION_MS: u64 = 250;
pub const RETRY_RETENTION_MS: u64 = 120_000;
pub const PCM_SAMPLE_RATE_HZ: u32 = 16_000;
pub const PCM_CHANNELS: u8 = 1;
pub const PCM_BYTES_PER_SAMPLE: u8 = 2;

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TranscriptionState {
    Queued,
    Processing,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AsrErrorCategory {
    MicrophonePermission,
    UnsupportedRecordingFormat,
    NoAudio,
    TooShort,
    Upload,
    Decoder,
    ModelUnavailable,
    Timeout,
    Transcription,
    Busy,
    RateLimited,
    UnsupportedLanguage,
    Interrupted,
    Cancelled,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AsrTranscription {
    pub model_id: String,
    pub language: String,
    pub processing_source: String,
    pub id: String,
    pub state: TranscriptionState,
    pub source_device_id: String,
    pub duration_ms: u64,
    pub transcript_text: Option<String>,
    pub word_timestamps: Option<Vec<WordTimestamp>>,
    pub confidence: Option<f32>,
    pub retry_expires_at_ms: Option<u64>,
    pub error_category: Option<AsrErrorCategory>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerRequest {
    pub transcription_id: String,
    pub audio_format: String,
    pub sample_rate_hz: u32,
    pub channels: u8,
    pub duration_ms: u64,
    pub audio_base64: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerResponse {
    pub transcription_id: String,
    pub transcript_text: Option<String>,
    pub word_timestamps: Option<Vec<WordTimestamp>>,
    pub confidence: Option<f32>,
    pub error_category: Option<AsrErrorCategory>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WordTimestamp {
    pub word: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub confidence: Option<f32>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AudioUploadMetadata<'a> {
    pub mime_type: &'a str,
    pub byte_length: usize,
    pub duration_ms: u64,
}

pub fn validate_upload(metadata: AudioUploadMetadata<'_>) -> Result<(), AsrErrorCategory> {
    if !matches!(
        metadata.mime_type,
        "audio/webm" | "audio/ogg" | "audio/mp4" | "audio/wav"
    ) {
        return Err(AsrErrorCategory::UnsupportedRecordingFormat);
    }
    if metadata.byte_length == 0 {
        return Err(AsrErrorCategory::NoAudio);
    }
    if metadata.byte_length > MAX_RECORDING_BYTES {
        return Err(AsrErrorCategory::Upload);
    }
    if metadata.duration_ms < MIN_RECORDING_DURATION_MS {
        return Err(AsrErrorCategory::TooShort);
    }
    if metadata.duration_ms > MAX_RECORDING_DURATION_MS {
        return Err(AsrErrorCategory::Timeout);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_policy_rejects_empty_short_long_and_unknown_audio() {
        let cases = [
            ("audio/webm", 0, 1_000, AsrErrorCategory::NoAudio),
            ("audio/webm", 10, 100, AsrErrorCategory::TooShort),
            ("audio/webm", 10, 300_001, AsrErrorCategory::Timeout),
            (
                "audio/flac",
                10,
                1_000,
                AsrErrorCategory::UnsupportedRecordingFormat,
            ),
        ];
        for (mime_type, byte_length, duration_ms, expected) in cases {
            assert_eq!(
                validate_upload(AudioUploadMetadata {
                    mime_type,
                    byte_length,
                    duration_ms
                }),
                Err(expected)
            );
        }
    }

    #[test]
    fn valid_upload_is_within_v1_limits() {
        assert_eq!(
            validate_upload(AudioUploadMetadata {
                mime_type: "audio/webm",
                byte_length: 1024,
                duration_ms: 1_000,
            }),
            Ok(())
        );
    }

    #[test]
    fn five_minute_pcm_and_encoded_boundaries_are_exact() {
        assert_eq!(
            MAX_PCM_BYTES,
            (MAX_RECORDING_DURATION_MS
                * PCM_SAMPLE_RATE_HZ as u64
                * PCM_CHANNELS as u64
                * PCM_BYTES_PER_SAMPLE as u64
                / 1000) as usize
        );
        assert_eq!((MAX_PCM_BYTES.div_ceil(3)) * 4, 12_800_000);
        assert!(validate_upload(AudioUploadMetadata {
            mime_type: "audio/wav",
            byte_length: MAX_PCM_BYTES + 44,
            duration_ms: 300_000
        })
        .is_ok());
        assert_eq!(
            validate_upload(AudioUploadMetadata {
                mime_type: "audio/wav",
                byte_length: MAX_RECORDING_BYTES + 1,
                duration_ms: 300_000
            }),
            Err(AsrErrorCategory::Upload)
        );
    }

    #[test]
    fn worker_messages_are_stable_jsonl_contracts() {
        let request = WorkerRequest {
            transcription_id: "transcription-1".into(),
            audio_format: "pcm_s16le".into(),
            sample_rate_hz: PCM_SAMPLE_RATE_HZ,
            channels: PCM_CHANNELS,
            duration_ms: 1_000,
            audio_base64: "AQI=".into(),
        };
        let encoded = serde_json::to_string(&request).expect("worker request");
        assert_eq!(
            encoded,
            r#"{"transcriptionId":"transcription-1","audioFormat":"pcm_s16le","sampleRateHz":16000,"channels":1,"durationMs":1000,"audioBase64":"AQI="}"#
        );
        let decoded: WorkerResponse = serde_json::from_str(
            r#"{"transcriptionId":"transcription-1","transcriptText":"hello","wordTimestamps":null,"confidence":0.9,"errorCategory":null}"#,
        )
        .expect("worker response");
        assert_eq!(decoded.transcript_text.as_deref(), Some("hello"));
    }
}
