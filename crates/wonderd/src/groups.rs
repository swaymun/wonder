use crate::*;

pub async fn tick(
    state: &AppState,
    tasks: &mut tokio::task::JoinSet<()>,
) -> Result<(), sqlx::Error> {
    state
        .store
        .refresh_assignment_execution_states(now_ms() as i64)
        .await?;
    state.store.reconcile_assignment_group_runs().await?;
    // A bounded number of parents; the existing semaphore also bounds workers.
    if tasks.len() >= 4 {
        return Ok(());
    }
    for run in state.store.pending_group_runs().await? {
        if tasks.len() >= 4 {
            break;
        }
        let assignment = state.store.assignment_for_parent(&run.parent.id).await?;
        if let Some(a) = assignment.as_ref() {
            if !crate::project_assignments::ready(state, a)
                .await
                .unwrap_or(false)
            {
                continue;
            }
        }
        if !state.store.claim_group_run(&run.parent.id).await? {
            continue;
        }
        let state = state.clone();
        tasks.spawn(async move {
            let mut assignment = assignment;
            if let Some(a) = assignment.as_mut() {
                if let Err(error) = crate::project_assignments::prepare(&state, a).await {
                    if a.state == "cancelled" {
                        return;
                    }
                    let _ = state
                        .store
                        .transition_assignment(
                            &a.id,
                            &a.state,
                            "failed",
                            Some(&error),
                            &now_ms().to_string(),
                        )
                        .await;
                    let _ = state
                        .store
                        .finish_group_run(&run.parent.id, None, &now_ms().to_string())
                        .await;
                    return;
                }
            }
            let route = if let Some(a) = assignment.as_ref() {
                Ok(ChannelRoute::Direct(a.bot_id.clone()))
            } else if group_collaboration::enabled(&state, &run.channel.id).await {
                Ok(ChannelRoute::Broadcast)
            } else {
                resolve_channel_route(&run.parent.body, &run.channel.members)
            };
            let target = match route {
                Ok(ChannelRoute::Broadcast) => None,
                Ok(ChannelRoute::Direct(id)) => Some(id),
                Err(_) => {
                    let _ = state
                        .store
                        .finish_group_run(&run.parent.id, None, &now_ms().to_string())
                        .await;
                    return;
                }
            };
            let collaboration_id = run.channel.id.clone();
            let mut output = if assignment.is_none()
                && group_collaboration::enabled(&state, &run.channel.id).await
            {
                group_collaboration::run(state.clone(), run.channel, run.parent.clone()).await
            } else {
                orchestrate_channel_message(
                    state.clone(),
                    run.channel,
                    run.parent.clone(),
                    if let Some(a) = assignment.as_ref() {
                        crate::project_assignments::instruction(a)
                    } else {
                        run.parent.body.clone()
                    },
                    target,
                )
                .await
            };
            if let Some(a) = assignment.as_ref() {
                if let Err(error) =
                    crate::project_assignments::finish(&state, a, output.as_deref()).await
                {
                    if let Ok(Some(current)) = state.store.project_assignment(&a.id).await {
                        if !matches!(
                            current.state.as_str(),
                            "working" | "uncertain" | "awaiting_input"
                        ) {
                            return;
                        }
                        let _ = state
                            .store
                            .transition_assignment(
                                &a.id,
                                &current.state,
                                "failed",
                                Some(&error),
                                &now_ms().to_string(),
                            )
                            .await;
                    }
                }
                // A completed turn may have a typed pending question or active
                // continuation. Keep the durable parent eligible for reconciliation.
                if let Ok(Some(current)) = state.store.project_assignment(&a.id).await {
                    if matches!(
                        current.state.as_str(),
                        "working" | "awaiting_input" | "uncertain"
                    ) {
                        output = None;
                    }
                }
            }
            if group_collaboration::enabled(&state, &collaboration_id).await {
                group_collaboration::settle(&state, &run.parent).await;
                return;
            }
            if state
                .store
                .finish_group_run(&run.parent.id, output.as_deref(), &now_ms().to_string())
                .await
                .is_ok()
            {
                publish_message_state(
                    &state,
                    &run.parent,
                    if output.is_some() {
                        DeliveryState::Completed
                    } else {
                        DeliveryState::Uncertain
                    },
                    None,
                    None,
                )
                .await;
            }
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn fixture() -> (tempfile::TempDir, AppState, wonder_store::GroupRun) {
        let (dir, state) = crate::ingestion::tests::fixture().await;
        state
            .store
            .upsert_bot(
                "worker",
                "Worker",
                "Assistant",
                "Help",
                dir.path().join("bot").to_str().unwrap(),
                "test",
                None,
                None,
                "1",
            )
            .await
            .unwrap();
        state
            .store
            .create_channel(
                "group",
                "group-chat",
                "Team",
                None,
                "bot",
                &[("bot", "coordinator"), ("worker", "worker")],
                "1",
            )
            .await
            .unwrap();
        let MessageInsert::Inserted(parent) = state
            .store
            .insert_message("owner", "parent", "hello", "hash", "group-chat", "1")
            .await
            .unwrap()
        else {
            panic!()
        };
        state
            .store
            .add_channel_message(NewChannelMessage {
                channel_id: "group",
                message_id: &parent.id,
                author_kind: "user",
                author_bot_id: None,
                phase: "user",
                created_at: "1",
                presentation_kind: "message",
                outcome: Some("completed"),
                retryable: false,
            })
            .await
            .unwrap();
        let run = state.store.pending_group_runs().await.unwrap().remove(0);
        (dir, state, run)
    }
    async fn child(state: &AppState, run: &wonder_store::GroupRun, completed: bool) {
        let conversation = format!("channel:group:worker:worker:message:{}", run.parent.id);
        state
            .store
            .create_conversation(&conversation, "worker", "Worker", "1")
            .await
            .unwrap();
        let client = deterministic_uuid(&format!("wonder-channel-worker:{}:worker", run.parent.id));
        let body="You are Worker in the Group Chat Team. Reply directly to the user in your own voice. Keep your answer concise and do not describe internal coordination.\n\nhello";
        let MessageInsert::Inserted(message) = state
            .store
            .insert_message(
                "owner",
                &client,
                body,
                &hex::encode(Sha256::digest(body.as_bytes())),
                &conversation,
                "2",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        state
            .store
            .update_message_delivery(
                &message.id,
                if completed { "completed" } else { "uncertain" },
                Some("worker-thread"),
                Some("worker-turn"),
            )
            .await
            .unwrap();
        if completed {
            state
                .store
                .complete_assistant_message(
                    &conversation,
                    "worker-thread",
                    "worker-turn",
                    "answer",
                    "Worker result",
                    "2",
                )
                .await
                .unwrap();
        }
    }
    #[tokio::test]
    async fn unknown_worker_blocks_synthesis_without_another_turn_start() {
        let (dir, state, run) = fixture().await;
        child(&state, &run, false).await;
        assert!(orchestrate_channel_message(
            state.clone(),
            run.channel,
            run.parent.clone(),
            run.parent.body.clone(),
            None
        )
        .await
        .is_none());
        let synthesis = deterministic_uuid(&format!("wonder-channel-synthesis:{}", run.parent.id));
        assert!(state
            .store
            .message_by_device_and_client_message_id("owner", &synthesis)
            .await
            .unwrap()
            .is_none());
        assert!(!std::fs::read_to_string(dir.path().join("requests"))
            .unwrap_or_default()
            .lines()
            .any(|line| line == "turn/start"));
        state.app_server.lock().await.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn completed_workers_and_synthesis_project_after_restart_without_execution() {
        let (dir, state, run) = fixture().await;
        child(&state, &run, true).await;
        let client = deterministic_uuid(&format!("wonder-channel-synthesis:{}", run.parent.id));
        let body="You are the coordinator Bot for channel Team. Synthesize the worker reports below into one clear answer to the user's request.\n\nUser request:\nhello\n\nWorker reports:\nWorker Bot Worker:\nWorker result";
        let MessageInsert::Inserted(message) = state
            .store
            .insert_message(
                "owner",
                &client,
                body,
                &hex::encode(Sha256::digest(body.as_bytes())),
                "group-chat",
                "3",
            )
            .await
            .unwrap()
        else {
            panic!()
        };
        state
            .store
            .update_message_delivery(
                &message.id,
                "completed",
                Some("coordinator-thread"),
                Some("correct-turn"),
            )
            .await
            .unwrap();
        state
            .store
            .complete_assistant_message(
                "group-chat",
                "coordinator-thread",
                "correct-turn",
                "answer",
                "Integrated result",
                "3",
            )
            .await
            .unwrap();
        state
            .store
            .complete_assistant_message(
                "group-chat",
                "coordinator-thread",
                "unrelated-turn",
                "other",
                "Unrelated newer answer",
                "4",
            )
            .await
            .unwrap();
        let output = orchestrate_channel_message(
            state.clone(),
            run.channel.clone(),
            run.parent.clone(),
            run.parent.body.clone(),
            None,
        )
        .await
        .unwrap();
        assert_eq!(
            state
                .store
                .message_by_id(&output)
                .await
                .unwrap()
                .unwrap()
                .body,
            "Integrated result"
        );
        let again = orchestrate_channel_message(
            state.clone(),
            run.channel,
            run.parent.clone(),
            run.parent.body.clone(),
            None,
        )
        .await
        .unwrap();
        assert_eq!(again, output);
        assert!(!std::fs::read_to_string(dir.path().join("requests"))
            .unwrap_or_default()
            .lines()
            .any(|line| line == "turn/start"));
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
