//! Native provider tools control the desktop. Wonder's capture helper serves
//! the phone's live viewer; it is not an agent tool implementation.
use super::*;

pub(super) const VERSION: &str = "native-computer-use-v2";

pub(super) fn registration_version(saved: &str) -> String {
    if saved.starts_with(VERSION) {
        return saved.to_owned();
    }
    let mut parts = saved
        .split('+')
        .filter(|v| {
            !v.starts_with("native-computer-use-")
                && !matches!(
                    *v,
                    "wonder-computer-use-v1"
                        | "wonder-computer-use-v2"
                        | "wonder-no-dynamic-tools-v1"
                )
        })
        .collect::<Vec<_>>();
    if !parts.iter().any(|v| v.starts_with("wonder-project-tools-")) {
        parts.insert(0, "wonder-no-dynamic-tools-v1");
    }
    format!("{VERSION}+{}", parts.join("+"))
}

pub(super) async fn configure(
    state: &AppState,
    conversation: &str,
    bot: &StoredBot,
    params: &mut serde_json::Value,
) -> Result<(), String> {
    let enabled = state.computer_use_enabled
        && group_collaboration::allows_computer(state, conversation, &bot.id).await?;
    let policy = if enabled {
        "Use the native cua_repl tools for computer use. These tools run the installed Codex Computer Use engine, including when the Bot uses a Claude model."
    } else {
        "Computer use is unavailable for this work."
    };
    let instructions = params["developerInstructions"].as_str().unwrap_or_default();
    params["developerInstructions"] = serde_json::json!(format!("{instructions}\n\n{policy} The old wonder_computer_use tool is retired; do not call it, even if it appears in older conversation metadata. If native computer tools are unavailable or return an error, report that accurately. Never claim a rejected action succeeded or substitute another computer-control implementation."));
    if !params["config"].is_object() {
        params["config"] = serde_json::json!({});
    }
    // App-managed plugins are not necessarily discovered by a standalone
    // app-server, even when their files and the owner's config are shared.
    // Reuse the installed provider manifest, including its matching runtime
    // paths and environment, instead of copying a desktop implementation.
    let home = state.launch_config.lock().await.runtime_home.clone();
    let server = if enabled {
        match home {
            Some(home) => installed_cua(&home).await?,
            None => None,
        }
    } else {
        None
    };
    params["config"]["mcp_servers.cua_repl"] =
        server.unwrap_or_else(|| serde_json::json!({"command":"/usr/bin/true", "enabled":false}));
    Ok(())
}

async fn installed_cua(home: &FsPath) -> Result<Option<serde_json::Value>, String> {
    let root = home.join("plugins/cache/openai-bundled/unified-computer-use");
    let mut entries = match tokio::fs::read_dir(root).await {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("Codex Computer Use could not be loaded: {error}")),
    };
    let mut versions = Vec::new();
    while let Some(entry) = entries.next_entry().await.map_err(|e| e.to_string())? {
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Ok(version) = name
            .split('.')
            .map(str::parse::<u64>)
            .collect::<Result<Vec<_>, _>>()
        {
            versions.push((version, entry.path()));
        }
    }
    versions.sort_by(|a, b| b.0.cmp(&a.0));
    let Some((_, path)) = versions.first() else {
        return Ok(None);
    };
    let manifest = tokio::fs::read(path.join(".mcp.json"))
        .await
        .map_err(|e| e.to_string())?;
    let manifest: serde_json::Value =
        serde_json::from_slice(&manifest).map_err(|e| e.to_string())?;
    let mut server = manifest
        .pointer("/mcpServers/cua_repl")
        .filter(|v| v.is_object())
        .cloned()
        .ok_or("The installed Codex Computer Use manifest is incompatible.")?;
    server["enabled"] = serde_json::json!(true);
    Ok(Some(server))
}

pub(super) fn turn_ended(state: &AppState, params: &serde_json::Value) {
    let (Some(thread), Some(turn), Some(runtime)) = (
        params.get("threadId").and_then(serde_json::Value::as_str),
        params
            .pointer("/turn/id")
            .or_else(|| params.get("turnId"))
            .and_then(serde_json::Value::as_str),
        params
            .get("_wonderRuntimeId")
            .and_then(serde_json::Value::as_str),
    ) else {
        return;
    };
    let (thread, turn, runtime) = (thread.to_owned(), turn.to_owned(), runtime.to_owned());
    let state = state.clone();
    // Reuse the native plugin's Stop hook. Do not block durable ingestion or
    // touch a replacement runtime if the daemon restarted during completion.
    tokio::spawn(async move {
        let rpc = state.app_server.lock().await.rpc();
        if rpc.health().id() != runtime {
            return;
        }
        let result = rpc
            .request(
                "mcpServer/tool/call",
                serde_json::json!({
                    "threadId": thread, "server":"cua_repl", "tool":"turn_ended",
                    "arguments":{"hook_event_name":"Stop", "session_id":thread, "turn_id":turn}
                }),
            )
            .await;
        // An unavailable server has no native session to release. The helper
        // itself handles idempotency for repeated terminal notifications.
        if let Err(error) = result {
            let _ = state.logger.record(
                "warn",
                "native_computer_cleanup_failed",
                serde_json::json!({"detail":error.to_string()}),
            );
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    // The runtime request owns this contract: a Bot gets the provider server,
    // without depending on or registering Wonder's old input helper.
    #[tokio::test]
    async fn bot_start_registers_native_runtime_without_legacy_helper() {
        let (dir, mut state) = ingestion::tests::fixture().await;
        let home = dir.path().join("codex-home");
        let plugin = home.join("plugins/cache/openai-bundled/unified-computer-use/26.10.1");
        tokio::fs::create_dir_all(&plugin).await.unwrap();
        tokio::fs::write(
            plugin.join(".mcp.json"),
            serde_json::json!({
                "mcpServers":{"cua_repl":{"command":"/provider/node","args":["/provider/cua.mjs"]}}
            })
            .to_string(),
        )
        .await
        .unwrap();
        state.launch_config.lock().await.runtime_home = Some(home);
        state.computer_use_enabled = true;
        state.computer_use_bin = None;
        let bot = state.store.bot("bot").await.unwrap().unwrap();
        let (settings, _) = effective_settings(&RuntimeCatalog::default(), &bot, None);
        start_bot_thread(
            &state,
            &mut *state.app_server.lock().await,
            "bot",
            &bot,
            &settings,
        )
        .await
        .unwrap();
        let requests = tokio::fs::read_to_string(dir.path().join("requests-jsonl"))
            .await
            .unwrap();
        let request = requests
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .find(|value| value["method"] == "thread/start")
            .unwrap();
        let params = &request["params"];
        assert_eq!(
            params["config"]["mcp_servers.cua_repl"]["command"],
            "/provider/node"
        );
        assert_eq!(params["config"]["mcp_servers.cua_repl"]["enabled"], true);
        assert!(params["dynamicTools"]
            .as_array()
            .unwrap()
            .iter()
            .all(|tool| tool["name"] != computer_tools::TOOL));
        let mut claude = bot.clone();
        claude.agent_family = AgentFamily::Claude;
        let mut params = serde_json::json!({});
        configure(&state, "bot", &claude, &mut params)
            .await
            .unwrap();
        assert_eq!(
            params["config"]["mcp_servers.cua_repl"]["command"],
            "/provider/node"
        );
        assert_eq!(params["config"]["mcp_servers.cua_repl"]["enabled"], true);
        state.computer_use_enabled = false;
        configure(&state, "bot", &claude, &mut params)
            .await
            .unwrap();
        assert_eq!(params["config"]["mcp_servers.cua_repl"]["enabled"], false);
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn native_manifest_preserves_provider_runtime_and_uses_newest_version() {
        let dir = tempfile::tempdir().unwrap();
        assert!(installed_cua(dir.path()).await.unwrap().is_none());
        for version in ["26.9.9", "26.10.1"] {
            let root = dir
                .path()
                .join("plugins/cache/openai-bundled/unified-computer-use")
                .join(version);
            tokio::fs::create_dir_all(&root).await.unwrap();
            let server = serde_json::json!({"command":"/provider/node", "args":[version], "env":{"CODEX_HOME":"/provider/home"}, "enabled":true});
            tokio::fs::write(
                root.join(".mcp.json"),
                serde_json::json!({"mcpServers":{"cua_repl":server}}).to_string(),
            )
            .await
            .unwrap();
        }
        let server = installed_cua(dir.path()).await.unwrap().unwrap();
        assert_eq!(server["args"], serde_json::json!(["26.10.1"]));
        assert_eq!(server["env"]["CODEX_HOME"], "/provider/home");
    }

    #[test]
    fn retiring_legacy_computer_registration_keeps_unrelated_migration_versions() {
        assert_eq!(
            registration_version("native-computer-use-v1+wonder-project-tools-v2"),
            format!("{VERSION}+wonder-project-tools-v2")
        );
        assert_eq!(
            registration_version("wonder-computer-use-v2+wonder-bot-profile-v5"),
            format!("{VERSION}+wonder-no-dynamic-tools-v1+wonder-bot-profile-v5")
        );
        assert_eq!(
            registration_version(
                "wonder-computer-use-v1+wonder-project-tools-v2+wonder-bot-profile-v3"
            ),
            format!("{VERSION}+wonder-project-tools-v2+wonder-bot-profile-v3")
        );
    }
}
