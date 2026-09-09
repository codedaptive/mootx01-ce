//! Estate-selection integration tests: charter-seeding gate.
//!
//! These tests verify that `EstateRegistry::new_sqlite_with` with
//! `EstateOpening::REGISTERED` seeds seven `AI_Charter_Hint` room drawers
//! (one per default wing) and that `EstateOpening::TRANSIENT` seeds none.
//! They test through `moot_estate_map` — the full dispatch stack — so a
//! mutation to the `seed_charters` gate inside `EstateRegistry::new_sqlite_with`
//! is caught at the surface level.
//!
//! `is_registered_opening` is `pub(crate)` in the bin crate; integration tests
//! link against the lib, not the bin, so they cannot reach that helper.
//! The test that catches `is_registered_opening` mutations is
//! `in_memory_always_transient_whatever_the_record_kind` in `src/main.rs`.
//!
//! Swift twin: `CharterSeedingTests.swift` in `Tests/aria-mcpTests/`.
//! Lower-level Rust twin: `transient_charter_gate_tests.rs` in AriaMcpKit.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::{EstateRegistry, EstateOpening},
    surfaced_recall_ledger::SurfacedRecallLedger,
};

/// Extract the text content from a successful dispatch result.
fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
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
        .join(format!("aria-sel-{label}-{unique}.sqlite"))
        .to_string_lossy()
        .into_owned()
}

/// A registered opening seeds exactly seven `AI_Charter_Hint` drawers — one per
/// default wing — visible through `moot_estate_map`. A mutation that removes the
/// `if opening.seed_charters` gate in `EstateRegistry::new_sqlite_with` makes this
/// test vacuous (zero lines), and a mutation that removes the gate entirely seeds
/// transient estates too (caught by `transient_opening_seeds_no_charter_drawers`).
#[test]
fn registered_opening_seeds_seven_charter_drawers() {
    let path = scratch_sqlite_path("registered");
    let registry =
        EstateRegistry::new_sqlite_with(&path, "estate-sel-owner", EstateOpening::REGISTERED)
            .expect("scratch SQLite estate with REGISTERED opening must open");

    let result = dispatch_tool(
        "moot_estate_map",
        &BTreeMap::new(),
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_estate_map must not return a transport fault");

    let text = content_text(&result);
    let charter_line_count = text.lines().filter(|l| l.contains("AI_Charter_Hint:")).count();
    // Seven default wings each contribute one AI_Charter_Hint room line.
    assert_eq!(
        charter_line_count, 7,
        "registered opening must seed exactly 7 AI_Charter_Hint room lines in moot_estate_map; \
         got {charter_line_count} in:\n{text}"
    );

    drop(registry);
    let _ = std::fs::remove_file(&path);
}

/// A transient opening does NOT call the charter seeding gate — the estate
/// remains empty of `AI_Charter_Hint` drawers. A mutation that seeds on every
/// open regardless of `EstateOpening::seed_charters` must fail this test.
#[test]
fn transient_opening_seeds_no_charter_drawers() {
    let path = scratch_sqlite_path("transient");
    let registry =
        EstateRegistry::new_sqlite_with(&path, "estate-sel-owner", EstateOpening::TRANSIENT)
            .expect("scratch SQLite estate with TRANSIENT opening must open");

    let result = dispatch_tool(
        "moot_estate_map",
        &BTreeMap::new(),
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_estate_map must not return a transport fault");

    let text = content_text(&result);
    let charter_line_count = text.lines().filter(|l| l.contains("AI_Charter_Hint:")).count();
    assert_eq!(
        charter_line_count, 0,
        "transient opening must seed zero AI_Charter_Hint room lines in moot_estate_map; \
         got {charter_line_count} in:\n{text}"
    );

    drop(registry);
    let _ = std::fs::remove_file(&path);
}
