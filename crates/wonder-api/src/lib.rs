//! Versioned, client-facing Wonder contracts.

use serde::{Deserialize, Serialize};

pub mod pairing;
pub mod pairing_protocol;

pub const API_VERSION: &str = "v1";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryState {
    DraftOnDevice,
    Submitting,
    AcceptedByWonder,
    DispatchingToCodex,
    AcceptedByCodex,
    Streaming,
    Completed,
    Interrupted,
    Failed,
    Uncertain,
    SafeToRetry,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientMessageReceipt {
    pub client_message_id: String,
    pub wonder_message_id: String,
    pub body_sha256: String,
    pub conversation_id: String,
    pub delivery_state: DeliveryState,
    pub codex_thread_id: Option<String>,
    pub codex_turn_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct EventCursor {
    pub host_epoch: String,
    pub sequence: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostEventEnvelope {
    #[serde(alias = "event_id")]
    pub event_id: String,
    #[serde(alias = "host_epoch")]
    pub host_epoch: String,
    pub sequence: u64,
    #[serde(alias = "occurred_at")]
    pub occurred_at: String,
    #[serde(alias = "request_id")]
    pub request_id: Option<String>,
    #[serde(alias = "device_id")]
    pub device_id: Option<String>,
    #[serde(alias = "conversation_id")]
    pub conversation_id: Option<String>,
    #[serde(alias = "message_id")]
    pub message_id: Option<String>,
    #[serde(alias = "thread_id")]
    pub thread_id: Option<String>,
    #[serde(alias = "turn_id")]
    pub turn_id: Option<String>,
    #[serde(alias = "item_id")]
    pub item_id: Option<String>,
    #[serde(alias = "approval_id")]
    pub approval_id: Option<String>,
    pub event: WonderEvent,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "type", content = "data", rename_all = "snake_case")]
pub enum WonderEvent {
    HostStatus {
        state: String,
    },
    MessageState {
        state: DeliveryState,
    },
    AssistantDelta {
        text: String,
    },
    AssistantCompleted {
        text: String,
    },
    ComputerUseScreenshot {
        image_url: String,
    },
    ComputerSessionChanged {
        session_id: String,
        generation: u64,
        state: String,
    },
    Activity {
        category: String,
        state: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    TerminalError {
        message: String,
    },
    ApprovalOpened {
        request_id: String,
    },
    ApprovalResolved {
        request_id: String,
        decision: String,
    },
    ResyncRequired {
        reason: ResyncReason,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ResyncReason {
    EpochChanged,
    ReplayWindowExpired,
}

/// Rejects regressions within an epoch. Epoch changes are handled by resync.
pub fn validate_event_cursor(
    previous: &EventCursor,
    next: &EventCursor,
) -> Result<(), &'static str> {
    if previous.host_epoch == next.host_epoch && next.sequence < previous.sequence {
        return Err("event sequence regression");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_state_events_fail_while_known_events_tolerate_extra_fields() {
        assert!(serde_json::from_value::<WonderEvent>(serde_json::json!({
            "type": "future_approval", "data": {"decision": "approved"}
        }))
        .is_err());
        let event = serde_json::from_value::<WonderEvent>(serde_json::json!({
            "type": "host_status", "data": {"state": "ready", "futureField": true}
        }))
        .unwrap();
        assert_eq!(
            event,
            WonderEvent::HostStatus {
                state: "ready".into()
            }
        );
    }

    #[test]
    fn rejects_sequence_regression() {
        let previous = EventCursor {
            host_epoch: "epoch-1".into(),
            sequence: 8,
        };
        let next = EventCursor {
            host_epoch: "epoch-1".into(),
            sequence: 7,
        };
        assert_eq!(
            validate_event_cursor(&previous, &next),
            Err("event sequence regression")
        );
    }

    #[test]
    fn permits_epoch_change_for_resync() {
        let previous = EventCursor {
            host_epoch: "epoch-1".into(),
            sequence: 8,
        };
        let next = EventCursor {
            host_epoch: "epoch-2".into(),
            sequence: 1,
        };
        assert_eq!(validate_event_cursor(&previous, &next), Ok(()));
    }

    #[test]
    fn host_event_envelope_uses_the_browser_contract_casing() {
        let envelope = HostEventEnvelope {
            event_id: "event-1".into(),
            host_epoch: "epoch-1".into(),
            sequence: 1,
            occurred_at: "2026-09-02T00:00:00Z".into(),
            request_id: None,
            device_id: None,
            conversation_id: Some("bot:1".into()),
            message_id: None,
            thread_id: None,
            turn_id: None,
            item_id: Some("item-1".into()),
            approval_id: None,
            event: WonderEvent::AssistantCompleted {
                text: "done".into(),
            },
        };
        let value = serde_json::to_value(envelope).expect("event should serialize");
        assert_eq!(value["eventId"], "event-1");
        assert_eq!(value["occurredAt"], "2026-09-02T00:00:00Z");
        assert_eq!(value["conversationId"], "bot:1");
        assert!(value.get("event_id").is_none());
    }

    #[test]
    fn host_event_envelope_reads_legacy_snake_case_rows() {
        let value = serde_json::json!({
            "event_id": "event-legacy",
            "host_epoch": "epoch-legacy",
            "sequence": 2,
            "occurred_at": "2026-09-02T00:00:00Z",
            "request_id": null,
            "device_id": null,
            "conversation_id": "bot:1",
            "message_id": null,
            "thread_id": null,
            "turn_id": null,
            "item_id": null,
            "approval_id": null,
            "event": {"type": "assistant_completed", "data": {"text": "done"}}
        });
        let envelope: HostEventEnvelope = serde_json::from_value(value).expect("legacy event");
        assert_eq!(envelope.event_id, "event-legacy");
        assert_eq!(envelope.conversation_id.as_deref(), Some("bot:1"));
    }
}
