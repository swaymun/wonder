use super::*;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Edit {
    expected_revision: i64,
    settings: Option<Settings>,
    body: Option<String>,
    cancel: Option<bool>,
    expected_turn_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Settings {
    model: Option<String>,
    reasoning_effort: Option<String>,
    service_tier: Option<String>,
    permission_mode: Option<permission_modes::PermissionMode>,
    approval_mode: Option<permission_modes::ApprovalMode>,
}
#[derive(Deserialize)]
pub(super) struct Reorder {
    items: Vec<(String, i64)>,
}
pub(super) async fn list(
    State(state): State<AppState>,
    Path(conversation): Path<String>,
) -> Response {
    let items = match state.store.pending_queue(&conversation).await {
        Ok(items) => items,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let bot = match bot_for_conversation(&state, &conversation).await {
        Ok(bot) => bot,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let child = match state
        .store
        .subagent_ownership_for_conversation(&conversation)
        .await
    {
        Ok(child) => child,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let mut result = Vec::new();
    for item in items {
        let mut value = serde_json::json!({"id":item.id,"clientMessageId":item.client_message_id,"body":item.body,"revision":item.revision,"attachmentIds":item.attachment_ids});
        if child.is_none() {
            if let Some(bot) = bot.clone() {
                let (bot, _) = match state.store.message_execution_bot(&item.id, bot).await {
                    Ok(result) => result,
                    Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
                };
                value["executionSettings"] = serde_json::json!({"model":bot.model,"reasoningEffort":bot.reasoning_effort,"serviceTier":bot.service_tier,"permissionMode":bot.permission_mode,"approvalMode":bot.approval_mode,"workingDirectory":bot.working_directory});
            }
        }
        result.push(value);
    }
    Json(result).into_response()
}
pub(super) async fn edit(
    State(state): State<AppState>,
    Path((conversation, id)): Path<(String, String)>,
    Json(request): Json<Edit>,
) -> Response {
    if let Some(response) = crate::subagents::reject_user_mutation(&state, &conversation).await {
        return response;
    }
    let is_child = match state
        .store
        .subagent_ownership_for_conversation(&conversation)
        .await
    {
        Ok(child) => child.is_some(),
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    if let Some(settings) = request.settings {
        if request.body.is_some()
            || request.cancel.unwrap_or(false)
            || request.expected_turn_id.is_some()
        {
            return StatusCode::BAD_REQUEST.into_response();
        }
        if is_child {
            return (
                StatusCode::CONFLICT,
                "Subagent settings are inherited from its runtime and cannot be changed here.",
            )
                .into_response();
        }
        let _guard = state.dispatch_lock.lock().await;
        let Ok(Some(bot)) = bot_for_conversation(&state, &conversation).await else {
            return StatusCode::NOT_FOUND.into_response();
        };
        if state.store.list_channels().await.map_or(true, |groups| {
            groups.iter().any(|g| g.conversation_id == conversation)
        }) {
            return StatusCode::CONFLICT.into_response();
        }
        let (mut bot, _) = match state.store.message_execution_bot(&id, bot).await {
            Ok(bot) => bot,
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        };
        if let Some(value) = settings.model {
            bot.model = (!value.is_empty()).then_some(value);
        }
        if let Some(value) = settings.reasoning_effort {
            bot.reasoning_effort = (!value.is_empty()).then_some(value);
        }
        if let Some(value) = settings.service_tier {
            bot.service_tier = (!value.is_empty()).then_some(value);
        }
        if let Err(error) = permission_modes::apply_selection(
            &mut bot,
            settings.permission_mode,
            settings.approval_mode,
        ) {
            return (StatusCode::BAD_REQUEST, error).into_response();
        }
        if let Err(error) = validate_bot_runtime_settings(
            &*state.runtime_catalog.read().await,
            bot.model.as_deref(),
            bot.reasoning_effort.as_deref(),
            bot.service_tier.as_deref(),
        ) {
            return (StatusCode::BAD_REQUEST, error).into_response();
        }
        if bot.permission_mode.is_some() || bot.approval_mode.is_some() {
            let Ok(access) = state.store.bot_file_access(&bot.id).await else {
                return StatusCode::SERVICE_UNAVAILABLE.into_response();
            };
            if let Err(error) = permission_modes::validate_roots(&bot, &access, &state.denied_roots)
            {
                return (StatusCode::BAD_REQUEST, error).into_response();
            }
            if let Err(error) =
                permission_modes::verify(&state, &mut *state.app_server.lock().await, &bot).await
            {
                return (StatusCode::BAD_REQUEST, error).into_response();
            }
        }
        return match state
            .store
            .update_pending_execution_bot(&conversation, &id, request.expected_revision, &bot)
            .await
        {
            Ok(true) => StatusCode::NO_CONTENT.into_response(),
            Ok(false) => StatusCode::CONFLICT.into_response(),
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        };
    }
    if let Some(turn) = request.expected_turn_id {
        if request.body.is_some() || request.cancel.unwrap_or(false) {
            return StatusCode::BAD_REQUEST.into_response();
        }
        if is_child {
            let child =
                match crate::subagents::runtime_for_conversation(&state, &conversation).await {
                    Ok(Some(child)) => child,
                    Ok(None) | Err(_) => {
                        return (
                            StatusCode::CONFLICT,
                            "This subagent is unavailable. Reopen the parent chat and try again.",
                        )
                            .into_response()
                    }
                };
            let active = crate::child_turn_is_active(&child, &turn, true)
                .await
                .unwrap_or(false);
            if !active {
                return (
                    StatusCode::CONFLICT,
                    "This subagent response is no longer accepting direct input.",
                )
                    .into_response();
            }
            return match state
                .store
                .queue_to_guide_verified_child(
                    &conversation,
                    &id,
                    request.expected_revision,
                    &child.ownership.thread_id,
                    &turn,
                )
                .await
            {
                Ok(true) => StatusCode::NO_CONTENT.into_response(),
                Ok(false) => (
                    StatusCode::CONFLICT,
                    "This message or the active subagent work changed. Nothing was moved.",
                )
                    .into_response(),
                Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
            };
        }
        return match state
            .store
            .queue_to_guide(&conversation, &id, request.expected_revision, &turn)
            .await
        {
            Ok(true) => StatusCode::NO_CONTENT.into_response(),
            Ok(false) => (
                StatusCode::CONFLICT,
                "This message or the active work changed. Nothing was moved.",
            )
                .into_response(),
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        };
    }
    let cancel = request.cancel.unwrap_or(false);
    if cancel == request.body.is_some()
        || request
            .body
            .as_ref()
            .is_some_and(|b| b.trim().is_empty() || b.len() > 65536)
    {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let hash = request
        .body
        .as_ref()
        .map(|b| hex::encode(Sha256::digest(b.as_bytes())));
    let body = request.body.as_deref().zip(hash.as_deref());
    match state
        .store
        .edit_pending(&conversation, &id, request.expected_revision, body)
        .await
    {
        Ok(true) => {
            let _ = publish_event_with_context(
                &state,
                WonderEvent::Activity {
                    category: "conversation".into(),
                    state: "updated".into(),
                    detail: None,
                },
                EventContext {
                    conversation_id: Some(conversation),
                    ..EventContext::default()
                },
            )
            .await;
            StatusCode::NO_CONTENT.into_response()
        }
        Ok(false) => (
            StatusCode::CONFLICT,
            "This message changed or started. Refresh the queue; your edit has not been applied.",
        )
            .into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}
pub(super) async fn reorder(
    State(state): State<AppState>,
    Path(conversation): Path<String>,
    Json(request): Json<Reorder>,
) -> Response {
    if let Some(response) = crate::subagents::reject_user_mutation(&state, &conversation).await {
        return response;
    }
    if request.items.len() > 1000 {
        return StatusCode::BAD_REQUEST.into_response();
    }
    match state
        .store
        .reorder_pending(&conversation, &request.items)
        .await
    {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => (
            StatusCode::CONFLICT,
            "The queue changed. Refresh before reordering.",
        )
            .into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;
    #[tokio::test]
    async fn composer_options_use_owned_queue_snapshot_not_current_bot_scope() {
        let (_dir, state) = crate::permission_modes::tests::fixture().await;
        state
            .store
            .ensure_conversation_metadata("bot", "bot", "Bot", "now")
            .await
            .unwrap();
        let mut bot = state.store.bot("bot").await.unwrap().unwrap();
        bot.permission_mode = Some("read-only".into());
        bot.approval_mode = Some("ask-for-approval".into());
        state
            .store
            .update_managed_bot(&bot, [true; 3])
            .await
            .unwrap();
        let MessageInsert::Inserted(message) = state
            .store
            .insert_dispatch_message(
                "owner",
                "snapshot-options",
                "work",
                "hash",
                "bot",
                &[],
                "now",
                true,
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        bot.permission_mode = Some("full-access".into());
        bot.approval_mode = Some("full-access".into());
        state
            .store
            .update_managed_bot(&bot, [true; 3])
            .await
            .unwrap();
        {
            let mut catalog = state.runtime_catalog.write().await;
            catalog.apply_permission_profiles(
                bot.execution_directory(),
                &serde_json::json!({"data": [
                    {"name": ":read-only", "allowed": true},
                    {"name": ":workspace", "allowed": false},
                    {"name": ":danger-full-access", "allowed": false}
                ]}),
            );
        }
        let response = conversation_composer_options(
            State(state.clone()),
            Path("bot".into()),
            Query(ComposerOptionsQuery {
                queued_message_id: Some(message.id.clone()),
            }),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let value: serde_json::Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        assert_eq!(value["approvalModes"][0]["allowed"], true);
        assert_eq!(value["approvalModes"][1]["allowed"], true);
        let response = conversation_composer_options(
            State(state.clone()),
            Path("bot".into()),
            Query(ComposerOptionsQuery::default()),
        )
        .await;
        let value: serde_json::Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 65536).await.unwrap()).unwrap();
        assert_eq!(value["approvalModes"][0]["allowed"], false);
        for id in ["unrelated-message".to_owned(), message.id.clone()] {
            if id == message.id {
                state
                    .store
                    .update_message_delivery(&id, "streaming", Some("thread"), Some("turn"))
                    .await
                    .unwrap();
            }
            assert_eq!(
                conversation_composer_options(
                    State(state.clone()),
                    Path("bot".into()),
                    Query(ComposerOptionsQuery {
                        queued_message_id: Some(id)
                    })
                )
                .await
                .status(),
                StatusCode::NOT_FOUND
            );
        }
        state.app_server.lock().await.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn queued_settings_edit_is_revision_checked_and_cannot_change_started_work() {
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        state
            .store
            .ensure_conversation_metadata("bot", "bot", "Bot", "now")
            .await
            .unwrap();
        let mut bot = state.store.bot("bot").await.unwrap().unwrap();
        bot.approval_mode = Some("approve-for-me".into());
        state
            .store
            .update_managed_bot(&bot, [true; 3])
            .await
            .unwrap();
        let MessageInsert::Inserted(message) = state
            .store
            .insert_dispatch_message("owner", "settings", "work", "hash", "bot", &[], "now", true)
            .await
            .unwrap()
        else {
            panic!()
        };
        let response = list(State(state.clone()), Path("bot".into())).await;
        let bytes = to_bytes(response.into_body(), 65536).await.unwrap();
        let queued: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            queued[0]["executionSettings"]["approvalMode"],
            "approve-for-me"
        );
        crate::permission_modes::tests::assert_http_contract("queueList", &queued);
        let request = || Edit {
            expected_revision: 1,
            settings: Some(Settings {
                model: Some("".into()),
                reasoning_effort: None,
                service_tier: None,
                permission_mode: None,
                approval_mode: None,
            }),
            body: None,
            cancel: None,
            expected_turn_id: None,
        };
        assert_eq!(
            edit(
                State(state.clone()),
                Path(("bot".into(), message.id.clone())),
                Json(request())
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            edit(
                State(state.clone()),
                Path(("bot".into(), message.id.clone())),
                Json(request())
            )
            .await
            .status(),
            StatusCode::CONFLICT
        );
        state
            .store
            .update_message_delivery(&message.id, "streaming", Some("thread"), Some("turn"))
            .await
            .unwrap();
        let mut next = request();
        next.expected_revision = 2;
        assert_eq!(
            edit(
                State(state.clone()),
                Path(("bot".into(), message.id)),
                Json(next)
            )
            .await
            .status(),
            StatusCode::CONFLICT
        );
    }

    #[tokio::test]
    async fn durable_guide_dispatches_once_and_stale_guide_preserves_text() {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        let MessageInsert::Inserted(active) = state
            .store
            .insert_message("owner", "active", "work", "hash", "bot", "now")
            .await
            .unwrap()
        else {
            panic!("active")
        };
        state
            .store
            .update_message_delivery(&active.id, "streaming", Some("thread"), Some("turn"))
            .await
            .unwrap();
        let MessageInsert::Inserted(guide) = state
            .store
            .insert_guide_message(
                "owner",
                "guide",
                "change direction",
                "hash2",
                "bot",
                &[],
                "now",
                "turn",
            )
            .await
            .unwrap()
        else {
            panic!("guide")
        };
        state.store.recover_dispatch_claims().await.unwrap();
        assert_eq!(state.store.pending_guides().await.unwrap().len(), 1);
        assert_eq!(
            crate::dispatch_guide(state.clone(), guide.clone(), "turn".into())
                .await
                .status(),
            StatusCode::ACCEPTED
        );
        assert_eq!(
            crate::dispatch_guide(state.clone(), guide.clone(), "turn".into())
                .await
                .status(),
            StatusCode::CONFLICT
        );
        let requests = std::fs::read_to_string(dir.path().join("requests")).unwrap();
        assert_eq!(requests.lines().filter(|s| *s == "turn/steer").count(), 1);
        assert_eq!(requests.lines().filter(|s| *s == "turn/start").count(), 0);
        let MessageInsert::Inserted(stale) = state
            .store
            .insert_guide_message(
                "owner",
                "stale",
                "keep these words",
                "hash3",
                "bot",
                &[],
                "now",
                "old-turn",
            )
            .await
            .unwrap()
        else {
            panic!("stale")
        };
        assert_eq!(
            crate::dispatch_guide(state.clone(), stale.clone(), "old-turn".into())
                .await
                .status(),
            StatusCode::CONFLICT
        );
        let saved = state.store.message_by_id(&stale.id).await.unwrap().unwrap();
        assert_eq!(saved.body, "keep these words");
        assert_eq!(saved.state, "failed");
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
