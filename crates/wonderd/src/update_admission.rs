//! Fence new work while the host persists and pauses update continuations.
//! Cancellation, expiry or a replacement daemon recovers the durable handoff.
use crate::{AppState, LocalOwnerAuthority};
use axum::{
    body::Body,
    extract::{Extension, State},
    http::{Method, Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use chrono::{Duration as ChronoDuration, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use std::{
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
use tokio::sync::Mutex;

const LEASE_DURATION: Duration = Duration::from_secs(60);

#[derive(Default)]
pub struct UpdateAdmission {
    lease: Mutex<Option<Lease>>,
    paused: AtomicBool,
}

pub(crate) struct Lease {
    request_id: String,
    expires: Instant,
}

impl UpdateAdmission {
    fn current(lease: &mut Option<Lease>) -> bool {
        if lease
            .as_ref()
            .is_some_and(|value| value.expires <= Instant::now())
        {
            *lease = None;
        }
        lease.is_some()
    }

    /// Scheduler claims use the same barrier as HTTP admissions.
    pub(crate) async fn claim_guard(&self) -> Option<tokio::sync::MutexGuard<'_, Option<Lease>>> {
        let mut lease = self.lease.lock().await;
        if Self::current(&mut lease) {
            None
        } else {
            self.paused.store(false, Ordering::Release);
            Some(lease)
        }
    }

    pub(crate) fn work_paused(&self) -> bool {
        self.paused.load(Ordering::Acquire)
    }

    /// Background Group/automation tasks can reach dispatch after the HTTP
    /// admission has finished. Fence their native submits at the shared lock.
    pub(crate) async fn dispatch_guard<'a>(
        &self,
        lock: &'a Mutex<()>,
    ) -> tokio::sync::MutexGuard<'a, ()> {
        loop {
            while self.work_paused() {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            let guard = lock.lock().await;
            if !self.work_paused() {
                return guard;
            }
        }
    }

    pub(crate) async fn prepare_update(
        &self,
        request_id: &str,
        state: &AppState,
    ) -> Result<(), (StatusCode, String)> {
        let mut lease = self.lease.lock().await;
        if Self::current(&mut lease) && lease.as_ref().is_some_and(|l| l.request_id != request_id) {
            return Err((
                StatusCode::CONFLICT,
                "Another update is being prepared.".into(),
            ));
        }
        let _dispatch = state.dispatch_lock.lock().await;
        self.paused.store(true, Ordering::Release);
        *lease = Some(Lease {
            request_id: request_id.into(),
            expires: Instant::now() + LEASE_DURATION,
        });
        let paused = tokio::time::timeout(
            Duration::from_secs(25),
            crate::update_handoff::pause(state, request_id),
        )
        .await;
        match paused {
            Ok(Ok(())) => {
                lease.as_mut().unwrap().expires = Instant::now() + LEASE_DURATION;
                Ok(())
            }
            result => {
                *lease = None;
                self.paused.store(false, Ordering::Release);
                let message = match result {
                    Ok(Err(message)) => message,
                    _ => "Work could not be safely paused. The update will retry.".into(),
                };
                Err((StatusCode::CONFLICT, message))
            }
        }
    }

    pub(crate) async fn cancel_lease(&self, request_id: &str) -> bool {
        let mut lease = self.lease.lock().await;
        if Self::current(&mut lease) {
            if lease
                .as_ref()
                .is_some_and(|value| value.request_id != request_id)
            {
                return false;
            }
            *lease = None;
        }
        self.paused.store(false, Ordering::Release);
        true
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateRequest {
    request_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Prepared {
    ready: bool,
    request_id: String,
    expires_at: String,
}

pub(crate) async fn prepare(
    State(state): State<AppState>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Json(request): Json<UpdateRequest>,
) -> Response {
    if local.is_none() {
        return StatusCode::FORBIDDEN.into_response();
    }
    if uuid::Uuid::parse_str(&request.request_id).is_err() {
        return (StatusCode::BAD_REQUEST, "requestId must be a UUID").into_response();
    }
    match state
        .update_admission
        .prepare_update(&request.request_id, &state)
        .await
    {
        Ok(()) => {}
        Err(error) => return error.into_response(),
    }
    let expires_at =
        (Utc::now() + ChronoDuration::seconds(60)).to_rfc3339_opts(SecondsFormat::Millis, true);
    Json(Prepared {
        ready: true,
        request_id: request.request_id,
        expires_at,
    })
    .into_response()
}

pub(crate) async fn cancel(
    State(state): State<AppState>,
    local: Option<Extension<LocalOwnerAuthority>>,
    Json(request): Json<UpdateRequest>,
) -> Response {
    if local.is_none() {
        return StatusCode::FORBIDDEN.into_response();
    }
    if uuid::Uuid::parse_str(&request.request_id).is_err() {
        return (StatusCode::BAD_REQUEST, "requestId must be a UUID").into_response();
    }
    if !state
        .update_admission
        .cancel_lease(&request.request_id)
        .await
    {
        return StatusCode::CONFLICT.into_response();
    }
    StatusCode::NO_CONTENT.into_response()
}

fn admits_work(method: &Method, path: &str) -> bool {
    if method != Method::POST {
        return false;
    }
    // These routes can persist a new user turn, automation, assignment, Bot
    // onboarding task, or computer session/control lease.
    (path.starts_with("/api/v1/conversations/")
        && (path.ends_with("/messages") || path.ends_with("/steer")))
        || ((path.starts_with("/api/v1/channels/") || path.starts_with("/api/v1/group-chats/"))
            && path.ends_with("/messages"))
        || (path.starts_with("/api/v1/messages/") && path.ends_with("/retry"))
        || (path.starts_with("/api/v1/automations/") && path.ends_with("/run"))
        || (path.starts_with("/api/v1/groups/") && path.ends_with("/assignments"))
        || (path.starts_with("/api/v1/assignments/") && path.ends_with("/integrate"))
        || matches!(
            path,
            "/api/v1/bots/new"
                | "/api/v1/bots"
                | "/api/v1/group-chats/new"
                | "/api/v1/group-chats/propose"
        )
        || (path.starts_with("/api/v1/group-chats/") && path.ends_with("/retry"))
        // A project thread's first message starts native provider work.
        || (path.starts_with("/api/v1/projects/") && path.ends_with("/threads"))
        || (path.starts_with("/api/v1/bots/")
            && (path.ends_with("/teaching/sessions") || path.ends_with("/fixture-tests")))
        || path == "/api/v1/computer/sessions"
        || (path.starts_with("/api/v1/computer/sessions/")
            && (path.ends_with("/admission")
                || path.ends_with("/control/acquire")
                || path.ends_with("/control/resume")))
}

pub(crate) async fn guard_new_work(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if !admits_work(request.method(), request.uri().path()) {
        return next.run(request).await;
    }
    let Some(_guard) = state.update_admission.claim_guard().await else {
        return (
            StatusCode::CONFLICT,
            "Wonder is preparing to update. Try again shortly.",
        )
            .into_response();
    };
    next.run(request).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gate_covers_all_work_admissions() {
        for path in [
            "/api/v1/conversations/id/messages",
            "/api/v1/channels/id/messages",
            "/api/v1/group-chats/id/messages",
            "/api/v1/messages/id/retry",
            "/api/v1/automations/id/run",
            "/api/v1/groups/id/assignments",
            "/api/v1/assignments/id/integrate",
            "/api/v1/bots/new",
            "/api/v1/group-chats/id/retry",
            "/api/v1/bots/id/teaching/sessions",
            "/api/v1/computer/sessions",
            "/api/v1/computer/sessions/id/admission",
            "/api/v1/computer/sessions/id/control/acquire",
            "/api/v1/projects/id/threads",
        ] {
            assert!(admits_work(&Method::POST, path), "{path}");
        }
        assert!(!admits_work(&Method::POST, "/api/v1/host/update/cancel"));
        assert!(!admits_work(
            &Method::GET,
            "/api/v1/conversations/id/messages"
        ));
    }

    #[tokio::test]
    async fn preparation_waits_for_admission_and_preserves_queued_work() {
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        let store = &state.store;
        let admission = &state.update_admission;
        let in_flight = admission.claim_guard().await.unwrap();
        let preparing = admission.prepare_update("request", &state);
        tokio::pin!(preparing);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut preparing)
                .await
                .is_err()
        );
        store
            .insert_dispatch_message("owner", "client", "body", "hash", "bot", &[], "now", true)
            .await
            .unwrap();
        drop(in_flight);
        assert_eq!(preparing.await, Ok(()));
        assert_eq!(store.pending_dispatch_messages().await.unwrap().len(), 1);
        assert!(admission.claim_guard().await.is_none());
    }

    #[tokio::test]
    async fn lease_blocks_admission_until_cancel_or_expiry() {
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        let admission = &state.update_admission;
        admission.prepare_update("first", &state).await.unwrap();
        assert!(admission.claim_guard().await.is_none());
        assert_eq!(
            admission.prepare_update("second", &state).await,
            Err((
                StatusCode::CONFLICT,
                "Another update is being prepared.".into()
            ))
        );
        assert!(!admission.cancel_lease("second").await);
        assert!(admission.claim_guard().await.is_none());
        admission.prepare_update("first", &state).await.unwrap();
        assert!(admission.cancel_lease("first").await);
        assert!(admission.claim_guard().await.is_some());
        admission.prepare_update("first", &state).await.unwrap();
        {
            let mut lease = admission.lease.lock().await;
            lease.as_mut().unwrap().expires = Instant::now() - Duration::from_secs(1);
        }
        assert!(admission.claim_guard().await.is_some());
    }

    #[tokio::test]
    async fn background_dispatch_waits_for_cancel_and_remote_clients_have_no_update_authority() {
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        let request = uuid::Uuid::new_v4().to_string();
        let response = prepare(
            State(state.clone()),
            None,
            Json(UpdateRequest {
                request_id: request.clone(),
            }),
        )
        .await;
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        state
            .update_admission
            .prepare_update(&request, &state)
            .await
            .unwrap();
        let dispatch = state.update_admission.dispatch_guard(&state.dispatch_lock);
        tokio::pin!(dispatch);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut dispatch)
                .await
                .is_err()
        );
        assert!(state.update_admission.cancel_lease(&request).await);
        assert!(tokio::time::timeout(Duration::from_secs(1), &mut dispatch)
            .await
            .is_ok());
    }
}
