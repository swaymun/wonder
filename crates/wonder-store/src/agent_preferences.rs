//! The owner's default model, effort and speed for each agent harness.

use crate::{AgentFamily, Store};
use sqlx::Row;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AgentDefaultPreference {
    pub model: Option<String>,
    pub effort: Option<String>,
    pub service_tier: Option<String>,
}

impl Store {
    pub async fn agent_default_preferences(
        &self,
    ) -> Result<Vec<(AgentFamily, AgentDefaultPreference)>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT agent_family,model,effort,service_tier FROM agent_default_preferences",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .filter_map(|row| {
                let name: String = row.get("agent_family");
                let family = AgentFamily::ALL.into_iter().find(|f| f.as_str() == name)?;
                Some((
                    family,
                    AgentDefaultPreference {
                        model: row.get("model"),
                        effort: row.get("effort"),
                        service_tier: row.get("service_tier"),
                    },
                ))
            })
            .collect())
    }

    /// A preference with no model removes the row, returning the harness to
    /// Wonder's own rule.
    pub async fn set_agent_default_preference(
        &self,
        family: AgentFamily,
        preference: &AgentDefaultPreference,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        if preference.model.is_none() {
            sqlx::query("DELETE FROM agent_default_preferences WHERE agent_family=?")
                .bind(family.as_str())
                .execute(&self.pool)
                .await?;
            return Ok(());
        }
        sqlx::query("INSERT INTO agent_default_preferences(agent_family,model,effort,service_tier,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(agent_family) DO UPDATE SET model=excluded.model,effort=excluded.effort,service_tier=excluded.service_tier,updated_at=excluded.updated_at")
            .bind(family.as_str())
            .bind(&preference.model)
            .bind(&preference.effort)
            .bind(&preference.service_tier)
            .bind(now)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn preferences_persist_per_family_and_clear_with_no_model() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let claude = AgentDefaultPreference {
            model: Some("claude:sonnet".into()),
            effort: Some("high".into()),
            service_tier: None,
        };
        store
            .set_agent_default_preference(AgentFamily::Claude, &claude, "now")
            .await
            .unwrap();
        assert_eq!(
            store.agent_default_preferences().await.unwrap(),
            vec![(AgentFamily::Claude, claude)]
        );
        store
            .set_agent_default_preference(
                AgentFamily::Claude,
                &AgentDefaultPreference::default(),
                "later",
            )
            .await
            .unwrap();
        assert!(store.agent_default_preferences().await.unwrap().is_empty());
    }
}
