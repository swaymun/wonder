//! The public website only explains native pairing; it cannot access a workspace.
use axum::{
    http::header,
    response::{Html, IntoResponse, Redirect},
};

pub async fn root() -> Redirect {
    Redirect::temporary("/pair")
}
pub async fn page() -> Html<&'static str> {
    Html(include_str!("pairing_web/index.html"))
}
pub async fn style() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
        include_str!("pairing_web/style.css"),
    )
}
#[cfg(test)]
mod tests {
    use axum::{
        body::{to_bytes, Body},
        http::{Request, StatusCode},
    };
    use tower::ServiceExt;

    #[tokio::test]
    async fn browser_routes_only_expose_pairing_and_native_api_stays_authenticated() {
        let (_dir, state) = crate::ingestion::tests::fixture().await;
        let router = crate::router(state.clone());
        for (path, expected) in [
            ("/", StatusCode::TEMPORARY_REDIRECT),
            ("/pair", StatusCode::OK),
            ("/pair/style.css", StatusCode::OK),
            ("/sw.js", StatusCode::NOT_FOUND),
            ("/manifest.webmanifest", StatusCode::NOT_FOUND),
            ("/precache-manifest.json", StatusCode::NOT_FOUND),
            ("/assets/index.js", StatusCode::NOT_FOUND),
            ("/index.html", StatusCode::NOT_FOUND),
            ("/bots", StatusCode::NOT_FOUND),
        ] {
            let response = router
                .clone()
                .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), expected, "{path}");
            assert_eq!(response.headers()["cache-control"], "no-store");
            assert!(response.headers().contains_key("content-security-policy"));
            if path == "/" {
                assert_eq!(response.headers()["location"], "/pair");
            }
            if path == "/pair" {
                let body = to_bytes(response.into_body(), 65536).await.unwrap();
                let html = std::str::from_utf8(&body).unwrap();
                assert!(html.contains("Open Wonder on your iPhone or iPad"));
                assert!(!html.contains("<script"));
                assert!(!html.contains("manifest"));
            }
        }
        let response = router
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/bots")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert!(!response.status().is_success());
        let response = router
            .oneshot(
                Request::builder()
                    .uri("/api/v1/bots")
                    .header("x-wonder-loopback-capability", &state.loopback_capability)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        state.app_server.lock().await.shutdown().await.unwrap();
    }
}
