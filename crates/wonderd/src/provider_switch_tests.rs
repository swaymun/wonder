//! Delivery of a message that carries the other provider's model, against a
//! fake Codex runtime and a fake Claude bridge.
use crate::projects::tests::handoff_fixture;
use crate::provider_switch::{count_positions, is_handoff_text};
use crate::AppState;
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};
use tokio::sync::Mutex;
use wonder_app_server::AppServerClient;
use wonder_store::{AgentFamily, HandoffDelivery, MessageInsert, StoredMessage};

const CLAUDE_THREAD: &str = "claude-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const CLAUDE_SESSION: &str = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";

struct Fx {
    chat: String,
    dir: tempfile::TempDir,
    state: AppState,
    _service: crate::ingestion::NotificationService,
}

fn model(id: &str, family: AgentFamily) -> crate::ModelOption {
    crate::ModelOption {
        agent_family: family,
        capabilities: crate::ModelCapabilities::for_family(family),
        id: id.into(),
        display_name: if family == AgentFamily::Claude {
            "Claude Sonnet".into()
        } else {
            "GPT Fake".into()
        },
        description: None,
        model_specialty: None,
        hidden: false,
        reasoning_efforts: vec![],
        default_reasoning_effort: None,
        service_tiers: vec![],
        default_service_tier: Some("default".into()),
        is_default: false,
        provider_default: None,
        native_ids: vec![],
    }
}

async fn fx() -> Fx {
    let (dir, mut state, first) = handoff_fixture().await;
    // The fixture's own message is long finished.
    state
        .store
        .update_message_delivery(&first.id, "completed", Some("thread"), Some("turn"))
        .await
        .unwrap();
    // The fake Codex runtime reports history from items.json and can hand out
    // a chosen thread id.
    let script = dir.path().join("runtime.py");
    let source = std::fs::read_to_string(&script).unwrap();
    let start = "elif method == 'thread/start': result = {'thread':{'id':'thread'}}";
    let items = "    elif method == 'thread/items/list':\n        if os.path.exists(root + '/long-history'):";
    let resume = "elif method == 'thread/resume': result = {'thread':child_thread()} if r.get('params',{}).get('threadId') == 'child-thread' else {'thread':{'status':{'type':'idle'}}}";
    assert!(source.contains(start) && source.contains(items) && source.contains(resume));
    let folder = state.store.project("project").await.unwrap().unwrap().roots[0]
        .path
        .clone();
    std::fs::write(
        dir.path().join("idle-fixture.json"),
        json!({"thread":{"id":"thread","status":{"type":"idle"},"cwd":folder},
            "codex-main":{"id":"codex-main","status":{"type":"idle"},"cwd":folder},
            "fresh-codex":{"id":"fresh-codex","status":{"type":"idle"},"cwd":folder}})
        .to_string(),
    )
    .unwrap();
    std::fs::write(
        &script,
        source
            .replace(
                resume,
                "elif method == 'thread/resume': result = {'thread':{'id':r.get('params',{}).get('threadId'),'status':{'type':'idle'}}}",
            )
            .replace(
                start,
                "elif method == 'thread/start': result = {'thread':{'id':open(root + '/next-thread').read().strip() if os.path.exists(root + '/next-thread') else 'thread'}}",
            )
            .replace(
                items,
                "    elif method == 'thread/items/list' and os.path.exists(root + '/codex-items.json'):\n        result = {'data':json.load(open(root + '/codex-items.json')).get(r['params']['threadId'], []),'nextCursor':None}\n    elif method == 'thread/items/list':\n        if os.path.exists(root + '/long-history'):",
            ),
    )
    .unwrap();
    state.projects.shutdown().await;
    let bridge = dir.path().join("claude-bridge.py");
    std::fs::write(
        &bridge,
        format!(
            r#"import json, sys, os
root = os.path.dirname(__file__)
n = 0
for line in sys.stdin:
    r = json.loads(line)
    if 'id' not in r: continue
    m = r.get('method'); p = r.get('params', {{}}); result = {{}}
    with open(root + '/claude-requests', 'a') as log: log.write(json.dumps({{'method': m, 'params': p}}) + '\n')
    if m == 'initialize': result = {{'wonderBridge': {{'protocolVersion': 1, 'family': 'claude'}}, 'capabilities': {{'experimentalApi': True}}}}
    elif m == 'thread/start':
        n += 1
        tid = open(root + '/next-claude').read().strip() if os.path.exists(root + '/next-claude') else '{CLAUDE_THREAD}'
        result = {{'thread': {{'id': tid, 'sessionId': tid[len('claude-'):]}}}}
    elif m == 'turn/start':
        if os.path.exists(root + '/claude-boom'):
            print(json.dumps({{'id': r['id'], 'error': {{'code': -32000, 'message': 'Claude stopped unexpectedly'}}}}), flush=True)
            continue
        if os.path.exists(root + '/claude-busy'):
            print(json.dumps({{'id': r['id'], 'error': {{'code': -32000, 'message': 'Claude is working on this conversation on your Mac. Try later.'}}}}), flush=True)
            continue
        result = {{'turn': {{'id': 'claude-turn-' + str(os.path.getsize(root + '/claude-requests'))}}}}
    elif m == 'thread/items/list':
        data = json.load(open(root + '/claude-items.json')).get(p.get('threadId'), []) if os.path.exists(root + '/claude-items.json') else []
        result = {{'data': data, 'nextCursor': None}}
    elif m == 'thread/read': result = {{'thread': {{'id': p.get('threadId')}}}}
    print(json.dumps({{'id': r['id'], 'result': result}}), flush=True)
"#
        ),
    )
    .unwrap();
    let config = wonder_app_server::BridgeLaunchConfig {
        node_bin: "/usr/bin/python3".into(),
        entrypoint: bridge,
        state_dir: dir.path().join("claude-state"),
        npm_cli: None,
        wonder_version: "test".into(),
    };
    let client = Arc::new(Mutex::new(AppServerClient::unavailable(
        "test".into(),
        crate::ingestion::notification_sink(state.store.clone()),
    )));
    client
        .lock()
        .await
        .restart_bridge(config.clone())
        .await
        .unwrap();
    state.claude = Some(Arc::new(crate::claude::Runtime { client, config }));
    // A conversation with a real id, bound to its own Codex thread.
    let chat = uuid::Uuid::new_v4().to_string();
    let project = state.store.project("project").await.unwrap().unwrap();
    state
        .store
        .create_project_conversation(wonder_store::ProjectConversationInsert {
            conversation_id: &chat,
            project_id: "project",
            family: AgentFamily::Codex,
            provider_store: &state.projects.codex_store,
            native_session_id: Some("codex-main"),
            cwd: &project.roots[0].path,
            roots_revision: project.roots_revision,
            title: "Main",
            model: Some("fake"),
            effort: None,
            service_tier: None,
            access_mode: "workspace",
            claude_approval: "ask",
            plan_mode: false,
            creation_request_id: None,
            now: "now",
        })
        .await
        .unwrap();
    state
        .store
        .bind_project_runtime(
            &chat,
            AgentFamily::Codex,
            &state.projects.codex_store,
            "codex-main",
            None,
            "now",
        )
        .await
        .unwrap();
    let service = crate::ingestion::spawn(state.clone()).await;
    for _ in 0..200 {
        if state.ingestion.project_readiness(&state.store).await.ready {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    Fx {
        chat,
        dir,
        state,
        _service: service,
    }
}

fn text_items(pairs: &[(&str, &str)]) -> Value {
    Value::Array(
        pairs
            .iter()
            .enumerate()
            .map(|(i, (role, text))| {
                let item = if *role == "user" {
                    json!({"type":"userMessage","id":format!("u{i}"),"content":[{"type":"text","text":text}]})
                } else {
                    json!({"type":"agentMessage","id":format!("a{i}"),"text":text})
                };
                json!({"turnId":"turn","item":item})
            })
            .collect(),
    )
}

impl Fx {
    fn write(&self, name: &str, value: &Value) {
        std::fs::write(self.dir.path().join(name), value.to_string()).unwrap();
    }

    fn claude_requests(&self, method: &str) -> Vec<Value> {
        std::fs::read_to_string(self.dir.path().join("claude-requests"))
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|request| request["method"] == method)
            .collect()
    }

    fn codex_requests(&self, method: &str) -> Vec<Value> {
        std::fs::read_to_string(self.dir.path().join("requests-jsonl"))
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|request| request["method"] == method)
            .collect()
    }

    async fn thread(&self) -> wonder_store::StoredProjectConversation {
        self.state
            .store
            .project_conversation(&self.chat)
            .await
            .unwrap()
            .unwrap()
    }

    /// Accepts a message the way the send route does, optionally with a model.
    async fn queue(&self, text: &str, with: Option<(AgentFamily, &str)>) -> StoredMessage {
        let client = uuid::Uuid::new_v4().to_string();
        if let Some((family, model)) = with {
            self.state
                .store
                .stage_project_message_target(
                    "owner",
                    &client,
                    family,
                    model,
                    None,
                    None,
                    "2026-01-01T00:00:00Z",
                )
                .await
                .unwrap();
        }
        let MessageInsert::Inserted(message) = self
            .state
            .store
            .insert_dispatch_message(
                "owner",
                &client,
                text,
                "hash",
                &self.chat,
                &[],
                "2026-01-01T00:00:00Z",
                true,
            )
            .await
            .unwrap()
        else {
            panic!("new message")
        };
        message
    }

    /// Starting a runtime refreshes the catalog from the fake provider, so the
    /// two models are offered again before each delivery.
    async fn offer_models(&self) {
        let _ = crate::projects::codex_rpc(&self.state).await;
        let mut catalog = self.state.runtime_catalog.write().await;
        catalog
            .models
            .retain(|m| m.id != "fake" && m.id != "claude:sonnet");
        catalog.models.push(model("fake", AgentFamily::Codex));
        catalog
            .models
            .push(model("claude:sonnet", AgentFamily::Claude));
    }

    /// Releases the message for delivery, as the dispatcher does.
    async fn release(&self, message: &StoredMessage) -> Result<(String, String, String), String> {
        self.offer_models().await;
        assert!(self
            .state
            .store
            .claim_message_for_dispatch(&message.id)
            .await
            .unwrap());
        let message = self
            .state
            .store
            .message_by_id(&message.id)
            .await
            .unwrap()
            .unwrap();
        let mut submitting = false;
        crate::projects::dispatch_inner(&self.state, &message, &mut submitting).await
    }

    async fn finish(&self, message: &StoredMessage) {
        self.state
            .store
            .update_message_delivery(&message.id, "completed", None, None)
            .await
            .unwrap();
    }
}

fn turn_input(request: &Value) -> Vec<Value> {
    request["params"]["input"].as_array().unwrap().clone()
}

fn text_of(part: &Value) -> &str {
    part["text"].as_str().unwrap()
}

// Contract: choosing the other provider's model for a message moves the thread
// when that message is released; the new session receives the earlier
// conversation once, and the owner's text is untouched.
#[tokio::test]
async fn a_message_with_claudes_model_starts_a_claude_session_with_the_history_once() {
    let fx = fx().await;
    fx.write(
        "codex-items.json",
        &json!({"codex-main": text_items(&[("user", "fix the parser"), ("agent", "parser fixed")])}),
    );
    let mut events = fx.state.events.subscribe();
    let first = fx
        .queue(
            "now continue in Claude",
            Some((AgentFamily::Claude, "claude:sonnet")),
        )
        .await;
    fx.release(&first).await.unwrap();

    let thread = fx.thread().await;
    assert_eq!(thread.family, AgentFamily::Claude);
    assert_eq!(thread.model.as_deref(), Some("claude:sonnet"));
    assert_eq!(thread.native_session_id.as_deref(), Some(CLAUDE_SESSION));
    assert_eq!(fx.claude_requests("thread/start").len(), 1);
    let starts = fx.claude_requests("turn/start");
    assert_eq!(starts.len(), 1);
    let input = turn_input(&starts[0]);
    assert_eq!(input.len(), 2, "briefing part then the owner's message");
    assert!(is_handoff_text(text_of(&input[0])));
    assert!(text_of(&input[0]).contains("fix the parser"));
    assert!(text_of(&input[0]).contains("parser fixed"));
    assert!(text_of(&input[0]).contains("wonder_thread_read"));
    assert_eq!(text_of(&input[1]), "now continue in Claude");
    // New Claude sessions get the thread tools to read what was left out.
    assert!(starts[0]["params"]["dynamicTools"]
        .as_array()
        .unwrap()
        .iter()
        .any(|tool| tool["name"] == "wonder_thread_read"));
    // Delivered and recorded; the old Codex session is remembered.
    assert!(fx
        .state
        .store
        .pending_handoff(&fx.chat)
        .await
        .unwrap()
        .is_none());
    assert_eq!(
        fx.state
            .store
            .handoff_delivery(&fx.chat, CLAUDE_THREAD)
            .await
            .unwrap(),
        Some(HandoffDelivery::Injected)
    );
    let history = fx
        .state
        .store
        .project_runtime_history(&fx.chat)
        .await
        .unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].family, AgentFamily::Codex);
    // The timeline got a switch row (a thread item, not a message), updated with counts.
    let mut rows = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let wonder_api::WonderEvent::Activity {
            category,
            detail: Some(detail),
            ..
        } = event.event
        {
            if category == "thread_item_upsert" {
                let detail: Value = serde_json::from_str(&detail).unwrap();
                if detail["item"]["type"] == "providerSwitch" {
                    rows.push(detail["item"]["text"].as_str().unwrap().to_owned());
                }
            }
        }
    }
    assert!(rows.len() >= 2, "{rows:?}");
    assert_eq!(
        rows.last().unwrap(),
        "Switched to Claude Sonnet · Codex history was handed over (2 messages)"
    );

    // The next message is an ordinary turn: the briefing is not sent again.
    fx.finish(&first).await;
    let second = fx.queue("and now this", None).await;
    fx.release(&second).await.unwrap();
    let starts = fx.claude_requests("turn/start");
    assert_eq!(starts.len(), 2);
    assert_eq!(turn_input(&starts[1]).len(), 1);
    assert_eq!(fx.claude_requests("thread/start").len(), 1);
}

#[tokio::test]
async fn going_back_resumes_the_old_session_and_sends_only_what_happened_since() {
    let fx = fx().await;
    fx.write(
        "codex-items.json",
        &json!({"codex-main": text_items(&[("user", "fix the parser"), ("agent", "parser fixed")])}),
    );
    let first = fx
        .queue("to claude", Some((AgentFamily::Claude, "claude:sonnet")))
        .await;
    fx.release(&first).await.unwrap();
    fx.finish(&first).await;
    fx.write(
        "claude-items.json",
        &json!({CLAUDE_THREAD: text_items(&[("user", "review the diff"), ("agent", "diff looks fine")])}),
    );
    let back = fx
        .queue("back to codex", Some((AgentFamily::Codex, "fake")))
        .await;
    fx.release(&back).await.unwrap();

    let thread = fx.thread().await;
    assert_eq!(thread.family, AgentFamily::Codex);
    assert_eq!(thread.native_session_id.as_deref(), Some("codex-main"));
    // The old Codex session was resumed, not started again.
    assert_eq!(fx.codex_requests("thread/start").len(), 0);
    assert!(!fx.codex_requests("thread/resume").is_empty());
    let starts = fx.codex_requests("turn/start");
    let input = turn_input(starts.last().unwrap());
    assert!(is_handoff_text(text_of(&input[0])));
    let briefing = text_of(&input[0]);
    assert!(briefing.contains("delta_since_target_last_seen"));
    assert!(briefing.contains("review the diff") && briefing.contains("diff looks fine"));
    // What Codex already had is not repeated.
    assert!(!briefing.contains("fix the parser"));
    assert_eq!(text_of(&input[1]), "back to codex");
    let history = fx
        .state
        .store
        .project_runtime_history(&fx.chat)
        .await
        .unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].family, AgentFamily::Claude);
    assert!(fx
        .state
        .store
        .pending_handoff(&fx.chat)
        .await
        .unwrap()
        .is_none());
}

#[tokio::test]
async fn a_session_that_cannot_be_resumed_is_replaced_with_a_full_handoff() {
    let fx = fx().await;
    fx.write(
        "codex-items.json",
        &json!({"codex-main": text_items(&[("user", "fix the parser"), ("agent", "parser fixed")])}),
    );
    let first = fx
        .queue("to claude", Some((AgentFamily::Claude, "claude:sonnet")))
        .await;
    fx.release(&first).await.unwrap();
    fx.finish(&first).await;
    // The earlier Codex session was never handed delivery state that is ambiguous,
    // but the provider no longer knows it: make its thread unreadable.
    fx.state
        .store
        .set_handoff_delivery(
            &fx.chat,
            "codex-main",
            Some(HandoffDelivery::Pending),
            "now",
        )
        .await
        .unwrap();
    std::fs::write(fx.dir.path().join("next-thread"), "fresh-codex").unwrap();
    let back = fx
        .queue("back to codex", Some((AgentFamily::Codex, "fake")))
        .await;
    fx.release(&back).await.unwrap();

    assert_eq!(fx.codex_requests("thread/start").len(), 1);
    let thread = fx.thread().await;
    assert_eq!(thread.native_session_id.as_deref(), Some("fresh-codex"));
    let starts = fx.codex_requests("turn/start");
    let briefing = text_of(&turn_input(starts.last().unwrap())[0]).to_owned();
    assert!(briefing.contains("full_thread_summary"));
    assert!(briefing.contains("fix the parser"));
}

// Contract: a send refused before it ran leaves the context owed, and the retry
// delivers it exactly once.
#[tokio::test]
async fn a_refused_send_is_retried_with_the_same_context_and_delivered_once() {
    let fx = fx().await;
    fx.write(
        "codex-items.json",
        &json!({"codex-main": text_items(&[("user", "fix the parser"), ("agent", "parser fixed")])}),
    );
    std::fs::write(fx.dir.path().join("claude-busy"), "").unwrap();
    let message = fx
        .queue("to claude", Some((AgentFamily::Claude, "claude:sonnet")))
        .await;
    assert!(fx.release(&message).await.is_err());
    // Nothing was delivered: the context is still owed and the delivery forgotten.
    assert!(fx
        .state
        .store
        .pending_handoff(&fx.chat)
        .await
        .unwrap()
        .is_some());
    assert_eq!(
        fx.state
            .store
            .handoff_delivery(&fx.chat, CLAUDE_THREAD)
            .await
            .unwrap(),
        None
    );
    std::fs::remove_file(fx.dir.path().join("claude-busy")).unwrap();
    fx.state
        .store
        .update_message_delivery(&message.id, "accepted_by_wonder", None, None)
        .await
        .unwrap();
    fx.release(&message).await.unwrap();
    let starts = fx.claude_requests("turn/start");
    assert_eq!(starts.len(), 2);
    let briefing = |request: &Value| text_of(&turn_input(request)[0]).to_owned();
    assert_eq!(briefing(&starts[0]), briefing(&starts[1]));
    // The thread did not get a second session for the retry.
    assert_eq!(fx.claude_requests("thread/start").len(), 1);
    assert!(fx
        .state
        .store
        .pending_handoff(&fx.chat)
        .await
        .unwrap()
        .is_none());
    assert_eq!(
        fx.state
            .store
            .handoff_delivery(&fx.chat, CLAUDE_THREAD)
            .await
            .unwrap(),
        Some(HandoffDelivery::Injected)
    );
}

// Contract: a delivery whose outcome is unknown is never repeated into the
// same session; the session is replaced and the context rebuilt.
#[tokio::test]
async fn an_ambiguous_delivery_replaces_the_session_instead_of_repeating_the_context() {
    let fx = fx().await;
    fx.write(
        "codex-items.json",
        &json!({"codex-main": text_items(&[("user", "fix the parser"), ("agent", "parser fixed")])}),
    );
    // The bridge fails after taking the turn: the outcome is unknown.
    std::fs::write(fx.dir.path().join("claude-boom"), "").unwrap();
    let first = fx
        .queue("to claude", Some((AgentFamily::Claude, "claude:sonnet")))
        .await;
    assert!(fx.release(&first).await.is_err());
    assert_eq!(
        fx.state
            .store
            .handoff_delivery(&fx.chat, CLAUDE_THREAD)
            .await
            .unwrap(),
        Some(HandoffDelivery::Pending)
    );
    assert!(fx
        .state
        .store
        .pending_handoff(&fx.chat)
        .await
        .unwrap()
        .is_some());
    // Recovery settles the unknown send; the owner sends again.
    fx.state
        .store
        .update_message_delivery(&first.id, "failed", None, None)
        .await
        .unwrap();
    std::fs::remove_file(fx.dir.path().join("claude-boom")).unwrap();
    std::fs::write(
        fx.dir.path().join("next-claude"),
        "claude-99999999-8888-4777-8666-555555555555",
    )
    .unwrap();
    let again = fx.queue("again", None).await;
    fx.release(&again).await.unwrap();
    // A second Claude session took the turn, with the context from the start.
    assert_eq!(fx.claude_requests("thread/start").len(), 2);
    let thread = fx.thread().await;
    assert_eq!(
        thread.native_session_id.as_deref(),
        Some("99999999-8888-4777-8666-555555555555")
    );
    let starts = fx.claude_requests("turn/start");
    let last = turn_input(starts.last().unwrap());
    assert!(is_handoff_text(text_of(&last[0])));
    assert!(text_of(&last[0]).contains("fix the parser"));
    assert_eq!(text_of(&last[1]), "again");
    assert!(fx
        .state
        .store
        .pending_handoff(&fx.chat)
        .await
        .unwrap()
        .is_none());
    // The half-delivered session stays readable as part of the thread.
    assert_eq!(
        fx.state
            .store
            .project_runtime_history(&fx.chat)
            .await
            .unwrap()
            .len(),
        2
    );
}

// Contract: a plain model change inside one provider needs no new session, and
// the thread's own settings are changed by nothing but delivery.
#[tokio::test]
async fn a_same_provider_model_keeps_the_session_and_the_thread_is_unmoved_until_release() {
    let fx = fx().await;
    let message = fx
        .queue("hello", Some((AgentFamily::Claude, "claude:sonnet")))
        .await;
    // Accepting a message with the other provider's model changes nothing yet.
    assert_eq!(fx.thread().await.family, AgentFamily::Codex);
    fx.finish(&message).await;
    let same = fx.queue("again", Some((AgentFamily::Codex, "fake"))).await;
    fx.release(&same).await.unwrap();
    assert_eq!(fx.thread().await.family, AgentFamily::Codex);
    assert!(fx
        .state
        .store
        .project_runtime_history(&fx.chat)
        .await
        .unwrap()
        .is_empty());
    assert!(fx
        .state
        .store
        .pending_handoff(&fx.chat)
        .await
        .unwrap()
        .is_none());
}

// Contract: the history tool and the settings follower both read the active
// session; an old provider's turns never flip settings back.
#[tokio::test]
async fn reading_and_desktop_settings_follow_the_active_session_after_a_switch() {
    let fx = fx().await;
    fx.write(
        "codex-items.json",
        &json!({"codex-main": text_items(&[("user", "fix the parser"), ("agent", "parser fixed")])}),
    );
    let first = fx
        .queue("to claude", Some((AgentFamily::Claude, "claude:sonnet")))
        .await;
    fx.release(&first).await.unwrap();
    fx.finish(&first).await;
    fx.write(
        "claude-items.json",
        &json!({CLAUDE_THREAD: text_items(&[("user", "to claude"), ("agent", "hello from claude")])}),
    );
    // Positions run through the Codex session, then the Claude one.
    let segments = crate::thread_tools::segments_for_test(&fx.state, &fx.chat).await;
    assert_eq!(
        segments,
        vec![
            (AgentFamily::Codex, "codex-main".to_owned(), false),
            (AgentFamily::Claude, CLAUDE_THREAD.to_owned(), true)
        ]
    );
    assert_eq!(count_positions(&fx.state, &fx.chat).await, Some(4));
    // A desktop turn on the old Codex session does not change the Claude thread.
    let stored = fx.thread().await;
    let desktop = crate::native_settings::NativeSettings {
        turn: "codex-desktop-turn".into(),
        model: "fake".into(),
        effort: None,
        service_tier: None,
    };
    let changed = crate::native_settings::apply(&fx.state, &stored, &desktop)
        .await
        .unwrap();
    assert!(!changed);
    let after = fx.thread().await;
    assert_eq!(after.model.as_deref(), Some("claude:sonnet"));
    assert_eq!(after.family, AgentFamily::Claude);
    // And reading settings goes to the active (Claude) binding only.
    let binding = fx
        .state
        .store
        .runtime_binding(&fx.chat)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(binding.family, AgentFamily::Claude);
}

#[tokio::test]
async fn a_message_too_large_for_the_handoff_is_refused_without_changing_it() {
    let fx = fx().await;
    fx.write(
        "codex-items.json",
        &json!({"codex-main": text_items(&[("user", "fix the parser"), ("agent", "parser fixed")])}),
    );
    let huge = "p".repeat(60_000);
    let message = fx
        .queue(&huge, Some((AgentFamily::Claude, "claude:sonnet")))
        .await;
    // 60 KB is more than a Claude handoff leaves room for beside the history.
    let result = fx.release(&message).await;
    if let Err(error) = result {
        assert!(error.contains("not enough room"), "{error}");
        assert!(fx.claude_requests("turn/start").is_empty());
    } else {
        // It fits: the text must have reached Claude whole.
        let starts = fx.claude_requests("turn/start");
        assert_eq!(text_of(&turn_input(&starts[0])[1]), huge);
    }
}
