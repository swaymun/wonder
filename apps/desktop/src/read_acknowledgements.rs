//! Read receipts are tied to a laid-out snapshot, never a newly fetched global cursor.
use crate::client::Connection;
use gpui_kit::*;
use serde_json::{json, Value};
use std::{cell::RefCell, rc::Rc, sync::mpsc};

#[derive(Clone, Debug, PartialEq, Eq)]
struct Receipt {
    host: String,
    conversation: String,
    group: Option<String>,
    epoch: String,
    sequence: u64,
}
impl Receipt {
    fn from_snapshot(
        host: &str,
        conversation: &str,
        group: Option<&str>,
        snapshot: &Value,
    ) -> Option<Self> {
        if host.is_empty()
            || snapshot["conversationId"] != conversation
            || !snapshot["messages"].is_array()
            || (group.is_none()
                && (!snapshot["assistantMessages"].is_array() || !snapshot["thread"].is_object()))
            || group.is_some_and(|id| snapshot["id"] != id)
        {
            return None;
        }
        // `hydrated` describes runtime-history loading, not the authority of this
        // persisted daemon snapshot (conversation_thread_projection sets false).
        let epoch = snapshot["hostEpoch"].as_str()?.to_owned();
        if epoch.is_empty() {
            return None;
        }
        Some(Self {
            host: host.into(),
            conversation: conversation.into(),
            group: group.map(str::to_owned),
            epoch,
            sequence: snapshot["lastSequence"].as_u64()?,
        })
    }
    fn request(&self) -> (&'static str, Vec<String>, Value) {
        if let Some(group) = &self.group {
            (
                "POST",
                vec![
                    "api".into(),
                    "v1".into(),
                    "group-chats".into(),
                    group.clone(),
                    "read".into(),
                ],
                json!({"hostEpoch":self.epoch,"readThroughSequence":self.sequence}),
            )
        } else {
            (
                "PATCH",
                vec![
                    "api".into(),
                    "v1".into(),
                    "conversations".into(),
                    self.conversation.clone(),
                ],
                json!({"markRead":true,"hostEpoch":self.epoch,"readThroughSequence":self.sequence}),
            )
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Snapshot {
    receipt: Receipt,
    revision: u64,
}

pub struct ReadAcknowledgements {
    current: Option<Snapshot>,
    revision: u64,
    painted: Rc<RefCell<Option<Snapshot>>>,
    pending: Option<Receipt>,
    attempted: Option<Snapshot>,
    confirmed: Option<Receipt>,
    sender: mpsc::Sender<(Receipt, bool)>,
    receiver: mpsc::Receiver<(Receipt, bool)>,
}
impl Default for ReadAcknowledgements {
    fn default() -> Self {
        let (sender, receiver) = mpsc::channel();
        Self {
            current: None,
            revision: 0,
            painted: Rc::default(),
            pending: None,
            attempted: None,
            confirmed: None,
            sender,
            receiver,
        }
    }
}
impl ReadAcknowledgements {
    pub fn clear(&mut self) {
        self.revision = self.revision.wrapping_add(1);
        self.current = None;
        self.painted.borrow_mut().take();
    }
    pub fn observe_snapshot(
        &mut self,
        host: &str,
        conversation: &str,
        group: Option<&str>,
        snapshot: &Value,
        unread: bool,
    ) {
        self.clear();
        if unread {
            self.current =
                Receipt::from_snapshot(host, conversation, group, snapshot).map(|receipt| {
                    Snapshot {
                        receipt,
                        revision: self.revision,
                    }
                });
        }
    }
    pub fn layout_listener(
        &self,
        scroll: ScrollHandle,
        rows: usize,
    ) -> impl Fn(Vec<Bounds<Pixels>>, &mut Window, &mut App) + 'static {
        let snapshot = self.current.clone();
        let painted = self.painted.clone();
        move |_, window, _| {
            painted.borrow_mut().take();
            if !window.is_window_active() {
                return;
            }
            let Some(snapshot) = snapshot.as_ref() else {
                return;
            };
            let Some(index) = rows.checked_sub(1) else {
                return;
            };
            // Tracked child bounds are before this container's scrolling; the listener
            // runs after prepaint has clamped/applied that frame's offset.
            let Some(mut frame) = scroll.bounds_for_item(index) else {
                return;
            };
            frame.origin += scroll.offset();
            let viewport = scroll
                .bounds()
                .intersect(&Bounds::new(Point::default(), window.viewport_size()));
            if latest_end_visible(frame, viewport) {
                *painted.borrow_mut() = Some(snapshot.clone());
            }
        }
    }
    pub fn tick(
        &mut self,
        connection: Option<&Connection>,
        selected: Option<&str>,
        host: Option<&str>,
        visible: bool,
    ) {
        while let Ok((receipt, confirmed)) = self.receiver.try_recv() {
            if self.pending.as_ref() == Some(&receipt) {
                self.pending = None;
            }
            if confirmed {
                self.confirmed = Some(receipt);
            }
            // Never apply an asynchronous reply to the Chats list. Its existing refresh
            // reloads authoritative summaries, so a late read cannot hide a newer unread.
        }
        if !visible {
            self.painted.borrow_mut().take();
            return;
        }
        if self.pending.is_some() {
            return;
        }
        let Some(painted) = self.painted.borrow_mut().take() else {
            return;
        };
        if !accepts_paint(self.current.as_ref(), &painted, selected, host, visible)
            || self.attempted.as_ref() == Some(&painted)
            || self.confirmed.as_ref() == Some(&painted.receipt)
        {
            return;
        }
        let Some(connection) = connection.cloned() else {
            return;
        };
        self.attempted = Some(painted.clone());
        let receipt = painted.receipt;
        self.pending = Some(receipt.clone());
        let sender = self.sender.clone();
        std::thread::spawn(move || {
            let (method, path, body) = receipt.request();
            let confirmed = connection
                .request(method, &path, &body, &receipt.host)
                .is_ok_and(|reply| {
                    reply["conversationId"] == receipt.conversation && reply["hasUnread"] == false
                });
            let _ = sender.send((receipt, confirmed));
        });
    }
}
fn accepts_paint(
    current: Option<&Snapshot>,
    painted: &Snapshot,
    selected: Option<&str>,
    host: Option<&str>,
    visible: bool,
) -> bool {
    visible
        && current == Some(painted)
        && selected == Some(painted.receipt.conversation.as_str())
        && host == Some(painted.receipt.host.as_str())
}
fn latest_end_visible(frame: Bounds<Pixels>, viewport: Bounds<Pixels>) -> bool {
    frame.size.width > px(0.)
        && frame.size.height > px(0.)
        && viewport.size.width > px(0.)
        && viewport.size.height > px(0.)
        && frame.bottom() >= viewport.top()
        && frame.bottom() <= viewport.bottom()
        && frame.right() > viewport.left()
        && frame.left() < viewport.right()
}

#[cfg(test)]
mod tests {
    use super::{accepts_paint, latest_end_visible, Receipt, Snapshot};
    use gpui_kit::{point, px, size, Bounds};
    use serde_json::json;
    fn snapshot(sequence: u64) -> serde_json::Value {
        json!({"conversationId":"chat","hostEpoch":"epoch","lastSequence":sequence,"messages":[],"assistantMessages":[],"thread":{"hydrated":false,"turns":[]}})
    }
    #[test]
    fn request_uses_displayed_sequence_and_correct_atomic_route() {
        let receipt = Receipt::from_snapshot("host", "chat", None, &snapshot(7)).unwrap();
        let (method, path, body) = receipt.request();
        assert_eq!(method, "PATCH");
        assert_eq!(path, ["api", "v1", "conversations", "chat"]);
        assert_eq!(
            body,
            json!({"markRead":true,"hostEpoch":"epoch","readThroughSequence":7})
        );
        let mut group = snapshot(8);
        group["id"] = json!("group");
        let receipt = Receipt::from_snapshot("host", "chat", Some("group"), &group).unwrap();
        let (method, path, body) = receipt.request();
        assert_eq!(method, "POST");
        assert_eq!(path, ["api", "v1", "group-chats", "group", "read"]);
        assert_eq!(body, json!({"hostEpoch":"epoch","readThroughSequence":8}));
        assert!(Receipt::from_snapshot("host", "elsewhere", None, &group).is_none());
        assert!(Receipt::from_snapshot("host", "chat", Some("other"), &group).is_none());
        let mut incomplete = snapshot(9);
        incomplete["messages"] = serde_json::Value::Null;
        assert!(Receipt::from_snapshot("host", "chat", None, &incomplete).is_none());
    }
    #[test]
    fn persisted_production_snapshot_is_readable_without_runtime_hydration() {
        let mut persisted: serde_json::Value = serde_json::from_str(include_str!(
            "../../../tests/contracts/native/conversation-snapshot.json"
        ))
        .unwrap();
        // The daemon's current persisted projection always sets hydrated=false.
        persisted["thread"]["hydrated"] = json!(false);
        assert!(!crate::client::rows(&persisted, "Bot", None).is_empty());
        let receipt = Receipt::from_snapshot("host", "default", None, &persisted).unwrap();
        assert_eq!(receipt.sequence, 55);
        assert_eq!(receipt.epoch, "contract-epoch");
        assert_eq!(receipt.request().2["readThroughSequence"], 55);
    }
    #[test]
    fn latest_message_end_must_be_in_the_actual_viewport() {
        let viewport = Bounds::new(point(px(10.), px(100.)), size(px(300.), px(400.)));
        let frame = |y, h| Bounds::new(point(px(20.), px(y)), size(px(200.), px(h)));
        assert!(latest_end_visible(frame(200., 100.), viewport));
        assert!(latest_end_visible(frame(-500., 1000.), viewport));
        assert!(!latest_end_visible(frame(200., 1000.), viewport));
        assert!(!latest_end_visible(frame(-500., 100.), viewport));
        assert!(!latest_end_visible(frame(500., 100.), viewport));
        assert!(!latest_end_visible(frame(200., 0.), viewport));
    }
    #[test]
    fn unseen_new_snapshot_chat_host_and_cover_invalidate_layout_proof() {
        let painted = Snapshot {
            receipt: Receipt::from_snapshot("host", "chat", None, &snapshot(7)).unwrap(),
            revision: 1,
        };
        assert!(accepts_paint(
            Some(&painted),
            &painted,
            Some("chat"),
            Some("host"),
            true
        ));
        let mut newer = painted.clone();
        newer.receipt.sequence = 8;
        assert!(!accepts_paint(
            Some(&newer),
            &painted,
            Some("chat"),
            Some("host"),
            true
        ));
        newer = painted.clone();
        newer.revision += 1;
        assert!(!accepts_paint(
            Some(&newer),
            &painted,
            Some("chat"),
            Some("host"),
            true
        ));
        assert!(!accepts_paint(
            Some(&painted),
            &painted,
            Some("other"),
            Some("host"),
            true
        ));
        assert!(!accepts_paint(
            Some(&painted),
            &painted,
            Some("chat"),
            Some("other"),
            true
        ));
        assert!(!accepts_paint(
            Some(&painted),
            &painted,
            Some("chat"),
            Some("host"),
            false
        ));
    }
}
