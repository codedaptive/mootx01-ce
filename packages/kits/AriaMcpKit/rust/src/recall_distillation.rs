//! The converter actually used by memory-get distilled reads.
use context_distill_lib::{converter::ContextDistillConverter, distiller::ContextDistiller, input::DistillationInput};

pub const CONVERTER: ContextDistillConverter = ContextDistillConverter::IntentSpanV23Attributed;

pub(crate) fn render(original: &str) -> String {
    let settings = moot_product_identity::settings::load(
        &moot_product_identity::storage::configuration_directory());
    if original.len() > settings.recall_distillation_max_source_bytes {
        return original.to_owned();
    }
    let result = ContextDistiller::new().distill_with_selection_budget(&DistillationInput::new(original, ""), CONVERTER, true);
    if result.selection_details["compression_skipped"].as_bool() == Some(true) {
        original.to_owned()
    } else {
        result.ai_text
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn large_batch_preserves_complete_evidence() {
        let source = "Unique evidence must not disappear.\n".repeat(10_000);
        for _ in 0..50 { assert_eq!(super::render(&source), source); }
    }

    #[test]
    fn atom_budget_preserves_whitespace_too() {
        let body = (0..600).map(|i| format!("- Item {i} contains evidence.")).collect::<Vec<_>>().join("\n");
        let source = format!("\n  {body}\n  ");
        assert_eq!(super::render(&source), source);
    }
}
