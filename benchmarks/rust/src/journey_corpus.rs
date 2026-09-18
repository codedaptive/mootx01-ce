//! journey_corpus.rs — deterministic corpus generators for the two journey-
//! measurement lanes. Twin of Swift `JourneyCorpus.swift`.
//!
//! WHY JOURNEY LANES EXIST. Public benchmarks provision a fresh estate per
//! question and ask binary retrieval questions: was the right item in the top
//! k? That design cannot measure two retrieval failure modes that appear only
//! when a memory system is used across multi-step agent journeys:
//!
//!   PRECISE-MISS: the correct fact is in the store, but a near-duplicate DECOY
//!     that repeats the query's distinctive tokens more densely outranks it.
//!     A BM25-only system fails this reliably; a system with date-aware scoring
//!     or dense vector recall may pass it. The lane measures the gap.
//!
//!   VAGUE-NARROW: the agent must resolve a vague, open-ended query ("which
//!     entry addresses X?") against a cluster of on-topic siblings, only one of
//!     which carries the specific answer detail. Keyword overlap alone cannot
//!     distinguish the true member from the siblings.
//!
//! Both corpora are pure functions of their seed — same seed, same bytes. The
//! conformance gate enforces this across the Swift and Rust legs.
//!
//! FAIRNESS RULE — load-bearing, do not relax it. Every scored behaviour must
//! be achievable in principle by any competent retrieval system. Nothing here
//! requires a moot-specific feature. A benchmark only our product can pass is
//! marketing; a benchmark that is simply harder, and that we happen to be good
//! at, is measurement.

use crate::longmemeval_runner::SplitMix64;
use crate::supersession_corpus::iso8601_from_epoch_seconds;
use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// PRECISE-MISS corpus model
// ─────────────────────────────────────────────────────────────────────────────

/// A single record in a PRECISE-MISS corpus — either the target, the decoy,
/// or a filler for a given scenario.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PreciseMissRecord {
    pub id: String,
    /// The text content that would be filed into the memory system.
    pub content: String,
    /// ISO8601 instant (UTC). All four records in a scenario share the same
    /// instant — eventTime is not the scored dimension here.
    pub event_time: String,
}

/// Ground truth and corpus identifiers for one PRECISE-MISS scenario.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PreciseMissScenario {
    pub id: String,
    /// The query the agent would issue.
    pub question: String,
    /// The record that carries the specific answer the question asks for.
    #[serde(rename = "targetRecordID")]
    pub target_record_id: String,
    /// The near-duplicate record engineered to outrank the target on lexical
    /// overlap alone. It densely repeats the query's distinctive tokens but
    /// deliberately omits the answer detail.
    ///
    /// WHY A DECOY. A recall system that ranks by bag-of-words similarity
    /// will surface the decoy over the target because the decoy accumulates
    /// more token-overlap weight. The target mentions the query tokens once
    /// each, then states the answer. The decoy repeats the tokens many times,
    /// filling its content with them, but never states the answer. Measuring
    /// how often the target outranks the decoy tests whether the system goes
    /// beyond pure frequency ranking to semantic or structural precision.
    #[serde(rename = "decoyRecordID")]
    pub decoy_record_id: String,
    /// Filler records: on-topic for the scenario's domain but carry no answer.
    /// Their presence prevents the scenario's true target from being trivially
    /// findable by topic alone (without the query).
    #[serde(rename = "fillerRecordIDs")]
    pub filler_record_ids: Vec<String>,
}

/// The complete PRECISE-MISS corpus: records to ingest and scenarios to score.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PreciseMissCorpus {
    pub seed: u64,
    pub scenario_count: i64,
    pub records: Vec<PreciseMissRecord>,
    pub scenarios: Vec<PreciseMissScenario>,
}

// ─────────────────────────────────────────────────────────────────────────────
// VAGUE-NARROW corpus model
// ─────────────────────────────────────────────────────────────────────────────

/// A single member record in a VAGUE-NARROW cluster.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct VagueNarrowRecord {
    pub id: String,
    pub content: String,
    pub event_time: String,
}

/// One cluster of on-topic member records, exactly one of which carries the
/// answer for the cluster's vague query.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct VagueNarrowCluster {
    pub id: String,
    /// A deliberately open-ended query that does not name the true member.
    pub question: String,
    /// All member record ids in this cluster.
    #[serde(rename = "memberIDs")]
    pub member_ids: Vec<String>,
    /// The one member that carries the answer.
    #[serde(rename = "trueID")]
    pub true_id: String,
}

/// The complete VAGUE-NARROW corpus.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct VagueNarrowCorpus {
    pub seed: u64,
    pub cluster_count: i64,
    pub members_per_cluster: i64,
    pub records: Vec<VagueNarrowRecord>,
    pub clusters: Vec<VagueNarrowCluster>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Bundled corpus
// ─────────────────────────────────────────────────────────────────────────────

/// Both sub-corpora bundled into one serialisable unit, so the conformance
/// vector file and `--dump-seed` path carry everything in one file.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct JourneyCorpus {
    pub seed: u64,
    pub precise_miss: PreciseMissCorpus,
    pub vague_narrow: VagueNarrowCorpus,
}

// ─────────────────────────────────────────────────────────────────────────────
// Topic definitions
// ─────────────────────────────────────────────────────────────────────────────

struct PreciseMissTopic {
    attr: &'static str,
    names: &'static [&'static str],
    answers: &'static [&'static str],
    question_form: &'static str,
}

// Word-for-word twin of the Swift topic arrays.
const PRECISE_MISS_TOPICS: &[PreciseMissTopic] = &[
    PreciseMissTopic {
        attr: "count-survey",
        names: &["Harrow", "Pelton", "Ridgemark", "Calwen", "Forley", "Dunmore"],
        answers: &["12", "38", "7", "54", "21", "9"],
        question_form: "What did the %@ count survey record for the north zone?",
    },
    PreciseMissTopic {
        attr: "batch-test",
        names: &["B14", "B7", "B22", "B5", "B31", "B9"],
        answers: &["74 units", "120 units", "31 units", "88 units", "215 units", "17 units"],
        question_form: "What output did batch %@ produce in the lab test?",
    },
    PreciseMissTopic {
        attr: "station-log",
        names: &["S-3", "S-7", "S-11", "S-4", "S-9", "S-6"],
        answers: &["412 kPa", "1.8 m/s", "19 C", "220 V", "64 pct", "38 kPa"],
        question_form: "What reading did station %@ log in the pressure report?",
    },
    PreciseMissTopic {
        attr: "route-check",
        names: &["Mallow", "Tenby", "Corvin", "Aldren", "Fenwick", "Dray"],
        answers: &["14.2 km", "8.7 km", "23.1 km", "5.6 km", "19.4 km", "11.3 km"],
        question_form: "What distance did the %@ route check record for the north segment?",
    },
];

struct VagueNarrowTopic {
    attr: &'static str,
    areas: &'static [&'static str],
    question_form: &'static str,
}

const VAGUE_NARROW_TOPICS: &[VagueNarrowTopic] = &[
    VagueNarrowTopic {
        attr: "protocol-set",
        areas: &["Harrow", "Pelton", "Ridgemark", "Calwen", "Forley", "Dunmore"],
        question_form: "Which entry in the %@ protocol set handles the critical path procedure?",
    },
    VagueNarrowTopic {
        attr: "equipment-list",
        areas: &["Lab-A", "Lab-B", "Lab-C", "Lab-D", "Lab-E", "Lab-F"],
        question_form: "Which item on the %@ equipment list measures peak load?",
    },
    VagueNarrowTopic {
        attr: "log-book",
        areas: &["Mallow", "Tenby", "Corvin", "Aldren", "Fenwick", "Dray"],
        question_form: "Which entry in the %@ log book records the initial calibration?",
    },
    VagueNarrowTopic {
        attr: "reference-set",
        areas: &["Atlas", "Cairn", "Dunbar", "Elwick", "Folton", "Greyson"],
        question_form: "Which document in the %@ reference set confirms the operating limit?",
    },
];

// ─────────────────────────────────────────────────────────────────────────────
// Deterministic generation
// ─────────────────────────────────────────────────────────────────────────────

/// Generates both journey sub-corpora from `seed`. Same seed → same bytes on
/// every run and on both the Swift and Rust legs (conformance-gated).
///
/// The shared RNG is threaded through both sub-generators in sequence: first
/// PRECISE-MISS draws, then VAGUE-NARROW draws. The draw order within each
/// generator is identical to the Swift leg — any reordering breaks conformance.
pub fn generate_journey_corpus(
    seed: u64,
    precise_miss_count: usize,
    cluster_count: usize,
    members_per_cluster: usize,
) -> JourneyCorpus {
    let mut rng = SplitMix64::new(seed);

    // Fixed epoch — never the wall clock — so the corpus never changes between
    // runs. Same epoch as SupersessionCorpus for consistency across the suite.
    let epoch: f64 = 1_580_000_000.0; // 2020-01-26T00:53:20Z

    let precise_miss = generate_precise_miss_corpus(
        seed, precise_miss_count, &mut rng, epoch,
    );
    let vague_narrow = generate_vague_narrow_corpus(
        seed, cluster_count, members_per_cluster, &mut rng, epoch, precise_miss_count,
    );

    JourneyCorpus { seed, precise_miss, vague_narrow }
}

fn generate_precise_miss_corpus(
    seed: u64,
    count: usize,
    rng: &mut SplitMix64,
    epoch: f64,
) -> PreciseMissCorpus {
    let mut records: Vec<PreciseMissRecord> = Vec::new();
    let mut scenarios: Vec<PreciseMissScenario> = Vec::new();

    for i in 0..count {
        let topic = &PRECISE_MISS_TOPICS[i % PRECISE_MISS_TOPICS.len()];

        let name = topic.names[(rng.next_u64() % topic.names.len() as u64) as usize];
        let answer = topic.answers[(rng.next_u64() % topic.answers.len() as u64) as usize];

        // All four records in a scenario share one timestamp. Scenarios are
        // spaced one week apart on the fixed epoch timeline.
        let when = epoch + i as f64 * 7.0 * 86_400.0;
        let timestamp = iso8601_from_epoch_seconds(when as i64);

        let target_id = format!("pm-{i}-t");
        let decoy_id = format!("pm-{i}-d");
        let filler0_id = format!("pm-{i}-f0");
        let filler1_id = format!("pm-{i}-f1");

        records.push(PreciseMissRecord {
            id: target_id.clone(),
            content: precise_miss_target_content(topic.attr, name, answer),
            event_time: timestamp.clone(),
        });
        records.push(PreciseMissRecord {
            id: decoy_id.clone(),
            content: precise_miss_decoy_content(topic.attr, name),
            event_time: timestamp.clone(),
        });
        records.push(PreciseMissRecord {
            id: filler0_id.clone(),
            content: precise_miss_filler_content(topic.attr, name, 0),
            event_time: timestamp.clone(),
        });
        records.push(PreciseMissRecord {
            id: filler1_id.clone(),
            content: precise_miss_filler_content(topic.attr, name, 1),
            event_time: timestamp,
        });

        scenarios.push(PreciseMissScenario {
            id: format!("pm-q-{i}"),
            question: topic.question_form.replace("%@", name),
            target_record_id: target_id,
            decoy_record_id: decoy_id,
            filler_record_ids: vec![filler0_id, filler1_id],
        });
    }

    PreciseMissCorpus {
        seed,
        scenario_count: count as i64,
        records,
        scenarios,
    }
}

fn generate_vague_narrow_corpus(
    seed: u64,
    cluster_count: usize,
    members_per_cluster: usize,
    rng: &mut SplitMix64,
    epoch: f64,
    scenario_offset: usize,
) -> VagueNarrowCorpus {
    let mut records: Vec<VagueNarrowRecord> = Vec::new();
    let mut clusters: Vec<VagueNarrowCluster> = Vec::new();

    for i in 0..cluster_count {
        let topic = &VAGUE_NARROW_TOPICS[i % VAGUE_NARROW_TOPICS.len()];

        let area = topic.areas[(rng.next_u64() % topic.areas.len() as u64) as usize];
        // True member index: which of the membersPerCluster members carries the answer.
        let true_idx = (rng.next_u64() % members_per_cluster as u64) as usize;

        // Clusters placed after the PRECISE-MISS scenarios on the timeline,
        // one week apart. Members within a cluster share the cluster's timestamp.
        let when = epoch + (scenario_offset + i) as f64 * 7.0 * 86_400.0;
        let timestamp = iso8601_from_epoch_seconds(when as i64);

        let mut member_ids: Vec<String> = Vec::new();
        for j in 0..members_per_cluster {
            let member_id = format!("vn-{i}-{j}");
            member_ids.push(member_id.clone());
            let content = if j == true_idx {
                vague_narrow_true_content(topic.attr, area, j)
            } else {
                vague_narrow_sibling_content(topic.attr, area, j)
            };
            records.push(VagueNarrowRecord {
                id: member_id,
                content,
                event_time: timestamp.clone(),
            });
        }

        clusters.push(VagueNarrowCluster {
            id: format!("vn-q-{i}"),
            question: topic.question_form.replace("%@", area),
            true_id: format!("vn-{i}-{true_idx}"),
            member_ids,
        });
    }

    VagueNarrowCorpus {
        seed,
        cluster_count: cluster_count as i64,
        members_per_cluster: members_per_cluster as i64,
        records,
        clusters,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Content helpers — word-for-word twins of the Swift helpers
// ─────────────────────────────────────────────────────────────────────────────

/// The target carries the specific answer detail the question asks for.
/// It mentions the query tokens exactly once each, then states the answer.
fn precise_miss_target_content(attr: &str, name: &str, answer: &str) -> String {
    match attr {
        "count-survey" => format!(
            "{name} count survey north zone result: {answer}. Field crew verified the total."
        ),
        "batch-test" => format!(
            "Batch {name} lab test output: {answer}. Technician sign-off on file."
        ),
        "station-log" => format!(
            "Station {name} pressure report: reading was {answer} at 0800."
        ),
        "route-check" => format!(
            "{name} route check north segment distance: {answer}. Inspector sign-off complete."
        ),
        _ => format!("{name} {attr} result: {answer}."),
    }
}

/// The decoy repeats the query's distinctive tokens many times without ever
/// stating the answer. A system that ranks purely by lexical frequency will
/// surface the decoy first, which is the failure mode being measured.
fn precise_miss_decoy_content(attr: &str, name: &str) -> String {
    match attr {
        "count-survey" => format!(
            "The {name} count survey examined north zone data. {name} count survey north zone \
             readings were logged. Count survey {name} north zone figures are on record."
        ),
        "batch-test" => format!(
            "Batch {name} lab test batch {name} data was processed. The lab test for batch \
             {name} examined lab test batch parameters. Batch {name} lab test logs are on file."
        ),
        "station-log" => format!(
            "Station {name} pressure report readings were taken at station {name}. The {name} \
             pressure report station {name} log was filed. Pressure report station {name} data \
             is archived."
        ),
        "route-check" => format!(
            "The {name} route check north segment records were filed. {name} route check north \
             segment measurements are on file. Route check {name} north segment data was recorded."
        ),
        _ => format!("{name} {attr} {name} data was recorded. {name} {attr} activity {name}."),
    }
}

/// Filler records are on-topic for the domain but carry no answer.
fn precise_miss_filler_content(attr: &str, name: &str, index: usize) -> String {
    match (attr, index) {
        ("count-survey", 0) => format!("{name} count survey equipment was staged before deployment."),
        ("count-survey", _) => format!("North zone observations were noted in {name} count survey records."),
        ("batch-test",   0) => format!("Batch {name} materials were staged before the lab test."),
        ("batch-test",   _) => format!("The lab test protocol was verified for batch {name}."),
        ("station-log",  0) => format!("Station {name} equipment was inspected last quarter."),
        ("station-log",  _) => format!("The pressure team reviewed station {name} logs."),
        ("route-check",  0) => format!("{name} route check team departed at first light."),
        ("route-check",  _) => format!("North segment conditions were noted in the {name} route check."),
        _                   => format!("{name} {attr} general notes are on file."),
    }
}

/// The true member carries the specific answer detail for the cluster's vague
/// query — a fact that the question asks about.
fn vague_narrow_true_content(attr: &str, area: &str, member_index: usize) -> String {
    match attr {
        "protocol-set" => format!(
            "{area} protocol set entry {member_index}: critical path procedure requires \
             48-hour hold and dual sign-off. Verified effective."
        ),
        "equipment-list" => format!(
            "{area} equipment list item {member_index}: peak load meter, calibrated range \
             0-500 N. In service."
        ),
        "log-book" => format!(
            "{area} log book entry {member_index}: initial calibration completed, reference \
             value 1.00. Accepted."
        ),
        "reference-set" => format!(
            "{area} reference set document {member_index}: operating limit is 85 C. Confirmed."
        ),
        _ => format!("{area} {attr} entry {member_index}: answer detail confirmed."),
    }
}

/// Sibling members are plausible on-topic entries — same domain, same format,
/// but they carry no answer to the cluster's specific question.
fn vague_narrow_sibling_content(attr: &str, area: &str, member_index: usize) -> String {
    match attr {
        "protocol-set"   => format!("{area} protocol set entry {member_index}: general administration procedures. Standard reference."),
        "equipment-list" => format!("{area} equipment list item {member_index}: general monitoring equipment. Routine maintenance."),
        "log-book"       => format!("{area} log book entry {member_index}: routine check, no anomalies noted. Closed."),
        "reference-set"  => format!("{area} reference set document {member_index}: background reference material. For information only."),
        _                => format!("{area} {attr} entry {member_index}: general information on file."),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generation_is_a_pure_function_of_seed() {
        let a = generate_journey_corpus(42, 4, 3, 4);
        let b = generate_journey_corpus(42, 4, 3, 4);
        assert_eq!(a, b);
        let c = generate_journey_corpus(43, 4, 3, 4);
        // Different seed → different corpus.
        assert_ne!(a.precise_miss.records[0].content, c.precise_miss.records[0].content);
    }

    #[test]
    fn precise_miss_scenario_has_four_records() {
        let corpus = generate_journey_corpus(20260725, 4, 0, 6);
        // Each scenario contributes target + decoy + 2 fillers = 4 records.
        assert_eq!(corpus.precise_miss.records.len(), 16);
        assert_eq!(corpus.precise_miss.scenarios.len(), 4);
        for (i, s) in corpus.precise_miss.scenarios.iter().enumerate() {
            assert_eq!(s.target_record_id, format!("pm-{i}-t"));
            assert_eq!(s.decoy_record_id, format!("pm-{i}-d"));
            assert_eq!(s.filler_record_ids, vec![format!("pm-{i}-f0"), format!("pm-{i}-f1")]);
        }
    }

    #[test]
    fn vague_narrow_cluster_has_true_id() {
        let corpus = generate_journey_corpus(20260725, 0, 3, 4);
        for cluster in &corpus.vague_narrow.clusters {
            assert!(cluster.member_ids.contains(&cluster.true_id));
        }
    }

    #[test]
    fn topics_cycle_across_scenarios() {
        let corpus = generate_journey_corpus(1, 8, 0, 4);
        // Topic attr for scenario 4 must match scenario 0 (4 % 4 = 0).
        let q0 = &corpus.precise_miss.scenarios[0].question;
        let q4 = &corpus.precise_miss.scenarios[4].question;
        // Different names are drawn, but the question_form base is the same.
        // Both use the "count-survey" topic (index 0 and 4 % 4 = 0).
        let base = "count survey";
        assert!(q0.contains(base) && q4.contains(base));
    }
}
