//! The owner's default model, effort and speed for each agent harness. The
//! host stores them, the model catalog publishes the result as `isDefault`,
//! `defaultReasoningEffort` and `defaultServiceTier`, and
//! `agent_defaults` falls back to Wonder's own rule when none is set.

use crate::{agent_defaults, AgentFamily, AppState, OwnerAuthority};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Extension, Json,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use wonder_store::AgentDefaultPreference;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SetDefaultModel {
    /// `null` returns the harness to Wonder's own default.
    model: Option<String>,
    effort: Option<String>,
    service_tier: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FamilyPreference {
    family: AgentFamily,
    model: Option<String>,
    effort: Option<String>,
    service_tier: Option<String>,
}

async fn listing(state: &AppState) -> Value {
    let catalog = state.runtime_catalog.read().await;
    let families: Vec<_> = AgentFamily::ALL
        .into_iter()
        .map(|family| {
            let preference = catalog
                .preferences
                .get(&family)
                .cloned()
                .unwrap_or_default();
            FamilyPreference {
                family,
                model: preference.model,
                effort: preference.effort,
                service_tier: preference.service_tier,
            }
        })
        .collect();
    json!({ "families": families })
}

pub(crate) async fn list(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
) -> Response {
    Json(listing(&state).await).into_response()
}

pub(crate) async fn set(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Path(family): Path<AgentFamily>,
    Json(request): Json<SetDefaultModel>,
) -> Response {
    let preference = AgentDefaultPreference {
        model: request.model,
        effort: request.effort,
        service_tier: request.service_tier,
    };
    {
        let catalog = state.runtime_catalog.read().await;
        if let Err(message) = validate(&catalog, family, &preference) {
            return (StatusCode::UNPROCESSABLE_ENTITY, message).into_response();
        }
    }
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    if state
        .store
        .set_agent_default_preference(family, &preference, &now)
        .await
        .is_err()
    {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "The default could not be saved. Try again.",
        )
            .into_response();
    }
    {
        let mut catalog = state.runtime_catalog.write().await;
        if preference.model.is_some() {
            catalog.preferences.insert(family, preference);
        } else {
            catalog.preferences.remove(&family);
        }
        catalog.resolve_defaults();
    }
    Json(listing(&state).await).into_response()
}

/// Only what the catalog offers for the harness can be the default.
fn validate(
    catalog: &crate::RuntimeCatalog,
    family: AgentFamily,
    preference: &AgentDefaultPreference,
) -> Result<(), &'static str> {
    let Some(model) = preference.model.as_deref() else {
        return if preference.effort.is_some() || preference.service_tier.is_some() {
            Err("Choose a model before changing its settings.")
        } else {
            Ok(())
        };
    };
    let option = catalog
        .models
        .iter()
        .find(|m| m.id == model && m.agent_family == family && !m.hidden)
        .ok_or("This model is not available for this harness.")?;
    if preference
        .effort
        .as_deref()
        .is_some_and(|effort| !option.reasoning_efforts.iter().any(|e| e.id == effort))
    {
        return Err("This model does not support that effort.");
    }
    if preference
        .service_tier
        .as_deref()
        .is_some_and(|tier| !agent_defaults::offers_tier(option, tier))
    {
        return Err("This model does not support that speed.");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_defaults::tests::model;
    use crate::RuntimeCatalog;

    fn catalog() -> RuntimeCatalog {
        let mut c = RuntimeCatalog {
            models: vec![
                model("claude:haiku", AgentFamily::Claude, &[], None),
                model("claude:sonnet", AgentFamily::Claude, &["low", "high"], None),
                model(
                    "claude:opus",
                    AgentFamily::Claude,
                    &["medium", "xhigh"],
                    None,
                ),
                model(
                    "gpt-a",
                    AgentFamily::Codex,
                    &["low", "medium"],
                    Some("medium"),
                ),
                model("gpt-b", AgentFamily::Codex, &["low", "xhigh"], None),
            ],
            ..Default::default()
        };
        c.resolve_defaults();
        c
    }

    fn prefer(
        c: &mut RuntimeCatalog,
        family: AgentFamily,
        model: &str,
        effort: Option<&str>,
        tier: Option<&str>,
    ) {
        c.preferences.insert(
            family,
            AgentDefaultPreference {
                model: Some(model.into()),
                effort: effort.map(str::to_owned),
                service_tier: tier.map(str::to_owned),
            },
        );
        c.resolve_defaults();
    }

    fn default_of(
        c: &RuntimeCatalog,
        family: AgentFamily,
    ) -> (String, Option<String>, Option<String>) {
        let m = c
            .models
            .iter()
            .find(|m| m.agent_family == family && m.is_default)
            .unwrap();
        (
            m.id.clone(),
            m.default_reasoning_effort.clone(),
            m.default_service_tier.clone(),
        )
    }

    // Contract: the preference decides the default model, effort and speed for
    // its harness, the catalog publishes them, and clearing it, or the model
    // leaving the catalog, returns to Wonder's rule.
    #[test]
    fn preference_overrides_the_default_and_falls_back_when_unoffered() {
        let mut c = catalog();
        assert_eq!(default_of(&c, AgentFamily::Claude).0, "claude:sonnet");
        assert_eq!(default_of(&c, AgentFamily::Codex).0, "gpt-a");

        prefer(
            &mut c,
            AgentFamily::Claude,
            "claude:opus",
            Some("xhigh"),
            None,
        );
        prefer(
            &mut c,
            AgentFamily::Codex,
            "gpt-b",
            Some("xhigh"),
            Some("priority"),
        );
        assert_eq!(default_of(&c, AgentFamily::Claude).0, "claude:opus");
        assert_eq!(
            default_of(&c, AgentFamily::Claude).1.as_deref(),
            Some("xhigh")
        );
        let codex = default_of(&c, AgentFamily::Codex);
        assert_eq!(
            (codex.0.as_str(), codex.1.as_deref(), codex.2.as_deref()),
            ("gpt-b", Some("xhigh"), Some("priority"))
        );
        // A new thread resolves to the same values with no client-side rule.
        let new_thread = agent_defaults::resolve(&c, AgentFamily::Codex, None, None, None);
        assert_eq!(
            (
                new_thread.model.as_deref(),
                new_thread.effort.as_deref(),
                new_thread.service_tier.as_deref()
            ),
            (Some("gpt-b"), Some("xhigh"), Some("priority"))
        );
        // The other harness is untouched.
        assert_eq!(
            agent_defaults::resolve(&c, AgentFamily::Claude, None, None, None)
                .model
                .as_deref(),
            Some("claude:opus")
        );

        // The preferred model disappears from the catalog.
        c.models.retain(|m| m.id != "gpt-b");
        c.resolve_defaults();
        assert_eq!(default_of(&c, AgentFamily::Codex).0, "gpt-a");

        // An effort the model stops offering falls back to the model's own.
        prefer(
            &mut c,
            AgentFamily::Claude,
            "claude:opus",
            Some("xhigh"),
            None,
        );
        c.models
            .iter_mut()
            .find(|m| m.id == "claude:opus")
            .unwrap()
            .reasoning_efforts
            .retain(|e| e.id != "xhigh");
        c.resolve_defaults();
        assert_eq!(
            default_of(&c, AgentFamily::Claude).1.as_deref(),
            Some("medium")
        );

        // Clearing returns to Wonder's rule and the provider's own tier.
        c.preferences.clear();
        c.resolve_defaults();
        assert_eq!(default_of(&c, AgentFamily::Claude).0, "claude:sonnet");
        assert_eq!(default_of(&c, AgentFamily::Codex).2, None);
    }

    #[test]
    fn only_what_the_catalog_offers_can_be_chosen() {
        let c = catalog();
        let pick = |model: Option<&str>, effort: Option<&str>, tier: Option<&str>| {
            validate(
                &c,
                AgentFamily::Codex,
                &AgentDefaultPreference {
                    model: model.map(str::to_owned),
                    effort: effort.map(str::to_owned),
                    service_tier: tier.map(str::to_owned),
                },
            )
        };
        assert!(pick(Some("gpt-b"), Some("xhigh"), Some("priority")).is_ok());
        assert!(pick(None, None, None).is_ok());
        assert!(
            pick(Some("claude:opus"), None, None).is_err(),
            "another harness's model"
        );
        assert!(
            pick(Some("gpt-a"), Some("xhigh"), None).is_err(),
            "unoffered effort"
        );
        assert!(
            pick(Some("gpt-a"), None, Some("turbo")).is_err(),
            "unoffered speed"
        );
        assert!(
            pick(None, Some("low"), None).is_err(),
            "settings without a model"
        );
    }

    // Contract: the HTTP setting persists on the host, updates the catalog the
    // composer reads, and survives a restart; unavailable choices are refused.
    #[tokio::test]
    async fn setting_a_default_persists_and_updates_the_catalog() {
        use crate::permission_modes::tests::{call, fixture};
        let (_dir, state) = fixture().await;
        *state.runtime_catalog.write().await = catalog();
        let put = |family: &str, body: Value| {
            let state = state.clone();
            let path = format!("/api/v1/settings/default-models/{family}");
            async move { call(&state, "PUT", &path, body).await }
        };
        let saved = put("claude", json!({"model": "claude:opus", "effort": "xhigh"})).await;
        assert_eq!(saved.0, StatusCode::OK, "{}", saved.1);
        crate::tests::validate_http_contract("defaultModelPreferences", &saved.1);
        assert_eq!(saved.1["families"][1]["model"], "claude:opus");
        let catalog = state.runtime_catalog.read().await;
        assert_eq!(default_of(&catalog, AgentFamily::Claude).0, "claude:opus");
        drop(catalog);
        let stored = state.store.agent_default_preferences().await.unwrap();
        assert_eq!(stored[0].1.effort.as_deref(), Some("xhigh"));
        let refused = put("codex", json!({"model": "claude:opus"})).await;
        assert_eq!(refused.0, StatusCode::UNPROCESSABLE_ENTITY);
        let reset = put("claude", json!({"model": null})).await;
        assert_eq!(reset.0, StatusCode::OK, "{}", reset.1);
        assert!(state
            .store
            .agent_default_preferences()
            .await
            .unwrap()
            .is_empty());
        let catalog = state.runtime_catalog.read().await;
        assert_eq!(default_of(&catalog, AgentFamily::Claude).0, "claude:sonnet");
    }
}
