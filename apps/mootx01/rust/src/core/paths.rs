//! core/paths.rs — platform path resolution (spec §1, §3).
//!
//! | Concern  | Linux                                   | Windows                  |
//! |----------|-----------------------------------------|--------------------------|
//! | Data dir | ${XDG_DATA_HOME:-~/.local/share}/mootx01 | %LOCALAPPDATA%\MOOTx01  |
//!
//! macOS appears only for dev runs of the Rust binary (Swift owns Apple
//! targets in production); it uses the spec's open-source data dir
//! `~/Library/Application Support/ai.mootx01.ce` so a dev run sees the same
//! estate layout the Swift binary manages.
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
}
