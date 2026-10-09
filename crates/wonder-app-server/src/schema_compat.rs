//! Accept additive Codex schema changes without accepting a changed contract.
//!
//! The pinned schema remains the contract Wonder was built and tested against.
//! New definitions, distinct request/notification methods, and optional object
//! fields are safe to ignore. Changed or newly required fields need a Wonder
//! release, rather than a downloaded schema silently changing authorization.

use serde_json::Value;

const STABLE: &[u8] = include_bytes!(
    "../../../research/codex-app-server/0.155.0-alpha.16.3/stable/codex_app_server_protocol.v2.schemas.json"
);
const EXPERIMENTAL: &[u8] = include_bytes!(
    "../../../research/codex-app-server/0.155.0-alpha.16.3/experimental/codex_app_server_protocol.v2.schemas.json"
);

pub(super) fn verify(stable: &[u8], experimental: &[u8]) -> Result<(), String> {
    for (name, reference, candidate) in [
        ("stable", STABLE, stable),
        ("experimental", EXPERIMENTAL, experimental),
    ] {
        let reference: Value = serde_json::from_slice(reference)
            .map_err(|error| format!("invalid embedded {name} schema: {error}"))?;
        let mut candidate: Value = serde_json::from_slice(candidate)
            .map_err(|error| format!("invalid generated {name} schema: {error}"))?;
        // 0.159 adds item-anchor cursors while retaining the same opaque string
        // and null inputs Wonder sends. Accept only that verified widening.
        let cursor = &candidate["definitions"]["ThreadItemsListParams"]["properties"]["cursor"];
        let definition = &candidate["definitions"]["ThreadItemsListCursor"];
        if [cursor, definition].iter().all(|value| {
            value.as_object().is_some_and(|properties| {
                properties.keys().all(|key| {
                    matches!(
                        key.as_str(),
                        "anyOf" | "description" | "title" | "$comment" | "examples"
                    )
                })
            })
        }) && cursor.get("anyOf")
            == Some(&serde_json::json!([
                {"$ref":"#/definitions/ThreadItemsListCursor"}, {"type":"null"}
            ]))
            && definition["anyOf"]
                .as_array()
                .is_some_and(|variants| variants.contains(&serde_json::json!({"type":"string"})))
        {
            candidate["definitions"]["ThreadItemsListParams"]["properties"]["cursor"] =
                reference["definitions"]["ThreadItemsListParams"]["properties"]["cursor"].clone();
        }
        accept_widened_error_info(&reference, &mut candidate);
        preserve(&reference, &candidate, name)?;
    }
    Ok(())
}

/// 0.162 regroups `CodexErrorInfo` from `oneOf` to `anyOf` and appends one
/// catch-all variant (any string or object) so unknown error labels still
/// deserialize. The type is reachable only from `TurnError`, which the runtime
/// sends in `Turn`, `ErrorNotification` and timeline entries; Wonder never sends
/// or reads it, so it cannot carry authority. Accept exactly that shape: every
/// earlier variant is still compared by `preserve` (added labels are allowed
/// there). Any other `anyOf` shape, or a changed catch-all, still fails.
fn accept_widened_error_info(reference: &Value, candidate: &mut Value) {
    let Some(old) = reference["definitions"]["CodexErrorInfo"]["oneOf"].as_array() else {
        return;
    };
    let Some(info) = candidate["definitions"]["CodexErrorInfo"].as_object_mut() else {
        return;
    };
    if info.contains_key("oneOf") {
        return;
    }
    let Some(variants) = info.get("anyOf").and_then(Value::as_array) else {
        return;
    };
    if variants.len() != old.len() + 1
        || variants.last() != Some(&serde_json::json!({"type": ["string", "object"]}))
    {
        return;
    }
    let kept = Value::Array(variants[..old.len()].to_vec());
    info.remove("anyOf");
    info.insert("oneOf".into(), kept);
}

fn preserve(reference: &Value, candidate: &Value, path: &str) -> Result<(), String> {
    match (reference, candidate) {
        (Value::Object(old), Value::Object(new)) => {
            for (key, value) in old {
                if matches!(
                    key.as_str(),
                    "description" | "title" | "$comment" | "examples"
                ) {
                    continue;
                }
                let next = format!("{path}.{key}");
                // 0.158 retired this optional Windows-only response property.
                // Wonder is a Mac host and never reads or sends it. All other
                // removed fields, including permission contracts, still fail.
                if key == "windowsSandboxPrivateDesktop"
                    && path.ends_with(".definitions.ConfigRequirements.properties")
                    && !new.contains_key(key)
                {
                    continue;
                }
                let current = new.get(key).ok_or_else(|| format!("{next} missing"))?;
                if key == "required" || key == "enum" {
                    // These response labels are presented generically. Added
                    // labels cannot grant authority; permission enums stay exact.
                    let extensible = key == "enum"
                        && (path.ends_with(".definitions.PlanType")
                            || path.ends_with(".definitions.CodexErrorInfo.oneOf"));
                    if extensible
                        && value
                            .as_array()
                            .zip(current.as_array())
                            .is_some_and(|(old, new)| old.iter().all(|v| new.contains(v)))
                    {
                        continue;
                    }
                    if !same_set(value, current) {
                        return Err(format!("{next} changed"));
                    }
                } else if key == "oneOf" || key == "anyOf" || key == "allOf" {
                    preserve_variants(value, current, &next)?;
                } else {
                    preserve(value, current, &next)?;
                }
            }
            for key in new.keys() {
                if old.contains_key(key)
                    || matches!(
                        key.as_str(),
                        "description" | "title" | "$comment" | "examples"
                    )
                    || path.ends_with(".definitions")
                    || path.ends_with(".properties")
                {
                    continue;
                }
                return Err(format!("{path}.{key} added a constraint"));
            }
            Ok(())
        }
        (Value::Array(old), Value::Array(new)) => {
            if old.len() != new.len() {
                return Err(format!("{path} changed length"));
            }
            for (index, (before, after)) in old.iter().zip(new).enumerate() {
                preserve(before, after, &format!("{path}[{index}]"))?;
            }
            Ok(())
        }
        _ if reference == candidate => Ok(()),
        _ => Err(format!("{path} changed")),
    }
}

fn same_set(reference: &Value, candidate: &Value) -> bool {
    match (reference.as_array(), candidate.as_array()) {
        (Some(old), Some(new)) => {
            old.len() == new.len() && old.iter().all(|value| new.contains(value))
        }
        _ => false,
    }
}

fn preserve_variants(reference: &Value, candidate: &Value, path: &str) -> Result<(), String> {
    let old = reference
        .as_array()
        .ok_or_else(|| format!("{path} is not an array"))?;
    let new = candidate
        .as_array()
        .ok_or_else(|| format!("{path} is not an array"))?;
    let additive_methods = path.ends_with(".definitions.ClientRequest.oneOf")
        || path.ends_with(".definitions.ServerNotification.oneOf");
    if !additive_methods && old.len() != new.len() {
        return Err(format!("{path} changed variants"));
    }
    if additive_methods {
        let old_methods = variant_methods(old, path)?;
        let new_methods = variant_methods(new, path)?;
        for (method, before) in old_methods {
            let after = new_methods
                .iter()
                .find(|(name, _)| *name == method)
                .map(|(_, value)| *value)
                .ok_or_else(|| format!("{path}: {method} removed"))?;
            preserve(before, after, &format!("{path}.{method}"))?;
        }
        return Ok(());
    }
    let mut used = vec![false; new.len()];
    for (index, before) in old.iter().enumerate() {
        let Some(position) = new.iter().enumerate().find_map(|(position, after)| {
            (!used[position] && preserve(before, after, path).is_ok()).then_some(position)
        }) else {
            return Err(format!("{path}[{index}] changed"));
        };
        used[position] = true;
    }
    Ok(())
}

fn variant_methods<'a>(
    variants: &'a [Value],
    path: &str,
) -> Result<Vec<(&'a str, &'a Value)>, String> {
    let mut methods = Vec::with_capacity(variants.len());
    for variant in variants {
        let method = variant["properties"]["method"]["enum"][0]
            .as_str()
            .ok_or_else(|| format!("{path} has a variant without a method"))?;
        if methods.iter().any(|(existing, _)| *existing == method) {
            return Err(format!("{path} has duplicate method {method}"));
        }
        methods.push((method, variant));
    }
    Ok(methods)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn baseline() -> (Value, Value) {
        (
            serde_json::from_slice(STABLE).unwrap(),
            serde_json::from_slice(EXPERIMENTAL).unwrap(),
        )
    }

    fn check(stable: &Value, experimental: &Value) -> Result<(), String> {
        verify(
            &serde_json::to_vec(stable).unwrap(),
            &serde_json::to_vec(experimental).unwrap(),
        )
    }

    #[test]
    fn current_contract_is_accepted() {
        let (stable, experimental) = baseline();
        assert!(check(&stable, &experimental).is_ok());
    }

    #[test]
    fn optional_fields_and_new_methods_do_not_require_a_wonder_release() {
        let (mut stable, mut experimental) = baseline();
        stable["definitions"]["ThreadStartParams"]["properties"]["futureOption"] =
            json!({"type":"string"});
        experimental["definitions"]["FutureResponse"] = json!({"type":"object"});
        let request = experimental["definitions"]["ClientRequest"]["oneOf"][0].clone();
        let mut added = request;
        added["properties"]["method"]["enum"] = json!(["future/read"]);
        experimental["definitions"]["ClientRequest"]["oneOf"]
            .as_array_mut()
            .unwrap()
            .push(added);
        assert!(check(&stable, &experimental).is_ok());
    }

    #[test]
    fn additive_error_plan_and_string_cursor_shapes_preserve_existing_inputs() {
        let (mut stable, mut experimental) = baseline();
        for schema in [&mut stable, &mut experimental] {
            schema["definitions"]["CodexErrorInfo"]["oneOf"][0]["enum"]
                .as_array_mut()
                .unwrap()
                .push(json!("flexUnavailable"));
            schema["definitions"]["PlanType"]["enum"]
                .as_array_mut()
                .unwrap()
                .push(json!("promax"));
            schema["definitions"]["ThreadItemsListParams"]["properties"]["cursor"] =
                json!({"anyOf":[{"$ref":"#/definitions/ThreadItemsListCursor"},{"type":"null"}]});
            schema["definitions"]["ThreadItemsListCursor"] =
                json!({"anyOf":[{"type":"string"},{"type":"object"}]});
        }
        assert!(check(&stable, &experimental).is_ok());
        experimental["definitions"]["ThreadItemsListParams"]["properties"]["cursor"]["maxLength"] =
            json!(1);
        assert!(
            check(&stable, &experimental).is_err(),
            "New cursor constraints must not be hidden"
        );
        experimental["definitions"]["ThreadItemsListParams"]["properties"]["cursor"]
            .as_object_mut()
            .unwrap()
            .remove("maxLength");
        experimental["definitions"]["ThreadItemsListCursor"]["maxLength"] = json!(1);
        assert!(
            check(&stable, &experimental).is_err(),
            "Referenced constraints must remain visible"
        );
        experimental["definitions"]["ThreadItemsListCursor"]
            .as_object_mut()
            .unwrap()
            .remove("maxLength");
        experimental["definitions"]["ThreadItemsListCursor"]["anyOf"][0] =
            json!({"type":"integer"});
        assert!(
            check(&stable, &experimental).is_err(),
            "Opaque strings must remain accepted"
        );
        let (mut stable, experimental) = baseline();
        stable["definitions"]["PlanType"]["enum"]
            .as_array_mut()
            .unwrap()
            .remove(0);
        assert!(
            check(&stable, &experimental).is_err(),
            "Existing response labels must remain supported"
        );
    }

    #[test]
    fn changed_or_newly_required_fields_are_rejected() {
        let (stable, mut experimental) = baseline();
        experimental["definitions"]["TurnStartParams"]["properties"]["permissions"]["type"] =
            json!("object");
        assert!(check(&stable, &experimental).is_err());
        let (stable, mut experimental) = baseline();
        experimental["definitions"]["TurnStartParams"]["required"]
            .as_array_mut()
            .unwrap()
            .push(json!("futureOption"));
        assert!(check(&stable, &experimental).is_err());
    }

    #[test]
    fn retired_windows_response_field_does_not_disable_the_mac_runtime() {
        let (mut stable, mut experimental) = baseline();
        for schema in [&mut stable, &mut experimental] {
            schema["definitions"]["ConfigRequirements"]["properties"]
                .as_object_mut()
                .unwrap()
                .remove("windowsSandboxPrivateDesktop");
        }
        assert!(check(&stable, &experimental).is_ok());
        experimental["definitions"]["TurnStartParams"]["properties"]
            .as_object_mut()
            .unwrap()
            .remove("permissions");
        assert!(check(&stable, &experimental).is_err());
    }

    #[test]
    fn duplicate_methods_and_new_constraints_are_rejected() {
        let (stable, mut experimental) = baseline();
        let request = experimental["definitions"]["ClientRequest"]["oneOf"][0].clone();
        experimental["definitions"]["ClientRequest"]["oneOf"]
            .as_array_mut()
            .unwrap()
            .push(request);
        assert!(check(&stable, &experimental).is_err());
        let (stable, mut experimental) = baseline();
        experimental["definitions"]["TurnStartParams"]["additionalProperties"] = json!(false);
        assert!(check(&stable, &experimental).is_err());
    }

    const V162_STABLE: &[u8] = include_bytes!(
        "../../../research/codex-app-server/0.162.0-alpha.2/stable/codex_app_server_protocol.v2.schemas.json"
    );
    const V162_EXPERIMENTAL: &[u8] = include_bytes!(
        "../../../research/codex-app-server/0.162.0-alpha.2/experimental/codex_app_server_protocol.v2.schemas.json"
    );

    fn v162() -> (Value, Value) {
        (
            serde_json::from_slice(V162_STABLE).unwrap(),
            serde_json::from_slice(V162_EXPERIMENTAL).unwrap(),
        )
    }

    #[test]
    fn generated_0_162_schemas_pass_the_additive_check_without_the_hash_shortcut() {
        // Regression: 0.162 regrouped CodexErrorInfo as anyOf and every unknown
        // version path then failed with "CodexErrorInfo.oneOf missing".
        assert_eq!(verify(V162_STABLE, V162_EXPERIMENTAL), Ok(()));
    }

    #[test]
    fn permission_and_sandbox_contract_changes_still_fail_on_0_162() {
        let (stable, experimental) = v162();
        for (path, mutate) in [
            (
                "permissions type",
                Box::new(|schema: &mut Value| {
                    schema["definitions"]["TurnStartParams"]["properties"]["permissions"]["type"] =
                        json!("object");
                }) as Box<dyn Fn(&mut Value)>,
            ),
            (
                "permissions removed",
                Box::new(|schema: &mut Value| {
                    schema["definitions"]["ThreadStartParams"]["properties"]
                        .as_object_mut()
                        .unwrap()
                        .remove("permissions");
                }),
            ),
            (
                "approval policy enum widened",
                Box::new(|schema: &mut Value| {
                    schema["definitions"]["AskForApproval"]["oneOf"][0]["enum"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!("future-auto-approve"));
                }),
            ),
        ] {
            let (mut changed_stable, mut changed_experimental) =
                (stable.clone(), experimental.clone());
            mutate(&mut changed_stable);
            mutate(&mut changed_experimental);
            assert!(
                check(&changed_stable, &changed_experimental).is_err(),
                "{path} must need a Wonder release"
            );
        }
    }

    #[test]
    fn only_the_exact_error_info_widening_is_accepted() {
        let (mut stable, experimental) = v162();
        let variants = stable["definitions"]["CodexErrorInfo"]["anyOf"]
            .as_array_mut()
            .unwrap();
        // A different catch-all is a different contract.
        *variants.last_mut().unwrap() = json!({"type": "string"});
        assert!(check(&stable, &experimental).is_err());
        let (mut stable, experimental) = v162();
        // An existing variant disappearing is not a widening.
        let variants = stable["definitions"]["CodexErrorInfo"]["anyOf"]
            .as_array_mut()
            .unwrap();
        variants.remove(1);
        assert!(check(&stable, &experimental).is_err());
    }
}
