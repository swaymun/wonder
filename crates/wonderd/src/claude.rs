//! Claude's owned process and provider routing. Session bindings, never model
//! output or a guessed thread prefix, decide which transport receives a request.
use crate::{ingestion, AppState, RuntimeCatalog};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::sync::Mutex;
use wonder_app_server::{AppServerClient, BridgeLaunchConfig, RpcClient};
use wonder_store::{AgentFamily, Store, StoredBot};

pub struct Runtime {
    pub client: Arc<Mutex<AppServerClient>>,
    pub config: BridgeLaunchConfig,
}
impl Runtime {
    pub fn configured(data: &Path, store: &Store) -> Option<Arc<Self>> {
        let resources = std::env::current_exe()
            .ok()?
            .parent()?
            .parent()?
            .join("Resources");
        let entrypoint = std::env::var_os("WONDER_CLAUDE_BRIDGE")
            .map(PathBuf::from)
            .unwrap_or_else(|| resources.join("claude-runtime/main.mjs"));
        if !entrypoint.is_file() {
            return None;
        }
        let node_bin = std::env::var_os("WONDER_NODE_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| resources.join("node/bin/node"));
        let npm_cli = std::env::var_os("WONDER_NPM_CLI")
            .map(PathBuf::from)
            .or_else(|| {
                Some(resources.join("node/lib/node_modules/npm/bin/npm-cli.js"))
                    .filter(|p| p.is_file())
            });
        Some(Arc::new(Self {
            client: Arc::new(Mutex::new(AppServerClient::unavailable(
                env!("CARGO_PKG_VERSION").into(),
                ingestion::notification_sink(store.clone()),
            ))),
            config: BridgeLaunchConfig {
                node_bin,
                entrypoint,
                npm_cli,
                state_dir: data.join("claude-runtime"),
                wonder_version: env!("CARGO_PKG_VERSION").into(),
            },
        }))
    }
}

pub(crate) fn client(
    state: &AppState,
    family: AgentFamily,
) -> Result<Arc<Mutex<AppServerClient>>, String> {
    match family {
        AgentFamily::Codex => Ok(state.app_server.clone()),
        AgentFamily::Claude => state
            .claude
            .as_ref()
            .map(|r| r.client.clone())
            .ok_or_else(|| "Claude is not installed. Update Wonder on your Mac.".into()),
    }
}

pub(crate) async fn for_thread(state: &AppState, thread: &str) -> Result<RpcClient, String> {
    let family = state
        .store
        .runtime_family_for_thread(thread)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("The conversation has no runtime binding. Reopen it and try again.")?;
    Ok(client(state, family)?.lock().await.rpc())
}

pub(crate) async fn conversation_family(state: &AppState, id: &str) -> Result<AgentFamily, String> {
    if let Some(binding) = state
        .store
        .runtime_binding(id)
        .await
        .map_err(|e| e.to_string())?
    {
        return Ok(binding.family);
    }
    if let Some(group) = state
        .store
        .group_id_for_conversation(id)
        .await
        .map_err(|e| e.to_string())?
    {
        return crate::group_collaboration::family(state, &group).await;
    }
    if let Some(bot) = crate::bot_for_conversation(state, id)
        .await
        .map_err(|e| e.to_string())?
    {
        return Ok(bot.agent_family);
    }
    Err("The conversation could not be found.".into())
}

pub(crate) async fn discover(
    state: &AppState,
    runtime: &mut AppServerClient,
) -> Result<(), String> {
    let account = runtime
        .request("account/read", json!({"refresh":true}))
        .await
        .map_err(|e| e.to_string())?
        .result
        .ok_or("Claude could not check your subscription. Sign in on your Mac.")?;
    if account["connected"] != true {
        return Err("Sign in to your Claude subscription on your Mac.".into());
    }
    let models = runtime
        .request("model/list", json!({}))
        .await
        .map_err(|e| e.to_string())?
        .result
        .ok_or("Claude models are temporarily unavailable.")?;
    let mut discovered = RuntimeCatalog::default();
    discovered.apply_models_page(&models);
    if discovered.models.is_empty()
        || discovered
            .models
            .iter()
            .any(|m| AgentFamily::for_model(Some(&m.id)) != AgentFamily::Claude)
    {
        return Err(
            "Claude returned an incompatible model list. Update Wonder on your Mac.".into(),
        );
    }
    let mut catalog = state.runtime_catalog.write().await;
    catalog
        .models
        .retain(|m| AgentFamily::for_model(Some(&m.id)) != AgentFamily::Claude);
    catalog.models.extend(discovered.models);
    Ok(())
}

pub(crate) async fn policy(state: &AppState, bot: &StoredBot) -> Result<Value, String> {
    let mode = match bot.permission_mode.as_deref() {
        Some("read-only") => "read_only",
        Some("workspace") => "workspace",
        Some("full-access") => "full_access",
        _ => return Err("Choose Claude's access mode in Bot settings.".into()),
    };
    if bot.approval_mode.as_deref() == Some("approve-for-me") {
        return Err(
            "Claude supports Ask for approval or Full access. Choose one in Bot settings.".into(),
        );
    }
    let group = crate::permission_modes::is_group_workspace(state, bot).await?;
    let writes = if mode == "read_only" {
        Vec::new()
    } else {
        crate::permission_modes::runtime_roots(state, bot).await?
    };
    let reads = if group {
        vec![bot.workspace_path.clone()]
    } else {
        vec!["/".to_owned()]
    };
    Ok(
        json!({"mode":mode,"workspace":bot.workspace_path,"approvalMode":if crate::permission_modes::resolve(bot).approval_policy == "never" {"full_access"} else {"ask"},
        "readRoots":reads,"writeRoots":writes,"deniedRoots":state.denied_roots}),
    )
}

pub(crate) async fn configure_thread(
    state: &AppState,
    bot: &StoredBot,
    params: &mut Value,
) -> Result<(), String> {
    if bot.agent_family == AgentFamily::Claude {
        params
            .as_object_mut()
            .ok_or("Invalid thread configuration")?
            .remove("config");
        params["wonderPolicy"] = policy(state, bot).await?;
        params["wonderConnectors"] = json!(true);
    }
    Ok(())
}
