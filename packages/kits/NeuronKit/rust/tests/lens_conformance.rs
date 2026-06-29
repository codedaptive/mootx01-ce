//! Lens vector conformance — the Rust half of the shared-artifact gate
//! (NEURONKIT_SPEC § 7, § 9). Reads the SAME
//! `Tests/NeuronKitTests/Fixtures/lens_vectors.json` the Swift
//! `LensVectorConformanceTests` suite reads (QueueKit's fixtures
//! pattern) and asserts every lens reproduces the expected outputs
//! bit-for-bit. Floats travel as bit-pattern hex strings, so equality
//! is exact and JSON-precision-safe.
//!
//! A failure here is a cross-version drift signal. The artifact is
//! re-recorded only from the Swift leg (the design surface), only
//! after a DELIBERATE behavioral change:
//!   RECORD_LENS_VECTORS=1 swift test --filter LensVectorConformance

use std::collections::HashSet;
use std::path::PathBuf;

use serde::Deserialize;

use neuron_kit::{
    anomalies, anticipate, benchmark_score, bradley_terry, constellations, dp_summary, drift,
    keystones, latent_themes, learned_preference, mmr_select, page_recall,
    partial_recall, representation_bias, rerank, shingle_similarity, spreading_activation,
    summary_overlap, synthesize, theme_weather, ActionObservation, DrawerRow, DrawerRowMeta,
    RecallFrameTuning, RecallPage, ScenarioProfile,
};
use neuron_kit::{
    calibration_lens::calibrate as lens_calibrate,
    complexity::complexity,
    moment_signature::moment_signature,
    precedence::precedence,
    rhythm::rhythm,
};
use genius_locus_kit::{MatrixCalibrationCurve, MatrixCalibrationOutcome};
use substrate_ml::moment_summary::RowLite;
use substrate_ml::temporal_causality_fold::{TemporalCausalityKey, TemporalFieldCoord};
// FCA and ARM engines live in SubstrateML, not this crate.
use substrate_ml::association_rule_mining::{mine_association_rules, MiningThresholds};
use substrate_ml::formal_concept_analysis::{BoundedConceptMiner, FormalAttribute, FormalContext};
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::{MatrixO, RowId, HLC};

// Engram is a type alias for Fingerprint256 (engram_lib::Engram = Fingerprint256).
// Use Fingerprint256 directly — same type, already imported.
type Engram = Fingerprint256;

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/NeuronKitTests/Fixtures/lens_vectors.json")
}

/// Sort all JSON object keys recursively, producing a new Value where every
/// object's keys appear in ascending lexicographic order.
///
/// Required because Cargo feature unification may activate serde_json's
/// `preserve_order` feature (GeniusLocusKit requests it), which switches
/// `Value`'s internal map from `BTreeMap` to `IndexMap`. With `IndexMap`,
/// `serde_json::to_value` preserves struct declaration order instead of
/// sorting keys — breaking the implicit sort the two-step `to_value →
/// to_string` pattern relied on. Sorting explicitly here makes canonical
/// encoding independent of which map type is active, matching Swift's
/// `.sortedKeys` unconditionally.
fn sort_keys(v: serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(map) => {
            let mut pairs: Vec<(String, serde_json::Value)> =
                map.into_iter().map(|(k, v)| (k, sort_keys(v))).collect();
            pairs.sort_by(|a, b| a.0.cmp(&b.0));
            serde_json::Value::Object(pairs.into_iter().collect())
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.into_iter().map(sort_keys).collect())
        }
        other => other,
    }
}

fn f32_of(s: &str) -> f32 {
    f32::from_bits(u32::from_str_radix(&s[2..], 16).unwrap())
}
fn f64_of(s: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(&s[2..], 16).unwrap())
}
fn u64_of(s: &str) -> u64 {
    u64::from_str_radix(&s[2..], 16).unwrap()
}
fn hex32(v: f32) -> String {
    format!("{:#010x}", v.to_bits())
}
fn hex64(v: f64) -> String {
    format!("{:#018x}", v.to_bits())
}
fn hexu64(v: u64) -> String {
    format!("{:#018x}", v)
}
fn fp_of(blocks: &[String]) -> Fingerprint256 {
    Fingerprint256 {
        block0: u64_of(&blocks[0]),
        block1: u64_of(&blocks[1]),
        block2: u64_of(&blocks[2]),
        block3: u64_of(&blocks[3]),
    }
}
fn blocks_of(fp: Fingerprint256) -> Vec<String> {
    vec![
        hexu64(fp.block0),
        hexu64(fp.block1),
        hexu64(fp.block2),
        hexu64(fp.block3),
    ]
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LensVectors {
    drift: Vec<DriftCase>,
    anomalies: Vec<AnomalyCase>,
    keystones: Vec<KeystonesCase>,
    constellations: Vec<ConstellationCase>,
    spreading_activation: Vec<ActivationCase>,
    theme_weather: Vec<ThemeWeatherCase>,
    latent_themes: Vec<LatentThemesCase>,
    representation_bias: Vec<BiasCase>,
    learned_preference: Vec<PreferenceCase>,
    anticipate: Vec<AnticipateCase>,
    partial_recall: Vec<PartialRecallCase>,
    mind_overlap: Vec<MindOverlapCase>,
    shingle_similarity: Vec<ShingleCase>,
    // Families migrated by BYCOPY_MIGRATION_001:
    benchmark_scoring: Vec<BenchmarkScoringCase>,
    mmr_rank: Vec<MmrRankCase>,
    formal_concept_analysis: Vec<FcaCase>,
    hybrid_recall: HybridRecallSection,
    association_rule_mining: Vec<AssocRuleCase>,
    scenario_profile: Vec<ScenarioProfileCase>,
    context_synthesizer: Vec<ContextSynthesizerCase>,
    bradley_terry: Vec<BradleyTerryCase>,
    // Five-Lenses families (TASK-MXE-N4):
    moment_signature: Vec<MomentSignatureCase>,
    rhythm: Vec<RhythmCase>,
    precedence: Vec<PrecedenceCase>,
    complexity: Vec<ComplexityCase>,
    calibration: Vec<CalibrationCase>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DriftCase {
    p: Vec<String>,
    q: Vec<String>,
    jensen_shannon: String,
    kl_divergence: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AnomalyCase {
    values: Vec<String>,
    threshold: String,
    flagged: Vec<FlaggedEntry>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FlaggedEntry {
    index: usize,
    z_score: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeystonesCase {
    #[serde(rename = "nodeIDs")]
    node_ids: Vec<String>,
    edges: Vec<[String; 2]>,
    top_k: usize,
    ranked: Vec<RankedKeystone>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RankedKeystone {
    id: String,
    centrality: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConstellationCase {
    #[serde(rename = "nodeIDs")]
    node_ids: Vec<String>,
    edges: Vec<[String; 2]>,
    max_passes: usize,
    communities: Vec<Vec<String>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActivationCase {
    adjacency: Vec<Vec<AdjacencyEdge>>,
    seed: usize,
    walk_length: usize,
    restart_prob: String,
    rng_seed: u64,
    k: usize,
    activations: Vec<ActivatedNode>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AdjacencyEdge {
    node: usize,
    weight: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActivatedNode {
    node: usize,
    activation: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThemeWeatherCase {
    categories: Vec<CategoryMass>,
    momenta: Vec<MomentumEntry>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CategoryMass {
    category: String,
    raw_count: String,
    weighted_mass: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MomentumEntry {
    category: String,
    momentum: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LatentThemesCase {
    labels: Vec<String>,
    cooccurrence: Vec<CooccurrencePair>,
    k: usize,
    seed: u64,
    result_k: usize,
    loadings: Vec<LoadingEntry>,
    reconstruction_error: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CooccurrencePair {
    label_a: String,
    label_b: String,
    weight: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoadingEntry {
    label: String,
    loadings: Vec<String>,
    dominant_theme: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BiasCase {
    estate: Vec<LabeledMass>,
    reference: Vec<LabeledMass>,
    biases: Vec<BiasEntry>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LabeledMass {
    label: String,
    mass: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BiasEntry {
    label: String,
    estate_share: String,
    reference_share: String,
    bias: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PreferenceCase {
    records: Vec<CurationRecord>,
    strengths: Vec<StrengthEntry>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CurationRecord {
    label: String,
    endorsements: i64,
    dismissals: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StrengthEntry {
    label: String,
    strength: String,
    confidence_low: String,
    confidence_high: String,
    endorsements: i64,
    dismissals: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AnticipateCase {
    observations: Vec<ObservationEntry>,
    target_outcome: u8,
    k: usize,
    min_observations: u32,
    predictions: Vec<PredictionEntry>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ObservationEntry {
    action: u8,
    outcome: u8,
    success: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PredictionEntry {
    action: u8,
    success_rate: String,
    count: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PartialRecallCase {
    anchor: Vec<String>,
    rows: Vec<Vec<String>>,
    match_blocks: Vec<u8>,
    differ_blocks: Vec<u8>,
    k: usize,
    matches: Vec<MatchEntry>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MatchEntry {
    row: usize,
    score: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MindOverlapCase {
    fingerprints_a: Vec<Vec<String>>,
    fingerprints_b: Vec<Vec<String>>,
    epsilon: String,
    delta: String,
    k_anonymity: usize,
    seed: u64,
    summary_a: Vec<String>,
    summary_b: Vec<String>,
    overlap: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShingleCase {
    a: String,
    b: String,
    similarity: String,
}

// ── BYCOPY_MIGRATION_001 structs ─────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BenchmarkScoringCase {
    expected_i_ds: Vec<String>,
    found_per_query: Vec<Vec<String>>,
    query_count: usize,
    recall_overlap: String,
    recall_precision: String,
    mean_reciprocal_rank: String,
    not_found_in_branch: Vec<String>,
    new_in_branch: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MmrRankCandidate {
    // id is carried for Swift-leg ordering; Rust uses expected_indices by position.
    #[allow(dead_code)]
    id: String,
    block_bits: Vec<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MmrRankCase {
    candidates: Vec<MmrRankCandidate>,
    lambda: f32,
    k: i64,
    // expected_i_ds carries Swift's string ordering; Rust verifies by index.
    #[allow(dead_code)]
    expected_i_ds: Vec<String>,
    expected_indices: Vec<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FcaAttr {
    namespace: String,
    key: String,
    value: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FcaConcept {
    extent: Vec<usize>,
    intent: Vec<FcaAttr>,
    support: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FcaCase {
    rows: Vec<Vec<FcaAttr>>,
    min_support: usize,
    max_intent_size: usize,
    max_concepts: usize,
    concepts: Vec<FcaConcept>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HybridDrawer {
    id: String,
    content: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RerankCase {
    drawers: Vec<HybridDrawer>,
    mmr_lambda: f32,
    expected_order: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PageEntry {
    ids: Vec<String>,
    is_last: bool,
    page_index: i32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PagingCase {
    rows: Vec<HybridDrawer>,
    page_size: i32,
    pages: Vec<PageEntry>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HybridRecallSection {
    rerank_cases: Vec<RerankCase>,
    paging_cases: Vec<PagingCase>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AssocItemPair {
    field: u8,
    value: u8,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AssocRule {
    antecedent_field: u8,
    antecedent_value: u8,
    consequent_field: u8,
    consequent_value: u8,
    support: String,
    confidence: String,
    lift: String,
    leverage: String,
    conviction: String, // "inf" or f64 hex
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AssocRuleCase {
    rows: Vec<Vec<AssocItemPair>>,
    active_row_count: i64,
    min_support: f64,
    min_confidence: f64,
    rules: Vec<AssocRule>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScenarioProfileCase {
    profile_i_d: String,
    name: String,
    framing_parameters: std::collections::BTreeMap<String, String>,
    scoring_breakdown: std::collections::BTreeMap<String, f64>,
    preference_weights: std::collections::BTreeMap<String, f64>,
    created_at: String,
    training_eligible: bool,
    // Swift-produced canonical sorted-keys JSON. Since SCENARIO_WIRE_PARITY_001
    // (serde rename_all = camelCase + the explicit profileID rename), both legs
    // share the Swift Codable camelCase wire vocabulary, and the Rust verifier
    // compares its own sorted-keys encoding against this byte-for-byte.
    canonical_json: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContextSynthRow {
    content: String,
    #[serde(rename = "parentNodeId")]
    parent_node_id: String,
    wing: String,
    room: String,
    // State in bits 0-5 of adjectiveBitmap (LocusKit State enum raws).
    // Cluster A (currently believed) = (state_raw >> 4) & 0x3 == 0,
    // i.e. states 0-15 (active=0, pending=1, contested=2, accepted=3).
    adjective_bitmap: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContextSynthesizerCase {
    rows: Vec<ContextSynthRow>,
    summary: String,
    patterns: Vec<String>,
    key_insights: Vec<String>,
    success_rate: String, // f32 hex
    recommendations_count: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BtOutcome {
    winner: String,
    loser: String,
    count: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BtScore {
    competitor_i_d: String,
    strength: String,
    confidence_low: String,
    confidence_high: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BradleyTerryCase {
    outcomes: Vec<BtOutcome>,
    tolerance: String,
    scores: Vec<BtScore>,
}

// Five-Lenses case structs (TASK-MXE-N4)

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MsRanked {
    candidate: Vec<String>,    // 4-element block-hex array
    hamming_distance: u32,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MomentSignatureCase {
    rows: Vec<Vec<String>>,       // each row is a 4-element block-hex array
    candidates: Vec<Vec<String>>,
    signature_blocks: Vec<String>,
    ranking: Vec<MsRanked>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RhythmPeriod {
    period_seconds: String,         // f64 hex
    relative_magnitude: String,     // f64 hex
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RhythmCase {
    buckets: Vec<bool>,
    bucket_duration_seconds: String, // f64 hex
    top_k: usize,
    periods: Vec<RhythmPeriod>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PrecPair {
    source_field: String,
    source_value: String,
    target_field: String,
    target_value: String,
    lag_bucket: i32,
    count: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PrecRanked {
    source_field: String,
    source_value: String,
    lag_bucket: i32,
    count: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PrecedenceCase {
    pairs: Vec<PrecPair>,
    target_field: String,
    target_value: String,
    k: usize,
    ranked: Vec<PrecRanked>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ComplexityCase {
    counts_a: Vec<String>,              // f32 hex
    counts_b: Option<Vec<String>>,      // f32 hex; absent = not provided
    joint: Option<Vec<Vec<String>>>,    // f32 hex; absent = not provided
    entropy_a: String,                  // f32 hex
    entropy_b: Option<String>,          // f32 hex; absent when counts_b absent
    mutual_information: Option<String>, // f32 hex; absent when joint absent
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CalibRecord {
    value: String,   // f32 hex
    outcome: String, // "success" | "failure"
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CalibOutput {
    claimed_hex: String,
    calibrated_hex: String,
    is_calibrated: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CalibrationCase {
    records: Vec<CalibRecord>,
    claimed: Vec<String>,
    calibrated: Vec<CalibOutput>,
}

#[test]
fn lenses_reproduce_shared_vectors() {
    let data = std::fs::read_to_string(fixture_path()).expect("shared lens_vectors.json");
    let v: LensVectors = serde_json::from_str(&data).expect("vector schema");

    for c in &v.drift {
        let p: Vec<f32> = c.p.iter().map(|s| f32_of(s)).collect();
        let q: Vec<f32> = c.q.iter().map(|s| f32_of(s)).collect();
        let out = drift(&p, &q);
        assert_eq!(
            hex32(out.jensen_shannon),
            c.jensen_shannon,
            "drift jensen_shannon"
        );
        assert_eq!(
            hex32(out.kl_divergence),
            c.kl_divergence,
            "drift kl_divergence"
        );
    }

    for c in &v.anomalies {
        let values: Vec<f32> = c.values.iter().map(|s| f32_of(s)).collect();
        let out = anomalies(&values, f32_of(&c.threshold));
        assert_eq!(out.len(), c.flagged.len(), "anomalies count");
        for (got, want) in out.iter().zip(&c.flagged) {
            assert_eq!(got.index, want.index, "anomaly index");
            assert_eq!(hex32(got.z_score), want.z_score, "anomaly z_score");
        }
    }

    for c in &v.keystones {
        let edges: Vec<(String, String)> = c
            .edges
            .iter()
            .map(|e| (e[0].clone(), e[1].clone()))
            .collect();
        let out = keystones(&c.node_ids, &edges, c.top_k);
        assert_eq!(out.len(), c.ranked.len(), "keystones count");
        for (got, want) in out.iter().zip(&c.ranked) {
            assert_eq!(got.id, want.id, "keystone id");
            assert_eq!(
                hex64(got.centrality),
                want.centrality,
                "keystone centrality"
            );
        }
    }

    for c in &v.constellations {
        let edges: Vec<(String, String)> = c
            .edges
            .iter()
            .map(|e| (e[0].clone(), e[1].clone()))
            .collect();
        let out = constellations(&c.node_ids, &edges, c.max_passes);
        assert_eq!(out.communities, c.communities, "constellation communities");
    }

    for c in &v.spreading_activation {
        let adjacency: Vec<Vec<(usize, f64)>> = c
            .adjacency
            .iter()
            .map(|row| row.iter().map(|e| (e.node, f64_of(&e.weight))).collect())
            .collect();
        let out = spreading_activation(
            &adjacency,
            c.seed,
            c.walk_length,
            f64_of(&c.restart_prob),
            c.rng_seed,
            c.k,
        );
        assert_eq!(out.len(), c.activations.len(), "activation count");
        for (got, want) in out.iter().zip(&c.activations) {
            assert_eq!(got.node, want.node, "activated node");
            assert_eq!(hex64(got.activation), want.activation, "activation");
        }
    }

    for c in &v.theme_weather {
        let categories: Vec<(String, f64, f64)> = c
            .categories
            .iter()
            .map(|m| {
                (
                    m.category.clone(),
                    f64_of(&m.raw_count),
                    f64_of(&m.weighted_mass),
                )
            })
            .collect();
        let out = theme_weather(&categories);
        assert_eq!(out.len(), c.momenta.len(), "momentum count");
        for (got, want) in out.iter().zip(&c.momenta) {
            assert_eq!(got.category, want.category, "momentum category");
            assert_eq!(hex64(got.momentum), want.momentum, "momentum");
        }
    }

    for c in &v.latent_themes {
        let cooccurrence: Vec<(String, String, f64)> = c
            .cooccurrence
            .iter()
            .map(|p| (p.label_a.clone(), p.label_b.clone(), f64_of(&p.weight)))
            .collect();
        let out = latent_themes(&c.labels, &cooccurrence, c.k, c.seed);
        assert_eq!(out.k, c.result_k, "latent themes k");
        assert_eq!(
            hex64(out.reconstruction_error),
            c.reconstruction_error,
            "reconstruction error"
        );
        assert_eq!(out.loadings.len(), c.loadings.len(), "loading count");
        for (got, want) in out.loadings.iter().zip(&c.loadings) {
            assert_eq!(got.label, want.label, "loading label");
            assert_eq!(got.dominant_theme, want.dominant_theme, "dominant theme");
            let got_bits: Vec<String> = got.loadings.iter().map(|x| hex64(*x)).collect();
            assert_eq!(got_bits, want.loadings, "loading vector");
        }
    }

    for c in &v.representation_bias {
        let estate: Vec<(String, f64)> = c
            .estate
            .iter()
            .map(|m| (m.label.clone(), f64_of(&m.mass)))
            .collect();
        let reference: Vec<(String, f64)> = c
            .reference
            .iter()
            .map(|m| (m.label.clone(), f64_of(&m.mass)))
            .collect();
        let out = representation_bias(&estate, &reference);
        assert_eq!(out.len(), c.biases.len(), "bias count");
        for (got, want) in out.iter().zip(&c.biases) {
            assert_eq!(got.label, want.label, "bias label");
            assert_eq!(hex64(got.estate_share), want.estate_share, "estate share");
            assert_eq!(
                hex64(got.reference_share),
                want.reference_share,
                "reference share"
            );
            assert_eq!(hex64(got.bias), want.bias, "bias");
        }
    }

    for c in &v.learned_preference {
        let records: Vec<(String, i64, i64)> = c
            .records
            .iter()
            .map(|r| (r.label.clone(), r.endorsements, r.dismissals))
            .collect();
        let out = learned_preference(&records).expect("learned preference");
        assert_eq!(out.len(), c.strengths.len(), "strength count");
        for (got, want) in out.iter().zip(&c.strengths) {
            assert_eq!(got.label, want.label, "strength label");
            assert_eq!(hex64(got.strength), want.strength, "strength");
            assert_eq!(
                hex64(got.confidence_low),
                want.confidence_low,
                "confidence low"
            );
            assert_eq!(
                hex64(got.confidence_high),
                want.confidence_high,
                "confidence high"
            );
            assert_eq!(got.endorsements, want.endorsements, "endorsements");
            assert_eq!(got.dismissals, want.dismissals, "dismissals");
        }
    }

    for c in &v.anticipate {
        let observations: Vec<ActionObservation> = c
            .observations
            .iter()
            .map(|o| ActionObservation {
                action: o.action,
                outcome: o.outcome,
                success: o.success,
            })
            .collect();
        let out = anticipate(&observations, c.target_outcome, c.k, c.min_observations);
        assert_eq!(out.len(), c.predictions.len(), "prediction count");
        for (got, want) in out.iter().zip(&c.predictions) {
            assert_eq!(got.action, want.action, "predicted action");
            assert_eq!(hex32(got.success_rate), want.success_rate, "success rate");
            assert_eq!(got.count, want.count, "observation count");
        }
    }

    for c in &v.partial_recall {
        // Rows are index-keyed in the artifact; this leg keys them by
        // RowId(index).
        let rows: Vec<(RowId, Fingerprint256)> = c
            .rows
            .iter()
            .enumerate()
            .map(|(i, blocks)| (RowId(i as u128), fp_of(blocks)))
            .collect();
        let match_blocks: HashSet<u8> = c.match_blocks.iter().copied().collect();
        let differ_blocks: HashSet<u8> = c.differ_blocks.iter().copied().collect();
        let out = partial_recall(fp_of(&c.anchor), &rows, &match_blocks, &differ_blocks, c.k);
        assert_eq!(out.len(), c.matches.len(), "match count");
        for (got, want) in out.iter().zip(&c.matches) {
            assert_eq!(got.0, RowId(want.row as u128), "matched row");
            assert_eq!(hex64(got.1), want.score, "match score");
        }
    }

    for c in &v.mind_overlap {
        let fps_a: Vec<Fingerprint256> = c.fingerprints_a.iter().map(|b| fp_of(b)).collect();
        let fps_b: Vec<Fingerprint256> = c.fingerprints_b.iter().map(|b| fp_of(b)).collect();
        let summary_a = dp_summary(
            &fps_a,
            f64_of(&c.epsilon),
            f64_of(&c.delta),
            c.k_anonymity,
            c.seed,
        );
        let summary_b = dp_summary(
            &fps_b,
            f64_of(&c.epsilon),
            f64_of(&c.delta),
            c.k_anonymity,
            c.seed,
        );
        assert_eq!(blocks_of(summary_a), c.summary_a, "summary A");
        assert_eq!(blocks_of(summary_b), c.summary_b, "summary B");
        assert_eq!(
            hex64(summary_overlap(summary_a, summary_b)),
            c.overlap,
            "overlap"
        );
    }

    for c in &v.shingle_similarity {
        assert_eq!(
            hex32(shingle_similarity(&c.a, &c.b)),
            c.similarity,
            "shingle similarity"
        );
    }

    // ── BYCOPY_MIGRATION_001 walkers ─────────────────────────────────────────

    // benchmark_scoring: reproduce the exact same BenchmarkScore field values
    // the Swift leg recorded. All four float metrics travel as f32 hex.
    for c in &v.benchmark_scoring {
        let out = benchmark_score(&c.expected_i_ds, &c.found_per_query);
        assert_eq!(out.query_count, c.query_count, "bs query_count");
        assert_eq!(
            hex32(out.recall_overlap),
            c.recall_overlap,
            "bs recall_overlap"
        );
        assert_eq!(
            hex32(out.recall_precision),
            c.recall_precision,
            "bs recall_precision"
        );
        assert_eq!(
            hex32(out.mean_reciprocal_rank),
            c.mean_reciprocal_rank,
            "bs mean_reciprocal_rank"
        );
        assert_eq!(
            out.not_found_in_branch, c.not_found_in_branch,
            "bs not_found_in_branch"
        );
        assert_eq!(out.new_in_branch, c.new_in_branch, "bs new_in_branch");
    }

    // mmr_rank: reconstruct Engram (= Fingerprint256) from blockBits encoding.
    // Each blockBits element is the count of low bits set in that 64-bit block.
    // Query = all-zero engram. Verify the selection order matches expectedIndices.
    for c in &v.mmr_rank {
        fn low_bits(count: usize) -> u64 {
            if count >= 64 {
                u64::MAX
            } else {
                (1u64 << count) - 1
            }
        }
        let fingerprints: Vec<Engram> = c
            .candidates
            .iter()
            .map(|cand| Engram {
                block0: low_bits(cand.block_bits[0]),
                block1: low_bits(cand.block_bits[1]),
                block2: low_bits(cand.block_bits[2]),
                block3: low_bits(cand.block_bits[3]),
            })
            .collect();
        let query = Engram {
            block0: 0,
            block1: 0,
            block2: 0,
            block3: 0,
        };
        let order = mmr_select(&fingerprints, &query, c.lambda, c.k);
        assert_eq!(order, c.expected_indices, "mmr_rank selection order");
    }

    // formal_concept_analysis: reconstruct FormalContext from rows of
    // FormalAttribute triples; run BoundedConceptMiner with the artifact's
    // params; verify the concepts match (extent, intent, support).
    for c in &v.formal_concept_analysis {
        let rows: Vec<Vec<FormalAttribute>> = c
            .rows
            .iter()
            .map(|row| {
                row.iter()
                    .map(|a| FormalAttribute {
                        namespace: a.namespace.clone(),
                        key: a.key.clone(),
                        value: a.value.clone(),
                    })
                    .collect()
            })
            .collect();
        let ctx = FormalContext::new(&rows);
        let miner = BoundedConceptMiner::new(c.min_support, c.max_intent_size, c.max_concepts);
        let concepts = miner.mine(&ctx);
        assert_eq!(concepts.len(), c.concepts.len(), "fca concept count");
        for (got, want) in concepts.iter().zip(&c.concepts) {
            // extent is Vec<u32> in Rust, Vec<Int> in artifact
            let got_extent: Vec<usize> = got.extent.iter().map(|&r| r as usize).collect();
            assert_eq!(got_extent, want.extent, "fca extent");
            assert_eq!(got.support, want.support, "fca support");
            assert_eq!(got.intent.len(), want.intent.len(), "fca intent len");
            for (ga, wa) in got.intent.iter().zip(&want.intent) {
                assert_eq!(ga.namespace, wa.namespace, "fca intent namespace");
                assert_eq!(ga.key, wa.key, "fca intent key");
                assert_eq!(ga.value, wa.value, "fca intent value");
            }
        }
    }

    // hybrid_recall rerank cases: build DrawerRow slice, rerank with tuning,
    // verify expected id order.
    for rc in &v.hybrid_recall.rerank_cases {
        let drawers: Vec<DrawerRow> = rc
            .drawers
            .iter()
            .map(|d| DrawerRow {
                id: d.id.clone(),
                content: d.content.clone(),
            })
            .collect();
        let tuning = RecallFrameTuning {
            mmr_lambda: rc.mmr_lambda,
            ..RecallFrameTuning::default_tuning()
        };
        let out = rerank(&drawers, &tuning);
        let ids: Vec<String> = out.iter().map(|d| d.id.clone()).collect();
        assert_eq!(ids, rc.expected_order, "hybrid_recall rerank order");
    }

    // hybrid_recall paging cases: rerank with default tuning, then page;
    // verify page ids, isLast flags, and pageIndex values.
    for pc in &v.hybrid_recall.paging_cases {
        let drawers: Vec<DrawerRow> = pc
            .rows
            .iter()
            .map(|d| DrawerRow {
                id: d.id.clone(),
                content: d.content.clone(),
            })
            .collect();
        let reranked = rerank(&drawers, &RecallFrameTuning::default_tuning());
        let pages = page_recall(&reranked, pc.page_size);
        assert_eq!(pages.len(), pc.pages.len(), "hybrid_recall page count");
        for (got, want) in pages.iter().zip(&pc.pages) {
            let got_ids: Vec<String> = got.rows.iter().map(|d| d.id.clone()).collect();
            assert_eq!(got_ids, want.ids, "hybrid_recall page ids");
            assert_eq!(got.is_last, want.is_last, "hybrid_recall is_last");
            assert_eq!(got.page_index, want.page_index, "hybrid_recall page_index");
        }
    }

    // association_rule_mining: rebuild MatrixO via apply_row, mine rules,
    // verify the expected rule metrics as f64 hex. Infinite conviction →
    // sentinel string "inf" per both-legs convention.
    for c in &v.association_rule_mining {
        let mut matrix = MatrixO::default();
        for row in &c.rows {
            let field_values: Vec<(u8, u8)> = row.iter().map(|p| (p.field, p.value)).collect();
            matrix.apply_row(1_i64, &field_values);
        }
        let thresholds = MiningThresholds {
            min_support: c.min_support,
            min_confidence: c.min_confidence,
        };
        let rules = mine_association_rules(&matrix, c.active_row_count, thresholds);
        assert_eq!(rules.len(), c.rules.len(), "assoc rule count");
        for (got, want) in rules.iter().zip(&c.rules) {
            assert_eq!(
                got.antecedent.field, want.antecedent_field,
                "antecedent field"
            );
            assert_eq!(
                got.antecedent.value, want.antecedent_value,
                "antecedent value"
            );
            assert_eq!(
                got.consequent.field, want.consequent_field,
                "consequent field"
            );
            assert_eq!(
                got.consequent.value, want.consequent_value,
                "consequent value"
            );
            assert_eq!(hex64(got.support), want.support, "assoc support");
            assert_eq!(hex64(got.confidence), want.confidence, "assoc confidence");
            assert_eq!(hex64(got.lift), want.lift, "assoc lift");
            assert_eq!(hex64(got.leverage), want.leverage, "assoc leverage");
            if got.conviction.is_infinite() {
                assert_eq!(want.conviction, "inf", "assoc conviction (inf)");
            } else {
                assert_eq!(hex64(got.conviction), want.conviction, "assoc conviction");
            }
        }
    }

    // scenario_profile: both legs share the Swift Codable camelCase wire
    // vocabulary (SCENARIO_WIRE_PARITY_001), so the Rust sorted-keys encoding
    // must reproduce the Swift-recorded canonical_json byte-for-byte — the
    // cross-leg wire assertion the old per-leg round-trip could not make.
    for c in &v.scenario_profile {
        let profile = ScenarioProfile::new(
            c.profile_i_d.clone(),
            c.name.clone(),
            c.framing_parameters.clone(),
            c.scoring_breakdown.clone(),
            c.preference_weights.clone(),
            c.created_at.clone(),
            c.training_eligible,
        );
        // Explicit sort_keys pass then to_string — the Rust analog of Swift's
        // .sortedKeys. sort_keys is required because Cargo feature unification
        // may activate serde_json's `preserve_order` feature (GeniusLocusKit
        // requests it), which makes to_value emit declaration order instead of
        // sorted order. sort_keys reconstructs every object from a sorted Vec,
        // so keys are ascending-lexicographic regardless of which map type
        // backs Value.
        let value = serde_json::to_value(&profile).expect("scenario profile to_value");
        let canonical =
            serde_json::to_string(&sort_keys(value)).expect("scenario profile serialize");
        assert_eq!(
            canonical, c.canonical_json,
            "sp cross-leg wire bytes (camelCase sorted keys)"
        );
        // Round-trip through Rust JSON and verify field values are preserved.
        let json = canonical.clone();
        let decoded: ScenarioProfile =
            serde_json::from_str(&json).expect("scenario profile deserialize");
        assert_eq!(decoded.profile_id, profile.profile_id, "sp profile_id");
        assert_eq!(decoded.name, profile.name, "sp name");
        assert_eq!(decoded.created_at, profile.created_at, "sp created_at");
        assert_eq!(
            decoded.training_eligible, profile.training_eligible,
            "sp training_eligible"
        );
        // `tournament_report` is `#[serde(skip)]` — runtime-only advisory
        // value that is not part of the wire shape. Verify it is absent.
        assert!(
            !json.contains("tournament_report"),
            "sp no tournament_report"
        );
        assert!(
            !json.contains("tournamentReport"),
            "sp no tournamentReport (camel)"
        );
    }

    // context_synthesizer: build DrawerRow + DrawerRowMeta slices from the
    // artifact's row inputs. The loader derives is_currently_believed from
    // adjectiveBitmap via the State cluster formula documented on the meta
    // construction below: (state_raw >> 4) & 0x3 == 0 (Cluster A — matches
    // LocusKit's shipped Drawer.isCurrentlyBelieved). No source changes.
    for c in &v.context_synthesizer {
        let rows: Vec<DrawerRow> = c
            .rows
            .iter()
            .map(|r| DrawerRow {
                id: r.content.chars().take(8).collect(),
                content: r.content.clone(),
            })
            .collect();
        let meta: Vec<DrawerRowMeta> = c
            .rows
            .iter()
            .map(|r| DrawerRowMeta {
                parent_node_id: r.parent_node_id.clone(),
                wing: r.wing.clone(),
                room: r.room.clone(),
                // State occupies bits 0-5 of adjectiveBitmap (LocusKit State enum).
                // Cluster A (currently believed) = (state_raw >> 4) & 0x3 == 0.
                // This correctly identifies states 0-15 (active, pending, contested,
                // accepted = raws 0,1,2,3) as currently believed, and 16+ as not.
                // Cluster B (16-31: superseded, decayed, withdrawn, expired) and
                // Cluster C (32+: rejected, tombstoned) are NOT currently believed.
                is_currently_believed: {
                    let state_raw = (r.adjective_bitmap & 0x3F) as u8;
                    ((state_raw >> 4) & 0x3) == 0
                },
            })
            .collect();
        let page = RecallPage {
            rows: rows.clone(),
            page_index: 0,
            is_last: true,
        };
        let doc = synthesize(&page, &meta);
        assert_eq!(doc.summary, c.summary, "ctx summary");
        assert_eq!(doc.patterns, c.patterns, "ctx patterns");
        assert_eq!(doc.key_insights, c.key_insights, "ctx key_insights");
        assert_eq!(hex32(doc.success_rate), c.success_rate, "ctx success_rate");
        assert_eq!(
            doc.recommendations.len(),
            c.recommendations_count,
            "ctx recommendations count"
        );
    }

    // bradley_terry: tolerance-based (NOT bit-exact) per the documented
    // C-6-adjacent contract. The tolerance string "1e-6" is carried in the
    // artifact; both legs assert within the same bound.
    for c in &v.bradley_terry {
        let tol: f64 = c.tolerance.parse().unwrap_or(1e-6);
        let outcomes: Vec<neuron_kit::PairwiseOutcome> = c
            .outcomes
            .iter()
            .map(|o| neuron_kit::PairwiseOutcome::new(&o.winner, &o.loser, o.count))
            .collect();
        let fitted = bradley_terry(&outcomes).expect("bradley_terry fit");
        assert_eq!(fitted.len(), c.scores.len(), "bt score count");
        for (got, want) in fitted.iter().zip(&c.scores) {
            assert_eq!(got.competitor_id, want.competitor_i_d, "bt competitor_id");
            let got_str = f64::from_bits(u64::from_str_radix(&want.strength[2..], 16).unwrap());
            let got_lo =
                f64::from_bits(u64::from_str_radix(&want.confidence_low[2..], 16).unwrap());
            let got_hi =
                f64::from_bits(u64::from_str_radix(&want.confidence_high[2..], 16).unwrap());
            assert!(
                (got.strength - got_str).abs() < tol,
                "bt strength: got {}, want {} (tol {})",
                got.strength,
                got_str,
                tol
            );
            assert!(
                (got.confidence_low - got_lo).abs() < tol,
                "bt confidence_low: got {}, want {} (tol {})",
                got.confidence_low,
                got_lo,
                tol
            );
            assert!(
                (got.confidence_high - got_hi).abs() < tol,
                "bt confidence_high: got {}, want {} (tol {})",
                got.confidence_high,
                got_hi,
                tol
            );
        }
    }

    // ── Five-Lenses verification blocks (TASK-MXE-N4) ──────────────────────

    // moment_signature: decode block-hex rows + candidates → call moment_signature.
    for (i, c) in v.moment_signature.iter().enumerate() {
        let rows: Vec<RowLite> = c.rows.iter().map(|b| RowLite {
            fingerprint: fp_of(b),
            capture_hlc: HLC::ZERO,
        }).collect();
        let candidates: Vec<Engram> = c.candidates.iter().map(|b| fp_of(b)).collect();
        let result = moment_signature(&rows, &candidates);
        assert_eq!(
            blocks_of(result.signature), c.signature_blocks,
            "moment_signature[{i}] signature_blocks"
        );
        assert_eq!(result.ranking.len(), c.ranking.len(),
            "moment_signature[{i}] ranking length");
        for (j, (got, want)) in result.ranking.iter().zip(&c.ranking).enumerate() {
            assert_eq!(blocks_of(got.candidate), want.candidate,
                "moment_signature[{i}] ranking[{j}].candidate");
            assert_eq!(got.hamming_distance, want.hamming_distance,
                "moment_signature[{i}] ranking[{j}].hamming_distance");
        }
    }

    // rhythm: decode f64 hex duration → call rhythm.
    for (i, c) in v.rhythm.iter().enumerate() {
        let duration = f64_of(&c.bucket_duration_seconds);
        let result = rhythm(&c.buckets, duration, c.top_k);
        assert_eq!(result.len(), c.periods.len(),
            "rhythm[{i}] period count");
        for (j, (got, want)) in result.iter().zip(&c.periods).enumerate() {
            assert_eq!(hex64(got.period_seconds), want.period_seconds,
                "rhythm[{i}] periods[{j}].period_seconds");
            assert_eq!(hex64(got.relative_magnitude), want.relative_magnitude,
                "rhythm[{i}] periods[{j}].relative_magnitude");
        }
    }

    // precedence: rebuild (TemporalCausalityKey, i64) pairs → call precedence.
    for (i, c) in v.precedence.iter().enumerate() {
        let target = TemporalFieldCoord::new(&c.target_field, &c.target_value);
        let pairs: Vec<(TemporalCausalityKey, i64)> = c.pairs.iter().map(|p| {
            let src = TemporalFieldCoord::new(&p.source_field, &p.source_value);
            let tgt = TemporalFieldCoord::new(&p.target_field, &p.target_value);
            (TemporalCausalityKey::new(src, tgt, p.lag_bucket), p.count)
        }).collect();
        let result = precedence(&pairs, &target, c.k);
        assert_eq!(result.len(), c.ranked.len(),
            "precedence[{i}] ranked length");
        for (j, (got, want)) in result.iter().zip(&c.ranked).enumerate() {
            assert_eq!(got.source.field_path, want.source_field,
                "precedence[{i}] ranked[{j}].source_field");
            assert_eq!(got.source.value_repr, want.source_value,
                "precedence[{i}] ranked[{j}].source_value");
            assert_eq!(got.lag_bucket, want.lag_bucket,
                "precedence[{i}] ranked[{j}].lag_bucket");
            assert_eq!(got.count, want.count,
                "precedence[{i}] ranked[{j}].count");
        }
    }

    // complexity: decode f32 hex count arrays → call complexity.
    for (i, c) in v.complexity.iter().enumerate() {
        let counts_a: Vec<f32> = c.counts_a.iter().map(|s| f32_of(s)).collect();
        let counts_b: Option<Vec<f32>> = c.counts_b.as_ref()
            .map(|v| v.iter().map(|s| f32_of(s)).collect());
        let joint: Option<Vec<Vec<f32>>> = c.joint.as_ref()
            .map(|rows| rows.iter().map(|row| row.iter().map(|s| f32_of(s)).collect()).collect());
        let result = complexity(&counts_a, counts_b.as_deref(), joint.as_deref());
        assert_eq!(hex32(result.entropy_a), c.entropy_a,
            "complexity[{i}] entropy_a");
        match (&result.entropy_b, &c.entropy_b) {
            (Some(got), Some(want)) => assert_eq!(hex32(*got), *want,
                "complexity[{i}] entropy_b"),
            (None, None) => {}
            _ => panic!("complexity[{i}] entropy_b present/absent mismatch"),
        }
        match (&result.mutual_information, &c.mutual_information) {
            (Some(got), Some(want)) => assert_eq!(hex32(*got), *want,
                "complexity[{i}] mutual_information"),
            (None, None) => {}
            _ => panic!("complexity[{i}] mutual_information present/absent mismatch"),
        }
    }

    // calibration: replay records to build the curve → call lens_calibrate.
    for (i, c) in v.calibration.iter().enumerate() {
        let mut curve = MatrixCalibrationCurve::new();
        for r in &c.records {
            let outcome = if r.outcome == "success" {
                MatrixCalibrationOutcome::Success
            } else {
                MatrixCalibrationOutcome::Failure
            };
            curve.record(f32_of(&r.value), outcome);
        }
        let claimed: Vec<f32> = c.claimed.iter().map(|s| f32_of(s)).collect();
        let result = lens_calibrate(&curve, &claimed);
        assert_eq!(result.len(), c.calibrated.len(),
            "calibration[{i}] output length");
        for (j, (got, want)) in result.iter().zip(&c.calibrated).enumerate() {
            assert_eq!(hex32(got.claimed), want.claimed_hex,
                "calibration[{i}] [{j}].claimed");
            assert_eq!(hex32(got.calibrated), want.calibrated_hex,
                "calibration[{i}] [{j}].calibrated");
            assert_eq!(got.is_calibrated, want.is_calibrated,
                "calibration[{i}] [{j}].is_calibrated");
        }
    }
}
