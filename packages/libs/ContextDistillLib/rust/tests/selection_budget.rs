fn select(source: &str, trailer: usize, peer: bool) -> context_distill_lib::selection::IntentSpanResult {
    context_distill_lib::selection::intent_span_selection_with_budget(source, trailer, peer, true)
}

#[test]
fn oversized_source_preserved() {
    let source = "é".repeat(16385);
    let result = select(&source, 0, true);
    assert_eq!(result.compact_core, source);
    assert_eq!(result.selection_details["unsupported_shapes"], serde_json::json!(["source-byte-budget"]));
}

#[test]
fn many_atoms_preserved() {
    let source = (0..600).map(|i| format!("- Item {i} contains evidence.")).collect::<Vec<_>>().join("\n");
    let result = select(&source, 0, true);
    assert_eq!(result.compact_core, source);
    assert_eq!(result.selection_details["unsupported_shapes"], serde_json::json!(["atom-budget"]));
    assert_eq!(select(&source, 0, true).compact_core, result.compact_core);
}

#[test]
fn work_budget_preserves_source() {
    let source = (0..250).map(|i| format!("Unique item {i} describes orchard storage.")).collect::<Vec<_>>().join("\n");
    let result = select(&source, 0, true);
    assert_eq!(result.compact_core, source);
    assert_eq!(result.selection_details["unsupported_shapes"], serde_json::json!(["selector-work-budget"]));
}
