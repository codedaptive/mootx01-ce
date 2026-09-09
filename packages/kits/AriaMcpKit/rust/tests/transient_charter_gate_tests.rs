//! The charter gate: a TRANSIENT opening seeds no charter drawers, on every
//! backend.
//!
//! The 2026-08-24 ruling is that a transient estate holds exactly what was
//! imported into it. A benchmark RAM arm that serves seven `AI_Charter_Hint`
//! drawers measures a candidate pool the spec never described, and its Swift
//! twin — which has always gated seeding on the record's kind — measures a
//! different one. Before this gate the SQLite constructor honoured
//! `EstateOpening::seed_charters` and the in-memory and PostgreSQL
//! constructors seeded unconditionally.
//!
//! A freshly opened estate has no content of its own, so the whole drawer
//! count IS the charter count: seven with seeding, zero without.
//!
//! PostgreSQL needs a live server (`DrawerStoreCore::new` initialises the
//! manifest on first open) and is gated on `PERSISTENCEKIT_PG_URL`, the same
//! gate `persistence_tests.rs` uses.

use aria_mcp::estate_registry::{EstateRegistry, EstateOpening};

/// Number of drawers in the estate right after the open.
fn drawer_count(registry: &EstateRegistry) -> usize {
    let coord = registry.coord.lock().unwrap();
    coord
        .all_drawers(&registry.default.handle)
        .expect("all_drawers must succeed on a freshly opened estate")
        .len()
}

/// A unique scratch SQLite path under the system temp directory.
fn scratch_sqlite_path(label: &str) -> String {
    let unique = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );
    std::env::temp_dir()
        .join(format!("aria-charter-gate-{label}-{unique}.sqlite"))
        .to_string_lossy()
        .into_owned()
}

/// Read `PERSISTENCEKIT_PG_URL`; None when absent or empty.
fn pg_url() -> Option<String> {
    std::env::var("PERSISTENCEKIT_PG_URL").ok().filter(|s| !s.is_empty())
}

#[test]
fn inmemory_transient_opening_seeds_no_charters() {
    let registry = EstateRegistry::new_inmemory_with(EstateOpening::TRANSIENT);
    assert_eq!(
        drawer_count(&registry),
        0,
        "a transient in-memory estate must hold exactly what was imported into it"
    );
}

#[test]
fn inmemory_registered_opening_seeds_charters() {
    // The control: the same constructor with the registered opening still
    // seeds, so the assertion above is discriminating rather than vacuous.
    let registry = EstateRegistry::new_inmemory_with(EstateOpening::REGISTERED);
    assert!(
        drawer_count(&registry) > 0,
        "a registered in-memory estate seeds its seven default wings"
    );
}

#[test]
fn inmemory_default_constructor_seeds_charters() {
    // `new_inmemory()` is the test and development default and keeps seeding;
    // only the product's `--in-memory` path passes TRANSIENT.
    let registry = EstateRegistry::new_inmemory();
    assert!(drawer_count(&registry) > 0, "new_inmemory() seeds the default wings");
}

#[test]
fn sqlite_transient_opening_seeds_no_charters() {
    let path = scratch_sqlite_path("transient");
    let registry = EstateRegistry::new_sqlite_with(&path, "charter-gate-owner", EstateOpening::TRANSIENT)
        .expect("scratch SQLite estate must open");
    assert_eq!(
        drawer_count(&registry),
        0,
        "a transient SQLite estate must hold exactly what was imported into it"
    );
    drop(registry);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn sqlite_registered_opening_seeds_charters() {
    let path = scratch_sqlite_path("registered");
    let registry = EstateRegistry::new_sqlite_with(&path, "charter-gate-owner", EstateOpening::REGISTERED)
        .expect("scratch SQLite estate must open");
    assert!(
        drawer_count(&registry) > 0,
        "a registered SQLite estate seeds its seven default wings"
    );
    drop(registry);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn postgres_transient_opening_seeds_no_charters() {
    let Some(url) = pg_url() else {
        eprintln!("skip: PERSISTENCEKIT_PG_URL not set — PostgreSQL charter gate needs a live server");
        return;
    };
    let registry = EstateRegistry::new_postgres_with(&url, "charter-gate-owner", EstateOpening::TRANSIENT)
        .expect("PostgreSQL estate must open");
    assert_eq!(
        drawer_count(&registry),
        0,
        "a transient PostgreSQL estate must hold exactly what was imported into it"
    );
}
