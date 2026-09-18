//! lmeb_spec_conformance.rs — vector-driven conformance tests for the Rust lmeb-spec leg.
//!
//! Drives `lmeb_spec_metrics` (and by extension the shared `metric_vectors.json`) to verify
//! identical metric values, R_cap None propagation, two-level aggregation, and §A4 instruction
//! strings on the Rust port.
//!
//! Conformance contract (BENCHMARKER_OPTIMIZER_CONTRACT.md §4):
//!   Same inputs → identical outputs on Rust and Swift legs.
//!   `conformance/lmeb-spec/metric_vectors.json` is the single source of expected values;
//!   neither port hardcodes expected values independently (except golden pins that verify
//!   known exact literals by construction).
//!
//! Path resolution:
//!   CARGO_MANIFEST_DIR = benchmarks/rust/
//!   parent()           = benchmarks/
//!   join(...)          = benchmarks/conformance/lmeb-spec/metric_vectors.json
//!
//! Run with:
//!   CARGO_TARGET_DIR=target-lcspec cargo test --offline lmeb_spec

use mcp_benchmarker_rs::lmeb_spec_metrics::{
    lmeb_spec_ndcg, lmeb_spec_ap, lmeb_spec_recall, lmeb_spec_precision, lmeb_spec_mrr,
    lmeb_spec_r_cap, lmeb_spec_apply_options, lmeb_spec_per_query_metrics,
    lmeb_spec_subset_metrics, lmeb_spec_task_metrics, lmeb_spec_instruction_for_subset,
    LmebSpecOptions, LMEB_SPEC_K_VALUES,
};
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;

// ─────────────────────────────────────────────────────────────────────────────
// Path helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Resolve `benchmarks/conformance/lmeb-spec/<filename>` from CARGO_MANIFEST_DIR.
///
/// CARGO_MANIFEST_DIR = `benchmarks/rust/`; one `parent()` → `benchmarks/`.
fn lmeb_spec_conformance_path(filename: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("benchmarks/ parent must exist")
        .join("conformance")
        .join("lmeb-spec")
        .join(filename)
}

/// Load and parse a JSON file; panic with a clear message on failure.
fn load_json(path: &PathBuf) -> Value {
    let data = std::fs::read(path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {e}", path.display()));
    serde_json::from_slice(&data)
        .unwrap_or_else(|e| panic!("Failed to parse {}: {e}", path.display()))
}

/// Load `metric_vectors.json` from the conformance directory.
fn load_metric_vectors() -> Value {
    load_json(&lmeb_spec_conformance_path("metric_vectors.json"))
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON decode helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Decode a `ranked_doc_ids` JSON array to `Vec<String>`.
fn decode_ranked(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap_or(&vec![])
        .iter()
        .map(|s| s.as_str().unwrap_or("").to_string())
        .collect()
}

/// Decode a `relevant_doc_ids` JSON array to `HashSet<String>`.
fn decode_relevant(v: &Value) -> HashSet<String> {
    v.as_array()
        .unwrap_or(&vec![])
        .iter()
        .map(|s| s.as_str().unwrap_or("").to_string())
        .collect()
}

/// Decode a `LmebSpecOptions` from a JSON object `{"skip_first_result": bool, "ignore_identical_ids": bool}`.
fn decode_options(v: &Value) -> LmebSpecOptions {
    LmebSpecOptions {
        skip_first_result:    v["skip_first_result"].as_bool().unwrap_or(false),
        ignore_identical_ids: v["ignore_identical_ids"].as_bool().unwrap_or(false),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3 nDCG conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `ndcg_cases` vector: `lmeb_spec_ndcg` must match expected within 1e-9.
#[test]
fn lmeb_spec_ndcg_conformance() {
    let vectors = load_metric_vectors();
    let cases = vectors["ndcg_cases"].as_array().expect("ndcg_cases must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let ranked   = decode_ranked(&c["ranked_doc_ids"]);
        let relevant = decode_relevant(&c["relevant_doc_ids"]);
        let k        = c["k"].as_u64().unwrap_or(10) as usize;
        let expected = c["ndcg"].as_f64()
            .unwrap_or_else(|| panic!("case {id}: missing 'ndcg'"));

        let got = lmeb_spec_ndcg(&ranked, &relevant, k);
        assert!(
            (got - expected).abs() < 1e-9,
            "case {id}: nDCG@{k} got {got} expected {expected}"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3 AP conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `ap_cases` vector: `lmeb_spec_ap` must match expected within 1e-9.
#[test]
fn lmeb_spec_ap_conformance() {
    let vectors = load_metric_vectors();
    let cases = vectors["ap_cases"].as_array().expect("ap_cases must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let ranked   = decode_ranked(&c["ranked_doc_ids"]);
        let relevant = decode_relevant(&c["relevant_doc_ids"]);
        let k        = c["k"].as_u64().unwrap_or(10) as usize;
        let expected = c["ap"].as_f64()
            .unwrap_or_else(|| panic!("case {id}: missing 'ap'"));

        let got = lmeb_spec_ap(&ranked, &relevant, k);
        assert!(
            (got - expected).abs() < 1e-9,
            "case {id}: AP@{k} got {got} expected {expected}"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3 Recall conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `recall_cases` vector across all three k values tested in the JSON.
///
/// Each recall case can have `recall_at_1`, `recall_at_5`, `recall_at_10`.
#[test]
fn lmeb_spec_recall_conformance() {
    let vectors = load_metric_vectors();
    let cases = vectors["recall_cases"].as_array().expect("recall_cases must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let ranked   = decode_ranked(&c["ranked_doc_ids"]);
        let relevant = decode_relevant(&c["relevant_doc_ids"]);

        for &k in &[1usize, 5, 10] {
            let key = format!("recall_at_{k}");
            if let Some(expected) = c[&key].as_f64() {
                let got = lmeb_spec_recall(&ranked, &relevant, k);
                assert!(
                    (got - expected).abs() < 1e-9,
                    "case {id}: Recall@{k} got {got} expected {expected}"
                );
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3 Precision conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `precision_cases` vector across all three k values tested in the JSON.
#[test]
fn lmeb_spec_precision_conformance() {
    let vectors = load_metric_vectors();
    let cases = vectors["precision_cases"].as_array().expect("precision_cases must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let ranked   = decode_ranked(&c["ranked_doc_ids"]);
        let relevant = decode_relevant(&c["relevant_doc_ids"]);

        for &k in &[1usize, 5, 10] {
            let key = format!("precision_at_{k}");
            if let Some(expected) = c[&key].as_f64() {
                let got = lmeb_spec_precision(&ranked, &relevant, k);
                assert!(
                    (got - expected).abs() < 1e-9,
                    "case {id}: Precision@{k} got {got} expected {expected}"
                );
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3 MRR conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `mrr_cases` vector.
///
/// Cases with `mrr_at_1/5/10` are iterated over those k values.
/// Cases with a single `k` + `mrr` field are tested at that specific k.
#[test]
fn lmeb_spec_mrr_conformance() {
    let vectors = load_metric_vectors();
    let cases = vectors["mrr_cases"].as_array().expect("mrr_cases must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let ranked   = decode_ranked(&c["ranked_doc_ids"]);
        let relevant = decode_relevant(&c["relevant_doc_ids"]);

        // Multi-k form: mrr_at_1, mrr_at_5, mrr_at_10.
        for &k in &[1usize, 5, 10] {
            let key = format!("mrr_at_{k}");
            if let Some(expected) = c[&key].as_f64() {
                let got = lmeb_spec_mrr(&ranked, &relevant, k);
                assert!(
                    (got - expected).abs() < 1e-9,
                    "case {id}: MRR@{k} got {got} expected {expected}"
                );
            }
        }

        // Single-k form: `k` + `mrr`.
        if let (Some(k), Some(expected)) = (c["k"].as_u64(), c["mrr"].as_f64()) {
            let got = lmeb_spec_mrr(&ranked, &relevant, k as usize);
            assert!(
                (got - expected).abs() < 1e-9,
                "case {id}: MRR@{k} got {got} expected {expected}"
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3 R_cap conformance (including None propagation)
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `rcap_cases` vector.
///
/// JSON `null` values represent R_cap = None (zero relevant docs → uncapped metric is undefined).
/// Each case can have `rcap_at_1`, `rcap_at_5`, `rcap_at_10`, `rcap_at_25`, `rcap_at_50`.
#[test]
fn lmeb_spec_rcap_conformance() {
    let vectors = load_metric_vectors();
    let cases = vectors["rcap_cases"].as_array().expect("rcap_cases must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let ranked   = decode_ranked(&c["ranked_doc_ids"]);
        let relevant = decode_relevant(&c["relevant_doc_ids"]);

        for &k in LMEB_SPEC_K_VALUES {
            let key = format!("rcap_at_{k}");
            if c.get(&key).is_some() {
                let expected_opt = if c[&key].is_null() {
                    None
                } else {
                    c[&key].as_f64()
                };

                let got = lmeb_spec_r_cap(&ranked, &relevant, k);

                match (got, expected_opt) {
                    (None, None) => { /* correct: both None */ }
                    (Some(g), Some(e)) => {
                        assert!(
                            (g - e).abs() < 1e-4,
                            "case {id}: R_cap@{k} got {g} expected {e}"
                        );
                    }
                    (got, expected) => {
                        panic!("case {id}: R_cap@{k} got {got:?} expected {expected:?}");
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3 R_cap macro average (None propagation + 5-decimal rounding)
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies R_cap None propagation through `lmeb_spec_subset_metrics`.
///
/// Drives the `rcap_macro_average_cases` test semantics by constructing synthetic
/// per-query inputs that produce the described per_query_values, then verifying the
/// subset macro average matches expected_avg.
#[test]
fn lmeb_spec_rcap_macro_average_none_propagation() {
    // Case: [None, 1.0] → expected_avg = 1.0.
    //   Query 1: no relevant docs (R_cap = None at all k).
    //   Query 2: 1 relevant at rank 1 (R_cap = 1.0 at k=5).
    let opts = LmebSpecOptions::default();
    let no_relevant: HashSet<String> = HashSet::new();
    let one_relevant: HashSet<String> = ["A".to_string()].into();

    let q1 = lmeb_spec_per_query_metrics(
        &["A".to_string(), "B".to_string()],
        &no_relevant,
        "q1",
        &opts,
    );
    let q2 = lmeb_spec_per_query_metrics(
        &["A".to_string(), "B".to_string()],
        &one_relevant,
        "q2",
        &opts,
    );

    let subset = lmeb_spec_subset_metrics(vec![q1, q2], "user_evidence");

    // R_cap@5 macro average: None ignored → avg(1.0) = 1.0.
    let rcap5 = subset.r_cap.iter()
        .find(|(k, _)| *k == 5)
        .and_then(|(_, v)| *v);
    assert_eq!(rcap5, Some(1.0),
        "[None, 1.0] macro average must be 1.0 (None ignored per §A3)");
}

#[test]
fn lmeb_spec_rcap_macro_average_all_none() {
    // Case: [None, None, None] → expected_avg = None.
    let opts = LmebSpecOptions::default();
    let no_relevant: HashSet<String> = HashSet::new();

    let queries: Vec<_> = (0..3).map(|i| {
        lmeb_spec_per_query_metrics(
            &["A".to_string()],
            &no_relevant,
            &format!("q{i}"),
            &opts,
        )
    }).collect();

    let subset = lmeb_spec_subset_metrics(queries, "preference_evidence");

    // All None → subset R_cap@5 = None.
    let rcap5 = subset.r_cap.iter()
        .find(|(k, _)| *k == 5)
        .and_then(|(_, v)| *v);
    assert_eq!(rcap5, None,
        "[None, None, None] macro average must be None (§A3)");
}

#[test]
fn lmeb_spec_rcap_macro_average_mixed() {
    // Case: [0.5, None, 1.0] → expected_avg = 0.75.
    //   Query with R_cap@5 = 0.5: 2 relevant, 1 hit in top-5, R_cap = 1/min(2,5) = 0.5.
    //   Query with R_cap@5 = None: no relevant docs.
    //   Query with R_cap@5 = 1.0: 1 relevant at rank 1, R_cap = 1/min(1,5) = 1.0.
    let opts = LmebSpecOptions::default();

    let two_relevant: HashSet<String> = ["A".to_string(), "B".to_string()].into();
    let no_relevant: HashSet<String>  = HashSet::new();
    let one_relevant: HashSet<String> = ["A".to_string()].into();

    // q_half: 2 relevant, only A at rank 1, B missing → R_cap@5 = 1/2 = 0.5.
    let q_half = lmeb_spec_per_query_metrics(
        &["A".to_string(), "X".to_string(), "Y".to_string()],
        &two_relevant,
        "q_half",
        &opts,
    );
    // q_none: no relevant → R_cap@5 = None.
    let q_none = lmeb_spec_per_query_metrics(
        &["A".to_string()],
        &no_relevant,
        "q_none",
        &opts,
    );
    // q_full: 1 relevant at rank 1 → R_cap@5 = 1.0.
    let q_full = lmeb_spec_per_query_metrics(
        &["A".to_string(), "B".to_string()],
        &one_relevant,
        "q_full",
        &opts,
    );

    let subset = lmeb_spec_subset_metrics(vec![q_half, q_none, q_full], "changing_evidence");

    let rcap5 = subset.r_cap.iter()
        .find(|(k, _)| *k == 5)
        .and_then(|(_, v)| *v);
    // avg(0.5, 1.0) = 0.75; rounded to 5 decimal places = 0.75.
    assert!(
        rcap5.map(|v| (v - 0.75).abs() < 1e-4).unwrap_or(false),
        "[0.5, None, 1.0] macro average must be ≈0.75, got {rcap5:?}"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3 skip_first_result options
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `skip_first_result_cases` vector.
///
/// Verifies that apply_options drops the first ranked result when the option is set,
/// then drives the affected metrics through the per-query compute path.
#[test]
fn lmeb_spec_skip_first_result_conformance() {
    let vectors = load_metric_vectors();
    let cases = vectors["skip_first_result_cases"]
        .as_array()
        .expect("skip_first_result_cases must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let opts     = decode_options(&c["options"]);
        let query_id = c["query_id"].as_str().unwrap_or("q");
        let ranked   = decode_ranked(&c["ranked_doc_ids"]);
        let relevant = decode_relevant(&c["relevant_doc_ids"]);

        // Verify the after-filter list if present.
        if let Some(after_arr) = c["after_filter"].as_array() {
            let expected_after: Vec<String> = after_arr
                .iter()
                .map(|s| s.as_str().unwrap_or("").to_string())
                .collect();
            let got_after = lmeb_spec_apply_options(&ranked, query_id, &opts);
            assert_eq!(got_after, expected_after,
                "case {id}: after_filter mismatch after apply_options");
        }

        let qm = lmeb_spec_per_query_metrics(&ranked, &relevant, query_id, &opts);

        for &k in &[1usize, 5, 10] {
            let ndcg_key  = format!("ndcg_at_{k}");
            let recall_key = format!("recall_at_{k}");
            let rcap_key  = format!("rcap_at_{k}");
            let mrr_key   = format!("mrr_at_{k}");

            if let Some(expected) = c[&ndcg_key].as_f64() {
                let got = qm.ndcg.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0);
                assert!((got - expected).abs() < 1e-9,
                    "case {id}: nDCG@{k} got {got} expected {expected}");
            }
            if let Some(expected) = c[&recall_key].as_f64() {
                let got = qm.recall.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0);
                assert!((got - expected).abs() < 1e-9,
                    "case {id}: Recall@{k} got {got} expected {expected}");
            }
            if c.get(&rcap_key).is_some() {
                let expected_opt = if c[&rcap_key].is_null() { None } else { c[&rcap_key].as_f64() };
                let got = qm.r_cap_at(k);
                match (got, expected_opt) {
                    (None, None) => {}
                    (Some(g), Some(e)) => {
                        assert!((g - e).abs() < 1e-4,
                            "case {id}: R_cap@{k} got {g} expected {e}");
                    }
                    _ => panic!("case {id}: R_cap@{k} got {got:?} expected {expected_opt:?}"),
                }
            }
            if let Some(expected) = c[&mrr_key].as_f64() {
                let got = qm.mrr.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0);
                assert!((got - expected).abs() < 1e-9,
                    "case {id}: MRR@{k} got {got} expected {expected}");
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3 ignore_identical_ids options
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `ignore_identical_ids_cases` vector.
#[test]
fn lmeb_spec_ignore_identical_ids_conformance() {
    let vectors = load_metric_vectors();
    let cases = vectors["ignore_identical_ids_cases"]
        .as_array()
        .expect("ignore_identical_ids_cases must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let opts     = decode_options(&c["options"]);
        let query_id = c["query_id"].as_str().unwrap_or("q");
        let ranked   = decode_ranked(&c["ranked_doc_ids"]);
        let relevant = decode_relevant(&c["relevant_doc_ids"]);

        // Verify after-filter if present.
        if let Some(after_arr) = c["after_filter"].as_array() {
            let expected_after: Vec<String> = after_arr
                .iter()
                .map(|s| s.as_str().unwrap_or("").to_string())
                .collect();
            let got_after = lmeb_spec_apply_options(&ranked, query_id, &opts);
            assert_eq!(got_after, expected_after,
                "case {id}: after_filter mismatch after apply_options");
        }

        let qm = lmeb_spec_per_query_metrics(&ranked, &relevant, query_id, &opts);

        for &k in &[1usize, 5, 10] {
            let ndcg_key   = format!("ndcg_at_{k}");
            let recall_key = format!("recall_at_{k}");
            let mrr_key    = format!("mrr_at_{k}");

            if let Some(expected) = c[&ndcg_key].as_f64() {
                let got = qm.ndcg.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0);
                assert!((got - expected).abs() < 1e-9,
                    "case {id}: nDCG@{k} got {got} expected {expected}");
            }
            if let Some(expected) = c[&recall_key].as_f64() {
                let got = qm.recall.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0);
                assert!((got - expected).abs() < 1e-9,
                    "case {id}: Recall@{k} got {got} expected {expected}");
            }
            if let Some(expected) = c[&mrr_key].as_f64() {
                let got = qm.mrr.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0);
                assert!((got - expected).abs() < 1e-9,
                    "case {id}: MRR@{k} got {got} expected {expected}");
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A1/§A3 Two-level aggregation
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `aggregation_cases` vector through the two-level aggregation path.
///
/// §A1: subset-level macro mean → task-level macro mean.
/// nDCG@10 is the headline metric.
#[test]
fn lmeb_spec_aggregation_two_level() {
    let vectors = load_metric_vectors();
    let cases   = vectors["aggregation_cases"]
        .as_array()
        .expect("aggregation_cases must be an array");

    for c in cases {
        let id      = c["id"].as_str().unwrap_or("(unknown)");
        let subsets_json = c["subsets"].as_array()
            .unwrap_or_else(|| panic!("case {id}: missing 'subsets'"));

        let opts = LmebSpecOptions::default();
        let mut subset_metrics = Vec::new();

        for s in subsets_json {
            let subset_name   = s["subset_name"].as_str().unwrap_or("unknown");
            let queries_json  = s["queries"].as_array()
                .unwrap_or_else(|| panic!("case {id}/{subset_name}: missing 'queries'"));

            let per_query_metrics: Vec<_> = queries_json.iter().map(|q| {
                let query_id = q["query_id"].as_str().unwrap_or("q");
                let ranked   = decode_ranked(&q["ranked_doc_ids"]);
                let relevant = decode_relevant(&q["relevant_doc_ids"]);
                lmeb_spec_per_query_metrics(&ranked, &relevant, query_id, &opts)
            }).collect();

            // Verify subset-level nDCG@10 if specified.
            let sub_m = lmeb_spec_subset_metrics(per_query_metrics, subset_name);
            if let Some(expected_ndcg) = s["expected_ndcg_at_10"].as_f64() {
                let got = sub_m.ndcg.iter()
                    .find(|(k, _)| *k == 10)
                    .map(|(_, v)| *v)
                    .unwrap_or(0.0);
                assert!(
                    (got - expected_ndcg).abs() < 1e-9,
                    "case {id}/{subset_name}: subset nDCG@10 got {got} expected {expected_ndcg}"
                );
            }

            // Verify subset-level R_cap@5 if specified.
            if c.get("expected_task_rcap_at_5").is_some() {
                if let Some(expected_rcap5) = s["expected_rcap_at_5"].as_f64() {
                    let got = sub_m.r_cap.iter()
                        .find(|(k, _)| *k == 5)
                        .and_then(|(_, v)| *v);
                    assert!(
                        got.map(|g| (g - expected_rcap5).abs() < 1e-4).unwrap_or(false),
                        "case {id}/{subset_name}: subset R_cap@5 got {got:?} expected {expected_rcap5}"
                    );
                } else if s["expected_rcap_at_5"].is_null() {
                    let got = sub_m.r_cap.iter()
                        .find(|(k, _)| *k == 5)
                        .and_then(|(_, v)| *v);
                    assert_eq!(got, None,
                        "case {id}/{subset_name}: subset R_cap@5 must be None");
                }
            }

            subset_metrics.push(sub_m);
        }

        let task_m = lmeb_spec_task_metrics(&subset_metrics);

        // Verify task-level nDCG@10 headline metric.
        if let Some(expected) = c["expected_task_ndcg_at_10"].as_f64() {
            let got = task_m.ndcg_at_10();
            assert!(
                (got - expected).abs() < 1e-9,
                "case {id}: task nDCG@10 got {got} expected {expected}"
            );
        }

        // Verify task-level R_cap@5 (None propagation through both levels).
        if c.get("expected_task_rcap_at_5").is_some() {
            let expected_opt = if c["expected_task_rcap_at_5"].is_null() {
                None
            } else {
                c["expected_task_rcap_at_5"].as_f64()
            };
            let got = task_m.r_cap.iter()
                .find(|(k, _)| *k == 5)
                .and_then(|(_, v)| *v);
            match (got, expected_opt) {
                (None, None) => {}
                (Some(g), Some(e)) => {
                    assert!((g - e).abs() < 1e-4,
                        "case {id}: task R_cap@5 got {g} expected {e}");
                }
                _ => panic!("case {id}: task R_cap@5 got {got:?} expected {expected_opt:?}"),
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A4 Instruction conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Drives the `instruction_cases` vector: all six §A4 instruction strings verbatim.
///
/// `lmeb_spec_instruction_for_subset` must return the exact instruction string for
/// each of the six ConvoMem subset names. Unknown names must return None.
#[test]
fn lmeb_spec_instruction_conformance() {
    let vectors = load_metric_vectors();
    let cases   = vectors["instruction_cases"]
        .as_array()
        .expect("instruction_cases must be an array");

    for c in cases {
        let id           = c["id"].as_str().unwrap_or("(unknown)");
        let instructions = c["instructions"].as_object()
            .unwrap_or_else(|| panic!("case {id}: missing 'instructions' object"));

        for (subset_name, expected_val) in instructions {
            let expected = expected_val.as_str()
                .unwrap_or_else(|| panic!("case {id}/{subset_name}: expected string value"));
            let got = lmeb_spec_instruction_for_subset(subset_name)
                .unwrap_or_else(|| panic!(
                    "case {id}: lmeb_spec_instruction_for_subset('{subset_name}') returned None"
                ));
            assert_eq!(got, expected,
                "case {id}/{subset_name}: instruction mismatch");
        }
    }
}

/// Unknown subset names must return None from `lmeb_spec_instruction_for_subset`.
#[test]
fn lmeb_spec_instruction_unknown_subset_is_none() {
    assert_eq!(
        lmeb_spec_instruction_for_subset("nonexistent_subset"),
        None,
        "unknown subset name must return None"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Golden pins
// ─────────────────────────────────────────────────────────────────────────────

/// §A3 golden pin: nDCG@10 hand-computed value.
///
/// Two relevant docs at ranks 1 and 3, k=10: DCG = 1 + 1/log2(4) = 1.5,
/// IDCG = 1 + 1/log2(3) ≈ 1.63093. nDCG ≈ 0.91972.
#[test]
fn lmeb_spec_ndcg_at_10_golden_pin() {
    let ranked: Vec<String>    = vec!["A", "B", "C", "D", "E"]
        .into_iter().map(String::from).collect();
    let relevant: HashSet<String> = ["A", "C"].into_iter().map(String::from).collect();

    let got = lmeb_spec_ndcg(&ranked, &relevant, 10);
    // Hand-computed: nDCG ≈ 0.9197207891481882 (matches Python ndcg_at_k output).
    assert!(
        (got - 0.9197207891481882).abs() < 1e-9,
        "nDCG@10 golden pin: got {got} expected ≈0.91972"
    );
}

/// §A3 golden pin: R_cap@5 None when relevant set is empty.
///
/// Zero relevant docs → R_cap is undefined (not 0.0) per §A3 / metric.py.
/// This is the most safety-critical distinction: returning 0.0 would suppress None
/// propagation and break the macro-average logic.
#[test]
fn lmeb_spec_rcap_none_when_no_relevant() {
    let ranked: Vec<String>    = vec!["A", "B", "C"].into_iter().map(String::from).collect();
    let relevant: HashSet<String> = HashSet::new();

    let got = lmeb_spec_r_cap(&ranked, &relevant, 5);
    assert_eq!(got, None,
        "R_cap@5 must be None when relevant set is empty (zero relevant docs → denominator undefined)");
}

/// §A3 golden pin: R_cap@5 = 0.0 when denominator > 0 but no hits in top-k.
///
/// Distinct from the None case: one relevant doc exists but is not in the top-5.
#[test]
fn lmeb_spec_rcap_zero_when_relevant_exists_but_no_hit() {
    let ranked: Vec<String>    = vec!["X", "Y", "Z"].into_iter().map(String::from).collect();
    let relevant: HashSet<String> = ["A"].into_iter().map(String::from).collect();

    let got = lmeb_spec_r_cap(&ranked, &relevant, 5);
    assert_eq!(got, Some(0.0),
        "R_cap@5 must be Some(0.0) when relevant doc exists but is absent from top-k");
}

/// §A1 golden pin: two-level aggregation nDCG@10.
///
/// Two subsets: user_evidence with mean 0.75, preference_evidence with mean 0.0.
/// Task mean = (0.75 + 0.0) / 2 = 0.375.
#[test]
fn lmeb_spec_two_level_aggregation_ndcg_at_10_golden_pin() {
    let opts = LmebSpecOptions::default();

    // user_evidence subset: q1 nDCG@10 = 1.0, q2 nDCG@10 = 0.5 → mean = 0.75.
    let q1 = lmeb_spec_per_query_metrics(
        &["A".to_string()],
        &["A".to_string()].into(),
        "q1",
        &opts,
    );
    let q2 = lmeb_spec_per_query_metrics(
        &["X".to_string(), "Y".to_string(), "A".to_string(), "Z".to_string()],
        &["A".to_string()].into(),
        "q2",
        &opts,
    );
    let user_sub = lmeb_spec_subset_metrics(vec![q1, q2], "user_evidence");
    let user_ndcg10 = user_sub.ndcg.iter()
        .find(|(k, _)| *k == 10)
        .map(|(_, v)| *v)
        .unwrap_or(0.0);
    assert!((user_ndcg10 - 0.75).abs() < 1e-9,
        "user_evidence subset nDCG@10 must be 0.75, got {user_ndcg10}");

    // preference_evidence subset: q3 has no relevant hits → nDCG@10 = 0.0.
    let q3 = lmeb_spec_per_query_metrics(
        &["X".to_string(), "Y".to_string(), "Z".to_string()],
        &["A".to_string()].into(),
        "q3",
        &opts,
    );
    let pref_sub = lmeb_spec_subset_metrics(vec![q3], "preference_evidence");

    let task_m = lmeb_spec_task_metrics(&[user_sub, pref_sub]);
    let task_ndcg10 = task_m.ndcg_at_10();
    assert!(
        (task_ndcg10 - 0.375).abs() < 1e-9,
        "task nDCG@10 golden pin: got {task_ndcg10} expected 0.375"
    );
}

/// §A3 golden pin: LmebSpecOptions defaults.
///
/// Both options must default to false — the original LMEB baseline condition.
#[test]
fn lmeb_spec_options_defaults() {
    let opts = LmebSpecOptions::default();
    assert!(!opts.skip_first_result,
        "skip_first_result must default to false (§A3 baseline)");
    assert!(!opts.ignore_identical_ids,
        "ignore_identical_ids must default to false (§A3 baseline)");
}

/// §A4 golden pin: all six instruction strings by literal value.
///
/// Byte-identical match against the strings in task_instructions.json (referenced in §A4).
/// Any deviation breaks parity between Swift and Rust ports.
#[test]
fn lmeb_spec_all_six_instructions_literal() {
    let expected = [
        ("abstention_evidence",
         "Given a query, retrieve documents that answer the query"),
        ("assistant_facts_evidence",
         "Given a query, retrieve assistant messages that answer the query"),
        ("changing_evidence",
         "Given a question, retrieve the latest information to answer the question"),
        ("implicit_connection_evidence",
         "Given a query, retrieve documents that answer the query"),
        ("preference_evidence",
         "Given a query, retrieve the user's stated preferences that can help answer the query"),
        ("user_evidence",
         "Given a query, retrieve documents that answer the query"),
    ];

    for (subset, instr) in &expected {
        let got = lmeb_spec_instruction_for_subset(subset)
            .unwrap_or_else(|| panic!("instruction_for_subset('{subset}') returned None"));
        assert_eq!(got, *instr,
            "§A4 instruction for '{subset}': got '{got}' expected '{instr}'");
    }
}
