//! commands/db.rs — §4.4: named estate lifecycle.
//!
//! Estate lifecycle commands follow the same structure as Swift DbCommand.
//! Note: flag names differ in places (e.g. `--force` here vs Swift's `--yes`
//! for delete confirmation), and exit codes on abort also differ.
//! Estates are directories under `<data>/databases/<name>/`; the SQLite file
//! is created on first `serve`, so `create` makes the directory only.

use std::io::{self, BufRead, Write};
use std::process::ExitCode;

use crate::cli::DbCommand;
use crate::core::paths;
use crate::exit;

pub fn run(cmd: DbCommand) -> ExitCode {
    let data = paths::data_dir();
    match cmd {
        DbCommand::Create { name } => create(&data, &name),
        DbCommand::List => list(&data),
        DbCommand::Open { name } => open(&data, &name),
        DbCommand::Delete { name, force } => delete(&data, &name, force),
    }
}

fn estate_dir(data: &std::path::Path, name: &str) -> std::path::PathBuf {
    data.join("databases").join(name)
}

/// Estate names are path components; refuse anything that could traverse.
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.contains('/')
        && !name.contains('\\')
}

fn create(data: &std::path::Path, name: &str) -> ExitCode {
    if !valid_name(name) {
        eprintln!("Estate name '{name}' is not valid (no path separators).");
        return ExitCode::from(exit::FAILURE);
    }
    let dir = estate_dir(data, name);
    if dir.exists() {
        eprintln!("Estate '{name}' already exists.");
        return ExitCode::from(exit::FAILURE);
    }
    if let Err(e) = std::fs::create_dir_all(&dir) {
        eprintln!("Cannot create estate '{name}': {e}");
        return ExitCode::from(exit::FAILURE);
    }
    println!("Created estate '{name}'.");
    println!("Run `mootx01 db open {name}` to make it the active estate.");
    ExitCode::from(exit::OK)
}

fn list(data: &std::path::Path) -> ExitCode {
    let estates = list_estates(data);
    if estates.is_empty() {
        println!("No estates found. Run `mootx01 serve` to create the default estate.");
        return ExitCode::from(exit::OK);
    }
    let active = paths::active_estate(data);
    println!("Estates:");
    for name in estates {
        let marker = if name == active { " (active)" } else { "" };
        println!("  {name}{marker}");
    }
    ExitCode::from(exit::OK)
}

/// Sorted estate directory names under `<data>/databases/`.
pub fn list_estates(data: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(data.join("databases"))
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
                .filter_map(|e| e.file_name().into_string().ok())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

fn open(data: &std::path::Path, name: &str) -> ExitCode {
    // Validate before computing the estate dir — estate_dir calls path::join
    // on the name; an unvalidated traversal like "../evil" would join outside
    // the databases/ subtree and allow arbitrary directory reads.
    if !valid_name(name) {
        eprintln!("Estate name '{name}' is not valid (no path separators).");
        return ExitCode::from(exit::FAILURE);
    }
    if !estate_dir(data, name).exists() {
        println!("Estate '{name}' not found. Run `mootx01 db list` to see available estates.");
        return ExitCode::from(exit::FAILURE);
    }
    if let Err(e) = paths::set_active_estate(data, name) {
        eprintln!("Cannot set active estate: {e}");
        return ExitCode::from(exit::FAILURE);
    }
    println!("Active estate set to '{name}'.");
    ExitCode::from(exit::OK)
}

fn delete(data: &std::path::Path, name: &str, force: bool) -> ExitCode {
    // Validate before computing the estate dir — an unvalidated traversal like
    // "../databases" or "../../../etc" would allow deleting arbitrary directories
    // outside the databases/ subtree.
    if !valid_name(name) {
        eprintln!("Estate name '{name}' is not valid (no path separators).");
        return ExitCode::from(exit::FAILURE);
    }
    if name == "default" {
        eprintln!("Cannot delete 'default' (use uninstall --purge).");
        return ExitCode::from(exit::FAILURE);
    }
    let dir = estate_dir(data, name);
    if !dir.exists() {
        println!("Estate '{name}' not found. Run `mootx01 db list` to see available estates.");
        return ExitCode::from(exit::FAILURE);
    }
    if !force {
        println!("Delete estate '{name}' and all its data? This is irreversible.");
        print!("Type 'yes' to confirm: ");
        let _ = io::stdout().flush();
        let mut line = String::new();
        let _ = io::stdin().lock().read_line(&mut line);
        if line.trim() != "yes" {
            println!("Aborted.");
            return ExitCode::from(exit::FAILURE);
        }
    }
    // Removing the estate directory disposes of everything in it: the encrypted
    // SQLite file, its -wal/-shm sidecars, AND the whole-file encryption key
    // (db.key). The key never outlives the data it protects.
    if let Err(e) = std::fs::remove_dir_all(&dir) {
        eprintln!("Cannot delete estate '{name}': {e}");
        return ExitCode::from(exit::FAILURE);
    }
    // Deleting the active estate falls back to default.
    if paths::active_estate(data) == name {
        let _ = paths::set_active_estate(data, "default");
    }
    println!("Estate '{name}' deleted (database, sidecars, and encryption key).");
    ExitCode::from(exit::OK)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_data(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("mootx01-db-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn list_estates_sorted_dirs_only() {
        let data = tmp_data("list");
        std::fs::create_dir_all(data.join("databases/work")).unwrap();
        std::fs::create_dir_all(data.join("databases/default")).unwrap();
        std::fs::write(data.join("databases/strayfile"), b"x").unwrap();
        assert_eq!(list_estates(&data), vec!["default", "work"]);
        let _ = std::fs::remove_dir_all(&data);
    }

    #[test]
    fn name_validation_blocks_traversal() {
        assert!(!valid_name("../evil"));
        assert!(!valid_name("a/b"));
        assert!(!valid_name(""));
        assert!(valid_name("work"));
    }

    #[test]
    fn open_rejects_traversal_name() {
        let data = tmp_data("open-traversal");
        std::fs::create_dir_all(data.join("databases")).unwrap();
        // "../work" would join outside databases/; open must reject it before
        // touching the filesystem so no speculative probe leaks path info.
        let code = open(&data, "../work");
        assert_ne!(code, ExitCode::from(exit::OK), "open should reject traversal names");
        let _ = std::fs::remove_dir_all(&data);
    }

    #[test]
    fn delete_rejects_traversal_name() {
        let data = tmp_data("delete-traversal");
        std::fs::create_dir_all(data.join("databases")).unwrap();
        // An attacker supplying "../databases" as the name would attempt to
        // delete the whole databases/ directory; the validation gate stops it.
        let code = delete(&data, "../databases", true);
        assert_ne!(code, ExitCode::from(exit::OK), "delete should reject traversal names");
        let _ = std::fs::remove_dir_all(&data);
    }

    /// Deleting an estate removes the whole directory — including the encryption
    /// key (db.key) and the SQLCipher sidecars — so the key never outlives the
    /// data it protected.
    #[test]
    fn delete_removes_database_sidecars_and_key() {
        let data = tmp_data("delete-key");
        let dir = estate_dir(&data, "work");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("estate.sqlite"), b"ciphertext").unwrap();
        std::fs::write(dir.join("estate.sqlite-wal"), b"wal").unwrap();
        std::fs::write(dir.join("db.key"), b"0123456789abcdef0123456789abcdef").unwrap();

        let _ = delete(&data, "work", true);
        assert!(!dir.exists(), "estate dir removed");
        assert!(!dir.join("db.key").exists(), "encryption key removed");
        let _ = std::fs::remove_dir_all(&data);
    }
}
