use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub(super) struct Locations {
    pub read_roots: Vec<String>,
    pub write_roots: Vec<String>,
}
impl Locations {
    pub fn add(&mut self, paths: Vec<String>, write: bool) -> Result<(), String> {
        let mut next = self.clone();
        for path in paths {
            next.read_roots.retain(|v| v != &path);
            next.write_roots.retain(|v| v != &path);
            if write {
                next.write_roots.push(path);
            } else {
                next.read_roots.push(path);
            }
        }
        if next.read_roots.len() + next.write_roots.len() > 32 {
            return Err("Choose up to 32 files or folders.".into());
        }
        *self = next;
        Ok(())
    }
    pub fn remove(&mut self, path: &str, write: bool) {
        if write {
            self.write_roots.retain(|v| v != path);
        } else {
            self.read_roots.retain(|v| v != path);
        }
    }
    pub fn folders(&self) -> Vec<String> {
        self.read_roots
            .iter()
            .chain(&self.write_roots)
            .filter(|v| std::path::Path::new(v).is_dir())
            .cloned()
            .collect()
    }
    pub fn from_draft(value: &Value) -> Option<Self> {
        if value["locations"].is_object() {
            return serde_json::from_value(value["locations"].clone()).ok();
        }
        // Preserve drafts made by the former text-entry editor.
        if value["fields"]["readRoots"].is_string() || value["fields"]["writeRoots"].is_string() {
            let roots = |key| {
                value["fields"][key]
                    .as_str()
                    .unwrap_or("")
                    .lines()
                    .filter(|v| !v.trim().is_empty())
                    .map(str::to_owned)
                    .collect()
            };
            return Some(Self {
                read_roots: roots("readRoots"),
                write_roots: roots("writeRoots"),
            });
        }
        None
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn selecting_again_changes_access_without_duplicate_entries() {
        let mut locations = Locations::default();
        locations
            .add(vec!["/tmp/report.txt".into(), "/tmp/project".into()], false)
            .unwrap();
        locations
            .add(
                vec!["/tmp/report.txt".into(), "/tmp/report.txt".into()],
                true,
            )
            .unwrap();
        assert_eq!(locations.read_roots, vec!["/tmp/project"]);
        assert_eq!(locations.write_roots, vec!["/tmp/report.txt"]);
        locations.remove("/tmp/report.txt", true);
        assert!(locations.write_roots.is_empty());
    }
    #[test]
    fn selected_paths_round_trip_losslessly_in_creation_drafts_and_payloads() {
        let mut locations = Locations::default();
        locations
            .add(vec!["/tmp/line\nbreak.txt".into()], false)
            .unwrap();
        let draft = json!({"locations":locations});
        let restored = Locations::from_draft(&draft).unwrap();
        let payload = serde_json::to_value(&restored).unwrap();
        assert_eq!(payload["readRoots"][0], "/tmp/line\nbreak.txt");
        assert_eq!(payload["writeRoots"], json!([]));
        assert!(Locations::from_draft(
            &json!({"fields":{"readRoots":"/tmp/old.txt","writeRoots":""}})
        )
        .is_some());
    }
    #[test]
    fn location_limit_rejects_batch_without_losing_existing_choices() {
        let mut locations = Locations::default();
        locations.add(vec!["/tmp/existing".into()], false).unwrap();
        assert!(locations
            .add((0..32).map(|n| format!("/tmp/new-{n}")).collect(), true)
            .is_err());
        assert_eq!(locations.read_roots, vec!["/tmp/existing"]);
        assert!(locations.write_roots.is_empty());
    }
}
