//! core/paths.rs — platform path resolution (spec §1, §3).
//!
//! | Concern  | Linux                                   | Windows                  |
//! |----------|-----------------------------------------|--------------------------|
//! | Data dir | ${XDG_DATA_HOME:-~/.local/share}/mootx01 | %LOCALAPPDATA%\MOOTx01  |
//!
//! macOS appears only for dev runs of the Rust binary (Swift owns Apple
//! targets in production); it uses `~/Library/Application Support/ai.mootx01.ce`
//! as the data dir. Note: Swift `MootPaths` uses `com.mootx01.ce`, so Rust dev
//! runs on macOS read a separate data directory from the Swift binary.
//!
//! `MOOTX01_DATA_DIR` overrides the data dir root on every platform.
//!
//! Estate layout (spec §4.4): named estates live at
//! `<data>/databases/<name>/estate.sqlite`; the active estate name is
//! tracked in `<data>/config.json`; the primary estate is `default`.
//!
//! Port files (spec §3): `<data>/daemon.port`, `<data>/mgr.port`.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// The data directory root, honoring `MOOTX01_DATA_DIR`.
pub fn data_dir() -> PathBuf {
    if let Ok(v) = std::env::var("MOOTX01_DATA_DIR") {
        if !v.is_empty() {
            return PathBuf::from(v);
        }
    }
    platform_data_dir()
}

/// The resident daemon's data directory as `mootx01 upgrade` needs it: a
/// directory to compare an estate against, or a registration that exists
/// but could not be read. Twin of the Swift `MootPaths.ResidentDataDirectory`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResidentDataDir {
    /// The daemon serves this directory: the `MOOTX01_DATA_DIR` its service
    /// registration bakes in, or the platform default when no registration
    /// exists or the registration carries no override.
    Directory(PathBuf),
    /// A daemon registration exists at this location but could not be read.
    /// Nothing can prove which estate the daemon has open, so every estate
    /// is treated as resident.
    UnreadableRegistration(PathBuf),
}

impl ResidentDataDir {
    /// One operator-facing line explaining why a step is about to quiesce
    /// the daemon for `data` although the directory may not be the one the
    /// daemon serves; `None` when the resident directory is known.
    pub fn registration_warning(&self, data: &Path) -> Option<String> {
        match self {
            ResidentDataDir::Directory(_) => None,
            ResidentDataDir::UnreadableRegistration(at) => Some(format!(
                "  daemon registration at {} could not be read; treating {} as the resident estate",
                at.display(),
                data.display()
            )),
        }
    }
}

/// The data directory the resident daemon serves, read from its service
/// registration. `mootx01 install` bakes the `MOOTX01_DATA_DIR` it was run
/// with into the systemd unit / Task Scheduler action, so the registration —
/// not the platform default — says which estate the daemon has open.
/// `service::daemon_registration` reads it; `resident_data_dir_from` decides.
pub fn resident_data_dir() -> ResidentDataDir {
    resident_data_dir_from(
        crate::core::service::daemon_registration(&home()),
        platform_data_dir(),
    )
}

/// Pure form of `resident_data_dir`: decide the resident directory from what
/// the service manager registers. Tests inject the registration.
///
/// - `Absent`: `platform_default` (no daemon; the default is what a later
///   install would serve).
/// - `Registered { data_dir: Some(dir) }`: `dir`.
/// - `Registered { data_dir: None }`: `platform_default` (the daemon
///   started with no override).
/// - `Unreadable(at)`: `UnreadableRegistration(at)`. SECURITY: a
///   registration we cannot read is never assumed to serve some other
///   directory; the upgrade quiesces the daemon rather than migrate an
///   estate the daemon may hold open.
pub fn resident_data_dir_from(
    registration: crate::core::service::DaemonRegistration,
    platform_default: PathBuf,
) -> ResidentDataDir {
    use crate::core::service::DaemonRegistration;
    match registration {
        DaemonRegistration::Absent => ResidentDataDir::Directory(platform_default),
        DaemonRegistration::Registered { data_dir: None } => {
            ResidentDataDir::Directory(platform_default)
        }
        DaemonRegistration::Registered { data_dir: Some(dir) } => {
            ResidentDataDir::Directory(PathBuf::from(dir))
        }
        DaemonRegistration::Unreadable(at) => ResidentDataDir::UnreadableRegistration(at),
    }
}

/// Whether `data` refers to the resident estate — the one the resident
/// daemon has open. `mootx01 upgrade` quiesces the daemon around a step
/// only when this is true; a cloned estate reached through
/// `MOOTX01_DATA_DIR` is upgraded with the daemon left running, because
/// the daemon has no stake in it.
///
/// `Directory`: both paths are canonicalised before comparison: symlinks
/// resolved (`fs::canonicalize`), `.` components and trailing separators
/// dropped, `..` collapsed. A path that does not exist cannot be
/// symlink-resolved and compares by its lexically normalised form.
///
/// `UnreadableRegistration`: always `true`. SAFETY: with the registration
/// unreadable no directory can be ruled out, so every estate is treated as
/// the daemon's and the step quiesces it.
pub fn is_resident_estate(data: &Path, resident: &ResidentDataDir) -> bool {
    match resident {
        ResidentDataDir::Directory(dir) => canonical_path(data) == canonical_path(dir),
        ResidentDataDir::UnreadableRegistration(_) => true,
    }
}

/// `fs::canonicalize` when the path exists, else a lexical normalisation
/// (`.` dropped, `..` collapsed into its parent where one exists).
/// `Path::components` already drops trailing separators.
fn canonical_path(path: &Path) -> PathBuf {
    if let Ok(real) = fs::canonicalize(path) {
        return real;
    }
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                if !out.pop() {
                    out.push(component);
                }
            }
            other => out.push(other),
        }
    }
    out
}

#[cfg(target_os = "windows")]
fn platform_data_dir() -> PathBuf {
    let base = std::env::var("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home().join("AppData").join("Local"));
    base.join("MOOTx01")
}

#[cfg(target_os = "macos")]
fn platform_data_dir() -> PathBuf {
    home()
        .join("Library")
        .join("Application Support")
        .join("ai.mootx01.ce")
}

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
fn platform_data_dir() -> PathBuf {
    let base = std::env::var("XDG_DATA_HOME")
        .ok()
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local").join("share"));
    base.join("mootx01")
}

fn home() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        std::env::var("USERPROFILE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("."))
    }
    #[cfg(not(target_os = "windows"))]
    {
        std::env::var("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("."))
    }
}

/// `<data>/databases/<name>/estate.sqlite`
pub fn estate_sqlite_path(data: &Path, name: &str) -> PathBuf {
    data.join("databases").join(name).join("estate.sqlite")
}

/// `<data>/config.json` — `{"active_estate": "<name>"}`.
pub fn config_json_path(data: &Path) -> PathBuf {
    data.join("config.json")
}

/// Read the active estate name from config.json; `default` when the file is
/// absent or unreadable.
pub fn active_estate(data: &Path) -> String {
    let path = config_json_path(data);
    let Ok(bytes) = fs::read(&path) else {
        return "default".to_string();
    };
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return "default".to_string();
    };
    v.get("active_estate")
        .and_then(|s| s.as_str())
        .unwrap_or("default")
        .to_string()
}

/// Write the active estate name to config.json, preserving any other keys.
pub fn set_active_estate(data: &Path, name: &str) -> io::Result<()> {
    let path = config_json_path(data);
    let mut root = fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .unwrap_or_else(|| serde_json::json!({}));
    root["active_estate"] = serde_json::Value::String(name.to_string());
    fs::create_dir_all(data)?;
    fs::write(&path, serde_json::to_vec_pretty(&root)?)
}

/// `<data>/daemon.port`
pub fn daemon_port_file(data: &Path) -> PathBuf {
    data.join("daemon.port")
}

/// `<data>/mgr.port`
pub fn mgr_port_file(data: &Path) -> PathBuf {
    data.join("mgr.port")
}

/// Read a port file. None when absent or malformed.
pub fn read_port_file(path: &Path) -> Option<u16> {
    fs::read_to_string(path).ok()?.trim().parse().ok()
}

/// Write a port file (creates the data dir if needed).
pub fn write_port_file(path: &Path, port: u16) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(path, format!("{port}\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn estate_path_shape() {
        let p = estate_sqlite_path(Path::new("/tmp/m"), "work");
        assert_eq!(p, PathBuf::from("/tmp/m/databases/work/estate.sqlite"));
    }

    #[test]
    fn active_estate_defaults_when_missing() {
        let dir = std::env::temp_dir().join(format!("mootx01-test-{}", std::process::id()));
        assert_eq!(active_estate(&dir), "default");
    }

    #[test]
    fn active_estate_round_trip_preserves_other_keys() {
        let dir = std::env::temp_dir().join(format!("mootx01-test-rt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            config_json_path(&dir),
            br#"{"active_estate":"default","other":42}"#,
        )
        .unwrap();
        set_active_estate(&dir, "work").unwrap();
        assert_eq!(active_estate(&dir), "work");
        let v: serde_json::Value =
            serde_json::from_slice(&std::fs::read(config_json_path(&dir)).unwrap()).unwrap();
        assert_eq!(v["other"], 42);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn port_file_round_trip() {
        let dir = std::env::temp_dir().join(format!("mootx01-test-port-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let f = daemon_port_file(&dir);
        write_port_file(&f, 4242).unwrap();
        assert_eq!(read_port_file(&f), Some(4242));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resident_dir_is_resident_estate() {
        let resident = Path::new("/srv/moot/resident");
        let registered = ResidentDataDir::Directory(resident.to_path_buf());
        assert!(is_resident_estate(resident, &registered));
        // `.` segments and a trailing separator are spellings, not a
        // different directory.
        assert!(is_resident_estate(Path::new("/srv/moot/./resident/"), &registered));
        assert!(is_resident_estate(Path::new("/srv/moot/other/../resident"), &registered));
    }

    #[cfg(unix)]
    #[test]
    fn symlink_to_resident_dir_is_resident_estate() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let resident = tmp.path().join("resident");
        fs::create_dir_all(&resident).expect("resident dir");
        let link = tmp.path().join("estate-link");
        std::os::unix::fs::symlink(&resident, &link).expect("symlink");
        assert!(is_resident_estate(&link, &ResidentDataDir::Directory(resident)));
    }

    #[test]
    fn sibling_scratch_dir_is_not_resident_estate() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let resident = tmp.path().join("resident");
        // A benchmark clone beside the resident directory: same parent,
        // same prefix, a different estate.
        let scratch = tmp.path().join("resident-bench");
        fs::create_dir_all(&resident).expect("resident dir");
        fs::create_dir_all(&scratch).expect("scratch dir");
        assert!(!is_resident_estate(&scratch, &ResidentDataDir::Directory(resident)));
        // Neither side existing still compares the two spellings.
        assert!(!is_resident_estate(
            Path::new("/srv/moot/bench-clone"),
            &ResidentDataDir::Directory(PathBuf::from("/srv/moot/resident"))
        ));
    }

    // -- the resident directory comes from the daemon registration ---------
    // Pinned fixture semantics (twin of the Swift PathsTests): registration
    // with MOOTX01_DATA_DIR=/x → /x; registration unparsable → resident
    // (quiesce); registration absent → platform default.

    #[test]
    fn registration_with_override_names_that_directory() {
        use crate::core::service::DaemonRegistration;
        let default = PathBuf::from("/home/u/.local/share/mootx01");
        let resident = resident_data_dir_from(
            DaemonRegistration::Registered { data_dir: Some("/x".to_string()) },
            default.clone(),
        );
        assert_eq!(resident, ResidentDataDir::Directory(PathBuf::from("/x")));
        // The daemon's estate is /x: a step on /x quiesces, a step on the
        // platform default (an estate the daemon never opened) does not.
        assert!(is_resident_estate(Path::new("/x"), &resident));
        assert!(!is_resident_estate(&default, &resident));
        assert_eq!(resident.registration_warning(Path::new("/x")), None);
    }

    #[test]
    fn registration_without_override_is_platform_default() {
        use crate::core::service::DaemonRegistration;
        let default = PathBuf::from("/home/u/.local/share/mootx01");
        assert_eq!(
            resident_data_dir_from(DaemonRegistration::Registered { data_dir: None }, default.clone()),
            ResidentDataDir::Directory(default.clone())
        );
        assert_eq!(
            resident_data_dir_from(DaemonRegistration::Absent, default.clone()),
            ResidentDataDir::Directory(default)
        );
    }

    #[test]
    fn unreadable_registration_makes_every_estate_resident() {
        use crate::core::service::DaemonRegistration;
        let at = PathBuf::from("/home/u/.config/systemd/user/mootx01.service");
        let default = PathBuf::from("/home/u/.local/share/mootx01");
        let resident = resident_data_dir_from(DaemonRegistration::Unreadable(at.clone()), default.clone());
        assert_eq!(resident, ResidentDataDir::UnreadableRegistration(at.clone()));
        assert!(is_resident_estate(Path::new("/srv/moot/bench-clone"), &resident));
        assert!(is_resident_estate(&default, &resident));
        let warning = resident.registration_warning(&default).expect("warning");
        assert!(warning.contains(&at.display().to_string()));
        assert!(warning.contains(&default.display().to_string()));
    }

    #[test]
    fn unit_file_on_disk_drives_the_resident_directory() {
        // install with MOOTX01_DATA_DIR=<custom> then upgrade with the same
        // override: the step on <custom> must quiesce.
        use crate::core::service;
        let tmp = tempfile::tempdir().expect("tempdir");
        let unit_path = service::systemd_user_dir(tmp.path()).join(service::DAEMON_UNIT);
        let custom = tmp.path().join("custom-estate");
        let default = tmp.path().join("default-estate");
        fs::create_dir_all(unit_path.parent().unwrap()).unwrap();
        fs::write(
            &unit_path,
            service::daemon_unit("/b", Some(&custom.display().to_string()), true).unwrap(),
        )
        .unwrap();
        let resident = resident_data_dir_from(
            service::daemon_registration_from_unit_file(&unit_path),
            default.clone(),
        );
        assert_eq!(resident, ResidentDataDir::Directory(custom.clone()));
        assert!(is_resident_estate(&custom, &resident));
        assert!(!is_resident_estate(&default, &resident));

        fs::write(&unit_path, "not a unit").unwrap();
        let unreadable = resident_data_dir_from(
            service::daemon_registration_from_unit_file(&unit_path),
            default.clone(),
        );
        assert_eq!(unreadable, ResidentDataDir::UnreadableRegistration(unit_path));
        assert!(is_resident_estate(&default, &unreadable));
    }
}
