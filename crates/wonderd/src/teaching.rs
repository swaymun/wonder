//! What remains of the retired Teach a task feature: taught skills saved by
//! earlier versions stay disabled in new Bot sessions, and a capture that was
//! recording when the feature was turned off is interrupted.

use crate::AppState;
use chrono::{SecondsFormat, Utc};
use serde_json::Value;
use std::{
    fs,
    path::{Component, Path as FsPath, PathBuf},
};

const BETA_UNAVAILABLE: &str = "Teach a task is unavailable in this beta.";
pub(crate) const BETA_POLICY: &str = "Wonder's Teach a task capture and taught-skill replay are unavailable in this beta. Do not offer teaching, run saved Wonder-taught skills, or recreate their capture/replay flow with another tool. Ordinary Codex skills and helping with the user's task directly remain available.";

/// Teaching is retired, so input is never captured. A legacy session still
/// recording on this lease is interrupted rather than left waiting.
pub(crate) async fn interrupt_capture(state: &AppState, lease: &str) -> Result<(), sqlx::Error> {
    state
        .store
        .interrupt_teaching_for_lease(
            lease,
            BETA_UNAVAILABLE,
            &Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        )
        .await?;
    Ok(())
}

pub(crate) async fn disabled_skill_paths(
    state: &AppState,
) -> Result<std::collections::BTreeSet<PathBuf>, String> {
    let mut paths = std::collections::BTreeSet::new();
    for (root, relative) in state
        .store
        .teaching_skill_paths()
        .await
        .map_err(|_| BETA_UNAVAILABLE)?
    {
        let relative = FsPath::new(&relative);
        if !FsPath::new(&root).is_absolute()
            || !relative.starts_with(".agents/skills")
            || relative.file_name().is_none_or(|name| name != "SKILL.md")
            || relative.components().count() < 4
            || relative
                .components()
                .any(|part| !matches!(part, Component::Normal(_)))
        {
            return Err("Saved teaching skill paths could not be checked.".into());
        }
        let path = FsPath::new(&root).join(relative);
        if let Ok(canonical) = fs::canonicalize(&path) {
            paths.insert(canonical);
        }
        paths.insert(path);
    }
    Ok(paths)
}

fn disabled_skill_config(
    config: &Value,
    paths: &std::collections::BTreeSet<PathBuf>,
) -> Result<Value, String> {
    let mut entries = match config.pointer("/skills/config") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(entries)) => entries.clone(),
        _ => return Err("Existing skill settings could not be preserved.".into()),
    };
    for path in paths {
        // Accept both selectors documented by Codex: SKILL.md and its folder.
        for selector in [path.as_path(), path.parent().ok_or(BETA_UNAVAILABLE)?] {
            for entry in &mut entries {
                if entry["path"]
                    .as_str()
                    .is_some_and(|value| FsPath::new(value) == selector)
                {
                    entry["enabled"] = Value::Bool(false);
                }
            }
            if !entries.iter().any(|entry| {
                entry["path"]
                    .as_str()
                    .is_some_and(|value| FsPath::new(value) == selector)
            }) {
                entries.push(serde_json::json!({"path":selector,"enabled":false}));
            }
        }
    }
    Ok(serde_json::json!({"skills.config":entries}))
}

pub(crate) async fn runtime_config(
    state: &AppState,
    rpc: &wonder_app_server::RpcClient,
    cwd: &str,
) -> Result<Value, String> {
    let paths = disabled_skill_paths(state).await?;
    if paths.is_empty() {
        return Ok(Value::Null);
    }
    if !FsPath::new(cwd).is_absolute() {
        return Err("The skill settings workspace could not be checked.".into());
    }
    // Read effective settings instead of replacing the owner's ordinary skill
    // preferences. These overrides are session-local; no config or skill is written.
    let response = rpc
        .request(
            "config/read",
            serde_json::json!({"cwd":cwd,"includeLayers":false}),
        )
        .await
        .map_err(|_| "Skill settings could not be checked before starting work.")?;
    if response.error.is_some() {
        return Err("Skill settings could not be checked before starting work.".into());
    }
    let config = response
        .result
        .as_ref()
        .and_then(|result| result.get("config"))
        .filter(|config| config.is_object())
        .ok_or("Skill settings could not be checked before starting work.")?;
    disabled_skill_config(config, &paths)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::permission_modes::tests::{call, fixture};
    use axum::http::StatusCode;
    use chrono::Duration as ChronoDuration;
    use serde_json::json;
    use wonder_store::{TeachingReview, TeachingSessionCreate};

    async fn legacy_session(
        state: &AppState,
        id: &str,
        status: &str,
    ) -> wonder_store::StoredTeachingSession {
        state
            .store
            .insert_teaching_session(&TeachingSessionCreate {
                id: id.into(),
                client_request_id: id.into(),
                owner_device_id: "wonder-desktop".into(),
                host_installation_id: state.host_installation_id.clone(),
                bot_id: "bot".into(),
                conversation_id: "bot:bot".into(),
                computer_session_id: Some("computer".into()),
                control_lease_id: Some("lease".into()),
                state: status.into(),
                capture_scope: "authenticated-remote-control".into(),
                capture_provider: "authenticated-remote-control-v1".into(),
                outcome: "Save a synthetic preview".into(),
                failure_reason: None,
                now: Utc::now().to_rfc3339(),
                expires_at: Some((Utc::now() + ChronoDuration::minutes(10)).to_rfc3339()),
            })
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn retired_capture_interrupts_a_legacy_recording_session() {
        let (_dir, state) = fixture().await;
        state
            .store
            .ensure_bot_workspace("bot", "Bot", "now")
            .await
            .unwrap();
        let session = legacy_session(&state, "legacy", "recording").await;
        for _ in 0..2 {
            interrupt_capture(&state, "lease").await.unwrap();
        }
        let read = state
            .store
            .teaching_session(&session.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(read.state, "interrupted");
        assert_eq!(read.failure_reason.as_deref(), Some(BETA_UNAVAILABLE));
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn beta_excludes_saved_teaching_skills_without_changing_ordinary_skills_or_files() {
        let (dir, state) = fixture().await;
        let conversation = state
            .store
            .ensure_bot_workspace("bot", "Bot", "now")
            .await
            .unwrap();
        let session = legacy_session(&state, "saved", "reviewing").await;
        let drafted = state
            .store
            .review_teaching_session(
                &session.id,
                "wonder-desktop",
                &TeachingReview {
                    expected_revision: session.revision,
                    name: "Preview".into(),
                    description: "Create a preview".into(),
                    goal: "Save".into(),
                    input_schema_json: "{}".into(),
                    prerequisites: "None".into(),
                    steps: "Save".into(),
                    result_checks: "Exists".into(),
                    content_hash: "hash".into(),
                    now: Utc::now().to_rfc3339(),
                },
            )
            .await
            .unwrap()
            .unwrap();
        state
            .store
            .reserve_bot_skill_version(
                "bot",
                &drafted,
                "skill",
                "preview",
                ".agents/skills/preview/SKILL.md",
                ".agents/skills/.wonder-versions/skill/1/SKILL.md",
                "save",
                "now",
            )
            .await
            .unwrap();
        let bot = state.store.bot("bot").await.unwrap().unwrap();
        let taught = FsPath::new(&bot.workspace_path).join(".agents/skills/preview/SKILL.md");
        let ordinary = FsPath::new(&bot.workspace_path).join(".agents/skills/ordinary/SKILL.md");
        for path in [&taught, &ordinary] {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "unchanged synthetic skill").unwrap();
        }
        let original = json!({"skills":{"config":[{"path":ordinary,"enabled":false},{"name":"explicitly-enabled","enabled":true},{"path":taught,"enabled":true}]}});
        fs::write(
            dir.path().join("skill-config.json"),
            json!({"config":original}).to_string(),
        )
        .unwrap();
        fs::write(
            dir.path().join("skill-list.json"),
            json!({"data":[{"skills":[
                {"name":"Preview","path":taught,"enabled":true},
                {"name":"Ordinary","path":ordinary,"enabled":true}
            ]}]})
            .to_string(),
        )
        .unwrap();
        let script = dir.path().join("runtime.py");
        let source = fs::read_to_string(&script).unwrap().replace("    elif method == 'thread/start':", "    elif method == 'config/read': result = json.load(open(root + '/skill-config.json'))\n    elif method == 'skills/list': result = json.load(open(root + '/skill-list.json'))\n    elif method == 'thread/start':");
        fs::write(&script, source).unwrap();
        state
            .app_server
            .lock()
            .await
            .restart(state.launch_config.lock().await.clone())
            .await
            .unwrap();
        for index in 0..2 {
            let crate::MessageInsert::Inserted(message) = state
                .store
                .insert_message(
                    "owner",
                    &format!("skill-gate-{index}"),
                    "Help with this task",
                    "hash",
                    &conversation,
                    "now",
                )
                .await
                .unwrap()
            else {
                panic!("new message")
            };
            crate::dispatch_to_codex_inner(state.clone(), message.clone(), None, None).await;
            assert_eq!(
                state
                    .store
                    .message_by_id(&message.id)
                    .await
                    .unwrap()
                    .unwrap()
                    .state,
                "accepted_by_codex"
            );
            state
                .store
                .update_message_delivery(&message.id, "completed", None, None)
                .await
                .unwrap();
        }
        let (status, capabilities) =
            call(&state, "GET", "/api/v1/runtime/capabilities", json!({})).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(capabilities["skills"].as_array().unwrap().len(), 1);
        assert_eq!(capabilities["skills"][0]["name"], "Ordinary");
        state.app_server.lock().await.shutdown().await.unwrap();
        let requests: Vec<Value> = fs::read_to_string(dir.path().join("payloads"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let registrations: Vec<_> = requests
            .iter()
            .filter(|request| {
                matches!(
                    request["method"].as_str(),
                    Some("thread/start" | "thread/resume")
                )
            })
            .collect();
        assert_eq!(registrations.len(), 2);
        for request in registrations {
            let config = &request["params"]["config"]["skills.config"];
            assert_eq!(config[0], original["skills"]["config"][0]);
            assert_eq!(config[1], original["skills"]["config"][1]);
            assert_eq!(config[2]["enabled"], false);
            assert!(config.as_array().unwrap().iter().any(|entry| entry["path"]
                .as_str()
                .is_some_and(|path| path.ends_with(".wonder-versions/skill/1/SKILL.md"))
                && entry["enabled"] == false));
            assert!(request["params"]["developerInstructions"]
                .as_str()
                .unwrap()
                .contains(BETA_POLICY));
        }
        assert_eq!(
            fs::read_to_string(&taught).unwrap(),
            "unchanged synthetic skill"
        );
        assert_eq!(
            fs::read_to_string(&ordinary).unwrap(),
            "unchanged synthetic skill"
        );
        assert_eq!(
            state
                .store
                .bot_skill_versions("bot", "skill")
                .await
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            state
                .store
                .teaching_session(&session.id)
                .await
                .unwrap()
                .unwrap(),
            drafted
        );
        assert!(disabled_skill_config(
            &json!({"skills":{"config":"malformed"}}),
            &disabled_skill_paths(&state).await.unwrap()
        )
        .is_err());
    }
}
