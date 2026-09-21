//! Sanitized account usage for the owner-facing settings surface.
use super::*;
use serde_json::{json, Value};

const MAX_WINDOWS: usize = 8;
const MAX_INSPECTED_LEGACY_WINDOWS: usize = 64;

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct UsageWindow {
    id: String,
    label: String,
    used_percent: f64,
    remaining_percent: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    window_duration_mins: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    resets_at: Option<u64>,
}

pub(super) async fn read(
    State(state): State<AppState>,
    Extension(_authority): Extension<OwnerAuthority>,
) -> Response {
    let result = state
        .app_server
        .lock()
        .await
        .rpc()
        .request("account/rateLimits/read", json!({}))
        .await;
    let Some(runtime) = result
        .ok()
        .filter(|response| response.error.is_none())
        .and_then(|response| response.result)
    else {
        return unavailable();
    };
    let Some(windows) = project_windows(&runtime) else {
        return unavailable();
    };
    (
        [(header::CACHE_CONTROL, "no-store")],
        Json(json!({
            "checkedAtMs": now_ms(),
            "windows": windows,
        })),
    )
        .into_response()
}

fn unavailable() -> Response {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        [(header::CACHE_CONTROL, "no-store")],
        "Codex usage is temporarily unavailable. Check Codex on your Mac, then refresh.",
    )
        .into_response()
}

fn project_windows(runtime: &Value) -> Option<Vec<UsageWindow>> {
    let preferred = runtime
        .get("rateLimitsByLimitId")
        .and_then(Value::as_object)
        .and_then(|limits| limits.get("codex"));
    if let Some(source) = preferred {
        let windows = project_source(source);
        if !windows.is_empty() {
            return Some(windows);
        }
    }
    runtime
        .get("rateLimits")
        .map(project_source)
        .filter(|windows| !windows.is_empty())
}

fn project_source(source: &Value) -> Vec<UsageWindow> {
    if let Some(legacy) = source.as_array() {
        let mut windows = Vec::new();
        for value in legacy.iter().take(MAX_INSPECTED_LEGACY_WINDOWS) {
            let Some(mut window) = project_window(value, String::new()) else {
                continue;
            };
            window.id = format!("window-{}", windows.len() + 1);
            windows.push(window);
            if windows.len() == MAX_WINDOWS {
                break;
            }
        }
        return windows;
    }
    ["primary", "secondary"]
        .iter()
        .filter_map(|id| {
            source
                .get(id)
                .and_then(|value| project_window(value, (*id).to_owned()))
        })
        .take(MAX_WINDOWS)
        .collect()
}

fn project_window(value: &Value, id: String) -> Option<UsageWindow> {
    let used_percent = value.get("usedPercent")?.as_f64()?;
    if !used_percent.is_finite() {
        return None;
    }
    let used_percent = used_percent.clamp(0.0, 100.0);
    let window_duration_mins = value
        .get("windowDurationMins")
        .and_then(Value::as_u64)
        .filter(|minutes| *minutes > 0);
    let resets_at = value
        .get("resetsAt")
        .and_then(Value::as_u64)
        .filter(|seconds| *seconds > 0);
    Some(UsageWindow {
        id,
        label: label_for(window_duration_mins),
        used_percent,
        remaining_percent: 100.0 - used_percent,
        window_duration_mins,
        resets_at,
    })
}

fn label_for(duration_mins: Option<u64>) -> String {
    match duration_mins {
        Some(60) => "Hourly".to_owned(),
        Some(1_440) => "Daily".to_owned(),
        Some(300) => "5 hours".to_owned(),
        Some(10_080) => "Weekly".to_owned(),
        Some(minutes) if minutes % 60 == 0 && minutes / 60 <= 24 => {
            format!("{} hours", minutes / 60)
        }
        _ => "Usage".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(value: Value) -> Vec<UsageWindow> {
        project_windows(&value).unwrap_or_default()
    }

    #[test]
    fn projects_current_primary_and_secondary_windows() {
        let windows = project(json!({
            "rateLimits": {
                "primary": {"usedPercent": 12.5, "windowDurationMins": 300, "resetsAt": 10},
                "secondary": {"usedPercent": 80, "windowDurationMins": 10080, "resetsAt": 20}
            }
        }));
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].id, "primary");
        assert_eq!(windows[0].label, "5 hours");
        assert_eq!(windows[0].remaining_percent, 87.5);
        assert_eq!(windows[1].label, "Weekly");
    }

    #[test]
    fn prefers_codex_limit_id_over_generic_limits() {
        let windows = project(json!({
            "rateLimits": {"primary": {"usedPercent": 90}},
            "rateLimitsByLimitId": {
                "codex": {"primary": {"usedPercent": 25, "windowDurationMins": 60}}
            }
        }));
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].used_percent, 25.0);
        assert_eq!(windows[0].label, "Hourly");
    }

    #[test]
    fn projects_legacy_array_without_exposing_runtime_names() {
        let windows = project(json!({
            "rateLimits": [{
                "limitName": "internal_codex_credits",
                "usedPercent": 5,
                "windowDurationMins": 60,
                "resetsAt": 30
            }]
        }));
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].id, "window-1");
        assert_eq!(windows[0].label, "Hourly");
        let output = serde_json::to_string(&windows).unwrap();
        assert!(!output.contains("internal_codex_credits"));
    }

    #[test]
    fn assigns_legacy_ids_after_filtering_invalid_entries() {
        let mut values = vec![
            json!({"usedPercent": "invalid"}),
            json!({"usedPercent": null}),
            json!({"usedPercent": 150}),
        ];
        values.extend((0..9).map(|index| json!({"usedPercent": index})));
        let windows = project(json!({"rateLimits": values}));
        assert_eq!(windows.len(), MAX_WINDOWS);
        assert_eq!(windows[0].id, "window-1");
        assert_eq!(windows[7].id, "window-8");
        assert_eq!(windows[0].used_percent, 100.0);
    }

    #[test]
    fn falls_back_when_codex_limits_have_no_valid_windows() {
        let windows = project(json!({
            "rateLimits": {"primary": {"usedPercent": 40, "windowDurationMins": 300}},
            "rateLimitsByLimitId": {
                "codex": {"primary": {"usedPercent": "invalid"}, "secondary": {}}
            }
        }));
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].id, "primary");
        assert_eq!(windows[0].used_percent, 40.0);
    }

    #[test]
    fn clamps_percentages_and_omits_invalid_windows() {
        let windows = project(json!({
            "rateLimits": [
                {"usedPercent": -20},
                {"usedPercent": 140},
                {"usedPercent": "not-a-number"},
                {"usedPercent": null},
                {"usedPercent": 50}
            ]
        }));
        assert_eq!(windows.len(), 3);
        assert_eq!(windows[0].used_percent, 0.0);
        assert_eq!(windows[0].remaining_percent, 100.0);
        assert_eq!(windows[1].used_percent, 100.0);
        assert_eq!(windows[1].remaining_percent, 0.0);
        assert_eq!(windows[2].used_percent, 50.0);
    }

    #[test]
    fn rejects_empty_or_malformed_limits() {
        assert!(project_windows(&json!({"rateLimits": []})).is_none());
        assert!(project_windows(&json!({"rateLimits": {"other": {}}})).is_none());
        assert!(project_windows(&json!({"rateLimits": "unavailable"})).is_none());
        assert!(project_windows(&json!({})).is_none());
    }

    #[test]
    fn bounds_the_projected_window_count() {
        let values = (0..12)
            .map(|index| json!({"usedPercent": index}))
            .collect::<Vec<_>>();
        let windows = project(json!({"rateLimits": values}));
        assert_eq!(windows.len(), MAX_WINDOWS);
        assert_eq!(windows[7].id, "window-8");
    }
}
