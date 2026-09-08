use context_distill_lib::{converter::ContextDistillConverter, distiller::ContextDistiller, input::DistillationInput};

#[test]
fn complete_dispatch_keeps_source_and_trailer() {
    let source = "Nora may arrive Tuesday, unless the train is cancelled.\nDo not remove the 12 boxes.";
    let output = ContextDistiller::new().distill(&DistillationInput::new(source, "trailer from original"), ContextDistillConverter::CompleteFormV6);
    assert_eq!(output.compact_core, source);
    assert_eq!(output.ai_text, format!("{source} trailer from original"));
    assert_eq!(output.converter_id, "complete-form@complete-form-visible-v6");
    assert_eq!(output.selection_details["complete"], true);
    assert_eq!(output.selection_details["count_unit"], "tokens_estimate");
    assert_eq!(output.selected_source_spans.as_array().unwrap().len(), 1);
}

#[test]
fn complete_dispatch_invalid_reserved_text_falls_back() {
    use context_distill_lib::complete_content::{VISIBLE_NOTICE, REPEAT_LEGEND};
    let source = format!("{VISIBLE_NOTICE}{REPEAT_LEGEND}[[TSREF:9 REPEAT]]\n");
    let output = ContextDistiller::new().distill(&DistillationInput::new(&source, ""), ContextDistillConverter::CompleteFormV6);
    assert_eq!(output.ai_text, source);
    assert_eq!(output.selection_details["fallback_unchanged"], true);
}
