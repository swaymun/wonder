//! Persisted search with deterministic keyset pagination; no runtime history fetches.
use super::*;

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct SearchCursor {
    pub sort_ms: i64,
    pub kind: String,
    pub id: String,
}
pub struct SearchPage {
    pub results: Vec<StoredSearchResult>,
    pub next_cursor: Option<SearchCursor>,
}
impl Store {
    pub async fn search(
        &self,
        query: &str,
        limit: u32,
    ) -> Result<Vec<StoredSearchResult>, sqlx::Error> {
        Ok(self.search_page(query, None, None, limit).await?.results)
    }

    pub async fn search_page(
        &self,
        query: &str,
        conversation: Option<&str>,
        before: Option<&SearchCursor>,
        limit: u32,
    ) -> Result<SearchPage, sqlx::Error> {
        // V1 limitation: rebuild the small FTS projection at query time. An
        // incremental index needs mutation hooks for every searchable record;
        // keep this bounded and explicit until that lifecycle is designed.
        let match_query = search_match_query(query);
        if match_query.is_empty() || limit == 0 {
            return Ok(SearchPage {
                results: vec![],
                next_cursor: None,
            });
        }
        let mut transaction = self.pool.begin().await?;
        sqlx::query("DELETE FROM search_documents")
            .execute(&mut *transaction)
            .await?;
        sqlx::query(
            "INSERT INTO search_documents (kind, result_id, title, body, conversation_id, bot_id, updated_at)
             SELECT 'bot', id, name, role, NULL, id, created_at
             FROM bots
             WHERE is_archived = 0",
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            "INSERT INTO search_documents (kind, result_id, title, body, conversation_id, bot_id, updated_at)
             SELECT 'channel', id, name, name || ' ' || COALESCE(description, ''), conversation_id, coordinator_bot_id, updated_at
             FROM channels
             WHERE is_archived = 0",
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            "INSERT INTO search_documents (kind, result_id, title, body, conversation_id, bot_id, updated_at)
             SELECT 'conversation', metadata.id, metadata.title, metadata.title, metadata.id, metadata.bot_id, metadata.updated_at
             FROM conversation_metadata AS metadata
             JOIN bots ON bots.id = metadata.bot_id
             WHERE bots.is_archived = 0",
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            "INSERT INTO search_documents (kind, result_id, title, body, conversation_id, bot_id, updated_at)
             SELECT 'message', messages.id, metadata.title, messages.body, messages.conversation_id, metadata.bot_id, messages.created_at
             FROM messages
             JOIN conversation_metadata AS metadata ON metadata.id = messages.conversation_id
             JOIN bots ON bots.id = metadata.bot_id
             WHERE bots.is_archived = 0
               AND NOT EXISTS (SELECT 1 FROM bot_initializations WHERE message_id=messages.id)
               AND NOT EXISTS (SELECT 1 FROM bot_workspace_followups WHERE message_id=messages.id)
               AND NOT EXISTS (SELECT 1 FROM channels WHERE channels.conversation_id = messages.conversation_id)",
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            "INSERT INTO search_documents (kind, result_id, title, body, conversation_id, bot_id, updated_at)
             SELECT 'assistant_message', assistant.id, metadata.title, assistant.text, assistant.conversation_id, metadata.bot_id, assistant.updated_at
             FROM assistant_messages AS assistant
             JOIN conversation_metadata AS metadata ON metadata.id = assistant.conversation_id
             JOIN bots ON bots.id = metadata.bot_id
             WHERE bots.is_archived = 0
               AND NOT EXISTS (SELECT 1 FROM bot_initializations i JOIN messages m ON m.id=i.message_id WHERE m.codex_turn_id=assistant.codex_turn_id AND m.conversation_id=assistant.conversation_id)
               AND NOT EXISTS (SELECT 1 FROM channels WHERE channels.conversation_id = assistant.conversation_id)",
        )
        .execute(&mut *transaction)
        .await?;
        // Group timeline rows are public presentation copies. The same conversation
        // also stores private synthesis inputs and raw assistant output: neither is
        // a rendered Group message or a valid native search focus target.
        sqlx::query(
            "INSERT INTO search_documents (kind, result_id, title, body, conversation_id, bot_id, updated_at)
             SELECT 'message', messages.id, channels.name, messages.body, channels.conversation_id,
                    COALESCE(presentation.author_bot_id, channels.coordinator_bot_id), messages.created_at
             FROM channel_messages AS presentation
             JOIN messages ON messages.id = presentation.message_id
             JOIN channels ON channels.id = presentation.channel_id
             WHERE channels.is_archived = 0
               AND presentation.author_kind IN ('user', 'automation', 'member', 'coordinator')
               AND NOT (presentation.presentation_kind='status' AND presentation.author_kind='user')",
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            "INSERT INTO search_documents (kind, result_id, title, body, conversation_id, bot_id, updated_at)
             SELECT 'file', files.id, files.name, files.name || ' ' || COALESCE(files.relative_path, ''), files.conversation_id, metadata.bot_id, files.updated_at
             FROM conversation_files AS files
             JOIN conversation_metadata AS metadata ON metadata.id = files.conversation_id
             JOIN bots ON bots.id = metadata.bot_id
             WHERE bots.is_archived = 0",
        )
        .execute(&mut *transaction)
        .await?;
        // Reuse the Chats list's durable worker exclusion. Scope is a narrowing
        // filter only; visibility is checked independently on every page.
        sqlx::query("DELETE FROM search_documents WHERE conversation_id IS NOT NULL AND (NOT EXISTS(SELECT 1 FROM conversation_metadata m JOIN bots b ON b.id=m.bot_id WHERE m.id=search_documents.conversation_id AND m.is_archived=0 AND b.is_archived=0) OR EXISTS(SELECT 1 FROM channels c WHERE c.conversation_id=search_documents.conversation_id AND c.is_archived<>0) OR EXISTS(SELECT 1 FROM group_nodes n JOIN messages child ON child.device_id=n.device_id AND child.client_message_id=n.client_message_id WHERE n.phase='worker' AND child.conversation_id=search_documents.conversation_id) OR EXISTS(SELECT 1 FROM subagent_ownership child WHERE child.conversation_id=search_documents.conversation_id))")
            .execute(&mut *transaction).await?;
        let rows = sqlx::query(r#"
            WITH matched AS (
                SELECT kind,result_id,title,snippet(search_documents,3,'<mark>','</mark>','…',12) AS snippet,
                    conversation_id,bot_id,updated_at,
                    CASE WHEN updated_at NOT GLOB '*[^0-9]*' THEN CAST(updated_at AS INTEGER)
                    ELSE COALESCE(CAST((julianday(updated_at)-2440587.5)*86400000 AS INTEGER),0) END AS sort_ms
                FROM search_documents WHERE search_documents MATCH ? AND (? IS NULL OR conversation_id=?)
            )
            SELECT * FROM matched WHERE ? IS NULL OR (sort_ms,kind,result_id)<(?,?,?)
            ORDER BY sort_ms DESC,kind DESC,result_id DESC LIMIT ?
        "#)
        .bind(match_query).bind(conversation).bind(conversation)
        .bind(before.map(|c| c.sort_ms)).bind(before.map(|c| c.sort_ms))
        .bind(before.map(|c| &c.kind)).bind(before.map(|c| &c.id))
        .bind(i64::from(limit.min(100)) + 1)
        .fetch_all(&mut *transaction).await?;
        // Read the page in the rebuild transaction: another query cannot replace
        // the FTS projection between matching and fetching results.
        transaction.commit().await?;
        let has_more = rows.len() > limit.min(100) as usize;
        let mut next_cursor = None;
        let results = rows
            .into_iter()
            .take(limit.min(100) as usize)
            .map(|row| {
                next_cursor = Some(SearchCursor {
                    sort_ms: row.get("sort_ms"),
                    kind: row.get("kind"),
                    id: row.get("result_id"),
                });
                StoredSearchResult {
                    kind: row.get("kind"),
                    id: row.get("result_id"),
                    title: row.get("title"),
                    snippet: row.get("snippet"),
                    conversation_id: row.get("conversation_id"),
                    bot_id: row.get("bot_id"),
                    updated_at: row.get("updated_at"),
                }
            })
            .collect();
        Ok(SearchPage {
            results,
            next_cursor: if has_more { next_cursor } else { None },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn tied_pages_filter_scope_and_hidden_content_and_refresh_edits() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_owner_device("owner", "Owner", "{}", "1")
            .await
            .unwrap();
        store
            .upsert_bot(
                "bot",
                "Bot",
                "Role",
                "private-system-needle",
                "/tmp/bot",
                "chat",
                None,
                None,
                "1",
            )
            .await
            .unwrap();
        store
            .create_conversation("chat", "bot", "Chat", "1")
            .await
            .unwrap();
        store
            .create_conversation("other", "bot", "Other", "1")
            .await
            .unwrap();
        store
            .create_conversation("archived", "bot", "Archived", "1")
            .await
            .unwrap();
        store
            .update_conversation("archived", None, Some(true), None, None, "2")
            .await
            .unwrap();
        store
            .create_conversation("hidden", "bot", "Hidden", "1")
            .await
            .unwrap();
        let mut expected = std::collections::BTreeSet::new();
        let mut first_id = String::new();
        for n in 0..23 {
            let MessageInsert::Inserted(m) = store
                .insert_message(
                    "owner",
                    &format!("message-{n}"),
                    "A needle matching message",
                    "hash",
                    "chat",
                    "1000",
                )
                .await
                .unwrap()
            else {
                panic!()
            };
            if n == 0 {
                first_id = m.id.clone();
            }
            expected.insert(("message".to_owned(), m.id));
        }
        for n in 0..3 {
            let assistant = store
                .complete_assistant_message(
                    "chat",
                    "thread",
                    &format!("turn-{n}"),
                    "answer",
                    "A needle assistant response",
                    "1000",
                )
                .await
                .unwrap()
                .unwrap();
            expected.insert(("assistant_message".to_owned(), assistant.id));
        }
        for (client, conversation) in [
            ("other-message", "other"),
            ("archived-message", "archived"),
            ("hidden-message", "hidden"),
        ] {
            store
                .insert_message(
                    "owner",
                    client,
                    "needle excluded from scoped results",
                    "hash",
                    conversation,
                    "1000",
                )
                .await
                .unwrap();
        }
        store
            .create_channel(
                "group",
                "group-chat",
                "Group",
                None,
                "bot",
                &[("bot", "coordinator")],
                "1",
            )
            .await
            .unwrap();
        sqlx::query("INSERT INTO group_runs(parent_message_id,channel_id,snapshot_json,updated_at) VALUES (?,'group','{}','1')").bind(&first_id).execute(&store.pool).await.unwrap();
        sqlx::query("INSERT INTO group_nodes(parent_message_id,device_id,client_message_id,bot_id,phase) VALUES (?,'owner','hidden-message','bot','worker')").bind(&first_id).execute(&store.pool).await.unwrap();
        let mut cursor = None;
        let mut seen = std::collections::BTreeSet::new();
        loop {
            let page = store
                .search_page("needle", Some("chat"), cursor.as_ref(), 4)
                .await
                .unwrap();
            for result in page.results {
                assert_eq!(result.conversation_id.as_deref(), Some("chat"));
                assert!(result.snippet.unwrap().contains("<mark>needle</mark>"));
                assert!(
                    seen.insert((result.kind, result.id)),
                    "no duplicate across tied pages"
                );
            }
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        assert_eq!(seen, expected, "no gaps across tied pages");
        assert!(store
            .search_page("needle", Some("hidden"), None, 10)
            .await
            .unwrap()
            .results
            .is_empty());
        assert!(store
            .search_page("needle", Some("archived"), None, 10)
            .await
            .unwrap()
            .results
            .is_empty());
        assert!(store
            .search_page("needle", Some("missing"), None, 10)
            .await
            .unwrap()
            .results
            .is_empty());
        let all = store.search("needle", 100).await.unwrap();
        assert_eq!(all.len(), 27);
        assert!(
            all.iter()
                .all(|r| matches!(r.kind.as_str(), "message" | "assistant_message")),
            "system prompts are not searchable message content"
        );
        sqlx::query("UPDATE messages SET body='changed away from query' WHERE id=?")
            .bind(&first_id)
            .execute(&store.pool)
            .await
            .unwrap();
        assert_eq!(
            store
                .search_page("needle", Some("chat"), None, 100)
                .await
                .unwrap()
                .results
                .len(),
            25
        );
        sqlx::query(
            "DELETE FROM messages WHERE device_id='owner' AND client_message_id='message-1'",
        )
        .execute(&store.pool)
        .await
        .unwrap();
        assert_eq!(
            store
                .search_page("needle", Some("chat"), None, 100)
                .await
                .unwrap()
                .results
                .len(),
            24
        );
        assert!(!store.search("Group", 100).await.unwrap().is_empty());
        sqlx::query("UPDATE channels SET is_archived=1 WHERE id='group'")
            .execute(&store.pool)
            .await
            .unwrap();
        assert!(store.search("Group", 100).await.unwrap().is_empty());
    }
    #[tokio::test]
    async fn group_results_are_only_openable_public_message_copies() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_owner_device("owner", "Owner", "{}", "1")
            .await
            .unwrap();
        store
            .upsert_bot(
                "bot", "Bot", "Role", "system", "/tmp/bot", "direct", None, None, "1",
            )
            .await
            .unwrap();
        store
            .create_channel(
                "group",
                "group-chat",
                "Team",
                None,
                "bot",
                &[("bot", "coordinator")],
                "1",
            )
            .await
            .unwrap();
        let mut expected = std::collections::BTreeSet::new();
        for (client, body, public, author) in [
            ("user", "needle public question", true, "user"),
            (
                "synthesis",
                "needle private coordinator instructions and worker reports",
                false,
                "coordinator",
            ),
            ("public-output", "needle final answer", true, "coordinator"),
        ] {
            let MessageInsert::Inserted(message) = store
                .insert_message("owner", client, body, "hash", "group-chat", "1000")
                .await
                .unwrap()
            else {
                panic!()
            };
            if public {
                store
                    .add_channel_message(NewChannelMessage {
                        channel_id: "group",
                        message_id: &message.id,
                        author_kind: author,
                        author_bot_id: Some("bot"),
                        phase: "synthesis",
                        created_at: "1000",
                        presentation_kind: "message",
                        outcome: Some("completed"),
                        retryable: false,
                    })
                    .await
                    .unwrap();
                expected.insert(message.id);
            }
        }
        // This is the runtime source for the presentation copy; its ID is not a Group row.
        store
            .complete_assistant_message(
                "group-chat",
                "thread",
                "turn",
                "answer",
                "needle final answer",
                "1000",
            )
            .await
            .unwrap();
        let displayed: std::collections::BTreeSet<_> = store
            .channel_messages("group")
            .await
            .unwrap()
            .into_iter()
            .map(|m| m.message_id)
            .collect();
        assert_eq!(displayed, expected);
        for scope in [None, Some("group-chat")] {
            let mut cursor = None;
            let mut found = std::collections::BTreeSet::new();
            loop {
                let page = store
                    .search_page("needle", scope, cursor.as_ref(), 1)
                    .await
                    .unwrap();
                for result in page.results {
                    assert_eq!(
                        result.kind, "message",
                        "raw Group assistant outputs are not rendered messages"
                    );
                    assert_eq!(result.conversation_id.as_deref(), Some("group-chat"));
                    assert!(
                        displayed.contains(&result.id),
                        "every result must open a rendered Group message: {}",
                        result.id
                    );
                    assert!(
                        found.insert(result.id),
                        "each public reply appears once across pages"
                    );
                }
                cursor = page.next_cursor;
                if cursor.is_none() {
                    break;
                }
            }
            assert_eq!(found, expected);
        }
    }
}
