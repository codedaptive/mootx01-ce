//! core/paths.rs — the port files in the configuration directory.
//!
//! The configuration directory is the estate catalog's
//! (`genius_locus_kit::EstateCatalog::configuration_directory()`, the one
//! place that spells it): `${XDG_DATA_HOME:-~/.local/share}/mootx01` on
//! Unix, `%LOCALAPPDATA%\com.mootx01.ce` on Windows. No environment value of
//! the product's own selects it; only the platform base-directory variables
//! are read. It holds the estate catalog (`estatecatalog.json`), the port
//! files (`daemon.port`, `mgr.port`) and, under `databases/`, the default
//! database location. Callers pass it to the helpers below.
//!
//! Estate selection is the estate catalog's (`genius_locus_kit::EstateCatalog`):
//! `<default location>/<name>/estate.sqlite` for a bare name, the record's
//! directory otherwise. Nothing here names an estate.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

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
    fn port_file_round_trip() {
        let dir = std::env::temp_dir().join(format!("mootx01-paths-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let f = daemon_port_file(&dir);
        write_port_file(&f, 4242).unwrap();
        assert_eq!(read_port_file(&f), Some(4242));
        assert_eq!(read_port_file(&dir.join("absent")), None);
        let _ = fs::remove_dir_all(&dir);
    }
}
