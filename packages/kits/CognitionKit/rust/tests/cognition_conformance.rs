//! Migration-ranking vector conformance — the Rust half of the shared-artifact
//! gate (BYCOPY_MIGRATION_001). Reads the SAME
//! `Tests/CognitionKitTests/Fixtures/cognition_vectors.json` the Swift
//! `CognitionVectorConformanceTests` suite reads and asserts every
//! migration-ranking function reproduces the expected outputs. Floats travel
//! as bit-pattern hex strings, so equality is exact and JSON-precision-safe.
//!
//! A failure here is a cross-version drift signal. The artifact is
//! re-recorded only from the Swift leg (the design surface), only after a
//! DELIBERATE behavioral change:
//!   RECORD_COGNITION_VECTORS=1 swift test --filter CognitionVectorConformance

use std::path::PathBuf;

use serde::Deserialize;

use cognition_kit::migration_ranking::{
    first_duplicate, lost_concepts, partition_origin, rank, PlanOutcome,
};

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/CognitionKitTests/Fixtures/cognition_vectors.json")
}

fn f32_of(s: &str) -> f32 {
    f32::from_bits(u32::from_str_radix(&s[2..], 16).unwrap())
}
fn hex32(v: f32) -> String {
    format!("{:#010x}", v.to_bits())
}

// ── Schema (mirrored from CognitionVectorConformanceTests.swift) ─────────────

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CognitionVectors {
    first_duplicate: Vec<FirstDuplicateCase>,
    lost_concepts: Vec<LostConceptsCase>,
    partition_origin: Vec<PartitionOriginCase>,
    migration_rank: Vec<MigrationRankCase>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FirstDuplicateCase {
    names: Vec<String>,
    expected: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LostConceptsCase {
    dropped: Vec<String>,
    not_found: Vec<String>,
    expected: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PartitionOriginEntry {
    id: String,
    content: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PartitionOriginCase {
    entries: Vec<PartitionOriginEntry>,
    expected_migratable: Vec<String>,
    expected_dropped: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OutcomeInput {
    name: String,
    recall_overlap: String,
    mean_reciprocal_rank: String,
    lost: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RankedPlanEntry {
    name: String,
    recall_overlap: String,
    mean_reciprocal_rank: String,
    combined_score: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DisqualifiedEntry {
    name: String,
    lost_concepts: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MigrationRankCase {
    outcomes: Vec<OutcomeInput>,
    expected_rankings: Vec<RankedPlanEntry>,
    expected_disqualified: Vec<DisqualifiedEntry>,
    expected_winner: Option<String>,
}

// ── The gate ─────────────────────────────────────────────────────────────────

#[test]
fn migration_ranking_reproduces_shared_vectors() {
    let data = std::fs::read_to_string(fixture_path()).expect("shared cognition_vectors.json");
    let v: CognitionVectors = serde_json::from_str(&data).expect("cognition vector schema");

    // firstDuplicate
    for c in &v.first_duplicate {
        let got = first_duplicate(&c.names);
        assert_eq!(got, c.expected, "first_duplicate {:?}", c.names);
    }

    // lostConcepts
    for c in &v.lost_concepts {
        let got = lost_concepts(&c.dropped, &c.not_found);
        assert_eq!(got, c.expected, "lost_concepts");
    }

    // partitionOrigin
    for c in &v.partition_origin {
        let entries: Vec<(String, String)> = c
            .entries
            .iter()
            .map(|e| (e.id.clone(), e.content.clone()))
            .collect();
        let (migratable, dropped) = partition_origin(&entries);
        assert_eq!(migratable, c.expected_migratable, "partition migratable");
        assert_eq!(dropped, c.expected_dropped, "partition dropped");
    }

    // migrationRank
    for c in &v.migration_rank {
        let outcomes: Vec<PlanOutcome> = c
            .outcomes
            .iter()
            .map(|o| PlanOutcome {
                name: o.name.clone(),
                recall_overlap: f32_of(&o.recall_overlap),
                mean_reciprocal_rank: f32_of(&o.mean_reciprocal_rank),
                lost: o.lost.clone(),
            })
            .collect();
        let result = rank(&outcomes);

        assert_eq!(
            result.rankings.len(),
            c.expected_rankings.len(),
            "rank count"
        );
        for (got, want) in result.rankings.iter().zip(&c.expected_rankings) {
            assert_eq!(got.name, want.name, "ranked name");
            assert_eq!(
                hex32(got.recall_overlap),
                want.recall_overlap,
                "ranked recall_overlap"
            );
            assert_eq!(
                hex32(got.mean_reciprocal_rank),
                want.mean_reciprocal_rank,
                "ranked mrr"
            );
            assert_eq!(
                hex32(got.combined_score),
                want.combined_score,
                "ranked combined_score"
            );
        }

        assert_eq!(
            result.disqualified.len(),
            c.expected_disqualified.len(),
            "disqualified count"
        );
        for (got, want) in result.disqualified.iter().zip(&c.expected_disqualified) {
            assert_eq!(got.name, want.name, "disqualified name");
            assert_eq!(
                got.lost_concepts, want.lost_concepts,
                "disqualified lost_concepts"
            );
        }

        assert_eq!(result.winner, c.expected_winner, "winner");
    }
}
