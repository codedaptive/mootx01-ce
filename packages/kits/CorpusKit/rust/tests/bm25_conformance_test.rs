// bm25_conformance_test.rs — Rust leg of the BM25 cross-language bit-identity
// gate (inspection finding W1).
//
// Retrieval algorithms reference §2.2 claims BM25-derived impacts are
// bit-identical across Swift and Rust after round-half-even quantization at
// QUANT_SCALE=100. This test PROVES that claim against a float-stressing
// fixture. The prior conformance tests (bm25_weighting.rs unit tests) used
// pre-quantized / tiny integer vectors and could not catch a real float
// divergence such as FMA contraction shifting an f64 ULP across a .5
// quantization boundary before quantization.
//
// The fixture is generated deterministically by an xorshift64 PRNG whose seed
// and constants are shared VERBATIM with the Swift leg
// (Tests/CorpusKitTests/BM25ConformanceTests.swift), so both languages build
// the identical (term, doc, tf) table independently — only the canonical
// impact map is checked in, never the table itself.
//
// Two checks:
//   1. Canonical match: build the InvertedIndex from the fixture via
//      BM25Weighting::build, recover each (term,item) impact via a single-term
//      exhaustive_scan, and assert it equals the SAME canonical JSON the Swift
//      leg generated (Tests/SharedVectors/bm25_impact_vectors.json).
//   2. In-language contraction self-check: recompute every raw f64 impact in
//      long-form (separate, named multiply/add steps) and assert it quantizes
//      to the same i32 as the production formula — detecting compiler FMA
//      contraction WITHIN Rust.

use corpus_kit::engine::bm25_weighting::{BM25Parameters, BM25Weighting, TermFreqTable};
use corpus_kit::engine::inverted_index::QUANT_SCALE;
use corpus_kit::engine::bm25_weighting::quantize_impact;
use serde::Deserialize;
use std::collections::HashMap;

// MARK: - Shared deterministic fixture generator
//
// xorshift64 with the SAME seed and constants as the Swift leg. Identical
// arithmetic on identical u64 state yields the identical (term, doc, tf) table.
struct XorShift64 {
    state: u64,
}

impl XorShift64 {
    fn new(seed: u64) -> Self {
        // Seed must be non-zero for xorshift64. The mission seed is fixed.
        let s = if seed == 0 { 0x9E3779B97F4A7C15 } else { seed };
        XorShift64 { state: s }
    }
    fn next(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x
    }
    /// Uniform integer in [lo, hi] inclusive. lo <= hi required.
    fn next_in_range(&mut self, lo: i64, hi: i64) -> i64 {
        let span = (hi - lo + 1) as u64;
        lo + (self.next() % span) as i64
    }
}

// Fixture dimensions — must match the Swift leg exactly.
const FIXTURE_NUM_DOCS: i64 = 240;
const FIXTURE_NUM_TERMS: i64 = 60;
const FIXTURE_SEED: u64 = 0xDB25_0001;
const FIXTURE_K1: f64 = 1.2;
const FIXTURE_B: f64 = 0.75;

/// Build the deterministic term-frequency and doc-length tables. MUST mirror
/// `buildFixture()` in the Swift leg bit-for-bit (iteration order + arithmetic).
fn build_fixture() -> (TermFreqTable, HashMap<String, usize>) {
    let mut rng = XorShift64::new(FIXTURE_SEED);

    // Document IDs and lengths first, in ascending index order. Lengths span
    // 5..400 to give a wide range of |d|/avgdl ratios.
    let mut doc_lengths: HashMap<String, usize> = HashMap::new();
    let mut doc_ids: Vec<String> = Vec::with_capacity(FIXTURE_NUM_DOCS as usize);
    for d in 0..FIXTURE_NUM_DOCS {
        let id = format!("d{:03}", d);
        doc_ids.push(id.clone());
        doc_lengths.insert(id, rng.next_in_range(5, 400) as usize);
    }

    // For each term (ascending index), pick a document subset and per-doc tf.
    let mut term_freqs: TermFreqTable = HashMap::new();
    for t in 0..FIXTURE_NUM_TERMS {
        let term = format!("t{:03}", t);
        let df_target = rng.next_in_range(1, FIXTURE_NUM_DOCS);
        let mut doc_tfs: HashMap<String, usize> = HashMap::new();
        for d in 0..FIXTURE_NUM_DOCS {
            // Deterministic Bernoulli ~ df_target/num_docs via a fresh draw.
            let roll = rng.next_in_range(1, FIXTURE_NUM_DOCS);
            if roll <= df_target {
                let tf = rng.next_in_range(1, 30) as usize;
                doc_tfs.insert(doc_ids[d as usize].clone(), tf);
            }
        }
        // Guarantee at least one posting.
        if doc_tfs.is_empty() {
            doc_tfs.insert(doc_ids[0].clone(), rng.next_in_range(1, 30) as usize);
        }
        term_freqs.insert(term, doc_tfs);
    }

    (term_freqs, doc_lengths)
}

// MARK: - Canonical vector schema (mirrors the Swift Codable types)

#[derive(Deserialize)]
struct BM25CanonicalVector {
    term: String,
    item: String,
    impact: i32,
}

#[derive(Deserialize)]
struct BM25CanonicalFile {
    schema_version: String,
    quant_scale: i32,
    vectors: Vec<BM25CanonicalVector>,
}

fn load_canonical() -> BM25CanonicalFile {
    // The canonical file is at Tests/SharedVectors/bm25_impact_vectors.json
    // relative to the CorpusKit package root. This integration test lives at
    // rust/tests/, so the path walks up two directories then into Tests/.
    const FIXTURE: &[u8] = include_bytes!(
        "../../Tests/SharedVectors/bm25_impact_vectors.json"
    );
    serde_json::from_slice(FIXTURE).expect("bm25_impact_vectors.json must parse")
}

/// Recover the full (term, item) -> quantized impact map from a built index.
/// Postings are not publicly readable, so each term's impacts are recovered via
/// a single-term exhaustive_scan: score = query_weight(=100) * impact, exposed
/// as f32(score)/100 = impact. Impacts are < 2^24, so the f32 round-trip is
/// lossless; recover the i32 by rounding.
fn recover_impacts(
    index: &corpus_kit::engine::inverted_index::InvertedIndex,
    term_mapping: &HashMap<String, u32>,
) -> HashMap<String, HashMap<String, i32>> {
    let mut result: HashMap<String, HashMap<String, i32>> = HashMap::new();
    for (term, &term_id) in term_mapping {
        let hits = index.exhaustive_scan(&[(term_id, QUANT_SCALE)], FIXTURE_NUM_DOCS as usize);
        let mut per_item: HashMap<String, i32> = HashMap::new();
        for hit in hits {
            let recovered = hit.impact.round() as i32;
            per_item.insert(hit.item_id, recovered);
        }
        result.insert(term.clone(), per_item);
    }
    result
}

/// Long-form BM25 raw impact: each multiply/add held in a named binding so the
/// optimizer cannot contract the chain into an FMA. Contraction reference for
/// the in-language self-check.
fn long_form_raw_impact(tf: usize, dl: usize, df: usize, num_docs: usize, avgdl: f64) -> f64 {
    let tf_d = tf as f64;
    let df_d = df as f64;
    // IDF: ln(1 + (N - df + 0.5)/(df + 0.5)), split into named steps.
    let numerator = num_docs as f64 - df_d + 0.5;
    let denominator_idf = df_d + 0.5;
    let ratio = numerator / denominator_idf;
    let idf = (1.0 + ratio).ln();
    // Length norm: (1 - b + b*|d|/avgdl), split.
    let length_ratio = dl as f64 / avgdl.max(1.0);
    let b_scaled = FIXTURE_B * length_ratio;
    let length_norm = 1.0 - FIXTURE_B + b_scaled;
    // Denominator: tf + k1 * length_norm.
    let k1_term = FIXTURE_K1 * length_norm;
    let denom = tf_d + k1_term;
    // Numerator: tf * (k1 + 1).
    let k1_plus_1 = FIXTURE_K1 + 1.0;
    let tf_weighted = tf_d * k1_plus_1;
    let fraction = tf_weighted / denom.max(0.0001);
    idf * fraction
}

// MARK: - Conformance tests

/// CHECK 1: the Rust production build path reproduces the canonical vectors
/// that the Swift leg generated, EXACTLY. Any mismatch is a cross-language
/// BM25 bit-identity violation (finding W1).
#[test]
fn rust_production_matches_canonical() {
    let canonical = load_canonical();
    assert_eq!(canonical.schema_version, "1");
    assert_eq!(canonical.quant_scale, QUANT_SCALE);
    assert!(!canonical.vectors.is_empty());

    let (term_freqs, doc_lengths) = build_fixture();
    let (index, term_mapping) = BM25Weighting::build(
        &term_freqs,
        &doc_lengths,
        BM25Parameters::new(FIXTURE_K1, FIXTURE_B),
    );
    let recovered = recover_impacts(&index, &term_mapping);

    // Flatten recovered into a (term \0 item) -> impact map.
    let mut built: HashMap<String, i32> = HashMap::new();
    for (term, per_item) in &recovered {
        for (item, &impact) in per_item {
            built.insert(format!("{term}\u{0}{item}"), impact);
        }
    }

    assert_eq!(
        built.len(),
        canonical.vectors.len(),
        "vector count drift: built {} vs canonical {}",
        built.len(),
        canonical.vectors.len()
    );

    let mut failures: Vec<String> = Vec::new();
    for v in &canonical.vectors {
        let key = format!("{}\u{0}{}", v.term, v.item);
        match built.get(&key) {
            Some(&got) if got == v.impact => {}
            Some(&got) => failures.push(format!(
                "({},{}): canonical={} rust={}",
                v.term, v.item, v.impact, got
            )),
            None => failures.push(format!("({},{}): missing from rust build", v.term, v.item)),
        }
    }

    if !failures.is_empty() {
        let shown: Vec<&String> = failures.iter().take(50).collect();
        panic!(
            "BM25 Rust-vs-canonical FAILED: {} diverge:\n{}",
            failures.len(),
            shown.iter().map(|s| s.as_str()).collect::<Vec<_>>().join("\n")
        );
    }
}

/// CHECK 2: in-language FMA-contraction self-check. For every posting,
/// recompute the raw f64 impact in long-form and assert it quantizes to the
/// same i32 as the production formula. A divergence means the Rust compiler
/// contracted the production expression into an FMA across a .5 boundary.
#[test]
fn rust_formula_matches_long_form() {
    let (term_freqs, doc_lengths) = build_fixture();
    let num_docs = doc_lengths.len();
    let total_len: usize = doc_lengths.values().sum();
    let avgdl = total_len as f64 / num_docs as f64;

    let mut failures: Vec<String> = Vec::new();
    let mut checked = 0usize;
    for (term, doc_tfs) in &term_freqs {
        let df = doc_tfs.len();
        for (item, &tf) in doc_tfs {
            let dl = *doc_lengths.get(item).unwrap_or(&0);

            // Production formula (mirrors BM25Weighting::build exactly).
            let idf = (1.0 + (num_docs as f64 - df as f64 + 0.5) / (df as f64 + 0.5)).ln();
            let denom = tf as f64
                + FIXTURE_K1 * (1.0 - FIXTURE_B + FIXTURE_B * dl as f64 / avgdl.max(1.0));
            let prod_raw = idf * (tf as f64 * (FIXTURE_K1 + 1.0)) / denom.max(0.0001);
            let prod_quant = quantize_impact(prod_raw);

            // Long-form reference.
            let long_raw = long_form_raw_impact(tf, dl, df, num_docs, avgdl);
            let long_quant = quantize_impact(long_raw);

            checked += 1;
            if prod_quant != long_quant {
                failures.push(format!(
                    "({term},{item}) tf={tf} dl={dl} df={df}: prod_raw={:#018x} long_raw={:#018x} prod_q={prod_quant} long_q={long_quant}",
                    prod_raw.to_bits(),
                    long_raw.to_bits()
                ));
            }
        }
    }

    assert!(checked > 0);
    if !failures.is_empty() {
        let shown: Vec<&String> = failures.iter().take(50).collect();
        panic!(
            "Rust FMA-contraction self-check FAILED: {}/{} diverge:\n{}",
            failures.len(),
            checked,
            shown.iter().map(|s| s.as_str()).collect::<Vec<_>>().join("\n")
        );
    }
}
