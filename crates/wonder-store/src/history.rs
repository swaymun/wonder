//! Indexed local history, independent of runtime I/O and replay retention.
use super::*;
use wonder_api::DeliveryState;

#[derive(Clone, Debug)]
pub struct HistoryCursor {
    pub sort_ms: i64,
    pub sequence: i64,
}

impl Store {
    /// The same selected directory used for Bot execution, with legacy fallback.
    pub async fn conversation_execution_directory(
        &self,
        conversation: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT COALESCE(working_directory, workspace_path) FROM bots WHERE id = COALESCE((SELECT bot_id FROM conversation_metadata WHERE id = ?), ?)")
            .bind(conversation).bind(conversation.strip_prefix("automation:").unwrap_or(conversation))
            .fetch_optional(&self.pool).await
    }

    pub async fn needs_file_change_repair(
        &self,
        conversation: &str,
        now: i64,
    ) -> Result<bool, sqlx::Error> {
        let row = sqlx::query("SELECT file_change_version,state,updated_at_ms FROM history_hydration WHERE conversation_id=?")
            .bind(conversation).fetch_optional(&self.pool).await?;
        Ok(row.is_none_or(|row| {
            row.get::<i64, _>("file_change_version") == 0
                && row.get::<i64, _>("updated_at_ms") < now - 60_000
        }))
    }

    pub async fn committed_conversation_snapshot(
        &self,
        host_epoch: &str,
        conversation_id: &str,
    ) -> Result<Option<CommittedConversationSnapshot>, sqlx::Error> {
        self.conversation_history_page(host_epoch, conversation_id, None, 100)
            .await
    }
    pub async fn conversation_history_page(
        &self,
        host_epoch: &str,
        conversation_id: &str,
        before: Option<&HistoryCursor>,
        limit: u32,
    ) -> Result<Option<CommittedConversationSnapshot>, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        // This first read pins the WAL snapshot; every projection below shares it.
        let sequence: i64 = sqlx::query_scalar(
            "SELECT last_sequence FROM sync_state WHERE singleton = 1 AND host_epoch = ?",
        )
        .bind(host_epoch)
        .fetch_one(&mut *tx)
        .await?;
        let workspace_path: Option<String> = sqlx::query_scalar("SELECT COALESCE(working_directory, workspace_path) FROM bots WHERE id = COALESCE((SELECT bot_id FROM conversation_metadata WHERE id = ?), ?)")
            .bind(conversation_id).bind(conversation_id.strip_prefix("automation:").unwrap_or(conversation_id))
            .fetch_optional(&mut *tx).await?;
        let Some(workspace_path) = workspace_path else {
            return Ok(None);
        };
        let before_ms = before.map_or(i64::MAX, |c| c.sort_ms);
        let before_sequence = before.map_or(i64::MAX, |c| c.sequence);
        let limit = limit.clamp(1, 100);
        let mut page = sqlx::query("SELECT sequence, sort_ms FROM history_entries WHERE conversation_id = ? AND (sort_ms, sequence) < (?, ?) ORDER BY sort_ms DESC, sequence DESC LIMIT ?")
            .bind(conversation_id).bind(before_ms).bind(before_sequence).bind(i64::from(limit) + 1)
            .fetch_all(&mut *tx).await?;
        let more = page.len() > limit as usize;
        page.truncate(limit as usize);
        let next_cursor = if more {
            page.last().map(|row| HistoryCursor {
                sort_ms: row.get("sort_ms"),
                sequence: row.get("sequence"),
            })
        } else {
            None
        };
        let sequences = serde_json::to_string(
            &page
                .iter()
                .map(|row| row.get::<i64, _>("sequence"))
                .collect::<Vec<_>>(),
        )
        .unwrap();
        let rows = sqlx::query("SELECT m.* FROM history_entries h JOIN messages m ON m.id = h.source_id WHERE h.source = 'message' AND h.sequence IN (SELECT value FROM json_each(?))")
            .bind(&sequences)
            .fetch_all(&mut *tx)
            .await?;
        let mut messages = rows.iter().map(stored_message).collect::<Vec<_>>();
        messages.sort_by(|a, b| {
            compare_timestamps(&a.created_at, &b.created_at).then_with(|| a.id.cmp(&b.id))
        });
        let rows = sqlx::query(
            "SELECT m.* FROM history_entries h JOIN assistant_messages m ON m.id = h.source_id WHERE h.source = 'assistant' AND h.sequence IN (SELECT value FROM json_each(?)) ORDER BY m.created_at, m.id",
        )
        .bind(&sequences)
        .fetch_all(&mut *tx)
        .await?;
        let assistant_messages = rows
            .iter()
            .map(stored_assistant_message)
            .collect::<Vec<_>>();
        let rows = sqlx::query("SELECT a.message_id, a.file_id FROM message_attachments a JOIN messages m ON m.id = a.message_id WHERE m.id IN (SELECT source_id FROM history_entries WHERE source='message' AND sequence IN (SELECT value FROM json_each(?))) ORDER BY a.file_id")
            .bind(&sequences).fetch_all(&mut *tx).await?;
        let mut attachment_ids = HashMap::<String, Vec<String>>::new();
        for row in rows {
            attachment_ids
                .entry(row.get("message_id"))
                .or_default()
                .push(row.get("file_id"));
        }
        let codex_thread_id =
            sqlx::query_scalar("SELECT codex_thread_id FROM conversations WHERE id = ?")
                .bind(conversation_id)
                .fetch_optional(&mut *tx)
                .await?;
        let rows = sqlx::query("SELECT payload_json FROM history_entries WHERE source = 'event' AND sequence IN (SELECT value FROM json_each(?)) ORDER BY sort_ms, sequence")
            .bind(&sequences)
            .fetch_all(&mut *tx)
            .await?;
        let mut events = Vec::new();
        for row in rows {
            let event: HostEventEnvelope =
                serde_json::from_str(&row.get::<String, _>("payload_json"))
                    .map_err(|e| sqlx::Error::Decode(Box::new(e)))?;
            if event.conversation_id.as_deref() == Some(conversation_id) {
                events.push(event);
            }
        }
        // Item pagination must not paginate away the status of a represented
        // turn. Fetch its two durable boundaries by indexed identity, in this
        // same WAL snapshot, without adding other turns or changing the cursor.
        let turns =
            messages
                .iter()
                .filter_map(|message| {
                    Some((
                        message.codex_thread_id.as_deref()?,
                        message.codex_turn_id.as_deref()?,
                    ))
                })
                .chain(assistant_messages.iter().map(|message| {
                    (
                        message.codex_thread_id.as_str(),
                        message.codex_turn_id.as_str(),
                    )
                }))
                .chain(events.iter().filter_map(|event| {
                    Some((event.thread_id.as_deref()?, event.turn_id.as_deref()?))
                }))
                .collect::<std::collections::HashSet<_>>();
        let keys = turns
            .iter()
            .flat_map(|(thread, turn)| {
                ["work-start", "work-end"]
                    .map(|boundary| format!("{conversation_id}:{thread}:{turn}:{boundary}"))
            })
            .collect::<Vec<_>>();
        if !keys.is_empty() {
            let rows = sqlx::query("SELECT payload_json FROM history_entries WHERE source='event' AND source_id IN (SELECT value FROM json_each(?)) AND conversation_id=?")
                .bind(serde_json::to_string(&keys).unwrap())
                .bind(conversation_id)
                .fetch_all(&mut *tx)
                .await?;
            let mut seen = events
                .iter()
                .map(|event| event.event_id.clone())
                .collect::<std::collections::HashSet<_>>();
            for row in rows {
                let event: HostEventEnvelope =
                    serde_json::from_str(&row.get::<String, _>("payload_json"))
                        .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
                if matches!(event.event, WonderEvent::MessageState { .. })
                    && seen.insert(event.event_id.clone())
                {
                    events.push(event);
                }
            }
            events.sort_by(|left, right| {
                compare_timestamps(&left.occurred_at, &right.occurred_at)
                    .then_with(|| left.sequence.cmp(&right.sequence))
            });
        }
        tx.commit().await?;
        Ok(Some(CommittedConversationSnapshot {
            workspace_path,
            last_sequence: sequence as u64,
            messages,
            assistant_messages,
            attachment_ids,
            codex_thread_id,
            events,
            next_cursor,
        }))
    }
    pub(super) async fn save_history_event(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        event: &HostEventEnvelope,
    ) -> Result<(), sqlx::Error> {
        let Some(conversation) = &event.conversation_id else {
            return Ok(());
        };
        // Text has its own durable message projection. Keep typed activities once
        // per item so pruning replay cannot erase tool results from the transcript.
        let key = match &event.event {
            WonderEvent::Activity {
                category,
                detail: Some(detail),
                ..
            } if category == "thread_item_upsert" => {
                let value: serde_json::Value =
                    serde_json::from_str(detail).map_err(|e| sqlx::Error::Decode(Box::new(e)))?;
                let item_type = value["item"]["type"].as_str().unwrap_or("");
                // Assistant text does not retain phase or other typed metadata.
                // Its lifecycle event must survive even when the text arrived first.
                let existing = if item_type == "userMessage" {
                    sqlx::query_scalar::<_,i64>("SELECT COUNT(*) FROM messages WHERE conversation_id=? AND client_message_id=?")
                        .bind(conversation).bind(value["item"]["clientId"].as_str().unwrap_or("")).fetch_one(&mut **tx).await? > 0
                } else {
                    false
                };
                if existing {
                    return Ok(());
                }
                format!(
                    "{}:{}:{}:{}",
                    conversation,
                    event.thread_id.as_deref().unwrap_or(""),
                    value["turnId"].as_str().unwrap_or(""),
                    value["itemId"].as_str().unwrap_or(&event.event_id)
                )
            }
            WonderEvent::MessageState { state } if event.turn_id.is_some() => {
                let boundary = match state {
                    DeliveryState::AcceptedByCodex | DeliveryState::Streaming => "work-start",
                    DeliveryState::Completed
                    | DeliveryState::Failed
                    | DeliveryState::Interrupted => "work-end",
                    _ => return Ok(()),
                };
                format!(
                    "{}:{}:{}:{}",
                    conversation,
                    event.thread_id.as_deref().unwrap_or(""),
                    event.turn_id.as_deref().unwrap_or(""),
                    boundary
                )
            }
            WonderEvent::ComputerUseScreenshot { .. } => event.event_id.clone(),
            _ => return Ok(()),
        };
        let history_timestamp = if let WonderEvent::Activity {
            detail: Some(detail),
            ..
        } = &event.event
        {
            let value: serde_json::Value =
                serde_json::from_str(detail).map_err(|e| sqlx::Error::Decode(Box::new(e)))?;
            value["item"]["createdAt"].as_str().map(str::to_owned)
        } else {
            None
        };
        let previous: Option<String> = sqlx::query_scalar(
            "SELECT payload_json FROM history_entries WHERE source='event' AND source_id=?",
        )
        .bind(&key)
        .fetch_optional(&mut **tx)
        .await?;
        let previous =
            previous.and_then(|payload| serde_json::from_str::<HostEventEnvelope>(&payload).ok());
        let first_observed = previous.as_ref().map(|saved| saved.occurred_at.clone());
        let timestamp = first_observed
            .or(history_timestamp)
            .unwrap_or_else(|| event.occurred_at.clone());
        let mut historical = event.clone();
        historical.occurred_at = timestamp.clone();
        let mut refresh = if let WonderEvent::Activity {
            detail: Some(detail),
            ..
        } = &event.event
        {
            serde_json::from_str::<serde_json::Value>(detail)
                .ok()
                .is_some_and(|v| v["historyRefresh"] == true)
        } else {
            false
        };
        // Refresh normally fills gaps without replacing live observations. An
        // older generated-image record may instead contain truncated base64.
        // Enrich only that result with the retained attachment, preserving the
        // original lifecycle, identity and timeline position.
        if refresh {
            if let Some(mut saved) = previous {
                if let (
                    WonderEvent::Activity {
                        detail: Some(old), ..
                    },
                    WonderEvent::Activity {
                        detail: Some(new), ..
                    },
                ) = (&mut saved.event, &event.event)
                {
                    let mut old_value: serde_json::Value =
                        serde_json::from_str(old).map_err(|e| sqlx::Error::Decode(Box::new(e)))?;
                    let new_value: serde_json::Value =
                        serde_json::from_str(new).map_err(|e| sqlx::Error::Decode(Box::new(e)))?;
                    if old_value["item"]["type"] == "fileChange"
                        && new_value["item"]["type"] == "fileChange"
                        && old_value["item"]["fileChangeVersion"] != 1
                        && new_value["item"]["fileChangeVersion"] == 1
                    {
                        // Repair presentation fields only. Keep the original
                        // item lifecycle, timestamp and cursor identity.
                        for key in [
                            "paths",
                            "diffs",
                            "additions",
                            "deletions",
                            "fileChangeVersion",
                        ] {
                            old_value["item"][key] = new_value["item"][key].clone();
                        }
                        *old = old_value.to_string();
                        refresh = false;
                    }
                    if old_value["item"]["type"] == "imageGeneration"
                        && new_value["item"]["type"] == "imageGeneration"
                        && (old_value["item"]["result"].is_string()
                            || old_value["item"]["result"].is_null())
                        && new_value["item"]["result"]["content"][0]["type"] == "wonderArtifact"
                    {
                        old_value["item"]["result"] = new_value["item"]["result"].clone();
                        old_value["item"]
                            .as_object_mut()
                            .unwrap()
                            .remove("savedPath");
                        *old = old_value.to_string();
                        refresh = false;
                    }
                }
                if !refresh {
                    historical = saved;
                }
            }
        }
        let payload =
            serde_json::to_string(&historical).map_err(|e| sqlx::Error::Encode(Box::new(e)))?;
        sqlx::query("INSERT INTO history_entries(conversation_id,source,source_id,sort_ms,payload_json) VALUES (?,'event',?,CASE WHEN ? NOT GLOB '*[^0-9]*' THEN CAST(? AS INTEGER) ELSE COALESCE(CAST((julianday(?) - 2440587.5)*86400000 AS INTEGER),0) END,?) ON CONFLICT(source,source_id) DO UPDATE SET payload_json=excluded.payload_json WHERE ? = 0")
            .bind(conversation).bind(key).bind(&timestamp).bind(&timestamp).bind(&timestamp).bind(payload).bind(refresh).execute(&mut **tx).await?;
        Ok(())
    }
}

impl Store {
    pub async fn claim_history_refresh(
        &self,
        conversation: &str,
        token: &str,
        now: i64,
    ) -> Result<bool, sqlx::Error> {
        let result = sqlx::query("INSERT INTO history_hydration(conversation_id,state,updated_at_ms,detail,token) VALUES (?,'refreshing',?,NULL,?) ON CONFLICT(conversation_id) DO UPDATE SET state='refreshing', updated_at_ms=excluded.updated_at_ms, detail=NULL, token=excluded.token WHERE history_hydration.state != 'refreshing' OR history_hydration.updated_at_ms < ?")
            .bind(conversation).bind(now).bind(token).bind(now - 60_000).execute(&self.pool).await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn update_history_refresh(
        &self,
        conversation: &str,
        token: &str,
        state: &str,
        now: i64,
        detail: Option<&str>,
    ) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE history_hydration SET file_change_version=CASE WHEN ?='completed' THEN 1 ELSE file_change_version END,state=?,updated_at_ms=?,detail=? WHERE conversation_id=? AND token=?")
            .bind(state).bind(state).bind(now).bind(detail).bind(conversation).bind(token).execute(&self.pool).await?.rows_affected() == 1)
    }

    pub async fn history_refresh_status(
        &self,
        conversation: &str,
        now: i64,
    ) -> Result<serde_json::Value, sqlx::Error> {
        let row = sqlx::query(
            "SELECT state,updated_at_ms,detail FROM history_hydration WHERE conversation_id=?",
        )
        .bind(conversation)
        .fetch_optional(&self.pool)
        .await?;
        Ok(match row {
            None => serde_json::json!({"state":"idle","detail":null}),
            Some(row) => {
                let state: String = row.get("state");
                let stale =
                    state == "refreshing" && row.get::<i64, _>("updated_at_ms") < now - 60_000;
                serde_json::json!({"state":if stale { "failed" } else { &state }, "detail": if stale { Some("History refresh stopped. Try refreshing again.".to_owned()) } else { row.get::<Option<String>,_>("detail") }})
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[tokio::test]
    async fn image_refresh_enriches_legacy_result_without_replacing_live_history() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let original = serde_json::json!({"turnId":"turn","itemId":"image","state":"failed",
            "item":{"id":"image","type":"imageGeneration","status":"failed","result":"truncated base64",
                "savedPath":"/private/image.png","failure":"original failure"}});
        let mut event: HostEventEnvelope = serde_json::from_value(serde_json::json!({
            "eventId":"original","hostEpoch":"epoch","sequence":1,"occurredAt":"1700000000001",
            "conversationId":"chat","threadId":"thread","turnId":"turn","itemId":"image",
            "event":{"type":"activity","data":{"category":"thread_item_upsert","state":"updated","detail":original.to_string()}}
        })).unwrap();
        let mut tx = store.pool.begin().await.unwrap();
        store.save_history_event(&mut tx, &event).await.unwrap();
        tx.commit().await.unwrap();
        let before: (i64, i64) = sqlx::query_as("SELECT sequence,sort_ms FROM history_entries")
            .fetch_one(&store.pool)
            .await
            .unwrap();

        event.event_id = "refreshed".into();
        event.occurred_at = "1800000000000".into();
        let result = serde_json::json!({"content":[{"type":"wonderArtifact","file":{"id":"verified-file"}}]});
        let mut refreshed = original.clone();
        refreshed["historyRefresh"] = true.into();
        refreshed["state"] = "completed".into();
        refreshed["item"]["status"] = "completed".into();
        refreshed["item"]["failure"] = serde_json::Value::Null;
        refreshed["item"]["result"] = result.clone();
        if let WonderEvent::Activity { detail, .. } = &mut event.event {
            *detail = Some(refreshed.to_string());
        }
        for _ in 0..2 {
            let mut tx = store.pool.begin().await.unwrap();
            store.save_history_event(&mut tx, &event).await.unwrap();
            tx.commit().await.unwrap();
        }
        let rows: Vec<(i64, i64, String)> =
            sqlx::query_as("SELECT sequence,sort_ms,payload_json FROM history_entries")
                .fetch_all(&store.pool)
                .await
                .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!((rows[0].0, rows[0].1), before);
        let saved: HostEventEnvelope = serde_json::from_str(&rows[0].2).unwrap();
        assert_eq!(saved.event_id, "original");
        assert_eq!(saved.occurred_at, "1700000000001");
        let WonderEvent::Activity {
            detail: Some(detail),
            ..
        } = saved.event
        else {
            panic!("Expected image activity")
        };
        let mut expected = original;
        expected["item"]["result"] = result;
        expected["item"]
            .as_object_mut()
            .unwrap()
            .remove("savedPath");
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&detail).unwrap(),
            expected
        );
    }

    #[tokio::test]
    async fn ten_thousand_items_paginate_without_gaps_across_restarts() {
        let dir = tempfile::tempdir().unwrap();
        let url = format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("history.db").display()
        );
        let store = Store::connect(&url).await.unwrap();
        store
            .upsert_owner_device("owner", "Owner", "{}", "now")
            .await
            .unwrap();
        store
            .upsert_bot(
                "chat",
                "Bot",
                "Assistant",
                "Help",
                "/tmp",
                "test",
                None,
                None,
                "now",
            )
            .await
            .unwrap();
        store.start_event_epoch("epoch").await.unwrap();
        sqlx::query("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO messages(id,device_id,client_message_id,body,body_sha256,conversation_id,state,created_at) SELECT printf('message-%05d',x),'owner',printf('client-%05d',x),printf('%01024d',x),'hash','chat','completed',CAST(1700000000000+x/3 AS TEXT) FROM n").execute(&store.pool).await.unwrap();
        let cold = Instant::now();
        store
            .conversation_history_page("epoch", "chat", None, 100)
            .await
            .unwrap();
        let cold_ms = cold.elapsed().as_secs_f64() * 1000.0;
        let mut samples = vec![];
        for i in 0..105 {
            let start = Instant::now();
            let page = store
                .conversation_history_page("epoch", "chat", None, 100)
                .await
                .unwrap()
                .unwrap();
            assert_eq!(page.messages.len(), 100);
            if i >= 5 {
                samples.push(start.elapsed().as_secs_f64() * 1000.0);
            }
        }
        eprintln!("HISTORY_PAGE_COLD_MS={cold_ms}; HISTORY_PAGE_SAMPLES_MS={samples:?}");
        samples.sort_by(f64::total_cmp);
        assert!(samples[94] <= 200.0, "history p95 {}", samples[94]);
        let plan: Vec<String> = sqlx::query("EXPLAIN QUERY PLAN SELECT sequence,sort_ms FROM history_entries WHERE conversation_id='chat' AND (sort_ms,sequence)<(1700000003000,9999) ORDER BY sort_ms DESC,sequence DESC LIMIT 101").fetch_all(&store.pool).await.unwrap().iter().map(|r|r.get::<String,_>("detail")).collect();
        assert!(
            plan.iter().any(|s| s.contains("history_conversation_page")),
            "{plan:?}"
        );
        assert!(!plan.iter().any(|s| s.contains("TEMP B-TREE")), "{plan:?}");
        let mut before = None;
        let mut ids = std::collections::HashSet::new();
        for page_index in 0..100 {
            let page = store
                .conversation_history_page("epoch", "chat", before.as_ref(), 100)
                .await
                .unwrap()
                .unwrap();
            for message in page.messages {
                assert!(ids.insert(message.id));
            }
            before = page.next_cursor;
            if page_index == 0 {
                store
                    .insert_message("owner", "new", "new", "hash", "chat", "1800000000000")
                    .await
                    .unwrap();
            }
            if page_index < 99 {
                assert!(before.is_some());
            }
        }
        assert!(before.is_none());
        assert_eq!(ids.len(), 10000);
        for i in 0..10 {
            let reopened = Store::connect(&url).await.unwrap();
            reopened
                .start_event_epoch(&format!("restart-{i}"))
                .await
                .unwrap();
            assert_eq!(
                reopened
                    .conversation_history_page(&format!("restart-{i}"), "chat", None, 100)
                    .await
                    .unwrap()
                    .unwrap()
                    .messages
                    .len(),
                100
            );
        }
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM history_entries")
                .fetch_one(&store.pool)
                .await
                .unwrap(),
            10001
        );
        eprintln!(
            "HISTORY_STORAGE={:?}; WAL_BYTES={}",
            store.replay_storage_usage().await.unwrap(),
            std::fs::metadata(dir.path().join("history.db-wal"))
                .map(|m| m.len())
                .unwrap_or(0)
        );
    }

    #[tokio::test]
    async fn upgrade_and_replay_expiry_preserve_typed_transcripts() {
        let dir = tempfile::tempdir().unwrap();
        let url = format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("upgrade.db").display()
        );
        let pool = SqlitePool::connect(&url).await.unwrap();
        let mut prior = sqlx::migrate!();
        prior.migrations = std::borrow::Cow::Owned(
            prior
                .migrations
                .iter()
                .filter(|m| m.version < 36)
                .cloned()
                .collect(),
        );
        prior.run(&pool).await.unwrap();
        let old = Store { pool };
        old.upsert_owner_device("owner", "Owner", "{}", "now")
            .await
            .unwrap();
        old.upsert_bot(
            "chat",
            "Bot",
            "Assistant",
            "Help",
            "/tmp",
            "test",
            None,
            None,
            "now",
        )
        .await
        .unwrap();
        old.start_event_epoch("epoch").await.unwrap();
        old.insert_message(
            "owner",
            "pending",
            "unsent",
            "hash",
            "chat",
            "1700000000000",
        )
        .await
        .unwrap();
        let event=HostEventEnvelope {event_id:"tool".into(),host_epoch:"epoch".into(),sequence:1,occurred_at:"1700000000001".into(),conversation_id:Some("chat".into()),thread_id:Some("thread".into()),turn_id:Some("turn".into()),item_id:Some("command".into()),request_id:None,device_id:None,message_id:None,approval_id:None,event:WonderEvent::Activity {category:"thread_item_upsert".into(),state:"updated".into(),detail:Some(serde_json::json!({"itemId":"command","turnId":"turn","state":"completed","item":{"id":"command","type":"commandExecution","command":"echo saved","status":"completed"}}).to_string())}};
        sqlx::query("INSERT INTO events(event_id,host_epoch,sequence,occurred_at,payload_json) VALUES ('tool','epoch',1,'1700000000001',?)").bind(serde_json::to_string(&event).unwrap()).execute(&old.pool).await.unwrap();
        old.pool.close().await;
        let store = Store::connect(&url).await.unwrap();
        let page = store
            .committed_conversation_snapshot("epoch", "chat")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(page.messages[0].body, "unsent");
        assert_eq!(page.events.len(), 1);
        sqlx::query("UPDATE replay_retention SET retained_at=0")
            .execute(&store.pool)
            .await
            .unwrap();
        store.prune_replay().await.unwrap();
        assert_eq!(
            store
                .committed_conversation_snapshot("epoch", "chat")
                .await
                .unwrap()
                .unwrap()
                .events
                .len(),
            1
        );
        let mut refresh = event.clone();
        if let WonderEvent::Activity { detail, .. } = &mut refresh.event {
            let mut payload: serde_json::Value =
                serde_json::from_str(detail.as_ref().unwrap()).unwrap();
            payload["historyRefresh"] = true.into();
            payload["item"]["command"] = "stale".into();
            *detail = Some(payload.to_string());
        }
        let mut tx = store.pool.begin().await.unwrap();
        store.save_history_event(&mut tx, &refresh).await.unwrap();
        tx.commit().await.unwrap();
        let page = store
            .committed_conversation_snapshot("epoch", "chat")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(page.events.len(), 1);
        assert!(!serde_json::to_string(&page.events)
            .unwrap()
            .contains("stale"));
        let mut imported = event.clone();
        imported.item_id = Some("imported".into());
        imported.turn_id = Some("import-turn".into());
        imported.event=WonderEvent::Activity {category:"thread_item_upsert".into(),state:"updated".into(),detail:Some(serde_json::json!({"historyRefresh":true,"turnId":"import-turn","itemId":"imported","item":{"type":"agentMessage","id":"imported","text":"imported text","phase":"commentary"}}).to_string())};
        let mut tx = store.pool.begin().await.unwrap();
        store.save_history_event(&mut tx, &imported).await.unwrap();
        tx.commit().await.unwrap();
        store
            .complete_assistant_message(
                "chat",
                "thread",
                "import-turn",
                "imported",
                "live text",
                "1700000000002",
            )
            .await
            .unwrap();
        let page = store
            .committed_conversation_snapshot("epoch", "chat")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            page.events.len(),
            2,
            "canonical text preserves typed phase metadata"
        );
        assert_eq!(page.assistant_messages.len(), 1);
        assert_eq!(page.assistant_messages[0].text, "live text");
        // The reverse order must retain metadata too: text exists before a late event.
        let mut tx = store.pool.begin().await.unwrap();
        store.save_history_event(&mut tx, &imported).await.unwrap();
        tx.commit().await.unwrap();
        let page = store
            .committed_conversation_snapshot("epoch", "chat")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(page.events.len(), 2);
        assert!(serde_json::to_string(&page.events)
            .unwrap()
            .contains("commentary"));

        // Streaming updates retain the first observed start, independently of replay retention.
        let mut tx = store.pool.begin().await.unwrap();
        let mut boundary = event.clone();
        boundary.item_id = None;
        for (timestamp, state) in [
            ("1700000000100", DeliveryState::AcceptedByCodex),
            ("1700000000200", DeliveryState::Streaming),
            ("1700000001100", DeliveryState::Completed),
        ] {
            boundary.occurred_at = timestamp.into();
            boundary.event = WonderEvent::MessageState { state };
            store.save_history_event(&mut tx, &boundary).await.unwrap();
        }
        tx.commit().await.unwrap();
        store.prune_replay().await.unwrap();
        let page = store
            .committed_conversation_snapshot("epoch", "chat")
            .await
            .unwrap()
            .unwrap();
        let times: Vec<_> = page
            .events
            .iter()
            .filter(|event| matches!(event.event, WonderEvent::MessageState { .. }))
            .map(|event| event.occurred_at.as_str())
            .collect();
        assert_eq!(times, ["1700000000100", "1700000001100"]);

        store.reset_workspace("owner", "now").await.unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM history_entries")
                .fetch_one(&store.pool)
                .await
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn stale_refresh_can_be_retried_without_cleanup_and_old_job_cannot_finish_new_job() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        assert!(store
            .claim_history_refresh("chat", "old", 1000)
            .await
            .unwrap());
        assert!(!store
            .claim_history_refresh("chat", "other", 1001)
            .await
            .unwrap());
        assert_eq!(
            store.history_refresh_status("chat", 62000).await.unwrap()["state"],
            "failed"
        );
        assert!(store
            .claim_history_refresh("chat", "new", 62000)
            .await
            .unwrap());
        assert!(!store
            .update_history_refresh("chat", "old", "completed", 62001, None)
            .await
            .unwrap());
        assert!(store
            .update_history_refresh("chat", "new", "completed", 62001, None)
            .await
            .unwrap());
    }
}
