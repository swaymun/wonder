//! Narrow typed boundary for the supported Codex App Server JSONL protocol.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

mod process;
mod schema_compat;

pub use process::verify_runtime;
pub use process::{
    build_permission_override, permission_filesystem, AppServerClient, LaunchConfig,
    NotificationSink, RpcClient, RuntimeError, RuntimeHealth,
};

pub const CODEX_VERSION: &str = "codex-cli 0.155.0-alpha.9";
// Known versions retain a fast exact-hash path. Later versions are checked
// against the embedded protocol contract instead of requiring a Wonder update.
pub const COMPATIBLE_CODEX_VERSIONS: [&str; 4] = [
    CODEX_VERSION,
    "codex-cli 0.155.0-alpha.9.2",
    "codex-cli 0.155.0-alpha.16.3",
    "codex-cli 0.155.0-alpha.16.4",
];
pub const STABLE_SCHEMA_SHA256: &str =
    "5a4d50ed04afa9cd1b383d011f67ec055960a35ca7fdeab222ed65e70fca8f0b";
pub const EXPERIMENTAL_SCHEMA_SHA256: &str =
    "48368bf71d00498557245665dd4581f9b0d5381561a2c8ba1ef4eb26ea4a1632";
pub const ALPHA16_STABLE_SCHEMA_SHA256: &str =
    "6ca35a4c82645df5cba7b2bba1845d3167c12294317daf1923da1a2e8fa04738";
pub const ALPHA16_EXPERIMENTAL_SCHEMA_SHA256: &str =
    "c7291ce922a7e7f5fe5e36902544bbc18b793d6f5a998ef36aeff0b195b0e91d";

pub fn expected_schema_hashes(version: &str) -> Option<(&'static str, &'static str)> {
    match version {
        CODEX_VERSION | "codex-cli 0.155.0-alpha.9.2" => {
            Some((STABLE_SCHEMA_SHA256, EXPERIMENTAL_SCHEMA_SHA256))
        }
        "codex-cli 0.155.0-alpha.16.3" | "codex-cli 0.155.0-alpha.16.4" => Some((
            ALPHA16_STABLE_SCHEMA_SHA256,
            ALPHA16_EXPERIMENTAL_SCHEMA_SHA256,
        )),
        _ => None,
    }
}

pub const ALLOWED_SERVER_REQUESTS: [&str; 6] = [
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
    "item/tool/requestUserInput",
    "mcpServer/elicitation/request",
    "item/tool/call",
];

pub fn is_allowed_method(method: &str) -> bool {
    RequiredMethod::ALL
        .iter()
        .any(|candidate| candidate.as_str() == method)
}

pub fn is_allowed_server_request(method: &str) -> bool {
    ALLOWED_SERVER_REQUESTS.contains(&method)
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RpcRequest {
    pub method: String,
    pub id: Option<u64>,
    #[serde(default)]
    pub params: Value,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RpcResponse {
    pub id: u64,
    pub result: Option<Value>,
    pub error: Option<JsonRpcError>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    #[serde(default)]
    pub data: Option<Value>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RequiredMethod {
    Initialize,
    AccountRead,
    ModelList,
    RateLimitsRead,
    AppList,
    AppsInstalled,
    AppsRead,
    ConfigRead,
    SkillsList,
    McpServerStatusList,
    ConfigRequirementsRead,
    PermissionProfileList,
    ThreadStart,
    ThreadResume,
    ThreadRead,
    ThreadList,
    ThreadUnarchive,
    ThreadTurnsList,
    ThreadItemsList,
    ThreadSettingsUpdate,
    ThreadGoalSet,
    ThreadGoalGet,
    ThreadGoalClear,
    TurnStart,
    TurnSteer,
    TurnInterrupt,
}

impl RequiredMethod {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Initialize => "initialize",
            Self::AccountRead => "account/read",
            Self::ModelList => "model/list",
            Self::RateLimitsRead => "account/rateLimits/read",
            Self::AppList => "app/list",
            Self::AppsInstalled => "app/installed",
            Self::AppsRead => "app/read",
            Self::ConfigRead => "config/read",
            Self::SkillsList => "skills/list",
            Self::McpServerStatusList => "mcpServerStatus/list",
            Self::ConfigRequirementsRead => "configRequirements/read",
            Self::PermissionProfileList => "permissionProfile/list",
            Self::ThreadStart => "thread/start",
            Self::ThreadResume => "thread/resume",
            Self::ThreadRead => "thread/read",
            Self::ThreadList => "thread/list",
            Self::ThreadUnarchive => "thread/unarchive",
            Self::ThreadTurnsList => "thread/turns/list",
            Self::ThreadItemsList => "thread/items/list",
            Self::ThreadSettingsUpdate => "thread/settings/update",
            Self::ThreadGoalSet => "thread/goal/set",
            Self::ThreadGoalGet => "thread/goal/get",
            Self::ThreadGoalClear => "thread/goal/clear",
            Self::TurnStart => "turn/start",
            Self::TurnSteer => "turn/steer",
            Self::TurnInterrupt => "turn/interrupt",
        }
    }

    pub const ALL: [Self; 26] = [
        Self::Initialize,
        Self::AccountRead,
        Self::ModelList,
        Self::RateLimitsRead,
        Self::AppList,
        Self::AppsInstalled,
        Self::AppsRead,
        Self::ConfigRead,
        Self::SkillsList,
        Self::McpServerStatusList,
        Self::ConfigRequirementsRead,
        Self::PermissionProfileList,
        Self::ThreadStart,
        Self::ThreadResume,
        Self::ThreadRead,
        Self::ThreadList,
        Self::ThreadUnarchive,
        Self::ThreadTurnsList,
        Self::ThreadItemsList,
        Self::ThreadSettingsUpdate,
        Self::ThreadGoalSet,
        Self::ThreadGoalGet,
        Self::ThreadGoalClear,
        Self::TurnStart,
        Self::TurnSteer,
        Self::TurnInterrupt,
    ];
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InitializeRequest {
    pub id: u64,
    pub request: RpcRequest,
}

pub fn initialize_request(wonder_version: &str) -> InitializeRequest {
    InitializeRequest {
        id: 1,
        request: RpcRequest {
            method: "initialize".into(),
            id: Some(1),
            params: json!({
                "clientInfo": {
                    "name": "wonder",
                    "title": "Wonder",
                    "version": wonder_version
                },
                "capabilities": {
                    "experimentalApi": true,
                    "requestAttestation": false,
                    "optOutNotificationMethods": []
                }
            }),
        },
    }
}

pub fn validate_permission_request(params: &Value) -> Result<(), &'static str> {
    let object = params
        .as_object()
        .ok_or("request params must be an object")?;
    if object.contains_key("permissions")
        && (object.contains_key("sandbox") || object.contains_key("sandboxPolicy"))
    {
        return Err("permissions cannot be combined with legacy sandbox fields");
    }
    Ok(())
}

pub fn require_experimental_api(result: &Value) -> Result<(), &'static str> {
    // `experimentalApi` is a client-declared initialize capability in the
    // 0.153.0-alpha.5 schema. The live server acknowledges initialize with server
    // metadata and does not echo that client capability in its result.
    match result
        .get("capabilities")
        .and_then(Value::as_object)
        .and_then(|caps| caps.get("experimentalApi"))
    {
        None | Some(Value::Bool(true)) => Ok(()),
        Some(_) => Err("Codex runtime incompatible: experimentalApi was declined"),
    }
}

pub fn require_named_profile(result: &Value, expected_name: &str) -> Result<(), &'static str> {
    let profiles = result
        .get("data")
        .and_then(Value::as_array)
        .ok_or("Codex runtime incompatible: permissionProfile/list returned no data")?;
    let profile = profiles
        .iter()
        .find(|profile| profile_identifier(profile) == Some(expected_name));
    let valid = profile.is_some_and(|profile| {
        profile.get("allowed").and_then(Value::as_bool) == Some(true)
            && profile_policy_is_safe(profile)
    });
    if valid {
        Ok(())
    } else {
        Err("Codex runtime incompatible: generated permission profile is absent or disallowed")
    }
}

pub fn require_named_profile_with_scope(
    result: &Value,
    expected_name: &str,
    writable_root: &str,
    denied_roots: &[&str],
) -> Result<(), &'static str> {
    require_named_profile(result, expected_name)?;
    let profiles = result
        .get("data")
        .and_then(Value::as_array)
        .ok_or("Codex runtime incompatible: permissionProfile/list returned no data")?;
    let profile = profiles
        .iter()
        .find(|profile| profile_identifier(profile) == Some(expected_name))
        .ok_or("Codex runtime incompatible: generated permission profile is absent")?;
    if let Some(filesystem) = profile.get("filesystem").and_then(Value::as_object) {
        if filesystem.get(writable_root).and_then(Value::as_str) != Some("write") {
            return Err("Codex runtime incompatible: Bot home is not write-scoped");
        }
        if denied_roots
            .iter()
            .any(|root| filesystem.get(*root).and_then(Value::as_str) != Some("deny"))
        {
            return Err("Codex runtime incompatible: sensitive roots are not denied");
        }
    }
    Ok(())
}

fn profile_identifier(profile: &Value) -> Option<&str> {
    profile
        .get("name")
        .or_else(|| profile.get("id"))
        .and_then(Value::as_str)
}

fn profile_policy_is_safe(profile: &Value) -> bool {
    let Some(filesystem) = profile.get("filesystem") else {
        // Codex 0.153.0-alpha.5's permissionProfile/list only returns id/allowed for
        // generated profiles. The override is constructed and checked by
        // Wonder before launch, so absence here is not evidence of a broader
        // policy.
        return true;
    };
    filesystem
        .as_object()
        .and_then(|filesystem| filesystem.get(":minimal"))
        .and_then(Value::as_str)
        == Some("read")
        && profile
            .get("network")
            .and_then(Value::as_object)
            .and_then(|network| network.get("enabled"))
            .and_then(Value::as_bool)
            == Some(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pinned_runtime_metadata_matches_generated_schema_fixtures() {
        use sha2::{Digest, Sha256};
        let manifest: Value =
            serde_json::from_str(include_str!("../../../compatibility-manifest.json")).unwrap();
        assert_eq!(manifest["codex"]["version"], CODEX_VERSION);
        assert_eq!(
            manifest["codex"]["compatibleVersions"],
            serde_json::json!(COMPATIBLE_CODEX_VERSIONS)
        );
        assert_eq!(
            manifest["codex"]["stableSchemaSha256"],
            STABLE_SCHEMA_SHA256
        );
        assert_eq!(
            manifest["codex"]["experimentalSchemaSha256"],
            EXPERIMENTAL_SCHEMA_SHA256
        );
        assert_eq!(
            manifest["codex"]["alpha16SchemaSha256"]["stable"],
            ALPHA16_STABLE_SCHEMA_SHA256
        );
        assert_eq!(
            manifest["codex"]["alpha16SchemaSha256"]["experimental"],
            ALPHA16_EXPERIMENTAL_SCHEMA_SHA256
        );
        assert_eq!(manifest["policy"]["allowUnknownVersions"], true);
        assert_eq!(
            manifest["policy"]["unknownVersionPolicy"],
            "local-additive-schema-check-against-0.155.0-alpha.16.3"
        );
        assert_eq!(
            expected_schema_hashes("codex-cli 0.155.0-alpha.16.4"),
            Some((
                ALPHA16_STABLE_SCHEMA_SHA256,
                ALPHA16_EXPERIMENTAL_SCHEMA_SHA256
            ))
        );
        for (schema, expected) in [
            (include_bytes!("../../../research/codex-app-server/0.155.0-alpha.9/stable/codex_app_server_protocol.v2.schemas.json").as_slice(), STABLE_SCHEMA_SHA256),
            (include_bytes!("../../../research/codex-app-server/0.155.0-alpha.9/experimental/codex_app_server_protocol.v2.schemas.json").as_slice(), EXPERIMENTAL_SCHEMA_SHA256),
            (include_bytes!("../../../research/codex-app-server/0.155.0-alpha.16.3/stable/codex_app_server_protocol.v2.schemas.json").as_slice(), ALPHA16_STABLE_SCHEMA_SHA256),
            (include_bytes!("../../../research/codex-app-server/0.155.0-alpha.16.3/experimental/codex_app_server_protocol.v2.schemas.json").as_slice(), ALPHA16_EXPERIMENTAL_SCHEMA_SHA256),
        ] {
            assert_eq!(hex::encode(Sha256::digest(schema)), expected);
        }
    }

    #[test]
    fn pinned_schema_retains_required_methods_and_named_permission_boundary() {
        for (schema, server_requests) in [
            (include_str!("../../../research/codex-app-server/0.155.0-alpha.9/experimental/codex_app_server_protocol.v2.schemas.json"), include_str!("../../../research/codex-app-server/0.155.0-alpha.9/experimental/ServerRequest.ts")),
            (include_str!("../../../research/codex-app-server/0.155.0-alpha.16.3/experimental/codex_app_server_protocol.v2.schemas.json"), include_str!("../../../research/codex-app-server/0.155.0-alpha.16.3/experimental/ServerRequest.ts")),
        ] {
        let schema: Value = serde_json::from_str(schema).unwrap();
        let definitions = &schema["definitions"];
        let requests = definitions["ClientRequest"]["oneOf"].as_array().unwrap();
        for method in RequiredMethod::ALL {
            assert!(
                requests
                    .iter()
                    .any(|request| request["properties"]["method"]["enum"][0] == method.as_str()),
                "missing {}",
                method.as_str()
            );
        }
        for method in ALLOWED_SERVER_REQUESTS {
            assert!(
                server_requests.contains(&format!("\"{method}\"")),
                "missing {method}"
            );
        }
        for request in ["ThreadStartParams", "ThreadResumeParams", "TurnStartParams"] {
            assert_eq!(
                definitions[request]["properties"]["permissions"]["type"],
                json!(["string", "null"])
            );
        }
        assert_eq!(
            definitions["TurnStartParams"]["properties"]["clientUserMessageId"]["type"],
            json!(["string", "null"])
        );
        let image = definitions["UserInput"]["oneOf"]
            .as_array()
            .unwrap()
            .iter()
            .find(|input| input["properties"]["type"]["enum"][0] == "image")
            .unwrap();
        assert!(image["anyOf"]
            .as_array()
            .unwrap()
            .iter()
            .any(|variant| variant["required"] == json!(["url"])));
        }
        // Newly advertised capabilities are not automatically authorized.
        for method in [
            "thread/attachment/add",
            "thread/attachment/remove",
            "memory/status",
            "userVerification/cancel",
        ] {
            assert!(!is_allowed_method(method));
        }
    }

    #[test]
    fn initialize_is_exactly_one_experimental_handshake() {
        let request = initialize_request("0.1.0").request;
        assert_eq!(request.method, "initialize");
        assert_eq!(request.id, Some(1));
        assert_eq!(request.params["capabilities"]["experimentalApi"], true);
        assert!(
            require_experimental_api(&json!({"userAgent":"Codex Desktop/0.153.0-alpha.5"})).is_ok()
        );
        assert!(
            require_experimental_api(&json!({"capabilities":{"experimentalApi":false}})).is_err()
        );
    }

    #[test]
    fn legacy_sandbox_composition_fails_closed() {
        let params = json!({ "permissions": "wonder_bot_1", "sandboxPolicy": {} });
        assert_eq!(
            validate_permission_request(&params),
            Err("permissions cannot be combined with legacy sandbox fields")
        );
    }

    #[test]
    fn unrestricted_remote_filesystem_is_not_in_the_allowlist() {
        assert!(!is_allowed_method("fs/readFile"));
        assert!(is_allowed_method("thread/start"));
        assert!(is_allowed_method("app/list"));
        assert!(is_allowed_method("skills/list"));
        assert!(is_allowed_method("mcpServerStatus/list"));
        assert!(is_allowed_server_request("item/fileChange/requestApproval"));
        assert!(!is_allowed_server_request("execCommandApproval"));
    }

    #[test]
    fn subagent_discovery_and_reopen_methods_are_explicitly_allowlisted() {
        assert!(is_allowed_method("thread/list"));
        assert!(is_allowed_method("thread/read"));
        assert!(is_allowed_method("thread/unarchive"));
        assert!(is_allowed_method("thread/resume"));
        assert!(is_allowed_method("thread/goal/get"));
        assert!(is_allowed_method("thread/goal/set"));
        assert!(is_allowed_method("thread/goal/clear"));
        assert!(!is_allowed_method("thread/fork"));
    }

    #[test]
    fn missing_or_disallowed_profile_fails_closed() {
        let result = json!({ "data": [{ "name": "other", "allowed": true }] });
        assert_eq!(
            require_named_profile(&result, "wonder_bot_1"),
            Err("Codex runtime incompatible: generated permission profile is absent or disallowed")
        );
    }

    #[test]
    fn unknown_fields_are_accepted() {
        let request: RpcRequest = serde_json::from_value(json!({
            "method": "account/read",
            "id": 2,
            "params": {},
            "futureField": "ignored-by-the-typed-subset"
        }))
        .expect("unknown fields should not break the adapter");
        assert_eq!(request.method, "account/read");
    }
}
