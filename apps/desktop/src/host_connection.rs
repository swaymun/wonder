//! Authenticated loopback access for Mac Settings. No chat or message APIs.
use reqwest::{blocking::Client, redirect::Policy, Url};
use serde_json::Value;
use std::time::Duration;

#[derive(Clone)]
pub struct Connection {
    pub origin: Url,
    capability: String,
    http: Client,
}
impl Connection {
    pub fn from_environment() -> Result<Self, String> {
        let address = std::env::var("WONDER_LISTEN_ADDR").unwrap_or("127.0.0.1:3777".into());
        let origin = Url::parse(&format!("http://{address}")).map_err(|_| "Invalid Mac address")?;
        if origin.host_str() != Some("127.0.0.1")
            || origin.path() != "/"
            || origin.query().is_some()
            || origin.fragment().is_some()
            || !origin.username().is_empty()
            || origin.password().is_some()
        {
            return Err("Mac connection must use local loopback".into());
        }
        let capability =
            std::env::var("WONDER_LOOPBACK_CAPABILITY").map_err(|_| "Reopen Wonder on your Mac")?;
        if capability.is_empty() {
            return Err("Reopen Wonder on your Mac".into());
        }
        let http = Client::builder()
            .no_proxy()
            .redirect(Policy::none())
            .timeout(Duration::from_secs(8))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self {
            origin,
            capability,
            http,
        })
    }
    fn url(&self, parts: &[&str]) -> Url {
        let mut url = self.origin.clone();
        {
            let mut segments = url.path_segments_mut().expect("HTTP base URL");
            segments.clear().extend(parts);
        }
        url
    }
    pub fn get(&self, parts: &[&str]) -> Result<Value, String> {
        self.get_url(self.url(parts))
    }
    fn get_url(&self, url: Url) -> Result<Value, String> {
        let response = self
            .http
            .get(url)
            .header("x-wonder-loopback-capability", &self.capability)
            .send()
            .map_err(|_| "Mac unavailable. Reopen Wonder and try again.")?;
        if !response.status().is_success() {
            return Err("Couldn’t load these settings. Reopen Wonder and try again.".into());
        }
        response
            .json()
            .map_err(|_| "The Mac returned an unreadable response".into())
    }
    pub fn request(
        &self,
        method: &str,
        parts: &[String],
        body: &Value,
        host: &str,
    ) -> Result<Value, String> {
        if self.get(&["api", "v1", "host", "status"])?["hostInstallationId"] != host {
            return Err("Mac identity changed. Reopen Wonder.".into());
        }
        let method =
            reqwest::Method::from_bytes(method.as_bytes()).map_err(|_| "Invalid action")?;
        let deleting = method == reqwest::Method::DELETE;
        let response = self
            .http
            .request(
                method,
                self.url(&parts.iter().map(String::as_str).collect::<Vec<_>>()),
            )
            .header("x-wonder-loopback-capability", &self.capability)
            .json(body)
            .send()
            .map_err(|_| {
                "The Mac did not confirm this change. Refresh Settings before trying again."
            })?;
        let status = response.status();
        if deleting && status.as_u16() == 404 {
            return Ok(Value::Null);
        }
        if !status.is_success() {
            let message = response.text().unwrap_or_default();
            let message = if message.len() <= 500 && !message.trim().is_empty() {
                message
            } else {
                format!(
                    "The Mac could not complete this change ({}).",
                    status.as_u16()
                )
            };
            return Err(if status.is_client_error() && status.as_u16() != 408 {
                format!("Rejected: {message}")
            } else {
                message
            });
        }
        let bytes = response
            .bytes()
            .map_err(|_| "The change was not confirmed. Refresh Settings before trying again.")?;
        if bytes.is_empty() {
            Ok(Value::Null)
        } else {
            serde_json::from_slice(&bytes).map_err(|_| {
                "The change was not confirmed. Refresh Settings before trying again.".into()
            })
        }
    }
}
