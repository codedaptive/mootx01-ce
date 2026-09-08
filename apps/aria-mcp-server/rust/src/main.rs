//! `aria-mcp` binary entry point.
//!
//! The full runtime — telemetry wiring (`ARIA_MCP_STATS_STORE`) and transport
//! select (stdio default; resident HTTP + Autonomic Governor when
//! `MOOTX01_HTTP_PORT` is set) — lives in `aria_mcp::runtime::run` so this dev
//! binary and the product `mootx01 serve` (apps/mootx01/rust) execute the
//! identical logic from one source of truth. The estate is selected through
//! the estate catalog, as the product does: `--db <name>` for a registered
//! estate, `--db <dir>/<name>` for a transient one, the active estate by
//! default, `--in-memory` for the in-memory backend. No environment value
//! names an estate. Twin of the Swift `aria-mcp` `Arguments`.
//!
//! # Running
//!
//! ```sh
//! cargo run --manifest-path apps/aria-mcp-server/rust/Cargo.toml -- --db /tmp/scratch/x
//! ```

use aria_mcp::estate_registry::SqliteOpening;
use aria_mcp::server::RuntimeEstate;
use genius_locus_kit::{EstateBackend, EstateCatalog, EstateOpenPosture};

const USAGE: &str = "usage: aria-mcp [--db <name>|<dir>/<name>] [--in-memory]";

fn main() {
    let mut db: Option<String> = None;
    let mut in_memory = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--db" => match args.next() {
                Some(value) => db = Some(value),
                None => {
                    eprintln!("aria-mcp: --db requires a value\n{USAGE}");
                    std::process::exit(2);
                }
            },
            "--in-memory" => in_memory = true,
            "--help" | "-h" => {
                println!("{USAGE}");
                return;
            }
            other => {
                eprintln!("aria-mcp: unexpected argument {other:?}\n{USAGE}");
                std::process::exit(2);
            }
        }
    }

    let estate = if in_memory {
        RuntimeEstate::InMemory
    } else {
        let catalog = match db.as_deref() {
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
        match &record.backend {
            EstateBackend::Postgresql { connection_string } => {
                RuntimeEstate::Postgresql { connection_string: connection_string.clone() }
            }
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
                    opening: SqliteOpening::for_record(&record),
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
