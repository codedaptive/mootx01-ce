//! `aria-mcp` binary entry point.
//!
//! The full runtime — telemetry wiring (stats store path from configuration directory) and transport
//! select (stdio default; resident HTTP + Autonomic Governor when
//! `MOOTX01_HTTP_PORT` is set) — lives in `aria_mcp::runtime::run` so this dev
//! binary and the product `mootx01 serve` (apps/mootx01/rust) execute the
//! identical logic from one source of truth. The estate is selected through
//! the estate catalog, as the product does: `--db <name>` for a registered
//! estate, `--db <dir>/<name>` for a transient one, the active estate by
//! default, `--in-memory` for the in-memory backend. No environment value
//! names an estate. Twin of the Swift `aria-mcp` `Arguments`.
//!
//! `--in-memory` still opens the catalog and resolves the record first, so a
//! bad `--db` is refused before the backend is chosen; the estate is then
//! served as a transient one — no federation identity, no charter drawers
//! (R8, 2026-09-08). The same rule holds in the Swift port and in both ports
//! of `mootx01 serve`.
//!
//! # Running
//!
//! ```sh
//! cargo run --manifest-path apps/aria-mcp-server/rust/Cargo.toml -- --db /tmp/scratch/x
//! ```

use aria_mcp::estate_registry::EstateOpening;
use aria_mcp::server::RuntimeEstate;
use genius_locus_kit::{EstateBackend, EstateCatalog, EstateOpenPosture, EstateRecordKind};

const USAGE: &str = "usage: aria-mcp [--db <name>|<dir>/<name>] [--in-memory]";

/// Exit code for a usage error. One code across both ports: the Swift entry
/// point exits 1 for an unexpected argument, and a supervisor scripting on the
/// code must not have to know which port it launched.
const USAGE_EXIT: i32 = 1;

/// The two arguments the binary takes, plus `--help`. Anything else is a usage
/// error: this server has no other configuration on its command line. Twin of
/// the Swift `AriaMCPMain.Arguments`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Arguments {
    pub db: Option<String>,
    pub in_memory: bool,
    /// `--help` or `-h` was given: print the usage line and exit 0 without
    /// opening anything.
    pub help: bool,
}

/// What a refused command line reports: the message and nothing else. The
/// caller prints it to stderr and exits `USAGE_EXIT`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageError(pub String);

/// Parse the argument vector (already stripped of argv[0]).
///
/// Refuses the same three shapes the Swift port refuses, for the same reasons:
/// a `--db` with no value; a `--db` whose value begins with `--` (the operator
/// meant a flag and lost it to the value slot); and a repeated `--db` (two
/// estates named, neither of them unambiguously the one wanted — last-wins
/// silently serves the wrong estate).
pub fn parse_arguments<I: IntoIterator<Item = String>>(args: I) -> Result<Arguments, UsageError> {
    let mut parsed = Arguments::default();
    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--db" => {
                if parsed.db.is_some() {
                    return Err(UsageError(format!("aria-mcp: --db given twice\n{USAGE}")));
                }
                match it.next() {
                    Some(value) if !value.starts_with("--") => parsed.db = Some(value),
                    Some(value) => {
                        return Err(UsageError(format!(
                            "aria-mcp: --db requires an estate name, got the flag {value:?}\n{USAGE}"
                        )))
                    }
                    None => {
                        return Err(UsageError(format!("aria-mcp: --db requires a value\n{USAGE}")))
                    }
                }
            }
            "--in-memory" => parsed.in_memory = true,
            "--help" | "-h" => parsed.help = true,
            other => {
                return Err(UsageError(format!(
                    "aria-mcp: unexpected argument {other:?}\n{USAGE}"
                )))
            }
        }
    }
    Ok(parsed)
}

fn main() {
    let arguments = match parse_arguments(std::env::args().skip(1)) {
        Ok(arguments) => arguments,
        Err(UsageError(message)) => {
            eprintln!("{message}");
            std::process::exit(USAGE_EXIT);
        }
    };
    if arguments.help {
        println!("{USAGE}");
        return;
    }

    // The catalog is the one place that knows which estates exist and where,
    // and it is consulted for every invocation including `--in-memory`: the
    // record decides the estate's name and directory, and a `--db` that names
    // no registered estate and carries no path is refused here rather than
    // silently ignored.
    let catalog = match arguments.db.as_deref() {
        Some(value) => EstateCatalog::open_selecting(value),
        None => EstateCatalog::open(),
    };
    let catalog = match catalog {
        Ok(catalog) => catalog,
        Err(error) => {
            eprintln!("aria-mcp: {error}");
            std::process::exit(1);
        }
    };
    let record = catalog.active().clone();

    let registered = is_registered_opening(&record.kind, arguments.in_memory);
    let estate = if arguments.in_memory {
        // R8 (2026-09-08): `--in-memory` serves a TRANSIENT estate whatever
        // the record says. Nothing survives the process, so no federation
        // identity is minted and no charter drawers are seeded — a benchmark
        // RAM arm measures the pool it imported and nothing else.
        eprintln!(
            "aria-mcp: estate '{}' IN-MEMORY — exists only for this process (transient: no federation, no charters)",
            record.name
        );
        RuntimeEstate::InMemory { opening: EstateOpening::TRANSIENT }
    } else {
        match &record.backend {
            EstateBackend::Postgresql { connection_string } => RuntimeEstate::Postgresql {
                connection_string: connection_string.clone(),
                opening: if registered { EstateOpening::REGISTERED } else { EstateOpening::TRANSIENT },
            },
            EstateBackend::Sqlite => {
                // The posture is decided before the open: a registered estate
                // is created encrypted (its key minted beside it), a transient
                // or declared-plaintext one stays plaintext, and a ciphertext
                // file without its key fails closed here.
                let posture = match EstateOpenPosture::resolve(&record) {
                    Ok(posture) => posture,
                    Err(error) => {
                        eprintln!("aria-mcp: estate encryption posture unavailable: {error}");
                        std::process::exit(1);
                    }
                };
                eprintln!(
                    "aria-mcp: estate '{}' [{:?}] at {}",
                    record.name, record.kind, record.directory.display()
                );
                RuntimeEstate::Sqlite {
                    opening: if registered { EstateOpening::REGISTERED } else { EstateOpening::TRANSIENT },
                    encryption: posture.manifest_encryption(),
                    record,
                }
            }
        }
    };

    // No plugin concept for this reference server — always "" (no skew to
    // report) and no release feed — None (no update advisory either).
    aria_mcp::runtime::run("mootx01", "", None, estate);
}


/// Whether the estate should be opened with registered posture: federated
/// identity, Keychain key store, and charter seeding. Returns `false` when
/// `in_memory` is true regardless of the record kind — `--in-memory` always
/// forces the transient posture (R8, 2026-09-08).
///
/// Extracted from `main()` so that estate-selection tests can verify the
/// condition with records from a scratch catalog. A mutation that drops
/// `&& !in_memory` makes `in_memory_always_transient_whatever_the_record_kind` red.
pub(crate) fn is_registered_opening(kind: &EstateRecordKind, in_memory: bool) -> bool {
    *kind == EstateRecordKind::Registered && !in_memory
}

#[cfg(test)]
mod tests {
    use super::{parse_arguments, Arguments};

    /// Turn a slice of &str into the owned iterator `parse_arguments` takes.
    fn parse(args: &[&str]) -> Result<Arguments, super::UsageError> {
        parse_arguments(args.iter().map(|s| (*s).to_string()))
    }

    #[test]
    fn no_arguments_selects_the_active_estate() {
        let parsed = parse(&[]).expect("empty argv is valid");
        assert_eq!(parsed, Arguments { db: None, in_memory: false, help: false });
    }

    #[test]
    fn db_takes_a_registered_name() {
        let parsed = parse(&["--db", "work"]).expect("a bare name is valid");
        assert_eq!(parsed.db.as_deref(), Some("work"));
        assert!(!parsed.in_memory);
    }

    #[test]
    fn db_takes_a_directory_and_name() {
        let parsed = parse(&["--db", "/tmp/scratch/bench"]).expect("a pathname is valid");
        assert_eq!(parsed.db.as_deref(), Some("/tmp/scratch/bench"));
    }

    #[test]
    fn in_memory_composes_with_db() {
        let parsed = parse(&["--db", "/tmp/scratch/bench", "--in-memory"])
            .expect("--db and --in-memory compose");
        assert_eq!(parsed.db.as_deref(), Some("/tmp/scratch/bench"));
        assert!(parsed.in_memory);
    }

    #[test]
    fn help_is_accepted_in_both_spellings() {
        assert!(parse(&["--help"]).expect("--help is valid").help);
        assert!(parse(&["-h"]).expect("-h is valid").help);
    }

    #[test]
    fn db_without_a_value_is_refused() {
        let error = parse(&["--db"]).expect_err("--db needs a value");
        assert!(error.0.contains("--db requires a value"), "{}", error.0);
    }

    #[test]
    fn db_followed_by_a_flag_is_refused() {
        // Swift refuses a value beginning with "--" so `--db --in-memory`
        // cannot silently become an estate named "--in-memory".
        let error = parse(&["--db", "--in-memory"]).expect_err("a flag is not an estate name");
        assert!(error.0.contains("requires an estate name"), "{}", error.0);
    }

    #[test]
    fn repeated_db_is_refused() {
        let error = parse(&["--db", "a", "--db", "b"]).expect_err("two estates named");
        assert!(error.0.contains("--db given twice"), "{}", error.0);
    }

    #[test]
    fn an_unknown_argument_is_refused() {
        let error = parse(&["--frozen"]).expect_err("aria-mcp takes no --frozen");
        assert!(error.0.contains("unexpected argument"), "{}", error.0);
    }
}

/// Estate-selection tests: verify `is_registered_opening` with records drawn
/// from a real scratch catalog via the `test-seams` seam. Twin of the Swift
/// `EstateSelectionTests` in the same order.
///
/// Each test holds `CATALOG_LOCK` for its duration because the configuration-
/// directory override is process-global: parallel tests would collide on it.
#[cfg(test)]
mod estate_selection_tests {
    use super::is_registered_opening;
    use genius_locus_kit::{EstateCatalog, EstateRecordKind};
    use std::path::PathBuf;
    use std::sync::Mutex;

    static CATALOG_LOCK: Mutex<()> = Mutex::new(());

    struct Scratch {
        dir: PathBuf,
        _guard: std::sync::MutexGuard<'static, ()>,
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            EstateCatalog::set_configuration_directory_override(None);
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// Create a scratch configuration directory, install it as the override,
    /// and return a Scratch guard that restores the override on drop.
    fn configuration() -> Scratch {
        let guard = CATALOG_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = std::env::temp_dir()
            .join(format!("aria-mcp-sel-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        EstateCatalog::set_configuration_directory_override(Some(dir.clone()));
        Scratch { dir, _guard: guard }
    }

    /// `--in-memory` forces transient posture whatever the record kind says.
    /// A mutation that drops `&& !in_memory` from `is_registered_opening` fails
    /// this test.
    #[test]
    fn in_memory_always_transient_whatever_the_record_kind() {
        let s = configuration();
        let catalog = EstateCatalog::create().expect("create scratch catalog");
        let record = catalog.active();
        // Sanity: catalog creates a registered default record.
        assert_eq!(record.kind, EstateRecordKind::Registered);
        // The claim: in-memory overrides the registered kind → transient posture.
        assert!(!is_registered_opening(&record.kind, true));
        drop(s);
    }

    /// A registered record without `--in-memory` → registered posture.
    /// Mirrors `AriaMCPMain.swift:143` (`isRegisteredOpening`) for mutation coverage.
    #[test]
    fn registered_record_without_in_memory_is_registered() {
        let s = configuration();
        let catalog = EstateCatalog::create().expect("create scratch catalog");
        let record = catalog.active();
        assert_eq!(record.kind, EstateRecordKind::Registered);
        assert!(is_registered_opening(&record.kind, false));
        drop(s);
    }

    /// A transient record (path-selected) is never registered regardless of
    /// `--in-memory`. Mirrors the `--db <dir>/<name>` path in `main()`.
    #[test]
    fn transient_record_is_always_transient() {
        let s = configuration();
        // Create the catalog so open_selecting can find it.
        EstateCatalog::create().expect("create scratch catalog");
        // Attach a transient estate by path (<dir>/<name> selector).
        let transient_path = s.dir.join("scratch/bench");
        std::fs::create_dir_all(&transient_path).unwrap();
        let selector = format!("{}/bench", s.dir.join("scratch").to_string_lossy());
        let catalog = EstateCatalog::open_selecting(&selector).expect("open transient by path");
        let record = catalog.active();
        assert_eq!(record.kind, EstateRecordKind::Transient);
        assert!(!is_registered_opening(&record.kind, false));
        assert!(!is_registered_opening(&record.kind, true));
        drop(s);
    }
}
