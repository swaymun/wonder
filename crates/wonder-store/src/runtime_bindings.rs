use super::*;

#[derive(
    Clone, Copy, Debug, Default, Eq, PartialEq, Hash, serde::Serialize, serde::Deserialize,
)]
#[serde(rename_all = "lowercase")]
pub enum AgentFamily {
    #[default]
    Codex,
    Claude,
}
impl AgentFamily {
    pub fn for_model(model: Option<&str>) -> Self {
        if model.is_some_and(|model| model.starts_with("claude:")) {
            Self::Claude
        } else {
            Self::Codex
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
        }
    }
    fn from_storage(value: &str) -> Result<Self, sqlx::Error> {
        match value {
            "codex" => Ok(Self::Codex),
            "claude" => Ok(Self::Claude),
            _ => Err(sqlx::Error::Protocol("Unknown runtime agent family".into())),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeBinding {
    pub conversation_id: String,
    pub family: AgentFamily,
    pub thread_id: String,
    pub session_id: Option<String>,
}

impl Store {
    pub async fn runtime_binding(
        &self,
        conversation: &str,
    ) -> Result<Option<RuntimeBinding>, sqlx::Error> {
        let row = sqlx::query("SELECT * FROM runtime_bindings WHERE conversation_id=?")
            .bind(conversation)
            .fetch_optional(&self.pool)
            .await?;
        row.map(|row| {
            Ok(RuntimeBinding {
                conversation_id: row.get("conversation_id"),
                family: AgentFamily::from_storage(row.get("agent_family"))?,
                thread_id: row.get("runtime_thread_id"),
                session_id: row.get("session_id"),
            })
        })
        .transpose()
    }

    pub async fn runtime_family_for_thread(
        &self,
        thread: &str,
    ) -> Result<Option<AgentFamily>, sqlx::Error> {
        let family: Option<String> = sqlx::query_scalar(
            "SELECT agent_family FROM runtime_bindings WHERE runtime_thread_id=?",
        )
        .bind(thread)
        .fetch_optional(&self.pool)
        .await?;
        family.as_deref().map(AgentFamily::from_storage).transpose()
    }

    pub async fn bind_runtime(
        &self,
        conversation: &str,
        family: AgentFamily,
        thread: &str,
        session: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        if thread.trim().is_empty()
            || thread.len() > 512
            || (family == AgentFamily::Claude && !thread.starts_with("claude-"))
            || (family == AgentFamily::Codex && thread.starts_with("claude-"))
        {
            return Err(sqlx::Error::Protocol(
                "Invalid provider session identity".into(),
            ));
        }
        let mut tx = self.pool.begin().await?;
        sqlx::query("INSERT INTO conversations(id,codex_thread_id,session_id,created_at) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET codex_thread_id=excluded.codex_thread_id,session_id=COALESCE(excluded.session_id,conversations.session_id)")
            .bind(conversation).bind(thread).bind(session).bind(now).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO runtime_bindings(conversation_id,agent_family,runtime_thread_id,session_id,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(conversation_id) DO UPDATE SET agent_family=excluded.agent_family,runtime_thread_id=excluded.runtime_thread_id,session_id=COALESCE(excluded.session_id,runtime_bindings.session_id),updated_at=excluded.updated_at")
            .bind(conversation).bind(family.as_str()).bind(thread).bind(session).bind(now).execute(&mut *tx).await?;
        tx.commit().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Contract: a stored Bot/session never changes provider as a side effect of
    // a model edit, restart, or partial failure. SQLite is the final boundary.
    #[tokio::test]
    async fn initial_model_binds_family_and_later_model_edits_cannot_cross_it() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        for (id, model, family) in [
            ("legacy", None, AgentFamily::Codex),
            ("new", Some("claude:haiku"), AgentFamily::Claude),
        ] {
            store
                .upsert_bot(
                    id, "Bot", "Help", "Help", "/tmp/bot", "profile", model, None, "now",
                )
                .await
                .unwrap();
            let bot = store.bot(id).await.unwrap().unwrap();
            assert_eq!(bot.agent_family, family);
        }
        assert!(store
            .update_bot("new", None, None, None, Some("gpt-5.6-luna"), None, None)
            .await
            .is_err());
        assert!(store
            .update_bot("legacy", None, None, None, Some("claude:haiku"), None, None)
            .await
            .is_err());
        store
            .update_bot("new", None, None, None, Some("claude:sonnet"), None, None)
            .await
            .unwrap();
        assert_eq!(
            store.bot("new").await.unwrap().unwrap().agent_family,
            AgentFamily::Claude
        );
    }

    #[tokio::test]
    async fn runtime_rebinding_is_atomic_and_cannot_cross_families_or_conversations() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .bind_runtime(
                "conversation",
                AgentFamily::Claude,
                "claude-original",
                Some("sdk-session"),
                "now",
            )
            .await
            .unwrap();
        assert!(store
            .bind_runtime(
                "conversation",
                AgentFamily::Codex,
                "codex-thread",
                None,
                "later"
            )
            .await
            .is_err());
        assert_eq!(
            store
                .conversation_thread("conversation")
                .await
                .unwrap()
                .as_deref(),
            Some("claude-original")
        );
        assert!(store
            .bind_runtime(
                "another",
                AgentFamily::Claude,
                "claude-original",
                None,
                "later"
            )
            .await
            .is_err());
        assert!(store
            .conversation_thread("another")
            .await
            .unwrap()
            .is_none());
        let binding = store
            .runtime_binding("conversation")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(binding.family, AgentFamily::Claude);
        assert_eq!(binding.session_id.as_deref(), Some("sdk-session"));
    }
}
