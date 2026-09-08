//! Conformance tests for CDL-01.
//!
//! - Shape classification tests (Part 1): all four beds, 509 rows.
//! - Full-row v23.2 conformance tests: 309 rows in v23_attributed_conformance.rs.
//! - Cross-port fixture helper (Part 5): writes JSONL when CDL_CROSSPORT_OUT
//!   is set.
//!
//! Each test bed is checked independently so failures are reported per bed.

mod oracle_vectors;

use context_distill_lib::converter::ContextDistillConverter;
use context_distill_lib::distiller::ContextDistiller;
use context_distill_lib::input::DistillationInput;
use context_distill_lib::shape::classify_record;
use serde_json::{Map, Value};

// ---------------------------------------------------------------------------
// §1 — Shape conformance helpers (Part 1)
// ---------------------------------------------------------------------------

/// Compare the port's ShapeDecision (serialised to Value) against the
/// oracle "shape" field from each JSONL row. All four beds, 509 rows.
fn run_shape_conformance(bed: &str) {
    let rows = oracle_vectors::load_bed(bed);
    let mut failures = Vec::new();

    for (i, row) in rows.iter().enumerate() {
        let original = row["original"]
            .as_str()
            .unwrap_or_else(|| panic!("row {i} in {bed}: 'original' not a string"));

        let decision = classify_record(original);
        let got: Value = serde_json::to_value(&decision)
            .unwrap_or_else(|e| panic!("row {i} in {bed}: serialize failed: {e}"));

        let expected = row["shape"].clone();

        if got != expected {
            failures.push(format!(
                "row {i} primary={} labels={:?}\n  got      = {}\n  expected = {}",
                decision.primary,
                decision.labels,
                serde_json::to_string_pretty(&got).unwrap_or_default(),
                serde_json::to_string_pretty(&expected).unwrap_or_default(),
            ));
        }
    }

    if !failures.is_empty() {
        panic!(
            "{} / {} rows failed in bed '{}':\n{}",
            failures.len(),
            rows.len(),
            bed,
            failures.join("\n---\n")
        );
    }
}

#[test]
fn shape_conformance_debug7() {
    run_shape_conformance("debug7");
}

#[test]
fn shape_conformance_sample30() {
    run_shape_conformance("sample30");
}

#[test]
fn shape_conformance_locomo() {
    run_shape_conformance("locomo");
}

#[test]
fn shape_conformance_blind200() {
    run_shape_conformance("blind200");
}

/// Recursively sort all Map keys in a Value for canonical comparison.
///
/// The oracle row's nested objects (shape, metrics, selection_details, etc.)
/// also need sorted keys for the string comparison to be order-independent.
fn sort_keys_recursive(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let sorted: std::collections::BTreeMap<String, Value> = map
                .into_iter()
                .map(|(k, v)| (k, sort_keys_recursive(v)))
                .collect();
            Value::Object(sorted.into_iter().collect())
        }
        Value::Array(arr) => Value::Array(arr.into_iter().map(sort_keys_recursive).collect()),
        other => other,
    }
}

// ---------------------------------------------------------------------------
// §3 — Cross-port fixture (CDL_CROSSPORT_OUT env var)
// ---------------------------------------------------------------------------

/// Write all 309 v23.2 Rust port output rows as canonical JSON
/// to the path in `CDL_CROSSPORT_OUT` when that variable is set.
///
/// When the variable is not set the test passes silently — it is a helper
/// for the cross-port diff, not a conformance gate.
///
/// Output format: one JSON object per line (JSONL).
/// - 309 v23.2 rows: debug7 → sample30 → locomo (no blind200 oracle for v23.2).
///
/// Each row carries `drawer_id`, `original`, `enrichment_trailer`, and `candidate`
/// alongside the converter output for cross-port correlation.
#[test]
fn crossport_fixture() {
    let out_path = match std::env::var("CDL_CROSSPORT_OUT") {
        Ok(p) if !p.is_empty() => p,
        _ => return, // Not set — skip.
    };

    let distiller = ContextDistiller::new();
    let mut lines: Vec<String> = Vec::with_capacity(309);

    // v23.2 rows: three beds (no blind200 oracle exists for v23.2).
    let v23_beds = ["debug7", "sample30", "locomo"];
    for bed in &v23_beds {
        let rows = oracle_vectors::load_bed_suffix(bed, "intent-span-v23-attributed");
        for (i, row) in rows.iter().enumerate() {
            let original  = row["original"].as_str()
                .unwrap_or_else(|| panic!("crossport v23.2 row {i} in {bed}: 'original' not string"));
            let trailer   = row["enrichment_trailer"].as_str().unwrap_or("");
            let drawer_id = row["drawer_id"].as_str().unwrap_or("?");

            let input = DistillationInput::new(original, trailer);
            let result = distiller.distill(&input, ContextDistillConverter::IntentSpanV23Attributed);

            let mut obj: Map<String, Value> = serde_json::to_value(&result)
                .expect("serialise v23.2 result")
                .as_object()
                .cloned()
                .expect("result is object");

            obj.insert("drawer_id".into(),          Value::String(drawer_id.to_string()));
            obj.insert("original".into(),           Value::String(original.to_string()));
            obj.insert("enrichment_trailer".into(), Value::String(trailer.to_string()));
            obj.insert("candidate".into(),
                Value::String("intent-span-v23-attributed".to_string()));

            let sorted = sort_keys_recursive(Value::Object(obj));
            lines.push(serde_json::to_string(&sorted).expect("line serialise"));
        }
    }

    let content = lines.join("\n") + "\n";
    std::fs::write(&out_path, content)
        .unwrap_or_else(|e| panic!("crossport_fixture: write {out_path}: {e}"));
}

#[test]
fn retired_v22_converter_is_unavailable() {
    assert!(serde_json::from_str::<ContextDistillConverter>("\"intent_span_v22\"").is_err());
    assert_eq!(
        ContextDistillConverter::CompleteFormV6.id(),
        "complete-form@complete-form-visible-v6"
    );
}
