//! Move the default home once, retaining an alias for saved absolute paths.
use std::{
    fs, io,
    path::{Path, PathBuf},
};

pub fn prepare(home: &Path) -> io::Result<PathBuf> {
    let target = home.join(".wonder");
    let legacy = home.join("Library/Application Support/Wonder");
    if legacy.is_symlink() {
        if fs::canonicalize(&legacy)? == fs::canonicalize(&target)? {
            return Ok(target);
        }
        return Err(io::Error::other("The legacy Wonder directory points elsewhere; move it manually before starting Wonder."));
    }
    if !legacy.exists() {
        // Recover a crash between moving the directory and installing its alias.
        if target.join(".legacy-home-migration").exists() {
            #[cfg(unix)]
            std::os::unix::fs::symlink(&target, &legacy)?;
            fs::remove_file(target.join(".legacy-home-migration"))?;
        }
        fs::create_dir_all(&target)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&target, fs::Permissions::from_mode(0o700))?;
        }
        return Ok(target);
    }
    if target.exists() {
        return Err(io::Error::other("Both ~/.wonder and the legacy Wonder directory exist. Neither was changed; reconcile them before starting Wonder."));
    }
    fs::create_dir_all(legacy.join("Service"))?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(legacy.join("Service/launcher.pid"))?;
    lock.try_lock().map_err(|_| {
        io::Error::other("Quit the running Wonder app before migrating its data to ~/.wonder.")
    })?;
    // A manually launched daemon may not have a supervisor lock.
    #[cfg(target_os = "macos")]
    if legacy.join("wonder.sqlite3").exists() {
        let result = std::process::Command::new("/usr/sbin/lsof")
            .args(["-t", "--"])
            .arg(legacy.join("wonder.sqlite3"))
            .output()?;
        if result.status.success() {
            return Err(io::Error::other(
                "Stop the running Wonder daemon before migrating its data.",
            ));
        }
        if result.status.code() != Some(1) {
            return Err(io::Error::other(
                "Could not check whether Wonder data is in use.",
            ));
        }
    }
    fs::write(legacy.join(".legacy-home-migration"), b"")?;
    fs::rename(&legacy, &target)?;
    #[cfg(unix)]
    if let Err(error) = std::os::unix::fs::symlink(&target, &legacy) {
        fs::rename(&target, &legacy)?;
        return Err(error);
    }
    fs::remove_file(target.join(".legacy-home-migration"))?;
    Ok(target)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn migration_preserves_files_and_saved_absolute_paths() {
        let home = tempfile::tempdir().unwrap();
        let old = home.path().join("Library/Application Support/Wonder");
        fs::create_dir_all(old.join("bots/ada")).unwrap();
        fs::write(old.join("bots/ada/work.txt"), "saved").unwrap();
        let new = prepare(home.path()).unwrap();
        assert_eq!(
            fs::read_to_string(new.join("bots/ada/work.txt")).unwrap(),
            "saved"
        );
        assert_eq!(
            fs::read_to_string(old.join("bots/ada/work.txt")).unwrap(),
            "saved"
        );
        assert_eq!(prepare(home.path()).unwrap(), new);
    }
    #[test]
    fn interrupted_alias_installation_recovers() {
        let home = tempfile::tempdir().unwrap();
        let old = home.path().join("Library/Application Support/Wonder");
        fs::create_dir_all(&old).unwrap();
        fs::write(old.join(".legacy-home-migration"), "").unwrap();
        fs::rename(&old, home.path().join(".wonder")).unwrap();
        prepare(home.path()).unwrap();
        assert!(old.is_symlink());
    }
    #[test]
    fn conflicting_homes_are_never_overwritten() {
        let home = tempfile::tempdir().unwrap();
        fs::create_dir_all(home.path().join("Library/Application Support/Wonder")).unwrap();
        fs::create_dir_all(home.path().join(".wonder")).unwrap();
        assert!(prepare(home.path()).is_err());
    }
    #[test]
    fn active_supervisor_blocks_migration() {
        let home = tempfile::tempdir().unwrap();
        let service = home
            .path()
            .join("Library/Application Support/Wonder/Service");
        fs::create_dir_all(&service).unwrap();
        let lock = fs::File::create(service.join("launcher.pid")).unwrap();
        lock.lock().unwrap();
        assert!(prepare(home.path()).is_err());
        assert!(!home.path().join(".wonder").exists());
    }
}
