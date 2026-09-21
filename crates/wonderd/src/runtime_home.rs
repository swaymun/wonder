//! Keep Wonder's runtime history out of the desktop client's task index.
//! Reuse configuration/authentication, but never share session or SQLite storage.
use std::{fs, path::Path};

pub fn prepare(root: &Path, legacy: &Path) -> Result<(), Box<dyn std::error::Error>> {
    fs::create_dir_all(root)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(root, fs::Permissions::from_mode(0o700))?;
        for name in [
            "config.toml",
            "auth.json",
            ".credentials.json",
            "plugins",
            "skills",
            "rules",
        ] {
            let source = legacy.join(name);
            let target = root.join(name);
            if source.exists() && fs::symlink_metadata(&target).is_err() {
                std::os::unix::fs::symlink(source, target)?;
            }
        }
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn shares_setup_without_sharing_history_or_overwriting_private_settings() {
        let temp = tempfile::tempdir().unwrap();
        let legacy = temp.path().join("desktop");
        let private = temp.path().join("wonder");
        fs::create_dir_all(legacy.join("sessions")).unwrap();
        fs::write(legacy.join("config.toml"), "model = 'test'").unwrap();
        fs::write(legacy.join("state_5.sqlite"), "desktop state").unwrap();
        prepare(&private, &legacy).unwrap();
        assert!(private.join("config.toml").is_symlink());
        assert!(!private.join("sessions").exists());
        assert!(!private.join("state_5.sqlite").exists());
        fs::create_dir_all(private.join("sessions")).unwrap();
        fs::write(private.join("sessions/wonder.jsonl"), "private history").unwrap();
        fs::write(private.join("auth.json"), "private sign-in").unwrap();
        prepare(&private, &legacy).unwrap();
        assert_eq!(
            fs::read_to_string(private.join("auth.json")).unwrap(),
            "private sign-in"
        );
        assert!(!legacy.join("sessions/wonder.jsonl").exists());
    }
}
