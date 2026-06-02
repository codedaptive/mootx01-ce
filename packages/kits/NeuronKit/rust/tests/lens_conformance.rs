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
    anomalies, anticipate, constellations, dp_summary, drift, keystones, latent_themes,
    learned_preference, partial_recall, representation_bias, shingle_similarity,
    spreading_activation, summary_overlap, theme_weather, ActionObservation,
};
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::RowId;

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/NeuronKitTests/Fixtures/lens_vectors.json")
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
    vec![hexu64(fp.block0), hexu64(fp.block1), hexu64(fp.block2), hexu64(fp.block3)]
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

#[test]
fn lenses_reproduce_shared_vectors() {
    let data = std::fs::read_to_string(fixture_path()).expect("shared lens_vectors.json");
    let v: LensVectors = serde_json::from_str(&data).expect("vector schema");

    for c in &v.drift {
        let p: Vec<f32> = c.p.iter().map(|s| f32_of(s)).collect();
        let q: Vec<f32> = c.q.iter().map(|s| f32_of(s)).collect();
        let out = drift(&p, &q);
        assert_eq!(hex32(out.jensen_shannon), c.jensen_shannon, "drift jensen_shannon");
        assert_eq!(hex32(out.kl_divergence), c.kl_divergence, "drift kl_divergence");
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
        let edges: Vec<(String, String)> =
            c.edges.iter().map(|e| (e[0].clone(), e[1].clone())).collect();
        let out = keystones(&c.node_ids, &edges, c.top_k);
        assert_eq!(out.len(), c.ranked.len(), "keystones count");
        for (got, want) in out.iter().zip(&c.ranked) {
            assert_eq!(got.id, want.id, "keystone id");
            assert_eq!(hex64(got.centrality), want.centrality, "keystone centrality");
        }
    }

    for c in &v.constellations {
        let edges: Vec<(String, String)> =
            c.edges.iter().map(|e| (e[0].clone(), e[1].clone())).collect();
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
            &adjacency, c.seed, c.walk_length, f64_of(&c.restart_prob), c.rng_seed, c.k,
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
            .map(|m| (m.category.clone(), f64_of(&m.raw_count), f64_of(&m.weighted_mass)))
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
        let estate: Vec<(String, f64)> =
            c.estate.iter().map(|m| (m.label.clone(), f64_of(&m.mass))).collect();
        let reference: Vec<(String, f64)> =
            c.reference.iter().map(|m| (m.label.clone(), f64_of(&m.mass))).collect();
        let out = representation_bias(&estate, &reference);
        assert_eq!(out.len(), c.biases.len(), "bias count");
        for (got, want) in out.iter().zip(&c.biases) {
            assert_eq!(got.label, want.label, "bias label");
            assert_eq!(hex64(got.estate_share), want.estate_share, "estate share");
            assert_eq!(hex64(got.reference_share), want.reference_share, "reference share");
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
            assert_eq!(hex64(got.confidence_low), want.confidence_low, "confidence low");
            assert_eq!(hex64(got.confidence_high), want.confidence_high, "confidence high");
            assert_eq!(got.endorsements, want.endorsements, "endorsements");
            assert_eq!(got.dismissals, want.dismissals, "dismissals");
        }
    }

    for c in &v.anticipate {
        let observations: Vec<ActionObservation> = c
            .observations
            .iter()
            .map(|o| ActionObservation { action: o.action, outcome: o.outcome, success: o.success })
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
        let summary_a =
            dp_summary(&fps_a, f64_of(&c.epsilon), f64_of(&c.delta), c.k_anonymity, c.seed);
        let summary_b =
            dp_summary(&fps_b, f64_of(&c.epsilon), f64_of(&c.delta), c.k_anonymity, c.seed);
        assert_eq!(blocks_of(summary_a), c.summary_a, "summary A");
        assert_eq!(blocks_of(summary_b), c.summary_b, "summary B");
        assert_eq!(hex64(summary_overlap(summary_a, summary_b)), c.overlap, "overlap");
    }

    for c in &v.shingle_similarity {
        assert_eq!(hex32(shingle_similarity(&c.a, &c.b)), c.similarity, "shingle similarity");
    }
}
