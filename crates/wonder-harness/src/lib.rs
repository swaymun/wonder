//! Deterministic projection and reconciliation primitives shared by runtime clients.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum TimelineItem {
    UserMessage {
        id: String,
        text: String,
    },
    AssistantMessage {
        id: String,
        text: String,
        provisional: bool,
    },
    Working {
        id: String,
    },
    Approval {
        id: String,
        request_id: String,
        scope: String,
    },
    TerminalError {
        id: String,
        message: String,
    },
}

pub fn project_notification(method: &str, params: &Value) -> Option<TimelineItem> {
    let item = params.get("item")?;
    let id = item.get("id")?.as_str()?.to_owned();
    match method {
        "item/agentMessage/delta" => Some(TimelineItem::AssistantMessage {
            id,
            text: params.get("delta")?.as_str()?.to_owned(),
            provisional: true,
        }),
        "item/started" => Some(TimelineItem::Working { id }),
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
            Some(TimelineItem::Approval {
                id,
                request_id: params.get("requestId")?.as_str()?.to_owned(),
                scope: params.get("scope")?.as_str()?.to_owned(),
            })
        }
        "item/completed" => Some(TimelineItem::AssistantMessage {
            id,
            text: item.get("text")?.as_str()?.to_owned(),
            provisional: false,
        }),
        _ => None,
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ThreadUserMessage {
    pub client_id: Option<String>,
    pub turn_id: String,
}

pub fn find_turn_for_client_id(
    items: &[ThreadUserMessage],
    client_message_id: &str,
) -> Option<String> {
    items
        .iter()
        .find(|item| item.client_id.as_deref() == Some(client_message_id))
        .map(|item| item.turn_id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn projects_streaming_and_completion_without_losing_terminal_state() {
        let delta = project_notification(
            "item/agentMessage/delta",
            &json!({
                "item": { "id": "item-1" }, "delta": "hello"
            }),
        );
        let completed = project_notification(
            "item/completed",
            &json!({
                "item": { "id": "item-1", "text": "hello world" }
            }),
        );
        assert_eq!(
            delta,
            Some(TimelineItem::AssistantMessage {
                id: "item-1".into(),
                text: "hello".into(),
                provisional: true
            })
        );
        assert_eq!(
            completed,
            Some(TimelineItem::AssistantMessage {
                id: "item-1".into(),
                text: "hello world".into(),
                provisional: false
            })
        );
    }

    #[test]
    fn reconciles_exact_client_id() {
        let items = vec![ThreadUserMessage {
            client_id: Some("client-1".into()),
            turn_id: "turn-1".into(),
        }];
        assert_eq!(
            find_turn_for_client_id(&items, "client-1"),
            Some("turn-1".into())
        );
        assert_eq!(find_turn_for_client_id(&items, "client-2"), None);
    }
}

mod instructions;
pub use instructions::{
    instruction_snapshot, instructions, InstructionSnapshot, INSTRUCTION_VERSION,
};
