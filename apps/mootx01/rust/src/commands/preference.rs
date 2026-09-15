//! commands/preference.rs — `mootx01 preference <list|get|set>`: the
//! user-owned estate preferences (`EstatePreferenceKey`), each stored in the
//! estate manifest as a plain string.
//!
//!   preference list [--db <value>]                         every key with its value, in `ALL` order
//!   preference get <key> [--db <value>]                    one key's value
//!   preference set <key> <value> [--db <value>]            write a value, print the read-back
//!
//! Values: on, off for the switches; fact_extractor takes nuextract or apple.
//! A key that has never been set reads as its default (on; nuextract for
//! fact_extractor). A `set` takes effect without a daemon restart: each reader
//! (daemon, duty, recall route) consults its key at fire time, so the next
//! fire after the write sees the new value.
//!
//! The estate is opened for one operation the same way `mootx01 upgrade`
//! opens it: the catalog names the estate (`--db` or the active record), a
//! `SqliteDrawerStore` on its database path becomes the coordinator's store,
//! and the coordinator is dropped when the command returns.
//! Twin of Swift PreferenceCommand.

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, EstateHandle, EstatePreferenceKey, EstatePreferenceValue};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate_types::OwnerCredentials;

use crate::cli::PreferenceCommand;
use crate::exit;

/// Run one `preference` subcommand against the estate `--db` names (or the
/// active estate) and exit 0 on success, 1 with the reason on stderr otherwise.
pub fn run(cmd: PreferenceCommand) -> ExitCode {
    let (db, operation) = match cmd {
        PreferenceCommand::List { db } => (db, Operation::List),
        PreferenceCommand::Get { key, db } => (db, Operation::Get { key }),
        PreferenceCommand::Set { key, value, db } => (db, Operation::Set { key, value }),
    };
    let result = estate_path(db.as_deref()).and_then(|path| {
        // A preference lives in an estate that exists. Opening a store on an
        // absent path would create an empty database, so the absence is
        // reported instead of silently minting an estate.
        if !path.exists() {
            return Err(format!(
                "estate '{}' does not exist; create it with `mootx01 db create` or run `mootx01 serve` first",
                path.display()
            ));
        }
        let estate = open_estate(&path)?;
        apply(&operation, &estate.coordinator, &estate.handle)
    });
    match result {
        Ok(output) => {
            print!("{output}");
            ExitCode::from(exit::OK)
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(exit::FAILURE)
        }
    }
}

/// The three operations, with `key` and `value` still as the user typed them
/// so a refusal can quote the offending text.
enum Operation {
    List,
    Get { key: String },
    Set { key: String, value: String },
}

/// A coordinator holding exactly one estate open for the life of the command.
struct OpenEstate {
    coordinator: EstateCoordinator,
    handle: EstateHandle,
}

/// The database path of the estate `db` selects: a registered name, a
/// `<dir>/<name>` transient estate, or (when `None`) the catalog's active
/// estate. Routes through the funnel (Windows base-directory adoption +
/// catalog open), exactly as `upgrade` does.
fn estate_path(db: Option<&str>) -> Result<PathBuf, String> {
    let catalog = crate::core::estate_open::catalog(db)?;
    Ok(catalog.active().database_path())
}

/// Open the estate at `path` through the substrate's real entry point:
/// `SqliteDrawerStore` → `EstateCoordinator::open`. The command is not the
/// estate's real owner; the substrate validates only that the owner
/// identifier is non-empty, so the sentinel credential is sufficient.
fn open_estate(path: &Path) -> Result<OpenEstate, String> {
    // The wall clock is read once here, at the command boundary; nothing
    // below this line calls the clock.
    let now = wall_now_millis();
    let sqlite_store = SqliteDrawerStore::from_path(&path.display().to_string(), now, None, 5.0)
        .map_err(|e| format!("could not open estate '{}': {e:?}", path.display()))?;
    let store: Arc<dyn DrawerStore> = Arc::new(sqlite_store);
    let mut coordinator = EstateCoordinator::new();
    let handle = coordinator
        .open(store, OwnerCredentials::new("mootx01-preference"), 0, 100)
        .map_err(|e| format!("could not open estate '{}': {e:?}", path.display()))?;
    Ok(OpenEstate { coordinator, handle })
}

/// Perform one operation and return exactly what the command prints on
/// success (one `\n`-terminated line per value), or the refusal message.
fn apply(
    operation: &Operation,
    coordinator: &EstateCoordinator,
    handle: &EstateHandle,
) -> Result<String, String> {
    match operation {
        Operation::List => {
            let mut out = String::new();
            for key in EstatePreferenceKey::ALL {
                let value = read(coordinator, handle, key)?;
                out.push_str(&format!("{} {}\n", key.as_str(), value.as_str()));
            }
            Ok(out)
        }
        Operation::Get { key } => {
            let key = parse_key(key)?;
            let value = read(coordinator, handle, key)?;
            Ok(format!("{}\n", value.as_str()))
        }
        Operation::Set { key, value } => {
            let key = parse_key(key)?;
            let value = EstatePreferenceValue::from_str(value)
                .filter(|v| key.allowed_values().contains(v))
                .ok_or_else(|| {
                    let allowed: Vec<&str> = key.allowed_values().iter().map(|v| v.as_str()).collect();
                    format!("invalid value '{value}' for '{}'; allowed: {}", key.as_str(), allowed.join(", "))
                })?;
            coordinator
                .provision_preference(handle, key, value)
                .map_err(|e| format!("could not set '{}': {e:?}", key.as_str()))?;
            // The read-back is what the estate now holds, not what was asked
            // for; the two agree unless the write failed silently.
            let stored = read(coordinator, handle, key)?;
            Ok(format!("{} {}\n", key.as_str(), stored.as_str()))
        }
    }
}

/// Decode a key the user typed; the refusal lists every accepted key.
fn parse_key(text: &str) -> Result<EstatePreferenceKey, String> {
    EstatePreferenceKey::from_str(text)
        .ok_or_else(|| format!("unknown preference '{text}'; allowed: {}", allowed_keys()))
}

/// The accepted keys as a comma-separated list, in `ALL` order.
fn allowed_keys() -> String {
    EstatePreferenceKey::ALL.iter().map(|key| key.as_str()).collect::<Vec<_>>().join(", ")
}

fn read(
    coordinator: &EstateCoordinator,
    handle: &EstateHandle,
    key: EstatePreferenceKey,
) -> Result<EstatePreferenceValue, String> {
    coordinator
        .provisioned_preference(handle, key)
        .map_err(|e| format!("could not read '{}': {e:?}", key.as_str()))
}

/// Milliseconds since the Unix epoch, saturating at `i64::MAX`.
fn wall_now_millis() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_then_get_round_trips_consolidation_off() {
        let dir = tempfile::tempdir().unwrap();
        let estate = open_estate(&dir.path().join("estate.sqlite")).unwrap();
        let set = Operation::Set { key: "consolidation".into(), value: "off".into() };
        assert_eq!(apply(&set, &estate.coordinator, &estate.handle).unwrap(), "consolidation off\n");
        let get = Operation::Get { key: "consolidation".into() };
        assert_eq!(apply(&get, &estate.coordinator, &estate.handle).unwrap(), "off\n");
        // `list` reports every key in declaration order; the untouched keys read as on.
        let list = apply(&Operation::List, &estate.coordinator, &estate.handle).unwrap();
        assert!(list.starts_with("fact_extraction on\nconsolidation off\n"), "{list}");
        assert_eq!(list.lines().count(), EstatePreferenceKey::ALL.len());
    }

    #[test]
    fn unknown_key_and_bad_value_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let estate = open_estate(&dir.path().join("estate.sqlite")).unwrap();
        let get = Operation::Get { key: "bogus".into() };
        let err = apply(&get, &estate.coordinator, &estate.handle).unwrap_err();
        assert_eq!(
            err,
            "unknown preference 'bogus'; allowed: fact_extraction, consolidation, contradiction_sweep, cross_encoder_routing, maintenance, adaptive_recall"
        );
        let set = Operation::Set { key: "consolidation".into(), value: "maybe".into() };
        let err = apply(&set, &estate.coordinator, &estate.handle).unwrap_err();
        assert_eq!(err, "invalid value 'maybe' for 'consolidation'; expected on or off");
    }
}
