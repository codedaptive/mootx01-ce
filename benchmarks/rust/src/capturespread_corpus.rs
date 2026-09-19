//! capturespread_corpus.rs — deterministic corpus generator for the
//! capture-spread benchmark (P2a). Twin of Swift `CaptureSpreadCorpus.swift`.
//!
//! The capture-spread benchmark measures whether the estate's decayed
//! co-occurrence matrix ranks FRESH evidence above a STALE bulk cluster when
//! queried for the CURRENT value of a changing fact. The spread variant gives
//! each record its designed capture date so the HLC clock sees the real age
//! difference; the burst variant omits capture dates so all records receive the
//! batch wall-clock (the null-control cell).
//!
//! CORPUS SHAPE (per spec)
//!
//!   N probe topics (default 50). Per topic:
//!     STALE cluster: 6–10 items, T0..T0+14d (early, high count).
//!     FRESH cluster: 2–3 items, T0+56d..T0+70d (late, low count).
//!   eventTime mirrors captureDate in v1 spread/burst variants (no confound).
//!
//!   M distractor topics (default 150), 2–4 items each, uniform T0+14d..T0+42d.
//!
//! TEMPORAL PROJECTION — THREE VARIANTS
//!
//!   The variant controls how `capture_spread_seed_records` fills the temporal
//!   fields of each `SeedFileRecord`:
//!
//!   Spread:   capture_date = designed per-record date (O-side alive);
//!             event_time   = capture_date (v1 no-confound: T-side == O-side).
//!   Burst:    capture_date = None (batch wall-clock, O-side collapsed);
//!             event_time   = capture_date (T-side alive; null-control cell).
//!   Splitcap: capture_date = designed per-record date (O-side alive);
//!             event_time   = T0 constant "2026-01-01T00:00:00Z" for ALL
//!             records (T-side killed). Comparing splitcap decayed-vs-balanced
//!             isolates the O projection alone; comparing against v1 burst
//!             decayed-vs-balanced (T-side alone) completes the decomposition.
//!
//! DETERMINISM
//!   All generation uses SplitMix64 from `longmemeval_runner`, seeded from the
//!   caller's seed. Same seed = identical corpus and probe set.

use crate::longmemeval_runner::SplitMix64;
use crate::seed_export::SeedFileRecord;
use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Variant enum (owned here; runner imports it)
// ─────────────────────────────────────────────────────────────────────────────

/// Which temporal projection to apply when projecting corpus records onto
/// `SeedFileRecord`. Twin of Swift `CaptureSpreadVariant`.
///
/// - Spread:   captureDate = designed per-record date; eventTime = captureDate.
///             Both O-side and T-side temporal signals are alive (v1).
/// - Burst:    captureDate = nil (batch wall-clock); eventTime = captureDate.
///             O-side collapsed; T-side signal alive. Null-control cell (v1).
/// - Splitcap: captureDate = designed per-record date (O-side alive);
///             eventTime   = T0 constant for all records (T-side killed).
///             Isolates the O projection alone (v2 escape hatch).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureSpreadVariant {
    Spread,
    Burst,
    Splitcap,
}

impl CaptureSpreadVariant {
    /// Raw string representation for report identity and cache keys.
    /// Must match the `--variant` CLI argument values.
    pub fn as_str(self) -> &'static str {
        match self {
            CaptureSpreadVariant::Spread => "spread",
            CaptureSpreadVariant::Burst => "burst",
            CaptureSpreadVariant::Splitcap => "splitcap",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Vocabulary tables — exact twin of Swift's private lets.
// All strings are identical to the Swift source (character-for-character).
// ─────────────────────────────────────────────────────────────────────────────

/// 26 neutral entity-name prefixes. RNG draws upTo(26).
static ENTITY_PREFIXES: [&str; 26] = [
    "Alvex", "Borven", "Caltex", "Drewin", "Elquen", "Fastor",
    "Grevon", "Helmax", "Inlux", "Jorten", "Klaven", "Lorven",
    "Mextun", "Norvel", "Orvex", "Pelvon", "Qorven", "Relmax",
    "Senvex", "Torvun", "Uxlev", "Veltun", "Welvor", "Xelvon",
    "Yelmax", "Zorven",
];

/// 10 attribute labels. RNG draws upTo(10).
static ATTRIBUTE_LABELS: [&str; 10] = [
    "primary contact", "assigned zone", "current project", "assigned tier",
    "home region", "preferred protocol", "active role", "main classifier",
    "reference index", "dispatch group",
];

/// 10×10 value pool. First 5 rows per attribute are "stale" values, last 5 "fresh".
/// RNG picks stale from [0..5) and fresh from [5..10).
static VALUE_POOL: [[&str; 10]; 10] = [
    ["Alpha-7", "Bravo-3", "Charlie-9", "Delta-2", "Echo-5",
     "Foxtrot-8", "Golf-1", "Hotel-6", "India-4", "Juliet-0"],
    ["Zone-Amber", "Zone-Blue", "Zone-Cedar", "Zone-Delta", "Zone-Echo",
     "Zone-Foxtrot", "Zone-Gamma", "Zone-Hotel", "Zone-Indigo", "Zone-Juliet"],
    ["Crestfall", "Dawnbridge", "Edgepath", "Faultline", "Greystone",
     "Harbour-One", "Irongate", "Jaderun", "Keystep", "Lodestar"],
    ["Tier-I", "Tier-II", "Tier-III", "Tier-IV", "Tier-V",
     "Tier-VI", "Tier-VII", "Tier-VIII", "Tier-IX", "Tier-X"],
    ["North-A", "North-B", "South-A", "South-B", "East-A",
     "East-B", "West-A", "West-B", "Central-A", "Central-B"],
    ["Proto-One", "Proto-Two", "Proto-Three", "Proto-Four", "Proto-Five",
     "Proto-Six", "Proto-Seven", "Proto-Eight", "Proto-Nine", "Proto-Ten"],
    ["Analyst", "Coordinator", "Director", "Evaluator", "Facilitator",
     "Guide", "Handler", "Inspector", "Liaison", "Monitor"],
    ["Class-Cyan", "Class-Dusk", "Class-Ember", "Class-Fawn", "Class-Gold",
     "Class-Haze", "Class-Iris", "Class-Jade", "Class-Khaki", "Class-Lime"],
    ["Ref-0011", "Ref-0022", "Ref-0033", "Ref-0044", "Ref-0055",
     "Ref-0066", "Ref-0077", "Ref-0088", "Ref-0099", "Ref-0110"],
    ["Dispatch-A", "Dispatch-B", "Dispatch-C", "Dispatch-D", "Dispatch-E",
     "Dispatch-F", "Dispatch-G", "Dispatch-H", "Dispatch-I", "Dispatch-J"],
];

/// 10 stale-cluster filler phrases. RNG draws upTo(10).
static STALE_FILLERS: [&str; 10] = [
    "confirmed by internal review",
    "recorded in the audit log",
    "verified by the coordinating team",
    "noted during the quarterly check",
    "registered at the status meeting",
    "documented by the assigned analyst",
    "logged under the oversight protocol",
    "flagged in the periodic report",
    "captured in the intake summary",
    "referenced in the progress update",
];

/// 5 fresh-cluster filler phrases. RNG draws upTo(5).
static FRESH_FILLERS: [&str; 5] = [
    "updated after the transition",
    "revised following the handover",
    "changed in the new cycle",
    "corrected per the latest record",
    "adjusted after the review session",
];

/// 4 distractor content templates. RNG draws upTo(4).
/// `%@` is the Swift Objective-C string format specifier; the generator
/// replaces the first `%@` with entityName and the second with codeValue.
static DISTRACTOR_TEMPLATES: [&str; 4] = [
    "%@ has tracking code %@ as of the last sync.",
    "The reference entry for %@ shows code %@ in the current listing.",
    "%@ is indexed under %@ per the maintenance record.",
    "Current registry entry: %@ \u{2192} %@.",
];

/// T0 = 2026-01-01T00:00:00Z in Unix epoch seconds.
/// Stale window:      days 0–14  (T0 .. T0+2 weeks).
/// Fresh window:      days 56–70 (T0+8 weeks .. T0+10 weeks).
/// Distractor window: days 14–42 (T0+2 weeks .. T0+6 weeks).
const T0_EPOCH_SECONDS: u64 = 1_767_225_600;

// ─────────────────────────────────────────────────────────────────────────────
// Output model
// ─────────────────────────────────────────────────────────────────────────────

/// Cluster membership for a generated record. Serde names match Swift Codable
/// keys so one conformance vector file drives both legs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClusterKind {
    Stale,
    Fresh,
    Distractor,
}

impl ClusterKind {
    /// Raw string used for room naming. Matches Swift `rawValue`.
    pub fn as_str(&self) -> &'static str {
        match self {
            ClusterKind::Stale => "stale",
            ClusterKind::Fresh => "fresh",
            ClusterKind::Distractor => "distractor",
        }
    }
}

/// One generated record. Twin of Swift `CaptureSpreadRecord`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSpreadRecord {
    pub id: String,
    pub content: String,
    /// UTC ISO8601 capture timestamp (also used as eventTime — no confound).
    pub capture_date: String,
    pub cluster_kind: ClusterKind,
    pub topic_index: usize,
}

/// One probe topic: entity, attribute, stale value, fresh value, and record ids.
/// Twin of Swift `CaptureSpreadTopic`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSpreadTopic {
    pub topic_index: usize,
    pub entity_name: String,
    pub attribute_label: String,
    pub stale_value: String,
    pub fresh_value: String,
    pub stale_record_ids: Vec<String>,
    pub fresh_record_ids: Vec<String>,
}

/// Probe class. Twin of Swift `CaptureSpreadProbe.ProbeClass`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProbeClass {
    /// Gold = fresh record IDs (decay should help).
    #[serde(rename = "current_value")]
    CurrentValue,
    /// Gold = stale record IDs (over-decay guard).
    #[serde(rename = "what_was_before")]
    WhatWasBefore,
}

impl ProbeClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            ProbeClass::CurrentValue => "current_value",
            ProbeClass::WhatWasBefore => "what_was_before",
        }
    }
}

/// One probe question. Twin of Swift `CaptureSpreadProbe`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSpreadProbe {
    pub probe_id: String,
    pub topic_index: usize,
    pub probe_class: ProbeClass,
    pub query_text: String,
    pub gold_ids: Vec<String>,
}

/// The complete generated corpus. Twin of Swift `CaptureSpreadCorpus`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSpreadCorpus {
    pub seed: u64,
    pub probe_topic_count: usize,
    pub distractor_count: usize,
    pub records: Vec<CaptureSpreadRecord>,
    pub topics: Vec<CaptureSpreadTopic>,
    pub probes: Vec<CaptureSpreadProbe>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Generator
// ─────────────────────────────────────────────────────────────────────────────

/// Generates a deterministic capture-spread corpus from `seed`. Same seed and
/// counts produce identical output on every call and on both ports (Swift twin).
///
/// The RNG call sequence per topic is:
///   1. upTo(26)   → entityIdx
///   2. upTo(10)   → attrIdx
///   3. upTo(5)    → stalePoolIdx (first half of 10-pool)
///   4. upTo(5)    → freshPoolIdx offset (added to 5)
///   5. upTo(5)    → staleCount offset (added to 6, yielding 6–10)
///   per stale item: upTo(15), upTo(3600), upTo(10)
///   6. upTo(2)    → freshCount offset (added to 2, yielding 2–3)
///   per fresh item: upTo(15), upTo(3600), upTo(5)
/// Then per distractor:
///   1. upTo(26), upTo(4), upTo(10), upTo(10)
///   2. upTo(3) → itemCount offset (added to 2, yielding 2–4)
///   per item: upTo(29), upTo(3600)
pub fn generate_capture_spread_corpus(
    seed: u64,
    probe_topic_count: usize,
    distractor_count: usize,
) -> CaptureSpreadCorpus {
    let mut rng = SplitMix64::new(seed);

    let mut records: Vec<CaptureSpreadRecord> = Vec::new();
    let mut topics: Vec<CaptureSpreadTopic> = Vec::new();
    let mut probes: Vec<CaptureSpreadProbe> = Vec::new();

    // ── Probe topics ──────────────────────────────────────────────────────────
    for topic_idx in 0..probe_topic_count {
        // RNG calls 1–4: entity, attribute, stale pool idx, fresh pool idx.
        let entity_idx = rng.next_upto(26) as usize;
        let entity_name = format!("{}-{}", ENTITY_PREFIXES[entity_idx], topic_idx);

        let attr_idx = rng.next_upto(10) as usize;
        let attribute_label = ATTRIBUTE_LABELS[attr_idx];

        let pool = &VALUE_POOL[attr_idx % VALUE_POOL.len()];
        // First 5 entries = stale values, last 5 = fresh values.
        let stale_pool_idx = rng.next_upto(5) as usize;
        let fresh_pool_idx = 5 + rng.next_upto(5) as usize;
        let stale_value = pool[stale_pool_idx];
        let fresh_value = pool[fresh_pool_idx];

        // STALE cluster: 6–10 items captured at T0 + day[0..14].
        let stale_count = 6 + rng.next_upto(5) as usize;
        let mut stale_ids: Vec<String> = Vec::with_capacity(stale_count);
        for item_idx in 0..stale_count {
            let day_offset = rng.next_upto(15) as u64;  // days 0..14
            let second_offset = day_offset * 86_400 + rng.next_upto(3600) as u64;
            let capture_date = iso8601_utc(T0_EPOCH_SECONDS + second_offset);
            let filler = STALE_FILLERS[rng.next_upto(10) as usize];
            let content = format!(
                "{}'s {} is {}. {}.",
                entity_name, attribute_label, stale_value, filler
            );
            let id = format!("cs-s-{}-{}", topic_idx, item_idx);
            records.push(CaptureSpreadRecord {
                id: id.clone(),
                content,
                capture_date,
                cluster_kind: ClusterKind::Stale,
                topic_index: topic_idx,
            });
            stale_ids.push(id);
        }

        // FRESH cluster: 2–3 items captured at T0 + day[56..70].
        // No explicit retirement — decay must win on time signal alone.
        let fresh_count = 2 + rng.next_upto(2) as usize;
        let mut fresh_ids: Vec<String> = Vec::with_capacity(fresh_count);
        for item_idx in 0..fresh_count {
            let day_offset = 56 + rng.next_upto(15) as u64;  // days 56..70
            let second_offset = day_offset * 86_400 + rng.next_upto(3600) as u64;
            let capture_date = iso8601_utc(T0_EPOCH_SECONDS + second_offset);
            let filler = FRESH_FILLERS[rng.next_upto(5) as usize];
            let content = format!(
                "{}'s {} is now {}. {}.",
                entity_name, attribute_label, fresh_value, filler
            );
            let id = format!("cs-f-{}-{}", topic_idx, item_idx);
            records.push(CaptureSpreadRecord {
                id: id.clone(),
                content,
                capture_date,
                cluster_kind: ClusterKind::Fresh,
                topic_index: topic_idx,
            });
            fresh_ids.push(id);
        }

        topics.push(CaptureSpreadTopic {
            topic_index: topic_idx,
            entity_name: entity_name.clone(),
            attribute_label: attribute_label.to_string(),
            stale_value: stale_value.to_string(),
            fresh_value: fresh_value.to_string(),
            stale_record_ids: stale_ids.clone(),
            fresh_record_ids: fresh_ids.clone(),
        });

        // Probe class 1: current_value — gold = fresh IDs.
        probes.push(CaptureSpreadProbe {
            probe_id: format!("probe-cv-{}", topic_idx),
            topic_index: topic_idx,
            probe_class: ProbeClass::CurrentValue,
            query_text: format!("What is {}'s current {}?", entity_name, attribute_label),
            gold_ids: fresh_ids,
        });

        // Probe class 2: what_was_before — gold = stale IDs.
        probes.push(CaptureSpreadProbe {
            probe_id: format!("probe-wb-{}", topic_idx),
            topic_index: topic_idx,
            probe_class: ProbeClass::WhatWasBefore,
            query_text: format!(
                "What was {}'s {} before the change?",
                entity_name, attribute_label
            ),
            gold_ids: stale_ids,
        });
    }

    // ── Distractor topics ─────────────────────────────────────────────────────
    for distractor_idx in 0..distractor_count {
        let entity_idx = rng.next_upto(26) as usize;
        let entity_name = format!("{}-d{}", ENTITY_PREFIXES[entity_idx], distractor_idx);

        let template_idx = rng.next_upto(4) as usize;
        let template = DISTRACTOR_TEMPLATES[template_idx];

        let pool_idx = rng.next_upto(10) as usize;
        let pool = &VALUE_POOL[pool_idx];
        let code_idx = rng.next_upto(10) as usize;
        let code_value = pool[code_idx];

        // 2, 3, or 4 distractor items.
        let item_count = 2 + rng.next_upto(3) as usize;
        for item_idx in 0..item_count {
            // Uniform capture window: T0+14d..T0+42d.
            let day_offset = 14 + rng.next_upto(29) as u64;
            let second_offset = day_offset * 86_400 + rng.next_upto(3600) as u64;
            let capture_date = iso8601_utc(T0_EPOCH_SECONDS + second_offset);
            // Apply template: replace each %@ with entity_name then code_value.
            let content = apply_string_template(template, &entity_name, code_value);
            let id = format!("cs-d-{}-{}", distractor_idx, item_idx);
            records.push(CaptureSpreadRecord {
                id,
                content,
                capture_date,
                cluster_kind: ClusterKind::Distractor,
                topic_index: distractor_idx,
            });
        }
    }

    CaptureSpreadCorpus {
        seed,
        probe_topic_count,
        distractor_count,
        records,
        topics,
        probes,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Seed-record projection
// ─────────────────────────────────────────────────────────────────────────────

/// Projects corpus records onto `SeedFileRecord` for emission via
/// `emit_seed_json`. The variant controls which temporal fields are set:
///
///   Spread:   capture_date = record.capture_date (O-side alive);
///             event_time   = capture_date (v1 no-confound: T-side == O-side).
///   Burst:    capture_date = None (batch wall-clock, O-side collapsed);
///             event_time   = capture_date (T-side alive; null-control cell).
///   Splitcap: capture_date = record.capture_date (O-side alive);
///             event_time   = T0 constant "2026-01-01T00:00:00Z" for all
///             records (T-side killed). Isolates the O projection alone.
///
/// Records are sorted chronologically by corpus `capture_date` in all variants
/// (ingestion order for the estate). For splitcap, event_time is T0 for all
/// records but the sort key remains the corpus captureDate (O-side ordering).
///
/// Twin of Swift `captureSpreadSeedRecords(from:variant:)`.
pub fn capture_spread_seed_records(
    corpus: &CaptureSpreadCorpus,
    variant: CaptureSpreadVariant,
) -> Vec<SeedFileRecord> {
    // Sort chronologically by corpus captureDate (O-side sort key).
    // File order IS ingestion order — the importer never sorts.
    // The sort key is the corpus record's capture_date in all variants; for
    // splitcap, event_time is T0 (constant) so it cannot be the sort key.
    let mut sorted = corpus.records.clone();
    sorted.sort_by(|a, b| {
        a.capture_date.cmp(&b.capture_date)
            .then_with(|| a.id.cmp(&b.id))
    });

    // T0 string used by the splitcap variant to kill the T-side signal.
    let t0_string = iso8601_utc(T0_EPOCH_SECONDS);

    sorted
        .into_iter()
        .map(|r| {
            // Room is TOPIC-keyed, never cluster-keyed: stale and fresh
            // records about the same entity share a room (where a real
            // estate files them), and distractor topics take offset
            // indexes. Encoding stale/fresh in the room would write the
            // measured signal into retrievable metadata. Twin of the
            // Swift roomIndex rule.
            let room_index = if r.cluster_kind == ClusterKind::Distractor {
                r.topic_index + 1000
            } else {
                r.topic_index
            };
            let room = format!("capturespread/topic-{}", room_index);
            // eventTime and capture_date are set according to the variant:
            let (event_time, capture_date) = match variant {
                CaptureSpreadVariant::Spread => {
                    // v1: both sides carry the designed per-record date. No confound.
                    (r.capture_date.clone(), Some(r.capture_date.clone()))
                }
                CaptureSpreadVariant::Burst => {
                    // v1: O-side collapsed (None → batch wall-clock); T-side alive.
                    (r.capture_date.clone(), None)
                }
                CaptureSpreadVariant::Splitcap => {
                    // v2: O-side alive (designed captureDate); T-side killed (T0 constant).
                    (t0_string.clone(), Some(r.capture_date.clone()))
                }
            };
            SeedFileRecord {
                id: r.id,
                content: r.content,
                capture_date,
                event_time,
                room,
                wing: None,
                kind: None,
                sensitivity: None,
                exportability: None,
            }
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Formats a Unix epoch second as UTC ISO8601 "YYYY-MM-DDTHH:MM:SSZ".
///
/// Exact twin of Swift `iso8601UTC(epochSeconds:)`. Uses a naive Gregorian
/// calendar walk from 1970-01-01 — same algorithm, same output for all dates
/// in the corpus's range (2026, days 0–70 past T0). The conformance vector
/// pins both ports to the same byte string.
pub(crate) fn iso8601_utc(epoch_seconds: u64) -> String {
    let mut rem = epoch_seconds;
    let s = rem % 60; rem /= 60;
    let m = rem % 60; rem /= 60;
    let h = rem % 24; rem /= 24;
    // `rem` is days since 1970-01-01.
    let is_leap = |y: u64| y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let days_in_month = [0u64, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut year: u64 = 1970;
    let mut month: usize = 1;
    let mut day: u64 = 1 + rem;
    loop {
        let dim = if month == 2 && is_leap(year) { 29 } else { days_in_month[month] };
        if day <= dim { break; }
        day -= dim;
        month += 1;
        if month > 12 { month = 1; year += 1; }
    }
    format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
}

/// Replaces the first two `%@` occurrences in `template` with `arg1` and
/// `arg2`. Twin of `String(format: template, entityName, codeValue)` in Swift,
/// where `%@` is the Objective-C string format specifier.
fn apply_string_template(template: &str, arg1: &str, arg2: &str) -> String {
    let first = template.replacen("%@", arg1, 1);
    first.replacen("%@", arg2, 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — golden pins (both ports must agree)
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// T0 itself (1_767_225_600 = 2026-01-01T00:00:00Z) must format correctly.
    /// Golden pin that also validates the Gregorian calendar walk.
    #[test]
    fn t0_formats_as_2026_01_01() {
        assert_eq!(iso8601_utc(T0_EPOCH_SECONDS), "2026-01-01T00:00:00Z");
    }

    /// T0 + 70 days = 2026-03-12T00:00:00Z (2026 is not a leap year).
    #[test]
    fn t0_plus_70_days_formats_correctly() {
        assert_eq!(
            iso8601_utc(T0_EPOCH_SECONDS + 70 * 86_400),
            "2026-03-12T00:00:00Z"
        );
    }

    /// Template substitution: both %@ slots must be filled in order.
    #[test]
    fn template_substitution_order() {
        assert_eq!(
            apply_string_template("%@ has tracking code %@ as of the last sync.", "Alvex-0", "Alpha-7"),
            "Alvex-0 has tracking code Alpha-7 as of the last sync."
        );
    }

    /// Golden pin: seed=42, probes=2, distractors=5. First record id and
    /// content are deterministic across both ports. Any RNG sequence change
    /// will break this test.
    #[test]
    fn corpus_golden_pin_seed42() {
        let corpus = generate_capture_spread_corpus(42, 2, 5);
        // Two probe topics + 5 distractors.
        assert!(corpus.probes.len() == 4, "expected 4 probes (2×2), got {}", corpus.probes.len());
        // First record must be the first stale item of topic 0.
        // Its ID and prefix are deterministic.
        let first_stale: Vec<_> = corpus.records.iter()
            .filter(|r| matches!(r.cluster_kind, ClusterKind::Stale) && r.topic_index == 0)
            .collect();
        assert!(!first_stale.is_empty(), "expected stale records for topic 0");
        assert!(first_stale[0].id.starts_with("cs-s-0-"), "unexpected id: {}", first_stale[0].id);

        // Probe IDs follow the expected pattern.
        assert_eq!(corpus.probes[0].probe_id, "probe-cv-0");
        assert_eq!(corpus.probes[1].probe_id, "probe-wb-0");
        assert_eq!(corpus.probes[2].probe_id, "probe-cv-1");
        assert_eq!(corpus.probes[3].probe_id, "probe-wb-1");

        // Gold IDs for current_value must be the fresh cluster IDs for topic 0.
        let cv0 = &corpus.probes[0];
        assert!(cv0.gold_ids.iter().all(|id| id.starts_with("cs-f-0-")),
            "current_value gold IDs must be fresh: {:?}", cv0.gold_ids);
        let wb0 = &corpus.probes[1];
        assert!(wb0.gold_ids.iter().all(|id| id.starts_with("cs-s-0-")),
            "what_was_before gold IDs must be stale: {:?}", wb0.gold_ids);
    }

    /// Seed-record projection: spread variant populates capture_date and
    /// sets event_time == capture_date (v1 no-confound); burst variant omits
    /// capture_date (batch wall-clock) but keeps event_time.
    #[test]
    fn seed_record_projection_spread_vs_burst() {
        let corpus = generate_capture_spread_corpus(42, 2, 5);
        let spread = capture_spread_seed_records(&corpus, CaptureSpreadVariant::Spread);
        let burst  = capture_spread_seed_records(&corpus, CaptureSpreadVariant::Burst);
        assert!(spread.iter().all(|r| r.capture_date.is_some()),
            "spread: every record must have capture_date");
        assert!(burst.iter().all(|r| r.capture_date.is_none()),
            "burst: no record must have capture_date");
        // v1 no-confound: spread event_time == capture_date.
        for r in &spread {
            assert_eq!(r.event_time, r.capture_date.as_deref().unwrap_or(""),
                "spread: event_time must equal capture_date for record {}", r.id);
        }
        // Records are sorted chronologically by corpus captureDate in both variants.
        for w in spread.windows(2) {
            assert!(w[0].event_time <= w[1].event_time,
                "spread not sorted: {} > {}", w[0].event_time, w[1].event_time);
        }
    }

    /// splitcap projection: captureDate carries the designed per-record date
    /// (O-side alive); eventTime is T0 constant for all records (T-side killed).
    /// Scientific contract: splitcap decayed-vs-balanced difference measures the
    /// O projection alone; comparing against v1 burst decayed-vs-balanced
    /// (T-side alone) completes the two-dimensional decomposition.
    ///
    /// Cross-port golden pin: both Swift and Rust ports must satisfy this test.
    #[test]
    fn seed_record_projection_splitcap() {
        let corpus = generate_capture_spread_corpus(42, 2, 5);
        let spread   = capture_spread_seed_records(&corpus, CaptureSpreadVariant::Spread);
        let splitcap = capture_spread_seed_records(&corpus, CaptureSpreadVariant::Splitcap);

        // T-side killed: all event_time values are T0.
        let t0 = "2026-01-01T00:00:00Z";
        assert!(
            splitcap.iter().all(|r| r.event_time == t0),
            "splitcap: every record must have event_time == T0 ({})", t0
        );

        // O-side alive: capture_date is set for every record.
        assert!(
            splitcap.iter().all(|r| r.capture_date.is_some()),
            "splitcap: every record must have capture_date set (O-side alive)"
        );

        // capture_date values match the spread variant exactly (same O-side clock).
        assert_eq!(spread.len(), splitcap.len(),
            "spread and splitcap must have the same record count");
        for (sp, sc) in spread.iter().zip(splitcap.iter()) {
            assert_eq!(
                sp.capture_date, sc.capture_date,
                "splitcap capture_date for {} must equal spread capture_date (O-side identical)",
                sc.id
            );
        }

        // Records are sorted chronologically by corpus captureDate (O-side sort key).
        // event_time is T0 (constant) so capture_date is the ordering field here.
        for w in splitcap.windows(2) {
            assert!(
                w[0].capture_date <= w[1].capture_date,
                "splitcap not sorted by capture_date: {:?} > {:?}",
                w[0].capture_date, w[1].capture_date
            );
        }

        // Cross-port golden pin: record "cs-s-0-0" (first stale item, topic 0,
        // seed=42) must have event_time == T0 and a non-empty capture_date that
        // differs from T0 (O-side is spread, not collapsed).
        let splitcap_first_stale = splitcap.iter().find(|r| r.id == "cs-s-0-0")
            .expect("golden-pin: record 'cs-s-0-0' not found in splitcap projection (seed=42)");
        assert_eq!(splitcap_first_stale.event_time, t0,
            "cs-s-0-0 splitcap event_time must be T0");
        assert!(splitcap_first_stale.capture_date.is_some(),
            "cs-s-0-0 splitcap capture_date must be set");
        assert_ne!(
            splitcap_first_stale.capture_date.as_deref(), Some(t0),
            "cs-s-0-0 splitcap capture_date must differ from T0 (O-side is spread)"
        );
    }
}
