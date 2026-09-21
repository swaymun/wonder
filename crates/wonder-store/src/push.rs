use super::*;

#[derive(Debug)]
pub struct PushDelivery {
    pub id: String,
    pub registration_id: String,
    pub endpoint: String,
    pub sender_secret: String,
    pub route_id: String,
    pub kind: String,
    pub attempts: i64,
    pub preview_key: Option<String>,
    pub source_key: String,
    pub source_conversation: String,
    pub conversation_id: String,
}
#[derive(Debug)]
pub struct PushRevocation {
    pub id: String,
    pub endpoint: String,
    pub sender_secret: String,
}

#[derive(serde::Serialize)]
pub struct PushPreview {
    pub title: String,
    pub body: String,
}

// Bound UTF-8 bytes before encryption, including JSON's worst-case escaping.
fn excerpt(value: &str, budget: usize) -> String {
    let mut result = String::new();
    for ch in value
        .trim()
        .chars()
        .filter(|ch| !ch.is_control() || *ch == '\n')
    {
        if result.len() + ch.len_utf8() > budget {
            result.push('…');
            break;
        }
        result.push(ch);
    }
    result
}

fn question_text(value: &serde_json::Value) -> String {
    value
        .as_array()
        .into_iter()
        .flatten()
        .take(3)
        .filter_map(|q| {
            q.get("title")
                .or_else(|| q.get("question"))
                .and_then(|v| v.as_str())
        })
        .map(|v| excerpt(v, 300))
        .collect::<Vec<_>>()
        .join("\n")
}

impl Store {
    /// Resolve the exact triggering turn/request; never use another turn's latest reply.
    pub async fn push_preview(
        &self,
        delivery: &PushDelivery,
    ) -> Result<Option<PushPreview>, sqlx::Error> {
        let title: String=sqlx::query_scalar("SELECT COALESCE((SELECT name FROM channels WHERE conversation_id=?),(SELECT title FROM conversation_metadata WHERE id=?),'Wonder')")
            .bind(&delivery.conversation_id).bind(&delivery.conversation_id).fetch_one(&self.pool).await?;
        let (label, body) = if let Some(question) = delivery.source_key.strip_prefix("question:") {
            let value:Option<String>=sqlx::query_scalar("SELECT questions_json FROM async_questions WHERE id=? AND conversation_id=? AND state='pending' AND expires_at_ms>unixepoch('subsec')*1000")
                .bind(question).bind(&delivery.source_conversation).fetch_optional(&self.pool).await?;
            let Some(value) = value else {
                return Ok(None);
            };
            (
                "Question",
                question_text(&serde_json::from_str(&value).unwrap_or_default()),
            )
        } else {
            let payload: Option<String> =
                sqlx::query_scalar("SELECT payload_json FROM events WHERE event_id=?")
                    .bind(&delivery.source_key)
                    .fetch_optional(&self.pool)
                    .await?;
            let Some(event) =
                payload.and_then(|p| serde_json::from_str::<HostEventEnvelope>(&p).ok())
            else {
                return Ok(None);
            };
            if event.conversation_id.as_deref() != Some(&delivery.source_conversation) {
                return Ok(None);
            }
            match event.event {
                WonderEvent::ApprovalOpened { request_id } => {
                    let value:Option<String>=sqlx::query_scalar("SELECT params_json FROM approvals WHERE server_request_id=? AND thread_id=? AND turn_id=? AND state='pending'")
                        .bind(request_id).bind(event.thread_id.as_deref().unwrap_or("")).bind(event.turn_id.as_deref().unwrap_or("")).fetch_optional(&self.pool).await?;
                    let Some(value) = value else {
                        return Ok(None);
                    };
                    let params: serde_json::Value =
                        serde_json::from_str(&value).unwrap_or_default();
                    let questions = question_text(&params["questions"]);
                    if !questions.is_empty() {
                        ("Question", questions)
                    } else {
                        let mut parts = Vec::new();
                        for key in [
                            "message",
                            "reason",
                            "command",
                            "filePath",
                            "grantRoot",
                            "url",
                        ] {
                            if let Some(text) =
                                params[key].as_str().filter(|v| !v.trim().is_empty())
                            {
                                let text = excerpt(text, 600);
                                if !parts.contains(&text) {
                                    parts.push(text);
                                }
                            }
                        }
                        ("Approval requested", parts.join("\n"))
                    }
                }
                WonderEvent::MessageState {
                    state: wonder_api::DeliveryState::Completed,
                } => {
                    let text:Option<String>=sqlx::query_scalar("SELECT substr(text,1,1000) FROM assistant_messages WHERE conversation_id=? AND codex_thread_id=? AND codex_turn_id=? AND state='completed' AND trim(text)!='' ORDER BY created_at DESC,rowid DESC LIMIT 1")
                        .bind(&delivery.source_conversation).bind(event.thread_id.as_deref().unwrap_or("")).bind(event.turn_id.as_deref().unwrap_or("")).fetch_optional(&self.pool).await?;
                    // Group parents point to an explicit final output message.
                    let text = if text.is_some() {
                        text
                    } else {
                        sqlx::query_scalar("SELECT substr(a.body,1,1000) FROM group_runs g JOIN messages a ON a.id=g.output_message_id JOIN channel_messages cm ON cm.message_id=a.id AND cm.channel_id=g.channel_id WHERE g.parent_message_id=? AND a.conversation_id=? AND a.state='completed' AND cm.author_kind!='user'")
                            .bind(event.message_id.as_deref().unwrap_or("")).bind(&delivery.source_conversation).fetch_optional(&self.pool).await?
                    };
                    ("", text.unwrap_or_else(|| "Your task is complete.".into()))
                }
                _ => (
                    "Needs attention",
                    "This task could not finish. Open Wonder to review it.".into(),
                ),
            }
        };
        let title = if label.is_empty() {
            title
        } else {
            format!("{} · {label}", excerpt(&title, 100))
        };
        Ok(Some(PushPreview {
            title: excerpt(&title, 160),
            body: excerpt(
                if body.trim().is_empty() {
                    "Open Wonder to review this request."
                } else {
                    &body
                },
                1000,
            ),
        }))
    }
    pub async fn register_push(
        &self,
        device: &str,
        id: &str,
        endpoint: &str,
        secret: &str,
    ) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        // A racing device revocation cannot restore delivery authority.
        let active: bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM devices WHERE id=? AND revoked_at IS NULL AND forgotten=0 AND is_local=0)").bind(device).fetch_one(&mut *tx).await?;
        if !active {
            return Err(sqlx::Error::RowNotFound);
        }
        let owner: Option<String> =
            sqlx::query_scalar("SELECT device_id FROM push_registrations WHERE id=?")
                .bind(id)
                .fetch_optional(&mut *tx)
                .await?;
        if owner.as_deref().is_some_and(|value| value != device) {
            return Err(sqlx::Error::RowNotFound);
        }
        sqlx::query("UPDATE push_registrations SET revoked=1 WHERE device_id=? AND id!=?")
            .bind(device)
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE push_outbox SET state='cancelled' WHERE registration_id IN(SELECT id FROM push_registrations WHERE device_id=? AND revoked=1) AND state='pending'").bind(device).execute(&mut *tx).await?;
        let changed = sqlx::query("INSERT INTO push_registrations(id,device_id,endpoint,sender_secret) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET endpoint=excluded.endpoint,sender_secret=excluded.sender_secret WHERE push_registrations.revoked=0")
            .bind(id).bind(device).bind(endpoint).bind(secret).execute(&mut *tx).await?;
        if changed.rows_affected() != 1 {
            return Err(sqlx::Error::RowNotFound);
        }
        tx.commit().await
    }
    pub async fn register_push_preview(
        &self,
        device: &str,
        id: &str,
        key: &str,
    ) -> Result<(), sqlx::Error> {
        let result=sqlx::query("UPDATE push_registrations SET preview_key=? WHERE id=? AND device_id=? AND revoked=0 AND EXISTS(SELECT 1 FROM devices WHERE id=? AND revoked_at IS NULL AND forgotten=0)")
            .bind(key).bind(id).bind(device).bind(device).execute(&self.pool).await?;
        if result.rows_affected() != 1 {
            return Err(sqlx::Error::RowNotFound);
        }
        Ok(())
    }
    pub async fn push_presence(
        &self,
        device: &str,
        foreground: bool,
        issued: i64,
        now: i64,
    ) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let until = if foreground { now + 45_000 } else { 0 };
        let changed=sqlx::query("INSERT INTO push_presence(device_id,issued_at_ms,foreground_until_ms) SELECT ?,?,? WHERE EXISTS(SELECT 1 FROM devices WHERE id=? AND revoked_at IS NULL AND forgotten=0 AND is_local=0) ON CONFLICT(device_id) DO UPDATE SET issued_at_ms=excluded.issued_at_ms,foreground_until_ms=excluded.foreground_until_ms WHERE excluded.issued_at_ms>push_presence.issued_at_ms")
            .bind(device).bind(issued).bind(until).bind(device).execute(&mut *tx).await?;
        if foreground && changed.rows_affected() == 1 {
            sqlx::query("INSERT OR IGNORE INTO push_suppressed SELECT id,? FROM push_intents WHERE distributed=0").bind(device).execute(&mut *tx).await?;
            sqlx::query("UPDATE push_outbox SET state='suppressed' WHERE state='pending' AND registration_id IN(SELECT id FROM push_registrations WHERE device_id=?)").bind(device).execute(&mut *tx).await?;
        }
        tx.commit().await
    }
    pub async fn revoke_push(&self, device: &str) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("UPDATE push_registrations SET revoked=1 WHERE device_id=?")
            .bind(device)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE push_outbox SET state='cancelled' WHERE registration_id IN(SELECT id FROM push_registrations WHERE device_id=?) AND state='pending'").bind(device).execute(&mut *tx).await?;
        tx.commit().await
    }
    pub async fn push_route(
        &self,
        device: &str,
        route: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT r.conversation_id FROM push_routes r JOIN devices d ON d.id=r.device_id WHERE r.id=? AND r.device_id=? AND d.revoked_at IS NULL")
            .bind(route).bind(device).fetch_optional(&self.pool).await
    }
    pub async fn distribute_push(&self) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let rows =
            sqlx::query("SELECT * FROM push_intents WHERE distributed=0 ORDER BY id LIMIT 100")
                .fetch_all(&mut *tx)
                .await?;
        for row in rows {
            let id: i64 = row.get("id");
            let kind: String = row.get("kind");
            let source: String = row.get("source_key");
            let conversation: String = row.get("conversation_id");
            // Walk only verified persisted ownership. Cycles/depth overflow fail closed.
            let root: Option<String> = sqlx::query_scalar(questions::VERIFIED_SUBAGENT_ROOT_SQL)
                .bind(&conversation)
                .fetch_optional(&mut *tx)
                .await?;
            let mut target = root;
            if let Some(root) = &target {
                let worker:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM group_nodes n JOIN messages m ON m.device_id=n.device_id AND m.client_message_id=n.client_message_id WHERE m.conversation_id=? AND n.phase='worker')").bind(root).fetch_one(&mut *tx).await?;
                if worker {
                    if kind == "completed" {
                        target = None;
                    } else {
                        target = sqlx::query_scalar(questions::VERIFIED_WORKER_GROUP_SQL)
                            .bind(root)
                            .bind(root)
                            .fetch_optional(&mut *tx)
                            .await?
                            .flatten();
                    }
                } else if kind == "completed" && root != &conversation {
                    target = None;
                }
            }
            if let Some(question) = source.strip_prefix("question:") {
                let pending: bool = sqlx::query_scalar(questions::scoped_questions!(" SELECT EXISTS(SELECT 1 FROM scoped_questions WHERE id=? AND visible_conversation IS NOT NULL AND state='pending' AND expires_at_ms>unixepoch()*1000)")).bind(question).fetch_one(&mut *tx).await?;
                if !pending {
                    target = None;
                }
            }
            if row.get::<i64, _>("created_at") + 86400
                < std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs() as i64
            {
                target = None;
            }
            if let Some(target) = target {
                let recipients:Vec<String>=sqlx::query_scalar("SELECT r.id FROM push_registrations r JOIN devices d ON d.id=r.device_id WHERE r.revoked=0 AND d.revoked_at IS NULL AND NOT EXISTS(SELECT 1 FROM push_presence p WHERE p.device_id=d.id AND p.foreground_until_ms>unixepoch('subsec')*1000) AND NOT EXISTS(SELECT 1 FROM push_suppressed s WHERE s.intent_id=? AND s.device_id=d.id)").bind(id).fetch_all(&mut *tx).await?;
                for registration in recipients {
                    let route = uuid::Uuid::new_v4().to_string();
                    sqlx::query("INSERT INTO push_routes(id,device_id,conversation_id) SELECT ?,device_id,? FROM push_registrations WHERE id=?").bind(&route).bind(&target).bind(&registration).execute(&mut *tx).await?;
                    sqlx::query("INSERT OR IGNORE INTO push_outbox(id,registration_id,intent_id,route_id,conversation_id,kind) VALUES(?,?,?,?,?,?)")
                        .bind(uuid::Uuid::new_v4().to_string()).bind(registration).bind(id).bind(route).bind(&target).bind(&kind).execute(&mut *tx).await?;
                }
            }
            sqlx::query("UPDATE push_intents SET distributed=1 WHERE id=?")
                .bind(id)
                .execute(&mut *tx)
                .await?;
        }
        sqlx::query("DELETE FROM push_routes WHERE created_at<unixepoch()-604800")
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM push_intents WHERE created_at<unixepoch()-604800")
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE push_outbox SET state='expired' WHERE state='pending' AND created_at<unixepoch()-86400").execute(&mut *tx).await?;
        tx.commit().await
    }
    pub async fn next_push(&self) -> Result<Option<PushDelivery>, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let row=sqlx::query("SELECT o.*,r.endpoint,r.sender_secret,r.preview_key,i.source_key,i.conversation_id AS source_conversation FROM push_outbox o JOIN push_intents i ON i.id=o.intent_id JOIN push_registrations r ON r.id=o.registration_id JOIN devices d ON d.id=r.device_id WHERE o.state='pending' AND o.attempts<5 AND o.next_attempt<=unixepoch() AND r.revoked=0 AND d.revoked_at IS NULL AND NOT EXISTS(SELECT 1 FROM push_presence p WHERE p.device_id=d.id AND p.foreground_until_ms>unixepoch('subsec')*1000) ORDER BY o.created_at LIMIT 1").fetch_optional(&mut *tx).await?;
        let result = if let Some(row) = row {
            let id: String = row.get("id");
            sqlx::query(
                "UPDATE push_outbox SET attempts=attempts+1,next_attempt=unixepoch()+60 WHERE id=?",
            )
            .bind(&id)
            .execute(&mut *tx)
            .await?;
            Some(PushDelivery {
                id,
                registration_id: row.get("registration_id"),
                endpoint: row.get("endpoint"),
                sender_secret: row.get("sender_secret"),
                route_id: row.get("route_id"),
                kind: row.get("kind"),
                attempts: row.get::<i64, _>("attempts") + 1,
                preview_key: row.get("preview_key"),
                source_key: row.get("source_key"),
                source_conversation: row.get("source_conversation"),
                conversation_id: row.get("conversation_id"),
            })
        } else {
            None
        };
        tx.commit().await?;
        Ok(result)
    }
    pub async fn can_send_push(&self, id: &str) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM push_outbox o JOIN push_registrations r ON r.id=o.registration_id JOIN devices d ON d.id=r.device_id WHERE o.id=? AND o.state='pending' AND r.revoked=0 AND d.revoked_at IS NULL AND NOT EXISTS(SELECT 1 FROM push_presence p WHERE p.device_id=d.id AND p.foreground_until_ms>unixepoch('subsec')*1000))").bind(id).fetch_one(&self.pool).await
    }
    pub async fn finish_push(&self, id: &str, state: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE push_outbox SET state=?,next_attempt=unixepoch()+MIN(3600,60*(1<<attempts)) WHERE id=? AND state='pending'").bind(state).bind(id).execute(&self.pool).await?;
        Ok(())
    }
    pub async fn next_push_revocation(&self) -> Result<Option<PushRevocation>, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        let row=sqlx::query("SELECT * FROM push_registrations WHERE revoked=1 AND revoke_attempts<5 AND next_revoke<=unixepoch() LIMIT 1").fetch_optional(&mut *tx).await?;
        let value = if let Some(row) = row {
            let id: String = row.get("id");
            sqlx::query("UPDATE push_registrations SET revoke_attempts=revoke_attempts+1,next_revoke=unixepoch()+3600 WHERE id=?").bind(&id).execute(&mut *tx).await?;
            Some(PushRevocation {
                id,
                endpoint: row.get("endpoint"),
                sender_secret: row.get("sender_secret"),
            })
        } else {
            None
        };
        tx.commit().await?;
        Ok(value)
    }
    pub async fn finish_push_revocation(&self, id: &str) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM push_registrations WHERE id=? AND revoked=1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn store() -> Store {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        for id in ["phone-a", "phone-b"] {
            store
                .upsert_owner_device(id, id, "{}", "now")
                .await
                .unwrap();
        }
        store
            .register_push("phone-a", "a", "https://push.test", "secret-a")
            .await
            .unwrap();
        store
            .register_push("phone-b", "b", "https://push.test", "secret-b")
            .await
            .unwrap();
        store
    }
    fn event() -> HostEventEnvelope {
        HostEventEnvelope {
            event_id: uuid::Uuid::new_v4().to_string(),
            host_epoch: "epoch".into(),
            sequence: 1,
            occurred_at: "now".into(),
            request_id: None,
            device_id: None,
            conversation_id: Some("parent".into()),
            message_id: None,
            thread_id: None,
            turn_id: None,
            item_id: None,
            approval_id: None,
            event: WonderEvent::MessageState {
                state: wonder_api::DeliveryState::Completed,
            },
        }
    }
    #[tokio::test]
    async fn push_intent_is_atomic_and_routes_are_device_scoped() {
        let store = store().await;
        let event = event();
        let mut tx = store.pool.begin().await.unwrap();
        sqlx::query("INSERT INTO events VALUES(?,?,?,?,?)")
            .bind(&event.event_id)
            .bind(&event.host_epoch)
            .bind(1)
            .bind("now")
            .bind(serde_json::to_string(&event).unwrap())
            .execute(&mut *tx)
            .await
            .unwrap();
        tx.rollback().await.unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM push_intents")
                .fetch_one(&store.pool)
                .await
                .unwrap(),
            0
        );
        store.append_event(&event).await.unwrap();
        store.append_event(&event).await.unwrap();
        store.distribute_push().await.unwrap();
        store.distribute_push().await.unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM push_outbox")
                .fetch_one(&store.pool)
                .await
                .unwrap(),
            2
        );
        let delivery = store.next_push().await.unwrap().unwrap();
        let owner = if delivery.registration_id == "a" {
            "phone-a"
        } else {
            "phone-b"
        };
        let other = if owner == "phone-a" {
            "phone-b"
        } else {
            "phone-a"
        };
        assert_eq!(
            store
                .push_route(owner, &delivery.route_id)
                .await
                .unwrap()
                .as_deref(),
            Some("parent")
        );
        assert!(store
            .push_route(other, &delivery.route_id)
            .await
            .unwrap()
            .is_none());
        store.revoke_owner_device(owner, "later").await.unwrap();
        assert!(store
            .push_route(owner, &delivery.route_id)
            .await
            .unwrap()
            .is_none());
        assert!(store
            .register_push(owner, "new", "https://push.test", "secret")
            .await
            .is_err());
        assert_eq!(
            store.next_push_revocation().await.unwrap().unwrap().id,
            delivery.registration_id
        );
    }
    #[tokio::test]
    async fn push_rotation_keeps_routes_and_revokes_old_capability() {
        let store = store().await;
        store.append_event(&event()).await.unwrap();
        store.distribute_push().await.unwrap();
        let route: String =
            sqlx::query_scalar("SELECT route_id FROM push_outbox WHERE registration_id='a'")
                .fetch_one(&store.pool)
                .await
                .unwrap();
        store
            .register_push("phone-a", "new-a", "https://push.test", "new-secret")
            .await
            .unwrap();
        assert_eq!(store.next_push_revocation().await.unwrap().unwrap().id, "a");
        store.finish_push_revocation("a").await.unwrap();
        assert_eq!(
            store
                .push_route("phone-a", &route)
                .await
                .unwrap()
                .as_deref(),
            Some("parent")
        );
        assert!(store
            .register_push("phone-b", "new-a", "https://push.test", "hijack")
            .await
            .is_err());
    }
    #[tokio::test]
    async fn revoked_registration_cannot_be_reactivated_or_replace_current_registration() {
        let store = store().await;
        store.revoke_push("phone-a").await.unwrap();
        store
            .register_push("phone-a", "new", "https://push.test", "new-secret")
            .await
            .unwrap();
        assert!(store
            .register_push("phone-a", "a", "https://push.test", "secret-a")
            .await
            .is_err());
        let active: String = sqlx::query_scalar(
            "SELECT id FROM push_registrations WHERE device_id='phone-a' AND revoked=0",
        )
        .fetch_one(&store.pool)
        .await
        .unwrap();
        assert_eq!(active, "new");
    }

    #[tokio::test]
    async fn push_claims_have_a_lease_and_bounded_retries() {
        let store = store().await;
        store.revoke_push("phone-b").await.unwrap();
        store.append_event(&event()).await.unwrap();
        store.distribute_push().await.unwrap();
        for attempt in 1..=5 {
            let delivery = store.next_push().await.unwrap().unwrap();
            assert_eq!(delivery.attempts, attempt);
            assert!(store.next_push().await.unwrap().is_none());
            store.finish_push(&delivery.id, "pending").await.unwrap();
            sqlx::query("UPDATE push_outbox SET next_attempt=0")
                .execute(&store.pool)
                .await
                .unwrap();
        }
        assert!(store.next_push().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn foreground_arrivals_stay_suppressed_after_background_and_other_devices_receive() {
        let store = store().await;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        store
            .push_presence("phone-a", true, now, now)
            .await
            .unwrap();
        store.append_event(&event()).await.unwrap();
        store
            .push_presence("phone-a", false, now + 1, now + 1)
            .await
            .unwrap();
        // A delayed heartbeat must not undo the newer background transition.
        store
            .push_presence("phone-a", true, now, now + 2)
            .await
            .unwrap();
        store.distribute_push().await.unwrap();
        let delivery = store.next_push().await.unwrap().unwrap();
        assert_eq!(delivery.registration_id, "b");
        assert!(store.next_push().await.unwrap().is_none());
        let mut next = event();
        next.sequence = 2;
        store.append_event(&next).await.unwrap();
        store.distribute_push().await.unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM push_outbox WHERE registration_id='a'"
            )
            .fetch_one(&store.pool)
            .await
            .unwrap(),
            1
        );
    }

    #[tokio::test]
    async fn foreground_cancels_inflight_claims_and_crashed_presence_expires() {
        let store = store().await;
        store.revoke_push("phone-b").await.unwrap();
        store.append_event(&event()).await.unwrap();
        store.distribute_push().await.unwrap();
        let delivery = store.next_push().await.unwrap().unwrap();
        assert!(store.can_send_push(&delivery.id).await.unwrap());
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        store
            .push_presence("phone-a", true, now, now)
            .await
            .unwrap();
        assert!(!store.can_send_push(&delivery.id).await.unwrap());
        sqlx::query("UPDATE push_presence SET foreground_until_ms=0")
            .execute(&store.pool)
            .await
            .unwrap();
        let mut next = event();
        next.sequence = 2;
        store.append_event(&next).await.unwrap();
        store.distribute_push().await.unwrap();
        assert!(store.next_push().await.unwrap().is_some());
    }

    #[tokio::test]
    async fn previews_use_exact_turn_and_questions_expire() {
        let store = store().await;
        store.revoke_push("phone-b").await.unwrap();
        store
            .complete_assistant_message(
                "parent",
                "thread",
                "one",
                "item-one",
                "Correct answer",
                "1",
            )
            .await
            .unwrap();
        store
            .complete_assistant_message(
                "parent",
                "thread",
                "two",
                "item-two",
                "Unrelated later answer",
                "2",
            )
            .await
            .unwrap();
        let mut event = event();
        event.thread_id = Some("thread".into());
        event.turn_id = Some("one".into());
        store.append_event(&event).await.unwrap();
        store.distribute_push().await.unwrap();
        let delivery = store.next_push().await.unwrap().unwrap();
        assert_eq!(
            store.push_preview(&delivery).await.unwrap().unwrap().body,
            "Correct answer"
        );
        store.finish_push(&delivery.id, "delivered").await.unwrap();
        store
            .save_async_question(
                "parent",
                "thread",
                "two",
                "ask",
                r#"[{"title":"Which day?"}]"#,
                i64::MAX,
            )
            .await
            .unwrap();
        store.distribute_push().await.unwrap();
        let delivery = store.next_push().await.unwrap().unwrap();
        assert_eq!(
            store.push_preview(&delivery).await.unwrap().unwrap().body,
            "Which day?"
        );
        sqlx::query("UPDATE async_questions SET state='answered'")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(store.push_preview(&delivery).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn approval_preview_is_exact_and_stale_requests_are_cancelled() {
        let store = store().await;
        store.revoke_push("phone-b").await.unwrap();
        sqlx::query("INSERT INTO approvals(approval_id,server_request_id,method,params_json,state,created_at,action_nonce,thread_id,turn_id,item_id) VALUES('approval','request','item/commandExecution/requestApproval',?,'pending','now','nonce','thread','turn','item')")
            .bind(r#"{"reason":"Install dependencies?","command":"npm ci"}"#).execute(&store.pool).await.unwrap();
        let mut event = event();
        event.thread_id = Some("thread".into());
        event.turn_id = Some("turn".into());
        event.event = WonderEvent::ApprovalOpened {
            request_id: "request".into(),
        };
        store.append_event(&event).await.unwrap();
        store.distribute_push().await.unwrap();
        let delivery = store.next_push().await.unwrap().unwrap();
        assert_eq!(
            store.push_preview(&delivery).await.unwrap().unwrap().body,
            "Install dependencies?\nnpm ci"
        );
        sqlx::query("UPDATE approvals SET state='resolved'")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(store.push_preview(&delivery).await.unwrap().is_none());
    }

    #[test]
    fn preview_excerpt_bounds_unicode_and_json_escaping() {
        let value = excerpt(&"🦀\"\n".repeat(1000), 1000);
        assert!(value.len() <= 1003);
        assert!(
            serde_json::to_vec(&PushPreview {
                title: excerpt(&"\"".repeat(200), 160),
                body: value
            })
            .unwrap()
            .len()
                < 2400
        );
    }
}
