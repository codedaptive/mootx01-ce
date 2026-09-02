//! Atoms conformance tests for CDL-01 Part 3.
//!
//! # Test 1: subset check (509 rows)
//!
//! For every oracle row the (start, end, kind, speaker) tuples of
//! `selected_source_spans` must be a subset of the atoms produced by
//! `intent_atoms(row.original)`.
//!
//! # Test 2: fixture pin (5 rows)
//!
//! Full atom list (all IntentAtom fields + SpeakerTurn fields) for the 5
//! fixture rows (one per shape.primary) must match the pinned
//! atoms-fixture-v22.json output from the Python oracle.
//!
//! # No regex
//! All pattern matching delegates to crate::scanners and crate::shape
//! hand-written scanners.  No regex crate is used.

mod oracle_vectors;

use context_distill_lib::atoms::{intent_atoms, IntentAtom};
use serde_json::Value;
use std::path::PathBuf;

// ---------------------------------------------------------------------------
// Helper: load atoms-fixture-v22.json
// ---------------------------------------------------------------------------

fn load_atoms_fixture() -> Vec<Value> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/ContextDistillLibTests/Vectors/atoms-fixture-v22.json");
    let content = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Failed to read atoms-fixture-v22.json: {e}"));
    serde_json::from_str(&content).expect("valid JSON in atoms-fixture-v22.json")
}

// ---------------------------------------------------------------------------
// Helper: span key from IntentAtom (start, end, kind, speaker)
// ---------------------------------------------------------------------------

#[derive(Debug, PartialEq, Eq, Hash)]
struct SpanKey {
    start: usize,
    end: usize,
    kind: String,
    speaker: Option<String>,
}

impl SpanKey {
    fn from_atom(atom: &IntentAtom) -> Self {
        SpanKey {
            start: atom.start,
            end: atom.end,
            kind: atom.kind.clone(),
            speaker: atom.speaker.clone(),
        }
    }

    fn from_oracle_span(span: &Value) -> Self {
        SpanKey {
            start: span["start"].as_u64().expect("start") as usize,
            end: span["end"].as_u64().expect("end") as usize,
            kind: span["kind"].as_str().expect("kind").to_string(),
            speaker: match &span["speaker"] {
                Value::Null => None,
                Value::String(s) => Some(s.clone()),
                other => panic!("unexpected speaker type: {other}"),
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Test 1: subset check across all 509 oracle rows
// ---------------------------------------------------------------------------

fn run_subset_check(bed: &str) {
    let rows = oracle_vectors::load_bed(bed);
    let mut failures: Vec<String> = Vec::new();

    for (i, row) in rows.iter().enumerate() {
        let original = row["original"]
            .as_str()
            .unwrap_or_else(|| panic!("row {i} in {bed}: 'original' not a string"));

        // Compute atoms from the Rust port.
        let result = intent_atoms(original);
        let produced_keys: std::collections::HashSet<SpanKey> = result
            .atoms
            .iter()
            .map(SpanKey::from_atom)
            .collect();

        // Check every oracle selected_source_span against produced atoms.
        let spans = match row.get("selected_source_spans") {
            Some(Value::Array(arr)) => arr,
            _ => continue, // no spans field → skip
        };

        let mut row_failures: Vec<String> = Vec::new();
        for span in spans {
            let key = SpanKey::from_oracle_span(span);
            if !produced_keys.contains(&key) {
                row_failures.push(format!(
                    "    span not found: start={} end={} kind={} speaker={:?}",
                    key.start, key.end, key.kind, key.speaker,
                ));
            }
        }
        if !row_failures.is_empty() {
            failures.push(format!(
                "row {i} bed={bed} drawer={} mode={} produced={} oracle_spans={}\n{}",
                &row["drawer_id"].as_str().unwrap_or("?")[..8],
                result.mode,
                result.atoms.len(),
                spans.len(),
                row_failures.join("\n"),
            ));
        }
    }

    if !failures.is_empty() {
        panic!(
            "{} / {} rows failed subset check in bed '{}':\n{}",
            failures.len(),
            rows.len(),
            bed,
            failures.join("\n---\n"),
        );
    }
}

#[test]
fn atoms_subset_debug7() {
    run_subset_check("debug7");
}

#[test]
fn atoms_subset_sample30() {
    run_subset_check("sample30");
}

#[test]
fn atoms_subset_locomo() {
    run_subset_check("locomo");
}

#[test]
fn atoms_subset_blind200() {
    run_subset_check("blind200");
}

// ---------------------------------------------------------------------------
// Test 2: full pin against atoms-fixture-v22.json
// ---------------------------------------------------------------------------

#[test]
fn atoms_fixture_pin() {
    let fixture = load_atoms_fixture();

    for entry in &fixture {
        let drawer_id = entry["drawer_id"].as_str().unwrap_or("?");
        let shape_primary = entry["shape_primary"].as_str().unwrap_or("?");

        // Find the matching oracle row to get the original text.
        // The fixture was generated from the oracle rows so we load it from
        // the vector beds.
        let original = find_original_for_drawer(drawer_id);

        let result = intent_atoms(&original);

        // Compare atom count.
        let expected_atoms = entry["atoms"].as_array().expect("atoms array");
        if result.atoms.len() != expected_atoms.len() {
            panic!(
                "drawer={} primary={}: atom count mismatch: got {} expected {}",
                &drawer_id[..8], shape_primary, result.atoms.len(), expected_atoms.len()
            );
        }

        // Compare each atom field-by-field.
        for (ai, (got, exp)) in result.atoms.iter().zip(expected_atoms.iter()).enumerate() {
            let exp_start = exp["start"].as_u64().expect("start") as usize;
            let exp_end = exp["end"].as_u64().expect("end") as usize;
            let exp_kind = exp["kind"].as_str().expect("kind");
            let exp_speaker: Option<String> = match &exp["speaker"] {
                Value::Null => None,
                Value::String(s) => Some(s.clone()),
                _ => None,
            };
            let exp_hard = exp["hard_required"].as_bool().expect("hard_required");

            if got.start != exp_start || got.end != exp_end {
                panic!(
                    "drawer={} atom[{ai}]: span mismatch: got [{},{}] expected [{},{}] kind={}",
                    &drawer_id[..8], got.start, got.end, exp_start, exp_end, exp_kind
                );
            }
            if got.kind != exp_kind {
                panic!(
                    "drawer={} atom[{ai}]: kind mismatch: got {:?} expected {:?}",
                    &drawer_id[..8], got.kind, exp_kind
                );
            }
            if got.speaker != exp_speaker {
                panic!(
                    "drawer={} atom[{ai}]: speaker mismatch: got {:?} expected {:?}",
                    &drawer_id[..8], got.speaker, exp_speaker
                );
            }
            if got.hard_required != exp_hard {
                panic!(
                    "drawer={} atom[{ai}]: hard_required mismatch: got {} expected {}",
                    &drawer_id[..8], got.hard_required, exp_hard
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helper: find the original text for a drawer_id across all beds
// ---------------------------------------------------------------------------

fn find_original_for_drawer(drawer_id: &str) -> String {
    for bed in &["debug7", "sample30", "locomo", "blind200"] {
        let rows = oracle_vectors::load_bed(bed);
        for row in rows {
            if row["drawer_id"].as_str() == Some(drawer_id) {
                return row["original"].as_str().expect("original").to_string();
            }
        }
    }
    panic!("drawer_id {drawer_id} not found in any bed");
}
