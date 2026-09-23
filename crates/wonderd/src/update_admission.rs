//! A short, process-local barrier while Sparkle swaps the host application.
//! An expired or restarted daemon admits work normally again.
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
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use wonder_store::Store;

const LEASE_DURATION: Duration = Duration::from_secs(60);

#[derive(Default)]
pub struct UpdateAdmission {
    lease: Mutex<Option<Lease>>,
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
            Some(lease)
        }
    }

    async fn prepare_lease(
        &self,
        request_id: &str,
        store: &Store,
        host_installation_id: &str,
        dispatch_lock: &Mutex<()>,
    ) -> Result<(), StatusCode> {
        let mut lease = self.lease.lock().await;
        if Self::current(&mut lease)
            && lease
                .as_ref()
                .is_some_and(|value| value.request_id != request_id)
        {
            return Err(StatusCode::CONFLICT);
        }
        // Dispatch and Group acceptance already use this lock. Holding it
        // while checking durable state prevents a claim from changing beneath
        // the check.
        let _dispatch = dispatch_lock.lock().await;
        match store.has_update_blocking_work(host_installation_id).await {
            Ok(false) => {}
            Ok(true) => return Err(StatusCode::CONFLICT),
            Err(_) => return Err(StatusCode::SERVICE_UNAVAILABLE),
        }
        *lease = Some(Lease {
            request_id: request_id.to_owned(),
            expires: Instant::now() + LEASE_DURATION,
        });
        Ok(())
    }

    async fn cancel_lease(&self, request_id: &str) -> bool {
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
        .prepare_lease(
            &request.request_id,
            &state.store,
            &state.host_installation_id,
            &state.dispatch_lock,
        )
        .await
    {
        Ok(()) => {}
        Err(StatusCode::CONFLICT) => {
            return (StatusCode::CONFLICT, "Wait for Wonder's work to finish.").into_response()
        }
        Err(status) => return status.into_response(),
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
    use std::sync::Arc;

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
    async fn preparation_waits_for_admission_and_sees_accepted_work() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_owner_device("device", "Owner", "{}", "now")
            .await
            .unwrap();
        let admission = Arc::new(UpdateAdmission::default());
        let dispatch_lock = Mutex::new(());
        let in_flight = admission.claim_guard().await.unwrap();
        let preparing = admission.prepare_lease("request", &store, "host", &dispatch_lock);
        tokio::pin!(preparing);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut preparing)
                .await
                .is_err()
        );
        store
            .insert_dispatch_message("device", "client", "body", "hash", "bot", &[], "now", true)
            .await
            .unwrap();
        drop(in_flight);
        assert_eq!(preparing.await, Err(StatusCode::CONFLICT));
        assert!(admission.claim_guard().await.is_some());
    }

    #[tokio::test]
    async fn lease_blocks_admission_until_cancel_or_expiry() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let admission = UpdateAdmission::default();
        let dispatch_lock = Mutex::new(());
        admission
            .prepare_lease("first", &store, "host", &dispatch_lock)
            .await
            .unwrap();
        assert!(admission.claim_guard().await.is_none());
        assert_eq!(
            admission
                .prepare_lease("second", &store, "host", &dispatch_lock)
                .await,
            Err(StatusCode::CONFLICT)
        );
        assert!(!admission.cancel_lease("second").await);
        assert!(admission.claim_guard().await.is_none());
        admission
            .prepare_lease("first", &store, "host", &dispatch_lock)
            .await
            .unwrap();
        assert!(admission.cancel_lease("first").await);
        assert!(admission.claim_guard().await.is_some());
        admission
            .prepare_lease("first", &store, "host", &dispatch_lock)
            .await
            .unwrap();
        {
            let mut lease = admission.lease.lock().await;
            lease.as_mut().unwrap().expires = Instant::now() - Duration::from_secs(1);
        }
        assert!(admission.claim_guard().await.is_some());
    }
}
