//! DistilledSavings shared-vector conformance: the Rust half of the gate.
//!
//! Reads the SAME `Tests/CognitionKitTests/Fixtures/distilled_savings_vectors.json`
//! the Swift `DistilledSavingsConformanceTests` reads. For each case it sums
//! the records, calls `measure_distilled_savings`, and compares the full
//! result against the decoded `expected` value with `assert_eq!`.
//!
//! A failure here is a cross-port drift signal. The fixture is re-recorded
//! only from the Swift leg after a DELIBERATE behavioural change.

use std::path::PathBuf;

use serde::Deserialize;

use cognition_kit::{measure_distilled_savings, DistilledSavings};

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/CognitionKitTests/Fixtures/distilled_savings_vectors.json")
}

// Schema mirrors the Swift fixture structs.

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixtureRecord {
    distilled_tokens: i64,
    original_tokens: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixtureCase {
    name: String,
    records: Vec<FixtureRecord>,
    skim_omitted_tokens: Option<i64>,
    /// Decoded directly as DistilledSavings: the fixture IS the wire contract.
    expected: DistilledSavings,
}

#[derive(Deserialize)]
struct DistilledSavingsFixture {
    cases: Vec<FixtureCase>,
}

#[test]
fn fixture_vectors_reproduce() {
    let data =
        std::fs::read_to_string(fixture_path()).expect("distilled_savings_vectors.json");
    let fixture: DistilledSavingsFixture =
        serde_json::from_str(&data).expect("fixture schema");

    for c in &fixture.cases {
        let total_distilled: i64 = c.records.iter().map(|r| r.distilled_tokens).sum();
        let total_original: i64 = c.records.iter().map(|r| r.original_tokens).sum();
        let result =
            measure_distilled_savings(total_original, total_distilled, c.skim_omitted_tokens);
        assert_eq!(
            result, c.expected,
            "case {}: computed DistilledSavings must equal the fixture expected",
            c.name
        );
    }
}
