//! FNV-1a 128-bit lineage_id cross-language conformance vectors.
//!
//! Every UUID in this file was produced by the Swift
//! `DrawerMapping.lineageID(forStableSourceKey:)` implementation, which is
//! the reference of record per ADR-VAULTKIT-001 (f). The Rust
//! `DrawerMapping::lineage_id` must produce bit-identical output for the
//! same inputs — this is the cross-language conformance anchor.
//!
//! Seed inputs are taken from the Swift `DrawerMappingTests.swift` test suite.
//! The expected UUIDs were captured by running the Swift test suite and
//! printing `lineageID(forStableSourceKey:)` for each input.
//!
//! To regenerate the expected values: run
//! `swift packages/kits/VaultKit/Tests/VaultKitTests/DrawerMappingTests.swift`
//! or add a debug print to the Swift test and inspect the output.

use vault_kit::DrawerMapping;

/// Canonical cross-language vector table.
/// Format: (stable_source_key, expected_uuid_lowercase_hyphenated).
/// Values verified against Swift output (2026-06-05).
const VECTORS: &[(&str, &str)] = &[
    // From DrawerMappingTests: lineageIDDeterminism
    ("Area/Note", "6536d7da-3d05-4dc5-624e-0bc079568151"),
    ("Area/Other", "3ad126b0-cb86-b1df-f608-71930aeee469"),
    // From DrawerMappingTests: importFrameFallbackUDC
    ("Inbox/Thought", "7ef8f6f1-8bbc-58b6-e09b-6be0e3b6e9a9"),
    // From DrawerMappingTests: explicitUDCClassified
    ("k", "d228cb69-691a-8caf-7891-2b704e4a8202"),
    // Edge case: the empty string hashes to the raw offset basis.
    // FNV-1a with no bytes processed leaves h = offset_basis, which
    // Swift packs as UUID(fromHigh: 0x6c62272e07bb0142, low: 0x62b821756295c58d).
    ("", "6c62272e-07bb-0142-62b8-21756295c58d"),
];

#[test]
fn fnv_128_bit_lineage_id_matches_swift() {
    for (key, expected_uuid_str) in VECTORS {
        let got = DrawerMapping::lineage_id(key);
        let got_str = got.to_string();
        assert_eq!(
            got_str.to_lowercase(),
            *expected_uuid_str,
            "FNV-1a 128-bit lineage_id mismatch for key {:?}: \
             Rust produced {got_str}, Swift reference is {expected_uuid_str}",
            key
        );
    }
}

#[test]
fn fnv_128_bit_is_deterministic() {
    // Same key must always produce the same UUID (no wall-clock or random state).
    let a1 = DrawerMapping::lineage_id("Area/Note");
    let a2 = DrawerMapping::lineage_id("Area/Note");
    let b = DrawerMapping::lineage_id("Area/Other");
    assert_eq!(a1, a2, "same key must produce same lineage_id");
    assert_ne!(a1, b, "distinct keys must produce distinct lineage_ids");
}
