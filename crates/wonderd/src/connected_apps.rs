//! Product metadata only. Discovery never grants access or resumes waiting work.
use super::*;
use serde_json::{json, Value};

// Pinned runtime built-ins are not user-connected service accounts.
const INTERNAL_APPS: [&str; 4] = [
    "connector_openai_codex_document_control",
    "connector_openai_hotline",
    "connector_openai_plugin_management",
    "connector_openai_safety_settings",
];

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct AppQuery {
    cursor: Option<String>,
    conversation_id: Option<String>,
    #[serde(default)]
    refresh: bool,
}

pub(super) async fn list(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
    Query(query): Query<AppQuery>,
) -> Response {
    if query.cursor.as_ref().is_some_and(|c| c.len() > 4096) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let thread = if let Some(conversation) = &query.conversation_id {
        // Never silently substitute the host scope for an unavailable Bot scope.
        match state.store.conversation_thread(conversation).await {
            Ok(Some(thread)) => Some(thread),
            _ => {
                return (
                    StatusCode::CONFLICT,
                    "Send this Bot a message before checking its app access.",
                )
                    .into_response()
            }
        }
    } else {
        None
    };
    let rpc = state.app_server.lock().await.rpc();
    let result = rpc
        .request(
            "app/installed",
            json!({"threadId":thread,"forceRefresh":query.refresh}),
        )
        .await;
    let installed = match result {
        Ok(response) if response.error.is_none() => response.result,
        _ => None,
    };
    let Some(mut runtime) = installed.and_then(|v| v["apps"].as_array().cloned()) else {
        return (
            if query.conversation_id.is_some() {
                StatusCode::CONFLICT
            } else {
                StatusCode::SERVICE_UNAVAILABLE
            },
            if query.conversation_id.is_some() {
                "This Bot's app access is not loaded. Send it a message, then refresh."
            } else {
                "App access could not be verified. Check Codex on your Mac, then refresh."
            },
        )
            .into_response();
    };
    runtime.retain(|app| {
        app["id"]
            .as_str()
            .is_some_and(|id| !INTERNAL_APPS.contains(&id))
    });
    runtime.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    let fingerprint = hex::encode(Sha256::digest(
        serde_json::to_vec(&runtime).unwrap_or_default(),
    ));
    let Some(offset) = page_offset(query.cursor.as_deref(), &fingerprint, runtime.len()) else {
        return (
            StatusCode::CONFLICT,
            "App access changed. Refresh to load the current list.",
        )
            .into_response();
    };
    let page = runtime.iter().skip(offset).take(50).collect::<Vec<_>>();
    let ids = page
        .iter()
        .filter_map(|app| app["id"].as_str())
        .collect::<Vec<_>>();
    let metadata = if ids.is_empty() {
        Some(json!({"apps":[]}))
    } else {
        match rpc
            .request(
                "app/read",
                json!({"appIds":ids,"threadId":thread,"includeTools":false}),
            )
            .await
        {
            Ok(response) if response.error.is_none() => response.result,
            _ => None,
        }
    };
    let apps=page.iter().filter_map(|installed| {
        let id=installed["id"].as_str()?;
        let fallback=json!({"id":id,"name":installed["runtimeName"].as_str().unwrap_or("Connected app")});
        let detail=metadata.as_ref().and_then(|v|v["apps"].as_array()).and_then(|apps|apps.iter().find(|app|app["id"]==id)).unwrap_or(&fallback);
        project(detail,Some(&runtime))
    }).collect::<Vec<_>>();
    let next_cursor = (offset + page.len() < runtime.len())
        .then(|| format!("{fingerprint}:{}", offset + page.len()));
    ([(header::CACHE_CONTROL,"no-store")],Json(json!({
        "hostInstallationId":state.host_installation_id,"conversationId":query.conversation_id,
        "apps":apps,"nextCursor":next_cursor,"checkedAtMs":now_ms(),
        "warning":if metadata.is_none(){Some("Some app details could not be loaded. Access status is current.")}else{None}
    }))).into_response()
}

fn page_offset(cursor: Option<&str>, fingerprint: &str, length: usize) -> Option<usize> {
    let Some(cursor) = cursor else {
        return Some(0);
    };
    let (hash, offset) = cursor.split_once(':')?;
    let offset = offset.parse::<usize>().ok()?;
    (hash == fingerprint && offset <= length).then_some(offset)
}

fn project(app: &Value, runtime: Option<&Vec<Value>>) -> Option<Value> {
    let id = app["id"].as_str()?;
    if INTERNAL_APPS.contains(&id) {
        return None;
    }
    let name = app["name"].as_str()?;
    let installed = runtime.and_then(|apps| apps.iter().find(|item| item["id"] == id));
    let status = match installed {
        Some(item) if item["enabled"] == false => "disabled",
        Some(item) if item["enabled"] == true && item["callable"] == true => "available",
        Some(item) if item["callable"] == false => "unavailable",
        Some(_) => "unknown",
        None if runtime.is_none() => "unknown",
        None if app["isEnabled"] == false => "disabled",
        None if app["isAccessible"] == false => "not_connected",
        None => "unknown",
    };
    Some(
        json!({"id":id,"name":name,"description":app["description"].as_str(),"status":status,
        "logoUrl":safe_url(app.get("logoUrl").filter(|v|v.is_string()).unwrap_or(&app["iconUrl"]),false),"logoUrlDark":safe_url(app.get("logoUrlDark").filter(|v|v.is_string()).unwrap_or(&app["iconUrlDark"]),false),
        "setupUrl":safe_url(&app["installUrl"],true),"accountName":Value::Null}),
    )
}

// Only vendor-owned metadata destinations; no loopback callbacks or credentials.
fn safe_url(value: &Value, setup: bool) -> Option<String> {
    let value = value.as_str()?;
    if value.len() > 2048 {
        return None;
    }
    let uri: axum::http::Uri = value.parse().ok()?;
    let authority = uri.authority()?;
    if uri.scheme_str() != Some("https")
        || authority.as_str().contains('@')
        || authority.port().is_some()
    {
        return None;
    }
    let host = authority.host();
    let trusted = if setup {
        host == "chatgpt.com" && uri.path().starts_with("/apps/")
    } else {
        [
            "openai.com",
            "oaistatic.com",
            "oaiusercontent.com",
            "chatgpt.com",
        ]
        .iter()
        .any(|domain| host == *domain || host.ends_with(&format!(".{domain}")))
    };
    (trusted && uri.query().is_none() && !value.contains('#')).then(|| value.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pagination_rejects_a_changed_runtime_snapshot() {
        assert_eq!(page_offset(None, "current", 120), Some(0));
        assert_eq!(page_offset(Some("current:50"), "current", 120), Some(50));
        assert_eq!(page_offset(Some("old:50"), "current", 120), None);
        assert_eq!(page_offset(Some("current:121"), "current", 120), None);
        assert_eq!(page_offset(Some("current:-1"), "current", 120), None);
    }
    #[test]
    fn directory_access_never_implies_callability() {
        assert!(project(
            &json!({"id":"connector_openai_hotline","name":"Internal"}),
            None
        )
        .is_none());
        let app = json!({"id":"a","name":"Calendar","isEnabled":true,"isAccessible":true});
        assert_eq!(project(&app, None).unwrap()["status"], "unknown");
        assert_eq!(project(&app, Some(&vec![])).unwrap()["status"], "unknown");
        assert_eq!(
            project(
                &app,
                Some(&vec![json!({"id":"a","enabled":true,"callable":true})])
            )
            .unwrap()["status"],
            "available"
        );
        assert_eq!(
            project(
                &app,
                Some(&vec![json!({"id":"a","enabled":false,"callable":true})])
            )
            .unwrap()["status"],
            "disabled"
        );
    }
    #[test]
    fn metadata_links_cannot_become_arbitrary_setup_or_private_fetches() {
        for url in [
            "http://chatgpt.com/apps/a",
            "https://chatgpt.com.evil.test/apps/a",
            "https://user@chatgpt.com/apps/a",
            "https://127.0.0.1/apps/a",
            "https://chatgpt.com/apps/a?token=secret",
            "https://chatgpt.com:444/apps/a",
        ] {
            assert!(safe_url(&json!(url), true).is_none());
        }
        assert!(safe_url(&json!("https://chatgpt.com/apps/calendar"), true).is_some());
        assert!(safe_url(&json!("https://cdn.oaistatic.com/icon.png"), false).is_some());
        assert!(safe_url(&json!("https://unknown.test/icon.png"), false).is_none());
    }
}
