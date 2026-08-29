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
use crate::core::{encrypt_optout, paths};
use crate::exit;

pub fn run(cmd: DbCommand) -> ExitCode {
    let data = paths::data_dir();
    match cmd {
        DbCommand::Create { name, no_encrypt } => create(&data, &name, no_encrypt),
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

fn create(data: &std::path::Path, name: &str, no_encrypt: bool) -> ExitCode {
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

    // create makes the estate DIRECTORY; the substrate writes the SQLite file
    // lazily on first serve. So the encryption posture is settled here, before
    // the file exists, in the same two ways install settles it (twin of Swift
    // DbCreateCommand).
    let estate = paths::estate_sqlite_path(data, name);
    if no_encrypt {
        if let Err(e) = encrypt_optout::write_opt_out(&estate) {
            // Failing to record the choice must not silently produce the
            // opposite posture. Leave nothing behind so the create can be
            // retried cleanly.
            let _ = std::fs::remove_dir_all(&dir);
            eprintln!("Cannot record the --no-encrypt choice for estate '{name}': {e}. Nothing was created.");
            return ExitCode::from(exit::FAILURE);
        }
        println!("Created estate '{name}' (UNENCRYPTED, --no-encrypt).");
        println!("  Run `mootx01 upgrade` at any time to encrypt it.");
    } else {
        // A re-created estate name can inherit a stale --no-encrypt marker
        // from an earlier estate at the same path. The open posture honors
        // the marker for an absent file — so without this sweep, first serve
        // would create the estate PLAINTEXT even though the user did not opt
        // out (stale-marker downgrade).
        match encrypt_optout::remove_opt_out(&estate) {
            Ok(true) => println!("Removed a stale --no-encrypt marker for '{name}'; the estate will be encrypted (the default)."),
            Ok(false) => {}
            Err(e) => {
                let _ = std::fs::remove_dir_all(&dir);
                eprintln!("Cannot remove a stale --no-encrypt marker for estate '{name}': {e}. Nothing was created.");
                return ExitCode::from(exit::FAILURE);
            }
        }
        // Mint db.key NOW rather than at first open. Two reasons: a failure
        // surfaces here, while `db create` can still be retried and nothing
        // has been half-made; and delete disposes of the key with the estate
        // directory, so minting eagerly keeps create and delete symmetric.
        if let Err(e) = aria_mcp::ensure_install_key(&dir) {
            // Fail closed and leave nothing behind: an estate directory whose
            // key could not be minted would otherwise be created plaintext on
            // first serve, silently contradicting the default the user did
            // not opt out of.
            let _ = std::fs::remove_dir_all(&dir);
            eprintln!("Cannot prepare the encryption key for estate '{name}': {e}. Nothing was created. Use --no-encrypt to create an unencrypted estate.");
            return ExitCode::from(exit::FAILURE);
        }
        println!("Created estate '{name}' (encrypted at rest).");
    }
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

    /// `db create --no-encrypt` records the opt-out marker beside the estate
    /// and mints NO key; the first serve then creates the estate plaintext.
    #[test]
    fn create_no_encrypt_writes_marker_and_mints_no_key() {
        let data = tmp_data("create-optout");
        let code = create(&data, "work", true);
        assert_eq!(code, ExitCode::from(exit::OK));
        let dir = estate_dir(&data, "work");
        assert!(dir.join(crate::core::encrypt_optout::ENCRYPTION_OPT_OUT_MARKER_NAME).exists());
        assert!(!dir.join(aria_mcp::INSTALL_KEY_FILE).exists(), "--no-encrypt must not mint a key");
        let _ = std::fs::remove_dir_all(&data);
    }

    /// Default `db create` mints db.key eagerly (a failure surfaces at create
    /// time, and delete disposes of the key with the directory — symmetric)
    /// and leaves no opt-out marker behind.
    #[test]
    fn create_default_mints_key_and_leaves_no_marker() {
        let data = tmp_data("create-default");
        let code = create(&data, "work", false);
        assert_eq!(code, ExitCode::from(exit::OK));
        let dir = estate_dir(&data, "work");
        assert!(
            !dir.join(crate::core::encrypt_optout::ENCRYPTION_OPT_OUT_MARKER_NAME).exists(),
            "default create must not leave an opt-out marker"
        );
        assert!(dir.join(aria_mcp::INSTALL_KEY_FILE).exists(), "default create mints db.key eagerly");
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
