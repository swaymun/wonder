//! Owner-visible local JSONL logging with conservative secret redaction.

use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

use serde_json::{Map, Value};

const MAX_LOG_BYTES: u64 = 100 * 1024 * 1024;

pub struct JsonlLogger {
    path: PathBuf,
}

impl JsonlLogger {
    pub fn new(directory: impl AsRef<Path>, filename: &str) -> std::io::Result<Self> {
        fs::create_dir_all(directory.as_ref())?;
        Ok(Self {
            path: directory.as_ref().join(filename),
        })
    }

    pub fn record(&self, severity: &str, event: &str, fields: Value) -> std::io::Result<()> {
        let mut record = Map::new();
        record.insert(
            "timestamp".into(),
            Value::String(
                time::OffsetDateTime::now_utc()
                    .format(&time::format_description::well_known::Rfc3339)
                    .unwrap_or_default(),
            ),
        );
        record.insert("severity".into(), Value::String(severity.into()));
        record.insert("subsystem".into(), Value::String("wonderd".into()));
        record.insert("event".into(), Value::String(event.into()));
        if let Value::Object(fields) = redact(fields) {
            record.extend(fields);
        }
        let line = serde_json::to_vec(&Value::Object(record)).map_err(std::io::Error::other)?;
        self.rotate_if_needed()?;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        file.write_all(&line)?;
        file.write_all(b"\n")?;
        file.flush()
    }

    fn rotate_if_needed(&self) -> std::io::Result<()> {
        if self
            .path
            .metadata()
            .map(|metadata| metadata.len() >= MAX_LOG_BYTES)
            .unwrap_or(false)
        {
            let rotated = self.path.with_extension("jsonl.1");
            let _ = fs::remove_file(&rotated);
            fs::rename(&self.path, rotated)?;
        }
        Ok(())
    }
}

fn redact(value: Value) -> Value {
    match value {
        Value::Object(fields) => Value::Object(
            fields
                .into_iter()
                .map(|(key, value)| {
                    let lowered = key.to_ascii_lowercase();
                    let redacted = [
                        "token",
                        "secret",
                        "cookie",
                        "privatekey",
                        "authorization",
                        "credential",
                        "password",
                        "prompt",
                        "audio",
                    ]
                    .iter()
                    .any(|needle| lowered.contains(needle));
                    (
                        key,
                        if redacted {
                            Value::String("[REDACTED]".into())
                        } else {
                            redact(value)
                        },
                    )
                })
                .collect(),
        ),
        Value::Array(values) => Value::Array(values.into_iter().map(redact).collect()),
        Value::String(value)
            if value.contains("#secret=")
                || value.contains("Bearer ")
                || value.contains("authorization=") =>
        {
            Value::String("[REDACTED]".into())
        }
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_sensitive_nested_fields() {
        let value = redact(serde_json::json!({
            "deviceId": "device-1",
            "sessionToken": "secret",
            "nested": [{"privateKeyJwk": "secret"}],
        }));
        assert_eq!(value["deviceId"], "device-1");
        assert_eq!(value["sessionToken"], "[REDACTED]");
        assert_eq!(value["nested"][0]["privateKeyJwk"], "[REDACTED]");
    }
}
