//! Output-only skim projection. Call only after the existing read gates.
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RecallSkim {
    pub text: String,
    pub complete: bool,
    #[serde(rename = "budgetHonored")]
    pub budget_honored: bool,
    pub savings: String,
}

/// Source order, no query ranking, no returned continuation or full body.
pub fn render(original: &str) -> RecallSkim {
    let reduced = genius_locus_kit::hydration_representation::distilled_rendering(original);
    let view = context_distill_lib::passage_views::skim(&reduced, "", 512, false)
        .expect("fixed positive skim budget");
    let savings = cognition_kit::distilled_savings_text(original, &reduced, true, Some(&view.text));
    RecallSkim { text: view.text, complete: view.complete, budget_honored: view.budget_honored, savings }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skim_short_empty_and_unicode_are_complete() {
        for text in ["", "Café 東京 🌱 is open."] {
            let skim = render(text);
            assert_eq!(skim.text, text);
            assert!(skim.complete && skim.budget_honored);
            assert!(skim.savings.starts_with("🌱"));
        }
    }

    #[test]
    fn skim_keeps_source_order_and_omits_tail_from_wire() {
        let first = "Opening fact about the conference. ".repeat(8);
        let source = format!("{first}\n\nThe omitted tail has another fact. {}", "detail ".repeat(70));
        let skim = render(&source);
        assert!(skim.text.starts_with("Opening fact"));
        assert!(!skim.text.contains("omitted tail"));
        assert!(!skim.complete && skim.budget_honored);
        let wire = serde_json::to_value(&skim).unwrap();
        assert_eq!(wire.as_object().unwrap().len(), 4);
        assert!(wire.get("continuation").is_none());
        assert!(wire.get("fullText").is_none());
        assert!(!wire.to_string().contains("omitted tail"));
    }

    #[test]
    fn skim_reports_oversized_intact_group() {
        let source = "東京".repeat(100);
        let skim = render(&source);
        assert_eq!(skim.text, source);
        assert!(skim.complete);
        assert!(!skim.budget_honored);
    }
}
