//! CROSS-PORT GATE — Rust decodes a Swift-written gauntlet corpus.
//!
//! The fixture `fixtures/corpus_swift_written/` (corpus-42.jsonl +
//! needles-42.json) was PRODUCED BY THE SWIFT PORT's `GauntletCLI
//! runGauntletCorpus` (GauntletGenerator.generate + GauntletIO.writeCorpus,
//! JSONEncoder .sortedKeys + .prettyPrinted) from seed 42, even mix (1 per
//! tier, 1 distractor per needle). This test proves the Rust production loader
//! reads the Swift writer's bytes field-for-field — every field of the first
//! needle is asserted individually so a key-name divergence or value mismatch
//! in any field is immediately visible. The Swift twin
//! (GauntletGeneratorTests.swift `decodesRustWrittenCorpus`) decodes the
//! Rust-written fixture.

use mcp_benchmarker_rs::gauntlet_corpus::NoiseTier;
use mcp_benchmarker_rs::gauntlet_io::load_corpus;

#[test]
fn decodes_swift_written_corpus() {
    // load_corpus expects the directory containing corpus-<seed>.jsonl and
    // needles-<seed>.json; stage the fixture directory so the production
    // loader (not a bare serde call) is what this gate exercises.
    let fixture_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/corpus_swift_written");

    let corpus = load_corpus(fixture_dir.to_str().unwrap())
        .expect("Rust must decode a Swift-written corpus directory");

    // Top-level corpus fields.
    assert_eq!(corpus.seed, 42);
    assert_eq!(corpus.distractors_per_needle, 1);
    assert_eq!(corpus.needles.len(), 5);
    assert_eq!(corpus.records.len(), 11);

    // First needle — T1 lexical, no split partner.
    // All eight Needle fields are asserted individually so any key-name
    // divergence or value drift in either port is immediately visible.
    let n0 = &corpus.needles[0];
    assert_eq!(n0.id,       "n0000",
        "needle id mismatch — the Rust loader did not read the Swift-written id");
    assert_eq!(n0.query,    "What is the charter year of the Quillon Charter?",
        "needle query mismatch");
    assert_eq!(n0.content,  "the Quillon Charter was chartered in the year 1926.",
        "needle content mismatch — GOLDEN PIN; should match crossPortGoldenPin in Swift");
    assert_eq!(n0.tier,     NoiseTier::Lexical,
        "needle tier mismatch — Swift writes T1; serde must decode NoiseTier::Lexical");
    assert_eq!(n0.location, "Ledger/quillon-charter",
        "needle location mismatch");
    assert_eq!(n0.distractor_ids, vec!["n0000-t1-0".to_string()],
        "distractor ids mismatch — Swift writes camelCase key distractorIDs");
    assert!(n0.split_partner_id.is_none(),
        "T1 needle must have no split partner; Swift omits the key for nil");
    assert_eq!(n0.expected_rank, 1,
        "expectedRank mismatch — Swift writes camelCase; serde rename must decode it");

    // Spot-check the T4 needle (split): splitPartnerID must decode from Swift's
    // presence-only key (Swift omits the key when nil, writes the value when Some).
    let n3 = &corpus.needles[3];
    assert_eq!(n3.tier, NoiseTier::Split,
        "fourth needle must be T4 split");
    assert_eq!(n3.split_partner_id.as_deref(), Some("n0003-partner"),
        "T4 split partner id must decode from Swift-written splitPartnerID");
    assert_eq!(n3.expected_rank, 1,
        "T4 needle expectedRank must be 1");
}
