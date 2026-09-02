//! Conformance tests for CDL-01.
//!
//! - Shape classification tests (Part 1): all four beds, 509 rows.
//! - Full-row conformance tests (Part 5): all four beds, 509 rows.
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
// Excluded keys (mirrors Swift ConformanceTests.swift rowExcludedKeys)
// ---------------------------------------------------------------------------

/// Fields that are record-identity or input-only — not converter output.
/// The comparison excludes these from both the port output and the oracle row.
const EXCLUDED_KEYS: &[&str] = &[
    "drawer_id",
    "event_time",
    "original",
    "candidate",
    "enrichment_trailer",
];

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

// ---------------------------------------------------------------------------
// §2 — Full-row conformance helpers (Part 5)
// ---------------------------------------------------------------------------

/// Strip excluded keys from a JSON object.
fn filter_excluded(obj: &Map<String, Value>) -> Map<String, Value> {
    obj.iter()
        .filter(|(k, _)| !EXCLUDED_KEYS.contains(&k.as_str()))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
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

/// Run full-row conformance for one bed.
///
/// For each row, the Rust port's `DistilledRepresentation` (serialised as
/// canonical JSON, excluding `EXCLUDED_KEYS`) must equal the oracle row
/// (also with `EXCLUDED_KEYS` removed).
fn run_full_row_conformance(bed: &str) {
    let rows = oracle_vectors::load_bed(bed);
    let distiller = ContextDistiller::new();
    let mut failures = Vec::new();
    let mut pass_count = 0usize;

    for (i, row) in rows.iter().enumerate() {
        let original = row["original"]
            .as_str()
            .unwrap_or_else(|| panic!("row {i} in {bed}: 'original' not a string"));
        let trailer = row["enrichment_trailer"]
            .as_str()
            .unwrap_or("");
        let drawer_id = row["drawer_id"].as_str().unwrap_or("?");

        let input = DistillationInput::new(original, trailer);
        let result = distiller.distill(&input, ContextDistillConverter::IntentSpanV22);

        // Serialise the port output as a serde_json Value (canonical JSON).
        let port_value: Value = serde_json::to_value(&result)
            .unwrap_or_else(|e| panic!("row {i}: serialise port failed: {e}"));
        let port_obj = port_value.as_object()
            .unwrap_or_else(|| panic!("row {i}: port value is not an object"));

        // Oracle row object (already a Value::Object from load_bed).
        let oracle_obj = row.as_object()
            .unwrap_or_else(|| panic!("row {i}: oracle row is not an object"));

        // Filter excluded keys from both sides.
        let port_filtered = filter_excluded(port_obj);
        let oracle_filtered = filter_excluded(oracle_obj);

        // Sort keys recursively so nested dicts compare correctly regardless
        // of serde_json insertion order.
        let port_sorted = sort_keys_recursive(Value::Object(port_filtered));
        let oracle_sorted = sort_keys_recursive(Value::Object(oracle_filtered));

        let port_str   = serde_json::to_string(&port_sorted).unwrap_or_default();
        let oracle_str = serde_json::to_string(&oracle_sorted).unwrap_or_default();

        if port_str == oracle_str {
            pass_count += 1;
        } else {
            // Find first differing key for a focused diagnostic.
            let first_diff = port_sorted.as_object()
                .and_then(|pm| oracle_sorted.as_object().map(|om| (pm, om)))
                .and_then(|(pm, om)| {
                    let all_keys: std::collections::BTreeSet<&str> =
                        pm.keys().chain(om.keys()).map(String::as_str).collect();
                    all_keys.into_iter().find(|k| pm.get(*k) != om.get(*k))
                        .map(|k| k.to_string())
                });
            failures.push(format!(
                "row {i} drawer={drawer_id} first_diff={first_diff:?}\n  port:   {port_str}\n  oracle: {oracle_str}",
            ));
        }
    }

    if !failures.is_empty() {
        panic!(
            "{} / {} rows failed in bed '{}':\n{}",
            failures.len(),
            rows.len(),
            bed,
            failures.join("\n---\n"),
        );
    }
    // Explicit pass count assertion for audit log.
    assert_eq!(pass_count, rows.len(), "pass count mismatch in bed '{bed}'");
}

#[test]
fn full_row_conformance_debug7() {
    run_full_row_conformance("debug7");
}

#[test]
fn full_row_conformance_sample30() {
    run_full_row_conformance("sample30");
}

#[test]
fn full_row_conformance_locomo() {
    run_full_row_conformance("locomo");
}

#[test]
fn full_row_conformance_blind200() {
    run_full_row_conformance("blind200");
}

// ---------------------------------------------------------------------------
// §3 — Cross-port fixture (CDL_CROSSPORT_OUT env var)
// ---------------------------------------------------------------------------

/// Write all 509 Rust port output rows as canonical JSON to the path in
/// `CDL_CROSSPORT_OUT` when that variable is set.
///
/// When the variable is not set the test passes silently — it is a helper
/// for the cross-port diff, not a conformance gate.
///
/// Output format: one JSON object per line (JSONL), 509 lines, one per oracle
/// row in canonical order debug7 → sample30 → locomo → blind200.
///
/// The test helper writes `drawer_id`, `original`, `enrichment_trailer`, and
/// `candidate` into each row alongside the converter output so the cross-port diff
/// can correlate rows across ports.
#[test]
fn crossport_fixture() {
    let out_path = match std::env::var("CDL_CROSSPORT_OUT") {
        Ok(p) if !p.is_empty() => p,
        _ => return, // Not set — skip.
    };

    let distiller = ContextDistiller::new();
    let beds = ["debug7", "sample30", "locomo", "blind200"];
    let mut lines: Vec<String> = Vec::with_capacity(509);

    for bed in &beds {
        let rows = oracle_vectors::load_bed(bed);
        for (i, row) in rows.iter().enumerate() {
            let original  = row["original"].as_str()
                .unwrap_or_else(|| panic!("crossport row {i} in {bed}: 'original' not string"));
            let trailer   = row["enrichment_trailer"].as_str().unwrap_or("");
            let drawer_id = row["drawer_id"].as_str().unwrap_or("?");

            let input = DistillationInput::new(original, trailer);
            let result = distiller.distill(&input, ContextDistillConverter::IntentSpanV22);

            let mut obj: Map<String, Value> = serde_json::to_value(&result)
                .expect("serialise result")
                .as_object()
                .cloned()
                .expect("result is object");

            // Add record-identity fields for cross-port correlation.
            obj.insert("drawer_id".into(),          Value::String(drawer_id.to_string()));
            obj.insert("original".into(),           Value::String(original.to_string()));
            obj.insert("enrichment_trailer".into(), Value::String(trailer.to_string()));
            obj.insert("candidate".into(),          Value::String("intent-span".to_string()));

            // Serialise with sorted keys (mirrors Python json.dumps(sort_keys=True)).
            let sorted = sort_keys_recursive(Value::Object(obj));
            lines.push(serde_json::to_string(&sorted).expect("line serialise"));
        }
    }

    let content = lines.join("\n") + "\n";
    std::fs::write(&out_path, content)
        .unwrap_or_else(|e| panic!("crossport_fixture: write {out_path}: {e}"));
}
