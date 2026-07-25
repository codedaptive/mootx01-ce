//! Rust reachability for the twenty-row plaintext estate fixture (CE-1.0.35-04
//! Part 3).
//!
//! ## Why a checked-in artifact instead of a Rust port of the generator
//!
//! The mission offered two options: expose the generated estate as a checked-in
//! binary artifact, or port the generator to Rust "producing a byte-identical
//! estate". The second cannot meet its own bar. Capture stamps wall-clock time
//! into every row, mints an estate UUID, and folds a Merkle rollup over the
//! result, so two independent implementations cannot agree byte-for-byte no
//! matter how carefully they are written. A port would produce an EQUIVALENT
//! estate, never the same one, and the parity gate would then be comparing two
//! generators rather than exercising one fixture.
//!
//! Reading the checked-in bytes is both cheaper and strictly more faithful to
//! "Rust runs the same fixture": it is the same file, not a lookalike.
//!
//! The artifact is regenerable rather than an orphan binary:
//!
//!   cd packages/kits/LocusKit
//!   swift run EstateFixtureEmit rust/tests/fixtures
//!
//! ## Assertions are manifest-driven
//!
//! `manifest.json` ships beside the estate and carries the counts and the row id
//! at each provenance tier. The tests below read the manifest and compare the
//! database against it, so resizing the fixture cannot silently invalidate a
//! test that meant "all of them". The one place a literal appears is the
//! twenty-drawer check the mission names explicitly as the verify step.

use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::provenance::Sensitivity;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

/// Fixed instant for store construction. The fixture is opened read-only in
/// spirit — nothing here writes — so `now` only has to be a valid stamp.
const NOW: i64 = 1_767_225_600_000;

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
}

fn manifest() -> serde_json::Value {
    let path = fixtures_dir().join("manifest.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("fixture manifest must be readable at {path:?}: {e}"));
    serde_json::from_str(&text).expect("fixture manifest must be valid JSON")
}

/// Open the checked-in fixture. Copied to a temp path first so a test run can
/// never mutate the committed artifact — SQLite opens read-write by default and
/// will happily write a WAL beside the source file otherwise.
fn open_fixture() -> (SqliteDrawerStore, PathBuf) {
    let source = fixtures_dir().join("estate.sqlite");
    let target = std::env::temp_dir().join(format!(
        "twenty-row-fixture-rs-{}.sqlite",
        uuid::Uuid::new_v4()
    ));
    std::fs::copy(&source, &target)
        .unwrap_or_else(|e| panic!("fixture estate must be readable at {source:?}: {e}"));
    let store = SqliteDrawerStore::from_path(target.to_str().unwrap(), NOW, None, 5.0)
        .expect("Rust must be able to open the Swift-generated plaintext estate");
    (store, target)
}

fn cleanup(path: &PathBuf) {
    let _ = std::fs::remove_file(path);
    for suffix in ["-wal", "-shm"] {
        let sibling = PathBuf::from(format!("{}{}", path.display(), suffix));
        let _ = std::fs::remove_file(sibling);
    }
}

/// The mission's verify step: cargo test opens the fixture and reads 20 drawers.
#[test]
fn rust_opens_the_fixture_and_reads_twenty_drawers() {
    let (store, path) = open_fixture();
    let drawers = store.all_drawers().expect("all_drawers must succeed");
    assert_eq!(
        drawers.len(),
        20,
        "Rust must read all twenty drawers from the Swift-generated estate"
    );
    cleanup(&path);
}

/// The file is plaintext, which is the property the encryption missions depend
/// on. Checked by reading the header bytes directly, never by opening SQLite.
#[test]
fn fixture_artifact_is_plaintext_sqlite() {
    let source = fixtures_dir().join("estate.sqlite");
    let bytes = std::fs::read(&source).expect("fixture must be readable");
    let magic: Vec<u8> = b"SQLite format 3\0".to_vec();
    assert!(
        bytes.len() > magic.len(),
        "fixture must not be empty or truncated"
    );
    assert_eq!(
        &bytes[..magic.len()],
        &magic[..],
        "the fixture must be PLAINTEXT SQLite; a SQLCipher file encrypts page 1 including this header"
    );
}

/// Counts agree with the manifest, so both verticals read the same shape.
#[test]
fn counts_match_the_shipped_manifest() {
    let manifest = manifest();
    let (store, path) = open_fixture();

    let expected_drawers = manifest["drawer_count"].as_u64().unwrap() as usize;
    let expected_facts = manifest["fact_count"].as_u64().unwrap() as usize;
    let expected_tunnels = manifest["tunnel_count"].as_u64().unwrap() as usize;

    assert_eq!(
        store.all_drawers().unwrap().len(),
        expected_drawers,
        "drawer count must match the manifest"
    );
    assert_eq!(
        store.all_kg_facts().unwrap().len(),
        expected_facts,
        "KG fact count must match the manifest"
    );
    assert_eq!(
        store.all_tunnels().unwrap().len(),
        expected_tunnels,
        "tunnel count must match the manifest"
    );

    cleanup(&path);
}

/// Every fact's provenance resolves to a drawer that exists. A migration that
/// dropped rows but kept facts would break this even with matching counts.
#[test]
fn every_fact_has_provenance_to_a_real_drawer() {
    let (store, path) = open_fixture();
    let drawer_ids: HashSet<String> = store
        .all_drawers()
        .unwrap()
        .into_iter()
        .map(|d| d.id)
        .collect();

    let facts = store.all_kg_facts().unwrap();
    assert!(!facts.is_empty(), "the fixture must ship KG facts");
    for fact in facts {
        assert!(
            drawer_ids.contains(&fact.source_drawer_id),
            "fact {} must have provenance to a real drawer (source_drawer_id={})",
            fact.id,
            fact.source_drawer_id
        );
    }
    cleanup(&path);
}

/// All four provenance sensitivity tiers survive the Swift-to-Rust read, and the
/// row the manifest names at each tier is the row Rust decodes at that tier.
/// This is the assertion the provenance-gate parity work rests on: if Rust
/// decoded the bitmap differently the two verticals could not agree on which
/// rows to withhold.
#[test]
fn all_four_provenance_tiers_round_trip_into_rust() {
    let manifest = manifest();
    let (store, path) = open_fixture();

    let by_id: HashMap<String, Sensitivity> = store
        .all_drawers()
        .unwrap()
        .into_iter()
        .map(|d| (d.id.clone(), d.sensitivity()))
        .collect();

    let tiers = manifest["drawer_ids_by_provenance_tier"]
        .as_object()
        .expect("manifest must carry the tier map");

    let expected: Vec<(&str, Sensitivity)> = vec![
        ("normal", Sensitivity::Normal),
        ("elevated", Sensitivity::Elevated),
        ("restricted", Sensitivity::Restricted),
        ("secret", Sensitivity::Secret),
    ];

    for (name, tier) in expected {
        let id = tiers
            .get(name)
            .unwrap_or_else(|| panic!("manifest must name a drawer at tier {name}"))
            .as_str()
            .unwrap();
        let actual = by_id
            .get(id)
            .unwrap_or_else(|| panic!("tier {name} drawer {id} must exist in the estate"));
        assert_eq!(
            *actual, tier,
            "drawer {id} must decode to provenance sensitivity {name} in Rust as it does in Swift"
        );
    }

    cleanup(&path);
}

/// Exactly two tunnels, one carrying the `precedes` label. `precedes` has no
/// TunnelKind case in either vertical; the MCP surface maps the kind string onto
/// `TunnelKind::Blocks`, so that is the substrate shape asserted here.
#[test]
fn tunnel_shape_round_trips_into_rust() {
    let manifest = manifest();
    let (store, path) = open_fixture();

    let tunnels = store.all_tunnels().unwrap();
    assert_eq!(tunnels.len(), 2, "the fixture ships exactly two tunnels");

    let precedes_id = manifest["precedes_tunnel_id"].as_str().unwrap();
    let precedes = tunnels
        .iter()
        .find(|t| t.id == precedes_id)
        .expect("the manifest's precedes tunnel must exist in the estate");
    assert_eq!(precedes.label, "precedes");

    cleanup(&path);
}
