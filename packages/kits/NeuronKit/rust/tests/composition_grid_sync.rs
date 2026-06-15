//! GRID SYNC ENFORCEMENT (Rust leg) — asserts that
//! `neuron_kit::composition_grid::all()` produces exactly the composition name
//! set recorded in the package-local fixture file:
//!
//!   packages/kits/NeuronKit/conformance/composition-grid.json
//!
//! This is the Rust mirror of the Swift `CompositionGridSyncTests`. That same
//! fixture is what the benchmarker's column list derives from, so any
//! divergence between the Rust grid, the Swift grid, and the benchmarker's
//! columns surfaces as a test failure in BOTH languages — not as silent drift.
//!
//! The fixture lives inside NeuronKit's own package tree so CE builds (which
//! do not ship tools/) can resolve it without reaching outside the package.
//!
//! NOTE ON "vector": the Rust grid contains "vector" (used inside weighted-all);
//! the benchmarker omits the standalone "vector" column. The fixture carries the
//! BENCHMARKER'S list (omitting "vector"). This test therefore checks the
//! fixture is a SUBSET of the grid, in order — every fixture name must appear in
//! the grid, in the fixture's relative order — exactly as the Swift test does.

use std::path::PathBuf;

use serde::Deserialize;

use neuron_kit::composition_grid;

/// The shared fixture's shape: a top-level `compositionNames` array.
#[derive(Debug, Deserialize)]
struct GridFixture {
    #[serde(rename = "compositionNames")]
    composition_names: Vec<String>,
}

/// Resolve packages/kits/NeuronKit/conformance/composition-grid.json from
/// CARGO_MANIFEST_DIR — package-local so CE builds (which do not ship
/// tools/) can resolve it without referencing the repo root:
///   CARGO_MANIFEST_DIR = packages/kits/NeuronKit/rust
///     → NeuronKit/ (pop ×1 — package root)
///     → NeuronKit/conformance/composition-grid.json
fn fixture_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR")); // .../NeuronKit/rust
    p.pop(); // NeuronKit/ (package root)
    p.push("conformance");
    p.push("composition-grid.json");
    p
}

fn load_fixture_compositions() -> Vec<String> {
    let path = fixture_path();
    let data = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("composition-grid.json missing at {}: {e}", path.display()));
    let fixture: GridFixture = serde_json::from_str(&data)
        .unwrap_or_else(|e| panic!("composition-grid.json malformed at {}: {e}", path.display()));
    fixture.composition_names
}

/// Every name in the benchmarker fixture must exist in the Rust grid. If a name
/// is present in the fixture but missing from the kit, the benchmarker would
/// send a composition arg the kit cannot resolve — silent wrong results at run
/// time. Fail here instead, loudly, at build time.
#[test]
fn fixture_names_exist_in_grid() {
    let fixture_names = load_fixture_compositions();
    let grid_names: Vec<String> = composition_grid::names();
    for name in &fixture_names {
        assert!(
            grid_names.contains(name),
            "composition '{name}' is in the benchmarker fixture but missing from the Rust composition grid — add it or update the fixture"
        );
    }
}

/// No name in the Rust grid is duplicated. Duplicates mean the benchmarker
/// sends a name that resolves ambiguously.
#[test]
fn grid_has_no_duplicate_names() {
    let mut names = composition_grid::names();
    let before = names.len();
    names.sort();
    names.dedup();
    assert_eq!(before, names.len(), "duplicate composition names in the Rust grid");
}

/// The fixture's composition list is in the same relative order as the Rust grid
/// (excluding names the benchmarker intentionally omits, e.g. "vector"). Order
/// stability keeps the leaderboard columns stable across runs and across langs.
#[test]
fn fixture_order_matches_grid() {
    let fixture_names = load_fixture_compositions();
    let grid_names = composition_grid::names();
    let grid_subset: Vec<String> = grid_names
        .into_iter()
        .filter(|n| fixture_names.contains(n))
        .collect();
    assert_eq!(
        grid_subset, fixture_names,
        "fixture order diverged from the Rust grid order — update the fixture to match the grid's declaration order"
    );
}
