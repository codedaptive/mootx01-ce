//! The converter actually used by memory-get distilled reads.
use context_distill_lib::{converter::ContextDistillConverter, distiller::ContextDistiller, input::DistillationInput};

pub const CONVERTER: ContextDistillConverter = ContextDistillConverter::IntentSpanV23Attributed;

pub(crate) fn render(original: &str) -> String {
    ContextDistiller::new().distill(&DistillationInput::new(original, ""), CONVERTER).ai_text
}
