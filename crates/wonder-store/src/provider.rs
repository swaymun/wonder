//! The provider registry: one descriptor per agent harness holding every fact
//! that differs between providers. Callers ask the descriptor instead of
//! branching on the family, and every `match` here is exhaustive, so adding a
//! provider fails to compile exactly where a decision is needed.
//!
//! A conversation's family comes from the provider that listed its model or
//! from its stored binding. Nothing infers it from a model id.

use crate::AgentFamily;

/// Which identifier a project binding shares with the provider's own session.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeSessionKey {
    /// The runtime thread id is the provider's session.
    ThreadId,
    /// The runtime thread is Wonder's bridge; its session id is the provider's.
    BridgeSessionId,
}

/// Which optional conversation features a provider offers.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProviderCapabilities {
    pub guide: bool,
    pub goals: bool,
    pub image_generation: bool,
    /// The provider can copy a session's history, up to a chosen turn, into a
    /// new session that continues independently.
    pub native_fork: bool,
    /// The provider has a plan mode a thread can stay in between turns.
    pub plan_mode: bool,
}

/// How a thread's speed is chosen when nothing is stored.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DefaultSpeed {
    /// The standard tier, named `default`.
    Standard,
    /// The tier the model's own catalog entry names.
    CatalogDefault,
}

#[derive(Clone, Copy, Debug)]
pub struct ProviderDescriptor {
    pub family: AgentFamily,
    pub display_name: &'static str,
    /// Prefix of every runtime thread id this provider issues, when it has one.
    pub thread_id_prefix: Option<&'static str>,
    /// Namespace the provider puts on the model ids it lists, when it has one.
    /// It keeps providers from shadowing each other in the shared catalog; it
    /// is never used to decide which provider owns a model.
    pub model_id_namespace: Option<&'static str>,
    /// Model id the provider avoids choosing as its default while others exist.
    pub avoided_default_model: Option<&'static str>,
    pub capabilities: ProviderCapabilities,
    /// Approval mode stored on a new thread (`claude_approval` column).
    pub default_approval: &'static str,
    /// Provider-specific approval modes a thread may store.
    pub approval_modes: &'static [&'static str],
    pub default_speed: DefaultSpeed,
    pub native_session: NativeSessionKey,
    /// A Bot must pick an access mode; the provider has no App Server
    /// permission profile to fall back on.
    pub requires_permission_mode: bool,
    /// The provider can review its own approvals automatically ("Approve for me").
    pub automatic_approval_reviewer: bool,
    /// The provider reports agent tasks from the session transcript instead of
    /// native subagent threads.
    pub transcript_agent_tasks: bool,
}

const CODEX: ProviderDescriptor = ProviderDescriptor {
    family: AgentFamily::Codex,
    display_name: "Codex",
    thread_id_prefix: None,
    model_id_namespace: None,
    avoided_default_model: None,
    capabilities: ProviderCapabilities {
        guide: true,
        goals: true,
        image_generation: true,
        native_fork: true,
        plan_mode: true,
    },
    default_approval: "ask",
    approval_modes: &["ask"],
    default_speed: DefaultSpeed::Standard,
    native_session: NativeSessionKey::ThreadId,
    requires_permission_mode: false,
    automatic_approval_reviewer: true,
    transcript_agent_tasks: false,
};

const CLAUDE: ProviderDescriptor = ProviderDescriptor {
    family: AgentFamily::Claude,
    display_name: "Claude",
    thread_id_prefix: Some("claude-"),
    model_id_namespace: Some("claude:"),
    avoided_default_model: Some("claude:haiku"),
    capabilities: ProviderCapabilities {
        guide: false,
        goals: false,
        image_generation: false,
        native_fork: true,
        plan_mode: true,
    },
    default_approval: "auto",
    approval_modes: &["ask", "accept_edits", "auto"],
    default_speed: DefaultSpeed::CatalogDefault,
    native_session: NativeSessionKey::BridgeSessionId,
    requires_permission_mode: true,
    automatic_approval_reviewer: false,
    transcript_agent_tasks: true,
};

impl AgentFamily {
    pub const ALL: [AgentFamily; 2] = [AgentFamily::Codex, AgentFamily::Claude];

    pub const fn provider(self) -> &'static ProviderDescriptor {
        match self {
            Self::Codex => &CODEX,
            Self::Claude => &CLAUDE,
        }
    }

    /// Whether this provider could have issued `thread`. A provider without a
    /// prefix owns every id that no other provider's prefix claims.
    pub fn accepts_thread_id(self, thread: &str) -> bool {
        match self.provider().thread_id_prefix {
            Some(prefix) => thread.starts_with(prefix),
            None => !Self::ALL.iter().any(|other| {
                other
                    .provider()
                    .thread_id_prefix
                    .is_some_and(|prefix| thread.starts_with(prefix))
            }),
        }
    }

    /// Whether threads of this provider choose among approval modes; others
    /// keep the neutral stored value.
    pub fn allows_approval_choice(self) -> bool {
        self.provider().approval_modes.len() > 1
    }

    /// Whether any provider stores `mode` as a thread approval.
    pub fn is_known_approval_mode(mode: &str) -> bool {
        Self::ALL
            .iter()
            .any(|family| family.provider().approval_modes.contains(&mode))
    }

    /// The provider that issued `thread`, for ids seen without a binding.
    pub fn issuing_thread(thread: &str) -> Self {
        Self::ALL
            .into_iter()
            .find(|family| family.accepts_thread_id(thread))
            .unwrap_or_default()
    }

    /// Whether `model` sits in a namespace another provider reserves.
    pub fn model_in_foreign_namespace(self, model: &str) -> bool {
        Self::ALL.iter().any(|other| {
            *other != self
                && other
                    .provider()
                    .model_id_namespace
                    .is_some_and(|namespace| model.starts_with(namespace))
        })
    }

    /// Whether `model` carries this provider's own namespace, if it has one.
    pub fn model_in_own_namespace(self, model: &str) -> bool {
        self.provider()
            .model_id_namespace
            .is_none_or(|namespace| model.starts_with(namespace))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptors_describe_their_own_family() {
        for family in AgentFamily::ALL {
            assert_eq!(family.provider().family, family);
        }
    }

    #[test]
    fn thread_identity_follows_the_issuing_provider() {
        assert!(AgentFamily::Claude.accepts_thread_id("claude-abc"));
        assert!(!AgentFamily::Claude.accepts_thread_id("abc"));
        assert!(AgentFamily::Codex.accepts_thread_id("abc"));
        assert!(!AgentFamily::Codex.accepts_thread_id("claude-abc"));
        assert_eq!(
            AgentFamily::issuing_thread("claude-abc"),
            AgentFamily::Claude
        );
        assert_eq!(AgentFamily::issuing_thread("abc"), AgentFamily::Codex);
    }
}
