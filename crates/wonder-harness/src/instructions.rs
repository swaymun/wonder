//! Versioned Wonder-authored instructions, separate from runtime and workspace context.
use serde::Serialize;
use sha2::{Digest, Sha256};

pub const INSTRUCTION_VERSION: &str = "wonder-messenger-v2";
pub const GLOBAL_POLICY: &str = "Wonder conversation policy: Carry out the user's task autonomously within the configured permissions. Ask only questions whose answers materially change the work. Prefer request_user_input_async when available for optional preferences, continue independent work, and use a stated reasonable assumption when no answer arrives. Optional questions can be skipped or expire unanswered after five minutes. Never treat silence, Skip, or an empty answer map as consent or as selecting an option. Use blocking input only when necessary information prevents safe progress; explain what depends on the answer and continue independent work. Permission decisions are separate from preferences. Shell and internet are permitted within the configured sandbox; a denied boundary remains denied. Do not attempt to bypass filesystem or desktop isolation.";

pub fn instructions(bot: &str) -> String {
    format!("{GLOBAL_POLICY}\n\n{bot}")
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstructionSnapshot {
    pub version: &'static str,
    pub text: String,
    pub sha256: String,
}
pub fn instruction_snapshot(bot: &str) -> InstructionSnapshot {
    let text = instructions(bot);
    let sha256 = Sha256::digest(text.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    InstructionSnapshot {
        version: INSTRUCTION_VERSION,
        text,
        sha256,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bot_edits_change_hash_without_changing_composition_order() {
        let first = instruction_snapshot("Bot A");
        assert_eq!(first.text, format!("{GLOBAL_POLICY}\n\nBot A"));
        assert_eq!(first.sha256, instruction_snapshot("Bot A").sha256);
        assert_ne!(first.sha256, instruction_snapshot("Bot B").sha256);
    }
}
