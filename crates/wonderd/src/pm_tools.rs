//! Coordinator tools consume correlated runtime requests, never owner HTTP credentials.
use super::*;
use serde_json::{json, Value};

pub(super) const VERSION: &str = "wonder-project-tools-v2";
const CREATE: &str = "wonder_assign_project";
const LIST: &str = "wonder_list_assignments";
const INSPECT: &str = "wonder_inspect_assignment";
pub(super) fn registered(name: &str) -> bool {
    matches!(name, CREATE | LIST | INSPECT)
}
pub(super) fn specs() -> Vec<Value> {
    let object = |properties: Value, required: Value| json!({"type":"object","additionalProperties":false,"properties":properties,"required":required});
    let spec = |name: &str, description: &str, schema: Value| json!({"type":"function","name":name,"description":description,"inputSchema":schema});
    vec![
        spec(LIST,"List assignments and eligible specialist projects for this Group and your assigned repository. Use this once to discover Bot IDs and current base revisions. Do not poll; finish your response so queued specialists can start.",object(json!({}),json!([]))),
        spec(CREATE,"Create one bounded specialist assignment in this Group and your assigned repository. Include owned files, a success example, exclusions and the smallest meaningful check in instruction. Reuse clientRequestId on retries. Creation queues work; finish your current response to let specialists start. Do not wait or poll in this turn. Result review and integration remain owner actions.",object(json!({"clientRequestId":{"type":"string","format":"uuid","description":"A UUID in canonical 8-4-4-4-12 hexadecimal form, for example 6f992ae9-851c-4ba4-8472-95381a22a26c. Generate a new UUID for each new assignment and reuse it on retries. Do not use a task name or descriptive slug."},"title":{"type":"string","maxLength":160},"instruction":{"type":"string","maxLength":32768},"botId":{"type":"string"},"baseRevision":{"type":"string","description":"Exact full current commit returned by wonder_list_assignments."},"dependencyIds":{"type":"array","items":{"type":"string"},"maxItems":16}}),json!(["clientRequestId","title","instruction","botId","baseRevision","dependencyIds"]))),
        spec(INSPECT,"Inspect one assignment in this Group and your assigned repository, including the submitted result and bounded diff. This cannot review, approve or integrate work on the owner's behalf.",object(json!({"assignmentId":{"type":"string"}}),json!(["assignmentId"])))
    ]
}

pub(super) async fn enabled(
    state: &AppState,
    conversation: &str,
    bot_id: &str,
) -> Result<bool, String> {
    Ok(state
        .store
        .coordinator_group_for_conversation(conversation)
        .await
        .map_err(|e| e.to_string())?
        .is_some_and(|group| {
            group.coordinator_bot_id == bot_id
                && group
                    .members
                    .iter()
                    .any(|m| m.bot_id == bot_id && m.role == "coordinator")
        }))
}
pub(super) fn version(computer: bool, pm: bool) -> String {
    match (computer, pm) {
        (true, true) => format!("{COMPUTER_USE_DYNAMIC_TOOLS_VERSION}+{VERSION}"),
        (true, false) => COMPUTER_USE_DYNAMIC_TOOLS_VERSION.into(),
        (false, true) => VERSION.into(),
        (false, false) => "wonder-no-dynamic-tools-v1".into(),
    }
}
fn response(result: Result<Value, String>) -> Value {
    match result {
        Ok(value) => {
            let text = value.to_string();
            if text.len() > 1024 * 1024 {
                return response(Err("This result is too large for a tool reply. Open the assignment details in Wonder.".into()));
            }
            json!({"success":true,"contentItems":[{"type":"inputText","text":text}]})
        }
        Err(error) => json!({"success":false,"contentItems":[{"type":"inputText","text":error}]}),
    }
}
struct Scope {
    run: wonder_store::GroupRun,
    repository: String,
}
async fn scope(
    state: &AppState,
    runtime: &str,
    thread: &str,
    message: &wonder_store::StoredMessage,
) -> Result<Scope, String> {
    if !state
        .ingestion
        .runtime_accepts_message(runtime, &message.id)
    {
        return Err("The request does not belong to this live runtime.".into());
    }
    if state
        .store
        .conversation_thread(&message.conversation_id)
        .await
        .map_err(|e| e.to_string())?
        .as_deref()
        != Some(thread)
    {
        return Err("This Group thread changed. Continue from its current conversation.".into());
    }
    let version = state
        .store
        .conversation_dynamic_tools_version(&message.conversation_id)
        .await
        .map_err(|e| e.to_string())?
        .unwrap_or_default();
    if !version.split('+').any(|part| part == VERSION) {
        return Err("Project tools were not registered on this thread.".into());
    }
    let run = state
        .store
        .coordinator_group_for_message(&message.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("Only the coordinator of this Group can assign project work.")?;
    if !run
        .channel
        .members
        .iter()
        .any(|m| m.bot_id == run.channel.coordinator_bot_id && m.role == "coordinator")
    {
        return Err("This Bot was not the coordinator in the accepted Group request.".into());
    }
    let bot = state
        .store
        .bot(&run.channel.coordinator_bot_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("Coordinator unavailable.")?;
    if bot.is_archived || !enabled(state, &message.conversation_id, &bot.id).await? {
        return Err("This Bot no longer coordinates this Group.".into());
    }
    // The accepted dispatch context pins the repository; settings changes cannot widen it.
    let context = state
        .store
        .dispatch_context(&message.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("This turn has no verified project context. Start a new Group message.")?;
    let context: Value =
        serde_json::from_str(&context).map_err(|_| "The saved project context is invalid.")?;
    let profile = context
        .get("permissionProfile")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !matches!(profile, ":workspace" | ":danger-full-access") {
        return Err("This accepted turn does not permit project edits. Start a new turn with approved write access.".into());
    }
    let repository = context
        .get("workingDirectory")
        .and_then(Value::as_str)
        .ok_or("The accepted project directory is unavailable.")?
        .to_owned();
    if profile == ":workspace"
        && !context
            .get("runtimeWorkspaceRoots")
            .and_then(Value::as_array)
            .is_some_and(|roots| {
                roots
                    .iter()
                    .filter_map(Value::as_str)
                    .any(|root| FsPath::new(&repository).starts_with(root))
            })
    {
        return Err("The accepted turn did not grant writes to this project.".into());
    }
    if bot.execution_directory() != repository {
        return Err("The coordinator's project changed. Start a new Group message.".into());
    }
    file_access::dispatch_check(state, &bot, bot.effective_permission_profile()).await?;
    if !matches!(
        bot.permission_mode.as_deref(),
        Some("workspace" | "full-access")
    ) {
        return Err(
            "The coordinator needs approved project write access before delegating edits.".into(),
        );
    }
    if bot.permission_mode.as_deref() == Some("workspace")
        && !permission_modes::runtime_roots(state, &bot)
            .await?
            .iter()
            .any(|root| FsPath::new(&repository).starts_with(root))
    {
        return Err("The coordinator lacks write access to this project.".into());
    }
    project_assignments::canonical_repo(&repository).await?;
    Ok(Scope { run, repository })
}
fn arguments(params: &Value) -> Result<Value, String> {
    let value = match params.get("arguments") {
        Some(Value::Object(value)) => Value::Object(value.clone()),
        Some(Value::String(value)) => {
            serde_json::from_str(value).map_err(|_| "Invalid project tool arguments.")?
        }
        _ => return Err("Project tool arguments must be an object.".into()),
    };
    if !value.is_object() || value.to_string().len() > 40 * 1024 {
        return Err("Project tool arguments exceed the supported size.".into());
    }
    Ok(value)
}
async fn execute(
    state: &AppState,
    scope: &Scope,
    tool: &str,
    args: Value,
) -> Result<Value, String> {
    let group = &scope.run.channel;
    match tool {
        CREATE => {
            let request: project_assignments::Create = serde_json::from_value(args.clone())
                .map_err(|_| {
                    "Use only the documented assignment fields; Group and owner scope are inferred."
                })?;
            let bot_id = args
                .get("botId")
                .and_then(Value::as_str)
                .ok_or("Choose a specialist Bot.")?;
            if !group
                .members
                .iter()
                .any(|m| m.bot_id == bot_id && m.role == "worker")
            {
                return Err("That Bot was not a specialist in this accepted Group request.".into());
            }
            let bot = state
                .store
                .bot(bot_id)
                .await
                .map_err(|e| e.to_string())?
                .ok_or("Specialist unavailable.")?;
            if bot.execution_directory() != scope.repository {
                return Err(
                    "That specialist uses another repository outside this assignment scope.".into(),
                );
            }
            let attachments = state
                .store
                .attachment_ids_for_message(&scope.run.parent.id)
                .await
                .map_err(|e| e.to_string())?;
            let Json(value) = project_assignments::create_for_owner_with_attachments(
                state,
                group.id.clone(),
                scope.run.parent.device_id.clone(),
                request,
                &attachments,
            )
            .await
            .map_err(|(_, message)| message)?;
            Ok(
                json!({"assignment":value,"nextAction":"Finish this response so the queued specialist can start. The owner reviews and integrates the result."}),
            )
        }
        LIST => {
            if args.as_object().is_none_or(|o| !o.is_empty()) {
                return Err("List takes no arguments; Group scope is inferred.".into());
            }
            let assignments = state
                .store
                .project_assignments(&group.id)
                .await
                .map_err(|e| e.to_string())?
                .into_iter()
                .filter(|a| a.repository_path == scope.repository)
                .map(|a| {
                    let mut value = project_assignments::summary(&a);
                    if let Some(object) = value.as_object_mut() {
                        object.remove("instruction");
                        object.remove("validation");
                    }
                    value["summary"] = json!(a
                        .summary
                        .map(|summary| summary.chars().take(1200).collect::<String>()));
                    value
                })
                .collect::<Vec<_>>();
            let mut projects = Vec::new();
            for member in group.members.iter().filter(|m| m.role == "worker") {
                let Some(bot) = state
                    .store
                    .bot(&member.bot_id)
                    .await
                    .map_err(|e| e.to_string())?
                else {
                    continue;
                };
                if bot.is_archived
                    || bot.execution_directory() != scope.repository
                    || !matches!(
                        bot.permission_mode.as_deref(),
                        Some("workspace" | "full-access")
                    )
                {
                    continue;
                }
                if file_access::dispatch_check(state, &bot, bot.effective_permission_profile())
                    .await
                    .is_err()
                {
                    continue;
                }
                if bot.permission_mode.as_deref() == Some("workspace")
                    && !permission_modes::runtime_roots(state, &bot)
                        .await?
                        .iter()
                        .any(|root| FsPath::new(&scope.repository).starts_with(root))
                {
                    continue;
                }
                let revision =
                    project_assignments::git(&scope.repository, &["rev-parse", "HEAD"]).await?;
                projects.push(json!({"botId":bot.id,"projectName":FsPath::new(&scope.repository).file_name().unwrap_or_default().to_string_lossy(),"baseRevision":revision}));
            }
            Ok(json!({"assignments":assignments,"projects":projects}))
        }
        INSPECT => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct Inspect {
                assignment_id: String,
            }
            let request: Inspect = serde_json::from_value(args)
                .map_err(|_| "Inspect takes only assignmentId; Group scope is inferred.")?;
            let assignment = state
                .store
                .project_assignment(&request.assignment_id)
                .await
                .map_err(|e| e.to_string())?
                .filter(|a| a.group_id == group.id && a.repository_path == scope.repository)
                .ok_or("Assignment not found in this Group and project.")?;
            let mut value = project_assignments::summary(&assignment);
            if let Some(result) = assignment.result_revision.as_deref() {
                value["diff"] = json!(
                    project_assignments::git(
                        &scope.repository,
                        &[
                            "diff",
                            "--no-ext-diff",
                            "--no-textconv",
                            "--no-color",
                            &assignment.base_revision,
                            result,
                            "--"
                        ]
                    )
                    .await?
                );
            }
            Ok(value)
        }
        _ => Err("Project tool is not registered.".into()),
    }
}

/// Called only by the durable notification path while dispatch_lock is held.
pub(super) async fn handle(
    state: &AppState,
    notification: &Value,
    params: &Value,
    message: Option<&wonder_store::StoredMessage>,
) -> bool {
    let Some(runtime) = notification.get("_wonderRuntimeId").and_then(Value::as_str) else {
        return true;
    };
    let mut actual = params.clone();
    actual["_wonderRuntimeId"] = json!(runtime);
    let Some(client) = state.ingestion.approval_client(&actual) else {
        return true;
    };
    let Some(request_id) = notification.get("id").cloned() else {
        return true;
    };
    let rpc = client.lock().await.rpc();
    if rpc.health().id() != runtime {
        return true;
    }
    let answer = handle_call(state, runtime, params, message).await;
    match answer {
        Ok(value) => rpc
            .respond_value(request_id, Some(value), None)
            .await
            .is_ok(),
        Err(_) => false,
    }
}
async fn handle_call(
    state: &AppState,
    runtime: &str,
    params: &Value,
    message: Option<&wonder_store::StoredMessage>,
) -> Result<Value, String> {
    let Some(message) = message else {
        return Ok(response(Err(
            "The request is not correlated with accepted Group work.".into(),
        )));
    };
    let Some(thread) = params.get("threadId").and_then(Value::as_str) else {
        return Ok(response(Err("Thread identity is required.".into())));
    };
    let Some(turn) = params.get("turnId").and_then(Value::as_str) else {
        return Ok(response(Err("Turn identity is required.".into())));
    };
    if message.codex_thread_id.as_deref() != Some(thread)
        || message.codex_turn_id.as_deref() != Some(turn)
    {
        return Ok(response(Err("The request targets different work.".into())));
    }
    let tool = params
        .get("tool")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !registered(tool) {
        return Ok(response(Err("Project tool is not registered.".into())));
    }
    let scope = match scope(state, runtime, thread, message).await {
        Ok(scope) => scope,
        Err(error) => return Ok(response(Err(error))),
    };
    let Some(call) = params
        .get("callId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && id.len() <= 256)
    else {
        return Ok(response(Err(
            "A stable runtime call identity is required.".into()
        )));
    };
    let key = hex::encode(Sha256::digest(
        json!([runtime, thread, turn, call]).to_string(),
    ));
    let hash = hex::encode(Sha256::digest(
        json!({"tool":tool,"arguments":params.get("arguments")}).to_string(),
    ));
    if let Some((saved, answer)) = state
        .store
        .pm_tool_call(&key)
        .await
        .map_err(|e| e.to_string())?
    {
        if saved != hash {
            return Ok(response(Err(
                "This runtime call was already used with different arguments.".into(),
            )));
        }
        if let Some(answer) = answer {
            return serde_json::from_str(&answer).map_err(|e| e.to_string());
        }
    }
    if !matches!(message.state.as_str(), "accepted_by_codex" | "streaming") {
        return Ok(response(Err(
            "This coordinator turn is no longer active.".into()
        )));
    }
    if !state
        .store
        .reserve_pm_tool_call(
            &key,
            &hash,
            &message.id,
            runtime,
            tool,
            &now_ms().to_string(),
        )
        .await
        .map_err(|e| e.to_string())?
    {
        return Ok(response(Err("This turn reached its 16-call coordination limit. Finish your response before continuing.".into())));
    }
    let value = response(match arguments(params) {
        Ok(args) => execute(state, &scope, tool, args).await,
        Err(error) => Err(error),
    });
    // Store the full response before writing to the transport. Create itself uses
    // the stable clientRequestId, so a crash before this commit cannot duplicate it.
    state
        .store
        .complete_pm_tool_call(&key, &hash, &value.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn fixture() -> (
        tempfile::TempDir,
        AppState,
        wonder_store::StoredMessage,
        String,
    ) {
        let (dir, state, head) = project_assignments::tests::fixture().await;
        let bot = state.store.bot("bot").await.unwrap().unwrap();
        let workspace = dir.path().join("worker");
        std::fs::create_dir(&workspace).unwrap();
        state
            .store
            .upsert_bot(
                "worker",
                "Specialist",
                "Engineer",
                "Implement bounded work",
                workspace.to_str().unwrap(),
                "test",
                None,
                None,
                "1",
            )
            .await
            .unwrap();
        let mut worker = state.store.bot("worker").await.unwrap().unwrap();
        worker.permission_mode = Some("full-access".into());
        worker.working_directory = bot.working_directory.clone();
        state
            .store
            .update_managed_bot(&worker, [false; 3])
            .await
            .unwrap();
        state
            .store
            .create_channel(
                "developers",
                "dev-chat",
                "Developers",
                None,
                "bot",
                &[("bot", "coordinator"), ("worker", "worker")],
                "1",
            )
            .await
            .unwrap();
        // Capture real thread/start params in the fake transport before restarting it.
        let script = dir.path().join("runtime.py");
        let source = std::fs::read_to_string(&script).unwrap();
        std::fs::write(&script,source.replacen("    result = {}","    with open(root + '/request-details', 'a') as log: log.write(json.dumps(r) + '\\n')\n    result = {}", 1)).unwrap();
        let config = state.launch_config.lock().await.clone();
        state.app_server.lock().await.restart(config).await.unwrap();
        let health = state.app_server.lock().await.health();
        state.ingestion.register(&state.app_server, health, None);
        let client = uuid::Uuid::new_v4().to_string();
        let MessageInsert::Inserted(parent) = state
            .store
            .insert_message(
                "owner",
                &client,
                "Coordinate a small Wonder change",
                "hash",
                "dev-chat",
                "2",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        state
            .store
            .add_channel_message(NewChannelMessage {
                channel_id: "developers",
                message_id: &parent.id,
                author_kind: "user",
                author_bot_id: None,
                phase: "user",
                created_at: "2",
                presentation_kind: "message",
                outcome: Some("completed"),
                retryable: false,
            })
            .await
            .unwrap();
        assert!(state.store.claim_group_run(&parent.id).await.unwrap());
        state
            .store
            .plan_group_node(&parent, &parent.client_message_id, "bot", "direct")
            .await
            .unwrap();
        let (resolved, _) = effective_settings(&RuntimeCatalog::default(), &bot, None);
        let mut runtime = state.app_server.lock().await;
        let thread = start_bot_thread(&state, &mut runtime, "dev-chat", &bot, &resolved)
            .await
            .unwrap();
        drop(runtime);
        assert!(state
            .store
            .claim_message_for_dispatch(&parent.id)
            .await
            .unwrap());
        state
            .store
            .begin_dispatch_submission_with_context(
                &parent.id,
                &thread,
                Some(&json!({"workingDirectory":bot.execution_directory(),"permissionProfile":":danger-full-access","runtimeWorkspaceRoots":[bot.workspace_path]}).to_string()),
            )
            .await
            .unwrap();
        state
            .store
            .update_message_delivery(
                &parent.id,
                "accepted_by_codex",
                Some(&thread),
                Some("pm-turn"),
            )
            .await
            .unwrap();
        let parent = state
            .store
            .message_by_id(&parent.id)
            .await
            .unwrap()
            .unwrap();
        (dir, state, parent, head)
    }
    async fn runtime_id(state: &AppState) -> String {
        state.app_server.lock().await.health().id().to_owned()
    }
    fn params(tool: &str, call: &str, args: Value) -> Value {
        json!({"tool":tool,"callId":call,"threadId":"thread","turnId":"pm-turn","arguments":args})
    }
    fn create(head: &str) -> Value {
        json!({"clientRequestId":uuid::Uuid::new_v4().to_string(),"title":"Improve a focused test","instruction":"Own only the selected test. Preserve unrelated work. Implement a bounded regression test, run it and commit.","botId":"worker","baseRevision":head,"dependencyIds":[]})
    }
    fn value(response: &Value) -> Value {
        serde_json::from_str(response["contentItems"][0]["text"].as_str().unwrap()).unwrap()
    }
    #[tokio::test]
    async fn descriptive_request_id_returns_actionable_error_and_corrected_uuid_succeeds() {
        let (_dir, state, parent, head) = fixture().await;
        let runtime = runtime_id(&state).await;
        let mut args = create(&head);
        args["clientRequestId"] = json!("wonder-management-error-accessibility-20260909-01");
        let rejected = handle_call(
            &state,
            &runtime,
            &params(CREATE, "slug-request", args.clone()),
            Some(&parent),
        )
        .await
        .unwrap();
        assert_eq!(rejected["success"], false);
        let error = rejected["contentItems"][0]["text"].as_str().unwrap();
        assert!(
            error.contains("clientRequestId") && error.contains("valid UUID"),
            "{error}"
        );
        assert!(state
            .store
            .project_assignments("developers")
            .await
            .unwrap()
            .is_empty());
        args["clientRequestId"] = json!(uuid::Uuid::new_v4().to_string());
        let accepted = handle_call(
            &state,
            &runtime,
            &params(CREATE, "corrected-request", args),
            Some(&parent),
        )
        .await
        .unwrap();
        assert_eq!(accepted["success"], true, "{accepted}");
        assert_eq!(
            state
                .store
                .project_assignments("developers")
                .await
                .unwrap()
                .len(),
            1
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn registered_coordinator_calls_create_list_inspect_and_replay_once_through_transport() {
        let (dir, state, parent, head) = fixture().await;
        let upload = upload_conversation_file(State(state.clone()), Path("dev-chat".into()), Json(serde_json::from_value(json!({"clientUploadId":uuid::Uuid::new_v4().to_string(),"name":"brief.txt","mimeType":"text/plain","contentBase64":base64::engine::general_purpose::STANDARD.encode("Owner's assignment brief")})).unwrap())).await;
        assert_eq!(upload.status(), StatusCode::OK);
        let file: Value = serde_json::from_slice(
            &axum::body::to_bytes(upload.into_body(), 100000)
                .await
                .unwrap(),
        )
        .unwrap();
        let file_id = file["id"].as_str().unwrap();
        let pool = sqlx::SqlitePool::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO message_attachments(message_id,file_id,created_at) VALUES(?,?, '2')",
        )
        .bind(&parent.id)
        .bind(file_id)
        .execute(&pool)
        .await
        .unwrap();
        let runtime = runtime_id(&state).await;
        let args = create(&head);
        let id = args["clientRequestId"].as_str().unwrap();
        let p = params(CREATE, "create-1", args.clone());
        let envelope =
            json!({"id":900,"_wonderRuntimeId":runtime,"method":"item/tool/call","params":p});
        {
            let _guard = state.dispatch_lock.lock().await;
            assert!(process_app_server_notification(&state, envelope.clone(), false).await);
            assert!(process_app_server_notification(&state, envelope, false).await);
        }
        assert_eq!(
            state
                .store
                .project_assignments("developers")
                .await
                .unwrap()
                .len(),
            1
        );
        let assignment = state.store.project_assignment(id).await.unwrap().unwrap();
        assert_eq!(
            state
                .store
                .attachment_ids_for_message(&assignment.parent_message_id)
                .await
                .unwrap(),
            vec![file_id]
        );
        let mut children = tokio::task::JoinSet::new();
        crate::groups::tick(&state, &mut children).await.unwrap();
        assert!(
            children.is_empty(),
            "Queued specialists must wait for the PM response to finish"
        );
        let list = handle_call(
            &state,
            &runtime,
            &params(LIST, "list-1", json!({})),
            Some(&parent),
        )
        .await
        .unwrap();
        assert_eq!(list["success"], true);
        assert_eq!(value(&list)["projects"][0]["botId"], "worker");
        let inspect = handle_call(
            &state,
            &runtime,
            &params(INSPECT, "inspect-1", json!({"assignmentId":id})),
            Some(&parent),
        )
        .await
        .unwrap();
        assert_eq!(value(&inspect)["id"], id);
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                let responses =
                    std::fs::read_to_string(dir.path().join("responses")).unwrap_or_default();
                if responses
                    .lines()
                    .filter(|line| line.contains("900"))
                    .count()
                    == 2
                {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let details = std::fs::read_to_string(dir.path().join("request-details")).unwrap();
        let start: Value = details
            .lines()
            .map(|l| serde_json::from_str::<Value>(l).unwrap())
            .find(|v| v["method"] == "thread/start")
            .unwrap();
        let names = start["params"]["dynamicTools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["name"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(names, vec![LIST, CREATE, INSPECT]);
        assert!(!std::fs::read_to_string(dir.path().join("requests"))
            .unwrap()
            .lines()
            .any(|l| l == "turn/start"));
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn crash_after_assignment_acceptance_before_response_does_not_create_twice() {
        let (dir, mut state, parent, head) = fixture().await;
        let runtime = runtime_id(&state).await;
        let args = create(&head);
        let p = params(CREATE, "lost-response", args.clone());
        let key = hex::encode(Sha256::digest(
            json!([runtime, "thread", "pm-turn", "lost-response"]).to_string(),
        ));
        let hash = hex::encode(Sha256::digest(
            json!({"tool":CREATE,"arguments":args}).to_string(),
        ));
        assert!(state
            .store
            .reserve_pm_tool_call(&key, &hash, &parent.id, &runtime, CREATE, "1")
            .await
            .unwrap());
        let scoped = scope(&state, &runtime, "thread", &parent).await.unwrap();
        execute(&state, &scoped, CREATE, args).await.unwrap();
        state.store = wonder_store::Store::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        let replay = handle_call(&state, &runtime, &p, Some(&parent))
            .await
            .unwrap();
        assert_eq!(replay["success"], true);
        assert_eq!(
            state
                .store
                .project_assignments("developers")
                .await
                .unwrap()
                .len(),
            1
        );
        let again = handle_call(&state, &runtime, &p, Some(&parent))
            .await
            .unwrap();
        assert_eq!(again, replay);
        let mut forged = p;
        forged["arguments"]["title"] = json!("Different");
        assert_eq!(
            handle_call(&state, &runtime, &forged, Some(&parent))
                .await
                .unwrap()["success"],
            false
        );
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn forged_scope_runtime_worker_and_unregistered_thread_are_rejected() {
        let (_dir, state, parent, head) = fixture().await;
        let runtime = runtime_id(&state).await;
        let mut supplied = create(&head);
        supplied["attachmentIds"] = json!([uuid::Uuid::new_v4().to_string()]);
        assert_eq!(
            handle_call(
                &state,
                &runtime,
                &params(CREATE, "forged-attachments", supplied),
                Some(&parent)
            )
            .await
            .unwrap()["success"],
            false
        );
        let mut args = create(&head);
        args["groupId"] = json!("another-group");
        assert_eq!(
            handle_call(
                &state,
                &runtime,
                &params(CREATE, "forged-group", args),
                Some(&parent)
            )
            .await
            .unwrap()["success"],
            false
        );
        assert_eq!(
            handle_call(
                &state,
                "forged-runtime",
                &params(CREATE, "forged-runtime", create(&head)),
                Some(&parent)
            )
            .await
            .unwrap()["success"],
            false
        );
        let mut wrong = params(CREATE, "forged-turn", create(&head));
        wrong["turnId"] = json!("other-turn");
        assert_eq!(
            handle_call(&state, &runtime, &wrong, Some(&parent))
                .await
                .unwrap()["success"],
            false
        );
        state
            .store
            .mark_conversation_dynamic_tools("dev-chat", COMPUTER_USE_DYNAMIC_TOOLS_VERSION)
            .await
            .unwrap();
        assert_eq!(
            handle_call(
                &state,
                &runtime,
                &params(CREATE, "old-thread", create(&head)),
                Some(&parent)
            )
            .await
            .unwrap()["success"],
            false
        );
        state
            .store
            .mark_conversation_dynamic_tools("dev-chat", VERSION)
            .await
            .unwrap();
        let child_client = uuid::Uuid::new_v4().to_string();
        state
            .store
            .plan_group_node(&parent, &child_client, "worker", "worker")
            .await
            .unwrap();
        let MessageInsert::Inserted(child) = state
            .store
            .insert_message(
                "owner",
                &child_client,
                "Specialist work",
                "hash",
                "worker-chat",
                "3",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        state
            .store
            .create_conversation("worker-chat", "worker", "Worker", "3")
            .await
            .unwrap();
        state
            .store
            .set_conversation_thread("worker-chat", "worker-thread", None, "3")
            .await
            .unwrap();
        state
            .store
            .mark_conversation_dynamic_tools("worker-chat", VERSION)
            .await
            .unwrap();
        state
            .store
            .update_message_delivery(
                &child.id,
                "accepted_by_codex",
                Some("worker-thread"),
                Some("worker-turn"),
            )
            .await
            .unwrap();
        let child = state.store.message_by_id(&child.id).await.unwrap().unwrap();
        let mut worker = params(CREATE, "worker-forgery", create(&head));
        worker["threadId"] = json!("worker-thread");
        worker["turnId"] = json!("worker-turn");
        assert_eq!(
            handle_call(&state, &runtime, &worker, Some(&child))
                .await
                .unwrap()["success"],
            false
        );
        assert!(state
            .store
            .project_assignments("developers")
            .await
            .unwrap()
            .is_empty());
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn tool_migration_preserves_computer_registration_and_never_runs_computer_approvals() {
        let (_dir, mut state, parent, _head) = fixture().await;
        state
            .store
            .mark_conversation_dynamic_tools("dev-chat", "wonder-project-tools-v1")
            .await
            .unwrap();
        assert!(
            conversation_needs_tool_migration(&state, "dev-chat", Some("thread"))
                .await
                .unwrap()
        );
        state
            .store
            .mark_conversation_dynamic_tools("dev-chat", COMPUTER_USE_DYNAMIC_TOOLS_VERSION)
            .await
            .unwrap();
        assert!(
            conversation_needs_tool_migration(&state, "dev-chat", Some("thread"))
                .await
                .unwrap()
        );
        state
            .store
            .mark_conversation_dynamic_tools("dev-chat", VERSION)
            .await
            .unwrap();
        assert!(
            !conversation_needs_tool_migration(&state, "dev-chat", Some("thread"))
                .await
                .unwrap()
        );
        state.computer_use_enabled = true;
        state.computer_use_bin = Some(PathBuf::from("/unused-test-helper"));
        assert!(
            conversation_needs_tool_migration(&state, "dev-chat", Some("thread"))
                .await
                .unwrap()
        );
        let bot = state.store.bot("bot").await.unwrap().unwrap();
        let (resolved, _) = effective_settings(&RuntimeCatalog::default(), &bot, None);
        start_bot_thread(
            &state,
            &mut *state.app_server.lock().await,
            "dev-chat",
            &bot,
            &resolved,
        )
        .await
        .unwrap();
        assert_eq!(
            state
                .store
                .conversation_dynamic_tools_version("dev-chat")
                .await
                .unwrap()
                .unwrap(),
            version(true, true)
        );
        assert!(
            !conversation_needs_tool_migration(&state, "dev-chat", Some("thread"))
                .await
                .unwrap()
        );
        assert!(!registered("wonder_computer_use"));
        assert!(registered(CREATE));
        let runtime = runtime_id(&state).await;
        let answer = handle_call(
            &state,
            &runtime,
            &params(
                "wonder_computer_use",
                "computer",
                json!({"success":true,"action":"click"}),
            ),
            Some(&parent),
        )
        .await
        .unwrap();
        assert_eq!(answer["success"], false);
        assert!(state
            .store
            .project_assignments("developers")
            .await
            .unwrap()
            .is_empty());
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn accepted_read_only_scope_and_worker_bound_runtime_cannot_delegate_edits() {
        let (dir, state, parent, head) = fixture().await;
        let runtime = runtime_id(&state).await;
        let health = state.app_server.lock().await.health();
        state.ingestion.register(
            &state.app_server,
            health,
            Some("other-worker-message".into()),
        );
        assert_eq!(
            handle_call(
                &state,
                &runtime,
                &params(CREATE, "bound-worker", create(&head)),
                Some(&parent)
            )
            .await
            .unwrap()["success"],
            false
        );
        let health = state.app_server.lock().await.health();
        state.ingestion.register(&state.app_server, health, None);
        let bot = state.store.bot("bot").await.unwrap().unwrap();
        let pool = sqlx::SqlitePool::connect(&format!(
            "sqlite://{}",
            dir.path().join("state.db").display()
        ))
        .await
        .unwrap();
        sqlx::query("UPDATE dispatch_attempts SET context_json=? WHERE message_id=?").bind(json!({"workingDirectory":bot.execution_directory(),"permissionProfile":":read-only","runtimeWorkspaceRoots":[bot.workspace_path]}).to_string()).bind(&parent.id).execute(&pool).await.unwrap();
        assert_eq!(
            handle_call(
                &state,
                &runtime,
                &params(CREATE, "accepted-read-only", create(&head)),
                Some(&parent)
            )
            .await
            .unwrap()["success"],
            false
        );
        assert!(state
            .store
            .project_assignments("developers")
            .await
            .unwrap()
            .is_empty());
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn bounded_calls_stop_delegation_and_cleanup_preserves_group_deletion() {
        let (_dir, state, parent, head) = fixture().await;
        let runtime = runtime_id(&state).await;
        for number in 0..16 {
            assert_eq!(
                handle_call(
                    &state,
                    &runtime,
                    &params(LIST, &format!("list-{number}"), json!({})),
                    Some(&parent)
                )
                .await
                .unwrap()["success"],
                true
            );
        }
        assert_eq!(
            handle_call(
                &state,
                &runtime,
                &params(CREATE, "over-limit", create(&head)),
                Some(&parent)
            )
            .await
            .unwrap()["success"],
            false
        );
        assert!(state
            .store
            .project_assignments("developers")
            .await
            .unwrap()
            .is_empty());
        state
            .store
            .update_message_delivery(&parent.id, "completed", Some("thread"), Some("pm-turn"))
            .await
            .unwrap();
        state
            .store
            .finish_group_run(&parent.id, Some(&parent.id), "4")
            .await
            .unwrap();
        assert!(state.store.delete_channel("developers").await.unwrap());
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
