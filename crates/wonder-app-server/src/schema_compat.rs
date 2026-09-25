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
        let candidate: Value = serde_json::from_slice(candidate)
            .map_err(|error| format!("invalid generated {name} schema: {error}"))?;
        preserve(&reference, &candidate, name)?;
    }
    Ok(())
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
                let current = new.get(key).ok_or_else(|| format!("{next} missing"))?;
                if key == "required" || key == "enum" {
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
}
