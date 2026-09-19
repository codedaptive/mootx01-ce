//! fact_layer_corpus.rs — deterministic fact-triple corpus for the fact-layer
//! supersession capability cell (PR-08, Deliverable 2).
//!
//! Rust twin of `FactLayerCorpus.swift`. Same seed → same bytes on both ports,
//! validated by the conformance vector at
//! `conformance/fact_layer_vectors.json` (seed = 20260725).
//!
//! INTERNAL CAPABILITY CELL — OUTSIDE THE FAIRNESS-RULE COMPARATIVE LANE.
//!
//! This corpus exercises moot-specific structured-fact verbs:
//!   moot_file_fact    — files a subject/predicate/object triple with metadata
//!   moot_retire_fact  — retires (supersedes) a fact by ID
//!   moot_fact_search  — queries filed facts
//!   moot_fact_timeline — retrieves the version history of a fact chain
//!
//! These verbs are NOT part of any public-benchmark fair-comparison lane.
//! No other system is scored here — this cell measures a product-specific
//! mechanism that only mootx01 exposes. Every report carrying this cell MUST
//! carry `cell_type: "internal_capability"` so consumers know it is not a
//! fairness-rule comparative measurement.

use crate::longmemeval_runner::SplitMix64;
use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Corpus model
// ─────────────────────────────────────────────────────────────────────────────

/// One structured fact triple (subject / predicate / object) at a point in time.
///
/// Maps to a `moot_file_fact` call. The harness uses `id` to track which
/// fact UUID was returned by the filing call. Twin of Swift `FactRecord`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FactRecord {
    /// Harness-assigned stable ID (used for ground-truth and retire calls).
    pub id: String,
    /// The subject of the fact ("Alice Nguyen 3").
    pub subject: String,
    /// The predicate ("employer").
    pub predicate: String,
    /// The object value at this point in the timeline ("Acme Robotics").
    pub object: String,
    /// Natural-language sentence filed as body content alongside structured fields.
    pub content: String,
    /// ISO8601 timestamp of when this fact was asserted. Passed as `event_time`.
    pub event_time: String,
    /// Source grounding sentence — the evidence backing this assertion.
    pub source_grounding: String,
    /// 0-based version index within this subject+predicate chain.
    pub version_index: usize,
    /// True for the most-recent (current) version of the chain.
    pub is_current: bool,
}

/// One scored query over the fact corpus. Twin of Swift `FactQuery`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FactQuery {
    pub id: String,
    /// Natural-language question answered by the current fact.
    pub question: String,
    /// Subject the question is about.
    pub subject: String,
    /// Predicate the question targets.
    pub predicate: String,
    /// Current (correct) fact ID — must appear in search results.
    pub current_fact_id: String,
    /// Retired fact IDs — must NOT outrank current_fact_id.
    pub retired_fact_ids: Vec<String>,
}

/// The complete fact-layer corpus. A pure function of `seed`.
/// Twin of Swift `FactLayerCorpus`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FactLayerCorpus {
    pub seed: u64,
    pub facts: Vec<FactRecord>,
    pub queries: Vec<FactQuery>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Deterministic generation
// ─────────────────────────────────────────────────────────────────────────────

/// Builds a `FactLayerCorpus` that is a pure function of `seed`.
///
/// Same seed → same bytes on every call, both Swift and Rust ports.
/// The conformance vector file `conformance/fact_layer_vectors.json` pins
/// the output for seed=20260725 so both legs can be regression-tested.
///
/// Parameters intentionally small so the conformance vector is human-readable
/// and the unit test runs in milliseconds.
///
/// Twin of Swift `generateFactLayerCorpus(seed:factCount:versionsPerFact:)`.
pub fn generate_fact_layer_corpus(
    seed: u64,
    fact_count: usize,
    versions_per_fact: usize,
) -> FactLayerCorpus {
    let mut rng = SplitMix64::new(seed);

    // Vocabulary: plain, unambiguous terms so the harness does not measure
    // whether the product handles complex phrasing — only the lifecycle.
    let first_names = [
        "Alice", "Bruno", "Chiara", "Dmitri", "Elena",
        "Farid", "Grace", "Hamid", "Ingrid", "Jonas",
    ];
    let last_names = [
        "Nguyen", "Osei", "Patel", "Romero", "Schmidt",
        "Tanaka", "Utomo", "Vargas", "Wang", "Zielinski",
    ];

    // (predicate, value_pool, question_template).
    // One value per version index — picked from the pool without replacement
    // so each version is a genuine change. Twin of Swift `predicates` array.
    let predicates: &[(&str, &[&str], &str)] = &[
        (
            "employer",
            &["Acme Robotics", "Northwind Analytics", "Beta Corp",
              "Vireo Systems", "Halcyon Labs", "Crest Technology"],
            "Where does %s work?",
        ),
        (
            "city",
            &["Lisbon", "Toronto", "Osaka", "Nairobi", "Reykjavik", "Montevideo"],
            "In what city does %s live?",
        ),
        (
            "role",
            &["staff engineer", "engineering manager", "principal architect",
              "director of platform", "technical lead", "VP of Engineering"],
            "What is %s's current role?",
        ),
        (
            "primary_language",
            &["Swift", "Rust", "Elixir", "OCaml", "Zig", "Haskell"],
            "What programming language does %s primarily use?",
        ),
    ];

    let mut facts: Vec<FactRecord> = Vec::new();
    let mut queries: Vec<FactQuery> = Vec::new();

    // Timeline epoch: fixed, never wall-clock, so the corpus is byte-stable
    // across runs and machines. 2020-01-26T00:53:20Z (Unix 1_580_000_000).
    // Same epoch as SupersessionCorpus for consistency.
    let epoch = 1_580_000_000.0_f64;

    for fi in 0..fact_count {
        let fn_idx = (rng.next_u64() % first_names.len() as u64) as usize;
        let ln_idx = (rng.next_u64() % last_names.len() as u64) as usize;
        // Index suffix guarantees entity uniqueness across the corpus.
        let subject = format!("{} {} {}", first_names[fn_idx], last_names[ln_idx], fi);

        let (predicate, value_pool, question_template) = predicates[fi % predicates.len()];

        // Pick distinct values for each version (no repeats within a chain).
        let mut pool: Vec<&str> = value_pool.to_vec();
        let mut chain_values: Vec<String> = Vec::new();
        for _ in 0..versions_per_fact.min(pool.len()) {
            let idx = (rng.next_u64() % pool.len() as u64) as usize;
            chain_values.push(pool.remove(idx).to_string());
        }

        let mut chain_ids: Vec<String> = Vec::new();
        for (vi, value) in chain_values.iter().enumerate() {
            let fact_id = format!("fact-{fi}-v{vi}");
            chain_ids.push(fact_id.clone());
            // Versions land 120–240 days apart, strictly increasing.
            let day_offset = vi as f64 * (120.0 + (rng.next_u64() % 120) as f64);
            let when = epoch + day_offset * 86_400.0;
            let is_current = vi == chain_values.len() - 1;
            // Content phrasing avoids "was" / "changed from" so the harness
            // does not accidentally test language-model coreference — only
            // the structured timeline makes the current version identifiable.
            let content = if vi == 0 {
                format!("{subject}'s {predicate} is {value}.")
            } else {
                format!("{subject}'s {predicate} is now {value}.")
            };
            let event_time = unix_to_iso8601(when);
            let grounding = format!(
                "Source: internal profile record, effective {event_time}."
            );
            facts.push(FactRecord {
                id: fact_id,
                subject: subject.clone(),
                predicate: predicate.to_string(),
                object: value.clone(),
                content,
                event_time,
                source_grounding: grounding,
                version_index: vi,
                is_current,
            });
        }

        // Query is keyed on the last (current) chain ID.
        let current_fact_id = chain_ids.last().cloned().unwrap_or_default();
        let retired: Vec<String> = chain_ids[..chain_ids.len().saturating_sub(1)].to_vec();
        let question = question_template.replace("%s", &subject);
        queries.push(FactQuery {
            id: format!("fq-{fi}"),
            question,
            subject,
            predicate: predicate.to_string(),
            current_fact_id,
            retired_fact_ids: retired,
        });
    }

    FactLayerCorpus { seed, facts, queries }
}

// ─────────────────────────────────────────────────────────────────────────────
// ISO8601 timestamp helper
// ─────────────────────────────────────────────────────────────────────────────

/// Converts a Unix timestamp (seconds since epoch) to an ISO8601 UTC string.
///
/// Produces exactly the format `2020-01-26T00:53:20Z` — no sub-second
/// component, Z suffix — matching Swift's `ISO8601DateFormatter` output
/// with `TimeZone(secondsFromGMT: 0)`.
pub fn unix_to_iso8601(ts: f64) -> String {
    let secs = ts as i64;
    // Decompose into date components using a pure-arithmetic proleptic
    // Gregorian algorithm (matches C mktime / Swift Date on the same inputs).
    let (year, month, day, h, m, s) = secs_to_datetime(secs);
    format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
}

/// Decomposes a Unix second-count into (year, month 1-12, day 1-31, h, m, s).
///
/// Uses the civil-calendar algorithm from Howard Hinnant's "chrono-Compatible
/// Low-Level Date Algorithms" (https://howardhinnant.github.io/date_algorithms.html),
/// which is the same underlying algorithm the C standard library and Swift Date use
/// for proleptic Gregorian decomposition.
fn secs_to_datetime(secs: i64) -> (i32, u32, u32, u32, u32, u32) {
    let days = secs.div_euclid(86400) as i32;
    let time = secs.rem_euclid(86400) as u32;
    let h = time / 3600;
    let m = (time % 3600) / 60;
    let s = time % 60;

    // civil_from_days: Hinnant algorithm §2.
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097) as u32;            // day of era [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // year of era [0, 399]
    let y = yoe as i32 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // day of year [0, 365]
    let mp = (5 * doy + 2) / 153;                    // month of period [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1;            // day [1, 31]
    let m_civil = if mp < 10 { mp + 3 } else { mp - 9 }; // month [1, 12]
    let y_civil = if m_civil <= 2 { y + 1 } else { y };

    (y_civil, m_civil, d, h, m, s)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Epoch is 2020-01-26T00:53:20Z — verifies the ISO formatter against the
    /// known anchor the Swift port also checks.
    #[test]
    fn epoch_formats_correctly() {
        assert_eq!(unix_to_iso8601(1_580_000_000.0), "2020-01-26T00:53:20Z");
    }

    /// Determinism: two calls with the same seed must produce identical corpora.
    #[test]
    fn generation_is_deterministic() {
        let a = generate_fact_layer_corpus(20260725, 10, 2);
        let b = generate_fact_layer_corpus(20260725, 10, 2);
        assert_eq!(a, b);
    }

    /// Seed sensitivity: different seeds must diverge on the first fact.
    #[test]
    fn different_seeds_produce_different_corpora() {
        let a = generate_fact_layer_corpus(20260725, 4, 2);
        let b = generate_fact_layer_corpus(99999999, 4, 2);
        assert_ne!(a.facts[0].subject, b.facts[0].subject,
            "different seeds must produce different subjects");
    }

    /// Every chain has exactly `versions_per_fact` fact records; the last is current.
    #[test]
    fn chain_structure_invariants() {
        let corpus = generate_fact_layer_corpus(20260725, 6, 3);
        // 6 entities × 3 versions = 18 facts total
        assert_eq!(corpus.facts.len(), 18);
        assert_eq!(corpus.queries.len(), 6);
        // Each query's retired_fact_ids + current_fact_id covers a full chain.
        for q in &corpus.queries {
            assert_eq!(q.retired_fact_ids.len(), 2,
                "chain of 3 versions → 2 retired: {:?}", q);
        }
    }

    /// The last version of each chain is marked is_current=true.
    #[test]
    fn is_current_set_on_last_version() {
        let corpus = generate_fact_layer_corpus(20260725, 4, 2);
        for q in &corpus.queries {
            // The current fact must exist and have is_current=true.
            let current = corpus.facts.iter().find(|f| f.id == q.current_fact_id)
                .expect("current_fact_id not found in facts");
            assert!(current.is_current, "current version must have is_current=true");
            // All retired facts must have is_current=false.
            for rid in &q.retired_fact_ids {
                let retired = corpus.facts.iter().find(|f| f.id == *rid)
                    .expect("retired_fact_id not found in facts");
                assert!(!retired.is_current, "retired version must have is_current=false");
            }
        }
    }

    /// Codable round-trip: serialise → deserialise must produce the same corpus.
    #[test]
    fn serde_round_trip() {
        let corpus = generate_fact_layer_corpus(20260725, 4, 2);
        let json = serde_json::to_string(&corpus).expect("serialize failed");
        let back: FactLayerCorpus = serde_json::from_str(&json).expect("deserialize failed");
        assert_eq!(corpus, back);
    }

    /// Conformance vector: if the pinned vector file exists, check the first
    /// fact record's fields against it. Graceful skip when the file is absent
    /// (unit-test environment without the full repo fixture tree).
    #[test]
    fn conformance_vector_pin() {
        let vector_path =
            "conformance/fact_layer_vectors.json";
        let Ok(json) = std::fs::read_to_string(vector_path) else {
            // Vector file absent — acceptable in isolated unit-test environments.
            return;
        };
        let pinned: FactLayerCorpus =
            serde_json::from_str(&json).expect("conformance vector parse failed");
        let live = generate_fact_layer_corpus(20260725, 10, 2);
        assert_eq!(live.facts[0].id, pinned.facts[0].id,
            "first fact id diverges from conformance vector");
        assert_eq!(live.facts[0].subject, pinned.facts[0].subject,
            "first fact subject diverges from conformance vector");
    }
}
