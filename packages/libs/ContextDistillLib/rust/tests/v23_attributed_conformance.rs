use std::collections::HashSet;

use context_distill_lib::atoms::IntentAtom;
use context_distill_lib::converter::ContextDistillConverter;
use context_distill_lib::distiller::ContextDistiller;
use context_distill_lib::input::DistillationInput;
use context_distill_lib::selection::render_exact;
use serde_json::Value;

mod oracle_vectors;

fn mode(result: &context_distill_lib::distiller::DistilledRepresentation) -> &str {
    result.selection_details["mode"].as_str().expect("mode")
}

fn distill(
    source: &str,
    converter: ContextDistillConverter,
) -> context_distill_lib::distiller::DistilledRepresentation {
    ContextDistiller::new().distill(&DistillationInput::new(source, ""), converter)
}

/// Fields excluded from full-row conformance comparison.
/// These are record-identity or input fields, not converter output.
const EXCLUDED_KEYS: &[&str] = &[
    "drawer_id",
    "event_time",
    "original",
    "candidate",
    "enrichment_trailer",
];

/// Strip excluded keys and recursively sort all map keys for canonical comparison.
fn canonical_filtered(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let sorted: std::collections::BTreeMap<String, Value> = map
                .into_iter()
                .filter(|(k, _)| !EXCLUDED_KEYS.contains(&k.as_str()))
                .map(|(k, v)| (k, canonical_filtered(v)))
                .collect();
            Value::Object(sorted.into_iter().collect())
        }
        Value::Array(arr) => Value::Array(arr.into_iter().map(canonical_filtered).collect()),
        other => other,
    }
}

/// Run full-row conformance for one v23.2 bed.
///
/// Loads `{bed}-intent-span-v23-attributed.jsonl` from the in-tree Vectors
/// directory, distils every row with `IntentSpanV23Attributed`, and compares
/// the output (excluding identity/input keys, canonical key order) against the
/// oracle row.  Fails with a structured diagnostic if any row diverges.
fn run_v23_full_row_conformance(bed: &str) {
    let rows = oracle_vectors::load_bed_suffix(bed, "intent-span-v23-attributed");
    let distiller = ContextDistiller::new();
    let mut failures = Vec::new();
    let mut pass_count = 0usize;

    for (i, row) in rows.iter().enumerate() {
        let original = row["original"]
            .as_str()
            .unwrap_or_else(|| panic!("row {i} in {bed}: 'original' not a string"));
        let trailer = row["enrichment_trailer"].as_str().unwrap_or("");
        let drawer_id = row["drawer_id"].as_str().unwrap_or("?");

        let input = DistillationInput::new(original, trailer);
        let result = distiller.distill(&input, ContextDistillConverter::IntentSpanV23Attributed);

        let port_value: Value = serde_json::to_value(&result)
            .unwrap_or_else(|e| panic!("row {i}: serialise port failed: {e}"));

        let port_sorted   = canonical_filtered(port_value);
        let oracle_sorted = canonical_filtered(row.clone());

        let port_str   = serde_json::to_string(&port_sorted).unwrap_or_default();
        let oracle_str = serde_json::to_string(&oracle_sorted).unwrap_or_default();

        if port_str == oracle_str {
            pass_count += 1;
        } else {
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
            "{} / {} rows failed in v23.2 bed '{}':\n{}",
            failures.len(),
            rows.len(),
            bed,
            failures.join("\n---\n"),
        );
    }
    assert_eq!(pass_count, rows.len(), "pass count mismatch in v23.2 bed '{bed}'");
}

// ---------------------------------------------------------------------------
// §1 — Full-row conformance over all three v23.2 oracle beds
// ---------------------------------------------------------------------------

/// Full-row conformance: IntentSpanV23Attributed matches every oracle field
/// for all 7 debug7 rows.
#[test]
fn v23_attributed_full_row_conformance_debug7() {
    run_v23_full_row_conformance("debug7");
}

/// Full-row conformance: IntentSpanV23Attributed matches every oracle field
/// for all 30 sample30 rows.
#[test]
fn v23_attributed_full_row_conformance_sample30() {
    run_v23_full_row_conformance("sample30");
}

/// Full-row conformance: IntentSpanV23Attributed matches every oracle field
/// for all 272 locomo rows.
#[test]
fn v23_attributed_full_row_conformance_locomo() {
    run_v23_full_row_conformance("locomo");
}

#[test]
fn v23_attributed_matches_focused_python_oracle() {
    let source = [
        "Alice: Good morning!",
        "Bob: Hi there!",
        "Alice: I decided to move to Boston on 2026-09-02.",
        "Bob: That sounds exciting and wonderful.",
        "Alice: I will start the new job on Friday.",
        "Bob: I prefer Austin, but Boston has great museums.",
        "Alice: The move requires 12 boxes.",
        "Bob: I can help pack the 12 boxes.",
    ]
    .join("\n");
    let trailer = "(*[ place: Boston, quantity: 12 ]*)";
    let result = ContextDistiller::new().distill(
        &DistillationInput::new(&source, trailer),
        ContextDistillConverter::IntentSpanV23Attributed,
    );

    assert_eq!(
        result.converter_id,
        "intent-span-v23-attributed@intent-span-v23.2-attributed-prose"
    );
    assert_eq!(result.ruleset_version, "intent-span-v23.2-attributed-prose");
    assert_eq!(mode(&result), "peer-dialogue");
    assert_eq!(
        result.selection_details["intent_span_version"],
        "intent-span-v22-authority-closure"
    );
    assert_eq!(
        result.selection_details["rendering"],
        "inline-attributed-prose"
    );
    assert_eq!(
        result.selection_details["peer_speakers"],
        serde_json::json!(["alice", "bob"])
    );
    assert_eq!(result.selection_details["peer_turn_count"], 8);
    assert_eq!(
        result.selection_details["discarded_turns"],
        serde_json::json!([
            {"reason": "filler", "speaker": "alice", "start": 0},
            {"reason": "filler", "speaker": "bob", "start": 21},
        ])
    );
    assert_eq!(
        result.compact_core,
        "Alice said: “I decided to move to Boston on 2026-09-02.” \
Bob said: “That sounds exciting and wonderful.” \
Alice said: “I will start the new job on Friday.” \
Bob said: “I prefer Austin, but Boston has great museums.” \
Alice said: “The move requires 12 boxes.” \
Bob said: “I can help pack the 12 boxes.”"
    );
    assert_eq!(result.applied_enrichment_trailer, trailer);
    assert_eq!(result.metrics["core_bytes"], 321);
    assert_eq!(result.metrics["distilled_bytes"], 357);
    assert_eq!(result.selection_details["selected_core_bytes"], 255);

    let spans = result.selected_source_spans.as_array().expect("spans");
    assert_eq!(spans.len(), 12);
    let selected_ids: HashSet<u64> = spans
        .iter()
        .filter_map(|span| span["atom_id"].as_u64())
        .collect();
    for span in spans {
        let start = span["start"].as_u64().expect("start") as usize;
        let end = span["end"].as_u64().expect("end") as usize;
        let start_byte = span["start_utf8_byte"].as_u64().expect("start byte") as usize;
        let end_byte = span["end_utf8_byte"].as_u64().expect("end byte") as usize;
        let source_chars: Vec<char> = source.chars().collect();
        assert_eq!(
            source_chars[start..end].iter().collect::<String>(),
            source[start_byte..end_byte]
        );
        if span["kind"] == "peer-speaker-prefix" {
            continue;
        }
        let prefix_dependencies: Vec<&Value> = span["dependencies"]
            .as_array()
            .expect("dependencies")
            .iter()
            .filter(|dependency| {
                let dependency_id = dependency.as_u64().expect("dependency id");
                selected_ids.contains(&dependency_id)
                    && spans.iter().any(|candidate| {
                        candidate["atom_id"].as_u64() == Some(dependency_id)
                            && candidate["kind"] == "peer-speaker-prefix"
                            && candidate["speaker"] == span["speaker"]
                    })
            })
            .collect();
        assert_eq!(prefix_dependencies.len(), 1);
    }
}

#[test]
fn v23_requires_every_strict_topology_threshold() {
    let cases = [
        // Fewer than six tagged turns.
        ["Alice: 1", "Bob: 2", "Alice: 3", "Bob: 4", "Alice: 5"].join("\n"),
        // More than two distinct labels.
        [
            "Alice: 1", "Bob: 2", "Carol: 3", "Alice: 4", "Bob: 5", "Carol: 6",
        ]
        .join("\n"),
        // Eight of nine nonblank lines are tagged: 88%, below the 90% floor.
        [
            "Alice: 1", "Bob: 2", "Alice: 3", "Bob: 4", "untagged", "Alice: 5", "Bob: 6",
            "Alice: 7", "Bob: 8",
        ]
        .join("\n"),
        // Two labels, but only one switch among five adjacencies.
        [
            "Alice: 1", "Alice: 2", "Alice: 3", "Bob: 4", "Bob: 5", "Bob: 6",
        ]
        .join("\n"),
        // Pinned roles are never arbitrary peers.
        [
            "User: 1", "Alice: 2", "User: 3", "Alice: 4", "User: 5", "Alice: 6",
        ]
        .join("\n"),
        // Metadata labels are never arbitrary peers.
        [
            "Name: Alice",
            "Date: 1",
            "Name: Bob",
            "Date: 2",
            "Name: Carol",
            "Date: 3",
        ]
        .join("\n"),
    ];

    for source in cases {
        let result = distill(&source, ContextDistillConverter::IntentSpanV23Attributed);
        assert_ne!(
            mode(&result),
            "peer-dialogue",
            "false positive for:\n{source}"
        );
        assert_eq!(result.selection_details["rendering"], "source-exact");
        assert!(!result.compact_core.contains(" said: "));
    }
}

#[test]
fn v23_detector_is_fence_aware() {
    let outside_peers = [
        "Alice: one",
        "Bob: two",
        "Alice: three",
        "Bob: four",
        "Alice: five",
        "Bob: six",
        "```",
        "Carol: fenced example",
        "Date: 2026-09-02",
        "```",
    ]
    .join("\n");
    assert_eq!(
        mode(&distill(
            &outside_peers,
            ContextDistillConverter::IntentSpanV23Attributed,
        )),
        "peer-dialogue"
    );

    let fenced_only = [
        "```",
        "Alice: one",
        "Bob: two",
        "Alice: three",
        "Bob: four",
        "Alice: five",
        "Bob: six",
        "```",
        "ordinary prose",
    ]
    .join("\n");
    assert_ne!(
        mode(&distill(
            &fenced_only,
            ContextDistillConverter::IntentSpanV23Attributed,
        )),
        "peer-dialogue"
    );
}

#[test]
fn document_exchange_precedes_peer_detection() {
    let payload = [
        "Alice: source fact one. ",
        "Bob: source fact two. ",
        "Alice: source fact three. ",
        "Bob: source fact four. ",
        "Alice: source fact five. ",
        "Bob: source fact six. ",
    ]
    .join("")
    .repeat(8);
    let source = format!(
        "User: Review this supplied document.\n{payload}\nAssistant: The generated transform is omitted."
    );
    let result = distill(&source, ContextDistillConverter::IntentSpanV23Attributed);
    assert_eq!(mode(&result), "document-exchange");
    assert_eq!(result.selection_details["rendering"], "source-exact");
}

#[test]
fn peer_nonwhitespace_gap_within_one_turn_renders_as_one_space() {
    let source = "Alice: Keep one. omit me Keep two.";
    let source_chars: Vec<char> = source.chars().collect();
    let atoms = vec![
        IntentAtom {
            atom_id: 0,
            start: 0,
            end: 7,
            text: "Alice: ".into(),
            kind: "peer-speaker-prefix".into(),
            speaker: Some("alice".into()),
            dependencies: vec![],
            hard_required: false,
        },
        IntentAtom {
            atom_id: 1,
            start: 7,
            end: 16,
            text: "Keep one.".into(),
            kind: "peer-sentence-or-entry".into(),
            speaker: Some("alice".into()),
            dependencies: vec![0],
            hard_required: false,
        },
        IntentAtom {
            atom_id: 2,
            start: 25,
            end: 34,
            text: "Keep two.".into(),
            kind: "peer-sentence-or-entry".into(),
            speaker: Some("alice".into()),
            dependencies: vec![0],
            hard_required: false,
        },
    ];
    let selected = HashSet::from([0, 1, 2]);
    let (rendered, _) = render_exact(&source_chars, &atoms, &selected, &HashSet::new());
    assert_eq!(rendered, "Alice: Keep one. Keep two.");
}
