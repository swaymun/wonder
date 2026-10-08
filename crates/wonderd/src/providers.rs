//! Per-provider adapters that need host state. The provider facts themselves
//! live in `wonder_store::ProviderDescriptor`; these functions are the only
//! places that map a family to a store, client or session identity, so a new
//! provider needs one arm in each.

use crate::AppState;
use wonder_store::{AgentFamily, NativeSessionKey, RuntimeBinding};

/// The provider history a Project thread of `family` lives in.
pub(crate) fn provider_store(state: &AppState, family: AgentFamily) -> &str {
    match family {
        AgentFamily::Codex => &state.projects.codex_store,
        AgentFamily::Claude => &state.projects.claude_store,
    }
}

/// Whether `binding` carries the provider's own `native_session`. Codex binds
/// the provider thread itself. Claude binds Wonder's bridge thread, whose
/// session is the native Claude Code session.
pub(crate) fn binds_native_session(
    family: AgentFamily,
    native_session: &str,
    binding: &RuntimeBinding,
) -> bool {
    match family.provider().native_session {
        NativeSessionKey::ThreadId => binding.thread_id == native_session,
        NativeSessionKey::BridgeSessionId => binding.session_id.as_deref() == Some(native_session),
    }
}
