//! Decide whether a Codex runtime Wonder has not seen can still serve Wonder.
//!
//! ChatGPT updates its bundled Codex without asking, so an unknown version is
//! compared with the pinned schema Wonder was built and tested against. Only
//! the contracts Wonder exercises are compared: the params and responses of
//! the methods `RpcClient` may send (`crate::sent_methods`) and the params of
//! the notifications wonderd reads (`crate::CONSUMED_NOTIFICATIONS`). Anything
//! else Codex adds, changes or retires cannot reach Wonder and passes.
//!
//! The comparison is directional:
//!
//! - Data Wonder sends (request params) may only widen. New optional fields,
//!   new variants and new enum labels are fine; a newly required field, a
//!   narrowed type, a removed label, a new constraint, or a removed field that
//!   was required, governs permissions or is now rejected, needs a Wonder
//!   release.
//! - Data Wonder receives (responses, notifications) may only grow. New
//!   fields, variants and labels are fine because ingestion keeps unknown
//!   items and labels as opaque values; removed optional fields are fine.
//!   A removed or no-longer-required field, a widened or changed type, or a
//!   removed label needs a release.
//! - Approval, sandbox and permission definitions Wonder sends stay exact:
//!   even an added label there needs review before Wonder relies on it.

use serde_json::{Map, Value};
use std::collections::HashSet;

const STABLE: &[u8] = include_bytes!(
    "../../../research/codex-app-server/0.155.0-alpha.16.3/stable/codex_app_server_protocol.v2.schemas.json"
);
const EXPERIMENTAL: &[u8] = include_bytes!(
    "../../../research/codex-app-server/0.155.0-alpha.16.3/experimental/codex_app_server_protocol.v2.schemas.json"
);

/// Keywords that document a schema without constraining values.
const ANNOTATIONS: &[&str] = &[
    "description",
    "title",
    "$comment",
    "examples",
    "$schema",
    "deprecated",
    "readOnly",
    "writeOnly",
];

/// Value constraints whose removal only accepts more values.
const CONSTRAINTS: &[&str] = &[
    "format",
    "maxLength",
    "minLength",
    "maximum",
    "minimum",
    "exclusiveMaximum",
    "exclusiveMinimum",
    "pattern",
    "maxItems",
    "minItems",
    "uniqueItems",
    "multipleOf",
    "maxProperties",
    "minProperties",
    "additionalProperties",
];

/// Responses whose names do not follow `<Name>Params` -> `<Name>Response`.
const RESPONSE_NAMES: &[(&str, &str)] =
    &[("configRequirements/read", "ConfigRequirementsReadResponse")];

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum Direction {
    /// Wonder sends this value to Codex.
    Input,
    /// Codex sends this value to Wonder.
    Output,
}

pub(super) fn verify(stable: &[u8], experimental: &[u8]) -> Result<(), String> {
    for (name, reference, candidate) in [
        ("stable", STABLE, stable),
        ("experimental", EXPERIMENTAL, experimental),
    ] {
        let reference: Value = serde_json::from_slice(reference)
            .map_err(|error| format!("invalid embedded {name} schema: {error}"))?;
        let candidate: Value = serde_json::from_slice(candidate)
            .map_err(|error| format!("invalid generated {name} schema: {error}"))?;
        verify_schema(&reference, &candidate).map_err(|reason| format!("{name}: {reason}"))?;
    }
    Ok(())
}

fn verify_schema(reference: &Value, candidate: &Value) -> Result<(), String> {
    let empty = Map::new();
    let old = reference["definitions"].as_object().unwrap_or(&empty);
    let new = candidate["definitions"]
        .as_object()
        .ok_or("schema has no definitions")?;
    let mut contract = Contract {
        old,
        new,
        seen: HashSet::new(),
    };
    let old_requests = methods(old, "ClientRequest")?;
    let new_requests = methods(new, "ClientRequest")?;
    for (method, required) in crate::sent_methods() {
        // A method the pinned schema lacks (Wonder's Claude bridge methods)
        // has no Codex contract to protect.
        let Some(before) = find(&old_requests, method) else {
            continue;
        };
        let Some(after) = find(&new_requests, method) else {
            if required {
                return Err(format!("{method} removed"));
            }
            continue;
        };
        let path = format!("{method} params");
        contract.compare_params(before, after, Direction::Input, &path)?;
        if let Some(response) = response_name(method, before).filter(|name| old.contains_key(name))
        {
            let current = response_name(method, after)
                .filter(|name| new.contains_key(name))
                .ok_or_else(|| format!("{method} response missing"))?;
            contract.compare_definition(&response, &current, Direction::Output, false)?;
        }
    }
    let old_notifications = methods(old, "ServerNotification")?;
    let new_notifications = methods(new, "ServerNotification")?;
    for (method, required) in crate::CONSUMED_NOTIFICATIONS {
        let Some(before) = find(&old_notifications, method) else {
            continue;
        };
        let Some(after) = find(&new_notifications, method) else {
            if required {
                return Err(format!("{method} notification removed"));
            }
            continue;
        };
        let path = format!("{method} notification");
        contract.compare_params(before, after, Direction::Output, &path)?;
    }
    Ok(())
}

fn methods<'a>(
    definitions: &'a Map<String, Value>,
    union: &str,
) -> Result<Vec<(&'a str, &'a Value)>, String> {
    let Some(variants) = definitions
        .get(union)
        .and_then(|value| value["oneOf"].as_array())
    else {
        return Err(format!("{union} missing"));
    };
    let mut methods = Vec::with_capacity(variants.len());
    for variant in variants {
        let method = variant["properties"]["method"]["enum"][0]
            .as_str()
            .ok_or_else(|| format!("{union} has a variant without a method"))?;
        if methods.iter().any(|(existing, _)| *existing == method) {
            return Err(format!("{union} has duplicate method {method}"));
        }
        methods.push((method, variant));
    }
    Ok(methods)
}

fn find<'a>(methods: &[(&str, &'a Value)], method: &str) -> Option<&'a Value> {
    methods
        .iter()
        .find(|(name, _)| *name == method)
        .map(|(_, variant)| *variant)
}

/// The response definition of a request: `ThreadStartParams` answers with
/// `ThreadStartResponse`, `GetAccountRateLimitsParams` (inside a nullable
/// `anyOf`) with `GetAccountRateLimitsResponse`.
fn response_name(method: &str, variant: &Value) -> Option<String> {
    if let Some((_, name)) = RESPONSE_NAMES.iter().find(|(known, _)| *known == method) {
        return Some((*name).to_owned());
    }
    fn params_ref(value: &Value) -> Option<&str> {
        if let Some(name) = value["$ref"].as_str() {
            return name.strip_prefix("#/definitions/");
        }
        ["anyOf", "oneOf", "allOf"]
            .iter()
            .filter_map(|key| value[*key].as_array())
            .flatten()
            .find_map(params_ref)
    }
    params_ref(&variant["properties"]["params"])
        .and_then(|name| name.strip_suffix("Params"))
        .map(|name| format!("{name}Response"))
}

fn is_authority(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    ["approval", "sandbox", "permission"]
        .iter()
        .any(|word| name.contains(word))
}

fn is_annotation(key: &str) -> bool {
    ANNOTATIONS.contains(&key)
}

/// `{"$ref": X}` or `{"allOf": [{"$ref": X}]}` with only annotations beside it.
fn reference_name(value: &Value) -> Option<&str> {
    let object = value.as_object()?;
    if let Some(name) = object.get("$ref").and_then(Value::as_str) {
        if object.keys().all(|key| key == "$ref" || is_annotation(key)) {
            return name.strip_prefix("#/definitions/");
        }
        return None;
    }
    let all_of = object.get("allOf")?.as_array()?;
    if all_of.len() == 1
        && object
            .keys()
            .all(|key| key == "allOf" || is_annotation(key))
    {
        return reference_name(&all_of[0]);
    }
    None
}

fn union_of(object: &Map<String, Value>) -> Option<(&'static str, &Vec<Value>)> {
    ["oneOf", "anyOf"]
        .into_iter()
        .find_map(|key| object.get(key).and_then(Value::as_array).map(|v| (key, v)))
}

fn type_set(value: &Value) -> Vec<&str> {
    match value {
        Value::String(name) => vec![name.as_str()],
        Value::Array(names) => names.iter().filter_map(Value::as_str).collect(),
        _ => Vec::new(),
    }
}

fn string_set(value: Option<&Value>) -> Vec<&str> {
    value
        .and_then(Value::as_array)
        .map(|values| values.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

struct Contract<'a> {
    old: &'a Map<String, Value>,
    new: &'a Map<String, Value>,
    /// Definition pairs compared (or being compared) in a direction. A cycle
    /// back to a pair in progress is assumed compatible.
    seen: HashSet<(String, String, Direction, bool)>,
}

impl<'a> Contract<'a> {
    fn compare_params(
        &mut self,
        before: &Value,
        after: &Value,
        direction: Direction,
        path: &str,
    ) -> Result<(), String> {
        match (
            before["properties"].get("params"),
            after["properties"].get("params"),
        ) {
            (None, _) => Ok(()),
            (Some(_), None) => Err(format!("{path} missing")),
            (Some(old), Some(new)) => self.compare(old, new, direction, false, path),
        }
    }

    fn definition(definitions: &'a Map<String, Value>, name: &str) -> Result<&'a Value, String> {
        definitions
            .get(name)
            .ok_or_else(|| format!("{name} missing"))
    }

    fn compare_definition(
        &mut self,
        old_name: &str,
        new_name: &str,
        direction: Direction,
        exact: bool,
    ) -> Result<(), String> {
        let exact = exact || (direction == Direction::Input && is_authority(old_name));
        if !self
            .seen
            .insert((old_name.to_owned(), new_name.to_owned(), direction, exact))
        {
            return Ok(());
        }
        let old = Self::definition(self.old, old_name)?;
        let new = Self::definition(self.new, new_name)?;
        self.compare(old, new, direction, exact, old_name)
    }

    /// Runs a comparison whose failure only means "not this one".
    fn attempt(
        &mut self,
        old: &Value,
        new: &Value,
        direction: Direction,
        exact: bool,
        path: &str,
    ) -> bool {
        let saved = self.seen.clone();
        let accepted = self.compare(old, new, direction, exact, path).is_ok();
        if !accepted {
            self.seen = saved;
        }
        accepted
    }

    fn compare(
        &mut self,
        old: &Value,
        new: &Value,
        direction: Direction,
        exact: bool,
        path: &str,
    ) -> Result<(), String> {
        match (reference_name(old), reference_name(new)) {
            (Some(before), Some(after)) => {
                return self.compare_definition(before, after, direction, exact)
            }
            (Some(before), None) => {
                let exact = exact || (direction == Direction::Input && is_authority(before));
                let old = Self::definition(self.old, before)?;
                return self.compare(old, new, direction, exact, path);
            }
            (None, Some(after)) => {
                let new = Self::definition(self.new, after)?;
                return self.compare(old, new, direction, exact, path);
            }
            (None, None) => {}
        }
        match (old, new) {
            (Value::Object(old), Value::Object(new)) => {
                self.compare_object(old, new, direction, exact, path)
            }
            (Value::Array(old), Value::Array(new)) => {
                if old.len() != new.len() {
                    return Err(format!("{path} changed length"));
                }
                for (index, (before, after)) in old.iter().zip(new).enumerate() {
                    self.compare(before, after, direction, exact, &format!("{path}[{index}]"))?;
                }
                Ok(())
            }
            _ if old == new => Ok(()),
            _ => Err(format!("{path} changed")),
        }
    }

    fn compare_object(
        &mut self,
        old: &Map<String, Value>,
        new: &Map<String, Value>,
        direction: Direction,
        exact: bool,
        path: &str,
    ) -> Result<(), String> {
        let old_union = union_of(old);
        let new_union = union_of(new);
        match (old_union, new_union) {
            (Some((_, before)), Some((_, after))) => {
                self.compare_variants(before, after, direction, exact, path)?;
            }
            (None, Some((union, after))) => {
                // A single shape became one of several (an opaque string
                // cursor gaining an object form). Every value the old shape
                // described must still fit one of the new variants.
                for piece in pieces(old) {
                    if !after
                        .iter()
                        .any(|variant| self.attempt(&piece, variant, direction, exact, path))
                    {
                        return Err(format!("{path} changed"));
                    }
                }
                if direction == Direction::Input || exact {
                    if let Some(key) = new
                        .keys()
                        .find(|key| *key != union && !is_annotation(key) && *key != "default")
                    {
                        return Err(format!("{path}.{key} added a constraint"));
                    }
                }
                return Ok(());
            }
            (Some(_), None) => return Err(format!("{path} changed variants")),
            (None, None) => {}
        }
        let union = old_union.map(|(key, _)| key);
        for (key, before) in old {
            if is_annotation(key) || Some(key.as_str()) == union || key == "required" {
                continue;
            }
            let next = format!("{path}.{key}");
            let after = new.get(key);
            match key.as_str() {
                "properties" => self.compare_properties(old, new, direction, exact, path)?,
                "enum" => {
                    let Some(after) = after else {
                        if exact {
                            return Err(format!("{next} removed"));
                        }
                        continue;
                    };
                    let (before, after) = (
                        before.as_array().ok_or_else(|| format!("{next} invalid"))?,
                        after.as_array().ok_or_else(|| format!("{next} invalid"))?,
                    );
                    if let Some(lost) = before.iter().find(|label| !after.contains(label)) {
                        return Err(format!("{next} lost {lost}"));
                    }
                    if exact && after.len() != before.len() {
                        return Err(format!("{next} changed"));
                    }
                }
                "type" => {
                    let before = type_set(before);
                    let Some(after) = after.map(type_set) else {
                        if direction == Direction::Input && !exact {
                            continue;
                        }
                        return Err(format!("{next} removed"));
                    };
                    let widened = before.iter().all(|kind| after.contains(kind));
                    let narrowed = after.iter().all(|kind| before.contains(kind));
                    let compatible = match direction {
                        _ if exact => widened && narrowed,
                        Direction::Input => widened,
                        Direction::Output => narrowed,
                    };
                    if !compatible {
                        return Err(format!("{next} changed"));
                    }
                }
                // The runtime applies a default when Wonder omits a field;
                // a changed default changes what Wonder's request means.
                "default" => {
                    if direction == Direction::Input && after != Some(before) {
                        return Err(format!("{next} changed"));
                    }
                }
                "additionalProperties"
                    if direction == Direction::Input
                        && before == &Value::Bool(false)
                        && after.is_none_or(|after| after == &Value::Bool(true)) => {}
                _ => match after {
                    Some(after) => self.compare(before, after, direction, exact, &next)?,
                    None if CONSTRAINTS.contains(&key.as_str()) && !exact => {}
                    None => return Err(format!("{next} missing")),
                },
            }
        }
        let before = string_set(old.get("required"));
        let after = string_set(new.get("required"));
        match direction {
            Direction::Input => {
                if let Some(field) = after.iter().find(|field| !before.contains(field)) {
                    return Err(format!("{path} now requires {field}"));
                }
            }
            Direction::Output => {
                if let Some(field) = before.iter().find(|field| !after.contains(field)) {
                    return Err(format!("{path}.{field} is no longer required"));
                }
            }
        }
        if direction == Direction::Input || exact {
            for key in new.keys() {
                if old.contains_key(key)
                    || is_annotation(key)
                    || matches!(key.as_str(), "properties" | "required" | "default")
                    || Some(key.as_str()) == new_union.map(|(key, _)| key)
                {
                    continue;
                }
                return Err(format!("{path}.{key} added a constraint"));
            }
        }
        Ok(())
    }

    fn compare_properties(
        &mut self,
        old: &Map<String, Value>,
        new: &Map<String, Value>,
        direction: Direction,
        exact: bool,
        path: &str,
    ) -> Result<(), String> {
        let empty = Map::new();
        let before = old["properties"].as_object().unwrap_or(&empty);
        let after = new
            .get("properties")
            .and_then(Value::as_object)
            .unwrap_or(&empty);
        let required = string_set(old.get("required"));
        let closed = new.get("additionalProperties") == Some(&Value::Bool(false));
        for (name, schema) in before {
            let next = format!("{path}.{name}");
            match after.get(name) {
                Some(current) => self.compare(schema, current, direction, exact, &next)?,
                // Codex ignores a field it no longer knows, so Wonder loses
                // only that field's effect. That is acceptable unless the
                // field was required, governs permissions, or is now refused.
                None if direction == Direction::Input
                    && !exact
                    && !required.contains(&name.as_str())
                    && !is_authority(name)
                    && !closed => {}
                // Wonder already copes with an optional field being absent.
                None if direction == Direction::Output && !required.contains(&name.as_str()) => {}
                None => return Err(format!("{next} removed")),
            }
        }
        Ok(())
    }

    fn compare_variants(
        &mut self,
        old: &[Value],
        new: &[Value],
        direction: Direction,
        exact: bool,
        path: &str,
    ) -> Result<(), String> {
        if exact && new.len() != old.len() {
            return Err(format!("{path} changed variants"));
        }
        let old_keys: Vec<_> = old.iter().map(variant_key).collect();
        let new_keys: Vec<_> = new.iter().map(variant_key).collect();
        let mut used = vec![false; new.len()];
        for (index, before) in old.iter().enumerate() {
            let next = format!("{path}[{index}]");
            let key = old_keys[index].as_ref();
            let unique = key.filter(|key| {
                old_keys
                    .iter()
                    .filter(|other| other.as_ref() == Some(key))
                    .count()
                    == 1
                    && new_keys
                        .iter()
                        .filter(|other| other.as_ref() == Some(key))
                        .count()
                        == 1
            });
            if let Some(key) = unique {
                // A tagged variant keeps its identity: compare it with its
                // successor and report exactly what changed.
                let position = new_keys
                    .iter()
                    .position(|other| other.as_ref() == Some(key))
                    .unwrap();
                if !used[position] {
                    self.compare(before, &new[position], direction, exact, &next)?;
                    used[position] = true;
                    continue;
                }
            }
            let Some(position) = (0..new.len()).find(|position| {
                !used[*position] && self.attempt(before, &new[*position], direction, exact, &next)
            }) else {
                return Err(format!("{next} removed or changed"));
            };
            used[position] = true;
        }
        Ok(())
    }
}

/// The separately matchable shapes of a non-union schema: a nullable string
/// is a string or a null.
fn pieces(object: &Map<String, Value>) -> Vec<Value> {
    let structural: Map<String, Value> = object
        .iter()
        .filter(|(key, _)| !is_annotation(key))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    match structural.get("type") {
        Some(Value::Array(kinds)) => kinds
            .iter()
            .map(|kind| {
                if kind == "null" {
                    serde_json::json!({"type": "null"})
                } else {
                    let mut piece = structural.clone();
                    piece.insert("type".into(), kind.clone());
                    Value::Object(piece)
                }
            })
            .collect(),
        _ => vec![Value::Object(structural)],
    }
}

/// The identity of a union variant across versions: its tag, method, first
/// label, single externally tagged property, reference or JSON type.
fn variant_key(variant: &Value) -> Option<String> {
    if let Some(name) = reference_name(variant) {
        return Some(format!("ref:{name}"));
    }
    for tag in ["type", "method"] {
        if let Some(label) = variant["properties"][tag]["enum"]
            .as_array()
            .filter(|labels| labels.len() == 1)
            .and_then(|labels| labels[0].as_str())
        {
            return Some(format!("{tag}:{label}"));
        }
    }
    if let Some(label) = variant["enum"].as_array().and_then(|labels| labels.first()) {
        return Some(format!("enum:{label}"));
    }
    let required = string_set(variant.get("required"));
    if variant["type"] == "object"
        && required.len() == 1
        && variant["properties"]
            .as_object()
            .is_some_and(|p| p.len() == 1)
    {
        return Some(format!("field:{}", required[0]));
    }
    if !variant["type"].is_null() {
        return Some(format!("json:{}", variant["type"]));
    }
    None
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

    type Mutation = Box<dyn Fn(&mut Value)>;

    fn mutation(apply: impl Fn(&mut Value) + 'static) -> Mutation {
        Box::new(apply)
    }

    fn variants<'v>(schema: &'v mut Value, definition: &str) -> &'v mut Vec<Value> {
        let definition = &mut schema["definitions"][definition];
        let key = if definition.get("oneOf").is_some() {
            "oneOf"
        } else {
            "anyOf"
        };
        definition[key].as_array_mut().unwrap()
    }

    fn tagged<'v>(schema: &'v mut Value, definition: &str, tag: &str) -> &'v mut Value {
        variants(schema, definition)
            .iter_mut()
            .find(|variant| variant["properties"]["type"]["enum"][0] == tag)
            .unwrap()
    }

    fn methods_mut<'v>(schema: &'v mut Value, union: &str) -> &'v mut Vec<Value> {
        schema["definitions"][union]["oneOf"]
            .as_array_mut()
            .unwrap()
    }

    fn assert_cases(
        schemas: impl Fn() -> (Value, Value),
        cases: Vec<(&str, Mutation)>,
        accepted: bool,
    ) {
        for (case, mutate) in cases {
            let (mut stable, mut experimental) = schemas();
            mutate(&mut stable);
            mutate(&mut experimental);
            let result = check(&stable, &experimental);
            assert_eq!(
                result.is_ok(),
                accepted,
                "{case}: {result:?} ({})",
                if accepted {
                    "Wonder does not depend on this, so it must not need a Wonder release"
                } else {
                    "this breaks Wonder, so it must need a Wonder release"
                }
            );
        }
    }

    #[test]
    fn current_contract_is_accepted() {
        let (stable, experimental) = baseline();
        assert!(check(&stable, &experimental).is_ok());
    }

    #[test]
    fn every_sent_method_has_a_compared_response() {
        // Guards response derivation: a request whose response cannot be
        // named would silently escape the check.
        let (_, experimental) = baseline();
        let definitions = experimental["definitions"].as_object().unwrap();
        let requests = methods(definitions, "ClientRequest").unwrap();
        for (method, _) in crate::sent_methods() {
            let Some(variant) = find(&requests, method) else {
                continue;
            };
            if method == "initialize" {
                continue;
            }
            let response = response_name(method, variant);
            assert!(
                response
                    .as_ref()
                    .is_some_and(|name| definitions.contains_key(name)),
                "{method} has no response definition ({response:?}); add it to RESPONSE_NAMES"
            );
        }
    }

    #[test]
    fn changes_wonder_cannot_observe_pass_without_a_release() {
        assert_cases(
            baseline,
            vec![
                (
                    "new optional request field",
                    mutation(|s| {
                        s["definitions"]["ThreadStartParams"]["properties"]["futureOption"] =
                            json!({"type":"string"});
                    }),
                ),
                (
                    "new method and definition",
                    mutation(|s| {
                        s["definitions"]["FutureResponse"] = json!({"type":"object"});
                        let mut added = methods_mut(s, "ClientRequest")[0].clone();
                        added["properties"]["method"]["enum"] = json!(["future/read"]);
                        methods_mut(s, "ClientRequest").push(added);
                    }),
                ),
                (
                    "new notification",
                    mutation(|s| {
                        let mut added = methods_mut(s, "ServerNotification")[0].clone();
                        added["properties"]["method"]["enum"] = json!(["future/changed"]);
                        methods_mut(s, "ServerNotification").push(added);
                    }),
                ),
                (
                    "changed params of a method Wonder never sends",
                    mutation(|s| {
                        s["definitions"]["FuzzyFileSearchParams"]["required"] =
                            json!(["query", "roots", "futureRequired"]);
                        s["definitions"]["FuzzyFileSearchParams"]["properties"]["query"] =
                            json!({"type":"integer"});
                    }),
                ),
                (
                    "removed method Wonder never sends",
                    mutation(|s| {
                        methods_mut(s, "ClientRequest").retain(|variant| {
                            variant["properties"]["method"]["enum"][0] != "fuzzyFileSearch"
                        });
                    }),
                ),
                (
                    "removed notification Wonder never reads",
                    mutation(|s| {
                        methods_mut(s, "ServerNotification").retain(|variant| {
                            variant["properties"]["method"]["enum"][0]
                                != "thread/tokenUsage/updated"
                        });
                    }),
                ),
                (
                    "new message phase label",
                    mutation(|s| {
                        variants(s, "MessagePhase")
                            .push(json!({"enum":["future_phase"], "type":"string"}));
                    }),
                ),
                (
                    "new thread item type",
                    mutation(|s| {
                        let mut added = tagged(s, "ThreadItem", "plan").clone();
                        added["properties"]["type"]["enum"] = json!(["futureItem"]);
                        added["required"] = json!(["id", "type", "futureField"]);
                        variants(s, "ThreadItem").push(added);
                    }),
                ),
                (
                    "new turn status and error labels",
                    mutation(|s| {
                        s["definitions"]["TurnStatus"]["enum"]
                            .as_array_mut()
                            .unwrap()
                            .push(json!("paused"));
                        variants(s, "CodexErrorInfo")[0]["enum"]
                            .as_array_mut()
                            .unwrap()
                            .push(json!("flexUnavailable"));
                        variants(s, "CodexErrorInfo").push(json!({"type":["string","object"]}));
                        s["definitions"]["PlanType"]["enum"]
                            .as_array_mut()
                            .unwrap()
                            .push(json!("promax"));
                    }),
                ),
                (
                    "new required response field",
                    mutation(|s| {
                        let thread = &mut s["definitions"]["Thread"];
                        thread["properties"]["futureField"] = json!({"type":"string"});
                        thread["required"]
                            .as_array_mut()
                            .unwrap()
                            .push(json!("futureField"));
                    }),
                ),
                (
                    "removed optional response field",
                    mutation(|s| {
                        s["definitions"]["ConfigRequirements"]["properties"]
                            .as_object_mut()
                            .unwrap()
                            .remove("windowsSandboxPrivateDesktop");
                    }),
                ),
                (
                    "removed optional request field outside permissions",
                    mutation(|s| {
                        s["definitions"]["ThreadResumeParams"]["properties"]
                            .as_object_mut()
                            .unwrap()
                            .remove("history");
                    }),
                ),
                (
                    "new variant in history Wonder could send",
                    mutation(|s| {
                        variants(s, "ResponseItem").push(json!({
                            "type":"object", "required":["type"],
                            "properties":{"type":{"enum":["future_item"],"type":"string"}}
                        }));
                    }),
                ),
                (
                    "widened request label outside permissions",
                    mutation(|s| {
                        s["definitions"]["ThreadSortKey"]["enum"]
                            .as_array_mut()
                            .unwrap()
                            .push(json!("future_key"));
                    }),
                ),
                (
                    "opaque string cursor gains an object form",
                    mutation(|s| {
                        s["definitions"]["ThreadItemsListParams"]["properties"]["cursor"] = json!(
                            {"anyOf":[{"$ref":"#/definitions/ThreadItemsListCursor"},{"type":"null"}]}
                        );
                        s["definitions"]["ThreadItemsListCursor"] =
                            json!({"anyOf":[{"type":"string"},{"type":"object"}]});
                    }),
                ),
            ],
            true,
        );
    }

    #[test]
    fn changes_that_break_wonder_still_need_a_release() {
        assert_cases(
            baseline,
            vec![
                (
                    "newly required request field",
                    mutation(|s| {
                        s["definitions"]["TurnStartParams"]["required"]
                            .as_array_mut()
                            .unwrap()
                            .push(json!("futureOption"));
                    }),
                ),
                (
                    "changed request field type",
                    mutation(|s| {
                        s["definitions"]["TurnStartParams"]["properties"]["permissions"]["type"] =
                            json!("object");
                    }),
                ),
                (
                    "removed permission field",
                    mutation(|s| {
                        s["definitions"]["TurnStartParams"]["properties"]
                            .as_object_mut()
                            .unwrap()
                            .remove("permissions");
                    }),
                ),
                (
                    "removed required request field",
                    mutation(|s| {
                        s["definitions"]["TurnStartParams"]["properties"]
                            .as_object_mut()
                            .unwrap()
                            .remove("input");
                    }),
                ),
                (
                    "request now refuses unknown fields",
                    mutation(|s| {
                        s["definitions"]["TurnStartParams"]["additionalProperties"] = json!(false);
                    }),
                ),
                (
                    "request input variant removed",
                    mutation(|s| {
                        variants(s, "UserInput")
                            .retain(|variant| variant["properties"]["type"]["enum"][0] != "image");
                    }),
                ),
                (
                    "approval policy label added",
                    mutation(|s| {
                        variants(s, "AskForApproval")[0]["enum"]
                            .as_array_mut()
                            .unwrap()
                            .push(json!("future-auto-approve"));
                    }),
                ),
                (
                    "required method removed",
                    mutation(|s| {
                        methods_mut(s, "ClientRequest").retain(|variant| {
                            variant["properties"]["method"]["enum"][0] != "turn/start"
                        });
                    }),
                ),
                (
                    "required notification removed",
                    mutation(|s| {
                        methods_mut(s, "ServerNotification").retain(|variant| {
                            variant["properties"]["method"]["enum"][0] != "turn/completed"
                        });
                    }),
                ),
                (
                    "response field Wonder relies on removed",
                    mutation(|s| {
                        s["definitions"]["Thread"]["properties"]
                            .as_object_mut()
                            .unwrap()
                            .remove("id");
                    }),
                ),
                (
                    "response field became optional",
                    mutation(|s| {
                        s["definitions"]["Turn"]["required"]
                            .as_array_mut()
                            .unwrap()
                            .retain(|field| field != "id");
                    }),
                ),
                (
                    "response field type changed",
                    mutation(|s| {
                        s["definitions"]["Thread"]["properties"]["id"] = json!({"type":"integer"});
                    }),
                ),
                (
                    "response label removed",
                    mutation(|s| {
                        s["definitions"]["PlanType"]["enum"]
                            .as_array_mut()
                            .unwrap()
                            .remove(0);
                    }),
                ),
                (
                    "final answer phase replaced",
                    mutation(|s| {
                        variants(s, "MessagePhase")
                            .retain(|variant| variant["enum"] != json!(["final_answer"]));
                    }),
                ),
                (
                    "consumed notification params changed",
                    mutation(|s| {
                        s["definitions"]["AgentMessageDeltaNotification"]["properties"]["delta"] =
                            json!({"type":"integer"});
                    }),
                ),
                (
                    "thread item type removed",
                    mutation(|s| {
                        variants(s, "ThreadItem").retain(|variant| {
                            variant["properties"]["type"]["enum"][0] != "agentMessage"
                        });
                    }),
                ),
                (
                    "duplicate method",
                    mutation(|s| {
                        let request = methods_mut(s, "ClientRequest")[0].clone();
                        methods_mut(s, "ClientRequest").push(request);
                    }),
                ),
            ],
            false,
        );
    }

    #[test]
    fn cursor_widening_keeps_opaque_strings_and_constraints_visible() {
        let widen = |schema: &mut Value| {
            schema["definitions"]["ThreadItemsListParams"]["properties"]["cursor"] =
                json!({"anyOf":[{"$ref":"#/definitions/ThreadItemsListCursor"},{"type":"null"}]});
            schema["definitions"]["ThreadItemsListCursor"] =
                json!({"anyOf":[{"type":"string"},{"type":"object"}]});
        };
        assert_cases(
            baseline,
            vec![
                (
                    "cursor constraint",
                    mutation(move |s| {
                        widen(s);
                        s["definitions"]["ThreadItemsListParams"]["properties"]["cursor"]
                            ["maxLength"] = json!(1);
                    }),
                ),
                (
                    "referenced cursor constraint",
                    mutation(move |s| {
                        widen(s);
                        s["definitions"]["ThreadItemsListCursor"]["maxLength"] = json!(1);
                    }),
                ),
                (
                    "cursor no longer a string",
                    mutation(move |s| {
                        widen(s);
                        s["definitions"]["ThreadItemsListCursor"]["anyOf"][0] =
                            json!({"type":"integer"});
                    }),
                ),
            ],
            false,
        );
    }

    const V162_STABLE: &[u8] = include_bytes!(
        "../../../research/codex-app-server/0.162.0-alpha.2/stable/codex_app_server_protocol.v2.schemas.json"
    );
    const V162_EXPERIMENTAL: &[u8] = include_bytes!(
        "../../../research/codex-app-server/0.162.0-alpha.2/experimental/codex_app_server_protocol.v2.schemas.json"
    );
    const V162_17_STABLE: &[u8] = include_bytes!(
        "../../../research/codex-app-server/0.162.0-alpha.17.2/stable/codex_app_server_protocol.v2.schemas.json"
    );
    const V162_17_EXPERIMENTAL: &[u8] = include_bytes!(
        "../../../research/codex-app-server/0.162.0-alpha.17.2/experimental/codex_app_server_protocol.v2.schemas.json"
    );

    fn v162_17() -> (Value, Value) {
        (
            serde_json::from_slice(V162_17_STABLE).unwrap(),
            serde_json::from_slice(V162_17_EXPERIMENTAL).unwrap(),
        )
    }

    #[test]
    fn every_shipped_codex_passes_without_the_hash_shortcut() {
        // Regressions: 0.162 regrouped CodexErrorInfo as anyOf ("oneOf
        // missing"); 0.162.0-alpha.17 added MessagePhase "partial_answer"
        // ("changed variants"). Each broke Codex for every user until a
        // Wonder release.
        assert_eq!(verify(V162_STABLE, V162_EXPERIMENTAL), Ok(()));
        assert_eq!(verify(V162_17_STABLE, V162_17_EXPERIMENTAL), Ok(()));
    }

    #[test]
    fn later_runtimes_are_judged_by_the_same_rules() {
        assert_cases(
            v162_17,
            vec![
                (
                    "another new phase label",
                    mutation(|s| {
                        variants(s, "MessagePhase")
                            .push(json!({"enum":["draft"], "type":"string"}));
                    }),
                ),
                (
                    "capability removed from a method Wonder never calls",
                    mutation(|s| {
                        let response =
                            &mut s["definitions"]["ModelProviderCapabilitiesReadResponse"];
                        response["properties"]
                            .as_object_mut()
                            .unwrap()
                            .remove("webSearch");
                        response["required"] = json!(["imageGeneration"]);
                    }),
                ),
            ],
            true,
        );
        assert_cases(
            v162_17,
            vec![
                (
                    "final answer phase replaced",
                    mutation(|s| {
                        variants(s, "MessagePhase")
                            .retain(|variant| variant["enum"] != json!(["final_answer"]));
                    }),
                ),
                (
                    "permissions retyped",
                    mutation(|s| {
                        s["definitions"]["ThreadStartParams"]["properties"]["permissions"]
                            ["type"] = json!("object");
                    }),
                ),
                (
                    "permissions removed",
                    mutation(|s| {
                        s["definitions"]["ThreadStartParams"]["properties"]
                            .as_object_mut()
                            .unwrap()
                            .remove("permissions");
                    }),
                ),
                (
                    "approval policy label added",
                    mutation(|s| {
                        variants(s, "AskForApproval")[0]["enum"]
                            .as_array_mut()
                            .unwrap()
                            .push(json!("future-auto-approve"));
                    }),
                ),
                (
                    "existing error variant removed",
                    mutation(|s| {
                        variants(s, "CodexErrorInfo").remove(1);
                    }),
                ),
            ],
            false,
        );
    }
}
