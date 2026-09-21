use super::{save_pending, Page};
use serde_json::{json, Value};
use std::path::PathBuf;

pub(super) struct Drafts {
    path: PathBuf,
    values: Value,
}
impl Drafts {
    pub fn load(path: PathBuf) -> Result<Self, String> {
        let values = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<Value>(&bytes)
                .ok()
                .filter(Value::is_object)
                .ok_or("Saved form drafts could not be read. They have been preserved.")?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => json!({}),
            Err(_) => {
                return Err("Saved form drafts could not be read. They have been preserved.".into())
            }
        };
        Ok(Self { path, values })
    }
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.values.get(key)
    }
    pub fn put(&mut self, key: &str, value: Value) -> Result<(), String> {
        self.values[key] = value;
        self.save()
    }
    pub fn remove(&mut self, key: &str) -> Result<(), String> {
        self.values
            .as_object_mut()
            .expect("draft object")
            .remove(key);
        self.save()
    }
    fn save(&self) -> Result<(), String> {
        save_pending(&self.path,&self.values).map_err(|_|"Your form draft could not be saved. Keep this form open and check available disk space.".into())
    }
}
pub(super) fn key(host: &str, page: &Page) -> Option<String> {
    let page = match page {
        Page::Bot(id) => format!("bot:{}", id.as_deref().unwrap_or("new")),
        Page::Group => "group:new".into(),
        Page::GroupEdit(id) => format!("group:{id}"),
        Page::GroupBot(group, bot) => format!("group:{group}:bot:{bot}"),
        Page::Automation(scope, id) => {
            format!("automation:{}:{}", scope.id, id.as_deref().unwrap_or("new"))
        }
        Page::FileAccess(id) => format!("files:{id}"),
        _ => return None,
    };
    Some(format!("{host}:{page}"))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn drafts_restore_per_host_and_discard_only_the_selected_form() {
        let path = std::env::temp_dir().join(format!("wonder-forms-{}.json", uuid::Uuid::new_v4()));
        let a = key("host-a", &Page::Bot(None)).unwrap();
        let b = key("host-b", &Page::Bot(None)).unwrap();
        let mut drafts = Drafts::load(path.clone()).unwrap();
        drafts
            .put(&a, json!({"fields":{"name":"Ada","role":"Research"}}))
            .unwrap();
        drafts.put(&b, json!({"fields":{"name":"Milo"}})).unwrap();
        let mut restored = Drafts::load(path.clone()).unwrap();
        assert_eq!(restored.get(&a).unwrap()["fields"]["name"], "Ada");
        restored.remove(&a).unwrap();
        let restored = Drafts::load(path.clone()).unwrap();
        assert!(restored.get(&a).is_none());
        assert_eq!(restored.get(&b).unwrap()["fields"]["name"], "Milo");
        std::fs::write(&path, b"broken").unwrap();
        assert!(Drafts::load(path.clone()).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"broken");
        std::fs::remove_file(path).unwrap();
    }
}
