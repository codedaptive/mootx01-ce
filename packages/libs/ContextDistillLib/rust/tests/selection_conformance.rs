//! Selection conformance tests for CDL-01 Part 4.
//!
//! For every oracle row (509 rows across four beds) the Rust
//! `intent_span_selection` function must produce:
//!
//! 1. `selected_source_spans` — exact field-by-field match with the oracle.
//! 2. `selection_details` — exact match excluding the `trailer_projection`
//!    key (which is outside CDL-01 Part 4 scope).
//! 3. `compact_core` — exact string match with the oracle.
//!
//! The test passes `applied_trailer_bytes` derived from the oracle row's
//! `applied_enrichment_trailer` field, which is the already-projected trailer
//! whose byte length drives the budget computation.

mod oracle_vectors;

use context_distill_lib::selection::intent_span_selection;
use serde_json::Value;

// ---------------------------------------------------------------------------
// Keys excluded from selection_details comparison
// ---------------------------------------------------------------------------

/// Keys in selection_details that are outside Part 4 scope.
const EXCLUDED_DETAIL_KEYS: &[&str] = &["trailer_projection"];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Per-bed runner
// ---------------------------------------------------------------------------

fn run_selection_conformance(bed: &str) {
    let rows = oracle_vectors::load_bed(bed);
    let mut failures: Vec<String> = Vec::new();

    for (i, row) in rows.iter().enumerate() {
        let source = row["original"]
            .as_str()
            .unwrap_or_else(|| panic!("row {i} in {bed}: 'original' not a string"));
        let drawer = row["drawer_id"].as_str().unwrap_or("?");

        // The applied trailer byte length drives the core budget.
        // Mirrors Python: len(projected_trailer.encode("utf-8")) in intent_span.
        let applied_trailer = row["applied_enrichment_trailer"]
            .as_str()
            .unwrap_or("");
        let applied_trailer_bytes = applied_trailer.len(); // UTF-8 byte count

        let result = intent_span_selection(source, applied_trailer_bytes);

        let mut row_failures: Vec<String> = Vec::new();

        // ---- 1. compact_core ----
        let oracle_core = row["compact_core"].as_str().unwrap_or("");
        if result.compact_core != oracle_core {
            row_failures.push(format!(
                "  compact_core mismatch:\n    got      = {:?}\n    expected = {:?}",
                &result.compact_core[..result.compact_core.len().min(200)],
                &oracle_core[..oracle_core.len().min(200)],
            ));
        }

        // ---- 2. selected_source_spans ----
        let oracle_spans = match row.get("selected_source_spans") {
            Some(Value::Array(arr)) => arr,
            _ => {
                row_failures.push("  selected_source_spans: not an array".to_string());
                failures.push(format!(
                    "row {i} bed={bed} drawer={}:\n{}",
                    &drawer[..drawer.len().min(8)],
                    row_failures.join("\n"),
                ));
                continue;
            }
        };
        let got_spans = &result.selected_source_spans;
        if got_spans.len() != oracle_spans.len() {
            row_failures.push(format!(
                "  selected_source_spans length: got={} expected={}",
                got_spans.len(), oracle_spans.len()
            ));
        } else {
            for (si, (gs, es)) in got_spans.iter().zip(oracle_spans.iter()).enumerate() {
                // Compare all fields present in oracle span.
                if let Value::Object(eo) = es {
                    for (k, ev) in eo {
                        let gv = gs.get(k.as_str()).unwrap_or(&Value::Null);
                        if gv != ev {
                            row_failures.push(format!(
                                "  span[{si}].{k}: got={} expected={}",
                                gv, ev,
                            ));
                        }
                    }
                }
            }
        }

        // ---- 3. selection_details (minus trailer_projection) ----
        let oracle_details = match row.get("selection_details") {
            Some(Value::Object(obj)) => obj,
            _ => {
                row_failures.push("  selection_details: not an object".to_string());
                failures.push(format!(
                    "row {i} bed={bed} drawer={}:\n{}",
                    &drawer[..drawer.len().min(8)],
                    row_failures.join("\n"),
                ));
                continue;
            }
        };

        let got_details = &result.selection_details;
        for (k, oracle_val) in oracle_details {
            if EXCLUDED_DETAIL_KEYS.contains(&k.as_str()) {
                continue; // skip trailer_projection
            }
            let got_val: Value = got_details.get(k.as_str())
                .cloned()
                .unwrap_or(Value::Null);
            if &got_val != oracle_val {
                row_failures.push(format!(
                    "  selection_details.{k}:\n    got      = {}\n    expected = {}",
                    serde_json::to_string(&got_val).unwrap_or_default(),
                    serde_json::to_string(oracle_val).unwrap_or_default(),
                ));
            }
        }

        if !row_failures.is_empty() {
            failures.push(format!(
                "row {i} bed={bed} drawer={}:\n{}",
                &drawer[..drawer.len().min(8)],
                row_failures.join("\n"),
            ));
        }
    }

    if !failures.is_empty() {
        panic!(
            "{} / {} rows failed selection conformance in bed '{}':\n{}",
            failures.len(),
            rows.len(),
            bed,
            failures[..failures.len().min(5)].join("\n---\n"),
        );
    }
}

// ---------------------------------------------------------------------------
// Test entry points — one per bed
// ---------------------------------------------------------------------------

#[test]
fn selection_conformance_debug7() {
    run_selection_conformance("debug7");
}

#[test]
fn selection_conformance_sample30() {
    run_selection_conformance("sample30");
}

#[test]
fn selection_conformance_locomo() {
    run_selection_conformance("locomo");
}

#[test]
fn selection_conformance_blind200() {
    run_selection_conformance("blind200");
}
